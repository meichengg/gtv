import Cocoa
import InputMethodKit
import VietEngine

typealias Client = IMKTextInput & NSObjectProtocol

private let notFound = NSRange(location: NSNotFound, length: 0)

/// Chuyển IMKTextInput thành TextClient cho Session.
private final class ClientAdapter: TextClient {
    var client: Client?

    func selectedRange() -> (location: Int, length: Int)? {
        guard let r = client?.selectedRange(), r.location != NSNotFound else { return nil }
        return (r.location, r.length)
    }

    func text(location: Int, length: Int) -> String? {
        client?.attributedSubstring(from: NSRange(location: location, length: length))?.string
    }

    func replaceText(location: Int, length: Int, with text: String) {
        client?.insertText(text, replacementRange: NSRange(location: location, length: length))
    }

    func setMarkedText(_ text: String) {
        client?.setMarkedText(text, selectionRange: NSRange(location: text.utf16.count, length: 0),
                              replacementRange: notFound)
    }

    func insertText(_ text: String) {
        client?.insertText(text, replacementRange: notFound)
    }

    func replaceViaMarkedText(location: Int, length: Int, with text: String) {
        client?.setMarkedText(text, selectionRange: NSRange(location: text.utf16.count, length: 0),
                              replacementRange: NSRange(location: location, length: length))
        client?.insertText(text, replacementRange: notFound)
    }

    /// Chạy `work` sau `delay` giây với chính ô nhập liệu hiện tại. Timer "strict": không bị hệ thống gộp với
    /// timer khác cho đỡ tốn pin (lần sửa chữ trong Ghostty hẹn vài mili giây, trễ hơn là thấy chữ chậm).
    func schedule(after delay: Double, _ work: @escaping () -> Void) {
        let target = client
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + delay, leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in
            timer.cancel()          // timer giữ chính nó tới lúc này
            guard let self, let target else { return }
            let saved = self.client
            self.client = target
            work()
            self.client = saved
        }
        timer.resume()
    }

    func hasMarkedText() -> Bool {
        guard let r = client?.markedRange() else { return false }
        return r.location != NSNotFound && r.length > 0
    }

    func currentTime() -> Double { ProcessInfo.processInfo.systemUptime }

    func lateEditSafe() -> Bool { KeyWatch.shared.lateEditSafe() }
}

/// Một controller cho mỗi ô nhập liệu.
///
/// Cách hoạt động (chế độ mặc định — không gạch chân), chi tiết trong `Session`:
/// - Phím không cần biến đổi được trả lại cho ứng dụng xử lý như bình thường.
/// - Khi cần thêm dấu, bộ gõ thay đúng đoạn chữ trước con trỏ bằng
///   `insertText(_:replacementRange:)` thay vì gửi phím Backspace giả, nên vùng gợi ý tự động
///   đang bôi đen (thanh địa chỉ, ô tìm kiếm) cũng bị thay luôn — không còn lỗi "dđ", "oô".
/// - Bộ gõ nhớ vị trí bắt đầu của từ; nếu con trỏ không còn ở đúng chỗ (Cmd+A, Cmd+Z, chuột...)
///   thì bỏ từ cũ và đọc lại từ trên màn hình.
///
/// Với các ứng dụng không hỗ trợ (terminal) thì dùng marked text như bộ gõ thông thường.
@objc(GTVInputController)
final class GTVInputController: IMKInputController {
    private let session: Session = {
        let s = Session()
        #if DEBUG
        s.log = { DebugLog.write("session: \($0)") }
        #endif
        return s
    }()
    private let adapter = ClientAdapter()
    private var bundleID = ""
    private var hotkeyArmedAt: TimeInterval?
    /// Ô đang gắn là ô văn bản hay view terminal (chỉ hỏi ở app terminal); nil: chưa biết, hỏi lại ở phím kế tiếp.
    private var clientKind: ClientKind?

    // MARK: - Vòng đời

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]).rawValue)
    }

    override func activateServer(_ sender: Any!) {
        session.reset()
        hotkeyArmedAt = nil
        clientKind = nil
        guard let client = sender as? Client else { return }
        bundleID = client.bundleIdentifier() ?? ""
        KeyWatch.shared.rebase()
        if Settings.knownTerminals.contains(bundleID) { clientKind = Self.kind(of: client) }
        #if DEBUG
        // IME Lab: thuộc tính marked text ô nhập liệu nhận — phân biệt view terminal với ô văn bản thường (NSTextView).
        DebugLog.write("activateServer \(bundleID) kind=\(clientKind.map { "\($0)" } ?? "-") attrs=[\(Self.markedTextAttributes(client).joined(separator: ","))] sel=\(client.selectedRange()) len=\(client.length())")
        #else
        DebugLog.write("activateServer \(bundleID)")
        #endif
        Modes.shared.clientActivated(client, bundleID: bundleID)
        _ = QtDetector.isQt(bundleID)   // kiểm tra trước ở luồng nền, có kết quả trước khi cần
    }

    private static func markedTextAttributes(_ client: Client) -> [String] {
        (client.validAttributesForMarkedText() as? [Any] ?? []).map { "\($0)" }
    }

    /// Byte terminal gửi xuống shell cho phím (kiểu cũ, không giao thức bàn phím kitty), cho các phím Ghostty nuốt khi
    /// đang có marked text: Enter, Tab, ⌫, Esc, ←, Home, End, PgUp, PgDn, ⌦, Ctrl+chữ. nil cho phím khác (Ghostty tự
    /// phát lại ↑ ↓ →) và phím có ⌘/⌥, ⇧ (trừ Esc).
    private static func legacyBytes(_ event: NSEvent, _ flags: NSEvent.ModifierFlags) -> String? {
        guard flags.isDisjoint(with: [.command, .option]) else { return nil }
        switch event.keyCode {
        case 53: return "\u{1b}"                                 // Esc
        case 36, 76: return flags.isEmpty ? "\r" : nil           // Return, Enter
        case 48: return flags.isEmpty ? "\t" : nil               // Tab
        case 51: return flags.isEmpty ? "\u{7f}" : nil           // Delete
        case 123: return flags.isEmpty ? "\u{1b}[D" : nil        // ←
        case 115: return flags.isEmpty ? "\u{1b}[H" : nil        // Home
        case 119: return flags.isEmpty ? "\u{1b}[F" : nil        // End
        case 116: return flags.isEmpty ? "\u{1b}[5~" : nil       // PgUp
        case 121: return flags.isEmpty ? "\u{1b}[6~" : nil       // PgDn
        case 117: return flags.isEmpty ? "\u{1b}[3~" : nil       // ⌦
        default:
            guard flags == [.control], let chars = event.characters, chars.unicodeScalars.count == 1,
                  let c = chars.unicodeScalars.first, c.value < 0x20 else { return nil }
            return chars                                         // Ctrl+chữ: ký tự điều khiển
        }
    }

    /// Loại ô; nil khi InputMethodKit chưa gắn ô thật (ô tạm).
    private static func kind(of client: Client) -> ClientKind? {
        let kind = ClientKind.classify(markedTextAttributes(client))
        return kind == .placeholder ? nil : kind
    }

    /// Terminal mà view terminal luôn báo con trỏ ở 0 (`Settings.cursorlessTerminals`): báo vị trí khác 0 là đang gõ trong
    /// một ô văn bản của app (Muxy: thanh Find không làm bộ gõ được gắn lại nên không thấy qua `activateServer`).
    private static func inTextField(_ client: Client, _ bundleID: String) -> Bool {
        guard Settings.cursorlessTerminals.contains(bundleID) else { return false }
        let sel = client.selectedRange()
        return sel.location != NSNotFound && sel.location > 0
    }

    override func deactivateServer(_ sender: Any!) {
        DebugLog.write("deactivateServer \(bundleID)")
        commit(sender)
    }

    override func commitComposition(_ sender: Any!) {
        commit(sender)
    }

    /// macOS báo đổi chế độ Tiếng Việt / Tiếng Anh.
    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        guard tag == Int(kTextServiceInputModePropertyTag), let mode = value as? String else {
            super.setValue(value, forTag: tag, client: sender)
            return
        }
        commit(sender)
        KeyWatch.shared.rebase()             // phím đổi chế độ (🌐, ⌃Space…) không tới bộ gõ
        Modes.shared.modeSelected(mode)
    }

    private func commit(_ sender: Any?) {
        adapter.client = sender as? Client
        session.commit(adapter.client == nil ? nil : adapter)
        adapter.client = nil
    }

    // MARK: - Xử lý phím

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? Client else { return false }
        let settings = Settings.shared
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])

        switch event.type {
        case .flagsChanged:
            KeyWatch.shared.noteModifiers(flags)
            // Phím tắt chuyển Anh/Việt: nhấn rồi nhả tổ hợp phím bổ trợ, không kèm phím nào khác.
            if let hotkey = settings.hotkey.flags {
                if flags == hotkey {
                    if hotkeyArmedAt == nil { hotkeyArmedAt = ProcessInfo.processInfo.systemUptime }
                } else if flags.isEmpty {
                    // Phím tắt như ⌘⇧Z được ứng dụng xử lý trước, bộ gõ không thấy phím Z:
                    // hỏi hệ thống xem có phím/click nào xen vào không.
                    if let armed = hotkeyArmedAt, Hotkey.isCleanTap(since: armed) {
                        commit(client)
                        // Chọn chế độ ngoài lúc đang xử lý sự kiện phím.
                        DispatchQueue.main.async { Modes.shared.toggle() }
                    }
                    hotkeyArmedAt = nil
                } else if !hotkey.isSuperset(of: flags) {
                    hotkeyArmedAt = nil
                }
            }
            return false
        case .keyDown:
            hotkeyArmedAt = nil
        default:                             // click chuột: con trỏ có thể đã đổi chỗ
            commit(client)
            KeyWatch.shared.rebase()
            return false
        }

        // Sổ phím: mọi keyDown bộ gõ nhận đều phải vào sổ, kể cả khi phím đi thẳng ngay dưới đây.
        let gap = KeyWatch.shared.observe(event)

        // Chế độ tiếng Anh, hoặc ứng dụng loại trừ: phím đi thẳng.
        guard Modes.shared.vietnamese, !settings.excludedApps.contains(bundleID) else {
            DebugLog.write("phím \(event.keyCode) '\(event.characters ?? "")' \(bundleID): chế độ E, đi thẳng")
            commit(client)
            return false
        }

        let key: Key
        if !flags.isDisjoint(with: [.command, .control, .option]) {
            key = .other
        } else if event.keyCode == 51 {      // Delete
            key = .backspace
        } else if flags.contains(.shift), [36, 76, 48].contains(event.keyCode) {
            key = .other                     // ⇧⏎ (xuống dòng trong Claude Code…), ⇧⇥: không phải Enter / Tab thường
        } else if let chars = event.characters, chars.count == 1, let ch = chars.first {
            key = .char(ch)
        } else {
            key = .other
        }

        adapter.client = client
        defer { adapter.client = nil }
        var terminal = settings.terminalStyle(for: bundleID)
        var forceMarked = terminal == nil && (settings.useMarked(for: bundleID)
            || (Settings.knownTerminals.contains(bundleID) && settings.terminalMode == "marked"))
        var earlyCommit = forceMarked && Settings.terminalApps.contains(bundleID)
        if Settings.knownTerminals.contains(bundleID) {
            if clientKind == nil { clientKind = Self.kind(of: client) }
            if clientKind == .textView || (terminal != nil && Self.inTextField(client, bundleID)) {
                // Ô văn bản trong app terminal (thanh Find, command palette, đổi tên tab…): gõ như ứng dụng thường —
                // DEL của kiểu gõ terminal sẽ thành chữ rác ở đây.
                terminal = nil
                forceMarked = settings.alwaysMarked
                earlyCommit = false
            }
        }
        let repeatDelay = Settings.repeatBypassTerminals.contains(bundleID) ? settings.keyRepeatDelay : nil
        let handled = session.handle(key, adapter, options: settings.options, forceMarked: forceMarked,
                                     qtApp: QtDetector.isQt(bundleID), terminal: terminal, repeatDelay: repeatDelay,
                                     earlyCommit: earlyCommit, gap: gap, legacy: Self.legacyBytes(event, flags))
        DebugLog.write("phím \(event.keyCode) '\(event.characters ?? "")' \(bundleID): \(handled ? "bộ gõ xử lý" : "đi thẳng") sel=\(client.selectedRange()) len=\(client.length())")
        return handled
    }

    // MARK: - Menu trong biểu tượng bộ gõ của macOS

    override func menu() -> NSMenu! {
        AppMenu.build(target: self, action: #selector(menuAction(_:)), appBundleID: bundleID, standalone: false)
    }

    @objc func menuAction(_ sender: Any?) {
        let item = (sender as? [String: Any])?[kIMKCommandMenuItemName] as? NSMenuItem
            ?? sender as? NSMenuItem
        guard let item else { return }
        AppMenu.perform(item, appBundleID: bundleID)
        session.reset()
    }
}
