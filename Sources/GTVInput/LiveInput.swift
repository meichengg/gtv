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

    /// Return, Enter, Tab, Delete, ⌦, Esc, ←, →, ↓, ↑, Home, End, PgUp, PgDn.
    static let watchedKeys: [CGKeyCode] = [36, 76, 48, 51, 117, 53, 123, 124, 125, 126, 115, 119, 116, 121]
    static let interval = 0.008

    private(set) var log = PressLog()
    private var until = 0.0
    private var timer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    private let hid: io_service_t = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    /// Sự kiện HID gần nhất (bàn phím / chuột thật) không đi kèm đổi phím bổ trợ, lúc đọc thấy.
    private(set) var lastForeignHID: Double?
    private var lastHIDEvent: Double?
    private var flagsChangedAt: Double?

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
        let flagsBefore = log.flagChanges.last
        log.sample(at: now, held: held, button: button, flags: flags)
        if log.flagChanges.last != flagsBefore { flagsChangedAt = now }
        trackHID(now)
    }

    /// Thời điểm sự kiện HID cuối (`HIDIdleTime` của IOHIDSystem: không làm tròn, không cần quyền) — chỉ có với bàn phím /
    /// chuột thật, không có với phím do chương trình gõ hay điều khiển từ xa. Sự kiện mới mà không có đổi phím bổ trợ quanh
    /// đó là phím ký tự (hay di chuột): dùng cho phím tắt đổi chế độ (⌘⇧Z không phải ⌘⇧ "trơn").
    private func trackHID(_ now: Double) {
        guard hid != 0, let value = IORegistryEntryCreateCFProperty(hid, "HIDIdleTime" as CFString,
                                                                     kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let ns = (value as? NSNumber)?.doubleValue else { return }
        let event = now - ns / 1e9
        defer { if lastHIDEvent.map({ event > $0 }) ?? true { lastHIDEvent = event } }
        guard let last = lastHIDEvent, event > last + 0.012 else { return }
        // Đổi phím bổ trợ (nhấn / nhả ⌘ ⇧…) cũng là sự kiện HID.
        if let changed = flagsChangedAt, abs(changed - now) <= 0.02 { return }
        lastForeignHID = now
    }

    /// Bộ gõ nhận keyDown.
    func keyReceived(_ event: NSEvent) {
        log.keyReceived(event.keyCode, at: event.timestamp, isRepeat: event.isARepeat)
    }

    /// Phím đặc biệt bộ gõ không nhận và click, trước phím vừa tới lúc `time` (lấy ra).
    func takeMissed(before time: Double) -> [PressLog.Press] {
        log.takeMissed(before: time)
    }

    /// Bỏ các lần nhấn đang chờ đối chiếu (đổi ô nhập liệu, click bộ gõ thấy…).
    func forgetPending() {
        _ = log.takeMissed(before: .infinity)
    }

    /// Người dùng có nhấn phím đặc biệt, nút chuột hay đổi phím bổ trợ trong [from, to] không — chỉ biết khi đã đọc liên tục
    /// suốt khoảng đó (`covered`).
    func activity(from: Double, to: Double) -> (seen: Bool, covered: Bool) {
        (log.pressed(from: from, to: to) || log.flagsChanged(from: from, to: to), log.covered(since: from))
    }
}
