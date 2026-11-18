import AppKit
import CoreGraphics
import Foundation

enum Hotkey {
    /// Sự kiện đổi phím bổ trợ này là của một phím thuộc tổ hợp `hotkey` (keyCode của ⇧ ⌃ ⌥ ⌘ trái / phải). Phím bổ trợ
    /// khác (kể cả fn, Caps Lock) thì không: lần đổi đó là nhả / nhấn một phím ngoài tổ hợp. keyCode lạ (sự kiện do chương
    /// trình tạo, điều khiển từ xa) thì coi như thuộc tổ hợp, như trước.
    static func changedKeyBelongs(to hotkey: NSEvent.ModifierFlags, keyCode: UInt16) -> Bool {
        let key: NSEvent.ModifierFlags
        switch keyCode {
        case 56, 60: key = .shift
        case 59, 62: key = .control
        case 58, 61: key = .option
        case 55, 54: key = .command
        case 63, 57: return false           // fn / 🌐, Caps Lock
        default: return true
        }
        return hotkey.contains(key)
    }

    /// Lúc nhấn tổ hợp, đang giữ sẵn phím đặc biệt hay nút chuột (vd. ⇧ nhấn sau ⌘ trong lúc giữ ←): không phải nhấn "trơn".
    static var heldAtArm = false

    /// Tổ hợp phím bổ trợ được nhấn từ thời điểm `armed` (systemUptime, lúc bộ gõ nhận) có phải là nhấn-rồi-nhả "trơn"
    /// không: không có phím thường hay cú click chuột nào xen vào (vd. ⌘⇧Z, ⌘⇧4, ⌘⇧←, ⌘⇧+click).
    /// Hỏi trực tiếp hệ thống nên đúng cả với phím tắt mà ứng dụng xử lý trước khi tới bộ gõ:
    /// - phím đặc biệt (mũi tên, Tab, ⏎…) và nút chuột: trạng thái đọc liên tục từ lúc nhấn tổ hợp (`LiveInput`);
    /// - macOS 26: thời điểm sự kiện của WindowServer cho mọi phím, tính từ lúc WindowServer thấy tổ hợp được nhấn — ứng dụng
    ///   giao chậm thì chữ Z của ⌘⇧Z có thể được bấm trước lúc bộ gõ nhận tổ hợp;
    /// - macOS 27 (thời điểm sự kiện chỉ công bố mỗi 0,5 s, làm tròn): phím ký tự trên bàn phím thật qua sự kiện HID không đi
    ///   kèm đổi phím bổ trợ (`PressLog.hotkeyTapClean`).
    static func isCleanTap(since armed: TimeInterval) -> Bool {
        let live = LiveInput.shared
        defer { live.endHID() }
        switch KeyWatch.shared.counterMode {
        case .exact:
            let start = Settings.shared.hotkey.flags.flatMap { live.hotkeyPressedAt($0, armedAt: armed) } ?? armed
            live.sample()
            let now = ProcessInfo.processInfo.systemUptime
            if heldAtArm || live.log.pressed(from: start, to: now) { return false }
            let held = now - start
            let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            return types.allSatisfy {
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) >= held
            }
        case .coarse:
            let lastKeyAt = KeyWatch.shared.lastKeyAt
            let held = heldAtArm
            return live.sampled { log in !held && log.hotkeyTapClean(armedAt: armed, lastKeyAt: lastKeyAt) }
        }
    }
}
