/// Bộ xử lý gõ cho một từ (âm tiết) đang gõ.
///
/// Engine không biết gì về ứng dụng: nó chỉ giữ trạng thái của từ hiện tại và trả về
/// `Action` cho biết văn bản trước con trỏ cần thay đổi thế nào.
public final class Engine {
    public var options: EngineOptions
    /// Văn bản của từ hiện tại mà engine tin là đang nằm ngay trước con trỏ.
    public private(set) var displayed = ""

    private(set) var chars: [VChar] = []
    private(set) var tone: Tone = .none
    private var raw = ""            // các phím đã gõ, dùng để khôi phục (chỉ ASCII)
    private var rawValid = true     // false khi raw không còn khớp với chữ (xoá lùi chữ không do phím cuối gõ thêm)
    private var literalOnly = false // sau khi huỷ dấu / từ không hợp lệ: gõ nguyên phím
    private var restoredAt = 0      // số phím trong raw tới phím đã làm từ bị khôi phục về phím gõ (0: không có)
    private var toneUndoAt = 0      // số phím trong raw tới phím thanh gõ lặp để huỷ dấu (0: không có)
    private var hatUndo = false     // đã huỷ dấu mũ bằng phím gõ lặp (aaa, eee, ooo)
    private var toneLost = false    // thanh đã gõ bị bỏ vì chữ mang nó trở về phím (ww → w, [[ → [)
    private var rewinding = false   // ⌫ đang lùi lại từng phím đã gõ (xem `rewind`), tới khi gõ phím khác

    public init(options: EngineOptions = EngineOptions()) {
        self.options = options
        chars.reserveCapacity(16)
    }

    public var isEmpty: Bool { chars.isEmpty }

    /// Từ hiện tại không còn bị biến đổi nữa (vừa huỷ dấu, hoặc không phải tiếng Việt và đã khôi phục):
    /// chữ cái gõ tiếp chỉ được nối thêm nguyên văn, kết thúc từ cũng không khôi phục gì.
    public var isFinal: Bool {
        literalOnly && tone == .none && !escapeRestore(decided: false) && !(hatUndo && ooTone(pending: true))
    }

    public func reset() {
        chars.removeAll(keepingCapacity: true)
        tone = .none
        raw = ""
        rawValid = true
        literalOnly = false
        restoredAt = 0
        toneUndoAt = 0
        hatUndo = false
        toneLost = false
        rewinding = false
        displayed = ""
    }

    /// Xử lý một ký tự. Trả về nil nếu ký tự không thuộc về từ (dấu cách, dấu câu...) —
    /// khi đó nơi gọi cần `finishWord()` rồi cho phím đi qua.
    public func process(_ ch: Character) -> Action? {
        guard let a = ch.asciiValue, a > 32, a < 127 else { return nil }
        let lowered = a | 0x20
        let isLetter = lowered >= 97 && lowered <= 122
        let isDigit = a >= 48 && a <= 57
        let isBracket = a == 91 || a == 93 || a == 123 || a == 125   // [ ] { }
        switch options.method {
        case .vni: guard isLetter || (isDigit && !chars.isEmpty) else { return nil }
        case .telex: guard isLetter || isBracket else { return nil }
        case .simpleTelex: guard isLetter else { return nil }
        }

        let old = displayed
        let key = isLetter ? lowered : a
        let upper = isLetter && a < 97
        rewinding = false
        raw.append(ch)

        if literalOnly {
            guard isLetter else { raw.removeLast(); return nil }
            // "ooo" → "oo" rồi ng/c (goòng, moóc, soóc): phím thanh vẫn đặt dấu. Chỉ với ng/c: "zoooms", "booots"
            // là cách gõ tiếng Anh.
            if hatUndo, let t = telexTone(key), ooTone(pending: false) {
                switch setTone(t, key, upper) {
                case .applied, .undone: return finish(old, ch)
                case .none: break
                }
            }
            appendTyped(key, upper)
            return finish(old, ch)
        }

        switch transform(key, upper: upper) {
        case .applied:
            break
        case .undone:
            literalOnly = true
        case .none:
            guard isLetter else { raw.removeLast(); return nil }
            appendTyped(key, upper)
            normalizeHorn()
            if !isValid(strict: false) {
                if options.autoRestore && rawValid {
                    restoreRaw()
                    restoredAt = raw.utf8.count
                }
                literalOnly = true
            }
        }
        return finish(old, ch)
    }

    /// Xoá lùi một ký tự của từ hiện tại.
    public func backspace() -> Action {
        guard !chars.isEmpty else { return .passThrough }
        let old = displayed
        let n = raw.utf8.count
        if rewinding || (options.autoRestore && rawValid && literalOnly && restoredAt == n && n >= 2) {
            return rewind(old)
        }
        let p = parse()
        let lastIndex = chars.count - 1
        let last = chars[lastIndex]
        let toneOnLast = tone != .none && toneIndex(p) == lastIndex
        if toneOnLast { tone = .none }
        // "uơ" (thuở, huơ, khuơ) hiện chữ u không móc: xoá ơ thì còn đúng chữ u đang thấy, không thành ư.
        let u = plainU(p)
        if u >= 0, u + 1 == lastIndex { chars[u].mark = .none }
        chars.removeLast()
        if rawValid, !toneOnLast, last.mark == .none, last.rawEnd == raw.utf8.count {
            raw.removeLast()    // xoá đúng chữ phím cuối gõ thêm: raw vẫn khớp, kết thúc từ vẫn khôi phục được
        } else {
            rawValid = false
        }
        if chars.isEmpty { reset(); return .passThrough }
        let q = parse()
        if q.vowelEnd == q.initEnd { tone = .none }
        literalOnly = !isValid(strict: false)
        if !literalOnly {
            toneUndoAt = 0
            hatUndo = false
            toneLost = false
        }
        if restoredAt > raw.utf8.count { restoredAt = 0 }
        displayed = render()
        return displayed == String(old.dropLast()) ? .passThrough : .replace(old: old, new: displayed)
    }

    /// Kết thúc từ (gặp dấu cách, dấu câu, Enter...). Nếu từ không phải tiếng Việt hợp lệ
    /// và bật tự khôi phục, trả về `.replace` để đưa về đúng các phím đã gõ.
    /// `text` là văn bản cuối cùng của từ.
    public func finishWord() -> (text: String, action: Action) {
        defer { reset() }
        let text = displayed
        if !literalOnly, hornOpenUo() {
            let fixed = render()
            return (fixed, .replace(old: text, new: fixed))
        }
        guard options.autoRestore, rawValid, !literalOnly || escapeRestore(decided: true), !chars.isEmpty,
              !isValid(strict: true), raw != text else { return (text, .passThrough) }
        return (raw, .replace(old: text, new: raw))
    }

    /// Nạp lại một từ đang có sẵn trên màn hình (vd. sau khi trạng thái bị lệch) để gõ tiếp.
    /// Trả về false nếu không nhận dạng được từ đó.
    @discardableResult
    public func seed(_ word: String) -> Bool {
        reset()
        guard !word.isEmpty, word.count <= 12 else { return false }
        for c in word {
            if let a = c.asciiValue, (a | 0x20) >= 97, (a | 0x20) <= 122 {
                chars.append(VChar(base: a | 0x20, upper: a < 97))
            } else if options.charset != .tcvn3, let v = VTable.decompose[c] {
                // Character so theo tương đương chính tắc: chữ tổ hợp ("ê" + U+0301) cũng tra ra "ế".
                if v.tone != .none {
                    guard tone == .none else { reset(); return false }
                    tone = v.tone
                }
                chars.append(v.char)
            } else {
                reset()
                return false
            }
        }
        guard render() == word else { reset(); return false }
        displayed = word
        raw = word
        rawValid = false
        literalOnly = !isValid(strict: false)
        return true
    }

    // MARK: - Biến đổi

    private enum TResult { case applied, undone, none }
    private enum HornMode { case telexW, horn, breve }

    private func finish(_ old: String, _ ch: Character) -> Action {
        displayed = render()
        if displayed.unicodeScalars.count == old.unicodeScalars.count + 1,
           displayed.hasPrefix(old), displayed.last == ch {
            return .passThrough
        }
        return .replace(old: old, new: displayed)
    }

    /// Thêm nguyên chữ cái của phím vừa gõ (phím cuối của raw).
    private func appendTyped(_ key: UInt8, _ upper: Bool) {
        var c = VChar(base: key, upper: upper)
        c.rawEnd = raw.utf8.count
        chars.append(c)
    }

    /// ⌫ ngay sau phím đã làm từ bị khôi phục về phím gõ — thường là gõ nhầm ("tiêng" + d → "tieengd"): bỏ đúng phím
    /// đó, gõ lại các phím trước nó, nên chữ đang gõ trở lại ("tiêng") để gõ tiếp như chưa gõ nhầm. Các ⌫ liền sau
    /// tiếp tục bỏ từng phím: raw luôn đúng các phím còn lại, nên từ tiếng Anh xoá vài chữ rồi gõ lại vẫn được khôi
    /// phục khi hết từ ("neesd" ⌫⌫ d → "need"), không mất chữ như khi xoá từng chữ trên "nế".
    private func rewind(_ old: String) -> Action {
        let keys = raw.dropLast()
        reset()
        for c in keys { _ = process(c) }
        if chars.isEmpty { reset() } else { rewinding = true }
        return displayed == String(old.dropLast()) ? .passThrough : .replace(old: old, new: displayed)
    }

    private func transform(_ key: UInt8, upper: Bool) -> TResult {
        switch options.method {
        case .telex, .simpleTelex:
            switch key {
            case UInt8(ascii: "s"): return setTone(.acute, key, upper)
            case UInt8(ascii: "f"): return setTone(.grave, key, upper)
            case UInt8(ascii: "r"): return setTone(.hook, key, upper)
            case UInt8(ascii: "x"): return setTone(.tilde, key, upper)
            case UInt8(ascii: "j"): return setTone(.dot, key, upper)
            case UInt8(ascii: "z"): return removeTone()
            case Ch.a, Ch.e, Ch.o: return setHat(key, match: key, upper)
            case Ch.w: return setHorn(key, .telexW, standalone: options.method == .telex, upper)
            case Ch.d: return setStroke(key, upper)
            case UInt8(ascii: "["): return appendHorned(Ch.o, upper: false, key: key)
            case UInt8(ascii: "]"): return appendHorned(Ch.u, upper: false, key: key)
            case UInt8(ascii: "{"): return appendHorned(Ch.o, upper: true, key: key)
            case UInt8(ascii: "}"): return appendHorned(Ch.u, upper: true, key: key)
            default: return .none
            }
        case .vni:
            switch key {
            case UInt8(ascii: "1"): return setTone(.acute, key, upper)
            case UInt8(ascii: "2"): return setTone(.grave, key, upper)
            case UInt8(ascii: "3"): return setTone(.hook, key, upper)
            case UInt8(ascii: "4"): return setTone(.tilde, key, upper)
            case UInt8(ascii: "5"): return setTone(.dot, key, upper)
            case UInt8(ascii: "0"): return removeTone()
            case UInt8(ascii: "6"): return setHat(key, match: nil, upper)
            case UInt8(ascii: "7"): return setHorn(key, .horn, standalone: false, upper)
            case UInt8(ascii: "8"): return setHorn(key, .breve, standalone: false, upper)
            case UInt8(ascii: "9"): return setStroke(key, upper)
            default: return .none
            }
        }
    }

    /// Telex: phím thanh s f r x j.
    private func telexTone(_ key: UInt8) -> Tone? {
        guard options.method != .vni else { return nil }
        switch key {
        case UInt8(ascii: "s"): return .acute
        case UInt8(ascii: "f"): return .grave
        case UInt8(ascii: "r"): return .hook
        case UInt8(ascii: "x"): return .tilde
        case UInt8(ascii: "j"): return .dot
        default: return nil
        }
    }

    /// Thử thay đổi; nếu từ trở nên không hợp lệ thì hoàn tác.
    private func attempt(_ change: () -> Void) -> TResult {
        let savedChars = chars, savedTone = tone
        change()
        if isValid(strict: false), options.method == .vni || marksFit() { return .applied }
        chars = savedChars
        tone = savedTone
        return .none
    }

    /// Telex: mũ/móc của các nguyên âm phải nằm trong một vần có thật: "ngoe" + o không đặt mũ lên o đầu thành "ngôe"
    /// (base "oe" vẫn là phần đầu của "oeo" nhưng không vần nào có "ôe"), để o được gõ thêm: ngoèo, khoèo. VNI không
    /// cần (số không bao giờ là chữ của từ, ngoeo2 vẫn ra ngoèo), và số bị từ chối sẽ làm hết từ.
    private func marksFit() -> Bool {
        let p = parse()
        return p.vowelEnd == p.initEnd
            || VTable.markedPrefixes.contains(vowelString(p.initEnd..<p.vowelEnd, marked: true))
    }

    private func setTone(_ t: Tone, _ key: UInt8, _ upper: Bool) -> TResult {
        let p = parse()
        guard p.vowelEnd > p.initEnd else { return .none }
        if tone == t {
            tone = .none
            chars.append(VChar(base: key, upper: upper))
            toneUndoAt = raw.utf8.count
            return .undone
        }
        return attempt { tone = t }
    }

    private func removeTone() -> TResult {
        guard tone != .none else { return .none }
        tone = .none
        return .applied
    }

    private func setHat(_ key: UInt8, match: UInt8?, _ upper: Bool) -> TResult {
        let p = parse()
        var idx = -1
        var i = p.vowelEnd - 1
        while i >= p.initEnd {
            let b = chars[i].base
            let hit = match.map { b == $0 } ?? (b == Ch.a || b == Ch.e || b == Ch.o)
            if hit { idx = i; break }
            i -= 1
        }
        guard idx >= 0 else { return .none }
        if chars[idx].mark == .hat {
            chars[idx].mark = .none
            chars.append(VChar(base: key, upper: upper))
            hatUndo = true
            return .undone
        }
        return attempt {
            chars[idx].mark = .hat
            // "ươ" + o -> "uô"
            if chars[idx].base == Ch.o, idx > p.initEnd, chars[idx - 1].base == Ch.u {
                chars[idx - 1].mark = .none
            }
        }
    }

    private func setHorn(_ key: UInt8, _ mode: HornMode, standalone: Bool, _ upper: Bool) -> TResult {
        let p = parse()
        let s = p.initEnd, e = p.vowelEnd
        var targets: [Int] = []
        if mode != .breve {
            var i = s
            while i + 1 < e {
                if chars[i].base == Ch.u && chars[i + 1].base == Ch.o { targets = [i, i + 1]; break }
                i += 1
            }
            if targets.isEmpty, let i = (s..<e).first(where: { chars[$0].base == Ch.u }) { targets = [i] }
        }
        if targets.isEmpty, mode != .horn, let i = (s..<e).last(where: { chars[$0].base == Ch.a }) { targets = [i] }
        if targets.isEmpty, mode != .breve, let i = (s..<e).first(where: { chars[$0].base == Ch.o }) { targets = [i] }

        if targets.isEmpty {
            guard standalone else { return .none }
            return attempt { chars.append(VChar(base: Ch.u, mark: .horn, upper: upper, fromKey: Ch.w)) }
        }

        func want(_ i: Int) -> Mark { chars[i].base == Ch.a ? .breve : .horn }
        if targets.allSatisfy({ chars[$0].mark == want($0) }) {
            let host = tone == .none ? nil : toneIndex(p)
            if targets.count == 1 && chars[targets[0]].fromKey == Ch.w {
                // "ww" -> "w"
                chars[targets[0]] = VChar(base: key, upper: chars[targets[0]].upper)
            } else {
                for t in targets {
                    // Chữ do phím đứng riêng tạo ra (w, [, ]): trả lại đúng phím ấy, không để lại u/o không ai gõ.
                    let from = chars[t].fromKey
                    if from != 0 {
                        chars[t] = VChar(base: from, upper: from == Ch.w && chars[t].upper)
                    } else {
                        chars[t].mark = .none
                    }
                }
                chars.append(VChar(base: key, upper: upper))
            }
            dropStaleTone(host)
            return .undone
        }
        return attempt { for t in targets { chars[t].mark = want(t) } }
    }

    /// Telex `[` `]` `{` `}` → ơ ư Ơ Ư. Gõ lặp ngay sau đó thì trả về dấu ngoặc ([[ → [).
    private func appendHorned(_ base: UInt8, upper: Bool, key: UInt8) -> TResult {
        if let last = chars.last, last.fromKey == key {
            let host = tone == .none ? nil : toneIndex(parse())
            chars[chars.count - 1] = VChar(base: key)
            dropStaleTone(host)
            return .undone
        }
        return attempt { chars.append(VChar(base: base, mark: .horn, upper: upper, fromKey: key)) }
    }

    /// Sau khi trả nguyên âm về phím đã tạo ra nó (ww → w, [[ → [): thanh đặt trên chữ đó (hoặc không còn nguyên âm
    /// nào để mang thanh) thì bỏ, không để nó hiện lại trên nguyên âm gõ sau ("tws" + w + a ra "twá"). Phím thanh ấy
    /// coi như còn dấu sau lần huỷ: kết thúc từ khôi phục phím gõ ("waxwing" không thành "waing").
    private func dropStaleTone(_ host: Int?) {
        guard tone != .none else { return }
        let p = parse()
        if p.vowelEnd == p.initEnd || (host.map { $0 < chars.count && !chars[$0].isVowel } ?? false) {
            tone = .none
            toneLost = true
        }
    }

    private func setStroke(_ key: UInt8, _ upper: Bool) -> TResult {
        guard let f = chars.first, f.base == Ch.d else { return .none }
        if f.mark == .stroke {
            chars[0].mark = .none
            chars.append(VChar(base: key, upper: upper))
            return .undone
        }
        return attempt { chars[0].mark = .stroke }
    }

    /// "ưo" / "uơ" có chữ theo sau -> "ươ" (người, trường...).
    private func normalizeHorn() {
        let p = parse()
        var i = p.initEnd
        while i + 1 < p.vowelEnd {
            if chars[i].base == Ch.u && chars[i + 1].base == Ch.o && i + 2 < chars.count {
                let h1 = chars[i].mark == .horn, h2 = chars[i + 1].mark == .horn
                if h1 != h2 && chars[i + 1].mark != .hat {
                    chars[i].mark = .horn
                    chars[i + 1].mark = .horn
                }
                return
            }
            i += 1
        }
    }

    /// Cuối từ: "ư" + "o" không có phụ âm cuối sau h/th/kh (gõ thuwor, huwo, VNI thu7o3) → o cũng có móc: thuở,
    /// huơ, khuơ. Không làm lúc gõ o: phím w ngay sau sẽ huỷ móc ("huwowi" → hươi).
    private func hornOpenUo() -> Bool {
        let p = parse()
        guard p.vowelEnd == chars.count, p.vowelEnd - p.initEnd == 2,
              chars[p.initEnd].base == Ch.u, chars[p.initEnd].mark == .horn,
              chars[p.initEnd + 1].base == Ch.o, chars[p.initEnd + 1].mark == .none else { return false }
        let ini = consonants(0..<p.initEnd)
        guard ini == "h" || ini == "th" || ini == "kh" else { return false }
        chars[p.initEnd + 1].mark = .horn
        return true
    }

    /// Vần "oo" chưa có dấu mũ (gõ "ooo") với phụ âm cuối ng/c, hoặc (`pending`) còn có thể thành như vậy.
    private func ooTone(pending: Bool) -> Bool {
        guard options.method != .vni else { return false }
        let p = parse()
        guard p.wellFormed, p.vowelEnd - p.initEnd == 2,
              chars[p.initEnd].base == Ch.o, chars[p.initEnd].mark == .none,
              chars[p.initEnd + 1].base == Ch.o, chars[p.initEnd + 1].mark == .none else { return false }
        let fin = consonants(p.vowelEnd..<chars.count)
        return fin == "ng" || fin == "c" || (pending && (fin.isEmpty || fin == "n"))
    }

    /// Telex: từ đã huỷ dấu bằng phím gõ lặp mà kết thúc từ vẫn khôi phục phím gõ (nếu không phải tiếng Việt):
    /// - còn mũ/móc/thanh từ trước lần huỷ ("worry" → "ưor", "cheese" → "chée"), hay thanh đã bị bỏ theo chữ mang nó
    ///   (`toneLost`): không phải chữ ai muốn gõ;
    /// - phím thanh gõ lặp rồi tới một chữ khác ("password", "possible", "message"): chữ cái đôi của tiếng Anh — trừ
    ///   khi đó là cách thoát cố ý (xem `escapeNeeded`). Gõ lặp ba ("bosss", "posssible") hay ở cuối từ ("ass") vẫn là
    ///   cố ý bỏ dấu.
    /// VNI thì không: gõ lặp số (a11 → a1) luôn là cố ý. `decided` = false: hỏi xem còn có thể khôi phục không
    /// (phím ngay sau lần huỷ chưa gõ thì chưa biết).
    private func escapeRestore(decided: Bool) -> Bool {
        guard options.autoRestore, rawValid, options.method != .vni else { return false }
        if tone != .none || toneLost || chars.contains(where: { $0.isVowel && $0.mark != .none }) { return true }
        guard toneUndoAt > 0 else { return false }
        let u = raw.utf8
        guard toneUndoAt < u.count else { return !decided }
        let next = u.index(u.startIndex, offsetBy: toneUndoAt)
        guard u[next] | 0x20 != u[u.index(before: next)] | 0x20 else { return false }
        return !decided || !escapeNeeded()
    }

    /// Phím thanh gõ lặp giữa từ là cách thoát cố ý khi gõ thẳng (bỏ phím lặp) không ra đúng các chữ ấy: thành tiếng
    /// Việt ("tesst": gõ "test" ra "tét"; "therre", "mosst", "zerro") hay mất chữ ("tessts": "tests" ra "tets").
    /// Khôi phục những từ đó thì chúng không còn cách nào gõ được ở chế độ V. Gõ thẳng ra đúng ("posible") thì chữ
    /// đôi là thật ("possible"). Chỉ chạy lúc hết từ, khi có phím lặp.
    private func escapeNeeded() -> Bool {
        var keys = Array(raw.utf8)
        keys.remove(at: toneUndoAt - 1)
        let single = String(decoding: keys, as: UTF8.self)
        let e = Engine(options: options)
        for c in single { _ = e.process(c) }
        return e.finishWord().text != single
    }

    private func restoreRaw() {
        chars.removeAll(keepingCapacity: true)
        var n = 0
        for c in raw {
            let a = c.asciiValue ?? 63
            let lowered = a | 0x20
            let isLetter = lowered >= 97 && lowered <= 122
            n += 1
            var v = VChar(base: isLetter ? lowered : a, upper: isLetter && a < 97)
            v.rawEnd = n
            chars.append(v)
        }
        tone = .none
    }

    // MARK: - Phân tích âm tiết

    struct Syllable {
        var initEnd: Int     // [0, initEnd): phụ âm đầu
        var vowelEnd: Int    // [initEnd, vowelEnd): nguyên âm; phần còn lại: phụ âm cuối
        var wellFormed: Bool // không có nguyên âm nằm sau phụ âm cuối
    }

    func parse() -> Syllable {
        let n = chars.count
        var i = 0
        while i < n && !chars[i].isVowel { i += 1 }
        var initEnd = i
        if initEnd == 1 && i < n {
            let c0 = chars[0].base
            if c0 == Ch.q && chars[1].base == Ch.u {
                initEnd = 2
            } else if c0 == Ch.g && chars[1].base == Ch.i && n > 2 && chars[2].isVowel {
                initEnd = 2
            }
        }
        var j = initEnd
        while j < n && chars[j].isVowel { j += 1 }
        var k = j
        while k < n && !chars[k].isVowel { k += 1 }
        return Syllable(initEnd: initEnd, vowelEnd: j, wellFormed: k == n)
    }

    private func consonants(_ r: Range<Int>) -> String {
        var s = String.UnicodeScalarView()
        for c in chars[r] {
            s.append(c.base == Ch.d && c.mark == .stroke ? "đ" : Unicode.Scalar(c.base))
        }
        return String(s)
    }

    private func vowelString(_ r: Range<Int>, marked: Bool) -> String {
        var s = String.UnicodeScalarView()
        for c in chars[r] {
            if marked, let row = VTable.row(c.base, c.mark) {
                s.append(VTable.lower[row][0])
            } else {
                s.append(Unicode.Scalar(c.base))
            }
        }
        return String(s)
    }

    /// strict = false: có thể là phần đầu của một âm tiết hợp lệ (đang gõ dở).
    /// strict = true: là một âm tiết tiếng Việt hoàn chỉnh.
    func isValid(strict: Bool) -> Bool {
        let p = parse()
        guard p.wellFormed else { return false }
        let n = chars.count
        if p.vowelEnd == p.initEnd {
            // Không có nguyên âm ("đ", "VN"...): không bao giờ khôi phục.
            if strict { return true }
            let ini = consonants(0..<n)
            return p.vowelEnd == n && (VTable.initialPrefixes.contains(ini) || isInformalInitial(ini) || ini == "kr")
        }
        let ini = consonants(0..<p.initEnd)
        let fin = consonants(p.vowelEnd..<n)
        // Địa danh Tây Nguyên, chỉ đúng các chữ này để không nuốt từ tiếng Anh ("hawk", "awkward", "Kris"):
        // Đắk, Lắk, Pắk (k cuối sau "ă" đứng riêng) và Krông ("kr" chỉ đi với o/ô rồi n, ng).
        if fin == "k" {
            guard ini == "đ" || ini == "l" || ini == "p", p.vowelEnd - p.initEnd == 1,
                  chars[p.initEnd].base == Ch.a, chars[p.initEnd].mark == .breve else { return false }
            return tone == .none || tone == .acute || tone == .dot
        }
        if ini == "kr" {
            guard p.vowelEnd - p.initEnd == 1, chars[p.initEnd].base == Ch.o else { return false }
            let ok = strict ? chars[p.initEnd].mark == .hat && fin == "ng"
                            : chars[p.initEnd].mark != .horn && (fin.isEmpty || fin == "n" || fin == "ng")
            guard ok else { return false }
        } else {
            guard VTable.initials.contains(ini) || isInformalInitial(ini) else { return false }
        }
        guard fin.isEmpty || VTable.finals.contains(fin) else { return false }

        let first = chars[p.initEnd].base
        switch ini {
        case "k", "gh", "ngh": guard first == Ch.e || first == Ch.i || first == Ch.y else { return false }
        case "c": guard first != Ch.e && first != Ch.i && first != Ch.y else { return false }
        case "g", "ng": guard first != Ch.e && (ini == "g" || first != Ch.i) else { return false }
        default: break
        }

        if fin == "ch" || fin == "nh" {
            let last = chars[p.vowelEnd - 1]
            switch last.base {
            case Ch.i, Ch.y: break
            case Ch.a: guard !strict || last.mark == .none else { return false }
            case Ch.e: guard !strict || last.mark == .hat else { return false }
            default: return false
            }
        }
        if fin == "c" || fin == "ch" || fin == "p" || fin == "t" {
            guard tone == .none || tone == .acute || tone == .dot else { return false }
        }

        if strict {
            guard let rule = VTable.clusters[vowelString(p.initEnd..<p.vowelEnd, marked: true)] else { return false }
            return fin.isEmpty ? rule != .closed : rule != .open
        }
        let base = vowelString(p.initEnd..<p.vowelEnd, marked: false)
        return fin.isEmpty ? VTable.basePrefixes.contains(base) : VTable.baseCanClose.contains(base)
    }

    private func isInformalInitial(_ ini: String) -> Bool {
        VTable.informalInitials.contains(ini)
    }

    // MARK: - Hiển thị

    private func toneIndex(_ p: Syllable) -> Int? {
        let s = p.initEnd, e = p.vowelEnd, n = e - s
        if n == 0 { return nil }
        if n == 1 { return s }
        for i in s..<e where chars[i].base == Ch.o && chars[i].mark == .horn { return i }   // ươ, ơi
        for i in s..<e where chars[i].mark != .none { return i }                             // ê, â, ư...
        if e < chars.count { return e - 1 }                                                  // có phụ âm cuối
        if n >= 3 { return s + 1 }                                                           // oai, uyu
        if options.modernToneStyle {
            let b0 = chars[s].base, b1 = chars[s + 1].base
            if (b0 == Ch.o && (b1 == Ch.a || b1 == Ch.e)) || (b0 == Ch.u && b1 == Ch.y) { return s + 1 }
        }
        return s
    }

    /// thuở, huơ, khuơ: "ươ" không có phụ âm cuối sau h/th/kh hiện là "uơ" — vị trí chữ u, hoặc -1.
    private func plainU(_ p: Syllable) -> Int {
        guard p.vowelEnd == chars.count, p.vowelEnd - p.initEnd == 2,
              chars[p.initEnd].base == Ch.u, chars[p.initEnd].mark == .horn,
              chars[p.initEnd + 1].base == Ch.o, chars[p.initEnd + 1].mark == .horn else { return -1 }
        let ini = consonants(0..<p.initEnd)
        return ini == "h" || ini == "th" || ini == "kh" ? p.initEnd : -1
    }

    func render() -> String {
        var out = String.UnicodeScalarView()
        let p = parse()
        let toneIdx = tone == .none ? -1 : (toneIndex(p) ?? -1)
        let plainU = plainU(p)

        let charset = options.charset
        for i in chars.indices {
            let c = chars[i]
            if var row = VTable.row(c.base, c.mark) {
                if i == plainU { row = VTable.plainU }
                VTable.emitVowel(row: row, tone: i == toneIdx ? tone : .none, upper: c.upper,
                                 charset: charset, into: &out)
            } else if c.base == Ch.d && c.mark == .stroke {
                VTable.emitD(upper: c.upper, charset: charset, into: &out)
            } else {
                out.append(Unicode.Scalar(c.upper ? c.base - 32 : c.base))
            }
        }
        return String(out)
    }
}
