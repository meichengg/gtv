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
        guard !text.isEmpty else {
            // Chuỗi rỗng: chỉ cần gỡ marked text (nếu có). Không gửi insertText rỗng: AWTView của Java đọc ký tự đầu tiên
            // của chuỗi (`characterAtIndex:0`) và văng lỗi.
            if hasMarkedText() { setMarkedText("") }
            return
        }
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
    func caretUndisturbed() -> Bool { KeyWatch.shared.caretUndisturbed() }

    /// Ô Java (AWT): trả lời "đã xử lý" không làm Java bỏ phím; marked text rỗng thì có (AWTView: fKeyEventsNeeded = NO) —
    /// nhưng sau đó Java coi như đang có phần gõ dở rỗng và đưa các phím ⌫ giả vào đó thay vì xoá chữ (IME Lab 42187016328:
    /// "Vieêệt"). Nên không giữ phím: phím đi thẳng, phím giả xoá luôn ký tự của nó.
    var swallowsWithEmptyMark = false

    func postKeys(deleting: Int, inserting: String) -> Bool {
        SyntheticKeys.shared.post(deleting: deleting, inserting: inserting)
    }
    func postKeys(prefix: String, deleting: Int, inserting: String) -> Bool {
        SyntheticKeys.shared.post(prefix: prefix, deleting: deleting, inserting: inserting)
    }
    var keysQueued: Bool {
        let watch = KeyWatch.shared
        return LiveInput.shared.userKeysPending(since: watch.lastKeyAt) || watch.clickUnconfirmed() || watch.clickSinceLastKey()
    }
    var keySwallowable: Bool { false }
    func swallowKey() {
        if swallowsWithEmptyMark {
            client?.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: notFound)
        }
    }
    var canPostKeys: Bool { SyntheticKeys.shared.available }
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
    /// Ô đang gắn là ô văn bản hay view terminal (hỏi một lần lúc gắn); nil: chưa biết (ô tạm), hỏi lại ở phím kế tiếp.
    private var clientKind: ClientKind? {
        didSet { if clientKind == nil { chromiumWeb = false } }
    }
    /// Ô web của Chromium (Chrome, Electron): gõ theo `Session.handleWeb` (bộ gõ tự giữ vị trí từ đang gõ, không bỏ dấu khi
    /// trang chậm).
    private var chromiumWeb = false
    /// RenderWidgetHostViewCocoa (render_widget_host_view_cocoa.mm) khai báo đúng 4 thuộc tính này (AppKit có thể thêm
    /// NSDictationHiliteMarkedText).
    private static let chromiumWebAttributes: Set<String> = [
        "NSUnderline", "NSUnderlineColor", "NSMarkedClauseSegment", "NSTextInputReplacementRangeAttributeName",
    ]
    /// Ô của ứng dụng Java (AWT…): chỉ gõ được bằng marked text, xem `JavaDetector`. nil: chưa biết.
    private var javaView: Bool?
    /// Đã xét lại loại ô theo bộ công cụ của ứng dụng chưa (SwiftTerm bản mới, xem `refineKind`) — một lần cho mỗi lần gắn.
    private var kindRefined = false
    /// Ô Java: chốt từ đang gạch chân sau một lúc không gõ (xem `scheduleJavaCommit`).
    private var javaCommit: DispatchWorkItem?
    /// Phím trước đi đường phím ⌫ giả: mọi phím đặc biệt đều qua bộ gõ (sổ phím không coi phím chưa tới là phím đi vòng).
    private var syntheticRoute = false
    /// Phím trước đi đường LiveInput đọc liên tục lúc gõ (⌫ giả, ô mù): khoảng không đọc là ngắt (xem `KeyWatch.observe`).
    private var readingRoute = false

    // MARK: - Vòng đời

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]).rawValue)
    }

    override func activateServer(_ sender: Any!) {
        session.reset()
        session.fieldChanged()
        hotkeyArmedAt = nil
        clientKind = nil
        kindRefined = false
        javaView = nil
        javaCommit?.cancel()
        guard let client = sender as? Client else { return }
        bundleID = client.bundleIdentifier() ?? ""
        KeyWatch.shared.rebase()
        classify(client)                             // một lần cho mỗi lần gắn
        if clientKind == .textView { javaView = false }
        if clientKind == .terminalView, !Settings.knownTerminals.contains(bundleID) {
            JavaDetector.prefetch(bundleID)          // có kết quả trước phím đầu tiên
        }
        #if DEBUG
        // IME Lab: thuộc tính marked text ô nhập liệu nhận — phân biệt view terminal với ô văn bản thường (NSTextView).
        DebugLog.write("activateServer \(bundleID) kind=\(clientKind.map { "\($0)" } ?? "-")\(chromiumWeb ? " web" : "") attrs=[\(Self.markedTextAttributes(client).joined(separator: ","))] sel=\(client.selectedRange()) len=\(client.length())")
        #else
        DebugLog.write("activateServer \(bundleID)")
        #endif
        Modes.shared.clientActivated(client, bundleID: bundleID)
        _ = AppToolkit.profile(bundleID)   // kiểm tra trước ở luồng nền, có kết quả trước khi cần
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
        case 48: return flags.isEmpty ? "\t" : (flags == [.shift] ? "\u{1b}[Z" : nil)   // Tab, ⇧⇥
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

    /// Loại ô (và ô web Chromium), từ một lần đọc thuộc tính marked text.
    private func classify(_ client: Client) {
        let attrs = Self.markedTextAttributes(client)
        let kind = ClientKind.classify(attrs)
        clientKind = kind == .placeholder ? nil : kind
        chromiumWeb = clientKind != nil
            && Set(attrs).subtracting(["NSDictationHiliteMarkedText"]) == Self.chromiumWebAttributes
    }

    /// Loại ô; nil khi InputMethodKit chưa gắn ô thật (ô tạm).
    private static func kind(of client: Client) -> ClientKind? {
        let kind = ClientKind.classify(markedTextAttributes(client))
        return kind == .placeholder ? nil : kind
    }

    /// View terminal của SwiftTerm từ 04/2026 khai báo đúng [NSUnderline, NSMarkedClauseSegment, NSGlyphInfo] — trông như ô
    /// văn bản nhưng bỏ qua vùng thay và báo con trỏ là chỉ số ô màn hình. Chỉ tin bộ ba này ở ứng dụng có SwiftTerm.
    private func refineKind(_ client: Client, _ toolkit: AppToolkit.Profile) {
        guard !kindRefined, toolkit.swiftTerm, clientKind == .textView else { return }
        kindRefined = true
        let attrs = Set(Self.markedTextAttributes(client)).subtracting(["NSDictationHiliteMarkedText"])
        if attrs == ["NSUnderline", "NSMarkedClauseSegment", "NSGlyphInfo"] {
            clientKind = .terminalView
            javaView = false
        }
    }

    /// Ô của ứng dụng Java (AWT, JavaFX, Compose Desktop): không khai báo thuộc tính marked text nào, trong tiến trình chạy
    /// máy ảo Java. Hỏi một lần cho mỗi ô (ô tạm của InputMethodKit: hỏi lại ở phím sau).
    private func isJavaView(_ client: Client) -> Bool {
        if let javaView { return javaView }
        if clientKind == nil { classify(client) }
        switch clientKind {
        case .terminalView?:
            guard let java = JavaDetector.usesJVM(bundleID, wait: 0.05) else { return false }   // chưa biết: hỏi lại sau
            javaView = java
            return java
        case .textView?:
            javaView = false
            return false
        default:
            return false
        }
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
        javaCommit?.cancel()
        commit(sender)
        LiveInput.shared.endTerminal()      // rời ô: không cần đọc trạng thái phím cho nó nữa (pin)
    }

    /// Ứng dụng (hay InputMethodKit) muốn chốt — không phải lúc mất focus (đó là `deactivateServer`). Gõ trực tiếp thì giữ
    /// từ đang gõ nếu nó vẫn nằm nguyên trước con trỏ, xem `Session.commitRequested`.
    override func commitComposition(_ sender: Any!) {
        DebugLog.write("commitComposition \(bundleID)")
        let saved = adapter.client
        adapter.client = sender as? Client
        session.commitRequested(adapter.client == nil ? nil : adapter)
        adapter.client = saved
    }

    /// macOS báo chế độ Tiếng Việt / Tiếng Anh. InputMethodKit gọi hàm này cả ngay SAU mỗi lần gắn bộ gõ vào ô nhập liệu
    /// (`activateServer`), với chế độ đang chọn — có lúc sau cả phím đầu tiên: gõ ngay khi ô vừa hiện (TinyCast, Spotlight:
    /// ⌘Space rồi gõ liền "d9…"). Chế độ không đổi thì không đụng tới từ đang gõ — chốt từ ở đây làm quên chữ 'd' vừa gõ,
    /// "d9a38ng" thành "d9ẳng".
    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        guard tag == Int(kTextServiceInputModePropertyTag), let mode = value as? String else {
            super.setValue(value, forTag: tag, client: sender)
            return
        }
        let wasVietnamese = Modes.shared.vietnamese
        Modes.shared.modeSelected(mode)
        let changed = Modes.shared.vietnamese != wasVietnamese
        DebugLog.write("setValue \(mode) \(bundleID): \(changed ? "đổi chế độ" : "chế độ không đổi, giữ từ đang gõ")")
        guard changed else { return }
        commit(sender)
        KeyWatch.shared.rebase()             // phím đổi chế độ (🌐, ⌃Space…) không tới bộ gõ
    }

    /// Chốt từ đang gõ với ô `sender`. Giữ lại ô của phím đang xử lý nếu lời gọi lồng vào giữa `handle`.
    private func commit(_ sender: Any?) {
        let saved = adapter.client
        adapter.client = sender as? Client
        session.commit(adapter.client == nil ? nil : adapter)
        adapter.client = saved
    }

    // MARK: - Xử lý phím

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? Client else { return false }
        let settings = Settings.shared
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])

        switch event.type {
        case .flagsChanged:
            KeyWatch.shared.noteModifiers(flags)
            LiveInput.shared.eventReceived(at: event.timestamp)
            // Phím tắt chuyển Anh/Việt: nhấn rồi nhả tổ hợp phím bổ trợ, không kèm phím nào khác.
            if let hotkey = settings.hotkey.flags {
                if flags == hotkey {
                    if hotkeyArmedAt == nil {
                        hotkeyArmedAt = ProcessInfo.processInfo.systemUptime
                        Hotkey.heldAtArm = LiveInput.shared.anyHeld()
                        LiveInput.shared.trackHID(for: 3)        // phím / click lúc đang giữ: xem `Hotkey.isCleanTap`
                    }
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
            switch SyntheticKeys.shared.match(event) {
            case let m? where m.kind == .edit:
                // Phím giả của chính bộ gõ: để ứng dụng xử lý (ghi vào sổ phím cho khớp bộ đếm của hệ thống, trừ phím chữ giả đã
                // báo trước). ⌫ giả tới ứng dụng đúng lúc này: Session cập nhật chữ thật trong ô.
                if !m.unseenAlready {
                    let gap = KeyWatch.shared.observe(event, terminal: Settings.knownTerminals.contains(bundleID),
                                                      throughIME: true, readsContinuously: true, syntheticSince: m.stamp)
                    // Click / phím tắt bộ gõ không thấy, lộ ra lúc phím giả tới (sổ phím đã dùng nó): phím thật kế tiếp không
                    // còn thấy — báo luôn cho Session.
                    if gap == .interrupted || gap == .bypassed { session.inputInterrupted() }
                }
                if event.keyCode == 51 { session.syntheticBackspaceArrived() }
                return false
            case .some:
                break                         // phím thật gửi lại sau phím giả: xử lý như thường
            case nil:
                if SyntheticKeys.shared.inFlight, javaView == true, adapter.keySwallowable {
                    // Phím thật tới trước phím giả của lần sửa trước: giữ lại, gửi lại sau chúng (đúng thứ tự gõ).
                    _ = KeyWatch.shared.observe(event, terminal: false)
                    adapter.client = client
                    adapter.swallowsWithEmptyMark = true
                    adapter.swallowKey()
                    adapter.client = nil
                    SyntheticKeys.shared.repost(event)
                    return true
                }
            }
        default:                             // click chuột: con trỏ có thể đã đổi chỗ
            commit(client)
            session.fieldChanged()
            KeyWatch.shared.rebase()
            return false
        }

        return handleKeyDown(event, client, flags: flags)
    }

    /// Ô Java: chốt từ đang gạch chân khi người dùng ngừng gõ một lúc. AWT nuốt phím không ra chữ (←, ⌘A, ⌘S, Esc…) nếu bộ gõ
    /// chốt từ ngay trong keyDown của chính phím đó (IME Lab: "việt←x" ra "việtx"); chốt sớm thì phím đó tới Java như thường.
    /// Đổi lại, dấu gõ sau khi đã dừng hơn `javaIdleCommit` giây không còn thêm được vào từ trước.
    private static let javaIdleCommit = 1.0

    private func scheduleJavaCommit(_ client: Client) {
        javaCommit?.cancel()
        javaCommit = nil
        guard session.composing else { return }
        let item = DispatchWorkItem { [weak self, weak client] in
            guard let self, let client, self.session.composing else { return }
            DebugLog.write("Java: chốt từ đang gạch chân sau \(Self.javaIdleCommit) s không gõ")
            self.commit(client)
        }
        javaCommit = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.javaIdleCommit, execute: item)
    }

    private func handleKeyDown(_ event: NSEvent, _ client: Client, flags: NSEvent.ModifierFlags) -> Bool {
        let settings = Settings.shared

        // Sổ phím: mọi keyDown bộ gõ nhận đều phải vào sổ, kể cả khi phím đi thẳng ngay dưới đây.
        let gap = KeyWatch.shared.observe(event, terminal: Settings.knownTerminals.contains(bundleID),
                                          throughIME: syntheticRoute, readsContinuously: readingRoute)

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
        let toolkit = AppToolkit.profile(bundleID)
        if clientKind == nil { classify(client) }
        refineKind(client, toolkit)
        var terminal = settings.terminalStyle(for: bundleID)
        var forceMarked = terminal == nil && (settings.useMarked(for: bundleID)
            || (Settings.knownTerminals.contains(bundleID) && settings.terminalMode == "marked"))
        var earlyCommit = forceMarked && Settings.terminalApps.contains(bundleID)
        if Settings.knownTerminals.contains(bundleID) {
            if clientKind == nil { classify(client) }
            if clientKind == .textView || (terminal != nil && Self.inTextField(client, bundleID)) {
                // Ô văn bản trong app terminal (thanh Find, command palette, đổi tên tab…): gõ như ứng dụng thường —
                // DEL của kiểu gõ terminal sẽ thành chữ rác ở đây.
                terminal = nil
                forceMarked = settings.alwaysMarked
                earlyCommit = false
            }
        } else if !forceMarked {
            // Ứng dụng bỏ qua cách thay chữ trực tiếp: Java (AWT), Qt 5, GTK, winit, LibreOffice, Emacs, MacVim, terminal
            // SwiftTerm / xterm.dart — gõ bằng phím ⌫ giả (không gạch chân) nếu có quyền Trợ năng, không thì marked text.
            forceMarked = toolkit.markedOnly || toolkit.flutterTerminal || (toolkit.swiftTerm && clientKind == .terminalView)
                || isJavaView(client)
        }
        // Phím ⌫ giả chỉ ở nơi đã biết mọi phím (thật và ⌫ giả) đi qua bộ gõ: Java (AWT, IME Lab), Qt 5, GTK, winit, LibreOffice.
        // Emacs, MacVim, terminal Flutter / SwiftTerm vẫn gõ bằng gạch chân (⌫ có thể không qua bộ gõ). Lựa chọn gạch chân của
        // người dùng (từng ứng dụng, mọi ứng dụng, terminal) thì giữ nguyên. Chưa có quyền Trợ năng: gạch chân như trước (xin quyền
        // trong menu — không bật hộp thoại của hệ thống giữa lúc đang gõ).
        let syntheticToolkit = javaView == true
            || (toolkit.markedOnly && !AppToolkit.isMarkedEditor(bundleID) && !toolkit.flutterTerminal)
        var synthetic = false
        if forceMarked, syntheticToolkit, !settings.alwaysMarked, !settings.useMarked(for: bundleID), terminal == nil,
           !Settings.knownTerminals.contains(bundleID), SyntheticKeys.shared.available {
            synthetic = true
            forceMarked = false
        }
        if synthetic || (session.blindLatched && SyntheticKeys.shared.available && terminal == nil) {
            // Đọc liên tục nút chuột / phím đặc biệt trong lúc gõ (như terminal): click giữa từ mà bộ gõ không thấy thì phím ⌫
            // giả của lần sửa sau sẽ xoá ở chỗ mới — macOS 27 chỉ công bố bộ đếm click mỗi 0,5 s; phím đặc biệt đã bấm mà chưa
            // tới bộ gõ thì hoãn phím sửa (`keysQueued`). Đọc lâu hơn terminal: phím đầu tiên sau lúc thôi đọc có khoảng không đọc
            // (ứng dụng giao chậm thì lần sửa của nó phải hoãn tới phím sau).
            LiveInput.shared.keepTerminal(for: 15)
        }
        adapter.swallowsWithEmptyMark = javaView == true
        if clientKind == nil { classify(client) }
        // Chữ phím này ra (⌥+chữ, dấu câu…) — chốt cùng từ đang gạch chân ở ô chỉ giữ một lần chèn mỗi phím (GTK, winit).
        let keyText = flags.isDisjoint(with: [.command, .control]) ? event.characters.flatMap { s in
            s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f && !(0xF700...0xF8FF).contains($0.value) } ? s : nil
        } : nil
        let repeatDelay = Settings.repeatBypassTerminals.contains(bundleID) ? settings.keyRepeatDelay : nil
        let handled = session.handle(key, adapter, options: settings.options, forceMarked: forceMarked,
                                     qtApp: toolkit.qt, terminal: terminal, repeatDelay: repeatDelay,
                                     earlyCommit: earlyCommit, gap: gap, legacy: Self.legacyBytes(event, flags),
                                     combinedCommit: toolkit.combinedCommit,
                                     clearAfterCommit: toolkit.clearAfterCommit, trustMarked: toolkit.trustMarked,
                                     keyText: keyText, web: chromiumWeb && !toolkit.gecko && !forceMarked && terminal == nil,
                                     synthetic: synthetic)
        if javaView == true, !synthetic { scheduleJavaCommit(client) }
        // Đường phím giả và ô web Chromium: mọi phím đặc biệt (⌫, mũi tên, ⏎) đều qua bộ gõ.
        readingRoute = synthetic || (session.blindLatched && SyntheticKeys.shared.available && terminal == nil)
        syntheticRoute = readingRoute || (chromiumWeb && !toolkit.gecko && !forceMarked && terminal == nil)
        if readingRoute { LiveInput.shared.keepTerminal(for: 15) }     // cả phím vừa chuyển sang ô mù
        #if DEBUG
        let route = synthetic ? "phím giả" : (chromiumWeb && !toolkit.gecko && !forceMarked && terminal == nil) ? "web" : terminal != nil ? "terminal"
            : forceMarked ? "gạch chân" : "trực tiếp"
        // Đường phím giả không hỏi ứng dụng (Java trả lời qua luồng sự kiện của nó — hỏi ở mỗi phím làm app chậm, có lúc đứng).
        let where_ = synthetic ? "" : " sel=\(client.selectedRange()) len=\(client.length())"
        DebugLog.write("phím \(event.keyCode) '\(event.characters ?? "")' \(bundleID) [\(route)\(session.blindLatched ? ", ô mù" : "")\(javaView == true ? ", java" : "")]: \(handled ? "bộ gõ xử lý" : "đi thẳng")\(where_)")
        #endif
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
        // Chốt từ đang gõ TRƯỚC khi đổi chế độ / tuỳ chọn (theo kiểu gõ cũ; mục "Thoát GTV" kết thúc tiến trình ngay trong
        // `perform`). Chỉ bỏ trạng thái thì phần đang gạch chân bị phím sau thay mất.
        commit((sender as? [String: Any])?[kIMKCommandClientName] ?? client())
        AppMenu.perform(item, appBundleID: bundleID)
    }
}
