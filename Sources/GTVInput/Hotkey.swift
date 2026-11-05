import CoreGraphics
import Foundation

enum Hotkey {
    /// Tổ hợp phím bổ trợ được nhấn từ thời điểm `armed` (systemUptime) có phải là nhấn-rồi-nhả "trơn"
    /// không: không có phím thường hay cú click chuột nào xen vào (vd. ⌘⇧Z, ⌘⇧4, ⌘⇧←, ⌘⇧+click).
    /// Hỏi trực tiếp hệ thống nên đúng cả với phím tắt mà ứng dụng xử lý trước khi tới bộ gõ:
    /// - phím đặc biệt (mũi tên, Tab, ⏎…) và nút chuột: trạng thái đọc liên tục từ lúc nhấn tổ hợp (`LiveInput`);
    /// - phím ký tự trên bàn phím thật: sự kiện HID không đi kèm đổi phím bổ trợ (`LiveInput.lastForeignHID`);
    /// - macOS 26: thêm thời điểm sự kiện của WindowServer (macOS 27 chỉ công bố mỗi 0,5 s, làm tròn: không dùng được).
    static func isCleanTap(since armed: TimeInterval) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let live = LiveInput.shared
        live.sample()
        if live.log.pressed(from: armed, to: now) { return false }
        if let foreign = live.lastForeignHID, foreign >= armed { return false }
        guard KeyWatch.shared.counterMode == .exact else { return true }
        let held = now - armed
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types.allSatisfy {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) >= held
        }
    }
}
