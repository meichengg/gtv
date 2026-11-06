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
        /// Lúc gửi (đồng hồ của NSEvent.timestamp).
        let stamp: TimeInterval
    }

    private let source = CGEventSource(stateID: .privateState)
    private var expected: [Expected] = []
    private var postedAt: TimeInterval = 0
    /// Phím giả chưa tới sau chừng này giây (tính từ lần gửi / lần khớp gần nhất) thì coi như không tới (ứng dụng đổi ô, bỏ
    /// phím…). Đủ dài cho ứng dụng khựng (Java GC, Burp đang tải): ⌫ giả tới muộn mà bị coi là ⌫ của người dùng thì sai chữ.
    private static let timeout = 3.0
    /// Mã phím mang chữ gõ giả: phím A (Java: KEY_PRESSED VK_A + KEY_TYPED đúng chữ; không phải phím chết, Enter, Tab…).
    private static let textKey: CGKeyCode = 0
    /// Chữ trong một sự kiện phím: hệ thống giữ tối đa ~20 đơn vị UTF-16.
    private static let chunk = 16

    private var permissionCache: (value: Bool, at: TimeInterval)?

    /// Thời điểm phím InputMethodKit đưa tới là lúc phím vào hàng đợi sự kiện, cùng đồng hồ với `systemUptime` (phím dồn ra
    /// sau lúc ứng dụng treo giữ thời điểm bấm): phím thật cùng mã (⌫) bấm TRƯỚC lúc gửi phím giả — nằm trước chúng trong hàng
    /// đợi của ứng dụng — không phải phím giả. Chỉ dùng sau khi đã thấy vài phím giả tới với thời điểm hợp lý (không trước lúc
    /// gửi, không quá xa); thấy thời điểm vô lý thì thôi hẳn — khi đó chỉ khớp theo thứ tự như trước.
    private var stampAgreements = 0
    private var stampsBroken = false
    private static let stampSlack = 0.002
    private var stampsUsable: Bool { !stampsBroken && stampAgreements >= 3 }

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
        // Chỉ còn phím chữ giả (có thể không bao giờ qua bộ gõ): không còn gì để chờ.
        if !expected.contains(where: { !$0.optional }) { expected.removeAll() }
        return !expected.isEmpty
    }

    private func expireIfStale() {
        // Thời điểm phím dùng được: phím mất được nhận ra trong `match` (phím bấm sau lúc gửi tới trước nó); chỉ giữ hạn rất
        // dài phòng hờ — ứng dụng treo vài giây thì phím giả vẫn tới đúng thứ tự, không được coi là phím của người dùng.
        let limit = stampsUsable ? 30 : Self.timeout
        if !expected.isEmpty, ProcessInfo.processInfo.systemUptime - postedAt > limit {
            DebugLog.write("phím giả: \(expected.count) phím không tới — bỏ")
            expected.removeAll()
        }
    }

    /// Gửi `deleting` phím ⌫ rồi `inserting` như phím gõ. false nếu không gửi được.
    @discardableResult
    func post(deleting: Int, inserting text: String) -> Bool { post(prefix: "", deleting: deleting, inserting: text) }

    /// Gửi chữ `prefix`, rồi `deleting` phím ⌫, rồi `inserting`.
    @discardableResult
    func post(prefix: String, deleting: Int, inserting text: String) -> Bool {
        let nothing = deleting == 0 && text.isEmpty && prefix.isEmpty
        guard available, !nothing else { return nothing }
        let stamp = ProcessInfo.processInfo.systemUptime       // trước khi tạo phím: thời điểm của chúng không sớm hơn
        var events: [CGEvent] = []
        guard textEvents(prefix, stamp: stamp, into: &events) else { return false }
        for _ in 0..<deleting {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false) else { return false }
            down.flags = []
            up.flags = []
            events += [down, up]
            expected.append(Expected(keyCode: UInt16(kVK_Delete), characters: nil, kind: .edit, optional: false, stamp: stamp))
        }
        guard textEvents(text, stamp: stamp, into: &events) else { return false }
        postedAt = ProcessInfo.processInfo.systemUptime
        KeyWatch.shared.expectUnseen(Self.pieces(prefix).count + Self.pieces(text).count)
        DebugLog.write("phím giả: gửi \(prefix.isEmpty ? "" : "\(prefix.debugDescription) + ")⌫×\(deleting) + \(text.debugDescription)")
        for e in events { e.post(tap: .cghidEventTap) }
        return true
    }

    /// Phím mang chữ Unicode (không qua bộ gõ — chỉ chờ phòng hờ).
    private func textEvents(_ text: String, stamp: TimeInterval, into events: inout [CGEvent]) -> Bool {
        for piece in Self.pieces(text) {
            let units = Array(piece.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: Self.textKey, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: Self.textKey, keyDown: false) else { return false }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            events += [down, up]
            expected.append(Expected(keyCode: UInt16(Self.textKey), characters: piece, kind: .edit, optional: true,
                                     stamp: stamp))
        }
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
        expected.append(Expected(keyCode: event.keyCode, characters: chars, kind: .user, optional: false,
                                 stamp: ProcessInfo.processInfo.systemUptime))
        DebugLog.write("phím giả: gửi lại phím thật \(event.keyCode) sau phím giả")
        postedAt = ProcessInfo.processInfo.systemUptime
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Phím vừa tới bộ gõ có phải phím giả kế tiếp trong hàng đợi không (lấy nó ra khỏi hàng đợi nếu đúng). `unseenAlready`:
    /// phím chữ giả đã được báo trước cho sổ phím (không ghi vào sổ lần nữa).
    func match(_ event: NSEvent) -> (kind: Kind, unseenAlready: Bool)? {
        expireIfStale()
        if stampsUsable, let head = expected.first(where: { !$0.optional }),
           event.keyCode != head.keyCode || (head.characters != nil && event.characters != head.characters),
           event.timestamp > head.stamp + 1 {
            // Phím bấm sau lúc gửi hơn 1 s mà tới trước phím giả: phím giả đã mất (ứng dụng đổi ô, bỏ phím…).
            DebugLog.write("phím giả: \(expected.count) phím không tới (phím bấm sau đó đã tới) — bỏ")
            expected.removeAll { $0.stamp < event.timestamp - 1 }
        }
        var i = 0
        while i < expected.count {
            let e = expected[i]
            if event.keyCode == e.keyCode, e.characters == nil || event.characters == e.characters {
                let dt = event.timestamp - e.stamp
                if stampsUsable, dt < -Self.stampSlack {
                    // Phím thật đã nằm trong hàng đợi trước các phím giả (gõ nhanh, ứng dụng chậm): để bộ gõ xử lý như phím gõ.
                    DebugLog.write("phím giả: phím \(event.keyCode) bấm trước lúc gửi phím giả \(String(format: "%.1f", -dt * 1000)) ms — phím thật")
                    return nil
                }
                if event.timestamp <= 0 || dt > 10 || dt < -1 {
                    if !stampsBroken { DebugLog.write("phím giả: thời điểm phím không dùng được (Δ \(dt) s)") }
                    stampsBroken = true
                } else if dt >= -Self.stampSlack, dt < 2 {
                    stampAgreements += 1
                }
                expected.removeFirst(i + 1)          // các phím chữ giả trước nó đã tới ứng dụng mà không qua bộ gõ
                postedAt = ProcessInfo.processInfo.systemUptime
                DebugLog.write("phím giả: khớp phím \(event.keyCode)\(e.kind == .user ? " (phím thật gửi lại)" : "") Δ \(String(format: "%+.1f", dt * 1000)) ms")
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
