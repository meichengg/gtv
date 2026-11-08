import AppKit
import Carbon
import CoreGraphics
import VietEngine

/// Phát hiện phím / click bộ gõ không thấy giữa hai phím, dùng chung cho mọi ô nhập liệu. Không event tap, không chặn hay
/// tạo phím, không cần quyền:
/// - `LiveInput`: phím đặc biệt (⌫, Tab, ⏎, mũi tên…) và nút chuột được nhấn mà bộ gõ không nhận — đọc trạng thái, cập
///   nhật ngay trên mọi phiên bản macOS;
/// - phím bổ trợ ⌘/⌃/⌥ (flagsChanged bộ gõ nhận): phím tắt đi vòng bộ gõ (⌘V, Ctrl+A…);
/// - sổ phím (`KeyLedger`): so số keyDown WindowServer đếm với số bộ gõ nhận — bắt được cả phím ký tự đi vòng, nhưng chỉ
///   khi bộ đếm cập nhật ngay (macOS 26). macOS 27 chỉ công bố bộ đếm mỗi 0,5 s (`counterMode == .coarse`): không dùng sổ.
final class KeyWatch {
    static let shared = KeyWatch()

    enum CounterMode: String { case exact, coarse }

    /// Bộ đếm / thời điểm sự kiện của WindowServer cập nhật ngay (`.exact`) hay chỉ ở mốc 0,5 s (`.coarse`). Chưa đủ dữ liệu
    /// để biết thì theo phiên bản macOS.
    private(set) var counterMode: CounterMode = KeyWatch.defaultCounterMode
    /// Đã đủ dữ liệu để biết `counterMode` (lúc mới đăng nhập có thể chưa có sự kiện nào).
    private var counterModeKnown = false
    /// Kết luận của lần nhận biết trước: chỉ tin khi hai lần liền nhau cùng kết luận.
    private var counterModeCandidate: CounterMode?
    private var ledger = KeyLedger()
    private var pointer = PointerWatch()
    /// ⌘/⌃/⌥ được nhấn kể từ keyDown trước (theo flagsChanged bộ gõ nhận).
    private var modifierPressed = false
    /// macOS 27: phím trước có phím / click đi vòng bộ gõ (hay khoảng không đọc). Phím dồn ra ngay sau nó (loạt phím sau lúc
    /// ứng dụng treo) có thể cũng được bấm trước lần nhấn đó: cũng báo.
    private var burstCarry = false
    /// Số lần đọc: lần kiểm tra hẹn giờ chỉ chạy nếu không có phím nào tới sau lần đọc đã hẹn nó.
    private var readings = 0
    /// Bộ đếm click lúc đọc phím gần nhất (`lateEditSafe`).
    private var clicksAtLastKey: UInt32 = 0
    /// macOS 27: số click lần đọc nút chuột đã thấy mà bộ đếm của hệ thống chưa công bố.
    private var clickCredit = 0
    /// Click còn chờ trong sổ (theo `PressLog.Press.at`) mà bộ đếm đã công bố trước lúc phím tạo sau nó tới: lúc sổ lấy nó ra
    /// không tính là click mới công bố lần nữa.
    private var publishedPending: [Double] = []
    private var checkTimer: DispatchSourceTimer?
    /// Lần đọc trạng thái lúc xử lý phím terminal gần nhất: `LiveInput` phải đọc liên tục từ đó tới phím sau.
    private var lastTerminalRead: Double?
    /// Lúc bộ gõ nhận keyDown gần nhất (mọi ứng dụng): `Modes` hỏi người dùng có gõ gì không.
    private(set) var lastKeyAt: Double = 0

    private init() {
        rebase()
    }

    /// macOS 27 trở lên: `.coarse`. Ứng dụng build với SDK cũ thấy số phiên bản "tương thích" (macOS 26 báo 16, 27 báo 17).
    private static var defaultCounterMode: CounterMode {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return major >= 27 || (major >= 17 && major < 26) ? .coarse : .exact
    }

    private static func keyDownCount() -> UInt32 {
        CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
    }

    private static func secondsSinceKeyDown() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }

    /// macOS 27: thời điểm sự kiện công bố luôn là bội của 0,5 s (kể từ lúc khởi động); loại sự kiện chưa từng xảy ra thì
    /// giữ thời điểm tạo phiên đăng nhập. Thời điểm thật thì gần như không bao giờ trùng bội 0,5 s ở hai loại cùng lúc
    /// (`KeyLedger.eventTimesQuantized`). Gọi lại (lúc gắn vào ô nhập liệu, ở mỗi phím) cho tới khi hai lần liền nhau cùng
    /// kết luận. IME Lab ép được (`counterMode` = exact / coarse, bản Debug).
    func detectCounterMode() {
        #if DEBUG
        if let forced = UserDefaults.standard.string(forKey: "counterMode").flatMap(CounterMode.init) {
            counterMode = forced
            counterModeKnown = true
            return
        }
        #endif
        guard !counterModeKnown else { return }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp,
                                    .rightMouseDown, .scrollWheel]
        var times: [Double] = []
        for type in types {
            let since = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
            // Đọc đồng hồ ngay sau mỗi lần hỏi: luồng bị chen giữa các lần hỏi không làm lệch các loại sau.
            let now = ProcessInfo.processInfo.systemUptime
            if since < 1e6 { times.append(now - since) }
        }
        guard let quantized = KeyLedger.eventTimesQuantized(times) else { return }
        let verdict: CounterMode = quantized ? .coarse : .exact
        if verdict == counterModeCandidate {
            counterMode = verdict
            counterModeKnown = true
            DebugLog.write("bộ đếm sự kiện: \(verdict.rawValue)")
        } else {
            DebugLog.write("bộ đếm sự kiện: có vẻ \(verdict.rawValue) (chờ lần sau), đang dùng \(counterMode.rawValue)")
        }
        counterModeCandidate = verdict
    }

    #if DEBUG
    /// IME Lab vừa đổi `counterMode` (ép / bỏ ép): nhận biết lại ngay.
    func reloadCounterModeForLab() {
        counterModeKnown = false
        counterModeCandidate = nil
        counterMode = Self.defaultCounterMode
        detectCounterMode()
        rebase()
    }
    #endif

    /// Phím giả bộ gõ vừa gửi mà sẽ không tới bộ gõ (xem `KeyLedger.expectUnseen`).
    func expectUnseen(_ n: Int) { ledger.expectUnseen(n) }

    /// Bộ gõ vừa gắn vào một ô nhập liệu, hoặc vừa có click: những gì xảy ra trước đó không còn liên quan.
    func rebase() {
        detectCounterMode()
        checkTimer?.cancel()
        checkTimer = nil
        ledger.rebase(keyDownCount: Self.keyDownCount())
        modifierPressed = false
        burstCarry = false
        clickCredit = 0
        publishedPending = []
        // macOS 27: click làm ô nhận focus có thể chỉ được công bố sau lúc này.
        pointer.rebase(Self.pointerCount(), at: ProcessInfo.processInfo.systemUptime,
                       quantum: counterMode == .coarse ? 0.5 : nil)
        let live = LiveInput.shared
        live.forgetPending()
        live.endTerminal()
        lastTerminalRead = nil
    }

    /// Từ phím bộ gõ nhận gần nhất tới giờ không có phím tắt (⌘/⌃/⌥ được nhấn) hay click nào: lần sửa gửi muộn của
    /// Ghostty vẫn đúng chỗ (phím thường bấm sau đó sẽ tới bộ gõ và được xử lý theo thứ tự).
    func lateEditSafe() -> Bool {
        guard !modifierPressed else { return false }
        switch counterMode {
        case .exact:
            return Self.pointerCount() == clicksAtLastKey
        case .coarse:
            // Click hệ thống mới công bố (mỗi 0,5 s) mà lần đọc nút chuột không thấy (chạm để click trên trackpad…).
            if pointer.differs(Self.pointerCount(), lastClickAt: Self.lastClickTime()) { return false }
            let since = lastTerminalRead
            return LiveInput.shared.sampled { log in
                let covered = since.map { log.covered(since: $0) } ?? false
                return covered && !log.pending.contains { $0.key == nil }
            }
        }
    }

    /// flagsChanged bộ gõ nhận. Phím tắt có ⌘/⌃/⌥ đi vòng bộ gõ (⌘V, Ctrl+A…): sổ phím tính là lỡ ngay, không chờ.
    func noteModifiers(_ flags: NSEvent.ModifierFlags) {
        if !flags.isDisjoint(with: [.command, .control, .option]) { modifierPressed = true }
    }

    /// Gọi với mọi keyDown bộ gõ nhận (cả ở chế độ E, ứng dụng loại trừ), trước khi xử lý phím: giữa phím trước
    /// mà bộ gõ thấy và phím này có phím / click nào bộ gõ không thấy không.
    /// `terminal`: ô nhập liệu của app terminal (chỉ ở đó các tín hiệu này được dùng: đọc trạng thái liên tục, hẹn kiểm tra).
    /// `syntheticSince`: phím giả của chính bộ gõ, gửi lúc đó (vẫn vào sổ đếm, không được coi là lần nhấn của người dùng).
    func observe(_ event: NSEvent, terminal: Bool, throughIME: Bool = false, syntheticSince: Double? = nil) -> KeyGap {
        if !counterModeKnown {
            let before = counterMode
            detectCounterMode()
            if counterMode != before { rebase() }        // sổ / mốc click lấy theo kiểu cũ: lấy lại
        }
        readings += 1
        checkTimer?.cancel()
        checkTimer = nil
        let synthetic = syntheticSince != nil
        let previousStamp = lastKeyAt
        // Phím giả của bộ gõ được tạo ngay sau phím trước: không phải loạt phím dồn ra sau lúc ứng dụng treo — không đổi mốc.
        if !synthetic { lastKeyAt = event.timestamp }
        let live = LiveInput.shared
        live.endHID()                       // phím tới: InputController đã bỏ lần nhấn phím tắt đổi chế độ (nếu có)
        let previousRead = lastTerminalRead
        if terminal { live.keepTerminal(for: 5) }
        let modifier = modifierPressed
        modifierPressed = false
        let keyModifier = !event.modifierFlags.isDisjoint(with: [.command, .control, .option])
        let shortcut = modifier && !keyModifier
        let coarse = counterMode == .coarse
        // macOS 27 (không có bộ đếm tức thời để sắp thứ tự): lần nhấn được đọc thấy sớm hơn lúc ứng dụng nhận phím này quá độ
        // trễ giao phím lớn nhất thì chắc là trước nó — trừ khi phím này nằm trong loạt phím dồn ra sau lúc ứng dụng treo
        // (cách phím trước dưới 5 ms: có thể đã được bấm từ trước đó). Lần nhấn đọc thấy chưa giữ ở một lần đọc sau phím này
        // thì chắc là sau nó. Còn lại thì chưa chắc: vẫn báo, giữ lại cho phím sau.
        let burst = coarse && !synthetic && event.timestamp - previousStamp < 0.005
        var covered = true
        var read: Double?
        var order: (taken: [PressLog.Press], uncertain: Bool) = ([], false)
        live.sampled { log in
            // Đọc liên tục từ lần đọc ở phím terminal trước tới giờ thì mới biết chắc có gì xen giữa không (đã ngừng đọc vì lâu
            // không gõ thì lần đọc vừa rồi bắt đầu lại từ đầu).
            covered = previousRead.map { log.covered(since: $0) } ?? true
            read = log.lastSample
            if let since = syntheticSince {
                log.syntheticKeyArrived(event.keyCode, since: since, at: event.timestamp)
            } else {
                log.keyReceived(event.keyCode, at: event.timestamp, isRepeat: event.isARepeat,
                                now: ProcessInfo.processInfo.systemUptime)
            }
            if coarse {
                order = log.order(keyAt: event.timestamp, maxDelivery: Self.maxDelivery, burst: burst, clicksOnly: throughIME)
            }
        }
        if terminal { lastTerminalRead = read }

        let gap: KeyGap
        switch counterMode {
        case .coarse:
            // Click mà lần đọc nút chuột không thấy (chạm để click trên trackpad, click rất nhanh): bộ đếm hệ thống công bố
            // mỗi 0,5 s — biết muộn, nhưng vẫn hơn không.
            // Click lần đọc nút chuột đã thấy (đã báo ở phím này hay phím trước) thì lúc bộ đếm công bố không báo lần nữa — báo
            // hai lần là bỏ ngang một từ đang gõ sau click (dấu rời khỏi từ).
            var published = pointer.newClicks(Self.pointerCount(), lastClickAt: Self.lastClickTime())
            let takenClicks = order.taken.filter { $0.key == nil }.map(\.at)
            clickCredit += takenClicks.filter { !publishedPending.contains($0) }.count
            publishedPending.removeAll { takenClicks.contains($0) }
            let known = min(published, clickCredit)
            published -= known
            clickCredit -= known
            if published > 0 {
                // Bộ đếm báo trước: click còn chờ trong sổ là chính click đó. Click có thể trước phím này: lấy ra luôn, không báo
                // lại ở phím sau. Click đọc thấy sau lúc tạo phím này thì còn xếp sau nó trong hàng đợi của ứng dụng: để lại trong
                // sổ (phím sửa vẫn hoãn tới khi phím tạo sau click tới — sổ lấy nó ra và báo ngắt lúc đó), ghi là đã công bố.
                let stamp = event.timestamp
                let owed = publishedPending
                let earlier = live.withLog { log in
                    log.take { $0.key == nil && $0.after < stamp && !owed.contains($0.at) }
                }.count
                let matched = min(published, earlier)
                clickCredit += earlier - matched
                published -= matched
                if published > 0 {
                    let later = live.withLog { log in log.pending.filter { $0.key == nil && !owed.contains($0.at) }.map(\.at) }
                    let paid = later.prefix(published)
                    publishedPending += paid
                    published -= paid.count
                }
            }
            let stillPending = live.withLog { log in log.pending.filter { $0.key == nil }.map(\.at) }
            publishedPending.removeAll { !stillPending.contains($0) }
            let clicked = published > 0
            let carried = burst && burstCarry
            if shortcut {
                gap = .interrupted
            } else if (terminal && !covered) || clicked || !order.taken.isEmpty || order.uncertain || carried {
                // Khoảng không đọc (lâu không gõ nên đã ngừng đọc): không biết có gì xen giữa — như có phím đi vòng. Terminal
                // cho đọc màn hình thì màn hình quyết định (từ đang gõ dở không mất vì dừng tay), terminal khác thì bỏ từ.
                gap = .bypassed
            } else if IsSecureEventInputEnabled() {
                // Secure input (ô mật khẩu, "Secure Keyboard Entry" của terminal, Ghostty lúc gặp dấu nhắc mật khẩu):
                // WindowServer đóng băng trạng thái phím của bàn phím thật — không thấy được ⌫ / mũi tên đi vòng. Nút
                // chuột thì vẫn thấy. Không phải bằng chứng: terminal cho đọc màn hình thì đối chiếu màn hình.
                gap = .unverified
            } else {
                gap = .none
            }
            if !synthetic { burstCarry = gap == .bypassed }
            #if DEBUG
            if terminal {
                let pending = live.log.pending.map { $0.key.map(String.init) ?? "click" }
                DebugLog.write("sổ phím (thô): \(gap)\(order.taken.isEmpty ? "" : ", lỡ \(order.taken.map { $0.key.map(String.init) ?? "click" })")\(order.uncertain ? ", chưa chắc \(pending)" : "")\(covered ? "" : ", có khoảng không đọc")\(clicked ? ", bộ đếm click đổi" : "")\(carried ? ", dồn sau phím có phím đi vòng" : "")\(modifier ? ", có ⌘/⌃/⌥" : "")\(burst ? ", dồn" : "") phím \(event.keyCode)")
            }
            #endif
        case .exact:
            gap = exactGap(event, modifier: modifier, keyModifier: keyModifier, quietChecks: terminal, synthetic: synthetic)
        }
        return gap
    }

    /// Độ trễ lớn nhất từ lúc bấm tới lúc ứng dụng nhận phím (IME Lab: 1–60 ms), cộng một chu kỳ đọc trạng thái.
    private static let maxDelivery = 0.06 + LiveInput.interval

    private func exactGap(_ event: NSEvent, modifier: Bool, keyModifier: Bool, quietChecks: Bool, synthetic: Bool = false) -> KeyGap {
        let since = Self.secondsSinceKeyDown()           // trước bộ đếm
        let count = Self.keyDownCount()
        let verdict = ledger.observe(KeyReading(keyDownCount: count, timestamp: event.timestamp, keyCode: event.keyCode,
                                                isRepeat: event.isARepeat, readAt: ProcessInfo.processInfo.systemUptime,
                                                sinceLastKeyDown: since),
                                     modifierPressed: modifier, keyHasModifier: keyModifier)
        // Sắp thứ tự lần nhấn (phím đặc biệt, click) với phím này bằng bộ đếm keyDown: ứng dụng xử lý phím theo thứ tự bấm,
        // nên phím đặc biệt có số đếm (lúc thấy nó được nhấn) không vượt quá phần sổ đã xử lý xong là đã được xử lý trước
        // phím này; click thì trước phím này nếu số phím đã bấm trước nó nhỏ hơn. Lần nhấn sau phím này để lại cho phím sau
        // (sổ còn thấy nó là phím chưa thấy: "chưa biết").
        let accounted = ledger.accounted
        let (taken, clickPending) = LiveInput.shared.withLog { log -> ([PressLog.Press], Bool) in
            var take: [PressLog.Press] = []
            if var acc = accounted {
                let ordered = log.pending.sorted { self.ledger.unwrapped($0.count) < self.ledger.unwrapped($1.count) }
                // Phím giả tới: lần nhấn phím đặc biệt còn chờ có thể là trạng thái phím của phím giả kế tiếp — không coi là phím đi vòng.
                for press in ordered where !synthetic && press.key != nil && self.ledger.unwrapped(press.count) <= acc {
                    take.append(press)
                    acc += 1
                }
                for press in ordered where press.key == nil && self.ledger.unwrapped(press.count) < acc {
                    take.append(press)
                }
            }
            // Click đọc thấy trước lúc tạo phím này (phím thật): theo thứ tự thì ứng dụng đã xử lý nó trước phím này — cả khi sổ
            // phím chưa có mốc (click chờ không còn hết hạn theo đồng hồ).
            if !synthetic {
                for press in log.pending where press.key == nil && press.at + 0.02 < event.timestamp && !take.contains(press) {
                    take.append(press)
                }
            }
            let taken = take.isEmpty ? [] : log.take { press in take.contains(press) }
            return (taken, log.pending.contains { $0.key == nil })
        }
        let missedKeys = taken.filter { $0.key != nil }.count
        let missedClick = taken.contains { $0.key == nil }
        if missedKeys > 0 { ledger.noteBypassed(missedKeys) }
        let clicks = Self.pointerCount()
        clicksAtLastKey = clicks
        // Click ngay trước lúc ứng dụng nhận phím này (thời điểm phím muộn hơn lúc bấm tới ~60 ms) có thể đã xảy ra sau
        // khi bấm phím: phím sau cũng coi là bị ngắt — trừ khi lần đọc nút chuột đã thấy nó (đã sắp thứ tự với phím này,
        // hay còn chờ báo ở phím sau). Click từ trước đó thì không.
        let pointerMoved = pointer.moved(clicks, recentClick: Self.secondsSinceClick()
                                            < ProcessInfo.processInfo.systemUptime - event.timestamp + 0.06,
                                         sampled: missedClick || clickPending)
        if quietChecks { scheduleCheck(step: 0, reading: readings, since: event.timestamp) }
        #if DEBUG
        let delivery = (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000
        DebugLog.write("sổ phím: \(verdict)\(pointerMoved ? ", có click" : "")\(modifier ? ", có ⌘/⌃/⌥" : "")\(missedKeys > 0 ? ", lỡ \(missedKeys) phím đặc biệt" : "")\(missedClick ? ", click" : "") phím \(event.keyCode)\(event.isARepeat ? " (lặp)" : "") đếm \(count), tới sau \(String(format: "%.2f", delivery)) ms")
        #endif
        if missedKeys > 0 || missedClick { return .bypassed }
        return pointerMoved ? .interrupted : verdict.gap(modifierPressed: modifier && !keyModifier)
    }

    /// Sau mỗi phím, kiểm tra vài lần (`KeyLedger.checkDelays`) xem có phím đi vòng bộ gõ không (còn phím đã đếm mà bộ
    /// gõ chưa thấy, lúc không có phím nào được bấm). Phím mới tới thì bỏ các lần còn lại.
    private func scheduleCheck(step: Int, reading: Int, since keyTime: Double, retry: Double? = nil, waits: Int = 0) {
        guard step < KeyLedger.checkDelays.count else { return }
        let due = retry ?? keyTime + KeyLedger.checkDelays[step] - ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(0.01, due), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self, self.readings == reading else { return }
            self.checkTimer = nil
            let count = Self.keyDownCount()
            let since = Self.secondsSinceKeyDown()           // sau bộ đếm
            let result = self.ledger.check(keyDownCount: count, secondsSinceLastKeyDown: since,
                                           now: ProcessInfo.processInfo.systemUptime)
            switch result {
            case .resolved:
                #if DEBUG
                DebugLog.write("sổ phím: kiểm tra (phím cuối cách \(Int(since * 1000)) ms): có phím đi vòng bộ gõ")
                #endif
            case .wait where waits < 2:
                // vừa có phím được bấm (ở đâu đó) mà bộ gõ chưa thấy: thử lại khi đã yên
                self.scheduleCheck(step: step, reading: reading, since: keyTime,
                                   retry: max(0.02, self.ledger.quietTime - since), waits: waits + 1)
            case .wait:
                self.scheduleCheck(step: step + 1, reading: reading, since: keyTime)
            case .none:
                self.scheduleCheck(step: step + 1, reading: reading, since: keyTime)
            }
        }
        checkTimer = timer
        timer.resume()
    }

    private static func secondsSinceClick() -> Double {
        [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }

    /// Thời điểm click cuối hệ thống công bố (macOS 27: làm tròn xuống mốc 0,5 s).
    private static func lastClickTime() -> Double {
        ProcessInfo.processInfo.systemUptime - secondsSinceClick()
    }

    private static func pointerCount() -> UInt32 {
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types.reduce(0) { $0 &+ CGEventSource.counterForEventType(.combinedSessionState, eventType: $1) }
    }
}
