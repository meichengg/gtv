import XCTest
@testable import VietEngine

/// Ô nhập liệu giả, mô phỏng hành vi của ứng dụng thật.
private final class Field: TextClient {
    var units: [UInt16] = []          // văn bản (UTF-16)
    var sel = (location: 0, length: 0)
    var readable = true               // ứng dụng có cho đọc văn bản không
    var suggestions: [String] = []    // gợi ý tự động kiểu thanh địa chỉ
    /// Mô phỏng ứng dụng Qt (Telegram): chuỗi chèn vào trùng ký tự phím đang bấm thì bị coi là nhấn
    /// phím thường — bỏ qua vùng cần thay, chèn tại con trỏ.
    var qtStyle = false
    /// Mô phỏng ô nhập liệu trong trang web (Chrome, Electron): marked text bỏ qua vùng cần thay,
    /// đặt tại con trỏ; thay trực tiếp thì đúng.
    var chromiumStyle = false
    private var currentKey: Character?

    let session = Session()
    var options = EngineOptions()

    var text: String { String(decoding: units, as: UTF16.self) }

    // MARK: TextClient
    func selectedRange() -> (location: Int, length: Int)? { sel }
    func text(location: Int, length: Int) -> String? {
        guard readable, location >= 0, location + length <= units.count else { return nil }
        return String(decoding: units[location..<location + length], as: UTF16.self)
    }
    func replaceText(location: Int, length: Int, with s: String) {
        if qtStyle, let k = currentKey, s == String(k) || s.isEmpty {
            // Qt: chuỗi trùng phím đang bấm -> coi như phím thường; chuỗi rỗng -> bị bỏ qua.
            if !s.isEmpty { insertAtCursor(s) }
            return
        }
        units.replaceSubrange(location..<location + length, with: Array(s.utf16))
        sel = (location + s.utf16.count, 0)
        autocomplete()
    }
    func setMarkedText(_ text: String) {}
    func replaceViaMarkedText(location: Int, length: Int, with s: String) {
        if chromiumStyle { insertAtCursor(s); return }
        // Qt và ứng dụng Cocoa: marked text thay đúng vùng, sau đó chốt.
        units.replaceSubrange(location..<location + length, with: Array(s.utf16))
        sel = (location + s.utf16.count, 0)
    }
    func insertText(_ text: String) { insertAtCursor(text) }

    private func insertAtCursor(_ text: String) {
        units.replaceSubrange(sel.location..<sel.location + sel.length, with: Array(text.utf16))
        sel = (sel.location + text.utf16.count, 0)
        autocomplete()
    }

    // MARK: Thao tác của người dùng
    func type(_ keys: String) {
        for k in keys {
            currentKey = k
            if !session.handle(.char(k), self, options: options, forceMarked: false, qtApp: qtStyle) {
                insertText(String(k))        // ứng dụng tự xử lý phím
            }
            currentKey = nil
        }
    }

    func backspace() {
        if session.handle(.backspace, self, options: options, forceMarked: false, qtApp: qtStyle) { return }
        if sel.length > 0 {
            units.removeSubrange(sel.location..<sel.location + sel.length)
        } else if sel.location > 0 {
            let before = String(decoding: units[0..<sel.location], as: UTF16.self)
            let n = before.last!.utf16.count
            units.removeSubrange(sel.location - n..<sel.location)
            sel.location -= n
        }
        sel.length = 0
    }

    /// Cmd+A — ứng dụng tự xử lý, bộ gõ không thấy.
    func selectAll() { sel = (0, units.count) }

    private func autocomplete() {
        let t = text
        guard sel.location == units.count, !t.isEmpty,
              let s = suggestions.first(where: { $0.hasPrefix(t) && $0 != t }) else { return }
        let rest = Array(s.utf16.dropFirst(units.count))
        units += rest
        sel.length = rest.count
    }
}

/// Terminal giả, dùng chế độ gạch chân: phím đi qua và chữ chốt (`insertText`) tới shell ngay, không sửa lại
/// được nữa; marked text (gạch chân) chỉ hiện trên màn hình, chưa tới shell.
private final class Terminal: TextClient {
    var shell = ""            // những gì shell đã nhận
    var marked = ""           // marked text đang hiện
    let session = Session()
    var options = EngineOptions()

    var screen: String { shell + marked }

    func selectedRange() -> (location: Int, length: Int)? { (0, 0) }
    func text(location: Int, length: Int) -> String? { nil }
    func replaceText(location: Int, length: Int, with text: String) {
        XCTFail("terminal không sửa được chữ đã gửi (thay bằng \"\(text)\")")
    }
    func setMarkedText(_ text: String) { marked = text }
    func insertText(_ text: String) { marked = ""; shell += text }
    func replaceViaMarkedText(location: Int, length: Int, with text: String) {
        XCTFail("terminal không sửa được chữ đã gửi (thay bằng \"\(text)\")")
    }

    func type(_ keys: String) {
        for k in keys where !session.handle(.char(k), self, options: options, forceMarked: true) {
            // Bộ gõ phải chốt marked text trước khi để terminal tự xử lý phím.
            XCTAssertEqual(marked, "", "phím \(k) đi thẳng khi còn marked text")
            shell.append(k)
        }
    }

    func backspace() {
        if session.handle(.backspace, self, options: options, forceMarked: true) { return }
        XCTAssertEqual(marked, "", "Backspace đi thẳng khi còn marked text")
        if !shell.isEmpty { shell.removeLast() }
    }
}

/// Shell giả sau một terminal (chế độ terminal): phím đi thẳng và chuỗi `insertText` được ghi xuống shell
/// ngay; DEL (0x7F) xoá một ký tự như phím Backspace. Không được dùng marked text.
private final class Shell: TextClient {
    var line: [Character] = []       // dòng lệnh của shell (mỗi phần tử một code point)
    var writes: [String] = []        // từng lần terminal ghi xuống shell
    let session = Session()
    var options = EngineOptions()
    var style = TerminalStyle.inline

    var text: String { String(String.UnicodeScalarView(line.flatMap { $0.unicodeScalars })) }

    func selectedRange() -> (location: Int, length: Int)? { (0, 0) }
    func text(location: Int, length: Int) -> String? { nil }
    func replaceText(location: Int, length: Int, with text: String) { XCTFail("terminal: không thay được chữ") }
    /// Kiểu `.deferred` (Ghostty): chỉ được dùng marked text rỗng U+200B (không hiện) để giữ phím.
    func setMarkedText(_ text: String) {
        if text == "\u{200B}" { invisibleMarks += 1; markActive = true } else { XCTFail("terminal: không được gạch chân (\(text))") }
    }
    func insertText(_ text: String) {
        markActive = false           // insertText thay marked text (như Ghostty)
        write(text)
    }
    var markActive = false
    func hasMarkedText() -> Bool { markActive }
    func replaceViaMarkedText(location: Int, length: Int, with text: String) { XCTFail("terminal: marked text") }

    var invisibleMarks = 0
    /// false: việc "sau keyDown" bị trễ (phím sau tới trước) — chạy bằng `runLater()`.
    var runScheduledNow = true
    private var later: [() -> Void] = []
    func schedule(_ work: @escaping () -> Void) {
        if runScheduledNow { work() } else { later.append(work) }
    }
    func schedule(after delay: Double, _ work: @escaping () -> Void) { later.append(work) }
    func runLater() {
        let works = later
        later = []
        works.forEach { $0() }
    }

    private func write(_ s: String) {
        writes.append(s)
        for scalar in s.unicodeScalars {
            if scalar == "\u{7f}" {
                if !line.isEmpty { line.removeLast() }
            } else {
                line.append(Character(scalar))
            }
        }
    }

    func type(_ keys: String) {
        for k in keys where !session.handle(.char(k), self, options: options, forceMarked: false, terminal: style) {
            write(String(k))
        }
    }

    func backspace() {
        if !session.handle(.backspace, self, options: options, forceMarked: false, terminal: style) { write("\u{7f}") }
    }

    /// Phím đặc biệt (Ctrl+E, mũi tên…): bộ gõ không được giữ lại.
    func other() -> Bool { session.handle(.other, self, options: options, forceMarked: false, terminal: style) }
}

/// Terminal giả có màn hình + con trỏ như iTerm2 / Terminal.app: báo vị trí con trỏ và cho đọc chữ trên màn
/// hình; chữ ghi xuống shell chỉ hiện sau khi shell in lại (`echo()`); một số phím terminal tự xử lý mà không
/// qua bộ gõ (`bypass…`).
private final class ScreenTerminal: TextClient {
    var cells: [Character] = []
    var cursor = 0
    let base = 100                     // vị trí tuyệt đối của ô đầu dòng
    var inFlight: [String] = []        // đã ghi xuống shell, chưa in lại lên màn hình
    var now = 1000.0
    let session = Session()
    var options = EngineOptions(method: .vni)

    var line: String { String(cells) }

    func selectedRange() -> (location: Int, length: Int)? { (base + cursor, 0) }
    func text(location: Int, length: Int) -> String? {
        let from = location - base, to = from + length
        guard from >= 0, to <= cells.count, from <= to else { return nil }
        return String(cells[from..<to])
    }
    func replaceText(location: Int, length: Int, with text: String) { XCTFail("terminal: không thay được chữ") }
    func setMarkedText(_ text: String) { XCTFail("terminal: không được gạch chân (\(text))") }
    func insertText(_ text: String) { inFlight.append(text) }
    func replaceViaMarkedText(location: Int, length: Int, with text: String) { XCTFail("terminal: marked text") }
    func currentTime() -> Double { now }

    /// Shell in lại mọi thứ đã nhận (DEL xoá ký tự trước con trỏ, chữ chèn tại con trỏ).
    func echo() {
        for chunk in inFlight {
            for scalar in chunk.unicodeScalars {
                if scalar == "\u{7f}" {
                    if cursor > 0 { cells.remove(at: cursor - 1); cursor -= 1 }
                } else {
                    cells.insert(Character(scalar), at: cursor); cursor += 1
                }
            }
        }
        inFlight = []
    }

    func tick(_ ms: Double) { now += ms / 1000 }

    /// Gõ (mỗi phím cách nhau `ms`), shell in lại ngay sau mỗi phím nếu `echoes`.
    func type(_ keys: String, ms: Double = 120, echoes: Bool = true) {
        for k in keys {
            if !session.handle(.char(k), self, options: options, forceMarked: false, terminal: .inline) {
                insertText(String(k))
            }
            if echoes { echo() }
            tick(ms)
        }
    }

    func bypassLeft() { cursor -= 1; tick(120) }
    func bypassLineStart() { cursor = 0; tick(120) }
    func bypassBackspace() { cells.remove(at: cursor - 1); cursor -= 1; tick(120) }
}

final class SessionTests: XCTestCase {
    func testTypingThroughSession() {
        let f = Field()
        f.type("Tooi yeeu tieengs Vieetj, ddepj lawms!")
        XCTAssertEqual(f.text, "Tôi yêu tiếng Việt, đẹp lắm!")
    }

    /// Gõ, Cmd+A, Delete, gõ lại — bộ gõ không thấy Cmd+A.
    func testSelectAllDeleteRetype() {
        let cases: [(String, String, String)] = [
            ("uw", "uw", "ư"), ("ow", "ow", "ơ"), ("ee", "ee", "ê"), ("w", "w", "ư"),
            ("oo thees", "oo", "ô"), ("dd", "dd", "đ"), ("vieetj", "aa", "â"),
        ]
        for readable in [true, false] {
            for (first, again, expected) in cases {
                let f = Field()
                f.readable = readable
                f.type(first)
                f.selectAll()
                f.backspace()
                f.type(again)
                XCTAssertEqual(f.text, expected, "\(first) -> \(again), readable=\(readable)")
            }
        }
    }

    /// Cmd+A rồi gõ đè luôn (không xoá).
    func testSelectAllOverwrite() {
        for readable in [true, false] {
            let f = Field()
            f.readable = readable
            f.type("ow")
            f.selectAll()
            f.type("uw")
            XCTAssertEqual(f.text, "ư", "readable=\(readable)")
        }
    }

    /// Thanh địa chỉ có gợi ý tự động đang bôi đen sau con trỏ.
    func testAutocomplete() {
        let f = Field()
        f.suggestions = ["dantri.com.vn", "oops.com", "tuoitre.vn"]
        f.type("dd")
        XCTAssertEqual(f.text, "đ")
        let g = Field()
        g.suggestions = f.suggestions
        g.type("oo")
        XCTAssertEqual(g.text, "ô")
        let h = Field()
        h.suggestions = f.suggestions
        h.type("tuoi")
        XCTAssertEqual(h.text, "tuoitre.vn")
        h.type("o")                          // gợi ý "tre.vn" đang bôi đen bị thay luôn
        XCTAssertEqual(h.text, "tuôi")
    }

    /// Backspace khi có gợi ý tự động: chỉ xoá gợi ý, từ đang gõ giữ nguyên.
    func testBackspaceOnSuggestion() {
        let f = Field()
        f.suggestions = ["vietnamnet.vn"]
        f.type("vie")
        XCTAssertEqual(f.text, "vietnamnet.vn")
        f.backspace()
        XCTAssertEqual(f.text, "vie")
        f.type("e")
        XCTAssertEqual(f.text, "viê")
    }

    /// Văn bản đổi ngoài tầm bộ gõ (Cmd+Z, dán...) ở giữa từ.
    func testExternalEdit() {
        let f = Field()
        f.type("tieng")
        f.units = Array("xin chao".utf16)
        f.sel = (8, 0)
        f.type("f")
        XCTAssertEqual(f.text, "xin chào")
    }

    /// Telegram (Qt): "[[" từng ra "ơ[" vì chuỗi thay vào trùng ký tự phím vừa bấm.
    func testQtStyleApp() {
        let cases: [(String, String)] = [
            ("[[", "["), ("]]", "]"), ("[[[", "[["), ("ww", "w"), ("t[[", "t["),
            ("vieetj", "việt"), ("dduwowngf", "đường"), ("ass", "as"), ("aaa", "aa"),
        ]
        for (keys, expected) in cases {
            let f = Field()
            f.qtStyle = true
            f.type(keys)
            XCTAssertEqual(f.text, expected, keys)
        }
    }

    /// Ô nhập liệu trong trang web (ô "Ask Google" của Chrome, Claude desktop): bản 1.10.4 dùng marked
    /// text cho "[[" ở mọi ứng dụng nên ra "ơ[". Chỉ ứng dụng Qt mới dùng marked text.
    func testChromiumWebField() {
        let cases: [(String, String)] = [
            ("[[", "["), ("]]", "]"), ("ww", "w"), ("t[[", "t["), ("vieetj", "việt"), ("dduwowngf", "đường"),
        ]
        for (keys, expected) in cases {
            let f = Field()
            f.chromiumStyle = true
            f.type(keys)
            XCTAssertEqual(f.text, expected, keys)
        }
    }

    /// Xoá lùi vào một từ đã gõ xong rồi gõ tiếp: "hoirr " → xoá " ", "r" → "hoi" → gõ "r" → "hỏi".
    func testContinueWordAfterBackspace() {
        let f = Field()
        f.type("hoirr ")
        XCTAssertEqual(f.text, "hoir ")
        f.backspace(); f.backspace()
        XCTAssertEqual(f.text, "hoi")
        f.type("r")
        XCTAssertEqual(f.text, "hỏi")

        let g = Field()
        g.type("viet ")
        g.backspace(); g.backspace()          // "vie"
        g.type("etj")
        XCTAssertEqual(g.text, "việt")

        let h = Field()
        h.type("toi ")
        h.backspace()                         // xoá dấu cách, còn "toi"
        h.type("f")
        XCTAssertEqual(h.text, "tòi")

        // Gõ sau dấu cách vẫn là từ mới, không nối vào từ trước
        let k = Field()
        k.type("toi f")
        XCTAssertEqual(k.text, "toi f")

        // Ứng dụng không cho đọc văn bản: không đọc lại được, gõ như từ mới (không ghi sai chỗ)
        let m = Field()
        m.readable = false
        m.type("hoirr ")
        m.backspace(); m.backspace()
        m.type("r")
        XCTAssertEqual(m.text, "hoir")
    }

    func testBackspaceInWord() {
        let f = Field()
        f.type("vieetj")
        f.backspace()
        f.backspace()
        XCTAssertEqual(f.text, "vi")
        f.type("eets")
        XCTAssertEqual(f.text, "viết")
    }

    // MARK: - Terminal (chế độ gạch chân)

    func testTerminalVietnamese() {
        let telex = Terminal()
        telex.type("Tooi yeeu tieengs Vieetj, ddepj lawms! Nguowif, Ddaof, quys, gif, ww.")
        XCTAssertEqual(telex.shell, "Tôi yêu tiếng Việt, đẹp lắm! Người, Đào, quý, gì, w.")
        XCTAssertEqual(telex.marked, "")

        let vni = Terminal()
        vni.options.method = .vni
        vni.type("To6i ye6u tie61ng Vie65t, d9e5p la81m! git commit -m \"Su73a lo64i\"")
        XCTAssertEqual(vni.shell, "Tôi yêu tiếng Việt, đẹp lắm! git commit -m \"Sửa lỗi\"")
        XCTAssertEqual(vni.marked, "")
    }

    /// Issue #2: lệnh tiếng Anh phải tới shell ngay khi gõ (để hiện gợi ý lệnh), không bị giữ trong phần
    /// gạch chân tới khi gõ dấu cách. Chỉ phần còn có thể thêm dấu mới bị giữ lại.
    func testTerminalSendsKeysEarly() {
        // (kiểu gõ, phím, shell đã nhận, đang gạch chân)
        let cases: [(InputMethod, String, String, String)] = [
            (.telex, "ls -la", "ls -l", "a"),           // "la" có thể thành "là"
            (.telex, "brew", "brew", ""),               // "br" không phải tiếng Việt: chốt ngay
            (.telex, "cd ~/Downloads", "cd ~/Downloads", ""),
            (.telex, "git st", "git st", ""),
            (.telex, "git status", "git status", ""),
            (.telex, "npm", "npm", ""),
            (.telex, "echo", "echo", ""),
            (.telex, "text", "text", ""),               // "tẽ" + t: khôi phục rồi chốt
            (.telex, "make", "make", ""),
            (.telex, "git", "g", "it"),                 // còn có thể thành "gít"
            (.telex, "nguowif", "ng", "ười"),
            (.telex, "dd", "", "đ"),                    // d có thể thành đ
            (.telex, "w", "", "ư"),
            (.vni, "ls -la", "ls -l", "a"),
            (.vni, "cd ~/Downloads", "cd ~/Downloads", ""),
            (.vni, "git checkout -b fix2", "git checkout -b fix2", ""),
            (.vni, "nguo7i2", "ng", "ười"),
        ]
        for (method, keys, shell, marked) in cases {
            let t = Terminal()
            t.options.method = method
            t.type(keys)
            XCTAssertEqual(t.shell, shell, "\(method) \(keys)")
            XCTAssertEqual(t.marked, marked, "\(method) \(keys)")
        }
    }

    func testTerminalBackspace() {
        let t = Terminal()
        t.type("tooi")
        XCTAssertEqual(t.shell, "t")
        XCTAssertEqual(t.screen, "tôi")
        t.backspace()                     // xoá trong phần gạch chân
        XCTAssertEqual(t.screen, "tô")
        t.type("s")
        XCTAssertEqual(t.screen, "tố")
        t.backspace()
        XCTAssertEqual(t.screen, "t")
        XCTAssertEqual(t.marked, "")
        t.backspace()                     // "t" đã ở shell: terminal tự xoá
        XCTAssertEqual(t.screen, "")
        t.type("ddi ")
        XCTAssertEqual(t.shell, "đi ")

        // Xoá phụ âm đầu đã gửi rồi gõ tiếp
        let u = Terminal()
        u.type("thx")
        XCTAssertEqual(u.shell, "thx")
        let v = Terminal()
        v.type("tr")
        v.backspace()
        v.type("hoaf")
        XCTAssertEqual(v.shell, "th")
        XCTAssertEqual(v.screen, "thòa")

        // Từ đã chốt (không phải tiếng Việt), xoá lùi rồi gõ tiếp: không ghi sai chỗ
        let w = Terminal()
        w.type("dock")
        XCTAssertEqual(w.shell, "dock")
        w.backspace()
        w.type("s ")
        XCTAssertEqual(w.shell, "docs ")
    }

    /// Click chuột / mất focus: chỉ chốt phần đang gạch chân, không gửi lại phần đã tới shell.
    func testTerminalCommit() {
        let t = Terminal()
        t.type("nguowif")
        t.session.commit(t)
        XCTAssertEqual(t.shell, "người")
        XCTAssertEqual(t.marked, "")
        t.type("ls")
        t.session.commit(t)
        XCTAssertEqual(t.shell, "ngườils")
    }

    // MARK: - Chế độ terminal (không gạch chân)

    func testTerminalModeVietnamese() {
        for style in TerminalStyle.allCases {
            let telex = Shell()
            telex.style = style
            telex.type("Tooi yeeu tieengs Vieetj, ddepj lawms! Nguowif, Ddaof, quys, gif, ww, text, windows.")
            XCTAssertEqual(telex.text, "Tôi yêu tiếng Việt, đẹp lắm! Người, Đào, quý, gì, w, text, windows.", "\(style)")

            let vni = Shell()
            vni.style = style
            vni.options.method = .vni
            vni.type("To6i ye6u tie61ng Vie65t, d9e5p la81m! git commit -m \"Su73a lo64i\" ls -la")
            XCTAssertEqual(vni.text, "Tôi yêu tiếng Việt, đẹp lắm! git commit -m \"Sửa lỗi\" ls -la", "\(style)")
        }
    }

    /// Issue #2: mọi phím tới shell ngay khi gõ (gợi ý của fish hiện ngay), Ctrl+E không bị giữ lại.
    func testTerminalModeKeysReachShellImmediately() {
        let t = Shell()
        t.options.method = .vni
        for (i, k) in "./suo".enumerated() {
            t.type(String(k))
            XCTAssertEqual(t.text, String(Array("./suo")[0...i]))
        }
        XCTAssertFalse(t.other(), "Ctrl+E phải tới shell")
        t.type("x")
        XCTAssertEqual(t.text, "./suox")
    }

    /// Mỗi lần sửa là một lần ghi: xoá và chữ mới tới shell cùng lúc (shell vẽ lại một lần, không nháy).
    func testTerminalModeEditsAreSingleWrites() {
        let t = Shell()
        t.type("tieengs Vieetj nguowif")
        let edits = t.writes.filter { $0.contains("\u{7f}") }
        XCTAssertFalse(edits.isEmpty)
        for w in edits {
            XCTAssertFalse(w.hasSuffix("\u{7f}"), "sửa phải kèm chữ mới trong cùng lần ghi: \(w.debugDescription)")
            XCTAssertNotEqual(w.unicodeScalars.first, "\u{7f}", "kiểu inline mở đầu bằng ký tự thường: \(w.debugDescription)")
        }
    }

    func testTerminalModeBackspace() {
        let t = Shell()
        t.options.method = .vni
        t.type("tie61ng")
        XCTAssertEqual(t.text, "tiếng")
        t.backspace(); t.backspace(); t.backspace()
        XCTAssertEqual(t.text, "ti")
        t.type("e65t ")
        XCTAssertEqual(t.text, "tiệt ")

        // Xoá hết rồi gõ lại
        let u = Shell()
        u.type("dd")
        u.backspace()
        XCTAssertEqual(u.text, "")
        u.type("ddi")
        XCTAssertEqual(u.text, "đi")
    }

    /// Ghostty (kiểu .deferred): giữ phím bằng marked text rỗng rồi gửi xoá + chữ mới sau keyDown.
    func testTerminalModeDeferred() {
        for now in [true, false] {
            let t = Shell()
            t.style = .deferred
            t.options.method = .vni
            t.runScheduledNow = now
            t.type("To6i ye6u tie61ng Vie65t, d9e5p la81m! ls -la ./suo")
            t.runLater()
            XCTAssertEqual(t.text, "Tôi yêu tiếng Việt, đẹp lắm! ls -la ./suo", "chạy ngay=\(now)")
            XCTAssertGreaterThan(t.invisibleMarks, 0)
        }
        // Phím sau tới trước khi lần sửa trước kịp gửi: lần sửa vẫn tới shell trước phím đó.
        let u = Shell()
        u.style = .deferred
        u.options.method = .vni
        u.runScheduledNow = false
        u.type("tie6")
        XCTAssertEqual(u.text, "tie")       // chưa gửi
        u.type("n")
        XCTAssertEqual(u.text, "tiên")
        u.runLater()                        // lần gửi cũ đến muộn: không gửi lại
        XCTAssertEqual(u.text, "tiên")
    }

    /// Phím đặc biệt (mũi tên, Ctrl+…) giữa từ: bộ gõ thôi theo dõi từ, không xoá nhầm chữ của shell.
    func testTerminalModeNeverDeletesShellText() {
        let t = Shell()
        t.line = Array("echo ")
        t.type("vie")
        _ = t.other()                 // vd. Ctrl+A rồi Ctrl+E, shell đổi chỗ con trỏ
        t.type("6")
        XCTAssertEqual(t.text, "echo vie6")
    }
    // MARK: - Terminal: phím terminal tự xử lý, không qua bộ gõ

    /// iTerm2: mũi tên không qua bộ gõ. Gõ "tie", ←, "6": không được xoá nhầm (chữ "e" sau con trỏ còn đó).
    func testTerminalGuardArrowBypass() {
        let t = ScreenTerminal()
        t.type("tie")
        t.bypassLeft()
        t.type("6")
        XCTAssertEqual(t.line, "ti6e")
    }

    /// Terminal.app: Backspace không qua bộ gõ. Gõ "tie61ng", xoá 3 lần, gõ tiếp "e65t ": đọc lại từ trên màn hình.
    func testTerminalGuardBackspaceBypass() {
        let t = ScreenTerminal()
        t.type("tie61ng")
        XCTAssertEqual(t.line, "tiếng")
        t.bypassBackspace(); t.bypassBackspace(); t.bypassBackspace()
        t.type("e65t ")
        XCTAssertEqual(t.line, "tiệt ")
    }

    /// Ctrl+A không qua bộ gõ: con trỏ về đầu dòng, phím dấu tiếp theo không xoá chữ phía sau.
    func testTerminalGuardLineStartBypass() {
        let t = ScreenTerminal()
        t.type("tie")
        t.bypassLineStart()
        t.type("6")
        XCTAssertEqual(t.line, "6tie")
    }

    /// Shell chưa kịp in lại chữ vừa gõ (gõ nhanh, ssh): con trỏ đứng sau là bình thường, vẫn thêm dấu đúng.
    func testTerminalGuardEchoLag() {
        let t = ScreenTerminal()
        t.type("tie6", ms: 30, echoes: false)
        t.echo()
        XCTAssertEqual(t.line, "tiê")
        let u = ScreenTerminal()
        u.type("Vie65t Nam to6i", ms: 20, echoes: false)
        u.echo()
        XCTAssertEqual(u.line, "Việt Nam tôi")
    }

    /// Gõ bình thường (shell in lại ngay): kết quả như không có kiểm tra con trỏ.
    func testTerminalGuardNormalTyping() {
        let t = ScreenTerminal()
        t.type("To6i ye6u tie61ng Vie65t, d9e5p la81m!")
        XCTAssertEqual(t.line, "Tôi yêu tiếng Việt, đẹp lắm!")
    }
}
