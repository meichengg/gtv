/// Ô nhập liệu mà bộ gõ làm việc cùng (InputMethodKit client, hoặc bản giả trong test).
/// Mọi vị trí tính theo UTF-16.
public protocol TextClient: AnyObject {
    /// nil nếu ứng dụng không cho biết vị trí con trỏ.
    func selectedRange() -> (location: Int, length: Int)?
    /// nil nếu ứng dụng không cho đọc văn bản.
    func text(location: Int, length: Int) -> String?
    func replaceText(location: Int, length: Int, with text: String)
    func setMarkedText(_ text: String)
    func insertText(_ text: String)
    /// Thay một đoạn bằng `text` qua marked text rồi chốt ngay (dùng cho ứng dụng Qt, xem `replace`).
    func replaceViaMarkedText(location: Int, length: Int, with text: String)
    /// Chạy `work` ngay sau khi ứng dụng xử lý xong phím hiện tại (ngoài keyDown), với cùng ô nhập liệu.
    func schedule(_ work: @escaping () -> Void)
}

public extension TextClient {
    func schedule(_ work: @escaping () -> Void) { work() }
}

public enum Key: Equatable {
    case char(Character)
    case backspace
    /// Enter, Tab, mũi tên, tổ hợp Cmd/Ctrl/Option...: kết thúc từ.
    case other
}

/// Cách gõ trong terminal: chữ đã gửi xuống shell không sửa được bằng cách thay văn bản, nên bộ gõ gửi
/// kèm ký tự xoá (DEL, như phím Backspace) để shell tự xoá rồi gõ chữ mới — không gạch chân, phím tới shell ngay.
public enum TerminalStyle: String, CaseIterable, Sendable {
    /// Một lần `insertText`: ký tự vừa gõ + (n+1) DEL + chữ mới. Mở đầu bằng ký tự thường vì Ghostty, kitty
    /// bỏ chuỗi bắt đầu bằng ký tự điều khiển; terminal ghi cả chuỗi xuống shell một lần nên shell vẽ lại
    /// một lần (không nháy).
    case inline
    /// Một lần `insertText`: n DEL + chữ mới (không có ký tự mồi).
    case inlineBare
    /// Cho Ghostty (và terminal dùng lớp AppKit của Ghostty): trong keyDown Ghostty bỏ chữ có ký tự điều khiển
    /// khi shell bật kitty keyboard protocol (fish 4), và không giữ phím nếu bộ gõ không đưa chữ / marked text.
    /// Nên: đặt marked text rỗng (U+200B, không hiện, không gạch chân) để giữ phím, rồi ngay sau khi phím xử lý
    /// xong mới gửi n DEL + chữ mới — đường này Ghostty ghi nguyên văn xuống shell, một lần.
    case deferred
}

/// Nối Engine với một ô nhập liệu: quyết định cho phím đi qua, thay văn bản hay dùng marked text,
/// và phát hiện khi văn bản bị thay đổi bởi thao tác mà bộ gõ không thấy (Cmd+A, Cmd+Z, chuột...).
public final class Session {
    public let engine = Engine()
    private var marked = false   // từ hiện tại dùng marked text (gạch chân)
    /// Chế độ gạch chân: phần đầu của từ đã nằm hẳn trong ô nhập liệu (với terminal: đã gửi xuống shell).
    /// Marked text chỉ là phần còn lại của từ. Xem `showMarked`.
    private var committed = ""
    /// Chế độ gạch chân: marked text đang hiện (phần sau `committed`).
    private var preedit = ""
    /// Chế độ gạch chân: từ đang gõ đã chốt vì không còn thay đổi được nữa; các chữ cái còn lại của từ đi thẳng.
    private var literalTail = false
    /// Terminal kiểu `.deferred`: chuỗi xoá + chữ mới chờ gửi sau keyDown; `pendingSerial` bỏ lần gửi đã cũ.
    private var pending: String?
    private weak var pendingClient: AnyObject?
    private var pendingSerial = 0
    private var anchor = 0       // vị trí bắt đầu của từ đang gõ
    private var qtApp = false    // ô nhập liệu thuộc ứng dụng Qt (xem `replace`)
    /// Vừa xoá lùi khi không có từ nào đang gõ (vd. "hoir " → xoá " " và "r" → còn "hoi"): ở phím chữ tiếp
    /// theo, đọc lại từ trước con trỏ để gõ tiếp (gõ "r" → "hỏi") thay vì bắt đầu từ mới.
    private var continueWordOnNextChar = false

    public init() {}

    public func reset() {
        engine.reset()
        endMarkedWord()
        continueWordOnNextChar = false
    }

    private func endMarkedWord() {
        marked = false
        committed = ""
        preedit = ""
        literalTail = false
    }

    /// Trả về true nếu bộ gõ đã xử lý phím (ứng dụng không cần xử lý nữa).
    /// `qtApp`: ứng dụng viết bằng Qt (Telegram Desktop…), cần cách thay riêng — xem `replace`.
    /// `terminal`: ô nhập liệu là terminal (xem `TerminalStyle`); khi có thì bỏ qua `forceMarked`.
    public func handle(_ key: Key, _ client: TextClient, options: EngineOptions, forceMarked: Bool,
                       qtApp: Bool = false, terminal: TerminalStyle? = nil) -> Bool {
        self.qtApp = qtApp
        if let terminal {
            if marked || literalTail { reset() }     // vừa đổi từ chế độ gạch chân
            return handleTerminal(key, client, options: options, style: terminal)
        }
        if literalTail {
            // Từ đã chốt (xem `showMarked`): chữ cái gõ tiếp đi thẳng, phím khác kết thúc từ.
            switch key {
            case let .char(ch) where ch.isASCII && ch.isLetter:
                return false
            case .char:
                reset()          // như khi từ kết thúc bằng dấu câu: phím đi thẳng
                return false
            case .backspace, .other:
                reset()          // ô nhập liệu tự xử lý (xem bên dưới)
            }
        }
        switch key {
        case .other:
            breakWord(client)
            continueWordOnNextChar = false
            return false
        case .backspace:
            let handled = backspace(client)
            if engine.isEmpty && !marked { continueWordOnNextChar = true }
            return handled
        case let .char(ch):
            if engine.isEmpty {
                engine.options = options
                let sel = client.selectedRange()
                marked = forceMarked || sel == nil
                committed = ""
                preedit = ""
                anchor = sel?.location ?? 0
                if continueWordOnNextChar && !marked { resync(client) }
                continueWordOnNextChar = false
            } else if !marked && !inSync(client.selectedRange()) {
                resync(client)
            }
            let before = engine.displayed
            guard let action = engine.process(ch) else {
                breakWord(client)
                return false
            }
            if marked { return showMarked(ch, action, before: before, client) }
            return perform(action, client, retry: ch)
        }
    }

    /// Chốt từ đang gõ (khi ô nhập liệu mất focus, click chuột...).
    public func commit(_ client: TextClient?) {
        if let client { flushPending(client) }
        if marked, !engine.isEmpty, let client {
            insertMarkedTail(engine.finishWord().text, client)
        }
        reset()
    }

    // MARK: - Chế độ gạch chân

    /// Ô nhập liệu đang hiện `committed` (đã chốt) rồi tới `preedit` (gạch chân). Với terminal, chỉ phần đã
    /// chốt là đã tới shell, phần gạch chân thì chưa. Để shell thấy chữ ngay khi gõ (gợi ý lệnh, tự hoàn
    /// thành), chỉ gạch chân phần còn có thể đổi:
    /// - Phụ âm đầu từ không bao giờ bị sửa lại (xem `isStableInitial`): cho phím đi thẳng như bình thường.
    /// - Khi từ không còn đổi được nữa (không phải tiếng Việt: `ls`, `brew`, `status`…, hoặc vừa huỷ dấu)
    ///   thì chốt ngay; các chữ cái còn lại của từ đi thẳng.
    /// Gạch chân chỉ còn ở phần từ nguyên âm đầu tiên (hoặc `d`, `w`) tới hết từ, khi từ còn có thể là tiếng Việt.
    private func showMarked(_ ch: Character, _ action: Action, before: String, _ client: TextClient) -> Bool {
        let final = engine.isFinal
        if preedit.isEmpty, before == committed, action == .passThrough, final || Self.isStableInitial(ch) {
            committed = engine.displayed
            if final { enterLiteralTail() }
            return false
        }
        // Phần đã chốt chỉ gồm phụ âm đầu, không bao giờ đổi: bỏ qua đúng số ký tự đó.
        let tail = String(engine.displayed.dropFirst(committed.count))
        if final {
            client.insertText(tail)
            enterLiteralTail()
        } else {
            client.setMarkedText(tail)
            preedit = tail
        }
        return true
    }

    private func enterLiteralTail() {
        engine.reset()
        committed = ""
        preedit = ""
        literalTail = true
    }

    /// Chữ cái không bao giờ bị bộ gõ sửa lại khi nằm trong phụ âm đầu: mọi phụ âm, trừ `d` (dd, d9 → đ,
    /// kể cả gõ ở cuối từ) và `w` (Telex: w → ư). Dấu thanh, dấu mũ, dấu móc chỉ đặt lên nguyên âm; khi khôi
    /// phục từ không phải tiếng Việt, phụ âm đầu cũng giữ nguyên vì được gõ đúng như hiện.
    private static func isStableInitial(_ ch: Character) -> Bool {
        guard let a = ch.asciiValue else { return false }
        let lowered = a | 0x20
        guard lowered >= 97, lowered <= 122 else { return false }
        return !"aeiouydw".utf8.contains(lowered)
    }

    /// Chốt phần chưa chốt của từ (`text`: chữ cuối cùng của cả từ).
    private func insertMarkedTail(_ text: String, _ client: TextClient) {
        let tail = String(text.dropFirst(committed.count))
        if !tail.isEmpty || !preedit.isEmpty { client.insertText(tail) }
    }

    // MARK: - Terminal

    /// Terminal: phím nào không làm đổi chữ thì đi thẳng (shell thấy ngay, gợi ý lệnh hiện ngay); khi cần
    /// thêm dấu thì gửi một lần chuỗi xoá + chữ mới (`emit`). Không đọc được dòng lệnh của shell, nên bộ gõ
    /// chỉ dựa vào chính những gì nó đã gửi; mọi thao tác nó không theo dõi được (phím đặc biệt, click) kết
    /// thúc từ, không bao giờ xoá quá phần do nó gõ ra.
    private func handleTerminal(_ key: Key, _ client: TextClient, options: EngineOptions,
                                style: TerminalStyle) -> Bool {
        continueWordOnNextChar = false
        flushPending(client)        // lần sửa trước (kiểu .deferred) luôn tới shell trước phím này
        switch key {
        case .other:
            engine.reset()          // Enter, mũi tên, Ctrl+...: shell tự xử lý, không khôi phục từ sau phím này
            return false
        case .backspace:
            guard !engine.isEmpty else { return false }
            if case .passThrough = engine.backspace() { return false }   // shell xoá 1 ký tự: vẫn khớp
            engine.reset()          // xoá làm dấu phải đặt lại chỗ khác: thôi theo dõi từ, xoá như thường
            return false
        case let .char(ch):
            if engine.isEmpty { engine.options = options }
            guard let action = engine.process(ch) else {
                // Hết từ (dấu cách, dấu câu…): khôi phục từ không phải tiếng Việt trước ký tự này.
                if case let .replace(old, new) = engine.finishWord().action, Self.isPrintable(ch) {
                    emit(old, new, typed: ch, then: String(ch), client, style)
                    return true
                }
                return false
            }
            guard case let .replace(old, new) = action else { return false }
            emit(old, new, typed: ch, then: "", client, style)
            return true
        }
    }

    /// Đổi `old` (đang nằm cuối dòng lệnh) thành `new` + `suffix`: một lần ghi xuống shell.
    private func emit(_ old: String, _ new: String, typed ch: Character, then suffix: String,
                      _ client: TextClient, _ style: TerminalStyle) {
        var oi = old.startIndex, ni = new.startIndex
        while oi < old.endIndex, ni < new.endIndex, old[oi] == new[ni] {
            oi = old.index(after: oi)
            ni = new.index(after: ni)
        }
        // Shell xoá từng code point một (chữ dựng sẵn: mỗi chữ là một code point).
        let deletes = old[oi...].unicodeScalars.count
        let insert = String(new[ni...]) + suffix
        let dels = String(repeating: "\u{7f}", count: deletes)
        switch style {
        case .inline:
            guard deletes > 0 else { client.insertText(insert); return }
            // Ký tự mồi (bị xoá ngay): phím vừa gõ; khi hết từ thì không dùng dấu cách (fish mở abbreviation).
            let lead = suffix.isEmpty ? ch : (insert.first ?? "x")
            client.insertText(String(lead) + "\u{7f}" + dels + insert)
        case .inlineBare:
            let out = dels + insert
            if !out.isEmpty { client.insertText(out) }
        case .deferred:
            pending = dels + insert
            pendingClient = client
            pendingSerial &+= 1
            let serial = pendingSerial
            client.setMarkedText("\u{200B}")     // giữ phím lại (Ghostty), không hiện gì
            client.schedule { [weak self, weak client] in
                guard let self, let client, self.pendingSerial == serial else { return }
                self.flushPending(client)
            }
        }
    }

    /// Gửi lần sửa đang chờ (kiểu `.deferred`) — chỉ tới đúng ô nhập liệu đã gõ ra nó.
    private func flushPending(_ client: TextClient) {
        guard let text = pending, pendingClient === client else { return }
        pending = nil
        pendingClient = nil
        client.insertText(text)
    }

    private static func isPrintable(_ ch: Character) -> Bool {
        guard let a = ch.asciiValue else { return false }
        return a >= 0x20 && a != 0x7f
    }

    // MARK: -

    /// Con trỏ có đang nằm ngay sau từ đang gõ không.
    private func inSync(_ sel: (location: Int, length: Int)?) -> Bool {
        guard let sel else { return false }
        return sel.location == anchor + engine.displayed.utf16.count
    }

    private func backspace(_ client: TextClient) -> Bool {
        guard !engine.isEmpty else { return false }
        if marked {
            _ = engine.backspace()
            if preedit.isEmpty {
                // Chữ trước con trỏ đã chốt (phụ âm đầu): ô nhập liệu tự xoá.
                committed = engine.displayed
                if engine.isEmpty { endMarkedWord() }
                return false
            }
            preedit = String(engine.displayed.dropFirst(committed.count))
            client.setMarkedText(preedit)
            if engine.isEmpty { endMarkedWord() }
            return true
        }
        let sel = client.selectedRange()
        guard let sel, inSync(sel) else {
            engine.reset()          // văn bản đã đổi ngoài tầm bộ gõ (vd. Cmd+A): bỏ từ đang gõ
            return false
        }
        if sel.length > 0 { return false }   // chỉ xoá phần gợi ý tự động đang bôi đen sau từ
        return perform(engine.backspace(), client, retry: nil)
    }

    private func breakWord(_ client: TextClient) {
        guard !engine.isEmpty else { return }
        let (text, action) = engine.finishWord()
        if marked {
            insertMarkedTail(text, client)
        } else if case let .replace(old, new) = action {
            _ = replace(old, new, client)
        }
        endMarkedWord()
    }

    private func perform(_ action: Action, _ client: TextClient, retry ch: Character?) -> Bool {
        guard case let .replace(old, new) = action else { return false }
        if replace(old, new, client, typed: ch) { return true }
        // Không khớp với màn hình: đọc lại từ trước con trỏ rồi xử lý phím này tiếp từ đó.
        resync(client)
        guard let ch else { engine.reset(); return false }
        if let a = engine.process(ch), case let .replace(o, n) = a {
            if replace(o, n, client, typed: ch) { return true }
            engine.reset()
        }
        return false
    }

    /// Bỏ trạng thái hiện tại, nạp lại từ đang nằm ngay trước con trỏ (nếu đọc được).
    private func resync(_ client: TextClient) {
        engine.reset()
        guard let sel = client.selectedRange() else { return }
        anchor = sel.location
        guard sel.location > 0 else { return }
        let len = min(sel.location, 16)
        guard let text = client.text(location: sel.location - len, length: len) else { return }
        let word = String(text.reversed().prefix(while: { $0.isLetter }).reversed())
        // Chỉ nạp khi thấy trọn từ (đứng sau ký tự không phải chữ, hoặc ở đầu văn bản).
        guard !word.isEmpty, word.utf16.count < len || len == sel.location else { return }
        if engine.seed(word) { anchor = sel.location - word.utf16.count }
    }

    /// `typed`: ký tự của phím vừa bấm (nếu việc thay đổi do phím đó gây ra).
    private func replace(_ old: String, _ new: String, _ client: TextClient, typed: Character? = nil) -> Bool {
        let oldLen = old.utf16.count
        guard let sel = client.selectedRange(), sel.location >= oldLen,
              sel.location == anchor + oldLen else { return false }
        if oldLen > 0, let current = client.text(location: sel.location - oldLen, length: oldLen), current != old {
            return false
        }
        // Chỉ thay phần khác nhau để ứng dụng phải làm ít việc nhất.
        var common = 0
        var oi = old.startIndex, ni = new.startIndex
        while oi < old.endIndex, ni < new.endIndex, old[oi] == new[ni] {
            common += old[oi].utf16.count
            oi = old.index(after: oi)
            ni = new.index(after: ni)
        }
        let deleteLen = oldLen - common
        let insert = String(new[ni...])
        let start = sel.location - deleteLen
        // Vùng đang bôi đen sau từ (gợi ý tự động) cũng bị thay luôn.
        let length = deleteLen + sel.length
        if qtApp, let typed, insert == String(typed), length > 0 {
            // Chuỗi thay vào trùng ký tự phím vừa bấm (vd. "ơ" + "[" -> "[", "ư" + "w" -> "w"): ứng dụng Qt
            // (Telegram...) coi đó là nhấn phím thường, bỏ qua vùng cần thay (và bỏ qua cả lệnh thay bằng
            // chuỗi rỗng) -> "ơ[". Đi qua marked text thì Qt xử lý theo đường của bộ gõ.
            // Chỉ dùng cho Qt: ô nhập liệu trong trang web (Chrome, Electron) lại bỏ qua vùng cần thay
            // của marked text, còn cách thay trực tiếp thì đúng.
            client.replaceViaMarkedText(location: start, length: length, with: insert)
        } else {
            client.replaceText(location: start, length: length, with: insert)
        }
        return true
    }
}
