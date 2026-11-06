import AppKit
import Carbon

/// Phím ⌫ giả + chữ gõ giả (CGEventPost) cho các ô không thay được chữ qua bộ gõ (Java, Qt 5, GTK, winit, LibreOffice…): ứng
/// dụng xử lý chúng như người dùng tự gõ — không gạch chân, không cần biết vị trí con trỏ. Không event tap (xem
/// no-event-tap-in-gtv): chỉ gửi phím, cần quyền Trợ năng (CGPreflightPostEventAccess).
///
/// Phím ⌫ giả đi qua bộ gõ (ứng dụng chuyển keyDown cho InputMethodKit). InputMethodKit dựng lại NSEvent trong tiến trình bộ gõ
/// chỉ với mã phím, chữ và phím bổ trợ — mất mọi đánh dấu riêng (eventSourceUserData), chữ của ⌫ cũng có thể khác — nên bộ gõ
/// nhận ra ⌫ của mình theo hàng đợi đúng thứ tự đã gửi (mã phím). Phím mang chữ Unicode thì thường KHÔNG qua bộ gõ (IME Lab: ứng
/// dụng nhận thẳng): không chờ nó, báo trước cho sổ phím (`KeyWatch.expectUnseen`). Phím thật của người dùng tới khi ⌫ giả chưa
/// tới hết: ô giữ được phím (Java) thì bộ gõ giữ lại và gửi lại sau phím giả, để đúng thứ tự gõ.
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
        /// nil: không so chữ (⌫ — InputMethodKit có thể báo "\u{8}" hay "\u{7f}").
        let characters: String?
        let kind: Kind
        /// Có thể không tới bộ gõ (phím mang chữ Unicode): phím sau khớp thì bỏ qua nó.
        let optional: Bool
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
        expected.removeAll { $0.optional && $0.kind == .edit && expected.firstIndex(where: { !$0.optional }) == nil }
        return expected.contains { !$0.optional }
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
            expected.append(Expected(keyCode: UInt16(kVK_Delete), characters: nil, kind: .edit, optional: false))
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
            expected.append(Expected(keyCode: UInt16(Self.textKey), characters: piece, kind: .edit, optional: true))
        }
        postedAt = ProcessInfo.processInfo.systemUptime
        KeyWatch.shared.expectUnseen(Self.pieces(text).count)
        DebugLog.write("phím giả: gửi ⌫×\(deleting) + \(text.debugDescription)")
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
        expected.append(Expected(keyCode: event.keyCode, characters: chars, kind: .user, optional: false))
        DebugLog.write("phím giả: gửi lại phím thật \(event.keyCode) sau phím giả")
        postedAt = ProcessInfo.processInfo.systemUptime
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Phím vừa tới bộ gõ có phải phím giả kế tiếp trong hàng đợi không (lấy nó ra khỏi hàng đợi nếu đúng). `unseenAlready`:
    /// phím chữ giả đã được báo trước cho sổ phím (không ghi vào sổ lần nữa).
    func match(_ event: NSEvent) -> (kind: Kind, unseenAlready: Bool)? {
        expireIfStale()
        var i = 0
        while i < expected.count {
            let e = expected[i]
            if event.keyCode == e.keyCode, e.characters == nil || event.characters == e.characters {
                expected.removeFirst(i + 1)          // các phím chữ giả trước nó đã tới ứng dụng mà không qua bộ gõ
                DebugLog.write("phím giả: khớp phím \(event.keyCode)\(e.kind == .user ? " (phím thật gửi lại)" : "")")
                return (e.kind, e.optional)
            }
            guard e.optional else { return nil }
            i += 1
        }
        return nil
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
