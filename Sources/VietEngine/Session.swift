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
    /// Hỏi ô nhập liệu một câu mà nó chỉ trả lời được sau khi TRANG xử lý xong mọi phím / click đã gửi cho trang trước đó (ô
    /// web của Chromium: câu hỏi "ký tự ở điểm này trên màn hình" đi một vòng đồng bộ sang trang — như bộ gõ có cửa sổ gợi ý
    /// vẫn hỏi). true: trang đã trả lời. false: ô không hỏi được, hoặc trang không trả lời kịp.
    func settle() -> Bool
}

public extension TextClient {
    func schedule(after delay: Double, _ work: @escaping () -> Void) { work() }
    func hasMarkedText() -> Bool { false }
    func currentTime() -> Double { 0 }
    func lateEditSafe() -> Bool { true }
    func settle() -> Bool { false }
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
        /// Chỉ các ký tự từ `raw[proofFrom]` là bằng chứng (`judgeSuspect`). Phím mà sổ phím báo có phím chưa thấy mới
        /// (`.unsure`): phím đi vòng bấm ngay sau phím đó (trước lúc bộ gõ đọc bộ đếm) được ứng dụng xử lý SAU nó — màn hình in
        /// lại ký tự của nó (và các ký tự trước) chưa chứng minh gì; phải có ký tự gõ sau đó. (`.bypassed`: phím đi vòng đã chắc
        /// là trước phím đó.)
        var proofFrom = 0
    }
    /// iTerm2 / Terminal.app: shell in lại chậm bao lâu, đo từ chính các lần gõ (`EchoClock`, `probeEcho`).
    private(set) var echo = EchoClock()
    /// Lịch đo thời gian in lại (`probeEcho`).
    private var probe = EchoProbe()
    /// Mỗi lần đo là hai lần hỏi ứng dụng (đồng bộ, ngoài keyDown): chỉ đo khi còn có ích.
    private struct EchoProbe {
        /// Chuỗi đo đang chạy (chuỗi cũ thấy khác thì thôi).
        var serial = 0
        var running = false
        /// Mốc đầu của chuỗi đang chạy, và mốc sẽ xem kế tiếp (các mốc từ `start` tới trước nó đã xem mà chưa thấy chữ).
        var start = 0, next = 0
        /// Mốc đầu của chuỗi sau: ngay dưới mốc gần nhất thấy chữ — khỏi xem lại các mốc chắc chắn chưa có gì.
        var from = 0
        /// Số chuỗi liền nhau không thấy chữ trong 32 ms, kể từ lần thấy gần nhất.
        var misses = 0
        /// Thôi đo cho tới khi `guardCursor` thấy màn hình khớp (ứng dụng toàn màn hình, ô mật khẩu, shell in rất chậm).
        var idle = false
        /// Không bắt đầu chuỗi mới trước lúc này.
        var notBefore = -Double.infinity
    }
    /// Terminal đã từng báo con trỏ thật (vị trí khác 0: iTerm2, Terminal.app). Chưa từng mà đã báo 0 / không biết nhiều lần
    /// (Ghostty, Rex, Muxy, kitty…) thì thôi hỏi — xem `readCursor`.
    private var screenSeen = false
    private var blindReads = 0
    private var blindSkips = 0
    /// Phím đang xử lý (`handleTerminal`) đã đọc con trỏ chưa, và màn hình có đọc được không: các bước sau của cùng phím dùng
    /// lại, khỏi hỏi lại ứng dụng (mỗi lần hỏi là một lần chờ ứng dụng trả lời trong keyDown).
    private var keyScreen: Bool?
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
    private var inTerminal = false   // phím gần nhất được xử lý theo cách gõ terminal (`handle(terminal:)`)
    /// Vừa xoá lùi khi không có từ nào đang gõ (vd. "hoir " → xoá " " và "r" → còn "hoi"): ở phím chữ tiếp
    /// theo, đọc lại từ trước con trỏ để gõ tiếp (gõ "r" → "hỏi") thay vì bắt đầu từ mới.
    private var continueWordOnNextChar = false
    /// Ô nhập liệu đã từng báo đúng là đang có marked text của bộ gõ (`hasMarkedText`): từ đó, không thấy marked text nữa nghĩa
    /// là ứng dụng đã tự chốt / bỏ nó. Ô không báo (hay báo sai) thì không bao giờ dựa vào dấu hiệu này.
    private var markedReported = false
    /// Gõ trực tiếp: không còn biết chắc từ đang gõ nằm đâu (ô không cho biết con trỏ thật — Qt5 luôn báo 0; bộ đệm phía ứng
    /// dụng chưa cập nhật — Chromium / Electron khi trang xử lý chậm): các chữ còn lại của từ đi nguyên văn tới hết từ. Không
    /// đoán, nên không bao giờ thay sai chỗ (chữ ở giữa từ thành "ư", xoá mất chữ sau từ).
    private var untracked = false
    /// Số ký tự của từ đã đi nguyên văn kể từ lúc bật `untracked`. ⌫ hết chừng đó ký tự thì người dùng đang gõ lại: gỡ cờ, gõ
    /// tiếp như thường (không thì xoá từ rồi gõ lại vẫn ra phím gõ thô).
    private var untrackedLength = 0
    /// Gõ trực tiếp: phím kết thúc từ vừa rồi tới khi ô còn báo chậm (xem `lostTrack`), và con trỏ ô báo lúc đó. Đầu từ sau mà ô
    /// vẫn báo đúng con trỏ ấy thì nó chưa báo gì thêm — vị trí đọc được là của bản chụp cũ: từ đó đi nguyên văn. Ô đã báo
    /// con trỏ khác thì gõ như thường.
    private var staleAt: Int?
    /// Gõ trực tiếp: phím trước đi thẳng (ứng dụng tự chèn chữ) và vị trí con trỏ đọc được lúc đó — ở phím sau, con trỏ phải
    /// đã nhích.
    private var passedAt: Int?
    /// Lúc phím đó đi thẳng.
    private var passedWhen = 0.0
    /// Ô gõ trực tiếp báo chậm tới đâu thì còn tin là "chưa báo kịp": quá chừng này mà con trỏ vẫn ở chỗ cũ là chữ đã bị xoá thật
    /// (hay người dùng đã tự dời con trỏ — không ai click rồi gõ tiếp trong chừng đó).
    private static let directLag = 0.15
    /// Một đợt ô báo chậm (`laggyUntil`) kéo dài chừng này kể từ bằng chứng gần nhất; ngừng gõ `lagPause` thì từ sau lại được
    /// theo dõi (ô đã có thời gian báo).
    private static let lagEpisode = 1.0
    private static let lagPause = 0.3
    /// Lúc phím gần nhất của đường gõ trực tiếp.
    private var directKeyAt = -Double.infinity
    /// Ô vừa cho thấy nó đang báo chậm hơn phím (bằng chứng chắc: con trỏ không nhích sau phím đi thẳng, chữ ô cho đọc là một
    /// trạng thái cũ của từ…): tới lúc này, từ nào gõ liền tay ngay sau dấu cách của từ trước đều đi nguyên văn. Khi ô chậm đều
    /// vài phím, bản chụp cũ của nó tự khớp với chính nó — từ lặp lại ("ba ba2") trông y như đã báo kịp, sửa theo là sửa vào từ
    /// trước. Ngừng gõ một nhịp (`lagPause`) là hết.
    private var laggyUntil = -Double.infinity
    /// Chữ ô cho đọc ở lần thay vừa hỏng (đúng vị trí mà khác chữ bộ gõ nhớ), xem `perform`.
    private var replaceMismatch: String?
    /// Chữ của phím vừa đi thẳng ngay trước phím này (dấu cách, dấu câu, chữ) — ô đã báo kịp thì nó nằm ngay trước con trỏ.
    private var lastPassed: Character?
    /// Lần thay gần nhất của bộ gõ trong từ đang gõ: từ trước (`from`) và sau (`to`) lần thay. Bộ đệm phía ứng dụng chưa có
    /// lần thay đó thì vẫn cho đọc `from` (xem `staleWord`).
    private var lastEdit: (from: String, to: String)?
    /// Gõ trực tiếp: ⌫ đi thẳng khi không còn từ đang gõ, và vị trí con trỏ lúc đó — ở chữ sau, nếu con trỏ chưa lùi thì ô chưa
    /// xử lý xong ⌫: không đọc lại từ trước con trỏ (`continueWordOnNextChar`) từ bản chụp cũ.
    private var deletedAt: Int?
    /// Gạch chân: ô chỉ giữ một lần chèn chữ cho mỗi phím (GTK) hoặc nuốt phím ngay sau lần chốt (winit) — chốt từ cùng chữ của
    /// phím kết thúc từ trong một lần `insertText` (xem `handle(combinedCommit:)`).
    private var combinedCommit = false
    /// Gạch chân: ô báo đúng `hasMarkedText` ngay từ đầu (GTK, winit) — không cần chờ thấy nó báo một lần (`markedReported`).
    private var trustMarked = false
    /// Phím gần nhất được xử lý theo đường của ô web Chromium (`handleWeb`).
    private var inWeb = false
    /// Ô đã cho thấy không cho biết con trỏ thật (gõ trực tiếp: con trỏ nil / ở đầu văn bản): không thay chữ trực tiếp được ở
    /// đây — từ sau gõ bằng phần chữ đang soạn của InputMethodKit (`marked`), không đoán vị trí.
    public private(set) var blindLatched = false
    /// Con trỏ ô báo lúc bật `blindLatched`. Ô mù báo mãi một giá trị (nil, {0,0}, vùng chọn cũ của SDL); đầu từ sau mà ô báo con
    /// trỏ khác là ô thật (ô chậm vừa báo kịp, hay khung khác trong cùng view — terminal và editor của Zed): gỡ cờ.
    private var blindSel: (location: Int, length: Int)?

    /// Ô này (kể từ lần gắn / click gần nhất) đã từng báo con trỏ ở vị trí khác 0: nó báo con trỏ thật. Ô như vậy mà báo con trỏ
    /// ở đầu văn bản thì chữ đã bị xoá hay con trỏ đã bị dời thật — Telegram: ⏎ gửi tin được ứng dụng xử lý trước bộ gõ rồi
    /// xoá trắng ô (nhật ký máy người dùng 2026-11-26: từ đầu của tin kế tiếp đi nguyên văn, từ sau gạch chân). Ô "mù" (Qt 5,
    /// view tự vẽ) thì báo 0 mãi.
    private var sighted = false

    /// Bật cờ ô mù, nhớ con trỏ lúc đó.
    private func latchBlind(_ sel: (location: Int, length: Int)?) {
        if !blindLatched { trace?("gõ trực tiếp: ô không cho biết con trỏ — từ sau soạn bằng InputMethodKit") }
        blindLatched = true
        blindSel = sel
    }

    /// Bộ gõ được gắn vào ô khác / người dùng click: cờ ô mù không còn đúng.
    public func fieldChanged() {
        blindLatched = false
        blindSel = nil
        sighted = false
        holdMisses = 0
        laggyUntil = -Double.infinity
        markedReported = false      // ô khác có thể không báo `hasMarkedText`: không suy "ô đã tự chốt" từ ô cũ
    }

    /// Gõ trực tiếp, giữa từ đầu tiên ở một ô chưa từng báo con trỏ thật (`sighted`), ô lại không cho biết con trỏ: nó vừa được
    /// gắn và còn trả lời tạm (gõ ngay lúc vừa mở Raycast / vừa chuyển ứng dụng — nhật ký máy người dùng 2026-11-26: phím thứ
    /// hai tới trước cả `setValue` của InputMethodKit), hoặc là ô mù thật. Phím không đi nguyên văn ngay mà được GIỮ lại cùng
    /// các chữ kế tiếp của từ; `engine` gõ tiếp từ định gõ. Ô trả lời thật — đúng chỗ, đúng chữ của phần đang có trên màn hình
    /// (`shown`) — thì phần đó được thay bằng cả từ trong một lần. Trong lúc giữ bộ gõ không gửi gì cho ô, nên thứ ô báo sau đó
    /// chỉ có thể là những gì đã gửi trước. Hết hạn (70 ms) hay hết từ mà ô vẫn vậy thì các phím đã giữ được chèn tại con trỏ
    /// thật của ô: đúng chữ có dấu nếu phần đang có trên màn hình không phải đổi, không thì đúng các phím đã gõ — không mất
    /// phím nào, không sửa nhầm chỗ; chèn xong mà con trỏ ô báo vẫn ở đầu văn bản thì đó là ô mù.
    /// Không dùng cho ô đã báo con trỏ thật mà báo CHẬM (bộ đệm phía ứng dụng): ở đó vị trí đầu từ đọc được cũng có thể cũ —
    /// phần còn lại của từ đi nguyên văn như trước (`loseTrack`); ô web Chromium / Gecko có đường riêng (`handleWeb`).
    private struct Hold {
        /// Từ như ô đang có: mọi thứ đã gửi cho ô trước khi giữ.
        var shown: String
        /// Các phím đang giữ.
        var keys: [Character]
    }
    private var hold: Hold?
    private var holdSerial = 0
    /// Số lần giữ phím mà ô không trả lời thật, kể từ lần gắn: đã một lần thì thôi giữ ở ô này.
    private var holdMisses = 0
    private var web: WebChain?
    /// Phím vừa rồi là ⌫ trong chuỗi và từ đang gõ trống: chữ sau gõ tiếp từ nằm ngay trước con trỏ (chữ của chuỗi).
    private var webResumeArmed = false
    /// Lần sửa đầu của một chuỗi chưa có bằng chứng vị trí, đang chờ trang báo (`deferWebEdit`).
    private var webPending: (old: String, new: String, typed: Character)?
    /// Từ đang gõ tạm đi nguyên văn ở ô web: chữ của nó hiện có trên trang (đúng các phím đã gõ — chưa lần sửa nào được gửi vì
    /// bộ gõ chưa chắc từ nằm ở đâu), trong khi `engine` vẫn giữ từ định gõ. Ngay khi bộ đệm cho thấy chắc chắn từ nằm ở đâu
    /// (`webCatchUp`) thì chữ nguyên văn được thay bằng từ định gõ trong một lần, rồi gõ tiếp như thường. nil: không có.
    private var webShadow: String?
    /// Các từ đã gõ xong trong lúc chưa có bằng chứng vị trí, còn nằm nguyên văn trên trang: `raw` là phần CUỐI của `webBefore`
    /// đúng như trang đang có (kèm ký tự ngăn cách), `intended` là chữ nó phải thành. Có bằng chứng thì được sửa trong cùng
    /// một lần thay với từ đang gõ (`applyWebEdit`) — không từ nào ở lại dạng thô chỉ vì trang báo chậm lúc gõ nó.
    private var webOwed: (raw: String, intended: String)?
    /// Lần đọc gần nhất mà bộ đệm cho thấy TRỌN chữ của chuỗi nằm ngay trước con trỏ của nó: chỗ đầu chuỗi suy ra, và độ dài
    /// chuỗi (đơn vị UTF-16) lúc đó. Xem `webProve`.
    private var webWitness: (at: Int, length: Int)?
    /// Đang trong lúc xử lý một phím của ô web (`handleWeb`).
    private var webInKey = false
    /// Trong phím đang xử lý, bộ gõ đã chèn chữ KHÔNG kèm vùng thay. Chromium gom chữ như vậy tới hết keyDown mới gửi cho
    /// trang (`textToBeInserted`), còn lần thay có vùng thì gửi ngay: thay chữ theo vị trí trong cùng phím đó sẽ tới trang
    /// TRƯỚC chữ vừa chèn (IME Lab 44236364944: chèn "9" rồi thay "d9" bằng "đ" — trang ra "đ9"). Xem `webCatchUp`.
    private var webInsertedInKey = false
    private weak var webPendingClient: TextClient?
    private var webSerial = 0
    /// Bộ đệm đang ở đúng trạng thái MỚI NHẤT của chuỗi và ô có vùng bôi đen bắt đầu ngay ở con trỏ (gợi ý tự điền): độ dài vùng
    /// đó, đọc ở `webRead`; chỉ dùng khi chưa có gì đổi từ lúc đọc (`webTailStates`). Xem `webReplace`.
    private var webTail = 0
    private var webTailStates = 0
    /// Rào đồng bộ (`TextClient.settle`) vừa qua: trang đã xử lý xong mọi thứ gửi trước `at`; `states` là số trạng thái của
    /// chuỗi lúc đó (chưa gửi thêm gì từ đó). Sau một nhịp (`webSettleRead`) bộ đệm cho thấy đúng con trỏ thật của trang —
    /// không còn gì "có thể chưa báo", không có chữ tự đoán: đọc là biết chuỗi nằm ở đâu (`webTryAnchor`).
    private var webSettle: (states: Int, at: Double)?
    private var webSettleSerial = 0
    /// Trang không trả lời kịp câu hỏi đồng bộ (đang treo): thôi hỏi tới lúc này.
    private var webSettleRetryAt = -Double.infinity
    /// Ô này đã trả lời được câu hỏi đồng bộ ít nhất một lần.
    private var webSettles = false
    /// Lúc gần nhất có phím bộ gõ không biết tác dụng (⌥⌫, ⌘⌫, ⌫, mũi tên, phím tắt…) hay click bộ gõ không thấy.
    private var webUnknownAt = -Double.infinity
    /// Sau phím cuối chừng này giây thì đặt rào (phím đã rời keyDown, chữ của nó đã tới trang).
    private static let webSettleAfter = 0.006
    /// Từ lúc rào qua tới lúc đọc bộ đệm: ứng dụng cần quay lại vòng lặp của nó để nhận các báo cáo trang đã gửi.
    private static let webSettleRead = 0.008
    /// Trang có thể đẩy chữ / con trỏ mới sang Chromium ở khung hình kế tiếp sau khi xử lý phím (VS Code): rào đặt sớm hơn
    /// chừng này sau một phím không biết tác dụng thì chưa chắc thấy tác dụng của nó.
    private static let webPageSlack = 0.05

    public init() {}

    /// Đang có phần gạch chân của bộ gõ chưa chốt trong ô nhập liệu.
    public var composing: Bool { marked && !preedit.isEmpty }

    /// Ghi log chẩn đoán (bản Debug của bộ gõ gắn vào DebugLog).
    public var log: ((String) -> Void)?
    /// Sự kiện chẩn đoán KHÔNG chứa chữ người dùng gõ (chỉ vị trí, độ dài, quyết định của bộ gõ ở ô web và khi gõ trực tiếp mà
    /// ô báo chậm): bản phát hành ghi vào nhật ký sự kiện khi người dùng bật (`DebugLog.event`).
    public var trace: ((String) -> Void)?

    /// Ô web của Gecko (Firefox, Zen, LibreWolf…) — đi cùng đường `handleWeb` với Chromium, khác ở mấy điểm (ContentCache.cpp,
    /// TextInputHandler.mm, PBrowser.ipdl):
    /// - bộ đệm phía trình duyệt KHÔNG tự đoán: nó chỉ đổi khi trang báo về. Bộ đệm cho thấy một ký tự của chuỗi là trang đã
    ///   báo ký tự đó (ở Chromium một ký tự có thể chỉ là chữ tự đoán — phải thấy hai);
    /// - không hỏi đồng bộ sang trang được (`TextClient.settle`): mọi câu hỏi được trả lời từ bộ đệm ở tiến trình cha. Bù lại,
    ///   chính ký tự đầu của chuỗi làm rào: bộ đệm cho thấy nó là trang đã xử lý mọi phím / click trước nó (`webPollProof`);
    /// - lần thay có vùng là "đặt vùng chọn" rồi "chèn chữ", và bước đặt vùng chọn bị BỎ QUA khi vùng thay trùng vùng chọn
    ///   trình duyệt đang nhớ (xem `webReplace`);
    /// - bộ gõ sửa chữ trong keyDown của một phím tắt có ⌘ thì chính phím tắt đó bị nuốt (IME Lab 45776448337: gõ dở "tie61"
    ///   rồi ⌘⌫ — lần khôi phục "tiế" → "tie61" của bộ gõ làm ⌘⌫ không xoá gì): không sửa cuối từ ở phím không ra chữ.
    /// Phím và lần sửa vẫn tới trang theo đúng thứ tự (cùng một hàng đợi ưu tiên nhập liệu), như Chromium.
    public var webGuessFree = false

    /// Ô luôn báo đúng con trỏ và chữ tại lúc hỏi (ô Java gõ trực tiếp: mỗi câu hỏi đi qua luồng sự kiện của Java, sau mọi
    /// phím và lần sửa trước đó). Con trỏ ở chỗ khác chỗ bộ gõ nghĩ thì đơn giản là nó đã bị dời — vd. focus sang ô khác trong
    /// cùng cửa sổ Java (cả cửa sổ là một ô với bộ gõ, không có lần gắn lại nào): đọc lại từ ở chỗ mới, không suy ra "ô không
    /// cho biết con trỏ" hay "ô chưa xử lý xong phím" như với ô có bộ đệm chậm.
    public var cursorReliable = false

    /// Ô chỉ nhận trọn vẹn MỘT lần sửa của bộ gõ cho mỗi phím, và chỉ khi bộ gõ giữ phím đó (ô Java gõ trực tiếp):
    /// - JetBrains Runtime giữ chữ của lần `insertText` CUỐI trong lúc xử lý phím làm chữ của chính phím đó. Bộ gõ sửa từ rồi để
    ///   phím đi thẳng thì chữ của phím (dấu cách) đè mất chữ sửa, vùng đã chọn bị thay bằng dấu cách — IME Lab 44247794337:
    ///   Telex "keeper " ra "ke " (lần khôi phục cuối từ), cũng như "thuở " / "huơ ";
    /// - AWT gốc + trợ thủ Java: sau lần sửa, phím không ra chữ (⏎, ⌫, mũi tên) của chính lần bấm đó bị AWT bỏ.
    /// Ở các ô này: lần sửa cuối từ gộp chung chữ của phím kết thúc từ trong một lần thay và bộ gõ giữ phím; phím kết thúc từ
    /// không ra chữ thì bỏ lần sửa cuối từ (chữ để nguyên như đang hiện, không mất gì); ⌫ làm dời dấu thì bộ gõ tự xoá luôn ký
    /// tự cuối trong cùng lần thay.
    public var singleEditPerKey = false

    public func reset() {
        resetWeb()
        hold = nil
        holdSerial &+= 1
        engine.reset()
        onLine = nil
        suspect = nil
        suspectSettled = false
        endMarkedWord()
        continueWordOnNextChar = false
        endDirectWord()
        staleAt = nil
    }

    /// Bỏ những gì biết về từ gõ trực tiếp (xem `untracked`, `passedAt`, `lastEdit`).
    private func endDirectWord() {
        untracked = false
        untrackedLength = 0
        passedAt = nil
        lastEdit = nil
        deletedAt = nil
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
    /// `combinedCommit` (GTK, winit): phím kết thúc từ đang gạch chân mà ra chữ (`keyText`: dấu cách, dấu câu, ⌥+chữ…) thì chốt
    /// từ cùng chữ đó trong một lần `insertText` và bộ gõ giữ phím; phím không ra chữ (⏎, ⇥, mũi tên…) thì chốt từ rồi cho phím
    /// đi, kèm gỡ marked text nếu `clearAfterCommit` (winit nuốt phím ngay sau lần chốt khi còn trạng thái "vừa chốt").
    /// `trustMarked`: ô báo đúng `hasMarkedText` ngay từ đầu (GTK, winit).
    public func handle(_ key: Key, _ client: TextClient, options: EngineOptions, forceMarked: Bool,
                       qtApp: Bool = false, terminal: TerminalStyle? = nil, repeatDelay: Double? = nil,
                       earlyCommit: Bool = false, gap: KeyGap = .none, legacy: String? = nil,
                       combinedCommit: Bool = false, clearAfterCommit: Bool = false,
                       trustMarked: Bool = false, keyText: String? = nil, web: Bool = false) -> Bool {
        if blindLatched, terminal == nil, !web, engine.isEmpty, !marked, case .char = key {
            let sel = client.selectedRange()
            if sel?.location != blindSel?.location || sel?.length != blindSel?.length {
                log?("ô báo con trỏ \(String(describing: sel)) khác lúc nhận là ô mù (\(String(describing: blindSel))) — gõ lại như ô thường")
                fieldChanged()
            }
        }
        // Ô mù (không cho biết con trỏ): không thay chữ trực tiếp được — soạn từ bằng InputMethodKit còn hơn chữ đi nguyên văn.
        let callerForcesMarked = forceMarked
        let forceMarked = forceMarked || (blindLatched && terminal == nil && !web)
        if web {
            inTerminal = false
            if marked || literalTail { commit(client) }   // đang gạch chân: chốt phần đang soạn, không bỏ (mất chữ)
            inWeb = true
            return handleWeb(key, client, options: options, gap: gap)
        }
        if inWeb { inWeb = false; resetWeb() }
        self.qtApp = qtApp
        self.combinedCommit = combinedCommit
        self.trustMarked = trustMarked
        self.earlyCommit = earlyCommit
        inTerminal = terminal != nil
        if let terminal {
            if marked || literalTail { commit(client) }     // vừa đổi từ chế độ gạch chân: chốt phần đang soạn
            return handleTerminal(key, client, options: options, style: terminal, repeatDelay: repeatDelay, gap: gap,
                                  legacy: legacy)
        }
        if marked, !preedit.isEmpty {
            if client.hasMarkedText() {
                markedReported = true
            } else if markedReported || trustMarked {
                // Ứng dụng đã tự chốt / bỏ phần gạch chân mà bộ gõ không thấy (JetBrains Runtime tự chốt khi click, ứng dụng
                // đổi ô hay đổi chữ bằng chương trình…): phần đó không còn để sửa. Dựng lại cả từ ở chỗ mới sẽ thành chữ
                // đôi — bắt đầu từ mới.
                log?("marked text đã mất ngoài tầm bộ gõ: bỏ từ \(engine.displayed.debugDescription)")
                reset()
            }
        }
        let sinceKey = client.currentTime() - directKeyAt
        let passedBefore = lastPassed
        lastPassed = nil
        defer { directKeyAt = client.currentTime() }
        if hold != nil, !holdRelease(client) {
            // Ô vẫn chưa báo kịp: chữ kế tiếp của từ cũng được giữ; phím khác thì trả các phím đã giữ cho ô trước nó.
            if case let .char(ch) = key, Self.continuesWord(ch), engine.process(ch) != nil {
                hold?.keys.append(ch)
                holdWatch(client)
                return true
            }
            holdGiveUp(client)
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
        if untracked {
            // Từ không theo dõi được (xem `untracked`): chữ trong từ đi nguyên văn, phím khác kết thúc từ.
            switch key {
            case let .char(ch) where Self.continuesWord(ch):
                untrackedLength += 1
                return false
            case .backspace:
                untrackedLength -= 1
                if untrackedLength <= 0 {
                    // Đã xoá hết phần đi nguyên văn: người dùng gõ lại. Chữ sau đọc lại từ trước con trỏ (nếu còn chữ của từ)
                    // rồi gõ như thường, như sau mọi ⌫ khi không còn từ đang gõ.
                    let at = client.selectedRange()?.location
                    reset()
                    continueWordOnNextChar = true
                    deletedAt = at
                }
                return false
            case .char, .other:
                reset()
            }
        }
        switch key {
        case .other:
            continueWordOnNextChar = false
            staleAt = nil
            if combinedCommit, marked, !engine.isEmpty {
                return endMarkedWord(with: keyText, client, clear: clearAfterCommit)
            }
            if singleEditPerKey, !marked {
                dropWord()                      // phím không ra chữ: không sửa gì trong phím này
            } else {
                breakWord(client)
            }
            return false
        case .backspace:
            staleAt = nil
            let handled = backspace(client)
            if engine.isEmpty && !marked {
                continueWordOnNextChar = true
                if !handled { deletedAt = client.selectedRange()?.location }   // trước khi ứng dụng xoá
            }
            return handled
        case let .char(ch):
            var sel: (location: Int, length: Int)?
            if engine.isEmpty {
                engine.options = options
                let deleted = deletedAt
                endDirectWord()
                if forceMarked {
                    marked = true            // gạch chân: không cần vị trí con trỏ (bớt một lần hỏi ứng dụng)
                    anchor = 0
                    staleAt = nil
                } else {
                    sel = client.selectedRange()
                    if let sel, sel.location > 0 { sighted = true }
                    marked = sel == nil
                    anchor = sel?.location ?? 0
                    if let stale = staleAt, let sel, sel.location == stale, sel.length == 0 {
                        // Ô vẫn báo đúng con trỏ cũ của lúc phím kết thúc từ trước tới: chưa có gì mới từ ô.
                        if Self.continuesWord(ch) {
                            staleAt = nil
                            continueWordOnNextChar = false
                            laggyUntil = client.currentTime() + Self.lagEpisode
                            return loseTrack("ô chưa báo gì từ phím kết thúc từ trước (con trỏ \(stale))")
                        }
                    } else {
                        staleAt = nil
                    }
                    if Self.continuesWord(ch), let sel, sel.length == 0 {
                        let now = client.currentTime()
                        // Ô đang trong một đợt báo chậm và từ này gõ liền sau dấu cách của từ trước: vị trí đầu từ đọc được không
                        // tin được. (Sau ⌫ / phím khác thì không: xoá từ đi nguyên văn rồi gõ lại phải ra dấu.)
                        if now < laggyUntil, passedBefore == " ", sinceKey < Self.lagPause {
                            laggyUntil = now + Self.lagEpisode
                            continueWordOnNextChar = false
                            return loseTrack("ô đang báo chậm (con trỏ \(sel.location))")
                        }
                        // Dấu cách vừa đi thẳng mà ô chưa cho thấy nó trước con trỏ: ô đang báo chậm, vị trí đầu từ đọc được là
                        // của bản chụp cũ — từ bắt đầu ở đó sẽ bị sửa lệch một ký tự ("ca61p" ra "cáp…6"). (Chỉ dấu cách: ô có thể
                        // tự đổi dấu câu vừa gõ — nháy kép thành nháy cong, "--" thành gạch dài.)
                        if passedBefore == " ", sinceKey < Self.directLag, sel.location > 0,
                           let shown = client.text(location: sel.location - 1, length: 1), shown != " ", shown != "\u{a0}" {
                            laggyUntil = now + Self.lagEpisode
                            continueWordOnNextChar = false
                            return loseTrack("ô chưa báo dấu cách vừa đi thẳng (con trỏ \(sel.location))")
                        }
                    }
                }
                committed = ""
                preedit = ""
                if continueWordOnNextChar && !marked {
                    if let d = deleted, sel?.location == d {
                        log?("gõ trực tiếp: con trỏ chưa lùi sau ⌫ (\(d)) — không đọc lại từ trước con trỏ")
                    } else if !resync(client), Self.continuesWord(ch) {
                        return loseTrack("ngay trước con trỏ là chữ không nạp lại được")
                    }
                }
                continueWordOnNextChar = false
            } else if !marked {
                sel = client.selectedRange()
                if let sel, sel.location > 0 { sighted = true }
                if let (reason, lag) = lostTrack(sel, now: client.currentTime()) {
                    if lag { laggyUntil = client.currentTime() + Self.lagEpisode }
                    guard Self.continuesWord(ch) else {
                        // Phím này kết thúc từ: không còn chữ nào của từ để đi nguyên văn. Bật `untracked` ở đây thì cả từ SAU
                        // (gõ ngay sau dấu cách / dấu ngoặc này) đi nguyên văn theo.
                        log?("gõ trực tiếp: \(reason) — bỏ từ \(engine.displayed.debugDescription), phím kết thúc từ đi thẳng")
                        if blindReason(sel) { latchBlind(sel) }
                        engine.reset()
                        endDirectWord()
                        staleAt = sel?.location
                        return false
                    }
                    if blindReason(sel) {
                        // Ô chưa từng báo con trỏ thật mà nay không cho biết con trỏ: hoặc nó vừa được gắn, còn trả lời tạm (gõ
                        // ngay lúc vừa chuyển ứng dụng) — giữ phím một nhịp chờ nó trả lời thật (`Hold`); hoặc là ô mù — đã
                        // một lần chờ không được thì từ sau soạn bằng InputMethodKit. (Con trỏ đứng yên kiểu SDL thì không: ở
                        // đó phần đang soạn đổi con trỏ báo, cờ sẽ bật / gỡ xen kẽ.)
                        if holdMisses == 0, holdStart(ch, client, reason: reason) { return true }
                        latchBlind(sel)
                    }
                    return loseTrack(reason)
                }
                if !inSync(sel) {
                    if let sel, sel.length == 0, !cursorReliable, let sure = staleInWord(sel, client, sinceKey: sinceKey) {
                        // Ô đang báo một trạng thái cũ của chính từ này (chậm hơn phím): đọc lại từ ở đó là đọc bản chụp cũ, sửa
                        // theo nó là sửa nhầm chỗ.
                        if sure { laggyUntil = client.currentTime() + Self.lagEpisode }
                        guard Self.continuesWord(ch) else {
                            engine.reset()
                            endDirectWord()
                            staleAt = sel.location
                            return false
                        }
                        return loseTrack("ô còn báo một trạng thái cũ của từ (con trỏ \(sel.location))")
                    }
                    // Con trỏ đã bị dời (vị trí không đổi trong keyDown này): đọc lại từ ở chỗ mới.
                    if !resync(client), Self.continuesWord(ch) {
                        return loseTrack("ngay trước con trỏ là chữ không nạp lại được")
                    }
                }
            }
            let before = engine.displayed
            guard let action = engine.process(ch) else {
                guard !engine.isEmpty else {
                    // Không có từ nào bắt đầu (End, mũi tên, dấu câu… ở đầu ô): không giữ chế độ gạch chân vừa chọn cho từ.
                    // (Ô mù — `blindLatched` — cũng vậy: giữ cờ thì đầu từ sau không còn xét gỡ cờ ô mù.)
                    if !callerForcesMarked { marked = false }
                    if !marked, Self.producesText(ch), !"\r\n\t".contains(ch) { lastPassed = ch }
                    return false
                }
                if combinedCommit, marked {
                    return endMarkedWord(with: Self.producesText(ch) ? keyText ?? String(ch) : nil, client,
                                         clear: clearAfterCommit)
                }
                if singleEditPerKey, !marked {
                    return breakWord(with: Self.producesText(ch) ? keyText ?? String(ch) : nil, client)
                }
                let direct = !marked
                breakWord(client)
                if direct, Self.producesText(ch), !"\r\n\t".contains(ch) { lastPassed = ch }
                return false
            }
            if marked { return showMarked(ch, action, before: before, client) }
            let handled = perform(action, client, retry: ch, sel: sel)
            // Phím đi thẳng: ứng dụng tự chèn chữ, con trỏ phải nhích ở phím sau (`lostTrack`).
            passedAt = handled || engine.isEmpty ? nil : sel?.location
            passedWhen = client.currentTime()
            if !handled, !untracked { lastPassed = ch }
            return handled
        }
    }

    /// Gõ trực tiếp, giữa từ, con trỏ ô báo không ở cuối từ: ô đang cho thấy một trạng thái CŨ của chính từ đang gõ (ô báo chậm
    /// hơn phím) chứ con trỏ không bị dời? nil: không. true: chắc chắn — con trỏ nằm giữa từ, chữ từ đầu từ tới đó đúng là
    /// phần đầu của từ, và phím trước mới gõ đây (người dùng không kịp click vào giữa từ rồi gõ tiếp). false: có thể — con trỏ
    /// ở ngay đầu từ, phím trước gõ chưa quá `directLag`: chưa chữ nào của từ được báo (lâu hơn thì từ đã bị xoá thật — ứng
    /// dụng tự xoá ô — và phím này bắt đầu từ mới ở đó).
    private func staleInWord(_ sel: (location: Int, length: Int), _ client: TextClient, sinceKey: Double) -> Bool? {
        let word = Array(engine.displayed.utf16)
        let k = sel.location - anchor
        if k == 0 { return !word.isEmpty && sinceKey < Self.directLag ? false : nil }
        guard k > 0, k < word.count, sinceKey < Self.lagEpisode / 2,
              let shown = client.text(location: anchor, length: k), Array(shown.utf16) == Array(word[..<k]) else { return nil }
        return true
    }

    /// Gõ trực tiếp: thôi theo dõi từ đang gõ — phím này và các chữ còn lại của từ đi nguyên văn (xem `untracked`).
    private func loseTrack(_ reason: String) -> Bool {
        log?("gõ trực tiếp: \(reason) — các chữ còn lại của từ \(engine.displayed.debugDescription) đi nguyên văn")
        trace?("gõ trực tiếp: \(reason) — phần còn lại của từ đi nguyên văn")
        engine.reset()
        untracked = true
        untrackedLength = 1
        return false
    }

    // MARK: Giữ phím khi ô báo chậm

    /// Bắt đầu giữ: `ch` là chữ kế tiếp của từ, ô chưa báo kịp phần đã gửi. false: `ch` không nối được vào từ (nơi gọi xử lý
    /// như trước).
    private func holdStart(_ ch: Character, _ client: TextClient, reason: String) -> Bool {
        let shown = engine.displayed
        guard engine.process(ch) != nil else { return false }
        log?("gõ trực tiếp: \(reason) — giữ phím, chờ ô báo kịp \(shown.debugDescription)")
        trace?("gõ trực tiếp: \(reason) — giữ phím, chờ ô báo kịp")
        hold = Hold(shown: shown, keys: [ch])
        passedAt = nil
        holdWatch(client)
        return true
    }

    /// Xem lại ô vài lần sau phím vừa giữ; lần cuối mà ô vẫn chưa trả lời thật thì trả phím cho ô (`holdGiveUp`).
    private func holdWatch(_ client: TextClient) {
        holdSerial &+= 1
        let serial = holdSerial
        let delays = [0.004, 0.012, 0.03, 0.07]
        for (i, delay) in delays.enumerated() {
            client.schedule(after: delay) { [weak self, weak client] in
                guard let self, let client, self.holdSerial == serial, self.hold != nil else { return }
                if !self.holdRelease(client), i == delays.count - 1 { self.holdGiveUp(client) }
            }
        }
    }

    /// Ô đã báo đúng chỗ và đúng chữ của phần đang có trên màn hình: thay nó bằng cả từ, hết giữ.
    private func holdRelease(_ client: TextClient) -> Bool {
        guard let h = hold, let sel = client.selectedRange(), sel.length == 0 else { return false }
        let n = h.shown.utf16.count
        guard sel.location == anchor + n, n == 0 || client.text(location: anchor, length: n) == h.shown else { return false }
        hold = nil
        holdSerial &+= 1
        holdMisses = 0
        if sel.location > 0 { sighted = true }
        log?("gõ trực tiếp: ô đã báo kịp — thay \(h.shown.debugDescription) bằng \(engine.displayed.debugDescription)")
        trace?("gõ trực tiếp: ô đã báo kịp — sửa \(h.keys.count) phím đã giữ")
        if !replace(h.shown, engine.displayed, client, sel: sel) {
            // Chữ vừa đọc còn đúng mà không thay được: trả phím như khi ô không báo kịp.
            hold = h
            return false
        }
        return true
    }

    /// Ô vẫn không trả lời thật: trả các phím đã giữ cho ô. Chèn phím đầu tại con trỏ thật của ô (không cần biết vị trí) rồi xem
    /// con trỏ ô báo:
    /// - đã nhích khỏi đầu văn bản: ô báo con trỏ thật, trước đó chữ cũ đã bị xoá thật (hay ô vừa trả lời được) — đọc lại từ
    ///   đang nằm trước con trỏ, gõ nốt các phím còn giữ lên đó như thường (có dấu);
    /// - vẫn ở đầu văn bản: ô mù — các phím còn lại đi nguyên văn, từ sau soạn bằng InputMethodKit.
    private func holdGiveUp(_ client: TextClient) {
        guard let h = hold, let first = h.keys.first else { return }
        hold = nil
        holdSerial &+= 1
        holdMisses += 1
        engine.reset()
        endDirectWord()
        client.insertText(String(first))
        let rest = h.keys.dropFirst()
        let after = client.selectedRange()
        if let after, after.location > 0, after.length == 0 {
            sighted = true
            log?("gõ trực tiếp: ô đã báo con trỏ thật (\(after.location)) — gõ lại \(rest.count) phím còn giữ")
            trace?("gõ trực tiếp: ô đã báo con trỏ thật — gõ lại \(h.keys.count) phím đã giữ")
            if resync(client) {
                let base = engine.displayed
                var ok = true
                for k in rest where ok { ok = engine.process(k) != nil }
                if ok {
                    if engine.displayed != base, !replace(base, engine.displayed, client) {
                        client.insertText(String(rest))
                        engine.reset()
                        untracked = !rest.isEmpty
                        untrackedLength = rest.count
                    }
                    return
                }
            }
            engine.reset()
        } else if !sighted {
            latchBlind(after)
        }
        log?("gõ trực tiếp: ô không trả lời thật — các phím \(String(h.keys).debugDescription) đi nguyên văn")
        trace?("gõ trực tiếp: ô không trả lời thật — \(h.keys.count) phím đã giữ đi nguyên văn")
        if !rest.isEmpty { client.insertText(String(rest)) }
        untracked = true
        untrackedLength = h.keys.count
    }

    /// Ký tự còn nằm trong một từ (chữ, số — VNI dùng số làm dấu, `[ ] { }` — Telex dùng cho ư ơ).
    private static func continuesWord(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || "[]{}".contains(ch)
    }

    /// Gõ trực tiếp, giữa từ: ô nhập liệu cho thấy điều bộ gõ không thể đoán chắc — trả về lý do, khi đó không sửa gì nữa trong
    /// từ này. nil: theo dõi tiếp (kể cả khi con trỏ đã bị dời — `resync` đọc lại từ ở chỗ mới).
    /// - phím trước (chữ hay ⌫) đi thẳng mà con trỏ chưa nhích: ứng dụng chưa xử lý xong phím đó (Chromium / Electron khi trang
    ///   chậm: vị trí và chữ đọc được đến từ bộ đệm chưa cập nhật), hay không cho biết con trỏ thật (Qt5: luôn báo 0);
    /// - con trỏ ở đúng chỗ của từ trước lần thay gần nhất của bộ gõ (bộ đệm chưa có lần thay đó);
    /// - ô báo con trỏ ở đầu văn bản trong khi từ đang gõ nằm sau đó (Qt5).
    /// `lag`: lý do là bằng chứng chắc rằng ô đang báo chậm (xem `laggyUntil`).
    private func lostTrack(_ sel: (location: Int, length: Int)?, now: Double) -> (reason: String, lag: Bool)? {
        guard let sel else { return ("ô không còn cho biết vị trí con trỏ", false) }
        let expected = anchor + engine.displayed.utf16.count
        if sel.location == expected || cursorReliable { return nil }
        // (⌘A chọn từ 0 thì là dời con trỏ thật: đọc lại. Ô đã từng báo con trỏ khác 0 cũng vậy: chữ đã bị xoá / con trỏ đã bị
        // dời thật — đọc lại từ ở đầu ô, phím này bắt đầu từ mới.)
        if sel.location == 0, sel.length == 0, expected > 0, !sighted {
            return ("ô báo con trỏ ở đầu văn bản", false)
        }
        if let at = passedAt, sel.location == at {
            // Từ mới có một chữ mà con trỏ vẫn ở đầu từ sau một lúc lâu: không phải ô báo chậm — chữ đó đã bị xoá (Telegram: gửi
            // tin một chữ "k" bằng ⏎, ô bị xoá trắng mà bộ gõ không thấy ⏎). Đọc lại ở đó, phím này bắt đầu từ mới.
            if at == anchor, sighted, now - passedWhen >= Self.directLag { return nil }
            return ("con trỏ chưa nhích sau phím đi thẳng (\(at))", at != anchor)
        }
        if let stale = staleWord(engine.displayed), stale.utf16.count != engine.displayed.utf16.count,
           sel.location == anchor + stale.utf16.count {
            return ("ô chưa có lần thay trước của bộ gõ (con trỏ \(sel.location))", true)
        }
        return nil
    }

    /// Chữ của từ mà ô nhập liệu cho thấy nếu nó chưa có lần thay gần nhất của bộ gõ (`lastEdit`); các chữ đi thẳng sau lần
    /// thay đó nằm ở cuối cả hai.
    private func staleWord(_ word: String) -> String? {
        guard let edit = lastEdit, word.hasPrefix(edit.to) else { return nil }
        return edit.from + word.dropFirst(edit.to.count)
    }

    /// Ứng dụng / InputMethodKit muốn chốt (`commitComposition`) mà ô nhập liệu không mất focus: ứng dụng tự đổi văn bản hay
    /// vùng chọn, InputMethodKit gọi lại quanh lúc gắn bộ gõ… Gõ trực tiếp (không gạch chân, không phải terminal) thì không có
    /// gì để chốt: nếu từ đang gõ vẫn nằm nguyên ngay trước con trỏ thì giữ — mọi lần sửa sau đều đối chiếu lại với màn hình
    /// (`inSync`, `replace`). Bỏ từ ở đây làm các phím vừa gõ mất tác dụng (vd. 'd' của "d9" → "d9ẳng").
    public func commitRequested(_ client: TextClient?) {
        if inWeb, let client {
            // Ô web: bộ gõ tự giữ từ đang gõ — chỉ bỏ khi trang cho thấy chữ đã bị đổi bởi thứ khác.
            if webPending != nil { flushWebPending(client, final: true) }
            if webNeedsProof { webCatchUp(client, settled: webSettled(client)) }
            if engine.isEmpty { return }
            if case .foreign = webRead(client, word: webShadow ?? engine.displayed) { commit(client) }
            return
        }
        if hold != nil { return }                       // đang giữ phím chờ ô báo: không có gì để chốt
        if !marked, !literalTail, !inTerminal, pending == nil, !engine.isEmpty, let client, wordOnScreen(client) {
            log?("commitComposition: gõ trực tiếp, từ \(engine.displayed.debugDescription) vẫn trước con trỏ — giữ")
            return
        }
        commit(client)
    }

    /// Gõ trực tiếp: từ đang gõ vẫn nằm ngay trước con trỏ, đúng như bộ gõ nhớ.
    private func wordOnScreen(_ client: TextClient) -> Bool {
        guard let sel = client.selectedRange(), sel.length == 0, inSync(sel) else { return false }
        let word = engine.displayed
        let n = word.utf16.count
        guard n > 0, sel.location >= n, let text = client.text(location: sel.location - n, length: n) else { return false }
        return text == word
    }

    /// Chốt từ đang gõ (khi ô nhập liệu mất focus, click chuột...).
    public func commit(_ client: TextClient?) {
        if let client, hold != nil, !holdRelease(client) { holdGiveUp(client) }
        if let client, webPending != nil { flushWebPending(client, final: true) }
        if let client, webNeedsProof { webCatchUp(client, settled: webSettled(client)) }
        if let client, pending != nil {
            if client.lateEditSafe() {
                settlePending(client)
            } else {
                // Có phím tắt / click sau lần sửa (vd. ⌘V): lần sửa có thể đã lỗi thời — bỏ, và gỡ luôn marked text rỗng
                // (U+200B) đang giữ phím ở Ghostty, không thì ⏎ / ⌫ / mũi tên kế tiếp bị nuốt.
                if pendingClient === client, client.hasMarkedText() { client.setMarkedText("") }
                clearPending()
            }
        }
        if marked, !engine.isEmpty, let client, !markedTextLost(client) {
            insertMarkedTail(engine.finishWord().text, client)
        }
        reset()
    }

    /// Ô đã tự chốt / bỏ phần gạch chân của bộ gõ (ô vốn báo đúng `hasMarkedText`): chốt lại sẽ chèn chữ lần hai.
    private func markedTextLost(_ client: TextClient) -> Bool {
        (markedReported || trustMarked) && !preedit.isEmpty && !client.hasMarkedText()
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
        keyScreen = nil
        defer { keyScreen = nil }
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
                    // dán), bỏ. Phím chữ thì tự gửi; phím có byte riêng (⏎, ⌫, ←, Home…) thì gửi các byte đó; phím không
                    // có (⇧⏎, ⌥…) chỉ gỡ marked text (Ghostty nuốt phím này — hiếm: lần sửa phải còn chờ đúng lúc đó).
                    log?("deferred: bỏ lần sửa chưa tới vì có phím / click đi vòng bộ gõ")
                    if let ch = printable {
                        carry = ch
                    } else {
                        resetTerminalWord()
                        if let legacy, legacy.unicodeScalars.count > 1 {
                            client.insertText(legacy)
                        } else if let legacy {
                            // Một byte (⏎ ⇥ ⌫ ⎋ Ctrl+chữ) đứng riêng là ký tự điều khiển, Ghostty bỏ: mở đầu bằng ký tự
                            // thường bị xoá ngay (như `fixLineWithKey`).
                            client.insertText("x\u{7f}" + legacy)
                        } else {
                            client.setMarkedText("")
                        }
                        return true
                    }
                } else if printable == nil, let legacy {
                    // Gửi phím kèm lần sửa trong một lần ghi (không còn là ký tự điều khiển đứng riêng).
                    log?("deferred: gửi lần sửa kèm phím \(legacy.debugDescription)")
                    // ⏎ ⇥ ⎋ chạy lệnh / hoàn thành ngay: từ không phải tiếng Việt được khôi phục trước phím, như khi không có
                    // lần sửa nào còn chờ (`fixLineWithKey`) — không thì "user" + ⏎ gõ liền tay chạy lệnh "ủe".
                    var fix = ""
                    if case .char = key, gap == .none, suspect == nil, onLine == nil, !engine.isEmpty,
                       legacy.unicodeScalars.count == 1 {
                        let old = engine.displayed
                        if case let .replace(_, new) = engine.finishWord().action, !Self.same(old, new) {
                            var oi = old.startIndex, ni = new.startIndex
                            while oi < old.endIndex, ni < new.endIndex, old[oi] == new[ni] {
                                oi = old.index(after: oi)
                                ni = new.index(after: ni)
                            }
                            fix = String(repeating: "\u{7f}", count: old[oi...].unicodeScalars.count) + String(new[ni...])
                            log?("deferred: khôi phục \(old.debugDescription) → \(new.debugDescription) cùng phím")
                        }
                    }
                    client.insertText(text + fix + legacy)
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
        if termLastWrite != writtenBefore { probeEcho(client, sentAt: termLastWrite) }
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
        // Có phím đi vòng chắc chắn mà chưa rõ nó làm gì với dòng (kể cả khi màn hình quyết định ngay ở phím này).
        let knownBypassAtEntry = suspect?.bypassKnown == true
        switch gap {
        case .unsureSteady:
            // Không có phím chưa thấy mới kể từ phím trước. Màn hình đã cho thấy tác dụng của các phím chưa thấy thì coi
            // là chắc; chưa thì xem màn hình bây giờ (iTerm2, Terminal.app).
            if suspectSettled || settleSuspect(client, options) { unsure = false }
        case .unsure:
            // Có phím chưa thấy mới: lúc chưa chắc bắt đầu lại từ phím này. Giả thuyết có phím đi vòng chắc chắn thì giữ, nhưng
            // ký tự của phím này (và các ký tự trước) không còn là bằng chứng: phím chưa thấy có thể bấm ngay sau nó.
            if suspect?.bypassKnown == true {
                var isChar = false
                if case .char = key { isChar = true }
                suspect!.proofFrom = suspect!.raw.count + (isChar ? 1 : 0)
            } else {
                suspect = nil
            }
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
                    s.proofFrom = min(s.proofFrom, s.raw.count)    // ký tự gõ sau ⌫ này vẫn là bằng chứng
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
            onLine = nil
            if unsure {
                if suspect == nil {
                    suspect = Suspect(oldLine: line, bypassKnown: bypassed, proofFrom: gap == .unsure ? 1 : 0)
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
                // ⏎ ⇥ ⎋ chạy lệnh / hoàn thành ngay, người dùng không kịp thấy dòng đã sửa: chỉ sửa kèm phím (từ còn phím đi
                // nguyên văn lúc chưa chắc, từ không phải tiếng Việt cần khôi phục) khi sổ phím chứng minh không có phím nào đi
                // vòng — không bao giờ dựa vào màn hình, kể cả khi màn hình vừa quyết định giả thuyết có phím đi vòng.
                if gap == .none, !unsure, !knownBypassAtEntry, !Self.isPrintable(ch),
                   let handled = fixLineWithKey(line, target, legacy: legacy, client, style) {
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

    /// Các mốc xem lại màn hình (giây sau lần gửi), gấp đôi dần tới gần `EchoClock.cap`: shell qua ssh in lại chậm hơn 64 ms
    /// cũng đo được (lúc ngừng tay).
    private static let probeSteps = [0.004, 0.008, 0.016, 0.032, 0.064, 0.128, 0.256]
    /// Chuỗi đo xem tới mốc 32 ms mà chưa thấy chữ thì tính là một lần không thấy (`EchoProbe.misses`).
    private static let probeMissAfter = 4
    /// Đã có đủ số đo thì chỉ đo lại sau ngần này giây.
    private static let probeRest = 0.25

    /// iTerm2 / Terminal.app: sau lần gửi lúc `sentAt`, xem lại màn hình ở các mốc `probeSteps` cho tới khi thấy đúng chữ của
    /// từ đang gõ trước con trỏ — đo trực tiếp thời gian shell in lại (`EchoClock`). Có phím mới thì thôi. Không đo khi chẳng
    /// được gì: đã có đủ số đo và vừa đo xong; các chuỗi trước không thấy chữ (ứng dụng toàn màn hình, ô mật khẩu, shell in
    /// lại chậm hơn nhịp gõ) — thưa dần, rồi thôi hẳn cho tới khi `guardCursor` thấy màn hình khớp.
    private func probeEcho(_ client: TextClient, sentAt: Double) {
        if probe.running {
            // Chuỗi trước bị phím này cắt ngang: chuỗi sau bắt đầu từ mốc cuối nó đã xem.
            probe.running = false
            if probe.next > probe.start {
                probe.from = probe.next - 1
                if probe.next >= Self.probeMissAfter { probeMissed(at: sentAt) }
            }
        }
        // Từ chỉ gồm một chữ lặp lại ("ll"): màn hình chưa in lại phím này cũng đã kết thúc bằng từ đó — đo vậy là sai.
        guard !probe.idle, sentAt >= probe.notBefore, Set(onLine ?? engine.displayed).count > 1,
              screenUsable(client) else { return }
        probe.serial &+= 1
        probe.running = true
        probe.start = probe.from
        probe.next = probe.from
        probeStep(client, sentAt: sentAt, serial: probe.serial, step: probe.from)
    }

    private func probeStep(_ client: TextClient, sentAt: Double, serial: Int, step: Int) {
        let delay = Self.probeSteps[step] - (client.currentTime() - sentAt)
        client.schedule(after: max(0, delay)) { [weak self, weak client] in
            guard let self, let client else { return }
            // Mỗi lần hỏi là một lần chờ ứng dụng trả lời (đồng bộ): phím kế tiếp có thể được xử lý ngay trong lúc chờ — hỏi
            // xong thì xem lại chuỗi đo còn hiệu lực không rồi mới dùng câu trả lời.
            func live() -> Bool { self.probe.serial == serial && self.probe.running && self.termLastWrite == sentAt }
            guard live() else { return }
            let word = Array((self.onLine ?? self.engine.displayed).utf16)
            guard self.echo.tracking, !word.isEmpty, let sel = client.selectedRange(), live(),
                  sel.location >= word.count else {
                if live() { self.probe.running = false }
                return
            }
            let before = client.text(location: sel.location - word.count, length: word.count).map { Array($0.utf16) }
            guard live() else { return }
            let now = client.currentTime()
            if before == word {
                self.probe.running = false
                self.probe.misses = 0
                if step == 0 || step > self.probe.start {
                    // Mốc trước chưa thấy (hay đây là mốc đầu tiên): số đo sát thời gian in lại thật (không quá gấp đôi).
                    self.echo.measured(now - sentAt)
                    self.probe.from = max(0, step - 1)
                    if self.echo.measurements >= 4 { self.probe.notBefore = now + Self.probeRest }
                } else {
                    // Thấy ngay ở mốc đầu của chuỗi: có thể shell đã in lại sớm hơn nhiều — không ghi số đo, lần sau xem sớm hơn.
                    self.probe.from = max(0, step - 2)
                }
            } else if step + 1 < Self.probeSteps.count {
                self.probe.next = step + 1
                self.probeStep(client, sentAt: sentAt, serial: serial, step: step + 1)
            } else {
                self.probe.running = false
                self.probe.from = step
                self.probeMissed(at: now)
            }
        }
    }

    /// Một chuỗi đo không thấy chữ: chuỗi sau chờ lâu dần; hai lần liền thì thôi đo cho tới khi `guardCursor` thấy khớp.
    private func probeMissed(at now: Double) {
        probe.misses += 1
        probe.notBefore = now + Self.probeRest * Double(1 << min(probe.misses - 1, 4))
        if probe.misses >= 2 { probe.idle = true }
    }

    /// Terminal cho đọc màn hình (iTerm2, Terminal.app: con trỏ thật) và màn hình đang cho thấy chữ bộ gõ gửi.
    private func screenUsable(_ client: TextClient) -> Bool {
        guard echo.tracking else { return false }
        if let known = keyScreen { return known }
        return readCursor(client) != nil
    }

    /// Sau bấy nhiêu lần được trả lời 0 / không biết (chưa từng thấy con trỏ thật) thì thôi hỏi con trỏ; chỉ hỏi lại sau mỗi
    /// `blindRecheck` lần bỏ qua.
    private static let blindLimit = 8
    private static let blindRecheck = 32

    /// Vị trí con trỏ thật trên màn hình terminal; nil nếu terminal không cho biết (Ghostty, Rex, Muxy báo 0; kitty không
    /// báo). Terminal chưa từng báo vị trí khác 0 thì sau `blindLimit` lần không hỏi nữa — câu trả lời luôn là không, mà mỗi lần
    /// hỏi là một lần chờ ứng dụng trong keyDown. Đã từng thấy con trỏ thật (iTerm2, Terminal.app) thì luôn hỏi.
    private func readCursor(_ client: TextClient) -> (location: Int, length: Int)? {
        if !screenSeen, blindReads >= Self.blindLimit, blindSkips < Self.blindRecheck {
            blindSkips += 1
            keyScreen = false
            return nil
        }
        blindSkips = 0
        guard let sel = client.selectedRange(), sel.location > 0 else {
            blindReads += 1
            keyScreen = false
            return nil
        }
        screenSeen = true
        keyScreen = true
        return sel
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
    /// - trước con trỏ là đúng từ cũ + các ký tự nguyên văn: các phím chưa thấy không đổi gì trước con trỏ (`.old`). Có phím
    ///   đi vòng chắc chắn (↑ gọi lại lệnh cũ…) thì từ cũ còn phải đứng đầu một từ trên màn hình: dòng lạ tình cờ kết thúc bằng
    ///   cùng các chữ đó ("…origin maf" sau "a", ↑, "f") không phải từ cũ — sửa theo nó là xoá chữ bộ gõ không gõ;
    /// - trước con trỏ là các ký tự nguyên văn, liền nhau: từ bắt đầu lại từ đó (`.restart`).
    /// Ứng dụng treo giữa lúc đó (phím đi vòng chỉ được xử lý ngay trước phím này) thì sổ phím không báo "không có gì mới"
    /// (phím này không tới ngay: xem `KeyLedger`).
    private func judgeSuspect(_ s: Suspect, _ client: TextClient) -> SuspectJudgement {
        guard s.raw.count > s.proofFrom, echo.tracking else { return .undecided }
        // Mọi phím chưa thấy (đã được đếm từ lần đọc phím trước) đã được ứng dụng xử lý ngay sau phím trước — kể cả phím
        // bấm ngay sau phím đó, được xử lý sau nó — và shell đã kịp in lại chúng cùng các ký tự bộ gõ đã gửi.
        guard client.currentTime() - termLastWrite >= echo.bound + Self.processingMargin else { return .undecided }
        guard let sel = readCursor(client) else { return .undecided }
        let cursor = sel.location
        let raw = String(s.raw)
        let full = Array((s.oldLine + raw).utf16)
        let rawUnits = Array(raw.utf16)
        // Đọc đủ dài cho từ cũ và ký tự ngay trước nó; dòng ngắn hơn thế (ô nhập liệu không cho đọc quá đầu) thì đọc đủ cho
        // các ký tự nguyên văn.
        var before: [UInt16] = []
        var from = cursor
        for len in [min(cursor, full.count + 1), min(cursor, rawUnits.count)] {
            if let text = client.text(location: cursor - len, length: len) {
                before = Array(text.utf16)
                from = cursor - len
                break
            }
        }
        guard !before.isEmpty else { return .undecided }
        func ends(_ x: [UInt16]) -> Bool { !x.isEmpty && before.count >= x.count && before.suffix(x.count).elementsEqual(x) }
        /// Trước từ cũ là đầu văn bản hay một ký tự không thuộc từ.
        func oldStartsWord() -> Bool {
            let i = before.count - full.count
            guard i > 0 else { return i == 0 && from == 0 }
            guard let c = Unicode.Scalar(before[i - 1]) else { return true }
            return !(Character(c).isLetter || Character(c).isNumber || c.properties.generalCategory == .nonspacingMark)
        }
        if ends(full), !s.bypassKnown || s.oldLine.isEmpty || oldStartsWord() { return .old }
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

    /// Phím chắc chắn (sổ phím) kết thúc từ mà không in được (⏎, ⇥, ⎋) khi dòng khác chữ cuối cùng của từ — còn giữ phím đi
    /// nguyên văn lúc chưa chắc (`onLine`), hay từ không phải tiếng Việt cần khôi phục ("nvm úe" → "nvm use"): sửa cả từ và
    /// gửi luôn byte của phím trong một lần ghi, bộ gõ giữ phím (iTerm2 coi phím đã xử lý khi có insertText trong keyDown). Mở đầu bằng ký tự thường: Ghostty bỏ chữ mở đầu bằng ký tự điều khiển trong keyDown,
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
        guard let sel = readCursor(client) else { return .unavailable }
        let word = Array((onLine ?? engine.displayed).utf16)
        let n = word.count, cursor = sel.location
        let beforeLen = min(n, cursor)
        let before = client.text(location: cursor - beforeLen, length: beforeLen).map { Array($0.utf16) } ?? []
        let sinceWrite = client.currentTime() - termLastWrite
        echo.observe(visible: before == word, after: sinceWrite)
        if before == word {
            probe.idle = false       // màn hình lại cho thấy chữ bộ gõ gửi: đo được
            return .matches
        }
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
            // Sổ phím chứng minh không có phím nào đi vòng: lệch chỉ có thể là shell in chậm (bận, ssh) hay không in lại
            // những gì gõ (vim ở normal mode, ô mật khẩu) — chỉ bỏ từ khi đã lâu (`EchoClock.mismatchLimit`).
            if sinceWrite >= echo.mismatchLimit { resetTerminalWord() }
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
        // Chỉ chữ dựng sẵn (mỗi chữ một code point, như bộ gõ xuất): chữ tổ hợp (tên file dán từ Finder) thì một DEL của shell
        // xoá cả chữ lẫn dấu, đếm DEL theo code point sẽ xoá lố ra ngoài từ.
        guard !word.isEmpty, word.utf16.count < len, word.unicodeScalars.count == word.count else { return }
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
            let marked = client.hasMarkedText()
            // Lần hỏi là một lần chờ ứng dụng trả lời (đồng bộ): phím kế tiếp có thể đã được xử lý ngay trong lúc chờ (đã lo
            // lần sửa này, có khi đã hẹn lần sửa mới) — câu trả lời không còn nói về lần sửa này.
            guard self.pendingSerial == serial, self.pending != nil else { return }
            if !marked {
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
        let serial = pendingSerial
        let marked = client.hasMarkedText()
        guard pendingSerial == serial, pending != nil else { return }   // phím lồng vào lúc chờ đã lo lần sửa này
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

    /// Phím ra chữ (không phải ký tự điều khiển hay mã phím chức năng U+F700… của AppKit: mũi tên, Home, F1…).
    private static func producesText(_ ch: Character) -> Bool {
        ch.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f && !(0xF700...0xF8FF).contains($0.value) }
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
        passedAt = nil
        if sel.length > 0 { return false }   // chỉ xoá phần gợi ý tự động đang bôi đen sau từ
        let old = engine.displayed
        guard case let .replace(_, new) = engine.backspace(), let last = old.last else {
            // Ứng dụng tự xoá ký tự cuối: ở phím sau con trỏ phải đã lùi (`lostTrack`).
            if !engine.isEmpty { passedAt = sel.location }
            return false
        }
        if singleEditPerKey {
            // Ô chỉ nhận một lần sửa mỗi phím: bộ gõ xoá luôn ký tự cuối trong cùng lần thay và giữ phím ⌫ (để ⌫ đi thẳng sau
            // lần thay thì JetBrains Runtime xoá cả vùng vừa chọn, AWT gốc bỏ luôn phím ⌫).
            if replace(old, new, client, sel: sel) { return true }
            engine.reset()
            if untracked { untrackedLength = old.count - 1 }
            if untracked, untrackedLength <= 0 { untracked = false }
            return false
        }
        // Xoá lùi làm đổi chữ còn lại (kiểu dấu cũ: "hoàn" ⌫ → "hòa"): thay phần đổi nhưng GIỮ ký tự cuối, rồi để chính ứng
        // dụng xoá nó như mọi phím ⌫ — không trả lời "đã xử lý" cho ⌫. Chromium / Electron vẫn chạy ⌫ của nó sau lần thay
        // của bộ gõ (IME Lab: "hoafn⌫" ra "hò").
        let kept = new + String(last)
        if replace(old, kept, client, sel: sel) {
            if kept.utf16.count == old.utf16.count { passedAt = sel.location }
            return false
        }
        engine.reset()              // không thay được: ứng dụng xoá ký tự cuối, bỏ từ
        if untracked { untrackedLength = old.count - 1 }   // phần còn lại của từ trên màn hình
        if untracked, untrackedLength <= 0 { untracked = false }
        return false
    }

    /// Kết thúc từ đang gạch chân bằng một phím (`combinedCommit`): phím ra chữ thì chốt từ + chữ đó trong một lần `insertText`
    /// và bộ gõ giữ phím (true); không thì chốt từ, gỡ marked text nếu `clear`, rồi cho phím đi (false).
    private func endMarkedWord(with text: String?, _ client: TextClient, clear: Bool) -> Bool {
        let tail = String(engine.finishWord().text.dropFirst(committed.count))
        let hadPreedit = !preedit.isEmpty
        endMarkedWord()
        if let text, !text.isEmpty {
            client.insertText(tail + text)
            return true
        }
        if !tail.isEmpty || hadPreedit { client.insertText(tail) }
        if clear { client.setMarkedText("") }
        return false
    }

    /// Hết từ mà không sửa gì (`singleEditPerKey`, phím không ra chữ): chữ của từ để nguyên như đang hiện.
    private func dropWord() {
        guard !engine.isEmpty else { return }
        if case let .replace(old, new) = engine.finishWord().action {
            log?("hết từ bằng phím không ra chữ: không sửa \(old.debugDescription) → \(new.debugDescription) (ô chỉ nhận một lần sửa mỗi phím)")
        }
        untracked = false
        endMarkedWord()
    }

    /// Hết từ ở ô chỉ nhận một lần sửa mỗi phím (`singleEditPerKey`): lần sửa cuối từ (khôi phục từ không phải tiếng Việt, "thửo"
    /// → "thuở") đi cùng chữ `text` của phím kết thúc từ trong một lần thay — bộ gõ giữ phím (true). Không có gì để sửa thì
    /// phím đi thẳng như thường (false).
    private func breakWord(with text: String?, _ client: TextClient) -> Bool {
        guard !engine.isEmpty else { return false }
        guard let text, !text.isEmpty else { dropWord(); return false }
        let action = engine.finishWord().action
        defer { endMarkedWord() }
        guard case let .replace(old, new) = action else { return false }
        let done = replace(old, new + text, client)
        untracked = false
        return done
    }

    private func breakWord(_ client: TextClient) {
        guard !engine.isEmpty else { return }
        let (text, action) = engine.finishWord()
        if marked {
            insertMarkedTail(text, client)
        } else if case let .replace(old, new) = action {
            _ = replace(old, new, client)
            untracked = false       // từ đã hết: cờ (bật khi ô chưa có lần thay trước) không kéo sang từ sau
        }
        endMarkedWord()
    }

    private func perform(_ action: Action, _ client: TextClient, retry ch: Character?,
                         sel: (location: Int, length: Int)? = nil) -> Bool {
        guard case let .replace(old, new) = action else { return false }
        replaceMismatch = nil
        if replace(old, new, client, typed: ch, sel: sel) { return true }
        if untracked {
            engine.reset()          // ô chưa cập nhật (xem `replace`): phím đi nguyên văn
            untrackedLength = 1
            laggyUntil = client.currentTime() + Self.lagEpisode
            return false
        }
        if let seen = replaceMismatch, !cursorReliable, seen.lowercased() != old.lowercased() {
            // Con trỏ đúng chỗ mà chữ ô cho đọc khác hẳn chữ bộ gõ vừa gõ ở đó (không chỉ khác hoa / thường như khi ô tự viết hoa
            // đầu câu): ô đang cho đọc bản chụp cũ, chậm đều vài phím nên vị trí trông vẫn khớp. Đọc lại từ theo nó rồi sửa là
            // sửa vào chữ khác.
            laggyUntil = client.currentTime() + Self.lagEpisode
            return loseTrack("chữ ô cho đọc không phải chữ vừa gõ (con trỏ \(sel?.location ?? -1))")
        }
        // Không khớp với màn hình: đọc lại từ trước con trỏ rồi xử lý phím này tiếp từ đó.
        guard resync(client) else { return loseTrack("ngay trước con trỏ là chữ không nạp lại được") }
        guard let ch else { engine.reset(); return false }
        if let a = engine.process(ch), case let .replace(o, n) = a {
            if replace(o, n, client, typed: ch) { return true }
            engine.reset()
        }
        return false
    }

    /// Bỏ trạng thái hiện tại, nạp lại từ đang nằm ngay trước con trỏ (nếu đọc được).
    /// Trả về false khi ngay trước con trỏ là chữ của một từ không phải tiếng Việt mà không nạp lại được (dài quá, có chữ
    /// ngoài bảng tiếng Việt — "responsibilit", "naïv"): gõ tiếp là gõ giữa từ đó, không được bắt đầu âm tiết mới
    /// ("responsibilitié") — nơi gọi cho phần còn lại đi nguyên văn. Chữ tiếng Việt viết liền nhiều âm tiết (#hànội, tên miền)
    /// thì vẫn như trước: âm tiết gõ thêm là từ mới. Không đọc được ô thì coi như không có gì (true).
    @discardableResult
    private func resync(_ client: TextClient) -> Bool {
        engine.reset()
        guard let sel = client.selectedRange() else { return true }
        anchor = sel.location
        guard sel.location > 0 else { return true }
        let len = min(sel.location, 16)
        guard let text = client.text(location: sel.location - len, length: len) else { return true }
        let word = String(text.reversed().prefix(while: { $0.isLetter }).reversed())
        guard !word.isEmpty else { return true }
        // Chỉ nạp khi thấy trọn từ (đứng sau ký tự không phải chữ, hoặc ở đầu văn bản).
        if word.utf16.count < len || len == sel.location, engine.seed(word) {
            anchor = sel.location - word.utf16.count
            return true
        }
        // TCVN3: chữ có dấu trên màn hình là ký tự Latin-1, không bao giờ nạp lại được — như trước.
        guard engine.options.charset != .tcvn3 else { return true }
        let vietnamese = word.contains(where: { !$0.isASCII }) && word.allSatisfy({ $0.isASCII || VTable.decompose[$0] != nil })
        return vietnamese
    }

    /// Lý do mất dấu của `lostTrack` là do ô không cho biết con trỏ thật (không phải ô đã đổi chữ / dời con trỏ).
    private func blindReason(_ sel: (location: Int, length: Int)?) -> Bool {
        // Ô không cho biết con trỏ (nil, {0,0}). Ô chậm (WebKit trả lời từ bộ đệm) cũng trông như vậy — cờ chỉ giữ tới khi ô báo
        // con trỏ khác (xem `blindSel`).
        guard !sighted else { return false }
        guard let sel else { return true }
        let expected = anchor + engine.displayed.utf16.count
        return sel.location == 0 && sel.length == 0 && expected > 0
    }

    // MARK: - Ô web Chromium (Chrome, Electron)

    /// Chuỗi gõ liền trong một ô web của Chromium (Chrome, Electron: VS Code, Zalo, Discord, Slack, Claude…).
    ///
    /// Chromium trả lời vị trí con trỏ và chữ quanh nó từ một bộ đệm phía trình duyệt; trang chỉ cập nhật bộ đệm sau khi xử lý
    /// xong phím (trang bận thì chậm một hai phím), lần sửa của bộ gõ (insertText kèm vùng thay) không bao giờ vào bộ đệm, và
    /// phím đi thẳng làm bộ đệm tự đoán từ vị trí trang báo lần cuối. Nhưng phím và lần sửa tới trang theo đúng thứ tự (cùng
    /// một hàng đợi) và vùng thay được tính theo văn bản của trang lúc xử lý. Nên bộ gõ tự giữ chữ của cả chuỗi gõ liền (từ
    /// `start`) và sửa theo vị trí của nó; bộ đệm chỉ để nhận ra:
    /// - trạng thái cũ của chính chuỗi (trong vài phím gần nhất): trang chậm — sửa tiếp, không bỏ dấu;
    /// - từ đang gõ nằm nguyên ở chỗ khác: dời vị trí;
    /// - chữ lạ (trang tự xoá / đổi ô bằng JavaScript, dán bằng chuột…): các chữ còn lại của từ đi nguyên văn.
    /// Ngừng gõ quá `webIdleBreak` giây thì chuỗi kết thúc: từ sau đọc lại vị trí từ bộ đệm (trang đã có thời gian báo).
    private struct WebChain {
        /// Con trỏ của trang sau mọi phím / lần sửa bộ gõ biết.
        var caret: Int
        /// Vị trí đầu chuỗi: chữ của chuỗi (`webBefore` + từ đang gõ) nằm từ đây.
        var start: Int
        /// Đã có bằng chứng vị trí là thật (trang đã báo lại, hoặc đã sửa một lần): lần sửa đầu của chuỗi chưa có bằng chứng
        /// chờ trang báo (`deferWebEdit`) — bộ đệm có thể chỉ là lần đoán của Chromium từ một vị trí cũ (ô được trang tự focus).
        var proven: Bool
        /// Vị trí đầu chuỗi đọc từ bộ đệm lúc trang có thể chưa báo hết các phím trước (⏎, mũi tên, ⌫ ngay trước đó): bộ đệm cho
        /// thấy trạng thái "cũ" của chuỗi thì có thể chỉ là trùng hợp — lần sửa đầu chỉ làm khi bộ đệm khớp đúng chữ đang gõ.
        var trusted = true
        /// Chuỗi chưa xác minh: ký tự người dùng vừa gõ ngay trước đầu chuỗi (⏎ → "\n", ⇥ → "\t"); bộ đệm cho thấy đúng ký tự đó
        /// trước đầu chuỗi (hay đầu chuỗi là đầu ô) mới là bằng chứng vị trí. nil: không biết — chỉ ngừng tay lâu mới tin.
        var expectBefore: Character?
        /// Lúc chuỗi bắt đầu, không còn phím gõ nào trước đó mà trang chưa báo (đã ngừng gõ lâu, hay chuỗi trước kết thúc lúc bộ
        /// đệm đã theo kịp nó — `webLeft`). Thứ duy nhất bộ đệm có thể chưa có là tác dụng của phím / click ngay trước chuỗi.
        /// Khi đó bộ đệm đổi khác đi chỉ có thể do trang báo việc xảy ra SAU đó: dùng làm bằng chứng vị trí được (`webEvident`).
        /// Trang đang chậm (còn phím cũ chưa báo) thì không: bộ đệm còn "phát lại" các phím cũ, trông y như chữ đang gõ.
        var clean = false
        /// Số đơn vị UTF-16 của chuỗi (tính từ `start`) đã có lúc gần nhất con trỏ có thể bị dời mà bộ gõ không biết (đầu chuỗi:
        /// 0; click / phím tắt bộ gõ không thấy giữa chuỗi: độ dài chuỗi lúc đó). Chỉ chữ gõ SAU mốc này mới là bằng chứng vị
        /// trí, và phải thấy từ hai ký tự trở lên (một ký tự có thể chỉ là Chromium tự đoán trên bộ đệm cũ).
        var evidenceFrom = 0
    }

    private enum WebRead { case current, lag, moved(Int), foreign }

    /// Chữ của chuỗi trước từ đang gõ (từ `web.start`).
    private var webBefore = ""
    private struct WebState {
        /// Số thứ tự (tăng dần suốt phiên).
        let serial: Int
        let text: String
        /// Phím tạo ra trạng thái này (`webKeyCount` lúc đó): một phím có thể tạo nhiều trạng thái (sửa + phím kết thúc từ…).
        var key = 0
    }
    /// Số phím ô web đã xử lý.
    private var webKeyCount = 0
    /// Ký tự phím kết thúc chuỗi vừa gõ (⏎ / ⇥): chuỗi sau bắt đầu ngay sau nó (xem `WebChain.expectBefore`).
    private var webNextExpect: Character?
    /// Phím trước của chuỗi là ⌫.
    private var webLastWasBackspace = false
    /// Chữ có sẵn ngay sau con trỏ (đọc lúc bộ đệm khớp đúng chuỗi, hay lúc bắt đầu chuỗi): gõ chèn trước nó thì chữ sau con trỏ
    /// trong bộ đệm cũ trùng phần chuỗi chưa báo không phải dấu hiệu click lùi.
    private var webSuffix = ""


    private func webNoteSuffix(_ client: TextClient, at location: Int) {
        webSuffix = client.text(location: location, length: 16) ?? ""
        if webSuffix.isEmpty, let t = client.text(location: location, length: 1) { webSuffix = t }
    }
    /// Trạng thái mới nhất của chuỗi lúc sổ phím báo click / phím tắt bộ gõ không thấy: bộ đệm cho thấy trạng thái đó hay cũ hơn
    /// thì trang chưa báo gì sau click (trang chậm) — không dùng làm bằng chứng vị trí.
    private var webGapSerial: Int?
    /// Chữ của chuỗi (từ `web.start` tới con trỏ) sau mỗi phím / lần sửa, cũ trước mới sau.
    private var webHistory: [WebState] = []
    private var webStateCount = 0
    /// Trạng thái cũ nhất bộ đệm còn có thể cho thấy: trang báo theo đúng thứ tự xử lý, nên đã thấy trang báo một trạng thái
    /// thì bộ đệm không quay về trạng thái trước nó nữa — quay về là trang đã tự đổi chữ (Notion "->" → "→"…), không phải chậm.
    private var webSeen = 0
    /// Chữ các lần chèn không vùng thay gần đây trang nhận (phím đi thẳng, `insertText` của bộ gõ), cũ trước mới sau. Chromium
    /// đoán bộ đệm bằng cách chèn chữ đó vào vị trí trang báo lần cuối — các lần chưa báo chồng lên nhau ngay sau con trỏ.
    private var webInserts: [String] = []
    private var webLastInsert: String? { webGuessFree ? nil : webInserts.last }
    /// Bộ đệm phải cho thấy bấy nhiêu đơn vị của chuỗi (gõ sau mốc) mới chắc là trang đã báo: Chromium tự đoán được một ký tự.
    private var webProofUnits: Int { webGuessFree ? 1 : 2 }

    private func webNoteInsert(_ text: String) {
        webInserts.append(text)
        if webInserts.count > 16 { webInserts.removeFirst(webInserts.count - 16) }
    }
    /// Lúc phím gần nhất ở ô web (chưa có phím nào: như đã lâu không gõ).
    private var webLastKeyAt = -Double.infinity
    /// Chuỗi trước vừa kết thúc bằng một phím bộ gõ không biết tác dụng (⌥⌫, ⌘⌫, mũi tên, ⏎, phím tắt…) đúng lúc bộ đệm đã theo
    /// kịp nó: con trỏ của bộ đệm lúc đó. Bộ đệm sau đó báo con trỏ ở chỗ khác thì trang đã báo tác dụng của phím ấy — đầu
    /// chuỗi kế tiếp đọc từ bộ đệm là thật. nil: không có / bộ đệm lúc đó còn chậm.
    /// `pending`: mọi vị trí con trỏ bộ đệm còn có thể cho thấy trong lúc trang báo nốt phần cuối của chuỗi đó (bộ đệm lúc ấy
    /// có thể đang chậm vài phím / lần sửa — kể cả lần sửa bộ gõ gửi ngay lúc kết thúc chuỗi); `final`: con trỏ của chuỗi khi
    /// trang đã báo hết chuỗi mà chưa báo tác dụng của phím kết thúc.
    private var webLeft: (pending: Set<Int>, final: Int)?
    /// Trang chậm hợp lý tới chừng này phím; bộ đệm cho thấy trạng thái cũ hơn là chữ lạ.
    private static let webLagLimit = 8
    private static let webIdleBreak = 1.0
    /// Chữ giữ lại trước từ đang gõ (bộ đệm của Chromium chỉ có chừng ±100 ký tự quanh con trỏ).
    private static let webWindow = 48

    private func resetWeb() {
        web = nil
        webGapSerial = nil
        webBefore = ""
        webHistory = []
        webInserts = []
        webResumeArmed = false
        webPending = nil
        webPendingClient = nil
        webShadow = nil
        webOwed = nil
        webWitness = nil
        webLeft = nil
        webSerial &+= 1
        webSettle = nil
        webSettleSerial &+= 1
    }

    private func webRecord() {
        webPush(webBefore + engine.displayed)
        web?.caret = anchor + engine.displayed.utf16.count
    }

    private func webPush(_ text: String) {
        webStateCount += 1
        webHistory.append(WebState(serial: webStateCount, text: text, key: webKeyCount))
        if webHistory.count > 64 { webHistory.removeFirst(webHistory.count - 64) }
    }

    /// Lịch sử mới chỉ có `text` — trạng thái bộ đệm vừa cho thấy.
    private func webSetHistory(_ text: String) {
        webGapSerial = nil
        webWitness = nil
        webHistory = []
        webPush(text)
        webSeen = webStateCount
    }

    private func startWebChain(at location: Int, trusted: Bool = true, clean: Bool = false) {
        trace?("ô web: chuỗi mới ở \(location): \(trusted ? "vị trí đáng tin" : clean ? "chưa đáng tin (chờ trang báo chữ đang gõ)" : "chưa đáng tin (bộ đệm có thể còn cũ)")")
        webSuffix = ""
        web = WebChain(caret: location, start: location, proven: false, trusted: trusted, expectBefore: webNextExpect,
                       clean: clean || trusted)
        webNextExpect = nil
        anchor = location
        webBefore = ""
        webSetHistory("")
    }

    private func handleWeb(_ key: Key, _ client: TextClient, options: EngineOptions, gap: KeyGap) -> Bool {
        webInKey = true
        webInsertedInKey = false
        defer { webInKey = false }
        let dropped = gap == .interrupted || gap == .bypassed
        // Rào đồng bộ đặt sau phím trước: đọc lại vị trí trước mọi quyết định của phím này — trừ khi vừa có click / phím tắt bộ
        // gõ không thấy (rào không tính được nó).
        if !dropped { webTryAnchor(client) }
        webSettle = nil
        webSettleSerial &+= 1
        if webPending != nil { flushWebPending(client, final: true) }   // lần sửa còn chờ: tới trang trước phím này
        webKeyCount += 1
        defer {
            let now = client.currentTime()
            webLastKeyAt = now
            // Phím ra chữ thường thì bộ gõ biết tác dụng; ⏎ / ⇥ / mũi tên / ⌫ / phím tắt / click thì không.
            var known = false
            if case let .char(ch) = key, Self.producesText(ch), !"\r\n\t".contains(ch) { known = true }
            if !known || dropped { webUnknownAt = now }
            // Chuỗi chưa có bằng chứng vị trí: hỏi trang ngay sau phím này, để phím kế tiếp đã biết chắc vị trí.
            if case .char = key, let chain = web, !chain.proven { webSettleSoon(client) }
        }
        // `webLeft` chỉ nói về phím ngay trước phím này.
        let left = webLeft
        webLeft = nil
        let idle = client.currentTime() - webLastKeyAt > Self.webIdleBreak
        if engine.isEmpty, !untracked, dropped {
            // Có click / phím tắt bộ gõ không thấy (Chromium không đưa chuột cho bộ gõ; macOS 27 báo click muộn tới 0,5 s): con
            // trỏ có thể đã ở chỗ khác. Không bỏ chuỗi (trang chậm thì bộ đệm còn cũ — bắt đầu lại ở đó là sửa sai chỗ) mà coi
            // như chưa có bằng chứng vị trí: lần sửa đầu chờ bộ đệm xác nhận; không gõ tiếp từ trước sau ⌫.
            web?.proven = false
            web?.evidenceFrom = (webHistory.last?.text ?? webBefore).utf16.count
            webWitness = nil                // lần thấy trước click không còn là bằng chứng
            webResumeArmed = false
        }
        if dropped, web != nil { webGapSerial = webStateCount }
        if !engine.isEmpty, !untracked, let chain = web {
            // Giữa từ mà có click / phím tắt bộ gõ không thấy, hay ngừng gõ lâu rồi bộ đệm (lúc này đã mới) báo con trỏ ở chỗ khác:
            // lần sửa sau của từ phải được bộ đệm xác nhận lại đúng chỗ — không thì phím đi nguyên văn.
            var moved = dropped
            if !moved, client.currentTime() - webLastKeyAt > Self.webIdleBreak, let sel = client.selectedRange() {
                moved = sel.length != 0 || sel.location != chain.caret
            }
            if moved {
                web?.proven = false
                web?.trusted = false
                web?.evidenceFrom = (webHistory.last?.text ?? webBefore).utf16.count
                webWitness = nil
            }
        }
        if case .backspace = key {
            let handled = webBackspace(client, dropped: dropped)
            webLastWasBackspace = true
            return handled
        }
        webLastWasBackspace = false
        let resume = webResumeArmed
        webResumeArmed = false
        switch key {
        case .other, .backspace:
            // Phím không ra chữ (⌥⌫, ⌘⌫, mũi tên, phím tắt…): từ đang đi nguyên văn kết thúc ở đây — từ gõ sau đó là từ mới, không
            // đi nguyên văn theo (nhật ký máy người dùng: gõ sai, ⌥⌫, gõ lại vẫn ra "tuye65t"). Gecko: không sửa gì trong
            // keyDown của phím này (phím tắt có ⌘ sẽ bị nuốt) — phần đang nguyên văn để nguyên.
            if webNeedsProof, webGuessFree || !webCatchUp(client, settled: webSettled(client)) { webShadowAbandon() }
            if untracked {
                untracked = false
                engine.reset()
                web = nil
            }
            let hadChain = web != nil
            endWebWord(client, terminator: nil)
            if !hadChain, !dropped, let sel = client.selectedRange(), sel.length == 0 {
                // Không có chuỗi nào (ô vừa được gắn, hay phím ngay trước cũng là phím như vậy — ⌥⌫ hai lần liền): vẫn biết bộ
                // đệm không còn gì chưa báo ngoài tác dụng của phím này nếu đã ngừng gõ lâu, hoặc bộ đệm vừa cho thấy tác dụng
                // của phím trước.
                if idle || left.map({ !$0.pending.contains(sel.location) }) == true {
                    webLeft = ([sel.location], sel.location)
                }
            }
            return false
        case let .char(ch):
            if untracked {
                if Self.continuesWord(ch) { return false }
                untracked = false
                engine.reset()
                web = nil
            }
            // Chuỗi chưa có bằng chứng vị trí (đầu chuỗi đọc lúc bộ đệm có thể còn cũ, có từ đang nằm nguyên văn): xem bộ đệm
            // đã cho thấy chữ của chuỗi ở đâu chưa — trước cả khi quyết định chuỗi còn tiếp hay không.
            if webNeedsProof { webCatchUp(client, settled: idle) }
            if engine.isEmpty { startWebWord(client, options: options, resume: resume, dropped: dropped, left: left) }
            if webShadow != nil {
                // Vẫn chưa biết từ nằm đâu: phím này cũng đi nguyên văn, `engine` gõ tiếp từ định gõ.
                guard engine.process(ch) != nil else {
                    if Self.producesText(ch), !"\r\n\t".contains(ch), webShadowCarry(ch) {
                        // Hết từ bằng dấu cách / dấu câu mà trang chưa cho thấy nó: từ đó còn nợ, sửa cùng từ sau khi có bằng chứng.
                        webNoteInsert(String(ch))
                        webShadowWatch(client)
                        return false
                    }
                    webShadowAbandon()                   // ⏎ / ⇥ / mũi tên: tác dụng không biết — để nguyên văn
                    endWebWord(client, terminator: ch)
                    if Self.producesText(ch) { webNoteInsert(String(ch)) }
                    return false
                }
                let page = (webShadow ?? "") + String(ch)
                webShadow = page
                webPush(webBefore + page)
                web?.caret = anchor + page.utf16.count
                webNoteInsert(String(ch))
                webShadowWatch(client)
                return false
            }
            guard let action = engine.process(ch) else {
                endWebWord(client, terminator: ch)
                if Self.producesText(ch) { webNoteInsert(String(ch)) }
                if webNeedsProof { webShadowWatch(client) }
                return false
            }
            switch action {
            case .passThrough:
                webRecord()
                webNoteInsert(String(ch))
                if webNeedsProof { webShadowWatch(client) }
                return false
            case let .replace(old, new):
                return webEdit(old: old, new: new, typed: ch, client)
            }
        }
    }

    /// Chuỗi đang cần bằng chứng vị trí: có từ đang đi nguyên văn, có từ còn nợ, hoặc đầu chuỗi chưa đáng tin và chưa xác minh.
    private var webNeedsProof: Bool {
        guard let chain = web else { return false }
        return webShadow != nil || webOwedValid != nil || (!chain.proven && !chain.trusted)
    }

    /// `webOwed` còn đúng (vẫn là phần cuối của `webBefore`); không thì bỏ.
    private var webOwedValid: (raw: String, intended: String)? {
        guard let owed = webOwed else { return nil }
        if !owed.raw.isEmpty, webBefore.hasSuffix(owed.raw) { return owed }
        webOwed = nil
        return nil
    }

    /// Thêm chữ vào cuối phần chuỗi trước từ đang gõ (từ vừa xong, ký tự ngăn cách); phần còn nợ dài ra theo.
    private func webAppendBefore(_ text: String) {
        let owed = webOwedValid
        webBefore += text
        if var owed {
            owed.raw += text
            owed.intended += text
            webOwed = owed.raw.utf16.count <= Self.webOwedLimit ? owed : nil
        }
    }

    /// Đã ngừng gõ quá `webIdleBreak`: trang đã có thời gian báo hết (như hẹn giờ cuối của `webShadowWatch`).
    private func webSettled(_ client: TextClient) -> Bool {
        client.currentTime() - webLastKeyAt > Self.webIdleBreak
    }
    private static let webOwedLimit = 48

    private func startWebWord(_ client: TextClient, options: EngineOptions, resume: Bool, dropped: Bool = false,
                              left: (pending: Set<Int>, final: Int)? = nil) {
        engine.options = options
        endDirectWord()
        marked = false
        committed = ""
        preedit = ""
        continueWordOnNextChar = false
        if web != nil, client.currentTime() - webLastKeyAt > Self.webIdleBreak {
            web = nil
            // Vừa ⌫ lùi về một từ rồi ngừng gõ: bộ đệm đã có mọi phím — dựng lại chuỗi từ bộ đệm để gõ tiếp từ đó.
            if resume, !dropped, let sel = client.selectedRange(), sel.length == 0 {
                _ = webRebuild(client, at: sel.location)
            }
        }
        guard let chain = web else {
            // Đầu chuỗi đọc từ bộ đệm: tin khi đã ngừng gõ lâu và không có click / phím tắt bộ gõ không thấy ngay trước — hoặc khi
            // chuỗi trước kết thúc lúc bộ đệm đã theo kịp (`webLeft`) mà nay bộ đệm báo con trỏ ở chỗ khác: trang đã báo tác dụng
            // của phím kết thúc chuỗi đó (⌥⌫ / ⌘⌫ xoá chữ, mũi tên dời con trỏ…), không còn gì chưa báo.
            let location = client.selectedRange()?.location ?? 0
            let idle = client.currentTime() - webLastKeyAt > Self.webIdleBreak
            var trusted = idle && !dropped
            var clean = idle
            if let left {
                if !left.pending.contains(location) {
                    clean = true                                 // trang đã báo hết chuỗi cũ lẫn tác dụng của phím đó
                    if !dropped { trusted = true }
                } else if location == left.final {
                    clean = true                                 // chỉ còn tác dụng của phím đó là có thể chưa báo
                }
            }
            startWebChain(at: location, trusted: trusted, clean: clean)
            webNoteSuffix(client, at: location)
            return
        }
        let text = webHistory.last?.text ?? webBefore
        // Gõ liền: từ mới bắt đầu ở con trỏ của bộ gõ — trừ khi trang báo con trỏ ở chỗ khác mà không phải trạng thái cũ của
        // chuỗi (trang chậm, kể cả trước các ⌫: con trỏ báo có thể ở SAU chỗ của bộ gõ): có chữ bộ gõ không biết (dán bằng
        // chuột, gợi ý được chọn…) hay người dùng đã click chỗ khác (Chromium không đưa click cho bộ gõ). Bắt đầu chuỗi mới ở
        // đó (chưa có bằng chứng: lần sửa đầu chờ trang báo).
        // (Chuỗi chưa đáng tin, chưa xác minh thì vị trí của nó có thể lệch — không so được với con trỏ bộ đệm báo: bộ đệm cho
        // thấy chính chữ của chuỗi, trọn hay một phần đầu, ngay trước con trỏ của nó thì vẫn là chuỗi này, trang chỉ đang báo
        // chậm — giữ chuỗi, có bằng chứng thì các từ còn nguyên văn của nó được sửa cả.)
        if let sel = client.selectedRange(), sel.length == 0, sel.location != chain.caret,
           !webCacheIsOlder(client, sel.location, chain: chain, model: text),
           chain.proven || chain.trusted || webSight(client, raw: text) == nil {
            webNextExpect = nil
            // Bộ đệm không còn là một trạng thái của chuỗi cũ: trang đã báo một việc bộ gõ không biết — mà trang báo theo thứ tự,
            // nên mọi phím của chuỗi cũ đã được báo trước đó (không còn phím cũ nào chưa báo: `clean`). Chỉ đúng khi vị trí của
            // chuỗi cũ là thật: chuỗi cũ chưa đáng tin, chưa xác minh thì "không khớp" có thể chỉ vì chính nó nằm sai chỗ, bộ
            // đệm vẫn còn đang báo dần các phím cũ (trang chậm vài phím: "la2 a1" ra "lá a1" — dấu rơi vào từ trước).
            startWebChain(at: sel.location, trusted: chain.trusted && !dropped, clean: chain.proven || chain.trusted)
            webNoteSuffix(client, at: sel.location)
            return
        }
        anchor = chain.caret
        webBefore = text
        if resume {
            // ⌫ vừa lùi tới cuối một từ (của chuỗi, bộ gõ biết chắc chữ): gõ tiếp từ đó. Chỉ khi thấy trọn từ (có ký tự không
            // phải chữ trước nó trong chuỗi, hay chuỗi bắt đầu ở đầu ô).
            let word = String(text.reversed().prefix(while: { $0.isLetter }).reversed())
            if !word.isEmpty, word.count < text.count || chain.start == 0, engine.seed(word) {
                anchor = chain.caret - word.utf16.count
                webBefore = String(text.dropLast(word.count))
                log?("ô web: gõ tiếp từ \(word.debugDescription) sau ⌫")
            }
        }
        trimWebChain()
    }

    /// Bỏ phần đầu chuỗi đã xa (giữ `webWindow` đơn vị UTF-16 trước từ đang gõ).
    private func trimWebChain() {
        guard var chain = web, webBefore.utf16.count > Self.webWindow else { return }
        var drop = 0, chars = 0
        for ch in webBefore {
            if webBefore.utf16.count - drop <= Self.webWindow { break }
            drop += ch.utf16.count
            chars += 1
        }
        let prefix = String(webBefore.prefix(chars))
        chain.start += drop
        chain.evidenceFrom = max(0, chain.evidenceFrom - drop)
        web = chain
        webBefore.removeFirst(chars)
        webHistory = webHistory.filter { $0.text.hasPrefix(prefix) }
            .map { WebState(serial: $0.serial, text: String($0.text.dropFirst(chars)), key: $0.key) }
    }

    /// So bộ đệm của Chromium với chữ của chuỗi (`webBefore` + từ đang gõ `word`).
    private func webRead(_ client: TextClient, word: String) -> WebRead {
        guard let chain = web, let sel = client.selectedRange() else { return .lag }

        let model = webBefore + word
        let base = chain.start
        webTail = 0
        if sel.length > 0 {
            // Vùng bôi đen bắt đầu đúng ở con trỏ của chuỗi, chữ trước nó đúng là trọn chuỗi, và trong các trạng thái bộ đệm còn
            // có thể cho thấy chỉ trạng thái mới nhất có đúng chữ đó: trang đã báo kịp và đang bôi đen một gợi ý tự điền ngay
            // sau chữ vừa gõ. (Vùng bôi đen chỉ đến từ báo cáo của trang — Chromium tự đoán thì con trỏ không kèm vùng chọn.)
            if sel.location == chain.caret, sel.location - base == model.utf16.count,
               let t = model.isEmpty ? "" : client.text(location: base, length: model.utf16.count), t == model,
               let last = webHistory.last, last.text == model,
               webHistory.filter({ $0.serial >= webSeen && $0.text == model }).count == 1 {
                webSeen = last.serial
                webGapSerial = nil
                webTail = sel.length
                webTailStates = webStateCount
                return .current
            }
            // Đang giữa lần sửa của bộ gõ (trang chọn vùng thay, chưa báo lần sau), hay gợi ý tự động bôi đen sau từ.
            let longest = max(webHistory.map { $0.text.utf16.count }.max() ?? 0, model.utf16.count)
            if sel.location >= base, sel.location <= base + longest { return .lag }
            return webMoved(client, sel, word)
        }
        let m = sel.location - base
        guard m >= 0 else { return webMoved(client, sel, word) }
        if m == 0, model.isEmpty { return .current }
        guard let t = m == 0 ? "" : client.text(location: base, length: m) else {
            return m == model.utf16.count ? .current : .lag
        }
        if t == model {
            if let gs = webGapSerial, (webHistory.last?.serial ?? 0) <= gs { return .lag }   // chưa có gì sau click
            webAccept(t)
            webNoteSuffix(client, at: sel.location)
            webGapSerial = nil
            return .current
        }
        if webAcceptOlder(client, t, location: sel.location, m: m, model: model) { return .lag }
        return webMoved(client, sel, word)
    }

    /// Bộ đệm (con trỏ ở `location`, khác chỗ của bộ gõ) cho thấy một trạng thái gần đây của chuỗi: trang chậm.
    private func webCacheIsOlder(_ client: TextClient, _ location: Int, chain: WebChain, model: String) -> Bool {
        let m = location - chain.start
        guard m >= 0 else { return false }
        guard let t = m == 0 ? "" : client.text(location: chain.start, length: m) else { return true }
        return webAcceptOlder(client, t, location: location, m: m, model: model)
    }

    /// Bộ đệm có cả phần chuỗi SAU con trỏ (`model` từ vị trí `m`): trang đã xử lý những chữ đó nên không chậm — con trỏ lùi vì
    /// người dùng click / kéo chọn (Chromium không đưa chuột cho bộ gõ). Trang chậm thì sau con trỏ chỉ là chữ có sẵn từ trước.
    private func webShowsRest(_ client: TextClient, _ location: Int, m: Int, model: String) -> Bool {
        let mu = Array(model.utf16)
        guard m >= 0, m < mu.count, let after = client.text(location: location, length: mu.count - m) else { return false }
        guard Array(after.utf16) == Array(mu[m...]) else { return false }
        // Chữ đó cũng là phần đầu của chữ có sẵn sau chỗ gõ: có thể chỉ là trang chậm (bộ đệm chưa có các chữ vừa gõ) — không chắc.
        return !webSuffix.hasPrefix(after)
    }

    /// Các trạng thái của chuỗi trong `webLagLimit` phím gần nhất (tính theo phím, không theo số trạng thái).
    private var webRecent: ArraySlice<WebState> {
        let from = webKeyCount - Self.webLagLimit
        let i = webHistory.lastIndex { $0.key < from }.map { $0 + 1 } ?? webHistory.startIndex
        // Giữ ít nhất trạng thái mới nhất trước phím cũ nhất trong cửa sổ (trang chậm đúng `webLagLimit` phím).
        return webHistory[max(webHistory.startIndex, i - 1)...]
    }

    /// Chữ bộ đệm cho thấy (từ đầu chuỗi tới con trỏ) là một trạng thái gần đây của chuỗi, không cũ hơn `webSeen`: đúng một
    /// trạng thái (trang báo chậm — mỗi phím là một trạng thái, kể cả trước các ⌫), hay trạng thái + chữ của lần chèn gần nhất
    /// (Chromium tự đoán từ vị trí báo lần cuối). Trả về số thứ tự nhỏ nhất của trạng thái trang có thể đang ở. Không nhận "phần
    /// đầu của một trạng thái" (click lùi vào giữa văn bản cũng trông như vậy) hay trạng thái + chữ khác (trang tự đổi chữ).
    /// `guess`: khớp được theo dạng Chromium tự đoán (trạng thái + chữ chèn gần nhất).
    private func webMatch(_ t: String) -> (serial: Int, guess: Bool)? {
        let tu = Array(t.utf16)
        let g = webLastInsert.map { Array($0.utf16) }
        var found: Int?
        var guess = false
        for s in webRecent where s.serial >= webSeen {
            let su = Array(s.text.utf16)
            let exact = tu == su
            let guessed = g.map { tu.count == su.count + $0.count && tu.starts(with: su) && Array(tu[su.count...]) == $0 } ?? false
            if exact || guessed {
                if found == nil { found = s.serial }
                if guessed { guess = true }
            }
        }
        return found.map { ($0, guess) }
    }

    /// Bộ đệm cho thấy trạng thái cũ của chuỗi (trang chậm) — không phải người dùng click lùi (xem `webShowsRest`); ghi nhận
    /// trạng thái trang đã báo.
    private func webAcceptOlder(_ client: TextClient, _ t: String, location: Int, m: Int, model: String) -> Bool {
        guard let found = webMatch(t) else { return false }
        if let gs = webGapSerial, found.serial > gs { webGapSerial = nil }   // trang đã báo phím gõ sau click
        if webShowsRest(client, location, m: m, model: model), !webStackedGuesses(client, location, m: m, model: model) {
            return false
        }
        if found.guess, let g = webLastInsert, model.hasSuffix(g), m >= g.utf16.count {
            // Khớp theo dạng đoán (chữ chèn gần nhất nằm ngay trước con trỏ): người dùng có thể đã click chỗ khác rồi gõ chữ đó —
            // bộ đệm khi ấy có cả phần chuỗi (không tính chữ đó) sau con trỏ.
            let base = String(model.dropLast(g.count)), mb = m - g.utf16.count
            if webShowsRest(client, location, m: mb, model: base), !webStackedGuesses(client, location, m: mb, model: base) {
                return false
            }
        }
        webSeen = max(webSeen, found.serial)
        return true
    }

    /// Chữ sau con trỏ trong bộ đệm có thể là các lần đoán chưa báo chồng lên nhau (lần chèn trước nằm sau lần chèn sau): trang
    /// chậm sau một lúc ngừng gõ, gõ hai ký tự giống nhau ("  ", "..") — trông như phần chuỗi sau con trỏ.
    private func webStackedGuesses(_ client: TextClient, _ location: Int, m: Int, model: String) -> Bool {
        let n = model.utf16.count - m
        guard !webGuessFree, n > 0, webInserts.count >= 2, let after = client.text(location: location, length: n) else { return false }
        let earlier = webInserts.dropLast().reversed().joined()
        return earlier.hasPrefix(after)
    }

    /// `webMatch`, và ghi nhận trạng thái trang đã báo.
    @discardableResult
    private func webAccept(_ t: String) -> Bool {
        guard let found = webMatch(t) else { return false }
        webSeen = max(webSeen, found.serial)
        return true
    }

    /// Bộ đệm khớp mô hình ở vị trí cách đầu chuỗi từ 2 ký tự trở lên: chắc chắn trang đã báo (Chromium tự đoán thì con trỏ
    /// chỉ hơn vị trí báo lần cuối đúng một ký tự) — vị trí của bộ gõ là thật.
    private func webProvable(_ word: String) -> Bool {
        guard let chain = web else { return false }
        return anchor + word.utf16.count - chain.start >= webProofUnits
    }

    /// Từ đang gõ nằm nguyên ngay trước con trỏ trang báo, nhưng ở chỗ khác chỗ bộ gõ nhớ: bắt đầu chuỗi mới ở đó.
    private func webMoved(_ client: TextClient, _ sel: (location: Int, length: Int), _ word: String) -> WebRead {
        let n = word.utf16.count
        // Một ký tự trước con trỏ trùng chữ đang gõ không chứng minh được gì (chữ đó có thể là chữ có sẵn).
        if n >= 2, sel.length == 0, sel.location >= n, let t = client.text(location: sel.location - n, length: n), t == word {
            return .moved(sel.location - n)
        }
        return .foreign
    }

    /// Dời từ đang gõ (`word`) tới `at`: chuỗi mới bắt đầu ở đó.
    private func webMove(to at: Int, word: String) {
        web = WebChain(caret: at + word.utf16.count, start: at, proven: true, clean: true)
        anchor = at
        webBefore = ""
        webSetHistory(word)
    }

    private func webEdit(old: String, new: String, typed: Character, _ client: TextClient) -> Bool {
        let proven = web?.proven ?? false
        let trusted = web?.trusted ?? false
        switch webRead(client, word: old) {
        case .foreign:
            // Chữ lạ trước con trỏ (trang tự đổi chữ, dán bằng chuột…): giữ phím, chờ trang báo rồi đọc lại từ ở đó.
            log?("ô web: chữ trước con trỏ khác chuỗi của bộ gõ — chờ trang báo rồi đọc lại")
            deferWebEdit(old: old, new: new, typed: typed, client)
            return true
        case let .moved(at) where !trusted && !webMovedConfirmed(client, at: at):
            deferWebEdit(old: old, new: new, typed: typed, client)
            return true
        case let .moved(at):
            webMove(to: at, word: old)
        case .current where !proven && (trusted ? webProvable(old) : webStartConfirmed(client)):
            web?.proven = true
            web?.trusted = true
        case .current, .lag:
            if !proven {
                if webEvident(client, word: old) {
                    web?.proven = true
                    web?.trusted = true
                } else if webGuessFree, trusted {
                    // Gecko: đầu chuỗi đáng tin là vị trí trang đã báo thật (bộ đệm không tự đoán) — sửa ngay theo vị trí của bộ
                    // gõ, không giữ phím chờ (phím còn giữ mà gặp phím tắt kế tiếp thì phải trả trong keyDown của phím tắt đó).
                    web?.proven = true
                } else if !trusted, webBefore.utf16.count + old.utf16.count < webProofUnits, !webSettles {
                    // Đầu chuỗi chưa đáng tin mà trên trang mới có một ký tự của chuỗi: chờ cũng không có bằng chứng (cần hai ký
                    // tự). Phím đi nguyên văn; có nó trên trang rồi thì trang báo là sửa lại được. (Ô trả lời được câu hỏi đồng
                    // bộ thì giữ phím một nhịp — `webSettleSoon` cuối phím này — rồi sửa đúng chỗ, không cho chữ thô ra trang.)
                    webShadowStart(client, old: old, typed: typed)
                    return true
                } else {
                    deferWebEdit(old: old, new: new, typed: typed, client)
                    return true
                }
            }
        }
        applyWebEdit(old: old, new: new, client)
        return true
    }

    /// Bộ đệm cho thấy đúng TRỌN chữ của chuỗi (`webBefore` + từ đang có trên trang `word`) từ đầu chuỗi tới con trỏ của nó, dài
    /// hơn mốc `evidenceFrom` (đầu chuỗi, hay chỗ chuỗi đang ở lúc có click / phím tắt bộ gõ không thấy) từ hai đơn vị trở lên, và
    /// không còn click nào trang chưa báo: trang chắc chắn đã báo ít nhất một ký tự gõ SAU mốc đó (Chromium tự đoán chỉ đẩy con
    /// trỏ quá vị trí báo lần cuối đúng một ký tự). Trang báo theo đúng thứ tự xử lý, nên mọi thứ xảy ra trước chuỗi (⌥⌫, ⌘⌫,
    /// click, mũi tên…) đã có trong bộ đệm: đầu chuỗi là thật, kể cả khi lúc đọc nó chưa đáng tin (`WebChain.trusted`).
    /// Phải là trọn chuỗi, không phải một trạng thái cũ của nó: đầu chuỗi đọc được lúc trang chưa báo tác dụng của phím trước
    /// (⌥⌫) là vị trí CŨ; trang báo xong, gõ lại dài hơn từ đã xoá thì vùng từ vị trí cũ ấy tới con trỏ là đuôi của từ mới —
    /// vài ký tự của nó trùng một trạng thái cũ của chuỗi là chuyện thường ("t " trùng "t" + dấu cách tự đoán), trùng trọn
    /// chuỗi thì không thể (vùng đó ngắn hơn chuỗi).
    /// Chỉ khi lúc chuỗi bắt đầu không còn phím cũ nào chưa được báo (`WebChain.clean`).
    private func webEvident(_ client: TextClient, word: String) -> Bool {
        guard let chain = web, chain.clean, webGapSerial == nil, let sel = client.selectedRange(), sel.length == 0 else {
            return false
        }
        let model = webBefore + word
        let m = sel.location - chain.start
        guard m == model.utf16.count, m - chain.evidenceFrom >= webProofUnits else { return false }
        return client.text(location: chain.start, length: m) == model
    }

    /// Chuỗi chưa có bằng chứng vị trí: ngay sau phím vừa rồi (khi chữ của nó đã tới trang) hỏi trang một câu đồng bộ
    /// (`TextClient.settle`). Trang trả lời nghĩa là nó đã xử lý xong mọi phím / click gửi trước đó — kể cả ⌥⌫ / ⌘⌫ / click
    /// ngay trước chuỗi mà bộ gõ không biết tác dụng; một nhịp sau bộ đệm cho thấy đúng con trỏ thật (`webTryAnchor`). Người
    /// gõ không phải chờ gì: việc này nằm gọn trong khoảng giữa hai phím, phím dấu kế tiếp sửa được ngay — không có chữ thô
    /// nào ra trang rồi mới được sửa lại.
    /// Sau một phím không biết tác dụng thì chờ thêm `webPageSlack`: trang có thể đẩy chữ / con trỏ mới sang Chromium ở
    /// khung hình kế tiếp chứ không ngay lúc xử lý phím.
    private func webSettleSoon(_ client: TextClient) {
        webSettle = nil
        webSettleSerial &+= 1
        let serial = webSettleSerial
        if webGuessFree {
            // Gecko: không hỏi đồng bộ được, nhưng bộ đệm không tự đoán — nó cho thấy trọn chuỗi (có ít nhất một ký tự gõ sau
            // mốc) là trang đã báo ký tự đó, tức đã xử lý mọi thứ trước nó (`webEvident`). Trang báo trong vài mili giây: xem
            // lại bộ đệm mấy lần ngay sau phím, để phím dấu kế tiếp sửa được ngay.
            for delay in [0.003, 0.008, 0.02, 0.045] {
                client.schedule(after: delay) { [weak self, weak client] in
                    guard let self, let client, self.webSettleSerial == serial, let chain = self.web, !chain.proven else { return }
                    if self.webPending != nil {
                        self.flushWebPending(client, check: 1)
                    } else {
                        self.webCatchUp(client, settled: false)
                    }
                }
            }
            return
        }
        let now = client.currentTime()
        guard now >= webSettleRetryAt else { return }
        let delay = max(Self.webSettleAfter, webUnknownAt + Self.webPageSlack - now)
        client.schedule(after: delay) { [weak self, weak client] in
            guard let self, let client, self.webSettleSerial == serial, let chain = self.web, !chain.proven else { return }
            let t0 = client.currentTime()
            let ok = client.settle()
            let t1 = client.currentTime()
            self.log?("ô web: hỏi trang (đồng bộ) \(ok ? "được" : "không được") sau \(Int((t1 - t0) * 1000)) ms")
            guard ok else {
                // Trang treo: mỗi lần hỏi là một lần chờ hết hạn của Chromium — thôi hỏi một lúc.
                if t1 - t0 > 0.25 { self.webSettleRetryAt = t1 + 3 }
                return
            }
            self.webSettles = true
            guard self.webSettleSerial == serial else { return }   // có phím tới trong lúc chờ trang trả lời
            self.webSettle = (self.webStateCount, t1)
            client.schedule(after: Self.webSettleRead) { [weak self, weak client] in
                guard let self, let client, self.webSettleSerial == serial, self.webTryAnchor(client) else { return }
                if self.webPending != nil {
                    self.flushWebPending(client, check: 1)
                } else {
                    self.webCatchUp(client, settled: false)
                }
            }
        }
    }

    /// Sau rào đồng bộ (`webSettleSoon`) và một nhịp cho ứng dụng nhận báo cáo của trang, chưa gửi thêm gì: con trỏ của bộ
    /// đệm là con trỏ THẬT của trang sau mọi phím bộ gõ biết. So với con trỏ bộ gõ đang nhớ:
    /// - trùng: vị trí của chuỗi là thật;
    /// - lệch mà trọn chữ của chuỗi nằm ngay trước con trỏ thật: đầu chuỗi đọc lúc bộ đệm còn cũ (trang chưa kịp báo ⌥⌫ / ⌘⌫ /
    ///   click) — dời cả chuỗi về chỗ thật;
    /// - lệch, chỉ phần gõ SAU lúc con trỏ có thể bị dời (`evidenceFrom`) nằm trước con trỏ thật: người dùng đã click chỗ khác
    ///   giữa chuỗi — chuỗi mới bắt đầu từ phần đó;
    /// - không khớp gì: không có bằng chứng (các đường cũ lo).
    @discardableResult
    private func webTryAnchor(_ client: TextClient) -> Bool {
        guard let s = webSettle else { return false }
        webSettle = nil
        guard var chain = web, !chain.proven, s.states == webStateCount,
              client.currentTime() - s.at >= Self.webSettleRead - 0.0005,
              let sel = client.selectedRange(), sel.length == 0 else { return false }
        let page = webShadow ?? engine.displayed            // từ đang gõ, đúng như trang đang có
        let units = Array((webBefore + page).utf16)
        func shows(_ n: Int) -> Bool {
            guard n > 0 else { return true }
            guard sel.location >= n, let t = client.text(location: sel.location - n, length: n) else { return false }
            return Array(t.utf16) == Array(units.suffix(n))
        }
        let delta = sel.location - chain.caret
        if delta == 0 {
            // đúng chỗ bộ gõ đang nhớ
        } else if chain.caret - chain.start == units.count, shows(units.count) {
            log?("ô web: trang cho thấy chuỗi bắt đầu ở \(chain.start + delta) (bộ gõ đang nhớ \(chain.start))")
            chain.start += delta
            chain.caret += delta
            anchor += delta
        } else {
            let since = units.count - chain.evidenceFrom
            guard since >= 0, since < units.count, page.utf16.count <= since, shows(since) else { return false }
            let kept = String(decoding: units.suffix(since), as: UTF16.self)
            guard kept.hasSuffix(page) else { return false }
            log?("ô web: con trỏ đã bị dời giữa chuỗi — chuỗi mới ở \(sel.location - since)")
            chain = WebChain(caret: sel.location, start: sel.location - since, proven: false)
            webBefore = String(kept.dropLast(page.count))
            anchor = chain.start + webBefore.utf16.count
            web = chain
            webSetHistory(kept)
            if webOwedValid == nil { webOwed = nil }
        }
        chain.proven = true
        chain.trusted = true
        chain.clean = true
        webGapSerial = nil
        webWitness = nil
        web = chain
        webNoteSuffix(client, at: sel.location)
        log?("ô web: trang đã trả lời — vị trí chắc chắn\(delta == 0 ? "" : " (lệch \(delta))")")
        trace?("ô web: trang đã trả lời: vị trí chắc chắn")
        return true
    }

    /// Không đặt được lần sửa (chưa chắc từ nằm ở đâu): phím đã giữ lại đi nguyên văn, và từ tạm đi nguyên văn (`webShadow`) —
    /// không bỏ từ: bộ gõ vẫn giữ từ định gõ, trang cho thấy chỗ của nó là sửa lại.
    private func webShadowStart(_ client: TextClient, old: String, typed: Character) {
        webPending = nil
        webPendingClient = nil
        client.insertText(String(typed))
        if webInKey { webInsertedInKey = true }
        webNoteInsert(String(typed))
        let page = old + String(typed)
        log?("ô web: chưa chắc vị trí — \(page.debugDescription) tạm đi nguyên văn, chờ trang báo để sửa thành \(engine.displayed.debugDescription)")
        trace?("ô web: chưa có bằng chứng vị trí: phím đi nguyên văn, chờ trang báo để sửa lại")
        webShadow = page
        webPush(webBefore + page)
        web?.caret = anchor + page.utf16.count
        if !webCatchUp(client, settled: false) { webShadowWatch(client) }
    }

    /// Xem lại bộ đệm sau khi trang có thời gian báo (30 / 70 / 250 ms), không cần đợi phím kế tiếp; lần cuối — đã ngừng gõ
    /// quá `webIdleBreak` — coi như trang đã báo xong (`settled`).
    private func webShadowWatch(_ client: TextClient) {
        webSerial &+= 1
        let serial = webSerial
        for delay in [0.03, 0.07, 0.25, Self.webIdleBreak + 0.05] {
            client.schedule(after: delay) { [weak self, weak client] in
                guard let self, let client, self.webSerial == serial, self.webNeedsProof else { return }
                self.webCatchUp(client, settled: delay > Self.webIdleBreak)
            }
        }
    }

    /// Chuỗi chưa có bằng chứng vị trí: thử lấy bằng chứng từ bộ đệm; có rồi thì sửa ngay mọi thứ còn nằm nguyên văn trên trang
    /// (từ đang gõ `webShadow`, các từ trước còn nợ `webOwed`) thành chữ định gõ trong một lần thay theo vị trí — mọi phím
    /// nguyên văn đã tới trang trước nó — rồi gõ tiếp như thường. `settled`: đã ngừng gõ đủ lâu để trang báo xong.
    @discardableResult
    private func webCatchUp(_ client: TextClient, settled: Bool) -> Bool {
        guard let chain = web else { return false }
        // Chữ vừa chèn trong phím này chưa tới trang (Chromium gửi nó khi hết keyDown): lần thay theo vị trí phải đợi sau phím —
        // hẹn giờ (`webShadowWatch`) hay đầu phím kế tiếp.
        if webInKey, webInsertedInKey { return false }
        let page = webShadow ?? engine.displayed            // từ đang gõ, đúng như trang đang có
        if !chain.proven {
            var proven = false
            switch webRead(client, word: page) {
            case .current, .lag: proven = webEvident(client, word: page)
            case .moved, .foreign: break
            }
            if !proven { proven = webProve(client, raw: webBefore + page, settled: settled) }
            guard proven else { return false }
            web?.proven = true
            web?.trusted = true
        }
        guard webShadow != nil || webOwedValid != nil else { return true }
        let new = engine.displayed
        log?("ô web: trang cho thấy chuỗi nằm ở \(web?.start ?? -1) — sửa phần còn nguyên văn (\((webOwedValid?.raw ?? "").debugDescription) + \(page.debugDescription)) thành \(((webOwedValid?.intended ?? "") + new).debugDescription)")
        trace?("ô web: đã có bằng chứng vị trí: sửa lại \((webOwedValid?.raw.utf16.count ?? 0) + page.utf16.count) đơn vị còn nguyên văn")
        webShadow = nil
        webSerial &+= 1
        applyWebEdit(old: page, new: new, client, atPosition: true)
        return true
    }

    /// Bằng chứng vị trí bằng NỘI DUNG, cho chuỗi mà đầu chuỗi đọc được lúc bộ đệm có thể còn cũ (ngay sau ⌥⌫ / ⌘⌫ / click khi
    /// trang chưa kịp báo): TRỌN chữ của chuỗi trên trang (`raw`, từ đầu chuỗi tới con trỏ — toàn phím đi thẳng) nằm ngay trước
    /// con trỏ của bộ đệm, và
    /// - thấy vậy ở CÙNG một chỗ trong hai lần đọc mà giữa đó trang đã báo thêm chữ của chuỗi (phần chắc chắn do trang báo ở
    ///   lần sau dài hơn mọi thứ đã thấy ở lần trước): trang đang báo kịp chính các phím của chuỗi ở đó — chỗ đó là thật. Bộ đệm cũ đứng yên không làm được vậy (Chromium tự đoán chỉ chèn chữ của lần chèn gần nhất vào
    ///   vị trí báo lần cuối), bộ đệm đang "phát lại" một từ cũ giống hệt (trang chậm cả từ) cũng không: nó chỉ trùng trọn
    ///   chuỗi được một lần; hoặc
    /// - (`settled`) đã ngừng gõ quá `webIdleBreak` — trang đã có thời gian báo hết. Không dùng mốc ngắn hơn: trang chậm thì bộ
    ///   đệm lúc đó còn là chữ Chromium tự đoán chồng lên trạng thái cũ.
    /// Chỉ chữ gõ SAU lúc con trỏ có thể đã bị dời (`evidenceFrom`) mới tính, và nếu biết ký tự đứng ngay trước đầu chuỗi
    /// (`expectBefore`: "\n" sau ⏎…) thì chỗ thấy phải đứng sau đúng ký tự đó.
    /// Thấy một phần đầu của chuỗi (trang báo chậm vài phím) thì chưa là bằng chứng — bộ đệm đang "phát lại" một từ cũ giống
    /// hệt cũng trông như vậy.
    private func webProve(_ client: TextClient, raw: String, settled: Bool) -> Bool {
        guard var chain = web, !chain.proven, let s = webSight(client, raw: raw) else { return false }
        let length = raw.utf16.count
        var proven = false
        if s.full, s.reported >= chain.evidenceFrom + 2, length >= 3, webStartMatches(client, chain, at: s.at) {
            if settled {
                proven = true
            } else if let seen = webWitness, seen.at == s.at {
                // Phần chắc chắn do trang báo ở lần này phải dài hơn TOÀN BỘ những gì đã thấy ở lần trước: chuỗi dài thêm chỉ
                // nhờ chữ Chromium tự đoán (trang chưa báo gì mới) thì chưa là gì — bộ đệm đang dừng ở một từ cũ giống hệt
                // cũng "dài thêm" kiểu đó ("a1 " của từ trước + "c" tự đoán trùng "a1 c" của chuỗi này).
                proven = s.reported > seen.length
            } else {
                webWitness = (s.at, length)
            }
        }
        guard proven else { return false }
        if s.at != chain.start {
            log?("ô web: bộ đệm cho thấy chuỗi bắt đầu ở \(s.at) (bộ gõ đang nhớ \(chain.start))")
            let delta = s.at - chain.start
            chain.start += delta
            chain.caret += delta
            anchor += delta
        }
        chain.clean = true
        webGapSerial = nil
        webWitness = nil
        web = chain
        return true
    }

    /// Chuỗi biết ký tự đứng ngay trước đầu chuỗi (`expectBefore`): chỗ `at` phải đứng sau đúng ký tự đó.
    private func webStartMatches(_ client: TextClient, _ chain: WebChain, at: Int) -> Bool {
        guard let expect = chain.expectBefore else { return true }
        guard at >= 1, let t = client.text(location: at - 1, length: 1) else { return false }
        return t == String(expect) || (expect == "\n" && t == "\r")
    }

    /// `raw` (chữ của chuỗi trên trang, từ đầu chuỗi tới con trỏ) nằm ngay trước con trỏ của bộ đệm: trọn chuỗi (`full`), hoặc —
    /// trang báo chậm vài phím — `j` đơn vị đầu của nó (từ hai trở lên), có hay không kèm chữ của lần chèn gần nhất mà Chromium
    /// tự đoán. Trả về chỗ đầu chuỗi theo bộ đệm và số đơn vị đầu chắc chắn do trang báo (không tính chữ có thể là tự đoán).
    private func webSight(_ client: TextClient, raw: String) -> (at: Int, reported: Int, full: Bool)? {
        guard let sel = client.selectedRange(), sel.length == 0 else { return nil }
        let all = Array(raw.utf16)
        let skip = max(0, all.count - 64)                    // chuỗi dài: chỉ so phần cuối
        let u = Array(all[skip...])
        let n = u.count, c = sel.location
        guard n >= 2, c >= 2 else { return nil }
        let len = min(n, c)
        guard let t = client.text(location: c - len, length: len) else { return nil }
        let w = Array(t.utf16)
        guard w.count == len else { return nil }
        let g = webLastInsert.map { Array($0.utf16) } ?? []
        func ends(_ tail: [UInt16]) -> Bool { tail.count <= len && Array(w[(len - tail.count)...]) == tail }
        if ends(u) {
            // Phần cuối trùng lần chèn gần nhất có thể chỉ là Chromium tự đoán.
            let guessed = !g.isEmpty && g.count < n && Array(u[(n - g.count)...]) == g ? g.count : 0
            return (c - n - skip, n - guessed, true)
        }
        var j = n - 1
        while j >= 2 {
            if ends(Array(u[..<j])) { return (c - j - skip, j, false) }                               // trang đã báo j đơn vị đầu
            if !g.isEmpty, ends(Array(u[..<j]) + g) { return (c - j - g.count - skip, j, false) }      // … kèm chữ tự đoán
            j -= 1
        }
        return nil
    }

    /// Hết từ bằng ký tự `ch` (dấu cách, dấu câu) mà trang vẫn chưa cho thấy từ đang đi nguyên văn nằm ở đâu: từ đó thành "còn
    /// nợ" (`webOwed`) — chuỗi gõ tiếp, có bằng chứng thì nó được sửa cùng từ sau.
    private func webShadowCarry(_ ch: Character) -> Bool {
        guard let page = webShadow, web != nil else { return false }
        let finished = engine.finishWord()
        var intended = finished.text
        if case let .replace(_, new) = finished.action { intended = new }
        let sep = String(ch)
        var owed = webOwedValid ?? ("", "")
        owed.raw += page + sep
        owed.intended += intended + sep
        webShadow = nil
        webBefore += page + sep
        anchor += (page + sep).utf16.count
        webOwed = owed.raw.utf16.count <= Self.webOwedLimit && owed.raw != owed.intended ? owed : nil
        webPush(webBefore)
        web?.caret = anchor
        webNextExpect = nil
        log?("ô web: hết từ mà trang chưa cho thấy \(page.debugDescription) — còn nợ \(intended.debugDescription)")
        return true
    }

    /// Phím có tác dụng bộ gõ không biết (⌫, ⏎, mũi tên, phím tắt…) tới lúc trang vẫn chưa cho thấy chuỗi nằm ở đâu: những gì
    /// đang nằm nguyên văn để nguyên như đã gõ.
    private func webShadowAbandon() {
        if webOwed != nil || webShadow != nil {
            trace?("ô web: phím có tác dụng không biết tới lúc chưa có bằng chứng vị trí: phần đang nguyên văn để nguyên")
        }
        webOwed = nil
        guard let page = webShadow else { return }
        log?("ô web: hết từ mà trang chưa cho thấy \(page.debugDescription) — để nguyên văn")
        webShadow = nil
        webSerial &+= 1
        engine.reset()
        webBefore += page
        anchor += page.utf16.count
    }

    /// Lần sửa đầu của chuỗi chưa có bằng chứng vị trí: giữ phím lại, xem bộ đệm sau khi trang có thời gian báo (30 / 70 /
    /// 120 ms) hay ở phím kế tiếp, rồi mới sửa (đúng thứ tự: phím kế tiếp luôn quyết định lần sửa này trước).
    private func deferWebEdit(old: String, new: String, typed: Character, _ client: TextClient) {
        webPending = (old, new, typed)
        webPendingClient = client
        webSerial &+= 1
        let serial = webSerial
        for (i, delay) in [0.03, 0.07, 0.25].enumerated() {
            client.schedule(after: delay) { [weak self, weak client] in
                guard let self, let client, self.webSerial == serial, self.webPending != nil else { return }
                self.flushWebPending(client, check: i)
            }
        }
    }

    /// Quyết định lần sửa đang chờ (`final`: phím kế tiếp, chốt từ — quyết định luôn).
    private func flushWebPending(_ client: TextClient, final: Bool) { flushWebPending(client, check: 2) }

    /// `check` 0: chỉ khi trang đã cho thấy từ nằm chỗ khác / chữ lạ; 1: thêm khi bộ đệm khớp và chứng minh được trang đã báo;
    /// 2: quyết định luôn, theo vị trí của bộ gõ.
    private func flushWebPending(_ client: TextClient, check: Int) {
        guard let p = webPending else { return }
        let c = webPendingClient ?? client
        var trusted = web?.trusted ?? false
        var check = check
        if let chain = web, !chain.proven, !trusted {
            // Đầu chuỗi chưa đáng tin: trang báo dần chữ của chuỗi ở đâu thì đó là bằng chứng (`webProve`).
            if webProve(c, raw: webBefore + p.old, settled: webSettled(c)) {
                web?.proven = true
                web?.trusted = true
                trusted = true
            } else if check == 1, chain.expectBefore == nil {
                // Không có ký tự biết trước nào để chờ: không giữ phím lâu — phím đi nguyên văn, trang báo là sửa lại.
                check = 2
            }
        }
        switch webRead(c, word: p.old) {
        case .current:
            // Chuỗi chưa xác minh: thấy đúng ký tự biết trước ngay trước đầu chuỗi thì vị trí đã chắc (khớp một ký tự cũng đủ).
            let provable = webEvident(c, word: p.old) || (web?.proven ?? false)
                || (trusted ? webProvable(p.old) : webStartConfirmed(c))
            if check < (provable ? 1 : 2) { return }
            // Đầu chuỗi đọc từ bộ đệm có thể cũ: bộ đệm khớp có thể chỉ là trùng hợp trên vị trí cũ (dòng trên, chữ cũ).
            if !trusted, !provable { webShadowStart(c, old: p.old, typed: p.typed); return }
        case .lag:
            if check < 2 { return }
            // Bộ đệm vẫn chưa cho thấy chữ đang gõ mà đầu chuỗi chưa xác minh, hay trang chưa báo gì từ lúc có click: không
            // đoán vị trí.
            if !trusted || webGapSerial != nil { webShadowStart(c, old: p.old, typed: p.typed); return }
        case let .moved(at):
            if !trusted, !webMovedConfirmed(c, at: at) {
                if check < 2 { return }
                // Từ trùng ở chỗ khác có thể là chữ có sẵn: chưa sửa ở đó, chờ thấy lại cùng chỗ sau phím kế tiếp.
                webShadowStart(c, old: p.old, typed: p.typed)
                return
            }
            webMove(to: at, word: p.old)
        case .foreign:
            if check < 2 { return }                    // còn chờ trang báo
            // Bộ đệm có thể vẫn cũ: đọc lại từ là đọc chữ đã xoá.
            if !trusted { webShadowStart(c, old: p.old, typed: p.typed); return }
            webPending = nil
            webSerial &+= 1
            webResync(c, typed: p.typed)
            return
        }
        webPending = nil
        webSerial &+= 1
        web?.proven = true
        web?.trusted = true
        applyWebEdit(old: p.old, new: p.new, c, atPosition: true)
    }

    /// Chuỗi chưa xác minh, từ đang gõ nằm nguyên ở `at`: trước nó đúng là phần chuỗi trước từ và ký tự biết trước (hay đầu ô).
    private func webMovedConfirmed(_ client: TextClient, at: Int) -> Bool {
        guard let chain = web, let expect = chain.expectBefore else { return false }
        let n = webBefore.utf16.count
        guard at - n - 1 >= 0, let t = client.text(location: at - n - 1, length: n + 1) else { return false }
        return t == String(expect) + webBefore || (expect == "\n" && t == "\r" + webBefore)
    }

    /// Chuỗi chưa xác minh: bộ đệm cho thấy đúng ký tự biết trước ngay trước đầu chuỗi (hay đầu chuỗi là đầu ô).
    private func webStartConfirmed(_ client: TextClient) -> Bool {
        guard let chain = web, let expect = chain.expectBefore else { return false }
        if chain.start == 0 { return true }
        guard let t = client.text(location: chain.start - 1, length: 1) else { return false }
        return t == String(expect) || (expect == "\n" && t == "\r")
    }

    /// Chữ trước con trỏ không còn là chuỗi của bộ gõ: đọc lại từ đang nằm trước con trỏ (bộ đệm, sau khi trang đã có thời gian
    /// báo) rồi gõ phím đã giữ lại lên đó; không đọc được thì gõ phím đó nguyên văn.
    private func webResync(_ client: TextClient, typed: Character) {
        engine.reset()
        if let sel = client.selectedRange(), sel.length == 0, sel.location > 0 {
            let len = min(sel.location, 16)
            if let text = client.text(location: sel.location - len, length: len) {
                let word = String(text.reversed().prefix(while: { $0.isLetter }).reversed())
                if !word.isEmpty, word.utf16.count < len || len == sel.location, engine.seed(word) {
                    webMove(to: sel.location - word.utf16.count, word: word)
                    log?("ô web: đọc lại từ \(word.debugDescription) trước con trỏ")
                    if let action = engine.process(typed) {
                        switch action {
                        case .passThrough:
                            client.insertText(String(typed))
                            webNoteInsert(String(typed))
                            webRecord()
                        case let .replace(old, new):
                            applyWebEdit(old: old, new: new, client)
                        }
                        return
                    }
                }
            }
        }
        client.insertText(String(typed))               // phím đã giữ lại: gõ nguyên văn
        webNoteInsert(String(typed))
        trace?("ô web: chữ trước con trỏ không còn là chuỗi của bộ gõ và không đọc lại được: phần còn lại của từ đi nguyên văn")
        engine.reset()
        untracked = true
        web = nil
    }

    /// `atPosition`: chèn theo vị trí (lần sửa đã chờ, gửi trong keyDown của phím sau: chèn tại con trỏ thì Chromium gửi nó SAU
    /// lần thay có vùng của chính phím đó — sai thứ tự).
    private func applyWebEdit(old: String, new: String, _ client: TextClient, atPosition: Bool = false) {
        if let owed = webOwedValid, let chain = web {
            // Còn từ nằm nguyên văn trước từ đang gõ: sửa chung một lần thay, kết thúc ở con trỏ (con trỏ của trang ở lại cuối).
            webOwed = nil
            let keep = String(webBefore.dropLast(owed.raw.count))
            let fullOld = owed.raw + old, fullNew = owed.intended + new
            var common = 0
            var oi = fullOld.startIndex, ni = fullNew.startIndex
            while oi < fullOld.endIndex, ni < fullNew.endIndex, fullOld[oi] == fullNew[ni] {
                common += fullOld[oi].utf16.count
                oi = fullOld.index(after: oi)
                ni = fullNew.index(after: ni)
            }
            let deleteLen = fullOld.utf16.count - common
            let insert = String(fullNew[ni...])
            if deleteLen > 0 || !insert.isEmpty {
                webReplace(client, location: chain.start + keep.utf16.count + common, length: deleteLen, with: insert,
                           before: (keep + fullOld[..<oi]).last)
            }
            webBefore = keep + owed.intended
            anchor = chain.start + webBefore.utf16.count
            lastEdit = (from: old, to: new)
            webPush(webBefore + new)
            web?.caret = anchor + new.utf16.count
            return
        }
        var common = 0
        var oi = old.startIndex, ni = new.startIndex
        while oi < old.endIndex, ni < new.endIndex, old[oi] == new[ni] {
            common += old[oi].utf16.count
            oi = old.index(after: oi)
            ni = new.index(after: ni)
        }
        let deleteLen = old.utf16.count - common
        let insert = String(new[ni...])
        if deleteLen == 0, !atPosition {
            if !insert.isEmpty {
                client.insertText(insert)                       // chèn tại con trỏ thật của trang, đúng thứ tự
                webNoteInsert(insert)
            }
        } else if deleteLen > 0 || !insert.isEmpty {
            webReplace(client, location: anchor + common, length: deleteLen, with: insert, before: (webBefore + old[..<oi]).last)
        }
        lastEdit = (from: old, to: new)
        webPush(webBefore + new)
        web?.caret = anchor + new.utf16.count
    }

    /// Lần thay theo vị trí của ô web: thay `length` đơn vị từ `location` — kết thúc ở con trỏ của chuỗi — bằng `text`.
    /// `before`: ký tự của chuỗi đứng ngay trước `location` (nil: `location` là đầu chuỗi).
    /// - Ô đang có vùng bôi đen ngay sau con trỏ (gợi ý tự điền của thanh địa chỉ / ô tìm kiếm — `webTail`): thay luôn cả vùng
    ///   đó, như khi người dùng gõ đè lên gợi ý. Không thì gợi ý mất bôi đen và dính lại thành chữ thật ("áxyz").
    /// - Gecko bỏ bước đặt vùng chọn khi vùng thay TRÙNG vùng chọn nó đang nhớ (TextInputHandler.mm:
    ///   `!NSEqualRanges(SelectedRange(), *aReplacementRange)`), rồi chèn chữ vào vùng chọn của trang lúc xử lý. Vùng chọn nó
    ///   nhớ có thể là trạng thái giữa chừng của chính lần thay trước (trang đã chọn vùng, chưa chèn chữ): tới lượt, trang đã
    ///   chèn xong lần trước, con trỏ nằm sau chữ đó — chữ mới bị chèn thêm chứ không thay ("â" rồi "ấ" ra "âấ"). Gặp vậy thì
    ///   nới vùng thay sang trái một ký tự đã biết (ghi lại y nguyên) để Gecko buộc phải đặt vùng chọn.
    private func webReplace(_ client: TextClient, location: Int, length: Int, with text: String, before: Character?) {
        var location = location, length = length, text = text
        if webTail > 0, webTailStates == webStateCount {
            length += webTail
        } else if webGuessFree, length > 0, let sel = client.selectedRange(), sel.location == location, sel.length == length {
            var lead = before.map(String.init)
            if lead == nil, location > 0, let t = client.text(location: location - 1, length: 1), t.count == 1 { lead = t }
            if let lead {
                location -= lead.utf16.count
                length += lead.utf16.count
                text = lead + text
            }
        }
        webTail = 0
        client.replaceText(location: location, length: length, with: text)
    }

    private func endWebWord(_ client: TextClient, terminator ch: Character?) {
        continueWordOnNextChar = false
        webNextExpect = ch == "\r" || ch == "\n" ? "\n" : ch == "\t" ? "\t" : nil
        let continues = ch.map { Self.producesText($0) && !"\r\n\t".contains($0) } ?? false
        guard !engine.isEmpty else {
            if continues, web != nil, let ch {
                webAppendBefore(String(ch))
                webPush(webBefore)
                web!.caret += String(ch).utf16.count
            } else {
                webNoteArrow(ch, text: webBefore)
                webLeave(client, text: webBefore)
                web = nil
            }
            return
        }
        var final = engine.displayed
        // Chữ bộ đệm còn cho thấy nếu vừa gửi một lần sửa ở đây (lần sửa có vùng thay không vào bộ đệm trước khi trang báo).
        var shown: String?
        let (text, action) = engine.finishWord()
        // (Gecko: sửa chữ trong keyDown của phím không ra chữ làm chính phím đó bị nuốt — xem `webGuessFree`; chữ để nguyên như
        // đang hiện.)
        if case let .replace(old, new) = action, web.map({ $0.proven || $0.trusted }) ?? false, continues || !webGuessFree {
            // Khôi phục từ tiếng Anh / sửa "ươ" khi hết từ.
            switch webRead(client, word: old) {
            case .foreign:
                web = nil
            case let .moved(at):
                webMove(to: at, word: old)
                shown = webBefore + old
                applyWebEdit(old: old, new: new, client)
                final = text
            case .current, .lag:
                shown = webBefore + old
                applyWebEdit(old: old, new: new, client)
                final = text
            }
        }
        if continues, web != nil, let ch {
            webAppendBefore(final + String(ch))
            webPush(webBefore)
            web!.caret = anchor + final.utf16.count + String(ch).utf16.count
        } else {
            webNoteArrow(ch, text: webBefore + final)
            webLeave(client, text: webBefore + final, shown: shown)
            web = nil
        }
    }

    /// Chuỗi (chữ `text` từ đầu chuỗi) sắp kết thúc bằng một phím bộ gõ không biết tác dụng (⌥⌫, ⌘⌫, mũi tên, ⏎, phím tắt…):
    /// ghi lại con trỏ của bộ đệm (`webLeft`) nếu sau đó thứ duy nhất trang còn có thể chưa báo là phím cuối / lần sửa cuối của
    /// chuỗi và tác dụng của chính phím kết thúc — tức là:
    /// - đầu chuỗi đã được xác minh là thật (đáng tin từ đầu, hay đã có bằng chứng) và lúc chuỗi bắt đầu không còn phím cũ nào
    ///   chưa báo; và
    /// - bộ đệm đang cho thấy một trạng thái của chính chuỗi đó (trọn chuỗi, hay chậm vài phím / lần sửa — lần sửa có vùng thay
    ///   bộ gõ vừa gửi ở đây chưa thể có trong bộ đệm).
    private func webLeave(_ client: TextClient, text: String, shown: String? = nil) {
        webLeft = nil
        guard let chain = web, chain.clean, chain.trusted || chain.proven, webGapSerial == nil,
              let sel = client.selectedRange(), sel.length == 0 else { return }
        let m = sel.location - chain.start
        guard m >= 0, let cached = m == 0 ? "" : client.text(location: chain.start, length: m) else { return }
        // Trạng thái cũ nhất của chuỗi mà bộ đệm có thể đang cho thấy (đúng chữ của nó, hay kèm chữ của lần chèn gần nhất mà
        // Chromium tự đoán): từ đó tới hết chuỗi là những gì trang còn có thể báo trước khi báo tác dụng của phím kết thúc.
        let cu = Array(cached.utf16)
        let g = webLastInsert.map { Array($0.utf16) } ?? []
        var first: Int?
        for (i, state) in webHistory.enumerated() where state.serial >= webSeen {
            let su = Array(state.text.utf16)
            if cu == su || (!g.isEmpty && cu == su + g) {
                first = i
                break
            }
        }
        guard let first else {
            trace?("ô web: hết chuỗi: bộ đệm không khớp trạng thái nào của chuỗi")
            return
        }
        trace?("ô web: hết chuỗi: bộ đệm ở trạng thái cách cuối \(webHistory.count - 1 - first) bước")
        let final = chain.start + text.utf16.count
        // Bộ đệm chỉ đi tới: từ đây nó còn có thể cho thấy con trỏ hiện tại (có thể kèm chữ tự đoán) rồi lần lượt các trạng
        // thái SAU trạng thái đó (trang báo thì chữ tự đoán mất). Không tính con trỏ của chính trạng thái cũ nhất ấy: xoá một
        // từ một ký tự ("d9" rồi ⌥⌫) đưa con trỏ về đúng chỗ đó — tính vào thì tác dụng của phím xoá trông như chưa được báo.
        var pending: Set<Int> = [final, sel.location]
        for state in webHistory[(first + 1)...] { pending.insert(chain.start + state.text.utf16.count) }
        webLeft = (pending, final)
    }

    /// ← / → kết thúc chuỗi: ký tự ngay trước con trỏ mới là ký tự biết trước (của chuỗi, hay chữ có sẵn ngay sau con trỏ) —
    /// bằng chứng vị trí cho chuỗi sau (xem `WebChain.expectBefore`).
    private func webNoteArrow(_ ch: Character?, text: String) {
        guard web != nil else { return }
        switch ch {
        case "\u{F702}":                                      // ←
            let chars = Array(text)
            webNextExpect = chars.count >= 2 ? chars[chars.count - 2] : nil
        case "\u{F703}":                                      // →
            webNextExpect = webSuffix.first
        default:
            break
        }
    }

    /// ⌫ ở ô web. Chuỗi tự theo dõi mọi ⌫ (trang xoá đúng ký tự trước con trỏ, theo thứ tự); lùi qua đầu chuỗi thì đọc ký tự
    /// trước đó từ bộ đệm — phím của chuỗi không đụng tới phần đó, bộ đệm cũ vẫn đúng. Chỉ dựng chuỗi mới từ bộ đệm khi chắc bộ
    /// đệm đã có mọi phím trước (lâu không gõ, hay bộ đệm cho thấy người dùng đã click lùi); không thì ⌫ đi thẳng, từ sau không
    /// gõ tiếp chữ trước con trỏ (mất dấu còn hơn sửa sai chỗ).
    private func webBackspace(_ client: TextClient, dropped: Bool) -> Bool {
        webResumeArmed = false
        if webNeedsProof, !webCatchUp(client, settled: webSettled(client)) { webShadowAbandon() }
        if untracked {
            untracked = false
            engine.reset()
            web = nil
            return false
        }
        var current = client.currentTime() - webLastKeyAt > Self.webIdleBreak
        if let chain = web {
            if current || dropped {
                // Lâu không gõ (dựng lại từ bộ đệm), hay có click / phím tắt bộ gõ không thấy: bỏ cả từ đang gõ.
                engine.reset()
                web = nil
            } else if let sel = client.selectedRange(), sel.length == 0, sel.location != chain.caret {
                let text = webHistory.last?.text ?? webBefore
                let m = sel.location - chain.start
                if m < 0 {
                    // Bộ đệm báo con trỏ trước cả đầu chuỗi: người dùng đã click về trước (trang chậm không báo vậy). Không dựng lại
                    // từ bộ đệm (có thể chưa có mọi phím): ⌫ đi thẳng.
                    log?("ô web: ⌫ — bộ đệm báo con trỏ \(sel.location) trước đầu chuỗi \(chain.start)")
                    engine.reset()
                    web = nil
                } else if webShowsRest(client, sel.location, m: m, model: text),
                   !webStackedGuesses(client, sel.location, m: m, model: text) {
                    log?("ô web: ⌫ — bộ đệm cho thấy con trỏ đã được click về \(sel.location)")
                    engine.reset()
                    web = nil
                    // Trang đã có cả phần chuỗi sau con trỏ: không chậm — trừ khi phím trước cũng là ⌫ (đã áp vào chuỗi cũ sau
                    // click, bộ đệm có thể chưa có nó).
                    current = !webLastWasBackspace
                } else if !webCacheIsOlder(client, sel.location, chain: chain, model: text) {
                    // Bộ đệm cho thấy chữ không có trong chuỗi (⌫ trước đã áp vào chỗ cũ sau một click trang báo muộn…): bỏ chuỗi.
                    log?("ô web: ⌫ — bộ đệm khác chuỗi của bộ gõ, bỏ chuỗi")
                    engine.reset()
                    web = nil
                }
            }
        }
        if web == nil {
            engine.reset()
            webNextExpect = nil                          // ⌫ đi thẳng: không còn biết ký tự trước con trỏ
            guard current, !dropped, let sel = client.selectedRange(), sel.length == 0 else { return false }
            guard webRebuild(client, at: sel.location) else { return false }
        }
        guard engine.isEmpty else { return webBackspaceInWord(client) }
        if webBefore.isEmpty, !webExtendBack(client) {
            web = nil                                    // không đọc được chữ trước chuỗi: thôi theo dõi
            return false
        }
        guard let last = webBefore.last else { return false }   // đầu ô: ⌫ không xoá gì
        guard Self.webSimpleChar(last) else {
            // ⌫ của Blink xoá từng dấu tổ hợp / cả cụm emoji — khác ký tự của Swift: thôi theo dõi.
            web = nil
            return false
        }
        webBefore.removeLast()
        webPush(webBefore)
        web!.caret -= String(last).utf16.count
        webResumeArmed = true
        return false
    }

    /// Dựng chuỗi từ bộ đệm (đã chắc là mới) với chữ trước con trỏ `location`. Cửa sổ không bắt đầu ở đầu ô thì bỏ ký tự đầu (có
    /// thể bị cắt giữa một cặp UTF-16 / một cụm).
    private func webRebuild(_ client: TextClient, at location: Int) -> Bool {
        let len = min(location, Self.webWindow)
        guard let text = len == 0 ? "" : client.text(location: location - len, length: len), text.utf16.count == len else {
            return false
        }
        var before = text
        if len < location, let first = before.first { before.removeFirst(); _ = first }
        web = WebChain(caret: location, start: location - before.utf16.count, proven: false)
        anchor = location
        webBefore = before
        webSetHistory(before)
        webNoteSuffix(client, at: location)
        return true
    }

    /// Ký tự ⌫ của Blink xoá đúng một lần như Swift: một mã Unicode trong BMP, không phải dấu tổ hợp / ký tự nối / chọn biến thể.
    private static func webSimpleChar(_ ch: Character) -> Bool {
        let scalars = Array(ch.unicodeScalars)
        guard scalars.count == 1, let u = scalars.first, u.value < 0x10000, u.value != 0xFFFD else { return false }
        let cat = u.properties.generalCategory
        return cat != .nonspacingMark && cat != .spacingMark && cat != .enclosingMark && cat != .format
            && cat != .surrogate && !(0xFE00...0xFE0F).contains(u.value)
    }

    /// Lùi đầu chuỗi (đọc từ bộ đệm) cho ⌫ sắp xoá vào phần trước chuỗi: thêm ký tự ngay trước đầu chuỗi, cùng cả từ đứng trước nó
    /// và một ký tự ngăn cách trước từ đó (gõ tiếp từ đó sau ⌫ thấy trọn từ). Phím của chuỗi không đụng phần này — bộ đệm cũ vẫn
    /// đúng. Mọi trạng thái trong lịch sử thêm phần đó ở đầu. false nếu không đọc được / gặp ký tự ⌫ của Blink xoá khác Swift.
    /// Ở đầu ô thì không cần gì.
    private func webExtendBack(_ client: TextClient) -> Bool {
        guard var chain = web else { return false }
        guard chain.start > 0 else { return true }
        let len = min(chain.start, 32)
        guard let t = client.text(location: chain.start - len, length: len), t.utf16.count == len else { return false }
        var chars = Array(t)
        if len < chain.start, !chars.isEmpty { chars.removeFirst() }    // ký tự đầu cửa sổ có thể bị cắt
        guard let ch = chars.popLast(), Self.webSimpleChar(ch) else { return false }
        var add = [ch]
        let word = chars.reversed().prefix(while: { $0.isLetter && Self.webSimpleChar($0) })
        if !word.isEmpty, word.count < chars.count, let sep = chars.dropLast(word.count).last, !sep.isLetter, Self.webSimpleChar(sep) {
            add = [sep] + word.reversed() + add
        } else if !word.isEmpty, word.count == chars.count, len == chain.start {
            add = word.reversed() + add                       // từ bắt đầu ở đầu ô
        }
        let c = String(add)
        chain.start -= c.utf16.count
        web = chain
        webBefore = c + webBefore
        webHistory = webHistory.map { WebState(serial: $0.serial, text: c + $0.text, key: $0.key) }
        return true
    }

    /// ⌫ khi đang có từ.
    private func webBackspaceInWord(_ client: TextClient) -> Bool {
        let old = engine.displayed
        guard case let .replace(_, new) = engine.backspace(), let last = old.last else {
            // Ứng dụng tự xoá ký tự cuối.
            webRecord()
            if engine.isEmpty { webResumeArmed = true }
            return false
        }
        // Xoá lùi làm đổi chữ còn lại (kiểu dấu cũ: "hoàn" ⌫ → "hòa"): thay phần đổi nhưng giữ ký tự cuối để chính ứng dụng xoá
        // nó (Chromium chạy ⌫ của nó sau lần thay — xem `backspace`).
        if case .foreign = webRead(client, word: old) {
            engine.reset()
            web = nil
            return false
        }
        applyWebEdit(old: old, new: new + String(last), client)
        webRecord()
        return false
    }

    /// `typed`: ký tự của phím vừa bấm (nếu việc thay đổi do phím đó gây ra). `known`: vị trí con trỏ vừa đọc trong cùng
    /// keyDown (chưa gửi lần sửa nào kể từ đó) — khỏi hỏi lại ứng dụng.
    private func replace(_ old: String, _ new: String, _ client: TextClient, typed: Character? = nil,
                         sel known: (location: Int, length: Int)? = nil) -> Bool {
        let oldLen = old.utf16.count
        guard let sel = known ?? client.selectedRange(), sel.location >= oldLen, sel.location == anchor + oldLen else {
            log?("thay \(old.debugDescription): con trỏ \(client.selectedRange().map { "\($0)" } ?? "-"), cần \(anchor + oldLen)")
            return false
        }
        if oldLen > 0, let current = client.text(location: sel.location - oldLen, length: oldLen), current != old {
            if let stale = staleWord(old), current == stale {
                // Ô vẫn cho đọc từ trước lần thay gần nhất của bộ gõ: bộ đệm phía ứng dụng chưa cập nhật (Chromium / Electron
                // khi trang chậm). Đọc lại từ đó rồi thay sẽ tính sai chỗ — không sửa gì nữa trong từ này.
                log?("thay \(old.debugDescription): ô chưa có lần thay trước (\(current.debugDescription)) — các chữ còn lại đi nguyên văn")
                untracked = true
                return false
            }
            log?("thay \(old.debugDescription): trước con trỏ lại là \(current.debugDescription)")
            replaceMismatch = current
            return false
        }
        // Chỉ thay phần khác nhau để ứng dụng phải làm ít việc nhất. "Giống" là trùng từng code point: chữ đọc lại từ màn hình
        // ở dạng tổ hợp (NFD — tên file của Finder: "u" + U+031B) bằng chữ dựng sẵn theo so sánh của String nhưng dài khác —
        // để nguyên nó thì từ trên màn hình dài khác từ bộ gõ nhớ, phím sau bị coi là "ô chưa cập nhật" và đi nguyên văn.
        var common = 0
        var oi = old.startIndex, ni = new.startIndex
        while oi < old.endIndex, ni < new.endIndex,
              old[oi].unicodeScalars.elementsEqual(new[ni].unicodeScalars) {
            common += old[oi].utf16.count
            oi = old.index(after: oi)
            ni = new.index(after: ni)
        }
        let deleteLen = oldLen - common
        let insert = String(new[ni...])
        let start = sel.location - deleteLen
        // Vùng đang bôi đen sau từ (gợi ý tự động) cũng bị thay luôn.
        let length = deleteLen + sel.length
        if deleteLen == 0 {
            // Chỉ chèn thêm (Telex "w" đầu từ → "ư", "nhw" → "như"): chèn tại con trỏ thật của ứng dụng (thay cả vùng đang bôi
            // đen), không theo vị trí đọc được — ô có bộ đệm chậm (Chromium) sẽ chèn trước phím còn chờ ("nưh").
            client.insertText(insert)
        } else if qtApp, let typed, insert == String(typed), length > 0 {
            // Chuỗi thay vào trùng ký tự phím vừa bấm (vd. "ơ" + "[" -> "[", "ư" + "w" -> "w"): ứng dụng Qt
            // (Telegram...) coi đó là nhấn phím thường, bỏ qua vùng cần thay (và bỏ qua cả lệnh thay bằng
            // chuỗi rỗng) -> "ơ[". Đi qua marked text thì Qt xử lý theo đường của bộ gõ.
            // Chỉ dùng cho Qt: ô nhập liệu trong trang web (Chrome, Electron) lại bỏ qua vùng cần thay
            // của marked text, còn cách thay trực tiếp thì đúng.
            client.replaceViaMarkedText(location: start, length: length, with: insert)
        } else {
            client.replaceText(location: start, length: length, with: insert)
        }
        lastEdit = (from: old, to: new)
        return true
    }
}
