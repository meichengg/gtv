import Cocoa
import InputMethodKit
import VietEngine

typealias Client = IMKTextInput & NSObjectProtocol

private let notFound = NSRange(location: NSNotFound, length: 0)

/// Chuyển IMKTextInput thành TextClient cho Session.
private final class ClientAdapter: TextClient {
    var client: Client?
    /// Ô Java (JDK gốc) có trợ thủ GTV trong máy ảo: vùng cần thay đi trong chính chuỗi gửi (`JavaWire`), vì AWT bỏ qua
    /// `replacementRange`.
    var javaHelper = false
    /// Ô Java trả lời mỗi câu hỏi qua luồng sự kiện của nó (một vòng đi-về). Trong lúc xử lý một phím, vị trí con trỏ chỉ đổi
    /// khi chính bộ gõ gửi chữ: nhớ câu trả lời tới lúc đó.
    var remembersSelection = false {
        didSet { remembered = nil }
    }
    private var remembered: (location: Int, length: Int)??

    func selectedRange() -> (location: Int, length: Int)? {
        if remembersSelection, let remembered { return remembered }
        var result: (location: Int, length: Int)?
        if let r = client?.selectedRange(), r.location != NSNotFound { result = (r.location, r.length) }
        if remembersSelection { remembered = .some(result) }
        return result
    }

    func text(location: Int, length: Int) -> String? {
        client?.attributedSubstring(from: NSRange(location: location, length: length))?.string
    }

    func replaceText(location: Int, length: Int, with text: String) {
        remembered = nil
        if javaHelper {
            client?.insertText(JavaWire.encode(location: location, length: length, text: text), replacementRange: notFound)
            return
        }
        client?.insertText(text, replacementRange: NSRange(location: location, length: length))
    }

    /// Phần chữ đang soạn (marked text) gửi cho ô nhập liệu. Bộ gõ đưa chuỗi thường thì InputMethodKit tự gắn gạch chân mặc
    /// định. Đưa chuỗi có thuộc tính "không gạch chân" (kiểu 0, màu trong suốt) thì macOS KHÔNG chuyển nguyên thuộc tính đó cho
    /// ô: ô vẫn nhận NSUnderline = 2 kèm màu thường (IME Lab 44067817184, ô không khai báo thuộc tính nào) — phần đang soạn đi qua
    /// kiểu tô sáng của TSM chứ không phải thuộc tính của bộ gõ. Bản Debug thử được các cách gắn khác (`labComposing`) để đo ô
    /// thật sự nhận gì.
    private static func composing(_ text: String) -> Any {
        #if DEBUG
        if !text.isEmpty, let recipe = UserDefaults.standard.string(forKey: "labComposing") {
            switch recipe {
            case "zero":
                return NSAttributedString(string: text, attributes: [.underlineStyle: 0, .underlineColor: NSColor.clear,
                                                                     .markedClauseSegment: 0])
            case "none": return NSAttributedString(string: text)
            case "clause": return NSAttributedString(string: text, attributes: [.markedClauseSegment: 0])
            case "color": return NSAttributedString(string: text, attributes: [.underlineStyle: 1, .underlineColor: NSColor.clear])
            default: break
            }
        }
        #endif
        return text
    }

    func setMarkedText(_ text: String) {
        remembered = nil
        client?.setMarkedText(Self.composing(text), selectionRange: NSRange(location: text.utf16.count, length: 0),
                              replacementRange: notFound)
    }

    func insertText(_ text: String) {
        guard !text.isEmpty else {
            // Chuỗi rỗng: chỉ cần gỡ marked text (nếu có). Không gửi insertText rỗng: AWTView của Java đọc ký tự đầu tiên
            // của chuỗi (`characterAtIndex:0`) và văng lỗi.
            if hasMarkedText() { setMarkedText("") }
            return
        }
        remembered = nil
        // Ô Java có trợ thủ: chuỗi một ký tự gửi trần thì AWT bỏ rồi phát lại phím gốc — luôn kèm phần đầu.
        client?.insertText(javaHelper ? JavaWire.encode(location: nil, length: 0, text: text) : text,
                           replacementRange: notFound)
    }

    func replaceViaMarkedText(location: Int, length: Int, with text: String) {
        remembered = nil
        client?.setMarkedText(Self.composing(text), selectionRange: NSRange(location: text.utf16.count, length: 0),
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
    /// Ô của ứng dụng Java chạy JDK gốc (AWT bỏ qua vùng thay chữ): chỉ soạn được bằng marked text, xem `JavaDetector`.
    /// Java chạy JetBrains Runtime nhận vùng thay chữ nên gõ trực tiếp như ô thường (false). nil: chưa biết.
    private var javaView: Bool?
    /// Ô Java chạy JetBrains Runtime: gõ trực tiếp (xem `commitComposition`).
    private var directJava = false
    /// Phím gần nhất gõ trực tiếp qua trợ thủ Java (`JavaHelper`): như `directJava`.
    private var helperRoute = false
    /// Phím gần nhất thật sự gõ trực tiếp ở ô Java (JetBrains Runtime hay trợ thủ) — không phải soạn từng từ, dù ô đó
    /// từng gõ trực tiếp (người dùng vừa bật "Soạn từng từ" cho ứng dụng). Xem `commitComposition`.
    private var directRoute = false
    /// Số lần đổi focus trợ thủ Java báo ở phím trước (xem `javaHelperDirect`).
    private var javaFocus: Int?
    /// Đã xét lại loại ô theo bộ công cụ của ứng dụng chưa (SwiftTerm bản mới, xem `refineKind`) — một lần cho mỗi lần gắn.
    private var kindRefined = false
    /// Ô Java: chốt từ đang gạch chân sau một lúc không gõ (xem `scheduleJavaCommit`).
    private var javaCommit: DispatchWorkItem?
    /// Phím trước đi đường ô web Chromium: mọi phím đặc biệt đều qua bộ gõ (sổ phím không coi phím chưa tới là phím đi vòng).
    private var webRoute = false

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
        directJava = false
        helperRoute = false
        directRoute = false
        javaFocus = nil
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
        DebugLog.event("activateServer \(bundleID) kind=\(clientKind.map { "\($0)" } ?? "-")\(chromiumWeb ? " web" : "")")
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

    /// Ô của ứng dụng Java chạy JDK gốc (AWT, Swing, JavaFX): không khai báo thuộc tính marked text nào, trong tiến trình chạy
    /// máy ảo Java không nhận vùng thay chữ. Hỏi một lần cho mỗi ô (ô tạm của InputMethodKit: hỏi lại ở phím sau).
    private func isJavaView(_ client: Client) -> Bool {
        if let javaView { return javaView }
        if clientKind == nil { classify(client) }
        switch clientKind {
        case .terminalView?:
            guard let runtime = JavaDetector.runtime(bundleID, wait: 0.05) else { return false }   // chưa biết: hỏi lại sau
            javaView = runtime == .stock
            directJava = runtime == .replacing
            return runtime == .stock
        case .textView?:
            javaView = false
            return false
        default:
            return false
        }
    }

    /// Ô Java (JDK gốc): loại ô đang giữ focus theo trợ thủ GTV trong máy ảo (`JavaWire.Focus`); nil: máy ảo không có trợ thủ.
    /// Hỏi vị trí con trỏ trước khi đọc trạng thái: câu trả lời đi qua luồng sự kiện của Java, nên khi nó về thì mọi lần đổi
    /// focus xảy ra trước phím này đã được trợ thủ ghi lại.
    private func javaHelperFocus() -> JavaWire.Focus? {
        guard JavaDetector.helper(bundleID) != nil else {      // không có trợ thủ: khỏi hỏi ô
            javaFocus = nil
            return nil
        }
        adapter.remembersSelection = true
        _ = adapter.selectedRange()
        guard let state = JavaDetector.helper(bundleID) else { return nil }
        if let last = javaFocus, last != state.serial {
            // Con trỏ sang ô khác trong cùng cửa sổ Java (bộ gõ không được gắn lại): từ đang gõ thuộc về ô cũ.
            DebugLog.event("Java: ô giữ focus đổi (\(last) → \(state.serial)) — bắt đầu từ mới")
            javaCommit?.cancel()
            session.reset()
            session.fieldChanged()
        }
        javaFocus = state.serial
        return state.focus
    }

    /// Terminal mà view terminal luôn báo con trỏ ở 0 (`Settings.cursorlessTerminals`): báo vị trí khác 0 là đang gõ trong
    /// một ô văn bản của app (Muxy: thanh Find không làm bộ gõ được gắn lại nên không thấy qua `activateServer`).
    private static func inTextField(_ client: Client, _ bundleID: String) -> Bool {
        guard Settings.cursorlessTerminals.contains(bundleID) else { return false }
        let sel = client.selectedRange()
        return sel.location != NSNotFound && sel.location > 0
    }

    override func deactivateServer(_ sender: Any!) {
        DebugLog.event("deactivateServer \(bundleID)")
        javaCommit?.cancel()
        commit(sender)
        LiveInput.shared.endTerminal()      // rời ô: không cần đọc trạng thái phím cho nó nữa (pin)
    }

    /// Ứng dụng (hay InputMethodKit) muốn chốt — không phải lúc mất focus (đó là `deactivateServer`). Gõ trực tiếp thì giữ
    /// từ đang gõ nếu nó vẫn nằm nguyên trước con trỏ, xem `Session.commitRequested`.
    override func commitComposition(_ sender: Any!) {
        DebugLog.event("commitComposition \(bundleID)")
        // Java: AWTView gọi abandonInput sau MỌI lần chèn chữ, kể cả chữ của phím đi thẳng — trước khi chữ đó vào văn bản. Ô
        // gõ trực tiếp (JetBrains Runtime) không có gì đang soạn: bỏ từ ở đây thì từ không bao giờ đủ dài để thêm dấu (IME Lab
        // 44067817184: mọi phím "đi thẳng"). Mỗi lần sửa vẫn đối chiếu lại với màn hình (`Session.lostTrack`, `replace`).
        if directRoute { return }
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
        DebugLog.event("setValue \(mode) \(bundleID): \(changed ? "đổi chế độ" : "chế độ không đổi, giữ từ đang gõ")")
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
        // Bộ gõ khởi động lại khi ô nhập liệu đang mở (vd. sau khi cập nhật): không có activateServer cho ô đó.
        if bundleID.isEmpty { bundleID = client.bundleIdentifier() ?? "" }
        let settings = Settings.shared
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])

        switch event.type {
        case .flagsChanged:
            KeyWatch.shared.noteModifiers(flags)
            LiveInput.shared.eventReceived(at: event.timestamp)
            // Phím tắt chuyển Anh/Việt: nhấn rồi nhả tổ hợp phím bổ trợ, không kèm phím nào khác.
            if let hotkey = settings.hotkey.flags {
                if flags == hotkey {
                    // Chỉ khi đi LÊN tới tổ hợp (phím vừa đổi là một phím của tổ hợp). Nhả ⌥ của ⌥⌘⇧V cũng về đúng ⌘⇧,
                    // nhưng chữ V đã bấm trước đó: tính từ lúc này thì lần nhả ⌘⇧ sau đó trông như nhấn "trơn" và chế độ
                    // tự đổi. Xét theo chính sự kiện (không nhớ trạng thái): phím nhả ở ứng dụng khác không làm kẹt gì.
                    if hotkeyArmedAt == nil, Hotkey.changedKeyBelongs(to: hotkey, keyCode: event.keyCode) {
                        hotkeyArmedAt = ProcessInfo.processInfo.systemUptime
                        Hotkey.heldAtArm = LiveInput.shared.anyHeld()
                        LiveInput.shared.trackHID(for: 3)        // phím / click lúc đang giữ: xem `Hotkey.isCleanTap`
                    }
                } else if flags.isEmpty {
                    // Phím tắt như ⌘⇧Z được ứng dụng xử lý trước, bộ gõ không thấy phím Z:
                    // hỏi hệ thống xem có phím/click nào xen vào không.
                    if let armed = hotkeyArmedAt, Hotkey.isCleanTap(since: armed) {
                        DebugLog.event("phím tắt đổi Anh/Việt (\(bundleID))")
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
                                          throughIME: webRoute)

        // Chế độ tiếng Anh, hoặc ứng dụng loại trừ: phím đi thẳng.
        guard Modes.shared.vietnamese, !settings.excludedApps.contains(bundleID) else {
            #if DEBUG
            DebugLog.write("phím \(event.keyCode) '\(event.characters ?? "")' \(bundleID): chế độ E, đi thẳng")
            #else
            DebugLog.event("phím \(Self.keyClass(event, flags)) \(bundleID): chế độ E, đi thẳng")
            #endif
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
        adapter.javaHelper = false
        defer {
            adapter.client = nil
            adapter.remembersSelection = false
        }
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
            // Ứng dụng bỏ qua cách thay chữ trực tiếp (Java chạy JDK gốc, Qt 5, GTK, winit, LibreOffice, Emacs, MacVim, terminal
            // SwiftTerm / xterm.dart): soạn từ bằng marked text của InputMethodKit.
            forceMarked = toolkit.markedOnly || toolkit.flutterTerminal || (toolkit.swiftTerm && clientKind == .terminalView)
            if !forceMarked, isJavaView(client) {
                // Java chạy JDK gốc: có trợ thủ GTV trong máy ảo thì thay chữ trực tiếp qua nó, không thì soạn từng từ.
                switch javaHelperFocus() {
                case .direct?:
                    adapter.javaHelper = true
                case JavaWire.Focus.none?:
                    // Ô đang giữ focus không nhận chữ (bảng, cây, nút, ô chỉ đọc): phím là lệnh của ứng dụng. Soạn từ ở đó chỉ
                    // làm AWT nuốt phím và hiện cửa sổ soạn nổi.
                    session.reset()
                    helperRoute = false
                    DebugLog.event("phím \(Self.keyClass(event, flags)) \(bundleID) [Java: ô không nhận chữ]: đi thẳng")
                    return false
                default:
                    forceMarked = true
                }
            }
        }
        helperRoute = adapter.javaHelper
        directRoute = helperRoute || (directJava && !forceMarked && terminal == nil)
        session.cursorReliable = directRoute
        if clientKind == nil { classify(client) }
        // Chữ phím này ra (⌥+chữ, dấu câu…) — chốt cùng từ đang gạch chân ở ô chỉ giữ một lần chèn mỗi phím (GTK, winit).
        let keyText = flags.isDisjoint(with: [.command, .control]) ? event.characters.flatMap { s in
            s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f && !(0xF700...0xF8FF).contains($0.value) } ? s : nil
        } : nil
        let repeatDelay = Settings.repeatBypassTerminals.contains(bundleID) ? settings.keyRepeatDelay : nil
        let web = chromiumWeb && !toolkit.gecko && !forceMarked && terminal == nil
        let handled = session.handle(key, adapter, options: settings.options, forceMarked: forceMarked,
                                     qtApp: toolkit.qt, terminal: terminal, repeatDelay: repeatDelay,
                                     earlyCommit: earlyCommit, gap: gap, legacy: Self.legacyBytes(event, flags),
                                     combinedCommit: toolkit.combinedCommit,
                                     clearAfterCommit: toolkit.clearAfterCommit, trustMarked: toolkit.trustMarked,
                                     keyText: keyText, web: web)
        if javaView == true, !helperRoute { scheduleJavaCommit(client) }
        // Ô web Chromium: mọi phím đặc biệt (⌫, mũi tên, ⏎) đều qua bộ gõ.
        webRoute = web
        let route = web ? "web" : terminal != nil ? "terminal" : forceMarked ? "soạn (marked)"
            : helperRoute ? "trực tiếp (trợ thủ Java)" : "trực tiếp"
        #if DEBUG
        // Ô Java trả lời qua luồng sự kiện của nó — hỏi ở mỗi phím làm app chậm: không hỏi.
        let where_ = javaView == true ? "" : " sel=\(client.selectedRange()) len=\(client.length())"
        DebugLog.write("phím \(event.keyCode) '\(event.characters ?? "")' \(bundleID) [\(route)\(session.blindLatched ? ", ô mù" : "")\(javaView == true ? ", java" : "")]: \(handled ? "bộ gõ xử lý" : "đi thẳng")\(where_)")
        #else
        DebugLog.event("phím \(Self.keyClass(event, flags)) \(bundleID) [\(route)\(session.blindLatched ? ", ô mù" : "")\(javaView == true ? ", java" : "")]: \(handled ? "bộ gõ xử lý" : "đi thẳng")")
        #endif
        return handled
    }

    /// Loại phím cho nhật ký sự kiện — không bao giờ ghi chính ký tự người dùng gõ.
    private static func keyClass(_ event: NSEvent, _ flags: NSEvent.ModifierFlags) -> String {
        if !flags.isDisjoint(with: [.command, .control, .option]) { return "phím tắt" }
        if event.keyCode == 51 { return "⌫" }
        guard let ch = event.characters?.unicodeScalars.first, event.characters?.unicodeScalars.count == 1 else { return "khác" }
        if ch == " " { return "cách" }
        if CharacterSet.letters.contains(ch) { return "chữ" }
        if CharacterSet.decimalDigits.contains(ch) { return "số" }
        if ch.value < 0x20 || ch.value == 0x7f || (0xF700...0xF8FF).contains(ch.value) { return "khác" }
        return "dấu"
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
