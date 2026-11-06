import AppKit
import Carbon

/// Phím ⌫ giả + chữ gõ giả (CGEventPost) cho các ô không thay được chữ qua bộ gõ (Java, Qt 5, GTK, winit, LibreOffice…): ứng
/// dụng xử lý chúng như người dùng tự gõ — không gạch chân, không cần biết vị trí con trỏ. Không event tap (xem
/// no-event-tap-in-gtv): chỉ gửi phím, cần quyền Trợ năng (CGPreflightPostEventAccess).
///
/// Phím giả cũng đi qua bộ gõ (ứng dụng chuyển mọi keyDown cho InputMethodKit). InputMethodKit dựng lại NSEvent trong tiến
/// trình bộ gõ chỉ với mã phím, chữ và phím bổ trợ — mất mọi đánh dấu riêng (eventSourceUserData) — nên bộ gõ nhận ra phím của
/// mình theo hàng đợi đúng thứ tự đã gửi (mã phím + chữ). Phím thật của người dùng tới khi phím giả chưa tới hết: ô giữ được
/// phím (Java) thì bộ gõ giữ lại và gửi lại sau phím giả, để đúng thứ tự gõ.
final class SyntheticKeys {
    static let shared = SyntheticKeys()

    enum Kind {
        /// Phím giả của một lần sửa: để ứng dụng tự xử lý.
        case edit
        /// Phím thật của người dùng gửi lại sau phím giả: bộ gõ xử lý như phím gõ bình thường.
        case user
    }

    private struct Expected {
        let keyCode: UInt16
        let characters: String
        let kind: Kind
    }

    private let source = CGEventSource(stateID: .privateState)
    private var expected: [Expected] = []
    private var postedAt: TimeInterval = 0
    /// Phím giả chưa tới sau chừng này giây thì coi như không tới (ứng dụng đổi ô, bỏ phím…).
    private static let timeout = 0.6
    /// Mã phím mang chữ gõ giả: phím A (Java: KEY_PRESSED VK_A + KEY_TYPED đúng chữ; không phải phím chết, Enter, Tab…).
    private static let textKey: CGKeyCode = 0
    /// Chữ trong một sự kiện phím: hệ thống giữ tối đa ~20 đơn vị UTF-16.
    private static let chunk = 16

    private var permissionCache: (value: Bool, at: TimeInterval)?

    /// Có quyền gửi phím không (hỏi lại hệ thống tối đa mỗi giây: người dùng có thể vừa cấp / gỡ quyền).
    var available: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let c = permissionCache, now - c.at < 1 { return c.value }
        let v = CGPreflightPostEventAccess()
        permissionCache = (v, now)
        return v
    }

    /// Còn phím giả đã gửi mà chưa tới bộ gõ.
    var inFlight: Bool {
        expireIfStale()
        return !expected.isEmpty
    }

    private func expireIfStale() {
        if !expected.isEmpty, ProcessInfo.processInfo.systemUptime - postedAt > Self.timeout {
            DebugLog.write("phím giả: \(expected.count) phím không tới — bỏ")
            expected.removeAll()
        }
    }

    /// Gửi `deleting` phím ⌫ rồi `inserting` như phím gõ. false nếu không gửi được.
    @discardableResult
    func post(deleting: Int, inserting text: String) -> Bool {
        guard available, deleting > 0 || !text.isEmpty else { return deleting == 0 && text.isEmpty }
        var events: [CGEvent] = []
        for _ in 0..<deleting {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false) else { return false }
            down.flags = []
            up.flags = []
            events += [down, up]
            expected.append(Expected(keyCode: UInt16(kVK_Delete), characters: "\u{7f}", kind: .edit))
        }
        for piece in Self.pieces(text) {
            let units = Array(piece.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: Self.textKey, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: Self.textKey, keyDown: false) else { return false }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            events += [down, up]
            expected.append(Expected(keyCode: UInt16(Self.textKey), characters: piece, kind: .edit))
        }
        postedAt = ProcessInfo.processInfo.systemUptime
        for e in events { e.post(tap: .cghidEventTap) }
        return true
    }

    /// Gửi lại phím thật của người dùng (tới khi phím giả chưa tới hết) — sau các phím giả.
    func repost(_ event: NSEvent) {
        guard let chars = event.characters,
              let down = CGEvent(keyboardEventSource: source, virtualKey: event.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: event.keyCode, keyDown: false) else { return }
        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue))
        down.flags = flags
        up.flags = flags
        let units = Array(chars.utf16)
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        expected.append(Expected(keyCode: event.keyCode, characters: chars, kind: .user))
        postedAt = ProcessInfo.processInfo.systemUptime
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Phím vừa tới bộ gõ có phải phím giả kế tiếp trong hàng đợi không (lấy nó ra khỏi hàng đợi nếu đúng).
    func match(_ event: NSEvent) -> Kind? {
        expireIfStale()
        guard let head = expected.first, event.keyCode == head.keyCode, event.characters == head.characters else { return nil }
        expected.removeFirst()
        return head.kind
    }

    private static func pieces(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            if current.utf16.count + ch.utf16.count > chunk {
                out.append(current)
                current = ""
            }
            current.append(ch)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Hỏi quyền Trợ năng (hộp thoại của hệ thống), tối đa một lần cho mỗi lần chạy bộ gõ.
    private var requested = false
    func requestPermissionOnce() {
        guard !requested, !available else { return }
        requested = true
        DebugLog.write("phím giả: chưa có quyền Trợ năng — hỏi người dùng")
        _ = CGRequestPostEventAccess()
    }
}
