import CoreGraphics
import Foundation

enum Hotkey {
    /// Lúc nhấn tổ hợp, đang giữ sẵn phím đặc biệt hay nút chuột (vd. ⇧ nhấn sau ⌘ trong lúc giữ ←): không phải nhấn "trơn".
    static var heldAtArm = false

    /// Tổ hợp phím bổ trợ được nhấn từ thời điểm `armed` (systemUptime) có phải là nhấn-rồi-nhả "trơn"
    /// không: không có phím thường hay cú click chuột nào xen vào (vd. ⌘⇧Z, ⌘⇧4, ⌘⇧←, ⌘⇧+click).
    /// Hỏi trực tiếp hệ thống nên đúng cả với phím tắt mà ứng dụng xử lý trước khi tới bộ gõ:
    /// - phím đặc biệt (mũi tên, Tab, ⏎…) và nút chuột: trạng thái đọc liên tục từ lúc nhấn tổ hợp (`LiveInput`);
    /// - macOS 26: thời điểm sự kiện của WindowServer cho mọi phím;
    /// - macOS 27 (thời điểm sự kiện chỉ công bố mỗi 0,5 s, làm tròn): phím ký tự trên bàn phím thật qua sự kiện HID không đi
    ///   kèm đổi phím bổ trợ (`LiveInput.hidEvents`) — một sự kiện lẻ ngay sau khi gõ chữ có thể chỉ là lần nhả phím chữ đó.
    static func isCleanTap(since armed: TimeInterval) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let live = LiveInput.shared
        live.sample()
        if heldAtArm || live.log.pressed(from: armed, to: now) { return false }
        switch KeyWatch.shared.counterMode {
        case .exact:
            let held = now - armed
            let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            return types.allSatisfy {
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) >= held
            }
        case .coarse:
            // Nhấn / nhả phím bổ trợ cũng là sự kiện HID: bỏ các sự kiện trùng (±25 ms, hai chiều — sự kiện HID và trạng thái
            // phím bổ trợ có thể tới lệch nhau qua một lần đọc) với lần đổi phím bổ trợ hay chính lúc nhấn tổ hợp.
            let flagTimes = live.log.flagChanges + [armed]
            let foreign = live.hidEvents.filter { event in
                event >= armed && !flagTimes.contains { abs($0 - event) <= 0.025 }
            }.count
            let typedJustBefore = KeyWatch.shared.lastKeyAt > armed - 0.35
            return foreign == 0 || (foreign == 1 && typedJustBefore)
        }
    }
}
