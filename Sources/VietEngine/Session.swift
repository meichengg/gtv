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
    /// Chạy `work` sau `delay` giây (đúng hạn, không bị gộp với timer khác), với cùng ô nhập liệu.
    func schedule(after delay: Double, _ work: @escaping () -> Void)
    /// Ô nhập liệu đang có marked text không.
    func hasMarkedText() -> Bool
    /// Đồng hồ đơn điệu (giây).
    func currentTime() -> Double
    /// Từ phím bộ gõ nhận gần nhất tới giờ không có phím tắt (⌘/⌃/⌥) hay click nào (GTVInput). Lần sửa gửi muộn (kiểu
    /// `.deferred`) chỉ gửi khi đúng như vậy; không thì để phím kế tiếp quyết định.
    func lateEditSafe() -> Bool
}

public extension TextClient {
    func schedule(after delay: Double, _ work: @escaping () -> Void) { work() }
    func hasMarkedText() -> Bool { false }
    func currentTime() -> Double { 0 }
    func lateEditSafe() -> Bool { true }
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
    /// Chế độ gạch chân trong terminal: chốt sớm phần không còn đổi được (xem `handle(earlyCommit:)`).
    private var earlyCommit = false
    /// Số ký tự của từ đã chốt (`literalTail`) còn trên dòng.
    private var literalLength = 0
    /// Terminal kiểu `.deferred`: chuỗi xoá + chữ mới chờ gửi sau keyDown; `pendingSerial` bỏ lần gửi đã cũ.
    /// Chỉ coi là xong khi marked text rỗng đã biến mất (ứng dụng đã nhận chuỗi): xem `settlePending`.
    private var pending: String?
    private weak var pendingClient: AnyObject?
    private var pendingSerial = 0
    /// Lúc bộ gõ ghi xuống shell lần cuối (terminal). Dùng để phân biệt "chữ chưa kịp in lại" với "con trỏ đã
    /// bị phím khác (không qua bộ gõ) dời đi" — xem `guardCursor`.
    private var termLastWrite = 0.0
    /// Lúc bấm Backspace gần nhất (terminal có phím lặp không qua bộ gõ), xem `handle(repeatDelay:)`.
    private var lastBackspaceAt: Double?
    /// Terminal: chữ của từ đang gõ thật sự nằm trên dòng, khi khác `engine.displayed` — phím đã đi nguyên văn vì
    /// chưa chắc có phím nào đi vòng bộ gõ không (`KeyGap.unsure`). nil nếu khớp.
    private var onLine: String?
    /// iTerm2 / Terminal.app, lúc chưa chắc mà màn hình lệch: hoặc chỉ là shell chưa in lại (từ cũ vẫn đúng), hoặc đã có
    /// phím đi vòng ngay trước (vd. ⌫ ở Terminal.app) và từ thật bắt đầu từ phím lúc đó — các ký tự đã gõ (nguyên văn) từ
    /// đó tới giờ. Phím sau quyết định: sổ phím sạch → từ cũ; màn hình (đã in kịp) khớp các ký tự này → từ mới.
    private var restartChars: [Character]?
    /// Chữ vừa gửi có thể chưa kịp hiện (shell chưa in lại): trong khoảng này con trỏ đứng sau là bình thường.
    private static let echoLag = 0.15
    /// Kiểu `.deferred` (Ghostty): gửi lần sửa sau bấy nhiêu giây kể từ lúc trả lời phím, không gửi ngay.
    /// Gửi ngay thì có lúc chuỗi tới Ghostty khi nó vẫn còn trong keyDown của chính phím đó (còn đang chờ trả
    /// lời của bộ gõ): chuỗi bị gom làm chữ của phím, rồi bị bỏ vì mở đầu bằng DEL — IME Lab: mất 4 trên ~90
    /// lần sửa khi gửi ngay, không mất lần nào khi gửi trễ ~1 ms. Phím kế tiếp tới trước hạn thì lần sửa được
    /// gửi ở đầu phím đó (`settlePending`), nên trễ này không làm sai thứ tự.
    public static let defaultDeferDelay = 0.005
    public static var deferDelay = defaultDeferDelay   // IME Lab đổi được (bản Debug)
    private var anchor = 0       // vị trí bắt đầu của từ đang gõ
    private var qtApp = false    // ô nhập liệu thuộc ứng dụng Qt (xem `replace`)
    /// Vừa xoá lùi khi không có từ nào đang gõ (vd. "hoir " → xoá " " và "r" → còn "hoi"): ở phím chữ tiếp
    /// theo, đọc lại từ trước con trỏ để gõ tiếp (gõ "r" → "hỏi") thay vì bắt đầu từ mới.
    private var continueWordOnNextChar = false

    public init() {}

    /// Ghi log chẩn đoán (bản Debug của bộ gõ gắn vào DebugLog).
    public var log: ((String) -> Void)?

    public func reset() {
        engine.reset()
        onLine = nil
        restartChars = nil
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
    /// `repeatDelay`: với terminal tự xử lý phím lặp mà không qua bộ gõ (Rex, Muxy) — thời gian giữ phím trước
    /// khi phím lặp; sau Backspace mà phím kế tiếp tới muộn hơn thế thì có thể Backspace đã lặp: bắt đầu từ mới.
    /// `earlyCommit`: chế độ gạch chân trong terminal — chữ không còn đổi được thì chốt ngay cho shell thấy (xem
    /// `showMarked`). Ứng dụng thường giữ cả từ trong phần gạch chân để xoá lùi rồi thêm dấu vẫn đúng.
    /// `gap`: terminal — giữa phím trước và phím này có phím / click nào bộ gõ không thấy không (sổ phím của
    /// GTVInput, xem `KeyLedger`).
    /// `legacy`: terminal — byte terminal gửi xuống shell cho phím này khi không có bổ trợ (Enter "\r", Tab "\t", ⌫ DEL,
    /// Esc, ←, Ctrl+chữ); dùng để gửi kèm phím khi Ghostty sẽ nuốt nó (xem `handleTerminal`).
    public func handle(_ key: Key, _ client: TextClient, options: EngineOptions, forceMarked: Bool,
                       qtApp: Bool = false, terminal: TerminalStyle? = nil, repeatDelay: Double? = nil,
                       earlyCommit: Bool = false, gap: KeyGap = .none, legacy: String? = nil) -> Bool {
        self.qtApp = qtApp
        self.earlyCommit = earlyCommit
        if let terminal {
            if marked || literalTail { reset() }     // vừa đổi từ chế độ gạch chân
            return handleTerminal(key, client, options: options, style: terminal, repeatDelay: repeatDelay, gap: gap,
                                  legacy: legacy)
        }
        if literalTail {
            // Từ đã chốt (xem `showMarked`): chữ cái gõ tiếp đi thẳng, phím khác kết thúc từ. Xoá lùi vẫn ở trong
            // từ đã chốt (không bắt đầu từ mới giữa từ: "shoq⌫w" phải ra "show", không phải "shoư").
            switch key {
            case let .char(ch) where ch.isASCII && ch.isLetter:
                literalLength += 1
                return false
            case .char:
                reset()          // như khi từ kết thúc bằng dấu câu: phím đi thẳng
                return false
            case .backspace:
                literalLength -= 1                     // terminal tự xoá
                if literalLength <= 0 { reset() }      // xoá hết từ: gõ tiếp là từ mới
                return false
            case .other:
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
        if let client {
            if client.lateEditSafe() {
                settlePending(client)
            } else {
                clearPending()     // có phím tắt / click sau lần sửa (vd. ⌘V): lần sửa có thể đã lỗi thời
            }
        }
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
        let final = earlyCommit && engine.isFinal
        if earlyCommit, preedit.isEmpty, before == committed, action == .passThrough,
           final || Self.isStableInitial(ch) {
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
        literalLength = engine.displayed.count
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
    ///
    /// Phím đi vòng bộ gõ (terminal tự xử lý: ⌘V, mũi tên / Ctrl+A ở iTerm2, Tab / Ctrl+A ở Muxy, mọi phím đặc biệt
    /// ở Terminal.app) và click / cuộn được sổ phím báo qua `gap`: `.interrupted` thì bỏ từ (con trỏ có thể đã đổi
    /// chỗ); `.unsure` thì chưa xoá gì, phím đi nguyên văn, phím sau khi đã chắc chắn sẽ sửa cả từ trong một lần.
    private func handleTerminal(_ key: Key, _ client: TextClient, options: EngineOptions,
                                style: TerminalStyle, repeatDelay: Double?, gap: KeyGap, legacy: String?) -> Bool {
        continueWordOnNextChar = false
        var carry: Character?
        if let text = pending, pendingClient === client {
            // Lần sửa trước (kiểu .deferred, Ghostty) luôn tới shell trước phím này.
            clearPending()
            if client.hasMarkedText() {
                // Nó chưa tới, và phím này tới khi marked text rỗng còn đó. Trong keyDown này Ghostty (nhánh A) chỉ ghi
                // chữ bộ gõ đưa — bỏ ký tự điều khiển đứng riêng — rồi chỉ phát lại ↑ ↓ →; phím khác bị nuốt.
                var printable: Character?
                if case let .char(ch) = key, Self.isPrintable(ch) { printable = ch }
                if gap == .interrupted {
                    // Đã có phím tắt / click đi vòng bộ gõ sau lần sửa đó (vd. ⌘V): lần sửa lỗi thời (DEL sẽ xoá chữ
                    // dán), bỏ. Phím chữ thì tự gửi; phím có chuỗi điều khiển nhiều byte (←, Home…) thì gửi chuỗi đó;
                    // còn lại chỉ gỡ marked text (Ghostty nuốt phím này — hiếm: lần sửa phải còn chờ đúng lúc đó).
                    log?("deferred: bỏ lần sửa chưa tới vì có phím / click đi vòng bộ gõ")
                    if let ch = printable {
                        carry = ch
                    } else {
                        resetTerminalWord()
                        if let legacy, legacy.unicodeScalars.count > 1 {
                            client.insertText(legacy)
                        } else {
                            client.setMarkedText("")
                        }
                        return true
                    }
                } else if printable == nil, let legacy {
                    // Gửi phím kèm lần sửa trong một lần ghi (không còn là ký tự điều khiển đứng riêng).
                    log?("deferred: gửi lần sửa kèm phím \(legacy.debugDescription)")
                    client.insertText(text + legacy)
                    if key == .backspace, onLine == nil, !engine.isEmpty, case .passThrough = engine.backspace() {
                        // từ vẫn khớp: shell xoá đúng ký tự cuối
                    } else {
                        resetTerminalWord()
                    }
                    return true
                } else {
                    log?("deferred: phím kế tiếp tới khi lần sửa chưa tới → gửi ngay trong keyDown")
                    client.insertText(text)
                }
            }
        }
        if gap == .interrupted, !engine.isEmpty {
            log?("có phím / click bộ gõ không thấy: bỏ từ \((onLine ?? engine.displayed).debugDescription)")
            resetTerminalWord()
        }
        let handled = handleTerminalKey(key, client, options: options, style: style, repeatDelay: repeatDelay, gap: gap,
                                        legacy: legacy)
        if let ch = carry, !handled {
            client.insertText(String(ch))
            return true
        }
        return handled
    }

    private func handleTerminalKey(_ key: Key, _ client: TextClient, options: EngineOptions,
                                   style: TerminalStyle, repeatDelay: Double?, gap: KeyGap, legacy: String?) -> Bool {
        var unsure = gap == .unsure || gap == .unsureSteady
        if gap == .none { restartChars = nil }      // không có phím nào đi vòng: từ cũ đúng
        let now = client.currentTime()
        if let repeatDelay, let bs = lastBackspaceAt, now - bs >= repeatDelay * 0.9 {
            resetTerminalWord()     // có thể Backspace đã được giữ (phím lặp không qua bộ gõ): không biết đã xoá bao nhiêu
        }
        lastBackspaceAt = nil
        switch key {
        case .other:
            resetTerminalWord()     // Enter, mũi tên, Ctrl+...: shell tự xử lý, không khôi phục từ sau phím này
            return false
        case .backspace:
            restartChars = nil
            guard !engine.isEmpty else { return false }
            if guardCursor(client, gap: gap) == .matches, gap == .unsureSteady { unsure = false }
            guard !engine.isEmpty else { return false }
            termLastWrite = client.currentTime()
            lastBackspaceAt = termLastWrite
            if let line = onLine {
                // Dòng đang khác từ của engine (phím đã đi nguyên văn lúc chưa chắc).
                guard !unsure else {
                    // Vẫn chưa chắc: shell xoá ký tự cuối của dòng; nạp lại phần còn lại (chữ dựng sẵn: mỗi chữ một code
                    // point) để gõ tiếp.
                    var rest = line.unicodeScalars
                    rest.removeLast()
                    resetTerminalWord()
                    if !rest.isEmpty { engine.seed(String(rest)) }
                    return false
                }
                // Đã chắc: sửa cả từ trong một lần ghi, kể cả phím xoá này (như thể không có lúc chưa chắc).
                _ = engine.backspace()
                onLine = nil
                emit(line, engine.displayed, typed: "x", then: "", client, style)
                return true
            }
            if case .passThrough = engine.backspace() { return false }   // shell xoá 1 ký tự: vẫn khớp
            engine.reset()          // xoá làm dấu phải đặt lại chỗ khác: thôi theo dõi từ, xoá như thường
            return false
        case let .char(ch):
            // iTerm2 / Terminal.app: sổ phím chưa chắc nhưng không có thêm phím nào chưa thấy kể từ phím trước, và màn
            // hình (đã in lại phím trước, nên cả mọi thứ trước nó) cho thấy đúng từ nằm ngay trước con trỏ: sửa được
            // (vd. ⌫ ở Terminal.app không qua bộ gõ, rồi gõ tiếp liền tay).
            if !engine.isEmpty {
                switch guardCursor(client, gap: gap) {
                case .matches where gap == .unsureSteady:
                    unsure = false
                case .restartMatches where gap == .unsureSteady:
                    restartWord(restartChars ?? [], options)
                    unsure = false
                case .unconfirmed where unsure && restartChars == nil:
                    restartChars = []          // từ phím này: có thể là từ mới (xem `restartChars`)
                default:
                    break
                }
            }
            if engine.isEmpty {
                engine.options = Self.terminalOptions(options)
                onLine = nil
            }
            termLastWrite = client.currentTime()
            let line = onLine ?? engine.displayed      // chữ của từ đang nằm ngay trước con trỏ
            let rawLine = onLine != nil
            onLine = nil
            if unsure, restartChars != nil { restartChars!.append(ch) }
            guard engine.process(ch) != nil else {
                // Hết từ (dấu cách, dấu câu…): khôi phục từ không phải tiếng Việt trước ký tự này.
                restartChars = nil
                let finished = engine.finishWord()
                var target = finished.text
                if case let .replace(_, new) = finished.action { target = new }
                if rawLine, !unsure, !Self.isPrintable(ch),
                   let handled = fixLineWithKey(line, finished.text, legacy: legacy, client, style) {
                    return handled
                }
                guard Self.isPrintable(ch), !unsure, !Self.same(line, target) else { return false }
                emit(line, target, typed: ch, then: String(ch), client, style)
                return true
            }
            let target = engine.displayed
            if Self.same(line + String(ch), target) { return false }   // shell gõ đúng ký tự này
            if unsure {
                // Chưa chắc con trỏ còn ngay sau từ: không xoá gì, phím đi nguyên văn; khi chắc chắn thì sửa cả từ.
                onLine = line + String(ch)
                log?("chưa chắc có phím đi vòng bộ gõ không: \(ch) đi nguyên văn, dòng \(onLine!.debugDescription)")
                return false
            }
            emit(line, target, typed: ch, then: "", client, style)
            return true
        }
    }

    private func resetTerminalWord() {
        engine.reset()
        onLine = nil
        restartChars = nil
    }

    /// Từ thật bắt đầu từ `restartChars` (đã nằm nguyên văn ngay trước con trỏ): nạp lại.
    private func restartWord(_ chars: [Character], _ options: EngineOptions) {
        resetTerminalWord()
        engine.options = Self.terminalOptions(options)
        var raw = ""
        for c in chars {
            guard engine.process(c) != nil else { resetTerminalWord(); return }
            raw.append(c)
        }
        if !Self.same(raw, engine.displayed) { onLine = raw }
        log?("màn hình cho thấy có phím đi vòng: từ bắt đầu lại từ \(raw.debugDescription)")
    }

    /// Phím chắc chắn (sổ phím) kết thúc từ mà không in được (⏎, ⇥, ⎋) khi dòng còn giữ phím đi nguyên văn lúc chưa chắc
    /// (`onLine`): sửa cả từ và gửi luôn byte của phím trong một lần ghi, bộ gõ giữ phím (iTerm2 coi phím đã xử lý khi có
    /// insertText trong keyDown). Mở đầu bằng ký tự thường: Ghostty bỏ chữ mở đầu bằng ký tự điều khiển trong keyDown,
    /// và với ⏎ thì ghi nguyên văn chữ đó (phím khác Ghostty tự mã hoá, bỏ chữ: từ giữ nguyên văn như trước).
    /// nil: không làm gì (phím đi thẳng, từ giữ nguyên văn).
    private func fixLineWithKey(_ old: String, _ new: String, legacy: String?, _ client: TextClient,
                                _ style: TerminalStyle) -> Bool? {
        guard !Self.same(old, new), let legacy, legacy.unicodeScalars.count == 1 else { return nil }
        var oi = old.startIndex, ni = new.startIndex
        while oi < old.endIndex, ni < new.endIndex, old[oi] == new[ni] {
            oi = old.index(after: oi)
            ni = new.index(after: ni)
        }
        let deletes = old[oi...].unicodeScalars.count
        let word = String(new[ni...])
        let dels = String(repeating: "\u{7f}", count: deletes)
        switch style {
        case .inlineBare:
            client.insertText(dels + word + legacy)
        case .inline, .deferred:
            client.insertText(deletes == 0 ? word + legacy : String(word.first ?? "x") + "\u{7f}" + dels + word + legacy)
        }
        log?("sửa \(old.debugDescription) → \(new.debugDescription) cùng phím \(legacy.debugDescription)")
        return true
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }

    /// Con trỏ có còn ngay sau từ bộ gõ đang theo dõi không (chỉ với terminal cho biết con trỏ và chữ trên
    /// màn hình: iTerm2, Terminal.app…; Ghostty báo con trỏ ở 0 — mọi phím đều qua bộ gõ nên không cần).
    /// Terminal tự xử lý một số phím mà không qua bộ gõ (iTerm2: mũi tên, Ctrl+A/E; Terminal.app: mọi phím đặc
    /// biệt kể cả Backspace); gửi DEL theo từ cũ khi đó sẽ xoá nhầm. Nguyên tắc: không bao giờ xoá mò.
    /// - Màn hình khớp từ, con trỏ ở cuối: bình thường.
    /// - Con trỏ nằm giữa từ đang hiện đầy đủ (mũi tên, Ctrl+A): đọc lại phần trước con trỏ rồi gõ tiếp.
    /// - Khác đi mà chữ vừa gửi đã đủ lâu (không phải đang chờ shell in lại): bắt đầu từ mới tại con trỏ — từ
    ///   đó chỉ xoá những gì gõ sau đó, luôn đúng dù shell in chậm.
    /// Kết quả đối chiếu từ đang theo dõi với màn hình (`guardCursor`).
    private enum ScreenCheck {
        /// Terminal không cho đọc màn hình (Ghostty, Rex, Muxy…).
        case unavailable
        /// Màn hình cho thấy đúng từ đang theo dõi nằm ngay trước con trỏ.
        case matches
        /// Con trỏ nằm giữa từ: đã nạp lại phần trước con trỏ (đúng như màn hình).
        case reseeded
        /// Màn hình khớp các ký tự gõ từ lúc nghi có phím đi vòng (`restartChars`), không khớp từ cũ.
        case restartMatches
        /// Không khớp (từ có thể đã bị bỏ).
        case unconfirmed
    }

    /// Đối chiếu từ đang theo dõi với màn hình (iTerm2, Terminal.app). Màn hình chỉ cho thấy những gì shell đã in lại,
    /// nên lệch có thể chỉ vì chưa in kịp; tuỳ sổ phím (`gap`):
    /// - không có phím nào đi vòng (`.none`): lệch là chưa in kịp (chữ sau con trỏ có thể là gợi ý của fish) — chỉ bỏ từ
    ///   khi đã quá lâu không in lại (vim ở normal mode, ô mật khẩu);
    /// - chưa chắc (`.unsure…`): có thể đã có phím đi vòng (⌫, mũi tên ở Terminal.app) — bỏ từ ngay, không đoán;
    /// - sổ không dùng được (`.unverified`): như trước khi có sổ phím (con trỏ giữa từ thì nạp lại phần trước con trỏ).
    @discardableResult
    private func guardCursor(_ client: TextClient, gap: KeyGap) -> ScreenCheck {
        guard let sel = client.selectedRange(), sel.location > 0 else { return .unavailable }
        let word = Array((onLine ?? engine.displayed).utf16)
        let n = word.count, cursor = sel.location
        let beforeLen = min(n, cursor)
        let before = client.text(location: cursor - beforeLen, length: beforeLen).map { Array($0.utf16) } ?? []
        if before == word { return .matches }
        switch gap {
        case .none:
            if client.currentTime() - termLastWrite >= Self.echoLag { resetTerminalWord() }
            return .unconfirmed
        case .unsure, .unsureSteady, .interrupted:
            // Không xoá gì lúc chưa chắc; giữ từ cũ (có thể chỉ là chưa in kịp). Màn hình khớp các ký tự gõ từ lúc nghi có
            // phím đi vòng thì đó là từ thật.
            if let chars = restartChars, !chars.isEmpty {
                let suffix = Array(String(chars).utf16)
                let tail = client.text(location: max(0, cursor - suffix.count), length: min(suffix.count, cursor))
                    .map { Array($0.utf16) } ?? []
                if tail == suffix { return .restartMatches }
            }
            return .unconfirmed
        case .unverified:
            break
        }
        let after = client.text(location: cursor, length: n).map { Array($0.utf16) } ?? []
        // Con trỏ nằm giữa (hoặc ngay trước) từ đang hiện đầy đủ: trước con trỏ là word[..<k], sau là word[k...].
        for k in stride(from: min(n - 1, before.count), through: 0, by: -1)
        where before.suffix(k).elementsEqual(word[..<k]) && after.prefix(n - k).elementsEqual(word[k...]) {
            resetTerminalWord()
            if k > 0 { engine.seed(String(decoding: word[..<k], as: UTF16.self)) }
            return .reseeded
        }
        if client.currentTime() - termLastWrite >= Self.echoLag { resetTerminalWord() }
        return .unconfirmed
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
            log?("deferred #\(serial): chờ \(pending!.debugDescription)")
            client.schedule(after: Self.deferDelay) { [weak self, weak client] in
                guard let self, let client else { return }
                self.sendPending(client, serial: serial, attempt: 1)
            }
        }
    }

    /// Gửi lần sửa đang chờ (ngoài keyDown) rồi kiểm tra: marked text rỗng còn đó nghĩa là ứng dụng đã bỏ chuỗi
    /// (Ghostty bỏ insertText khi không có sự kiện nào đang xử lý) — gửi lại, tối đa 3 lần; sau đó để phím kế tiếp
    /// gửi (`settlePending`). Ứng dụng nhận các lần gọi của bộ gõ theo thứ tự, nên lúc hỏi marked text thì chuỗi
    /// đã được xử lý xong: không bao giờ gửi trùng.
    private func sendPending(_ client: TextClient, serial: Int, attempt: Int) {
        guard let text = pending, pendingSerial == serial, pendingClient === client else { return }
        guard client.lateEditSafe() else {
            // Có phím tắt (⌘V…) / click sau phím này: lần sửa có thể đã lỗi thời. Để phím kế tiếp quyết định (gửi trong
            // keyDown của nó, hoặc bỏ nếu sổ phím báo có phím đi vòng).
            log?("deferred #\(serial): đã có phím tắt / click, để phím kế tiếp quyết định")
            return
        }
        log?("deferred #\(serial): gửi lần \(attempt) (ngoài keyDown)")
        client.insertText(text)
        client.schedule(after: 0.03) { [weak self, weak client] in
            guard let self, let client, self.pendingSerial == serial, self.pending != nil else { return }
            if !client.hasMarkedText() {
                self.log?("deferred #\(serial): đã tới (mark đã mất)")
                self.clearPending()
            } else if attempt < 3 {
                self.log?("deferred #\(serial): mark còn sau 30ms → gửi lại")
                self.sendPending(client, serial: serial, attempt: attempt + 1)
            } else {
                self.log?("deferred #\(serial): chưa tới sau \(attempt) lần, chờ phím kế tiếp")
            }
        }
    }

    /// Trước phím kế tiếp / khi chốt: lần sửa còn chờ (marked text rỗng vẫn còn) thì gửi ngay — lúc này
    /// Ghostty đang xử lý phím bắt đầu khi còn marked text nên ghi nguyên văn; đã tới rồi thì thôi.
    private func settlePending(_ client: TextClient) {
        guard let text = pending, pendingClient === client else { return }
        let marked = client.hasMarkedText()
        log?("deferred #\(pendingSerial): phím kế tiếp tới, mark \(marked ? "còn → gửi ngay trong keyDown" : "đã mất → coi như đã tới")")
        clearPending()
        if marked { client.insertText(text) }
    }

    private func clearPending() {
        pending = nil
        pendingClient = nil
    }

    /// Terminal: luôn xuất chữ dựng sẵn. Với chữ tổ hợp (chữ gốc + dấu thanh U+0300…), một DEL của fish, bash, zsh
    /// mặc định xoá cả chữ lẫn dấu còn zsh -f chỉ xoá dấu — không có số DEL nào đúng cho mọi shell.
    static func terminalOptions(_ options: EngineOptions) -> EngineOptions {
        var o = options
        if o.charset == .unicodeCombining { o.charset = .unicode }
        return o
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
