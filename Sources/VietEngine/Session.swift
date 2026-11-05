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
    /// iTerm2 / Terminal.app, lúc sổ phím chưa chắc (`.unsure…`): hoặc không có phím nào đi vòng (từ cũ vẫn đúng), hoặc
    /// có (vd. ⌫ ở Terminal.app) và từ thật bắt đầu từ các ký tự gõ sau đó. Xem `Suspect`, `judgeSuspect`.
    private var suspect: Suspect?
    /// Màn hình đã cho thấy tác dụng của các phím chưa thấy (`judgeSuspect`): các phím sau mà sổ phím vẫn báo cùng số dư
    /// (`.unsureSteady`, không có phím chưa thấy mới) coi là chắc.
    private var suspectSettled = false

    /// Từ lúc sổ phím báo có phím chưa thấy: dòng lúc đó, và các ký tự đã đi nguyên văn kể từ đó.
    private struct Suspect {
        /// Chữ của từ nằm trước con trỏ ngay trước phím đầu tiên của lúc chưa chắc (nếu không có phím nào đi vòng).
        var oldLine: String
        /// Các ký tự đã đi nguyên văn từ đó (gồm cả ký tự của phím đó).
        var raw: [Character] = []
        /// Chắc chắn có phím đi vòng / click (`.bypassed`), không chỉ là sổ phím chưa biết: sổ phím báo sạch sau đó không
        /// chứng minh được từ cũ còn đúng — chỉ màn hình quyết định.
        var bypassKnown = false
        /// `raw[0]` là ký tự của chính phím mà sổ phím báo có phím chưa thấy mới (`.unsure`): phím đi vòng bấm ngay sau phím
        /// đó (trước lúc bộ gõ đọc bộ đếm) được ứng dụng xử lý SAU nó — màn hình in lại nó chưa chứng minh gì; phải có ký tự
        /// gõ sau đó. (`.bypassed`: phím đi vòng đã chắc là trước phím đó.)
        var leadIsSuspectKey = false
    }
    /// iTerm2 / Terminal.app: shell in lại chậm bao lâu, đo từ chính các lần gõ (`EchoClock`, `probeEcho`).
    private var echo = EchoClock()
    /// Lần đo thời gian in lại đang chờ (`probeEcho`).
    private var echoProbe = 0
    /// Thời gian ứng dụng xử lý xong một phím đi vòng bấm ngay sau phím trước (xem `judgeSuspect`).
    private static let processingMargin = 0.01
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
        suspect = nil
        suspectSettled = false
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
                if gap.drops {
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
        // Phím tắt / phím đi vòng / click: con trỏ có thể đã đổi chỗ — bỏ từ. Phím đi vòng / click ở terminal cho đọc màn
        // hình thì giữ lại làm giả thuyết, màn hình quyết định sau (`judgeSuspect`).
        if gap == .interrupted || (gap == .bypassed && !screenUsable(client)), !engine.isEmpty {
            log?("có phím / click bộ gõ không thấy: bỏ từ \((onLine ?? engine.displayed).debugDescription)")
            resetTerminalWord()
        }
        let writtenBefore = termLastWrite
        let handled = handleTerminalKey(key, client, options: options, style: style, repeatDelay: repeatDelay, gap: gap,
                                        legacy: legacy)
        if termLastWrite != writtenBefore, screenUsable(client) { probeEcho(client, sentAt: termLastWrite) }
        if let ch = carry, !handled {
            client.insertText(String(ch))
            return true
        }
        return handled
    }

    private func handleTerminalKey(_ key: Key, _ client: TextClient, options: EngineOptions,
                                   style: TerminalStyle, repeatDelay: Double?, gap: KeyGap, legacy: String?) -> Bool {
        // Terminal không cho đọc màn hình: phím đi vòng / click đã bỏ từ (`handleTerminal`), phím này bắt đầu từ mới.
        let bypassed = gap == .bypassed && screenUsable(client)
        var unsure = gap == .unsure || gap == .unsureSteady || bypassed
        switch gap {
        case .unsureSteady:
            // Không có phím chưa thấy mới kể từ phím trước. Màn hình đã cho thấy tác dụng của các phím chưa thấy thì coi
            // là chắc; chưa thì xem màn hình bây giờ (iTerm2, Terminal.app).
            if suspectSettled || settleSuspect(client, options) { unsure = false }
        case .unsure:
            // Có phím chưa thấy mới: lúc chưa chắc bắt đầu lại từ phím này (giả thuyết có phím đi vòng chắc chắn thì giữ).
            if suspect?.bypassKnown != true { suspect = nil }
            suspectSettled = false
        case .bypassed:
            // Có phím đi vòng / click trước phím này (hoặc chưa chắc trước hay sau: còn báo ở các phím sau). Không xem màn
            // hình ở phím này: phím đi vòng có thể chỉ vừa được xử lý.
            suspectSettled = false
            if suspect?.bypassKnown != true { suspect = nil }
        case .none:
            if suspect?.bypassKnown == true {
                // Sổ sạch không chứng minh được từ cũ: chỉ màn hình quyết định.
                unsure = !settleSuspect(client, options)
            } else {
                suspect = nil              // không có phím nào đi vòng: từ cũ đúng
                suspectSettled = false
            }
        case .interrupted, .unverified:
            suspect = nil
            suspectSettled = false
        }
        // Phím chắc chắn: đối chiếu với màn hình như thường (con trỏ đã bị dời, shell chưa in lại…). Đã rõ nhờ màn hình
        // thì như sổ phím sạch.
        let screenGap: KeyGap = gap == .unverified ? .unverified : .none
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
            if bypassed {
                resetTerminalWord()      // không biết phím đi vòng đã làm gì với dòng: bỏ từ, ⌫ đi thẳng
                return false
            }
            guard !engine.isEmpty else { suspect = nil; return false }
            if !unsure { guardCursor(client, gap: screenGap) }
            guard !engine.isEmpty else { return false }
            termLastWrite = client.currentTime()
            lastBackspaceAt = termLastWrite
            if unsure, var s = suspect {
                // Shell xoá ký tự cuối của dòng, dù có phím đi vòng hay không: ký tự nguyên văn cuối (nếu còn), không thì
                // ký tự cuối của từ cũ.
                if !s.raw.isEmpty {
                    s.raw.removeLast()
                    if s.raw.isEmpty { s.leadIsSuspectKey = false }
                } else if !s.oldLine.isEmpty {
                    s.oldLine.removeLast()
                }
                suspect = s
            }
            if let line = onLine {
                // Dòng đang khác từ của engine (phím đã đi nguyên văn lúc chưa chắc).
                guard !unsure else {
                    // Vẫn chưa chắc: shell xoá ký tự cuối của dòng; nạp lại phần còn lại (chữ dựng sẵn: mỗi chữ một code
                    // point) để gõ tiếp.
                    var rest = line.unicodeScalars
                    rest.removeLast()
                    let keep = suspect
                    resetTerminalWord()
                    suspect = keep
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
            suspect = nil
            return false
        case let .char(ch):
            if !unsure, !engine.isEmpty { guardCursor(client, gap: screenGap) }
            if engine.isEmpty {
                engine.options = Self.terminalOptions(options)
                onLine = nil
            }
            termLastWrite = client.currentTime()
            let line = onLine ?? engine.displayed      // chữ của từ đang nằm ngay trước con trỏ
            let rawLine = onLine != nil
            onLine = nil
            if unsure {
                if suspect == nil {
                    suspect = Suspect(oldLine: line, bypassKnown: bypassed, leadIsSuspectKey: gap == .unsure)
                }
                suspect!.raw.append(ch)
            }
            guard engine.process(ch) != nil else {
                // Hết từ (dấu cách, dấu câu…): khôi phục từ không phải tiếng Việt trước ký tự này. Lúc chưa chắc, chữ / số
                // làm hết từ cũ (từ cũ không còn là tiếng Việt) vẫn có thể là một phần của từ bắt đầu lại: giữ `suspect`.
                if !(unsure && (ch.isLetter || ch.isNumber)) { suspect = nil }
                let finished = engine.finishWord()
                var target = finished.text
                if case let .replace(_, new) = finished.action { target = new }
                // ⏎ ⇥ ⎋ chạy lệnh / hoàn thành ngay, người dùng không kịp thấy dòng đã sửa: chỉ sửa kèm phím khi sổ phím
                // chứng minh không có phím nào đi vòng, không bao giờ dựa vào màn hình.
                if rawLine, gap == .none, !Self.isPrintable(ch),
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
        suspect = nil
    }

    /// iTerm2 / Terminal.app: sau lần gửi lúc `sentAt`, xem lại màn hình sau 4, 8, 16, 32, 64 ms cho tới khi thấy đúng chữ
    /// của từ đang gõ trước con trỏ — đo trực tiếp thời gian shell in lại (`EchoClock`). Có phím mới thì thôi.
    private func probeEcho(_ client: TextClient, sentAt: Double, step: Int = 0) {
        let delays = [0.004, 0.004, 0.008, 0.016, 0.032]
        guard step < delays.count else { return }
        if step == 0 { echoProbe &+= 1 }
        let probe = echoProbe
        client.schedule(after: delays[step]) { [weak self, weak client] in
            guard let self, let client, self.echoProbe == probe, self.termLastWrite == sentAt else { return }
            let word = Array((self.onLine ?? self.engine.displayed).utf16)
            guard !word.isEmpty, let sel = client.selectedRange(), sel.location >= word.count else { return }
            let before = client.text(location: sel.location - word.count, length: word.count).map { Array($0.utf16) }
            if before == word {
                self.echo.measured(client.currentTime() - sentAt)
            } else {
                self.probeEcho(client, sentAt: sentAt, step: step + 1)
            }
        }
    }

    /// Terminal cho đọc màn hình (iTerm2, Terminal.app: con trỏ thật) và màn hình đang cho thấy chữ bộ gõ gửi.
    private func screenUsable(_ client: TextClient) -> Bool {
        guard echo.tracking, let sel = client.selectedRange() else { return false }
        return sel.location > 0
    }

    /// Kết luận về lúc chưa chắc từ màn hình (`judgeSuspect`). true: đã rõ (từ cũ đúng, hay từ bắt đầu lại từ các ký tự
    /// nguyên văn), phím này coi là chắc.
    private func settleSuspect(_ client: TextClient, _ options: EngineOptions) -> Bool {
        guard let s = suspect else { return false }
        switch judgeSuspect(s, client) {
        case .undecided:
            return false
        case .old:
            log?("màn hình cho thấy các phím chưa thấy không đổi dòng: giữ từ \((s.oldLine + String(s.raw)).debugDescription)")
        case .restart:
            restartWord(s.raw, options)
        }
        suspect = nil
        suspectSettled = true
        return true
    }

    private enum SuspectJudgement { case old, restart, undecided }

    /// Màn hình (iTerm2, Terminal.app) chỉ cho thấy những gì shell đã in lại. Phím đi vòng mà sổ phím đã đếm ở lần đọc phím
    /// trước được ứng dụng xử lý ngay sau phím đó (cả khi bấm ngay sau nó, trước lúc bộ gõ đọc): khi đã qua thời gian in lại
    /// (`EchoClock`) kể từ phím trước, màn hình cho thấy đủ tác dụng của chúng và mọi ký tự bộ gõ đã gửi. Lúc đó (và màn hình
    /// không thể là một lúc in dở của dòng cũ):
    /// - trước con trỏ là đúng từ cũ + các ký tự nguyên văn: các phím chưa thấy không đổi gì trước con trỏ (`.old`);
    /// - trước con trỏ là các ký tự nguyên văn, liền nhau: từ bắt đầu lại từ đó (`.restart`).
    /// Ứng dụng treo giữa lúc đó (phím đi vòng chỉ được xử lý ngay trước phím này) thì sổ phím không báo "không có gì mới"
    /// (phím này không tới ngay: xem `KeyLedger`).
    private func judgeSuspect(_ s: Suspect, _ client: TextClient) -> SuspectJudgement {
        guard s.raw.count - (s.leadIsSuspectKey ? 1 : 0) >= 1, echo.tracking else { return .undecided }
        // Mọi phím chưa thấy (đã được đếm từ lần đọc phím trước) đã được ứng dụng xử lý ngay sau phím trước — kể cả phím
        // bấm ngay sau phím đó, được xử lý sau nó — và shell đã kịp in lại chúng cùng các ký tự bộ gõ đã gửi.
        guard client.currentTime() - termLastWrite >= echo.bound + Self.processingMargin else { return .undecided }
        guard let sel = client.selectedRange(), sel.location > 0 else { return .undecided }
        let cursor = sel.location
        let raw = String(s.raw)
        let full = Array((s.oldLine + raw).utf16)
        let rawUnits = Array(raw.utf16)
        // Đọc đủ dài cho từ cũ; dòng ngắn hơn thế (ô nhập liệu không cho đọc quá đầu) thì đọc đủ cho các ký tự nguyên văn.
        var before: [UInt16] = []
        for len in [min(cursor, max(full.count, rawUnits.count)), min(cursor, rawUnits.count)] {
            if let text = client.text(location: cursor - len, length: len) { before = Array(text.utf16); break }
        }
        guard !before.isEmpty else { return .undecided }
        func ends(_ x: [UInt16]) -> Bool { !x.isEmpty && before.count >= x.count && before.suffix(x.count).elementsEqual(x) }
        if ends(full) { return .old }
        if ends(rawUnits) { return .restart }
        return .undecided
    }

    /// Từ thật bắt đầu từ các ký tự này (đã nằm nguyên văn, liền nhau, ngay trước con trỏ — `judgeSuspect`): nạp lại.
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
        /// Không khớp (từ có thể đã bị bỏ).
        case unconfirmed
    }

    /// Đối chiếu từ đang theo dõi với màn hình (iTerm2, Terminal.app) ở phím chắc chắn. Màn hình chỉ cho thấy những gì
    /// shell đã in lại, nên lệch có thể chỉ vì chưa in kịp; tuỳ sổ phím (`gap`):
    /// - không có phím nào đi vòng (`.none`): lệch là chưa in kịp (chữ sau con trỏ có thể là gợi ý của fish) — chỉ bỏ từ
    ///   khi đã quá lâu không in lại (vim ở normal mode, ô mật khẩu);
    /// - sổ không dùng được (`.unverified`): như trước khi có sổ phím (con trỏ giữa từ thì nạp lại phần trước con trỏ).
    /// Lúc chưa chắc (`.unsure…`) thì không dùng hàm này (xem `judgeSuspect`).
    @discardableResult
    private func guardCursor(_ client: TextClient, gap: KeyGap) -> ScreenCheck {
        guard let sel = client.selectedRange(), sel.location > 0 else { return .unavailable }
        let word = Array((onLine ?? engine.displayed).utf16)
        let n = word.count, cursor = sel.location
        let beforeLen = min(n, cursor)
        let before = client.text(location: cursor - beforeLen, length: beforeLen).map { Array($0.utf16) } ?? []
        let sinceWrite = client.currentTime() - termLastWrite
        echo.observe(visible: before == word, after: sinceWrite)
        if before == word { return .matches }
        // Ứng dụng toàn màn hình vẽ con trỏ riêng (Claude Code, vim…): con trỏ thật ở chỗ khác, màn hình vô nghĩa.
        guard echo.tracking else { return .unavailable }
        // Đã qua thời gian in lại kể từ lần gửi cuối: màn hình đã in hết những gì bộ gõ gửi, lệch là do thứ khác.
        let settled = sinceWrite >= echo.bound
        switch gap {
        case .unverified:
            break
        case .unsure, .unsureSteady, .interrupted, .bypassed:
            return .unconfirmed      // không xoá gì, không đoán
        case .none:
            // Sổ phím chứng minh không có phím nào đi vòng: lệch chỉ có thể là shell in chậm (bận) hay không in lại những
            // gì gõ (vim ở normal mode, ô mật khẩu) — chỉ bỏ từ khi đã lâu.
            if sinceWrite >= max(EchoClock.unknown, echo.bound) { resetTerminalWord() }
            return .unconfirmed
        }
        let after = client.text(location: cursor, length: n).map { Array($0.utf16) } ?? []
        // Con trỏ nằm giữa (hoặc ngay trước) từ đang hiện đầy đủ: trước con trỏ là word[..<k], sau là word[k...].
        for k in stride(from: min(n - 1, before.count), through: 0, by: -1)
        where before.suffix(k).elementsEqual(word[..<k]) && after.prefix(n - k).elementsEqual(word[k...]) {
            resetTerminalWord()
            if k > 0 { engine.seed(String(decoding: word[..<k], as: UTF16.self)) }
            return .reseeded
        }
        if settled {
            // Có phím đi vòng đã đổi dòng (vd. ⌫ ở Terminal.app): gõ tiếp từ đang nằm trước con trỏ (nếu thấy trọn).
            resetTerminalWord()
            reseedFromScreen(client, cursor: cursor)
        }
        return .unconfirmed
    }

    /// Nạp từ đang nằm ngay trước con trỏ trên màn hình (chỉ khi thấy trọn: đứng sau ký tự không phải chữ).
    private func reseedFromScreen(_ client: TextClient, cursor: Int) {
        let len = min(cursor, 16)
        guard len > 0, let text = client.text(location: cursor - len, length: len) else { return }
        let word = String(text.reversed().prefix(while: { $0.isLetter }).reversed())
        guard !word.isEmpty, word.utf16.count < len else { return }
        if engine.seed(word) { log?("đọc lại từ trên màn hình: \(word.debugDescription)") }
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
