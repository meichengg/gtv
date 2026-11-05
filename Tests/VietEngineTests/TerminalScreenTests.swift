import XCTest
@testable import VietEngine

/// iTerm2 / Terminal.app với shell in lại chậm, điều khiển từng bước: mỗi lần ghi đổi dòng của shell ngay, còn màn hình
/// (`selectedRange` / `text`) chỉ cho thấy trạng thái sau các lần ghi đã được in lại (`echo`). `bypass` là phím terminal
/// tự xử lý, không qua bộ gõ (⌫ ở Terminal.app, ← ↑ → ở iTerm2): ghi xuống shell, bộ gõ không thấy.
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
    init(_ m: InputMethod) { options = EngineOptions(method: m) }

    var line: String { String(String.UnicodeScalarView(cells)) }

    func selectedRange() -> (location: Int, length: Int)? {
        (String(String.UnicodeScalarView(prompt + shown.cells[..<shown.cursor])).utf16.count, 0)
    }
    func text(location: Int, length: Int) -> String? {
        let u = Array(String(String.UnicodeScalarView(prompt + shown.cells)).utf16)
        let from = max(0, min(location, u.count)), to = max(from, min(location + length, u.count))
        return String(decoding: u[from..<to], as: UTF16.self)
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
    }

    /// Shell in lại `n` lần ghi đầu còn chờ (nil: tất cả).
    func echo(_ n: Int? = nil) {
        let m = min(n ?? pending.count, pending.count)
        guard m > 0 else { return }
        shown = pending[m - 1]
        pending.removeFirst(m)
    }

    /// Phím tới bộ gõ; bộ gõ không xử lý thì terminal tự ghi phím.
    func key(_ c: Character, _ gap: KeyGap, echoed: Bool = true) {
        let legacy: String? = c == "\r" ? "\r" : nil
        if !session.handle(.char(c), self, options: options, forceMarked: false, terminal: .inline, gap: gap,
                           legacy: legacy) {
            write(String(c))
        }
        if echoed { echo() }
        now += 0.05
    }
    func type(_ s: String) { for c in s { key(c, .none) } }
    func bypass(_ bytes: String) { write(bytes); now += 0.01 }
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

    func tick(_ ms: Double) { now += ms / 1000 }

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

    /// Phím chưa chắc thứ hai (phím đang tới được thay bằng phím đi vòng bấm sau nó, số dư không đổi), màn hình cũ.
    func testStaleScreenAtSecondSteadyKey() {
        let t = LagTerm(.telex)
        t.type("ba ")
        t.key("o", .unsure, echoed: false)
        t.key("s", .unsureSteady, echoed: false)
        t.bypass("\u{7f}")
        t.echo(2)
        t.key("n", .unsureSteady, echoed: false)
        t.echo()
        XCTAssertEqual(t.line, "ba on")
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

    /// Terminal.app VNI: "ti", → (không đổi gì), "e" khi shell chưa in "i" (nghi từ "e"), "6" khi màn hình đã cho thấy
    /// "tie" (từ cũ đúng, thêm dấu), ⌫ (không qua bộ gõ), "e6n" gõ liền: từ phải bắt đầu lại từ "e" gõ sau ⌫ — "tiên".
    func testRestartAfterOldWordWasConfirmed() {
        let t = CompletingTerminal(.vni)
        t.type("echo ", ms: 100)                         // shell in lại ngay: bộ gõ biết thời gian in lại ngắn
        t.type("t", ms: 100)
        t.type("i", ms: 25, echoes: false)
        t.bypassNoop()
        t.type("e", ms: 100, echoes: false, gap: .unsure)
        t.echo()
        t.type("6", ms: 100, gap: .unsureSteady)
        XCTAssertEqual(t.line, "echo tiê")
        t.bypassBackspace()
        t.type("e", ms: 100, gap: .unsure)
        t.type("6n", ms: 100, gap: .unsureSteady)
        XCTAssertEqual(t.line, "echo tiên")
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
}
