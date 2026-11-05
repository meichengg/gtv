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

    /// Bộ đếm / thời điểm sự kiện của WindowServer cập nhật ngay (`.exact`) hay chỉ ở mốc 0,5 s (`.coarse`).
    private(set) var counterMode: CounterMode = .exact
    /// Đã đủ dữ liệu để biết `counterMode` (lúc mới đăng nhập có thể chưa có sự kiện nào).
    private var counterModeKnown = false
    private var ledger = KeyLedger()
    private var pointer = PointerWatch()
    /// ⌘/⌃/⌥ được nhấn kể từ keyDown trước (theo flagsChanged bộ gõ nhận).
    private var modifierPressed = false
    /// Click được thấy ở lần đọc trước: có thể nó xảy ra sau phím đó (bấm phím rồi click ngay, trước lúc bộ gõ đọc bộ
    /// đếm), nên phím sau cũng coi là bị ngắt.
    private var pointerCarry = false
    /// Số lần đọc: lần kiểm tra hẹn giờ chỉ chạy nếu không có phím nào tới sau lần đọc đã hẹn nó.
    private var readings = 0
    /// Bộ đếm click lúc đọc phím gần nhất (`lateEditSafe`).
    private var clicksAtLastKey: UInt32 = 0
    private var checkTimer: DispatchSourceTimer?
    /// Lần đọc trạng thái lúc xử lý phím terminal gần nhất: `LiveInput` phải đọc liên tục từ đó tới phím sau.
    private var lastTerminalRead: Double?
    /// Lúc bộ gõ nhận keyDown gần nhất (mọi ứng dụng): `Modes` hỏi người dùng có gõ gì không.
    private(set) var lastKeyAt: Double = 0

    private init() {
        rebase()
    }

    private static func keyDownCount() -> UInt32 {
        CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
    }

    private static func secondsSinceKeyDown() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }

    /// macOS 27: thời điểm sự kiện công bố luôn là bội của 0,5 s (kể từ lúc khởi động); loại sự kiện chưa từng xảy ra thì
    /// giữ thời điểm tạo phiên đăng nhập. Thời điểm thật thì gần như không bao giờ trùng bội 0,5 s ở hai loại cùng lúc.
    /// Gọi lại (ở mỗi lần gắn vào ô nhập liệu) cho tới khi đủ dữ liệu. IME Lab ép được (`counterMode` = exact / coarse,
    /// bản Debug).
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
        let now = ProcessInfo.processInfo.systemUptime
        let times = types.compactMap { type -> Double? in
            let since = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
            return since < 1e6 ? now - since : nil
        }
        // Loại sự kiện chưa từng xảy ra giữ đúng thời điểm tạo phiên (nhiều loại trùng nhau tới từng nano giây): không phải
        // bằng chứng gì.
        let distinct = times.filter { t in times.filter { abs($0 - t) < 1e-7 }.count == 1 }
        let quantized = times.filter { t in
            let off = t.truncatingRemainder(dividingBy: 0.5)
            return min(off, 0.5 - off) < 0.0002
        }.count
        let exactTimes = distinct.filter { t in
            let off = t.truncatingRemainder(dividingBy: 0.5)
            return min(off, 0.5 - off) >= 0.0002
        }.count
        if quantized >= 3 || (quantized >= 2 && exactTimes == 0) {
            counterMode = .coarse
            counterModeKnown = true
        } else if exactTimes >= 2 && quantized <= 1 {
            counterMode = .exact
            counterModeKnown = true
        }
        let seen = times.count
        DebugLog.write("bộ đếm sự kiện: \(counterMode.rawValue)\(counterModeKnown ? "" : " (chưa chắc)") — \(quantized)/\(seen) loại làm tròn 0,5 s")
    }

    #if DEBUG
    /// IME Lab vừa đổi `counterMode` (ép / bỏ ép): nhận biết lại ngay.
    func reloadCounterModeForLab() {
        counterModeKnown = false
        detectCounterMode()
        rebase()
    }
    #endif

    /// Bộ gõ vừa gắn vào một ô nhập liệu, hoặc vừa có click: những gì xảy ra trước đó không còn liên quan.
    func rebase() {
        detectCounterMode()
        checkTimer?.cancel()
        checkTimer = nil
        ledger.rebase(keyDownCount: Self.keyDownCount())
        modifierPressed = false
        pointerCarry = false
        _ = pointer.changed(Self.pointerCount())
        LiveInput.shared.forgetPending()
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
            let live = LiveInput.shared
            live.sample()
            let covered = lastTerminalRead.map { live.log.covered(since: $0) } ?? false
            return covered && !live.log.pending.contains { $0.key == nil }
        }
    }

    /// flagsChanged bộ gõ nhận. Phím tắt có ⌘/⌃/⌥ đi vòng bộ gõ (⌘V, Ctrl+A…): sổ phím tính là lỡ ngay, không chờ.
    func noteModifiers(_ flags: NSEvent.ModifierFlags) {
        if !flags.isDisjoint(with: [.command, .control, .option]) { modifierPressed = true }
    }

    /// Gọi với mọi keyDown bộ gõ nhận (cả ở chế độ E, ứng dụng loại trừ), trước khi xử lý phím: giữa phím trước
    /// mà bộ gõ thấy và phím này có phím / click nào bộ gõ không thấy không.
    /// `terminal`: ô nhập liệu của app terminal (chỉ ở đó các tín hiệu này được dùng: đọc trạng thái liên tục, hẹn kiểm tra).
    func observe(_ event: NSEvent, terminal: Bool) -> KeyGap {
        readings += 1
        checkTimer?.cancel()
        checkTimer = nil
        let previousStamp = lastKeyAt
        lastKeyAt = event.timestamp
        let live = LiveInput.shared
        let previousRead = lastTerminalRead
        if terminal { live.keep(for: 5) }
        live.sample()
        // Đọc liên tục từ lần đọc ở phím terminal trước tới giờ thì mới biết chắc có gì xen giữa không (đã ngừng đọc vì lâu
        // không gõ thì lần đọc vừa rồi bắt đầu lại từ đầu).
        let covered = previousRead.map { live.log.covered(since: $0) } ?? true
        if terminal { lastTerminalRead = live.log.lastSample }
        live.keyReceived(event)
        let modifier = modifierPressed
        modifierPressed = false
        let keyModifier = !event.modifierFlags.isDisjoint(with: [.command, .control, .option])
        let shortcut = modifier && !keyModifier

        let gap: KeyGap
        switch counterMode {
        case .coarse:
            // Không có bộ đếm tức thời để sắp thứ tự: lần nhấn được đọc thấy sớm hơn lúc ứng dụng nhận phím này quá độ trễ
            // giao phím lớn nhất thì chắc là trước nó — trừ khi phím này nằm trong loạt phím dồn ra sau lúc ứng dụng treo
            // (cách phím trước dưới 5 ms: có thể đã được bấm từ trước đó). Còn lại thì chưa chắc: vẫn báo, giữ lại cho phím
            // sau.
            let burst = event.timestamp - previousStamp < 0.005
            let horizon = event.timestamp - Self.maxDelivery
            let taken = burst ? [] : live.take { $0.at <= horizon }
            let uncertain = live.log.pending.contains { $0.at <= ProcessInfo.processInfo.systemUptime }
            if shortcut || (terminal && !covered) {
                gap = .interrupted
            } else if !taken.isEmpty || uncertain {
                gap = .bypassed
            } else if IsSecureEventInputEnabled() {
                // Secure input (ô mật khẩu, "Secure Keyboard Entry" của terminal, Ghostty lúc gặp dấu nhắc mật khẩu):
                // WindowServer đóng băng trạng thái phím của bàn phím thật — không thấy được ⌫ / mũi tên đi vòng. Nút
                // chuột thì vẫn thấy. Không phải bằng chứng: terminal cho đọc màn hình thì đối chiếu màn hình.
                gap = .unverified
            } else {
                gap = .none
            }
            #if DEBUG
            if terminal {
                DebugLog.write("sổ phím (thô): \(gap)\(taken.isEmpty ? "" : ", lỡ \(taken.map { $0.key.map(String.init) ?? "click" })")\(uncertain ? ", chưa chắc \(live.log.pending.map { $0.key.map(String.init) ?? "click" })" : "")\(covered ? "" : ", có khoảng không đọc")\(modifier ? ", có ⌘/⌃/⌥" : "")\(burst ? ", dồn" : "") phím \(event.keyCode)")
            }
            #endif
        case .exact:
            gap = exactGap(event, modifier: modifier, keyModifier: keyModifier, quietChecks: terminal)
        }
        return gap
    }

    /// Độ trễ lớn nhất từ lúc bấm tới lúc ứng dụng nhận phím (IME Lab: 1–60 ms), cộng một chu kỳ đọc trạng thái.
    private static let maxDelivery = 0.06 + LiveInput.interval

    private func exactGap(_ event: NSEvent, modifier: Bool, keyModifier: Bool, quietChecks: Bool) -> KeyGap {
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
        var missedKeys = 0
        var missedClick = false
        if var acc = ledger.accounted {
            let live = LiveInput.shared
            let ordered = live.log.pending.sorted { ledger.unwrapped($0.count) < ledger.unwrapped($1.count) }
            var take: [PressLog.Press] = []
            for press in ordered where press.key != nil && ledger.unwrapped(press.count) <= acc {
                take.append(press)
                acc += 1
            }
            for press in ordered where press.key == nil && ledger.unwrapped(press.count) < acc {
                take.append(press)
            }
            let taken = live.take { press in take.contains(press) }
            missedKeys = taken.filter { $0.key != nil }.count
            missedClick = taken.contains { $0.key == nil }
            if missedKeys > 0 { ledger.noteBypassed(missedKeys) }
        }
        let clicks = Self.pointerCount()
        clicksAtLastKey = clicks
        let clicked = pointer.changed(clicks)
        let pointerMoved = clicked || pointerCarry
        // Click ngay trước lúc ứng dụng nhận phím này (thời điểm phím muộn hơn lúc bấm tới ~60 ms) có thể đã xảy ra sau
        // khi bấm phím: phím sau cũng coi là bị ngắt. Click từ trước đó thì không.
        pointerCarry = clicked && Self.secondsSinceClick() < ProcessInfo.processInfo.systemUptime - event.timestamp + 0.06
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

    private static func pointerCount() -> UInt32 {
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types.reduce(0) { $0 &+ CGEventSource.counterForEventType(.combinedSessionState, eventType: $1) }
    }
}
