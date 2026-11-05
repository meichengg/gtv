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
final class LiveInput {
    static let shared = LiveInput()

    /// Return, Enter, Tab, Delete, ⌦, Esc, ←, →, ↓, ↑, Home, End, PgUp, PgDn, F1–F12.
    static let watchedKeys: [CGKeyCode] = [36, 76, 48, 51, 117, 53, 123, 124, 125, 126, 115, 119, 116, 121,
                                           122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    static let interval = 0.008

    private(set) var log = PressLog()
    private var until = 0.0
    private var timer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    private let hid: io_service_t = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    /// Các sự kiện HID mới (bàn phím / chuột thật), lúc đọc thấy (chỉ đọc lúc `trackHID(for:)`). Sự kiện không trùng lần
    /// đổi phím bổ trợ nào là phím ký tự hay di chuột (`Hotkey.isCleanTap`).
    private(set) var hidEvents: [Double] = []
    private var lastHIDEvent: Double?
    private var hidUntil = 0.0

    private init() {}

    /// Đọc liên tục ít nhất `seconds` giây nữa.
    func keep(for seconds: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        until = max(until, now + seconds)
        guard timer == nil else { return }
        sample()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        t.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        // Bộ gõ là tiến trình nền: không để hệ thống giãn timer (App Nap) lúc đang cần đọc đều.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                         reason: "GTV: theo dõi phím đặc biệt và click lúc gõ")
        t.resume()
    }

    private func tick() {
        sample()
        if ProcessInfo.processInfo.systemUptime >= until { stop() }
    }

    private func stop() {
        timer?.cancel()
        timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    /// Đọc thêm `HIDIdleTime` trong `seconds` giây tới (lúc giữ phím tắt đổi chế độ: đọc nó tốn hơn, cần một lời gọi
    /// tới kernel). Mốc tính lại từ bây giờ: các sự kiện trước đó (kể cả chính lần nhấn phím bổ trợ) không tính.
    func trackHID(for seconds: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        if now >= hidUntil {
            lastHIDEvent = nil
            hidEvents = []
        }
        hidUntil = max(hidUntil, now + seconds)
        keep(for: seconds)
    }

    /// Đọc ngay.
    func sample() {
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
        log.sample(at: now, held: held, button: button, flags: flags, keyDownCount: count)
        if now < hidUntil { readHID() }
    }

    /// Thời điểm sự kiện HID cuối (`HIDIdleTime` của IOHIDSystem: không làm tròn, không cần quyền) — chỉ có với bàn phím /
    /// chuột thật, không có với phím do chương trình gõ hay điều khiển từ xa. Sự kiện mới mà không có đổi phím bổ trợ quanh
    /// đó là phím ký tự (hay di chuột): dùng cho phím tắt đổi chế độ (⌘⇧Z không phải ⌘⇧ "trơn").
    private func readHID() {
        guard hid != 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let value = IORegistryEntryCreateCFProperty(hid, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue(), let ns = (value as? NSNumber)?.doubleValue else { return }
        let event = now - ns / 1e9
        defer { if lastHIDEvent.map({ event > $0 }) ?? true { lastHIDEvent = event } }
        // Lần đọc đầu (sau khi bắt đầu theo dõi) chỉ lấy mốc. HIDIdleTime dao động vài ms giữa các lần đọc: chỉ tính khi
        // nhảy hẳn lên.
        guard let last = lastHIDEvent, event > last + 0.012 else { return }
        hidEvents.append(now)
    }

    /// Bộ gõ nhận keyDown.
    func keyReceived(_ event: NSEvent) {
        log.keyReceived(event.keyCode, at: event.timestamp, isRepeat: event.isARepeat)
    }

    /// Lấy ra các lần nhấn đang chờ thoả `condition` (phím bộ gõ không nhận, click).
    func take(where condition: (PressLog.Press) -> Bool) -> [PressLog.Press] {
        log.take(where: condition)
    }

    /// Bỏ các lần nhấn đang chờ đối chiếu (đổi ô nhập liệu, click bộ gõ thấy…).
    func forgetPending() {
        log.forget()
    }

    /// Đang giữ phím đặc biệt hay nút chuột nào không (đọc ngay).
    func anyHeld() -> Bool {
        sample()
        return log.anyHeld
    }

    /// Người dùng có nhấn phím đặc biệt, nút chuột hay nhấn thêm phím bổ trợ (nhả thì không tính) trong [from, to] không —
    /// chỉ biết khi đã đọc liên tục suốt khoảng đó (`covered`).
    func activity(from: Double, to: Double) -> (seen: Bool, covered: Bool) {
        (log.pressed(from: from, to: to) || log.flagsPressed(from: from, to: to), log.covered(since: from))
    }
}
