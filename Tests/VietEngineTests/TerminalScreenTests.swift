import XCTest
@testable import VietEngine

/// iTerm2 / Terminal.app với shell in lại chậm, điều khiển từng bước: mỗi lần ghi đổi dòng của shell ngay, còn màn hình
/// (`selectedRange` / `text`) chỉ cho thấy trạng thái sau các lần ghi đã được in lại (`echo`, hay tự in lại sau `latency`
/// giây). `bypass` là phím terminal tự xử lý, không qua bộ gõ (⌫ ở Terminal.app, ← ↑ → ở iTerm2): ghi xuống shell, bộ gõ
/// không thấy.
private final class LagTerm: TextClient {
    typealias State = (cells: [Unicode.Scalar], cursor: Int)
    var cells: [Unicode.Scalar] = []
    var cursor = 0
    var pending: [State] = []
    var shown: State = ([], 0)
    var executed: [String] = []
    let prompt: [Unicode.Scalar] = Array("$ ".unicodeScalars)
    var now = 100.0
    let session = Session()
    let options: EngineOptions
    var history = "git pull origin ma"
    /// > 0: shell tự in lại mỗi lần ghi sau ngần này giây (ssh).
    var latency = 0.0
    /// DEL xoá cả chữ lẫn dấu tổ hợp đi kèm (fish, bash, zsh mặc định), không chỉ một code point.
    var graphemeDel = false
    /// Ứng dụng toàn màn hình (Claude Code…): con trỏ thật của terminal đứng sau chữ này, màn hình không cho thấy dòng gõ.
    var parked: String?
    /// View không cho biết con trỏ (Ghostty, Rex, Muxy: luôn báo 0).
    var blind = false
    /// Số lần bộ gõ hỏi màn hình (con trỏ, chữ) trong lúc xử lý phím, và ngoài lúc đó (việc hẹn giờ).
    var readsInKey = 0, readsOutside = 0
    private var inKey = false
    init(_ m: InputMethod) { options = EngineOptions(method: m) }

    var line: String { String(String.UnicodeScalarView(cells)) }

    func selectedRange() -> (location: Int, length: Int)? {
        countRead()
        if blind { return (0, 0) }
        if let parked { return (parked.utf16.count, 0) }
        return (String(String.UnicodeScalarView(prompt + shown.cells[..<shown.cursor])).utf16.count, 0)
    }
    func text(location: Int, length: Int) -> String? {
        countRead()
        if blind { return nil }
        let u = Array((parked ?? String(String.UnicodeScalarView(prompt + shown.cells))).utf16)
        let from = max(0, min(location, u.count)), to = max(from, min(location + length, u.count))
        return String(decoding: u[from..<to], as: UTF16.self)
    }
    private func countRead() {
        if inKey { readsInKey += 1 } else { readsOutside += 1 }
    }
    func replaceText(location: Int, length: Int, with text: String) { XCTFail("terminal: replaceText") }
    func setMarkedText(_ text: String) { XCTFail("terminal: setMarkedText") }
    func insertText(_ text: String) { write(text) }
    func replaceViaMarkedText(location: Int, length: Int, with text: String) { XCTFail("terminal: marked text") }
    func currentTime() -> Double { now }

    func write(_ t: String) {
        let sc = Array(t.unicodeScalars)
        var k = 0
        while k < sc.count {
            let s = sc[k]
            if s == "\u{7f}" {
                if graphemeDel {
                    while cursor > 0, cells[cursor - 1].properties.generalCategory == .nonspacingMark {
                        cells.remove(at: cursor - 1); cursor -= 1
                    }
                }
                if cursor > 0 { cells.remove(at: cursor - 1); cursor -= 1 }
            } else if s == "\u{1b}", k + 2 < sc.count, sc[k + 1] == "[" {
                if sc[k + 2] == "D" { cursor = max(0, cursor - 1) }
                if sc[k + 2] == "C" { cursor = min(cells.count, cursor + 1) }
                if sc[k + 2] == "A" { cells = Array(history.unicodeScalars); cursor = cells.count }
                k += 2
            } else if s == "\r" {
                executed.append(line)
                cells = []
                cursor = 0
            } else {
                cells.insert(s, at: cursor)
                cursor += 1
            }
            k += 1
        }
        pending.append((cells, cursor))
        if latency > 0 { scheduled.append((now + latency, { [unowned self] in self.echo(1) })) }
    }

    /// Shell in lại `n` lần ghi đầu còn chờ (nil: tất cả).
    func echo(_ n: Int? = nil) {
        let m = min(n ?? pending.count, pending.count)
        guard m > 0 else { return }
        shown = pending[m - 1]
        pending.removeFirst(m)
    }

    /// Phím tới bộ gõ; bộ gõ không xử lý thì terminal tự ghi phím. `ms`: thời gian tới phím sau.
    func key(_ c: Character, _ gap: KeyGap, echoed: Bool = true, ms: Double = 50) {
        let legacy: String? = c == "\r" ? "\r" : c == "\t" ? "\t" : nil
        inKey = true
        let handled = session.handle(.char(c), self, options: options, forceMarked: false, terminal: .inline, gap: gap,
                                     legacy: legacy)
        inKey = false
        if !handled { write(String(c)) }
        if echoed { echo() }
        tick(ms)
    }
    func type(_ s: String, gap: KeyGap = .none, echoed: Bool = true, ms: Double = 50) {
        for c in s { key(c, gap, echoed: echoed, ms: ms) }
    }
    func backspace(_ gap: KeyGap, echoed: Bool = true, ms: Double = 50) {
        inKey = true
        let handled = session.handle(.backspace, self, options: options, forceMarked: false, terminal: .inline, gap: gap,
                                     legacy: "\u{7f}")
        inKey = false
        if !handled { write("\u{7f}") }
        if echoed { echo() }
        tick(ms)
    }
    func bypass(_ bytes: String, ms: Double = 10) { write(bytes); tick(ms) }

    /// Việc bộ gõ hẹn giờ (đo thời gian in lại…), chạy theo đồng hồ giả.
    var scheduled: [(due: Double, work: () -> Void)] = []
    func schedule(after delay: Double, _ work: @escaping () -> Void) { scheduled.append((now + delay, work)) }

    func tick(_ ms: Double) {
        let end = now + ms / 1000
        while let i = scheduled.indices.min(by: { scheduled[$0].due < scheduled[$1].due }), scheduled[i].due <= end {
            let item = scheduled.remove(at: i)
            now = max(now, item.due)
            item.work()
        }
        now = end
    }
}

/// Như `ScreenTerminal` (SessionTests) nhưng biết ký tự nào do shell gõ (Tab tự hoàn thành) để đếm DEL xoá nhầm.
private final class CompletingTerminal: TextClient {
    var cells: [Character] = []
    var shellTyped: Set<Int> = []        // vị trí (trong `cells`) các ký tự do shell gõ
    var cursor = 0
    let base = 100
    var inFlight: [String] = []
    var now = 1000.0
    let session = Session()
    var options: EngineOptions
    var foreignDeletes = 0

    init(_ method: InputMethod) { options = EngineOptions(method: method) }

    var line: String { String(cells) }

    func selectedRange() -> (location: Int, length: Int)? { (base + cursor, 0) }
    func text(location: Int, length: Int) -> String? {
        let from = location - base, to = from + length
        guard from >= 0, to <= cells.count, from <= to else { return nil }
        return String(cells[from..<to])
    }
    func replaceText(location: Int, length: Int, with text: String) { XCTFail("terminal: replaceText") }
    func setMarkedText(_ text: String) { XCTFail("terminal: marked text") }
    func insertText(_ text: String) { inFlight.append(text) }
    func replaceViaMarkedText(location: Int, length: Int, with text: String) { XCTFail("terminal: marked text") }
    func currentTime() -> Double { now }

    func echo() {
        for chunk in inFlight {
            for scalar in chunk.unicodeScalars {
                if scalar == "\u{7f}" {
                    if cursor > 0 {
                        if shellTyped.contains(cursor - 1) { foreignDeletes += 1 }
                        cells.remove(at: cursor - 1); cursor -= 1
                        shellTyped = Set(shellTyped.compactMap { $0 < cursor ? $0 : ($0 > cursor ? $0 - 1 : nil) })
                    }
                } else {
                    shellTyped = Set(shellTyped.map { $0 >= cursor ? $0 + 1 : $0 })
                    cells.insert(Character(scalar), at: cursor); cursor += 1
                }
            }
        }
        inFlight = []
    }

    /// Việc bộ gõ hẹn giờ (đo thời gian in lại…), chạy theo đồng hồ giả.
    var scheduled: [(due: Double, work: () -> Void)] = []
    func schedule(after delay: Double, _ work: @escaping () -> Void) { scheduled.append((now + delay, work)) }

    func tick(_ ms: Double) {
        let end = now + ms / 1000
        while let i = scheduled.indices.min(by: { scheduled[$0].due < scheduled[$1].due }), scheduled[i].due <= end {
            let item = scheduled.remove(at: i)
            now = max(now, item.due)
            item.work()
        }
        now = end
    }

    func type(_ keys: String, ms: Double = 120, echoes: Bool = true, gap: KeyGap = .none) {
        for k in keys {
            if !session.handle(.char(k), self, options: options, forceMarked: false, terminal: .inline, gap: gap) {
                insertText(String(k))
            }
            if echoes { echo() }
            tick(ms)
        }
    }

    /// Phím terminal tự xử lý mà không đổi gì trên dòng (→ ở cuối dòng, Tab không có gì để thêm).
    func bypassNoop() { tick(30) }
    func bypassBackspace() { cells.remove(at: cursor - 1); cursor -= 1; tick(100) }
    /// Tab tự hoàn thành (shell gõ `s`).
    func bypassComplete(_ s: String) {
        for c in s { shellTyped.insert(cursor); cells.insert(c, at: cursor); cursor += 1 }
        tick(100)
    }
}

/// Ghostty (kiểu `.deferred`), việc hẹn giờ chạy theo đồng hồ giả. `nested`: phím được xử lý lồng trong lần bộ gõ hỏi
/// marked text kế tiếp (InputMethodKit phục vụ yêu cầu tới trong lúc bộ gõ chờ trả lời) — câu trả lời là của lúc trước phím đó.
private final class NestingTerm: TextClient {
    var line: [Unicode.Scalar] = []
    var mark = false
    let session = Session()
    let options = EngineOptions(method: .vni)
    var now = 0.0
    var nested: Character?
    var scheduled: [(due: Double, work: () -> Void)] = []

    var text: String { String(String.UnicodeScalarView(line)) }

    func selectedRange() -> (location: Int, length: Int)? { (0, 0) }
    func text(location: Int, length: Int) -> String? { nil }
    func replaceText(location: Int, length: Int, with text: String) { XCTFail("terminal: replaceText") }
    func setMarkedText(_ text: String) { mark = !text.isEmpty }
    func insertText(_ text: String) { mark = false; write(text) }
    func replaceViaMarkedText(location: Int, length: Int, with text: String) { XCTFail("terminal: marked text") }
    func currentTime() -> Double { now }
    func hasMarkedText() -> Bool {
        let answer = mark
        if let c = nested {
            nested = nil
            key(c)
        }
        return answer
    }
    func schedule(after delay: Double, _ work: @escaping () -> Void) { scheduled.append((now + delay, work)) }

    func write(_ t: String) {
        for s in t.unicodeScalars {
            if s == "\u{7f}" { if !line.isEmpty { line.removeLast() } } else { line.append(s) }
        }
    }
    func key(_ c: Character) {
        if !session.handle(.char(c), self, options: options, forceMarked: false, terminal: .deferred) { write(String(c)) }
    }
    func tick(_ ms: Double) {
        let end = now + ms / 1000
        while let i = scheduled.indices.min(by: { scheduled[$0].due < scheduled[$1].due }), scheduled[i].due <= end {
            let item = scheduled.remove(at: i)
            now = max(now, item.due)
            item.work()
        }
        now = end
    }
}

/// Lúc sổ phím chưa chắc ở terminal có màn hình: màn hình chỉ là bằng chứng khi đã in lại một ký tự gõ sau phím báo có
/// phím chưa thấy (shell in lại đúng thứ tự), và ⏎ chỉ sửa từ khi sổ phím chứng minh sạch (review 2026-11-05).
final class TerminalScreenTests: XCTestCase {
    /// Terminal.app qua ssh: "ba " o s, ⌫ bấm ngay sau s (được đếm lúc đọc s, ứng dụng xử lý sau s), n đọc lúc màn hình đã
    /// in s mà chưa in ⌫. Sổ phím: s chưa chắc, n chưa chắc (không có gì mới). Không được xoá dấu cách của từ trước.
    func testStaleScreenAfterKeptWord() {
        let t = LagTerm(.telex)
        t.type("ba ")
        t.key("o", .none, echoed: false)
        t.key("s", .unsure, echoed: false)
        t.bypass("\u{7f}")
        t.echo(2)                                 // 'o' và 's' đã in, ⌫ chưa
        t.key("n", .unsureSteady, echoed: false)
        t.echo()
        XCTAssertEqual(t.line, "ba on")
    }

    /// Như trên nhưng màn hình đã in 'o' lúc đọc s (khớp ngay ở s).
    func testStaleScreenAtFirstSteadyKey() {
        let t = LagTerm(.telex)
        t.type("ba ")
        t.key("o", .none)
        t.key("s", .unsure, echoed: false)
        t.bypass("\u{7f}")
        t.echo(1)
        t.key("n", .unsureSteady, echoed: false)
        t.echo()
        XCTAssertEqual(t.line, "ba on")
    }

    /// iTerm2 qua ssh: "echo to" 6, ← bấm ngay sau 6, ⏎ đọc lúc màn hình vẫn là "echo to6|": ⏎ không được chạy lệnh bộ gõ
    /// đã sửa theo màn hình cũ.
    func testEnterNeverFixedFromScreen() {
        let t = LagTerm(.vni)
        t.type("echo to")
        t.key("6", .unsure, echoed: false)
        t.bypass("\u{1b}[D")
        t.echo(1)
        t.key("\r", .unsureSteady, echoed: false)
        XCTAssertEqual(t.executed, ["echo to6"])
    }

    /// iTerm2: a, ↑ gọi lại "git pull origin ma" (màn hình tình cờ cũng kết thúc bằng 'a'), 1, ⏎: không xoá chữ của lịch sử.
    func testEnterDoesNotDeleteHistoryText() {
        let t = LagTerm(.vni)
        t.key("a", .none)
        t.bypass("\u{1b}[A")
        t.echo()
        t.key("1", .unsure)
        t.key("\r", .unsureSteady, echoed: false)
        XCTAssertEqual(t.executed, ["git pull origin ma1"])
    }

    /// Phím chưa chắc thứ hai: phím đang tới ("s") được thay bằng ⌫ bấm ngay sau nó, số dư không đổi — sổ phím vẫn báo "không
    /// có gì mới". ⌫ là phím đặc biệt: KeyWatch thấy nó và sắp thứ tự bằng bộ đếm, nên "n" nhận `.bypassed`. Màn hình cũ
    /// ("ba os|") không được dùng: không xoá dấu cách của từ trước.
    func testStaleScreenAtSecondSteadyKey() {
        let t = LagTerm(.telex)
        t.type("ba ")
        t.key("o", .unsure, echoed: false)
        t.key("s", .unsureSteady, echoed: false)
        t.bypass("\u{7f}")
        t.echo(2)
        t.key("n", .bypassed, echoed: false)
        t.echo()
        t.key(" ", .none)
        XCTAssertEqual(t.line, "ba on ")
    }

    /// iTerm2 qua ssh: k, ← (đã in), rồi h o 6 n g lúc sổ phím chưa chắc, → bấm ngay sau g, ␣ đọc lúc màn hình đã in
    /// "ho6ng|k" mà chưa in →: không bắt đầu lại từ màn hình cũ rồi xoá 'k'.
    func testNoRestartFromStaleScreen() {
        let t = LagTerm(.vni)
        t.key("k", .none)
        t.bypass("\u{1b}[D")
        t.echo()
        t.key("h", .unsure, echoed: false)
        t.key("o", .unsure, echoed: false)
        t.key("6", .unsure, echoed: false)
        t.key("n", .unsureSteady, echoed: false)
        t.key("g", .unsure, echoed: false)
        t.bypass("\u{1b}[C")
        t.echo(5)
        t.key(" ", .unsureSteady)
        XCTAssertTrue(t.line.contains("k"), t.line)
    }

    /// Ứng dụng treo rồi các phím tới dồn, phím cuối (⏎) sạch: sửa cả từ cùng ⏎.
    func testStallBurstFixedWithCleanEnter() {
        let t = LagTerm(.vni)
        t.type("echo to")
        t.key("6", .unsure, echoed: false)
        t.key("\r", .none, echoed: false)
        XCTAssertEqual(t.executed, ["echo tô"])
    }

    /// Terminal.app: ⌫ (không qua bộ gõ) rồi gõ tiếp, màn hình in kịp: thêm dấu được (từ ký tự gõ sau ⌫).
    func testBackspaceBypassThenType() {
        let t = LagTerm(.vni)
        t.type("tie61ng")
        t.bypass("\u{7f}"); t.bypass("\u{7f}"); t.bypass("\u{7f}")
        t.echo()
        t.key("e", .unsure)
        t.key("6", .unsureSteady)
        t.key("5", .unsureSteady)
        t.key("t", .unsureSteady)
        XCTAssertEqual(t.line, "tiệt")
    }

    /// Terminal.app VNI: "ti", → (không đổi gì; Terminal.app tự xử lý, bộ gõ thấy qua trạng thái phím: phím sau nhận
    /// `.bypassed`), "e" khi shell chưa in "i", "6" khi màn hình đã cho thấy "tie" (từ cũ đúng, thêm dấu), ⌫ (không qua bộ
    /// gõ), "e6n" gõ liền: từ bắt đầu lại từ "e" gõ sau ⌫ — "tiên".
    func testRestartAfterOldWordWasConfirmed() {
        let t = CompletingTerminal(.vni)
        t.type("echo ", ms: 100)                         // shell in lại ngay: bộ gõ đo được thời gian in lại ngắn
        t.type("t", ms: 100)
        t.type("i", ms: 25, echoes: false)
        t.bypassNoop()
        t.type("e", ms: 100, echoes: false, gap: .bypassed)
        t.echo()
        t.type("6", ms: 100)
        XCTAssertEqual(t.line, "echo tiê")
        t.bypassBackspace()
        t.type("e", ms: 100, gap: .bypassed)
        t.type("6n", ms: 100)
        XCTAssertEqual(t.line, "echo tiên")
    }

    /// Cùng các phím nhưng sổ phím chỉ biết "có phím chưa thấy" (`.unsure`: phím đó có thể được bấm ngay sau "e"): màn hình
    /// in lại "e" chưa chứng minh gì, "6" đi nguyên văn — không bao giờ xoá gì ngoài chữ bộ gõ gõ.
    func testUnsureLeadKeyNeedsALaterKey() {
        let t = CompletingTerminal(.vni)
        t.type("echo ", ms: 100)
        t.type("t", ms: 100)
        t.type("i", ms: 25, echoes: false)
        t.bypassNoop()
        t.type("e", ms: 100, echoes: false, gap: .unsure)
        t.echo()
        t.type("6", ms: 100, gap: .unsureSteady)
        XCTAssertEqual(t.line, "echo tie6")
        t.type("t ", ms: 100, gap: .unsureSteady)          // giờ đã có ký tự gõ sau phím nghi vấn: sửa cả từ
        XCTAssertEqual(t.line, "echo tiêt ")
        XCTAssertEqual(t.foreignDeletes, 0)
    }

    /// Telex, còn phím chưa thấy; màn hình lệch ở "a", màn hình cho thấy "va" ở "o", rồi "f" tới khi "o" chưa in: không
    /// bắt đầu lại từ "a" cũ rồi xoá "o" ("vaà").
    func testStaleCharsDoNotMatchLaggingScreen() {
        let t = CompletingTerminal(.telex)
        t.type("echo ", ms: 100)                         // shell in lại ngay: bộ gõ biết thời gian in lại ngắn
        t.type("v", ms: 40, echoes: false, gap: .unsure)
        t.type("a", ms: 100, echoes: false, gap: .unsureSteady)
        t.echo()
        t.type("o", ms: 50, echoes: false, gap: .unsureSteady)
        t.type("f", ms: 50, echoes: false, gap: .unsureSteady)
        t.echo()
        t.type(" ", ms: 100, gap: .unsureSteady)
        XCTAssertEqual(t.line, "echo vào ")
    }

    /// Cùng các phím nhưng chưa biết thời gian in lại (vừa bắt đầu): không kết luận gì từ màn hình, chữ đi nguyên văn —
    /// không bao giờ xoá gì.
    func testUnknownEchoTimeStaysRaw() {
        let t = CompletingTerminal(.telex)
        t.type("v", ms: 40, echoes: false, gap: .unsure)
        t.type("a", ms: 100, echoes: false, gap: .unsureSteady)
        t.echo()
        t.type("o", ms: 50, echoes: false, gap: .unsureSteady)
        t.type("f", ms: 50, echoes: false, gap: .unsureSteady)
        t.echo()
        t.type(" ", ms: 100, gap: .unsureSteady)
        XCTAssertEqual(t.line, "vaof ")
        XCTAssertEqual(t.foreignDeletes, 0)
    }

    /// Terminal.app Telex: Tab tự hoàn thành thêm "e" sau khi từ cũ đã được xác nhận: "e" cũ + "s" không được khớp với
    /// "e" của shell — không bao giờ DEL chữ do shell gõ.
    func testCompletionCharsNeverDeleted() {
        let t = CompletingTerminal(.telex)
        t.type("t", ms: 100)
        t.type("i", ms: 25, echoes: false)
        t.bypassNoop()
        t.type("e", ms: 100, echoes: false, gap: .unsure)
        t.echo()
        t.type("n", ms: 80, gap: .unsureSteady)
        t.bypassComplete("e")
        t.type("s", ms: 100, gap: .unsure)
        t.type("t", ms: 100, gap: .unsureSteady)
        XCTAssertEqual(t.foreignDeletes, 0)
        XCTAssertEqual(t.line, "tienest")
    }

    /// Telex chữ đôi, không có phím đi vòng, màn hình chậm đúng một phím: không được bắt đầu lại từ đuôi 1 ký tự trùng
    /// ("chaá" thay cho "chấ").
    func testDoubleLetterTailIsNotARestart() {
        let t = LagTerm(.telex)
        t.type("ch")
        t.key("a", .unsure, echoed: false)
        t.key("a", .unsureSteady, echoed: false)
        t.echo(1)                                  // màn hình "cha", 'a' thứ hai chưa in
        t.key("s", .unsureSteady, echoed: false)
        t.echo()
        t.key(" ", .none)
        XCTAssertEqual(t.line, "chấ ")
    }

    // MARK: - Review 6 (2026-11-05)

    /// iTerm2: "echo ba", ← (iTerm2 tự xử lý; bộ gõ thấy qua trạng thái phím: phím sau nhận `.bypassed`), "f", rồi ⏎ với sổ
    /// phím sạch trước khi màn hình kịp quyết định: ⏎ chạy lệnh ngay — không được sửa dòng theo từ cũ ("echo àa"). Hai lần ←
    /// xen giữa thì màn hình không bao giờ quyết định được: không được xoá dấu cách ("echoãfa").
    func testEnterAfterKnownBypassNeverRewrites() {
        let t = LagTerm(.telex)
        t.type("echo ba")
        t.bypass("\u{1b}[D")
        t.echo()
        t.key("f", .bypassed, echoed: false)
        t.key("\r", .none, echoed: false)
        XCTAssertEqual(t.executed, ["echo bfa"])

        let u = LagTerm(.telex)
        u.type("echo ba")
        u.bypass("\u{1b}[D")
        u.echo()
        u.key("f", .bypassed, ms: 300)
        u.bypass("\u{1b}[D")
        u.echo()
        u.key("x", .bypassed, ms: 300)
        u.key("\r", .none, echoed: false)
        XCTAssertEqual(u.executed, ["echo bxfa"])
    }

    /// iTerm2: "a", ↑ gọi lại "git pull origin ma" (dòng lạ tình cờ kết thúc bằng 'a'), "f" (`.bypassed`), rồi ⏎ hay dấu cách:
    /// không xoá 'a' của lịch sử ("git pull origin mà") — cả khi phím tới ngay (màn hình chưa quyết định), lẫn khi màn hình đã
    /// in lại "…maf" (giống từ cũ + "f" nhưng 'a' không đứng đầu từ).
    func testHistoryRecallNeverEditsHistoryText() {
        for (end, wait) in [("\r", 20.0), ("\r", 300.0), (" ", 300.0)] {
            let t = LagTerm(.telex)
            t.type("echo ")                           // đo được thời gian in lại
            t.key("a", .none)
            t.bypass("\u{1b}[A")
            t.echo()
            t.key("f", .bypassed, echoed: wait > 50, ms: wait)
            t.key(Character(end), .none, echoed: false)
            let line = end == "\r" ? t.executed.first : t.line
            XCTAssertEqual(line, end == "\r" ? "git pull origin maf" : "git pull origin maf ", "\(end.debugDescription) \(wait) ms")
        }
    }

    /// Tự khôi phục từ không phải tiếng Việt cả khi từ kết thúc bằng ⏎ / ⇥ (sổ phím sạch): "nvm use⏎" chạy "nvm use", không
    /// phải "nvm úe" — như khi kết thúc bằng dấu cách. Từ tiếng Việt thì ⏎ đi thẳng như cũ.
    func testEnterRestoresNonVietnameseWord() {
        for keys in ["nvm use", "echo user", "echo we"] {
            let t = LagTerm(.telex)
            t.type(keys)
            t.key("\r", .none)
            XCTAssertEqual(t.executed, [keys])
        }
        let v = LagTerm(.vni)
        v.type("echo to6i")
        v.key("\r", .none)
        XCTAssertEqual(v.executed, ["echo tôi"])
        let tab = LagTerm(.telex)
        tab.type("cd use")
        tab.key("\t", .none)
        XCTAssertEqual(tab.line, "cd use\t")
        // Sổ phím chưa chắc lúc ⏎: không sửa gì, ⏎ đi thẳng (như trước).
        let u = LagTerm(.telex)
        u.type("nvm use")
        u.key("\r", .unsure)
        XCTAssertEqual(u.executed, ["nvm úe"])
    }

    /// ssh in lại chậm (200–300 ms), gõ đều tay nhanh hơn thế, sổ phím sạch: màn hình luôn chậm một phím. Chưa đo được thời
    /// gian in lại thì không được coi là "đã lâu không in lại" rồi bỏ từ ở mọi phím ("to6i ye6u…" thô).
    func testSlowEchoKeepsWords() {
        for (latency, ms) in [(0.2, 160.0), (0.2, 190.0), (0.25, 160.0), (0.25, 220.0), (0.3, 160.0), (0.3, 220.0)] {
            let t = LagTerm(.vni)
            t.latency = latency
            t.type("to6i ye6u tie61ng Vie65t d9i ", echoed: false, ms: ms)
            t.tick(1000)
            XCTAssertEqual(t.line, "tôi yêu tiếng Việt đi ", "in lại \(latency) s, \(ms) ms/phím")
        }
    }

    /// Ứng dụng toàn màn hình (Claude Code trong iTerm2): con trỏ thật đứng chỗ khác, màn hình không bao giờ cho thấy dòng gõ.
    /// Gõ đều tay ở mọi nhịp vẫn ra đúng chữ; và sau vài lần không thấy gì, bộ gõ thôi hỏi màn hình ngoài lúc gõ.
    func testParkedCursorTUI() {
        for ms in [120.0, 180.0, 230.0, 300.0, 400.0] {
            let t = LagTerm(.vni)
            t.parked = "> Try \"how does x work\"\n  ? for shortcuts"
            t.type("tie61ng Vie65t ", ms: ms)
            XCTAssertEqual(t.line, "tiếng Việt ", "\(ms) ms/phím")
            XCTAssertTrue(t.readsOutside <= 20, "\(ms) ms/phím: \(t.readsOutside) lần hỏi ngoài lúc gõ")
        }
        // Đã đo được thời gian in lại (gõ ở dấu nhắc trước khi mở ứng dụng toàn màn hình).
        for ms in [120.0, 180.0, 230.0] {
            let t = LagTerm(.vni)
            t.type("echo ")
            t.parked = "> Try \"how does x work\"\n  ? for shortcuts"
            t.cells = []
            t.cursor = 0
            t.type("tie61ng Vie65t ", ms: ms)
            XCTAssertEqual(t.line, "tiếng Việt ", "đã đo, \(ms) ms/phím")
        }
    }

    /// Như `testStaleScreenAfterKeptWord`, nhưng trước "o" có một phím đi vòng không đổi gì (→ ở cuối dòng; "o" nhận
    /// `.bypassed`): ký tự của phím chưa chắc ("s") vẫn không phải bằng chứng — không xoá dấu cách hay chữ của lịch sử.
    func testKnownBypassThenUnsureKeyNeedsALaterKey() {
        let t = LagTerm(.telex)
        t.type("ba ")
        t.key("o", .bypassed)
        t.key("s", .unsure, echoed: false)
        t.bypass("\u{7f}")
        t.echo(1)                                 // 's' đã in, ⌫ chưa
        t.key("n", .unsureSteady, echoed: false)
        t.echo()
        XCTAssertEqual(t.line, "ba on")

        let h = LagTerm(.telex)                   // chữ trước từ là của lịch sử
        h.cells = Array("git commit -m ".unicodeScalars)
        h.cursor = h.cells.count
        h.shown = (h.cells, h.cursor)
        h.key("o", .bypassed)
        h.key("s", .unsure, echoed: false, ms: 10)
        h.bypass("\u{7f}", ms: 200)
        h.echo(1)
        h.key("n", .unsureSteady, echoed: false)
        h.echo()
        XCTAssertEqual(h.line, "git commit -m on")

        // Không có phím chưa thấy nào thật: ký tự gõ sau đó vẫn là bằng chứng, sửa cả từ.
        let c = LagTerm(.telex)
        c.type("ba ")
        c.key("o", .bypassed)
        c.key("s", .unsure)
        c.key("n", .unsureSteady)
        c.key(" ", .unsureSteady)
        XCTAssertEqual(c.line, "ba ón ")
    }

    /// Từ chỉ gồm một chữ lặp lại ("ll"): màn hình chưa in lại phím mới cũng đã kết thúc bằng từ đó — không được coi là đo
    /// được thời gian in lại (ssh 100 ms: `bound` tụt còn 15 ms, màn hình cũ bị coi là đã in xong).
    func testRepeatedLetterDoesNotFakeEchoMeasurement() {
        let t = LagTerm(.telex)
        t.latency = 0.1
        t.type("echo ", echoed: false, ms: 300)
        t.type("lll", echoed: false, ms: 300)
        t.backspace(.none, echoed: false, ms: 300)
        XCTAssertGreaterThan(t.session.echo.bound, 0.1)
    }

    /// Bảo mật nhập liệu (sổ phím không dùng được): ↑ gọi lại dòng có tên file dán từ Finder (chữ tổ hợp, NFD). Không nạp lại
    /// từ đó để sửa — một DEL của shell xoá cả chữ lẫn dấu, đếm DEL theo code point sẽ xoá lố ('h').
    func testDecomposedWordOnScreenNotReseeded() {
        let t = LagTerm(.telex)
        t.graphemeDel = true
        t.history = "ls ho\u{300}a"
        t.key("x", .unverified, ms: 300)
        t.bypass("\u{1b}[A", ms: 300)
        t.echo()
        t.key("s", .unverified, ms: 300)
        XCTAssertTrue(t.line.unicodeScalars.starts(with: "ls ho\u{300}a".unicodeScalars), t.line.debugDescription)
    }

    /// ssh in lại 100 ms, gõ 150 ms/phím: đo thời gian in lại không được tốn hai lần hỏi màn hình ở mọi mốc của mọi phím
    /// (trước: 10 lần hỏi mỗi phím, ngoài lúc gõ — vẫn chặn luồng chính của bộ gõ khi terminal bận).
    func testEchoProbesStayCheap() {
        let t = LagTerm(.vni)
        t.latency = 0.1
        t.type("to6i ye6u tie61ng Vie65t ", echoed: false, ms: 150)
        t.tick(1000)
        XCTAssertEqual(t.line, "tôi yêu tiếng Việt ")
        XCTAssertGreaterThan(t.session.echo.bound, 0.1)
        XCTAssertTrue(t.readsOutside <= 60, "\(t.readsOutside) lần hỏi ngoài lúc gõ")
    }

    /// iTerm2 / Terminal.app: mỗi phím hỏi màn hình ít nhất có thể trong keyDown — chữ đầu từ không hỏi gì, các phím sau chỉ hai
    /// lần (con trỏ, chữ trước con trỏ).
    func testScreenReadsPerKey() {
        let t = LagTerm(.vni)
        t.type("to6i ye6u ")
        XCTAssertEqual(t.line, "tôi yêu ")
        XCTAssertEqual(t.readsInKey, 16)
    }

    /// View không cho biết con trỏ (Ghostty, Rex, Muxy luôn báo 0): sau vài lần, bộ gõ thôi hỏi con trỏ ở mỗi phím (mỗi lần là
    /// một lần chờ ứng dụng trong keyDown) — chữ vẫn ra đúng. Thỉnh thoảng hỏi lại: view hoá ra có con trỏ thật thì đối chiếu màn
    /// hình như thường (← không qua bộ gõ: không xoá nhầm).
    func testBlindTerminalStopsAskingForCursor() {
        let t = LagTerm(.vni)
        t.blind = true
        t.type("to6i ye6u tie61ng Vie65t, d9e5p la81m ")
        XCTAssertEqual(t.line, "tôi yêu tiếng Việt, đẹp lắm ")
        XCTAssertTrue(t.readsInKey <= 10, "\(t.readsInKey) lần hỏi")
        XCTAssertEqual(t.readsOutside, 0)

        t.blind = false
        t.type("to6i ye6u tie61ng Vie65t, d9e5p la81m ")
        t.type("tie")
        t.bypass("\u{1b}[D", ms: 200)
        t.echo()
        t.key("6", .none)
        XCTAssertTrue(t.line.hasSuffix(" ti6e"), t.line)
    }

    /// Ghostty: InputMethodKit xử lý phím kế tiếp ngay trong lúc bộ gõ chờ ứng dụng trả lời (đồng bộ). Câu trả lời cũ không được
    /// làm mất lần sửa mới (marked text rỗng kẹt lại), hay gửi lần sửa cũ lần nữa.
    func testNestedKeyDuringDeferredCheck() {
        let t = NestingTerm()
        t.key("t"); t.key("i"); t.key("e")
        t.key("6")                       // lần sửa #1 chờ gửi
        t.tick(10)                       // đã gửi: "tiê", hẹn kiểm tra sau 30 ms
        t.nested = "1"                   // "1" tới trong lúc kiểm tra hỏi marked text: lần sửa #2
        t.tick(40)
        t.tick(100)
        XCTAssertEqual(t.text, "tiế")
        XCTAssertFalse(t.mark)

        let u = NestingTerm()
        u.key("t"); u.key("i"); u.key("e")
        u.key("6")                       // lần sửa chưa gửi
        u.nested = "n"                   // "n" tới trong lúc chốt hỏi marked text (phím đó đã gửi lần sửa)
        u.session.commit(u)
        u.tick(100)
        XCTAssertEqual(u.text, "tiên")
        XCTAssertFalse(u.mark)
    }
}
