import XCTest
@testable import VietEngine

/// Mô phỏng một ô nhập liệu: áp dụng các Action của engine lên văn bản.
private func type(_ keys: String, _ options: EngineOptions = EngineOptions()) -> String {
    let engine = Engine(options: options)
    var text = ""
    func apply(_ action: Action, key: Character?) {
        switch action {
        case .passThrough:
            if let key { text.append(key) }
        case let .replace(old, new):
            XCTAssertTrue(text.hasSuffix(old), "'\(text)' không kết thúc bằng '\(old)'")
            text = String(text.dropLast(old.count)) + new
        }
    }
    for k in keys {
        if k == "<" {           // "<" = Backspace
            if engine.isEmpty { if !text.isEmpty { text.removeLast() } ; continue }
            let a = engine.backspace()
            if case .passThrough = a { text.removeLast() } else { apply(a, key: nil) }
            continue
        }
        if let a = engine.process(k) {
            apply(a, key: k)
        } else {
            apply(engine.finishWord().action, key: nil)
            text.append(k)
        }
    }
    apply(engine.finishWord().action, key: nil)
    return text
}

final class TelexTests: XCTestCase {
    func testBasicWords() {
        let cases: [(String, String)] = [
            ("vieetj", "việt"), ("Vieetj Nam", "Việt Nam"), ("tieengs", "tiếng"),
            ("dduwowngf", "đường"), ("nguwowif", "người"), ("nguoiwf", "người"),
            ("truowngf", "trường"), ("thuowr", "thuở"), ("huow", "huơ"),
            ("quas", "quá"), ("gif", "gì"), ("giuwx", "giữ"), ("gias", "giá"),
            ("khuyeenx", "khuyễn"), ("muaw", "mưa"), ("hoawcj", "hoặc"),
            ("tooi", "tôi"), ("dd", "đ"), ("DDaij", "Đại"), ("VIEETJ", "VIỆT"),
            ("khuyr", "khủy"), ("khuyur", "khuỷu"), ("hoaij", "hoại"),
            ("nghieengs", "nghiếng"), ("xooong", "xoong"), ("uw", "ư"), ("w", "ư"),
            ("tw", "tư"), ("ddi", "đi"), ("cuwus", "cứu"), ("ruouwj", "rượu"),
            ("tieesng", "tiếng"), ("chuyeenj", "chuyện"), ("ddeemf", "đềm"),
            ("hoaf", "hòa"), ("thuys", "thúy"), ("khoer", "khỏe"), ("hoanf", "hoàn"),
            ("giowf", "giờ"), ("cos", "có"), ("nuwax", "nữa"), ("ddoongf", "đồng"),
        ]
        for (k, v) in cases { XCTAssertEqual(type(k), v, k) }
    }

    func testModernToneStyle() {
        let o = EngineOptions(modernToneStyle: true)
        XCTAssertEqual(type("hoaf", o), "hoà")
        XCTAssertEqual(type("thuys", o), "thuý")
        XCTAssertEqual(type("khoer", o), "khoẻ")
        XCTAssertEqual(type("khuyr", o), "khuỷ")
        XCTAssertEqual(type("hoanf", o), "hoàn")
        XCTAssertEqual(type("hoaf<", o), "ho")
    }

    func testUndo() {
        XCTAssertEqual(type("ass"), "as")
        XCTAssertEqual(type("lass"), "las")
        XCTAssertEqual(type("aa "), "â ")
        XCTAssertEqual(type("aw "), "ă ")
        XCTAssertEqual(type("aab"), "aab")    // "âb" không phải tiếng Việt
        XCTAssertEqual(type("aaa"), "aa")
        XCTAssertEqual(type("ddd"), "dd")
        XCTAssertEqual(type("ww"), "w")
        XCTAssertEqual(type("aww"), "aw")
        XCTAssertEqual(type("asz"), "a")
    }

    func testEnglishRestore() {
        for w in ["windows", "facebook", "text", "users", "string", "they", "the", "class",
                  "google", "with", "Windows", "express", "dead", "banana", "chrome"] {
            XCTAssertEqual(type(w), w, w)
        }
        XCTAssertEqual(type("text", EngineOptions(autoRestore: false)) != "text", true)
    }

    func testSimpleTelex() {
        let o = EngineOptions(method: .simpleTelex)
        XCTAssertEqual(type("w", o), "w")
        XCTAssertEqual(type("uw", o), "ư")
        XCTAssertEqual(type("nguwowif", o), "người")
        XCTAssertEqual(type("a[0]", o), "a[0]")
    }

    func testBrackets() {
        XCTAssertEqual(type("t]"), "tư")
        XCTAssertEqual(type("m["), "mơ")
        XCTAssertEqual(type("["), "ơ")
        XCTAssertEqual(type("[["), "[")
        XCTAssertEqual(type("[[["), "[[")
        XCTAssertEqual(type("]"), "ư")
        XCTAssertEqual(type("]]"), "]")
        XCTAssertEqual(type("{{"), "{")
        XCTAssertEqual(type("}}"), "}")
        XCTAssertEqual(type("m[["), "m[")
        XCTAssertEqual(type("[]"), "ơ]")
        XCTAssertEqual(type("ww"), "w")
    }

    func testBackspace() {
        XCTAssertEqual(type("hoaf<"), "hò")
        XCTAssertEqual(type("vieetj<<"), "vi")
        XCTAssertEqual(type("ass<s"), "á")
        XCTAssertEqual(type("hoanf<"), "hòa")
    }

    func testSentence() {
        XCTAssertEqual(type("Tooi yeeu tieengs Vieetj, ddepj lawms!"), "Tôi yêu tiếng Việt, đẹp lắm!")
    }
}

final class InformalSpellingTests: XCTestCase {
    func testTelex() {
        let cases: [(String, String)] = [
            ("zij", "zị"), ("zaayj", "zậy"), ("zui", "zui"), ("zoo", "zô"), ("zaf", "zà"),
            ("dzaayj", "dzậy"), ("dzoo", "dzô"), ("qas", "qá"), ("Zaayj", "Zậy"),
            ("zij zaayj", "zị zậy"),
            // Chính tả chuẩn không bị ảnh hưởng
            ("vaayj", "vậy"), ("quas", "quá"), ("gif", "gì"), ("asz", "a"),
        ]
        for (k, v) in cases { XCTAssertEqual(type(k), v, k) }
    }

    func testVNI() {
        let o = EngineOptions(method: .vni)
        XCTAssertEqual(type("za6y5", o), "zậy")
        XCTAssertEqual(type("qa1", o), "qá")
        XCTAssertEqual(type("dzo6", o), "dzô")
    }

}

final class VNITests: XCTestCase {
    let o = EngineOptions(method: .vni)
    func testBasic() {
        XCTAssertEqual(type("vie65t", o), "việt")
        XCTAssertEqual(type("vie6t5", o), "việt")
        XCTAssertEqual(type("d9uo7ng2", o), "đường")
        XCTAssertEqual(type("nguo7i2", o), "người")
        XCTAssertEqual(type("a11", o), "a1")
        XCTAssertEqual(type("ho8c5", o), "ho8c5")
        XCTAssertEqual(type("hoa8c5", o), "hoặc")
        XCTAssertEqual(type("mu7a", o), "mưa")
        XCTAssertEqual(type("123 abc", o), "123 abc")
        XCTAssertEqual(type("D9a5i", o), "Đại")
    }
}

final class CharsetTests: XCTestCase {
    func testCombining() {
        let s = type("vieetj", EngineOptions(charset: .unicodeCombining))
        XCTAssertEqual(Array(s.unicodeScalars).map(\.value), [0x76, 0x69, 0xEA, 0x323, 0x74])
        XCTAssertEqual(s.precomposedStringWithCanonicalMapping, "việt")
    }

    func testTCVN3() {
        let o = EngineOptions(charset: .tcvn3)
        XCTAssertEqual(type("vieetj", o).unicodeScalars.map(\.value), [0x76, 0x69, 0xD6, 0x74])
        XCTAssertEqual(type("dd", o).unicodeScalars.map(\.value), [0xAE])
        XCTAssertEqual(type("DD", o).unicodeScalars.map(\.value), [0xA7])
        XCTAssertEqual(type("Awn", o).unicodeScalars.map(\.value), [0xA1, 0x6E])
        XCTAssertEqual(type("Aw", o).unicodeScalars.map(\.value), [0xA1])
        XCTAssertEqual(type("ddwowngf", o).unicodeScalars.map(\.value), [0xAE, 0xAD, 0xEA, 0x6E, 0x67])
    }
}

final class SeedTests: XCTestCase {
    /// Nạp `screen` như từ đang có trên màn hình rồi gõ tiếp `keys`.
    private func cont(_ screen: String, _ keys: String, _ o: EngineOptions = EngineOptions()) -> String {
        let e = Engine(options: o)
        var text = screen
        if !e.seed(screen) { return "seed failed" }
        for k in keys {
            switch e.process(k) {
            case .passThrough?: text.append(k)
            case let .replace(old, new)?:
                XCTAssertTrue(text.hasSuffix(old))
                text = String(text.dropLast(old.count)) + new
            case nil: text.append(k)
            }
        }
        return text
    }

    func testSeedContinue() {
        XCTAssertEqual(cont("o", "o"), "ô")          // Cmd+A, xoá, gõ lại "oo"
        XCTAssertEqual(cont("tiên", "s"), "tiến")
        XCTAssertEqual(cont("Viêt", "j"), "Việt")
        XCTAssertEqual(cont("ngươi", "f"), "người")
        XCTAssertEqual(cont("đươ", "ngf"), "đường")
        XCTAssertEqual(cont("thế", "f"), "thề")
    }

    func testSeedRejects() {
        XCTAssertFalse(Engine().seed("ab1"))
        XCTAssertFalse(Engine().seed("áà"))          // hai dấu thanh
        XCTAssertFalse(Engine(options: EngineOptions(charset: .tcvn3)).seed("tiên"))
    }

    /// Bảng mã tổ hợp: từ có dấu đọc lại từ màn hình (dựng sẵn hay tổ hợp) vẫn nạp được để gõ tiếp.
    func testSeedCombining() {
        let o = EngineOptions(charset: .unicodeCombining)
        XCTAssertTrue(Engine(options: o).seed("tiên"))
        XCTAssertTrue(Engine(options: o).seed("ti\u{EA}\u{301}ng"))          // ê + dấu sắc tổ hợp
        XCTAssertTrue(Engine(options: o).seed("tie\u{302}\u{301}ng"))        // tổ hợp hoàn toàn (NFD)
        XCTAssertEqual(cont("tiên", "s", o).precomposedStringWithCanonicalMapping, "tiến")
        XCTAssertEqual(cont("ti\u{EA}\u{301}n", "f", o).precomposedStringWithCanonicalMapping, "tiền")
        XCTAssertEqual(cont("Viêt", "j", o).precomposedStringWithCanonicalMapping, "Việt")
        XCTAssertEqual(cont("ti\u{EA}\u{301}ng", "x", o).unicodeScalars.map(\.value),
                       [0x74, 0x69, 0xEA, 0x303, 0x6E, 0x67])                // vẫn xuất dạng tổ hợp
        let v = EngineOptions(method: .vni, charset: .unicodeCombining)
        XCTAssertEqual(cont("tiên", "1", v).precomposedStringWithCanonicalMapping, "tiến")
    }
}

/// Ô nhập liệu Cocoa tối giản (gõ trực tiếp): kiểm tra engine qua Session khi ⌫ và khi đọc lại từ trên màn hình.
private final class CocoaField: TextClient {
    var units: [UInt16] = []
    var sel = (location: 0, length: 0)
    let session = Session()
    var options = EngineOptions()
    var text: String { String(decoding: units, as: UTF16.self) }

    func selectedRange() -> (location: Int, length: Int)? { sel }
    func text(location: Int, length: Int) -> String? {
        guard location >= 0, location + length <= units.count else { return nil }
        return String(decoding: units[location..<location + length], as: UTF16.self)
    }
    func replaceText(location: Int, length: Int, with s: String) {
        units.replaceSubrange(location..<location + length, with: Array(s.utf16))
        sel = (location + s.utf16.count, 0)
    }
    func setMarkedText(_ text: String) {}
    func replaceViaMarkedText(location: Int, length: Int, with s: String) {
        replaceText(location: location, length: length, with: s)
    }
    func insertText(_ text: String) { replaceText(location: sel.location, length: sel.length, with: text) }

    /// "<" = ⌫ (ứng dụng xoá một ký tự khi bộ gõ không xử lý).
    func run(_ keys: String) -> String {
        for k in keys {
            if k == "<" {
                if session.handle(.backspace, self, options: options, forceMarked: false) { continue }
                let before = String(decoding: units[0..<sel.location], as: UTF16.self)
                guard let last = before.last else { continue }
                let n = last.utf16.count
                units.removeSubrange(sel.location - n..<sel.location)
                sel = (sel.location - n, 0)
            } else if !session.handle(.char(k), self, options: options, forceMarked: false) {
                insertText(String(k))
            }
        }
        return text
    }
}

/// ⌫ ngay sau phím đã làm từ bị khôi phục về phím gõ (thường là gõ nhầm) trả lại chữ đang gõ trước phím đó; các ⌫
/// liền sau lùi tiếp từng phím, nên phím gõ luôn đúng và từ tiếng Anh vẫn được khôi phục khi hết từ.
final class BackspaceAfterRestoreTests: XCTestCase {
    func testTypoTelex() {
        let cases: [(String, String)] = [
            ("tieengd<s", "tiếng"), ("vieetk<j", "việt"), ("dduwowngv<f", "đường"), ("khoongq<", "không"),
            ("tieengdd<<s", "tiếng"),       // hai phím nhầm
            ("tieenbg<<gs", "tiếng"),       // thấy nhầm muộn một chữ
            ("tieengd<", "tiêng"), ("tieengd<<", "tiên"),
            ("tieengsd<<", "tiêng"),        // ⌫ thứ hai lùi phím thanh s (lùi từng phím, không xoá chữ g)
        ]
        for (k, v) in cases { XCTAssertEqual(type(k), v, k) }
    }

    func testTypoVNI() {
        let o = EngineOptions(method: .vni)
        let cases: [(String, String)] = [
            ("vie6t5b<", "việt"), ("d9uo7ngv<2", "đường"), ("vie6tb<5", "việt"), ("vie65tq<<t", "việt"),
        ]
        for (k, v) in cases { XCTAssertEqual(type(k, o), v, k) }
    }

    func testEnglishEditsKeepLetters() {
        // Xoá vài chữ cuối của từ tiếng Anh (qua phím đã làm khôi phục) rồi gõ lại: không mất chữ nào.
        let cases: [(String, String)] = [
            ("neesd<<d", "need"), ("work<<<ork", "work"), ("wrok<<<ork", "work"), ("Oxford<<rd", "Oxford"),
            ("book<<at", "boat"), ("axd<<ddress", "address"), ("text<t", "text"),
        ]
        for (k, v) in cases { XCTAssertEqual(type(k), v, k) }
    }

    func testActions() {
        let e = Engine()
        for c in "tieengd" { _ = e.process(c) }
        XCTAssertEqual(e.displayed, "tieengd")
        XCTAssertEqual(e.backspace(), Action.replace(old: "tieengd", new: "tiêng"))
        XCTAssertEqual(e.backspace(), Action.passThrough)        // lùi phím g: đúng một chữ
        XCTAssertEqual(e.displayed, "tiên")
        XCTAssertEqual(e.process("s"), Action.replace(old: "tiên", new: "tiến"))
        XCTAssertEqual(e.finishWord().text, "tiến")
    }

    func testRawKeptOnPlainBackspace() {
        // Xoá đúng chữ phím cuối vừa gõ thêm: vẫn khôi phục được khi hết từ.
        let cases: [(String, String)] = [
            ("sr<erver", "server"), ("ue<ser", "user"), ("ty<ext", "text"), ("wp<ord", "word"),
            // Không đổi
            ("ass<s", "á"), ("hoaf<", "hò"), ("vieetj<<", "vi"), ("hoanf<", "hòa"),
        ]
        for (k, v) in cases { XCTAssertEqual(type(k), v, k) }
        XCTAssertEqual(type("hofa<", EngineOptions(modernToneStyle: true)), "ho")
    }

    func testSession() {
        for (k, v) in [("tieengd<s ", "tiếng "), ("neesd<<d ", "need "), ("sr<erver ", "server ")] {
            let f = CocoaField()
            XCTAssertEqual(f.run(k), v, k)
        }
        let f = CocoaField()
        f.options = EngineOptions(method: .vni)
        XCTAssertEqual(f.run("vie6t5b<"), "việt")
    }

    /// Bảng mã tổ hợp: xoá dấu cách rồi gõ tiếp vào từ có dấu (đọc lại từ trên màn hình).
    func testSessionCombiningResync() {
        for (k, v) in [("tieen <s", "tiến"), ("tieens <f", "tiền"), ("vieet <j", "việt"), ("tieesng <x", "tiễng")] {
            let f = CocoaField()
            f.options = EngineOptions(charset: .unicodeCombining)
            XCTAssertEqual(f.run(k).precomposedStringWithCanonicalMapping, v, k)
        }
    }
}

/// Telex: huỷ dấu bằng phím gõ lặp mà còn mũ/móc/thanh từ trước, hay phím thanh gõ lặp rồi tới một chữ khác (chữ cái
/// đôi tiếng Anh): kết thúc từ khôi phục phím gõ. Gõ lặp ba hay gõ lặp ở cuối từ vẫn là cố ý bỏ dấu. VNI không đổi.
final class EscapeRestoreTests: XCTestCase {
    func testMarksLeftAfterUndo() {
        for w in ["worry", "cheese", "swiss", "warrior", "worried", "esteem", "defense", "serene", "recess",
                  "referee", "sweeten", "waxwing", "Warwick"] {
            XCTAssertEqual(type(w), w, w)
        }
        let kept: [(String, String)] = [
            ("ass", "as"), ("xooong", "xoong"), ("seeen", "seen"), ("aaa", "aa"), ("ddd", "dd"),
        ]
        for (k, v) in kept { XCTAssertEqual(type(k), v, k) }
        XCTAssertEqual(type("worry", EngineOptions(method: .simpleTelex)), "worry")
    }

    func testDoubledToneKey() {
        for w in ["sorry", "password", "session", "message", "possible", "different", "office", "issue", "issues",
                  "assert", "assess", "assign", "mission", "coffee", "cherry", "Mississippi"] {
            XCTAssertEqual(type(w), w, w)
        }
        let kept: [(String, String)] = [
            ("ass", "as"), ("lass", "las"), ("boss", "bos"), ("bosss", "boss"), ("posssible", "possible"),
            ("Misssissippi", "Mississippi"), ("tests", "tets"),
            // Gõ lặp để thoát khi gõ thẳng ra tiếng Việt ("test" → "tét") hay mất chữ ("tests" → "tets"): giữ nguyên,
            // không thì các từ này không còn cách nào gõ được.
            ("tesst", "test"), ("tessts", "tests"), ("therre", "there"), ("thesse", "these"), ("mosst", "most"),
            ("russt", "rust"), ("resset", "reset"), ("zerro", "zero"), ("cossts", "costs"), ("mirrza", "mirza"),
            // "eror" gõ thẳng ra "eor": chữ đôi của "error" giống cách thoát, giữ như trước; gõ lặp ba vẫn được.
            ("error", "eror"), ("errror", "error"), ("arrray", "array"),
        ]
        for (k, v) in kept { XCTAssertEqual(type(k), v, k) }
    }

    func testVNIUnchanged() {
        let o = EngineOptions(method: .vni)
        XCTAssertEqual(type("vie6t55", o), "viêt5")
        XCTAssertEqual(type("a11", o), "a1")
        XCTAssertEqual(type("a11b", o), "a1b")
    }

    func testIsFinal() {
        func isFinal(_ keys: String, _ o: EngineOptions = EngineOptions()) -> Bool {
            let e = Engine(options: o)
            for c in keys { _ = e.process(c) }
            return e.isFinal
        }
        XCTAssertFalse(isFinal("err"))      // phím sau quyết định
        XCTAssertFalse(isFinal("erro"))     // sẽ khôi phục "error"
        XCTAssertTrue(isFinal("errr"))      // gõ lặp ba: cố ý
        XCTAssertFalse(isFinal("worr"))     // còn ư từ trước lần huỷ
        XCTAssertTrue(isFinal("seeen"))
        XCTAssertTrue(isFinal("ls"))
        XCTAssertFalse(isFinal("xooo"))     // còn có thể thành xoong + thanh
        XCTAssertTrue(isFinal("vie6t55", EngineOptions(method: .vni)))
        XCTAssertTrue(isFinal("err", EngineOptions(autoRestore: false)))
    }
}

/// Telex "oeo" (ngoèo, khoèo): o gõ thêm không bị đặt mũ lên o đầu ("ngôe").
final class OeoTests: XCTestCase {
    func testTelex() {
        let cases: [(String, String)] = [
            ("ngoeof", "ngoèo"), ("ngoeoj", "ngoẹo"), ("ngoeos", "ngoéo"), ("khoeof", "khoèo"), ("ngoefo", "ngoèo"),
            ("ngoawfn ngoeof", "ngoằn ngoèo"), ("khoeo", "khoeo"),
        ]
        for (k, v) in cases { XCTAssertEqual(type(k), v, k) }
    }

    func testVNI() {
        let o = EngineOptions(method: .vni)
        XCTAssertEqual(type("ngoeo2", o), "ngoèo")
        XCTAssertEqual(type("ngoa8n2 ngoeo2", o), "ngoằn ngoèo")
    }
}

/// thuở, huơ, khuơ: "ư" + "o" không phụ âm cuối được thêm móc khi hết từ; xoá ơ của "uơ" còn đúng chữ u đang thấy.
final class OpenUoTests: XCTestCase {
    func testHornAddedAtWordEnd() {
        let cases: [(String, String)] = [
            ("thuwor", "thuở"), ("huwo", "huơ"), ("khuwo", "khuơ"), ("THUWOR", "THUỞ"),
            ("huwowi", "hươi"), ("thuowr", "thuở"),
        ]
        for (k, v) in cases { XCTAssertEqual(type(k), v, k) }
        let o = EngineOptions(method: .vni)
        XCTAssertEqual(type("thu7o3", o), "thuở")
        XCTAssertEqual(type("hu7o", o), "huơ")
        XCTAssertEqual(type("thuwor", EngineOptions(autoRestore: false)), "thuở")

        let e = Engine()
        for c in "thuwor" { _ = e.process(c) }
        let f = e.finishWord()
        XCTAssertEqual(f.text, "thuở")                    // chế độ gạch chân chèn `text`
        XCTAssertEqual(f.action, Action.replace(old: "thửo", new: "thuở"))
    }

    func testBackspaceKeepsPlainU() {
        let cases: [(String, String)] = [("thuowr<", "thu"), ("huow<", "hu"), ("thuowr<a", "thua"), ("khuow<", "khu")]
        for (k, v) in cases { XCTAssertEqual(type(k), v, k) }
        let o = EngineOptions(method: .vni)
        XCTAssertEqual(type("thuo73<", o), "thu")
        XCTAssertEqual(type("huo7<", o), "hu")

        let e = Engine()
        for c in "thuowr" { _ = e.process(c) }
        XCTAssertEqual(e.backspace(), Action.passThrough)  // ô chỉ cần xoá một chữ
        XCTAssertEqual(e.displayed, "thu")
    }
}

/// Telex: gõ lặp phím đứng riêng (ww → w, [[ → [) không để thanh cũ hiện lại, trả lại đúng phím đã gõ.
final class StandaloneUndoTests: XCTestCase {
    func testStaleTone() {
        let e = Engine()
        for c in "twswa" { _ = e.process(c) }
        XCTAssertEqual(e.displayed, "twa")                // thanh không hiện lại trên a
        // Phím thanh mất theo chữ ư: hết từ thì khôi phục phím gõ.
        let cases: [(String, String)] = [("twswa", "twswa"), ("Wjwo", "Wjwo"), ("[s[a", "[s[a"), ("]f]i", "]f]i")]
        for (k, v) in cases { XCTAssertEqual(type(k), v, k) }
    }

    func testRestoresTypedKey() {
        let cases: [(String, String)] = [
            ("woww", "wow"), ("]w", "]w"), ("[w", "[w"),
            // Không đổi
            ("ww", "w"), ("[[", "["), ("]]", "]"), ("{{", "{"), ("uww", "uw"), ("aww", "aw"),
        ]
        for (k, v) in cases { XCTAssertEqual(type(k), v, k) }
    }
}

/// Địa danh Tây Nguyên: Đắk Lắk, Krông Pắk; từ tiếng Anh gần giống vẫn được khôi phục.
final class PlaceNameTests: XCTestCase {
    func testTelex() {
        let cases: [(String, String)] = [
            ("DDawsk Lawsk", "Đắk Lắk"), ("DDawks Lawks", "Đắk Lắk"), ("DDawk Too", "Đăk Tô"),
            ("Kroong Pawks", "Krông Pắk"), ("DDAWSK LAWSK", "ĐẮK LẮK"),
        ]
        for (k, v) in cases { XCTAssertEqual(type(k), v, k) }
        for w in ["hawk", "hawks", "gawks", "awkward", "Kris", "Kroos", "Kraft", "krypton"] {
            XCTAssertEqual(type(w), w, w)
        }
    }

    func testVNI() {
        let o = EngineOptions(method: .vni)
        XCTAssertEqual(type("D9a8k1 La8k1", o), "Đắk Lắk")
        XCTAssertEqual(type("Kro6ng Pa8k1", o), "Krông Pắk")
    }
}

/// Telex: "ooo" → "oo" rồi ng/c, phím thanh vẫn đặt dấu (goòng, moóc, soóc); tiếng Anh gõ "ooo" giữ nguyên.
final class LoanwordOoTests: XCTestCase {
    func testToneAfterEscape() {
        let cases: [(String, String)] = [
            ("gooongf", "goòng"), ("mooocs", "moóc"), ("sooocs", "soóc"), ("booongj", "boọng"),
            // Không đổi
            ("zoooms", "zooms"), ("booots", "boots"), ("roooms", "rooms"), ("mooons", "moons"), ("xooong", "xoong"),
            ("mooocf", "moocf"),            // c chỉ đi với sắc, nặng
        ]
        for (k, v) in cases { XCTAssertEqual(type(k), v, k) }
        XCTAssertEqual(type("goong2", EngineOptions(method: .vni)), "goòng")
    }
}
