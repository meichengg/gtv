import AppKit
import CoreGraphics
import IOKit
import VietEngine

/// Đọc liên tục (mỗi 8 ms) trạng thái phím đặc biệt, nút chuột và phím bổ trợ của WindowServer — chỉ lúc cần: đang gõ trong
/// terminal, đang giữ phím tắt đổi chế độ, vài giây sau khi đổi ứng dụng / ô nhập liệu.
///
/// Chỉ đọc bộ nhớ chung WindowServer cấp cho mọi tiến trình: không event tap, không chặn hay tạo sự kiện, không cần quyền.
/// Các trạng thái này cập nhật ngay cho mọi tiến trình, kể cả trên macOS 27 — nơi bộ đếm và thời điểm sự kiện
/// (`CGEventSourceCounterForEventType`, `…SecondsSinceLastEventType`) chỉ được công bố ở các mốc 0,5 s, thời điểm làm tròn
/// xuống, với mọi tiến trình dù có quyền Input Monitoring. Phím ký tự (chữ, số, dấu câu) thì WindowServer chỉ cho tiến trình
/// đang ở trước hay có quyền đọc: bộ gõ không đọc được. Xem `PressLog`.
///
/// Đọc ở một luồng riêng (ưu tiên cao): luồng chính có thể bận cả trăm mili giây (chờ ứng dụng trả lời InputMethodKit…) —
/// đọc trên luồng chính thì mỗi lần như vậy là một khoảng hở giả (`PressLog.covered`), phím sau bị coi là có thể đã có gì
/// xen giữa và lần sửa gửi muộn của Ghostty bị bỏ. Sổ (`PressLog`) dùng chung cho hai luồng, luôn trong khoá.
final class LiveInput {
    static let shared = LiveInput()

    /// Return, Enter, Tab, Delete, ⌦, Esc, ←, →, ↓, ↑, Home, End, PgUp, PgDn, F1–F12.
    static let watchedKeys: [CGKeyCode] = [36, 76, 48, 51, 117, 53, 123, 124, 125, 126, 115, 119, 116, 121,
                                           122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    static let interval = 0.008
    /// Chu kỳ đọc lúc đang giữ phím tắt đổi chế độ (vài trăm mili giây): hai sự kiện HID trong một chu kỳ chỉ thấy được cái
    /// sau — đọc dày hơn để lần nhả phím bổ trợ không che mất chữ Z của ⌘⇧Z.
    static let hidInterval = 0.002

    private let queue = DispatchQueue(label: "GTV.LiveInput", qos: .userInteractive, autoreleaseFrequency: .workItem)
    /// Khoá mọi trạng thái bên dưới. Giữ khoá cả lúc đọc (vài micro giây): các lần đọc của hai luồng nối tiếp nhau đúng thứ
    /// tự thời gian.
    private let lock = NSLock()
    private var _log = PressLog()
    /// Hạn đọc: `keep` (Modes, phím tắt đổi chế độ), phím terminal (`keepTerminal`, bỏ khi rời ô nhập liệu đó), HID.
    private var until = 0.0
    private var terminalUntil = 0.0
    private var hidUntil = 0.0
    private var timer: DispatchSourceTimer?
    /// Timer đang chạy ở `hidInterval`.
    private var fast = false
    private var activity: NSObjectProtocol?
    private let hid: io_service_t = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    /// Lúc nhấn tổ hợp phím tắt đổi chế độ (`trackHID`): phím bổ trợ đang giữ, và lúc WindowServer thấy lần đổi phím bổ trợ
    /// cuối (macOS 26: tức thời).
    private var armFlags: (held: UInt64, changedAt: Double)?

    private init() {
        // Đổi ứng dụng: hạn đọc cho terminal chỉ còn đủ cho lần chốt từ lúc rời ô (deactivateServer: lần sửa gửi muộn của
        // Ghostty cần biết đã đọc liên tục) — không đọc tiếp tới 5 s sau phím cuối khi không còn gõ ở đó.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.terminalUntil = min(self.terminalUntil, ProcessInfo.processInfo.systemUptime + 1.5)
        }
    }

    /// Người dùng đã bấm phím đặc biệt / click / phím bổ trợ mà chưa tới bộ gõ (xem `PressLog.userKeysPending`); `since`: thời điểm
    /// phím bộ gõ nhận gần nhất.
    func userKeysPending(since: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard timer != nil else { return false }
        let reason = _log.userKeysPendingReason(now: ProcessInfo.processInfo.systemUptime, since: since)
        #if DEBUG
        if reason != lastPendingReason, let reason { DebugLog.write("phím chưa tới: \(reason)") }
        lastPendingReason = reason
        #endif
        return reason != nil
    }
    #if DEBUG
    private var lastPendingReason: String?
    #endif

    /// Bản sao sổ lúc này.
    var log: PressLog {
        lock.lock()
        defer { lock.unlock() }
        return _log
    }

    /// Đọc liên tục ít nhất `seconds` giây nữa.
    func keep(for seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        until = max(until, ProcessInfo.processInfo.systemUptime + seconds)
        startLocked()
    }

    /// Phím terminal: đọc liên tục ít nhất `seconds` giây nữa — hạn riêng, hết khi rời ô nhập liệu (`endTerminal`).
    func keepTerminal(for seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        terminalUntil = max(terminalUntil, ProcessInfo.processInfo.systemUptime + seconds)
        startLocked()
    }

    /// Bộ gõ đã rời ô terminal (gắn vào ô khác, click, đổi chế độ — sau khi đã chốt từ): không cần đọc cho nó nữa. Các hạn
    /// khác (Modes, phím tắt) vẫn giữ.
    func endTerminal() {
        lock.lock()
        defer { lock.unlock() }
        terminalUntil = 0
    }

    private func startLocked() {
        guard timer == nil else { return }
        sampleLocked()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        fast = ProcessInfo.processInfo.systemUptime < hidUntil
        scheduleLocked(t)
        // Bộ gõ là tiến trình nền: không để hệ thống giãn timer (App Nap) lúc đang cần đọc đều.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                         reason: "GTV: theo dõi phím đặc biệt và click lúc gõ")
        t.resume()
    }

    private func scheduleLocked(_ t: DispatchSourceTimer) {
        let interval = fast ? Self.hidInterval : Self.interval
        t.schedule(deadline: .now() + interval, repeating: interval,
                   leeway: fast ? .microseconds(500) : .milliseconds(1))
    }

    /// Luồng đọc.
    private func tick() {
        lock.lock()
        defer { lock.unlock() }
        guard let t = timer else { return }
        sampleLocked()
        let now = ProcessInfo.processInfo.systemUptime
        if now >= max(until, terminalUntil, hidUntil) {
            stopLocked()
        } else if fast && now >= hidUntil {
            fast = false
            scheduleLocked(t)
        }
    }

    private func stopLocked() {
        timer?.cancel()
        timer = nil
        fast = false
        if let activity {
            DispatchQueue.main.async { ProcessInfo.processInfo.endActivity(activity) }
        }
        activity = nil
    }

    /// Đọc thêm `HIDIdleTime` trong `seconds` giây tới, lúc nhấn tổ hợp phím tắt đổi chế độ (đọc nó tốn hơn, cần một lời gọi
    /// tới kernel), đọc dày hơn (`hidInterval`). Mốc lấy ngay bây giờ: các sự kiện tới lúc này (kể cả chính lần nhấn phím bổ
    /// trợ) không tính; lần nhấn trước (nếu còn trong hạn) bị bỏ. Hết khi nhả tổ hợp (`endHID`).
    func trackHID(for seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        hidUntil = now + seconds
        startLocked()
        if !fast, let t = timer {
            fast = true
            scheduleLocked(t)
        }
        let changedAt = ProcessInfo.processInfo.systemUptime
            - CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .flagsChanged)
        armFlags = (_log.lastFlags ?? 0, changedAt)
        _log.startHID()
        if let event = readHID() { _log.noteHID(event) }
    }

    /// Đã nhả tổ hợp phím tắt đổi chế độ (`Hotkey` đã kết luận): thôi đọc HID, timer về chu kỳ thường hoặc dừng nếu không còn
    /// hạn nào khác.
    func endHID() {
        lock.lock()
        defer { lock.unlock() }
        hidUntil = min(hidUntil, ProcessInfo.processInfo.systemUptime)
    }

    /// Lúc WindowServer thấy tổ hợp `flags` được nhấn — lần nhấn đang theo dõi (`trackHID`), sớm hơn lúc bộ gõ nhận khi ứng
    /// dụng giao chậm. Chỉ đúng khi thời điểm sự kiện tức thời (macOS 26); nil nếu lúc đó phím bổ trợ đang giữ không đúng là
    /// tổ hợp (đã nhả trước lúc bộ gõ nhận) hay lần đổi đó quá xa.
    func hotkeyPressedAt(_ flags: NSEvent.ModifierFlags, armedAt: Double) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        let mask = CGEventFlags([.maskShift, .maskControl, .maskAlternate, .maskCommand]).rawValue
        guard let arm = armFlags, arm.held & mask == UInt64(flags.rawValue) & mask,
              arm.changedAt <= armedAt, armedAt - arm.changedAt < 0.5 else { return nil }
        return arm.changedAt
    }

    /// Đọc ngay.
    func sample() {
        lock.lock()
        defer { lock.unlock() }
        sampleLocked()
    }

    /// Đọc ngay rồi chạy `body` với sổ, trong khoá: luồng đọc không chen vào giữa. `body` không được gọi lại `LiveInput`.
    func sampled<T>(_ body: (inout PressLog) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        sampleLocked()
        return body(&_log)
    }

    /// Chạy `body` với sổ, trong khoá (không đọc thêm). `body` không được gọi lại `LiveInput`.
    func withLog<T>(_ body: (inout PressLog) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&_log)
    }

    private func sampleLocked() {
        let now = ProcessInfo.processInfo.systemUptime
        var held = Set<UInt16>()
        for key in Self.watchedKeys where CGEventSource.keyState(.combinedSessionState, key: key) {
            held.insert(UInt16(key))
        }
        let button = [CGMouseButton.left, .right, .center]
            .contains { CGEventSource.buttonState(.combinedSessionState, button: $0) }
        let mask: CGEventFlags = [.maskAlphaShift, .maskShift, .maskControl, .maskAlternate, .maskCommand,
                                  .maskSecondaryFn]
        let flags = CGEventSource.flagsState(.combinedSessionState).intersection(mask).rawValue
        let count = CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
        _log.sample(at: now, held: held, button: button, flags: flags, keyDownCount: count)
        if now < hidUntil {
            if let event = readHID() { _log.noteHID(event) }
        } else if _log.hidActive {
            _log.endHID()
        }
    }

    /// Thời điểm sự kiện HID cuối (`HIDIdleTime` của IOHIDSystem: không làm tròn, không cần quyền) — chỉ có với bàn phím /
    /// chuột thật, không có với phím do chương trình gõ hay điều khiển từ xa. Sự kiện mới mà không có đổi phím bổ trợ đi kèm
    /// là phím ký tự (hay di chuột): dùng cho phím tắt đổi chế độ (⌘⇧Z không phải ⌘⇧ "trơn"). Tính với đồng hồ đọc trước và
    /// sau lời gọi kernel (lấy điểm giữa); lời gọi bị chen lâu thì đọc lại — sai số dưới 0,25 ms.
    private func readHID() -> Double? {
        guard hid != 0 else { return nil }
        for _ in 0..<3 {
            let before = ProcessInfo.processInfo.systemUptime
            guard let value = IORegistryEntryCreateCFProperty(hid, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue(), let ns = (value as? NSNumber)?.doubleValue else { return nil }
            let after = ProcessInfo.processInfo.systemUptime
            if after - before <= 0.0005 { return (before + after) / 2 - ns / 1e9 }
        }
        return nil
    }

    /// Bỏ các lần nhấn đang chờ đối chiếu (đổi ô nhập liệu, click bộ gõ thấy…).
    func forgetPending() {
        withLog { $0.forget() }
    }

    /// Đang giữ phím đặc biệt hay nút chuột nào không (đọc ngay).
    func anyHeld() -> Bool {
        sampled { $0.anyHeld }
    }

    /// Người dùng có nhấn phím đặc biệt, nút chuột hay nhấn thêm phím bổ trợ (nhả thì không tính) trong [from, to] không —
    /// chỉ biết khi đã đọc liên tục suốt khoảng đó (`covered`).
    func activity(from: Double, to: Double) -> (seen: Bool, covered: Bool) {
        withLog { log in
            (log.pressed(from: from, to: to) || log.flagsPressed(from: from, to: to), log.covered(since: from))
        }
    }
}
