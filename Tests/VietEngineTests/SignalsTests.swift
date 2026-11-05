import XCTest
@testable import VietEngine

private struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
}

/// Dòng lệnh của shell sau một terminal kiểu `.inline` (ghi nguyên chuỗi; DEL xoá ký tự trước con trỏ). Mỗi phím mang
/// theo `KeyGap` mà sổ phím báo.
private final class Pty: TextClient {
    var line: [Character] = []
    var cursor = 0
    let session = Session()
    var options = EngineOptions(method: .vni)
    var style = TerminalStyle.inline

    var text: String { String(line) }

    func selectedRange() -> (location: Int, length: Int)? { (0, 0) }   // như Ghostty, Muxy: không cho biết con trỏ
    func text(location: Int, length: Int) -> String? { nil }
    func replaceText(location: Int, length: Int, with text: String) { XCTFail("terminal: không thay được chữ") }
    /// Kiểu `.deferred` (Ghostty): chỉ được dùng marked text rỗng U+200B để giữ phím.
    func setMarkedText(_ text: String) {
        if text == "\u{200B}" {
            markActive = true
        } else if text.isEmpty {
            markActive = false
        } else {
            XCTFail("terminal: không được gạch chân (\(text))")
        }
    }
    func insertText(_ text: String) {
        markActive = false
        write(text)
    }
    func replaceViaMarkedText(location: Int, length: Int, with text: String) { XCTFail("terminal: marked text") }
    var markActive = false
    func hasMarkedText() -> Bool { markActive }
    /// Sổ phím: không có phím tắt / click nào từ phím vừa rồi.
    var quiet = true
    func lateEditSafe() -> Bool { quiet }
    /// false: lần gửi hẹn giờ (kiểu `.deferred`) chưa chạy — như khi Ghostty bỏ lần gửi ngoài keyDown.
    var runScheduledNow = true
    private var later: [() -> Void] = []
    func schedule(after delay: Double, _ work: @escaping () -> Void) {
        if runScheduledNow { work() } else { later.append(work) }
    }

    func write(_ s: String) {
        for scalar in s.unicodeScalars {
            if scalar == "\u{7f}" {
                if cursor > 0 { line.remove(at: cursor - 1); cursor -= 1 }
            } else {
                line.insert(Character(scalar), at: cursor); cursor += 1
            }
        }
    }

    func type(_ keys: String, gap: KeyGap = .none) {
        for k in keys {
            if !session.handle(.char(k), self, options: options, forceMarked: false, terminal: style, gap: gap) {
                write(String(k))
            }
        }
    }

    func key(_ k: Character, _ gap: KeyGap) { type(String(k), gap: gap) }

    func backspace(gap: KeyGap = .none) {
        if !session.handle(.backspace, self, options: options, forceMarked: false, terminal: style, gap: gap) {
            write("\u{7f}")
        }
    }

    // Phím terminal tự xử lý, không qua bộ gõ.
    func bypassLineStart() { cursor = 0 }
    func bypassLeft() { cursor -= 1 }
    func bypassPaste(_ s: String) { write(s) }
}

/// Terminal cho đọc màn hình (iTerm2, Terminal.app): con trỏ thật, đọc được dòng lệnh; shell in lại ngay. Đồng hồ giả, mỗi
/// phím cách nhau 50 ms.
private final class ScreenPty: TextClient {
    var line: [Character] = []
    var cursor = 0
    var now = 100.0
    let session = Session()
    let options = EngineOptions(method: .vni)
    let prompt = "$ "

    var text: String { String(line) }

    func selectedRange() -> (location: Int, length: Int)? { ((prompt + String(line[..<cursor])).utf16.count, 0) }
    func text(location: Int, length: Int) -> String? {
        let all = Array((prompt + text).utf16)
        guard location >= 0, length >= 0, location + length <= all.count else { return nil }
        return String(decoding: all[location..<location + length], as: UTF16.self)
    }
    func replaceText(location: Int, length: Int, with text: String) { XCTFail("terminal: không thay được chữ") }
    func setMarkedText(_ text: String) { XCTFail("terminal: không được gạch chân (\(text))") }
    func insertText(_ text: String) {
        for scalar in text.unicodeScalars {
            if scalar == "\u{7f}" {
                if cursor > 0 { line.remove(at: cursor - 1); cursor -= 1 }
            } else {
                line.insert(Character(scalar), at: cursor); cursor += 1
            }
        }
    }
    func replaceViaMarkedText(location: Int, length: Int, with text: String) { XCTFail("terminal: marked text") }
    func currentTime() -> Double { now }
    private var later: [() -> Void] = []
    func schedule(after delay: Double, _ work: @escaping () -> Void) { later.append(work) }

    func key(_ k: Character, _ gap: KeyGap) {
        if !session.handle(.char(k), self, options: options, forceMarked: false, terminal: .inline, gap: gap) {
            insertText(String(k))
        }
        // Việc hẹn giờ (xem lại màn hình: đo thời gian in lại) chạy sau khi shell đã in lại phím.
        while !later.isEmpty {
            now += 0.004
            later.removeFirst()()
        }
        now += 0.05
    }
    func type(_ keys: String) { for k in keys { key(k, .none) } }
}

/// Lịch kiểm tra hẹn giờ như `KeyWatch.scheduleCheck`: sau mỗi phím, ở các mốc `KeyLedger.checkDelays`; vừa có phím
/// được bấm thì thử lại khi đã yên (tối đa 2 lần mỗi mốc); phím mới tới thì bỏ lịch cũ.
private struct Checks {
    var keyTime: Double?
    var step = 0
    var waits = 0
    var next: Double?

    mutating func start(after t: Double) {
        keyTime = t
        step = 0
        waits = 0
        next = t + KeyLedger.checkDelays[0]
    }

    mutating func run(until t: Double, _ l: inout KeyLedger, reading: (Double) -> (UInt32, Double),
                      resolved: () -> Void) {
        while let at = next, at < t, let keyTime {
            let (count, since) = reading(at)
            switch l.check(keyDownCount: count, secondsSinceLastKeyDown: since) {
            case .resolved:
                resolved()
                next = nil
            case .wait where waits < 2:
                waits += 1
                next = at + max(0.02, l.quietTime - since)
            case .wait, .none:
                step += 1
                waits = 0
                next = step < KeyLedger.checkDelays.count ? keyTime + KeyLedger.checkDelays[step] : nil
                if let n = next, n <= at { next = at + 0.01 }
            }
        }
    }
}

final class SignalsTests: XCTestCase {
    // MARK: - Sổ phím

    private func reading(_ count: UInt32, at t: Double, code: UInt16 = 0, repeat isRepeat: Bool = false) -> KeyReading {
        KeyReading(keyDownCount: count, timestamp: t, keyCode: code, isRepeat: isRepeat)
    }

    /// Sổ đã có mốc ở bộ đếm `count` (như lúc bộ gõ vừa gắn vào ô nhập liệu).
    private func ledger(at count: UInt32) -> KeyLedger {
        var l = KeyLedger()
        l.rebase(keyDownCount: count)
        return l
    }

    func testLedgerCleanWhenEveryKeySeen() {
        var l = KeyLedger()
        XCTAssertEqual(l.observe(reading(1000, at: 1.0)), .unavailable)      // chưa có mốc
        for i in 1...20 {
            XCTAssertEqual(l.observe(reading(1000 + UInt32(i), at: 1.0 + Double(i) * 0.1, code: UInt16(i))), .clean)
        }
    }

    /// Phím kế tiếp đã bấm nhưng chưa tới bộ gõ (gõ nhanh, ứng dụng bận): chưa biết, rồi sạch khi nó tới.
    func testLedgerKeyInFlight() {
        var l = ledger(at: 10)
        XCTAssertEqual(l.observe(reading(12, at: 1.0, code: 1)), .unknown)
        XCTAssertEqual(l.observe(reading(12, at: 1.01, code: 2)), .clean)
        // ứng dụng treo: bốn phím dồn lại
        XCTAssertEqual(l.observe(reading(16, at: 1.5, code: 3)), .unknown)
        XCTAssertEqual(l.observe(reading(16, at: 1.51, code: 4)), .unknown)
        XCTAssertEqual(l.observe(reading(16, at: 1.52, code: 5)), .unknown)
        XCTAssertEqual(l.observe(reading(16, at: 1.53, code: 6)), .clean)
    }

    /// Phím đi vòng bộ gõ (mũi tên ở iTerm2, Tab ở Muxy…) rồi một phím: chưa biết; lúc yên tĩnh thì kiểm tra thấy vẫn
    /// còn phím chưa tới → phím sau được báo là có phím lỡ.
    func testLedgerBypassResolvedByQuietCheck() {
        var l = ledger(at: 10)
        XCTAssertEqual(l.observe(reading(11, at: 1.0, code: 1)), .clean)
        XCTAssertEqual(l.observe(reading(13, at: 1.3, code: 2)), .unknown)        // 1 phím đi vòng trước phím 2
        XCTAssertEqual(l.check(keyDownCount: 13, secondsSinceLastKeyDown: 0.01), .wait)   // vừa có phím: chờ
        XCTAssertEqual(l.check(keyDownCount: 13, secondsSinceLastKeyDown: 0.31), .resolved)
        XCTAssertEqual(l.observe(reading(14, at: 1.6, code: 3)), .missed(1))
        XCTAssertEqual(l.observe(reading(15, at: 1.7, code: 4)), .clean)
    }

    /// Phím đi vòng bấm SAU phím "chưa biết" (bộ đếm tăng thêm sau lần đọc): không biết phím lỡ ở đâu → lỡ.
    func testLedgerBypassAfterUnsureKey() {
        var l = ledger(at: 10)
        XCTAssertEqual(l.observe(reading(12, at: 1.0, code: 1)), .unknown)
        XCTAssertEqual(l.check(keyDownCount: 13, secondsSinceLastKeyDown: 0.35), .resolved)
        XCTAssertEqual(l.observe(reading(14, at: 1.5, code: 2)), .missed(2))
    }

    /// Phím đi vòng lúc người dùng dừng tay (Tab tự hoàn thành, mũi tên…): lần kiểm tra sau phím trước đã biết, phím
    /// kế tiếp được báo ngay là có phím lỡ — gõ tiếp bình thường, không phải đi nguyên văn.
    func testLedgerBypassFoundBeforeNextKey() {
        var l = ledger(at: 10)
        XCTAssertEqual(l.observe(reading(11, at: 1.0, code: 1)), .clean)
        XCTAssertEqual(l.check(keyDownCount: 11, secondsSinceLastKeyDown: 0.1), .none)     // chưa có gì
        XCTAssertEqual(l.check(keyDownCount: 12, secondsSinceLastKeyDown: 0.03), .wait)    // Tab vừa bấm
        XCTAssertEqual(l.check(keyDownCount: 12, secondsSinceLastKeyDown: 0.5), .resolved)
        XCTAssertEqual(l.observe(reading(13, at: 2.0, code: 2)), .missed(1))
        XCTAssertEqual(l.observe(reading(14, at: 2.1, code: 3)), .clean)
    }

    /// Nhiều phím "chưa biết" liền nhau rồi mới yên tĩnh: không biết phím lỡ trước phím nào → lỡ.
    func testLedgerLongUnsureRunIsMissed() {
        var l = ledger(at: 10)
        XCTAssertEqual(l.observe(reading(12, at: 1.0, code: 1)), .unknown)
        XCTAssertEqual(l.observe(reading(13, at: 1.05, code: 2)), .unknownSteady)
        XCTAssertEqual(l.check(keyDownCount: 13, secondsSinceLastKeyDown: 0.35), .resolved)
        XCTAssertEqual(l.observe(reading(14, at: 1.3, code: 3)), .missed(1))
    }

    /// Phím có ⌘/⌃/⌥ mà bộ gõ nhận được (Ctrl+E ở Ghostty): phím bổ trợ là của chính nó — sạch nếu không có gì đi vòng.
    func testLedgerModifierOfThisKeyIsNotABypass() {
        var l = ledger(at: 10)
        XCTAssertEqual(l.observe(reading(11, at: 1.0, code: 1)), .clean)
        XCTAssertEqual(l.observe(reading(12, at: 1.2, code: 14), modifierPressed: true, keyHasModifier: true), .clean)
        // ⌘V đi vòng rồi Ctrl+E: có phím chưa thấy → lỡ
        XCTAssertEqual(l.observe(reading(14, at: 1.5, code: 14), modifierPressed: true, keyHasModifier: true), .missed(1))
    }

    /// "Chưa biết" mà không có thêm phím nào chưa thấy kể từ phím trước: `.unknownSteady`.
    func testLedgerUnknownSteady() {
        var l = ledger(at: 10)
        XCTAssertEqual(l.observe(reading(11, at: 1.0, code: 1)), .clean)
        XCTAssertEqual(l.observe(reading(15, at: 1.2, code: 2)), .unknown)          // 3 phím ⌫ đi vòng (Terminal.app)
        XCTAssertEqual(l.observe(reading(16, at: 1.25, code: 3)), .unknownSteady)
        XCTAssertEqual(l.observe(reading(17, at: 1.3, code: 4)), .unknownSteady)
        XCTAssertEqual(l.observe(reading(19, at: 1.35, code: 5)), .unknown)         // thêm một phím chưa thấy
        XCTAssertEqual(l.observe(reading(20, at: 1.4, code: 6)), .unknownSteady)
    }

    /// Phím tắt có ⌘/⌃/⌥ (⌘V, Ctrl+A đi vòng bộ gõ): lỡ ngay, không chờ.
    func testLedgerModifierShortcutIsMissedAtOnce() {
        var l = ledger(at: 10)
        XCTAssertEqual(l.observe(reading(11, at: 1.0, code: 1)), .clean)
        XCTAssertEqual(l.observe(reading(13, at: 1.4, code: 2), modifierPressed: true), .missed(1))
        XCTAssertEqual(l.observe(reading(14, at: 1.5, code: 3)), .clean)
        // phím tắt tới bộ gõ (không đi vòng): vẫn bỏ từ — con trỏ có thể đã đổi chỗ
        XCTAssertEqual(l.observe(reading(15, at: 1.6, code: 4), modifierPressed: true), .missed(0))
        XCTAssertEqual(l.observe(reading(16, at: 1.7, code: 5)), .clean)
    }

    /// Gõ liền tay sau một phím đi vòng: "chưa biết" cho tới lúc dừng tay; lần kiểm tra lúc đó kết luận, phím kế tiếp
    /// (vừa bấm, tới ngay) bỏ từ rồi mọi thứ lại sạch.
    func testLedgerUnsureRunResolvedAtFirstPause() {
        var l = ledger(at: 10)
        var verdicts: [GapVerdict] = []
        for i in 0..<12 { verdicts.append(l.observe(reading(12 + UInt32(i), at: 1.0 + Double(i) * 0.06, code: UInt16(i)))) }
        XCTAssertTrue(verdicts.allSatisfy { $0 == .unknown || $0 == .unknownSteady }, "\(verdicts)")
        XCTAssertEqual(l.check(keyDownCount: 23, secondsSinceLastKeyDown: 0.2), .resolved)
        XCTAssertEqual(l.observe(reading(24, at: 2.0, code: 50)), .missed(1))
        XCTAssertEqual(l.observe(reading(25, at: 2.1, code: 51)), .clean)
    }

    /// Phím tắt (⌘V) mà phím sau tới muộn (ứng dụng treo): vẫn bỏ từ, nhưng không tính phím nào là lỡ (có thể còn phím
    /// đang nằm chờ) — số dư để lần kiểm tra kết luận.
    func testLedgerModifierDuringStallDoesNotBook() {
        var l = ledger(at: 10)
        XCTAssertEqual(l.observe(reading(11, at: 1.0, code: 1)), .clean)
        let late = KeyReading(keyDownCount: 14, timestamp: 1.5, keyCode: 2, isRepeat: false, sinceLastKeyDown: 0.3)
        XCTAssertEqual(l.observe(late, modifierPressed: true), .missed(2))
        let next = KeyReading(keyDownCount: 14, timestamp: 1.501, keyCode: 3, isRepeat: false, sinceLastKeyDown: 0.3)
        XCTAssertEqual(l.observe(next), .unknown)            // phím đang chờ tới: vẫn còn ⌘V chưa thấy
    }

    /// Phím đang nằm chờ trong ứng dụng (treo) bị lần kiểm tra tính là lỡ: khi nó tới thì không phải "phím duy nhất bấm
    /// sau lần kiểm tra" → huỷ kết luận, như chưa từng kiểm tra.
    func testLedgerStalledKeyBookedThenArrives() {
        var l = ledger(at: 10)
        XCTAssertEqual(l.observe(reading(12, at: 1.0, code: 1)), .unknown)
        XCTAssertEqual(l.check(keyDownCount: 12, secondsSinceLastKeyDown: 0.35), .resolved)
        // phím nằm chờ tới khi hết treo: phím mới nhất bấm cách đây đã lâu
        let late = KeyReading(keyDownCount: 12, timestamp: 1.2, keyCode: 2, isRepeat: false, sinceLastKeyDown: 0.4)
        XCTAssertEqual(l.observe(late), .clean)
        XCTAssertEqual(l.observe(reading(13, at: 1.3, code: 3)), .clean)
    }

    /// Phím đi vòng được kiểm tra tính là lỡ, rồi phím tới tiếp là phím do chương trình gõ (không được đếm) mà tới ngay:
    /// nó không được "bù" phím đi vòng thành sạch.
    func testLedgerUncountedKeyDoesNotHideBypass() {
        var l = ledger(at: 10)
        XCTAssertEqual(l.observe(reading(11, at: 1.0, code: 1)), .clean)
        // Home đi vòng (đếm 12), dừng tay → lần kiểm tra tính là lỡ
        XCTAssertEqual(l.check(keyDownCount: 12, secondsSinceLastKeyDown: 0.2), .resolved)
        let synthetic = KeyReading(keyDownCount: 12, timestamp: 1.5, keyCode: 2, isRepeat: false, sinceLastKeyDown: 0.001)
        XCTAssertNotEqual(l.observe(synthetic), .clean)
    }

    /// GTVInput thấy phím đặc biệt bộ gõ không nhận (`PressLog`): tính là lỡ ngay, các phím sau sạch.
    func testLedgerNoteBypassed() {
        var l = ledger(at: 10)
        XCTAssertEqual(l.observe(reading(11, at: 1.0, code: 1)), .clean)
        XCTAssertEqual(l.observe(reading(13, at: 1.2, code: 2)), .unknown)      // ⌫ đi vòng, rồi phím này
        l.noteBypassed(1)
        XCTAssertEqual(l.observe(reading(14, at: 1.3, code: 3)), .clean)
        l.noteBypassed(1)                                                       // không tính trùng
        XCTAssertEqual(l.observe(reading(15, at: 1.4, code: 4)), .clean)
    }

    /// Lần nhấn sớm hơn phím vừa tới (lúc `t`) quá `lead` giây.
    private func missed(_ p: inout PressLog, before t: Double, lead: Double = 0.01) -> [PressLog.Press] {
        p.take { $0.at <= t - lead }
    }

    /// Chỉ nhấn thêm phím bổ trợ mới là thao tác (nhả ⌘ sau ⌘Tab thì không); quên phím đã nhận khi đổi ô nhập liệu.
    func testPressLogFlagPressesAndForget() {
        var p = PressLog()
        p.sample(at: 1.000, held: [], button: false, flags: 0x100000)
        p.sample(at: 1.008, held: [], button: false, flags: 0)              // nhả ⌘
        XCTAssertTrue(p.flagsChanged(from: 1.0, to: 1.01))
        XCTAssertFalse(p.flagsPressed(from: 1.0, to: 1.01))
        p.sample(at: 1.016, held: [], button: false, flags: 0x40000)        // nhấn ⌃
        XCTAssertTrue(p.flagsPressed(from: 1.01, to: 1.02))
        p.keyReceived(51, at: 1.020, isRepeat: false)                        // ⌫ ở ứng dụng khác…
        p.forget()                                                           // …rồi đổi ô nhập liệu
        p.sample(at: 1.024, held: [51], button: false, flags: 0x40000)      // ⌫ Terminal.app tự xử lý
        XCTAssertEqual(p.pending.map(\.key), [51])
        XCTAssertTrue(p.anyHeld)
    }

    /// Đọc trạng thái phím đặc biệt / nút chuột: phím bộ gõ nhận được đối chiếu, phím terminal tự xử lý và click thì không.
    func testPressLogMatchesKeysAndFindsBypass() {
        var p = PressLog()
        p.maxGap = 1                                                              // đọc thưa cho gọn: không có khoảng hở
        p.sample(at: 1.000, held: [], button: false, flags: 0)
        p.sample(at: 1.008, held: [51], button: false, flags: 0)                // ⌫ được nhấn…
        p.keyReceived(51, at: 1.010, isRepeat: false)                            // …và tới bộ gõ (Ghostty)
        p.sample(at: 1.016, held: [], button: false, flags: 0)
        p.keyReceived(0, at: 1.100, isRepeat: false)
        XCTAssertTrue(missed(&p, before: 1.100).isEmpty)
        p.sample(at: 1.200, held: [123], button: false, flags: 0)               // ← (Terminal.app không đưa bộ gõ)
        p.sample(at: 1.208, held: [], button: false, flags: 0)
        p.keyReceived(14, at: 1.300, isRepeat: false)
        XCTAssertEqual(missed(&p, before: 1.300), [PressLog.Press(key: 123, at: 1.200, after: 1.016)])
        XCTAssertTrue(missed(&p, before: 1.400).isEmpty)                       // đã lấy ra
        p.sample(at: 1.248, held: [], button: true, flags: 0)                    // click
        p.keyReceived(15, at: 1.400, isRepeat: false)
        XCTAssertEqual(missed(&p, before: 1.400), [PressLog.Press(key: nil, at: 1.248, after: 1.208)])
    }

    /// Bộ gõ nhận phím trước lần đọc thấy nó được nhấn: vẫn đối chiếu được. Phím bấm ngay sau phím vừa tới (trong `lead`)
    /// chưa tính, để lần sau.
    func testPressLogKeyArrivesBeforeSampleAndLead() {
        var p = PressLog()
        p.sample(at: 1.000, held: [], button: false, flags: 0)
        p.keyReceived(36, at: 1.003, isRepeat: false)                            // ⏎ tới bộ gõ trước
        p.sample(at: 1.008, held: [36], button: false, flags: 0)
        XCTAssertTrue(p.pending.isEmpty)
        p.sample(at: 1.016, held: [], button: false, flags: 0)
        p.sample(at: 1.024, held: [48], button: false, flags: 0)                 // ⇥ nhấn ngay trước phím sau…
        p.keyReceived(3, at: 1.028, isRepeat: false)
        XCTAssertTrue(missed(&p, before: 1.028).isEmpty)                       // …chưa chắc là trước hay sau nó
        XCTAssertEqual(missed(&p, before: 1.2).map(\.key), [48])
    }

    /// Đọc có khoảng hở: không biết gì xảy ra giữa chừng (`covered`); phím / nút đang giữ lúc đọc lại không tính là vừa
    /// nhấn (vd. chính cú click làm đổi ứng dụng).
    func testPressLogCoverage() {
        var p = PressLog()
        p.sample(at: 1.00, held: [], button: false, flags: 0)
        p.sample(at: 1.04, held: [], button: false, flags: 0)
        XCTAssertTrue(p.covered(since: 1.0))
        p.sample(at: 2.00, held: [124], button: true, flags: 1)
        XCTAssertFalse(p.covered(since: 1.5))
        XCTAssertTrue(p.covered(since: 2.0))
        XCTAssertTrue(p.pending.isEmpty)
        XCTAssertFalse(p.pressed(from: 1.9, to: 2.1))
        p.sample(at: 2.01, held: [], button: false, flags: 3)
        p.sample(at: 2.02, held: [124], button: true, flags: 3)
        XCTAssertTrue(p.pressed(from: 2.01, to: 2.03))
        XCTAssertEqual(p.pending.map(\.key), [124, nil])
        XCTAssertTrue(p.flagsChanged(from: 2.0, to: 2.02))
        XCTAssertFalse(p.flagsChanged(from: 1.0, to: 1.99))
    }

    /// macOS 27: phím bộ gõ nhận lúc `stamp`. Lần nhấn mà ở lần đọc từ `stamp` trở đi vẫn chưa giữ thì chắc là sau phím đó (dù
    /// thời điểm sự kiện là lúc bấm hay lúc ứng dụng nhận): để lại cho phím sau, không báo ở phím này (trước đây mọi lần nhấn
    /// đang chờ đều "chưa chắc": phím có ⇥ bấm ngay sau nó bị bỏ từ oan).
    func testPressLogOrderLeavesLaterPressPending() {
        var p = PressLog()
        p.sample(at: 1.000, held: [], button: false, flags: 0)
        p.sample(at: 1.008, held: [], button: false, flags: 0)
        p.sample(at: 1.016, held: [48], button: false, flags: 0)              // ⇥ (Muxy tự xử lý)
        XCTAssertEqual(p.pending, [PressLog.Press(key: 48, at: 1.016, after: 1.008)])
        var order = p.order(keyAt: 1.007, maxDelivery: 0.068, burst: false)  // ⇥ chưa giữ lúc 1.008: sau phím này
        XCTAssertTrue(order.taken.isEmpty)
        XCTAssertFalse(order.uncertain)
        order = p.order(keyAt: 1.040, maxDelivery: 0.068, burst: false)      // có thể trước phím này: chưa chắc
        XCTAssertTrue(order.taken.isEmpty)
        XCTAssertTrue(order.uncertain)
        order = p.order(keyAt: 1.200, maxDelivery: 0.068, burst: true)       // dồn ra sau lúc treo: không lấy gì
        XCTAssertTrue(order.taken.isEmpty)
        XCTAssertTrue(order.uncertain)
        order = p.order(keyAt: 1.200, maxDelivery: 0.068, burst: false)
        XCTAssertEqual(order.taken.map(\.key), [48])
        XCTAssertFalse(order.uncertain)
    }

    /// macOS 27: bộ đếm click chỉ được công bố mỗi 0,5 s (thời điểm làm tròn xuống). Click làm ô nhận focus thường chỉ được
    /// công bố sau lúc bộ gõ lấy mốc: không tính. Click ở ô 0,5 s sau đó thì tính — kể cả khi lần đọc nút chuột không thấy nó
    /// (chạm để click trên trackpad).
    func testPointerWatchAbsorbsLatePublishedFocusClick() {
        var w = PointerWatch()
        w.rebase(7, at: 100.31, quantum: 0.5)
        XCTAssertFalse(w.differs(8, lastClickAt: 100.0))
        XCTAssertFalse(w.changed(8, lastClickAt: 100.0))
        XCTAssertFalse(w.changed(8, lastClickAt: 100.0))
        XCTAssertTrue(w.differs(9, lastClickAt: 100.5))
        XCTAssertTrue(w.changed(9, lastClickAt: 100.5))
        XCTAssertFalse(w.changed(9, lastClickAt: 100.5))
        var exact = PointerWatch()                                             // macOS 26: mọi lần đổi đều tính
        exact.rebase(7)
        XCTAssertTrue(exact.changed(8, lastClickAt: 0))
    }

    /// macOS 26: click ngay trước lúc phím tới có thể xảy ra sau phím đó, nên phím sau cũng báo — trừ khi lần đọc nút chuột
    /// đã thấy click (đã sắp thứ tự với phím, hay còn chờ báo ở phím sau): không báo hai lần (click rồi gõ nhanh "qua1" thành
    /// "qúa").
    func testPointerWatchCarryOnlyForUnsampledClick() {
        var w = PointerWatch()
        w.rebase(3)
        XCTAssertTrue(w.moved(4, recentClick: true, sampled: true))
        XCTAssertFalse(w.moved(4, recentClick: false, sampled: false))
        XCTAssertTrue(w.moved(5, recentClick: true, sampled: false))         // chạm để click: lần đọc không thấy
        XCTAssertTrue(w.moved(5, recentClick: false, sampled: false))        // báo cả ở phím sau
        XCTAssertFalse(w.moved(5, recentClick: false, sampled: false))
        XCTAssertTrue(w.moved(6, recentClick: false, sampled: false))        // click từ trước đó: chỉ phím này
        XCTAssertFalse(w.moved(6, recentClick: false, sampled: false))
    }

    /// Ứng dụng treo 0,4 s trong lúc gõ "Viet" (không phím nào đi vòng): lần kiểm tra lúc người dùng dừng tay tính nhầm
    /// phím đang chờ là lỡ; khi hết treo, phím tới không "ngay" → huỷ kết luận: không bỏ từ, chỉ "chưa biết" rồi sạch.
    func testLedgerStallDoesNotInterrupt() {
        var l = ledger(at: 10)
        XCTAssertEqual(l.observe(reading(11, at: 1.0, code: 1)), .clean)                           // V
        // ứng dụng treo; 'i' bấm lúc 1.12 (đếm 12), người dùng dừng tay → kiểm tra lúc 1.29 tính 'i' là lỡ
        XCTAssertEqual(l.check(keyDownCount: 12, secondsSinceLastKeyDown: 0.17), .resolved)
        // 'e' bấm lúc 1.30 (đếm 13); hết treo lúc 1.50: 'i' tới (phím mới nhất bấm cách đây 0,2 s)
        let i = KeyReading(keyDownCount: 13, timestamp: 1.5, keyCode: 2, isRepeat: false, sinceLastKeyDown: 0.2)
        XCTAssertEqual(l.observe(i), .unknown)
        let e = KeyReading(keyDownCount: 13, timestamp: 1.501, keyCode: 3, isRepeat: false, sinceLastKeyDown: 0.2)
        XCTAssertEqual(l.observe(e), .clean)
        XCTAssertEqual(l.observe(reading(14, at: 1.6, code: 4)), .clean)
    }

    func testLedgerRepeatsAreNotCounted() {
        var l = ledger(at: 10)
        XCTAssertEqual(l.observe(reading(11, at: 1.1, code: 1)), .clean)
        for i in 1...5 {   // hệ thống không đếm phím lặp
            XCTAssertEqual(l.observe(reading(11, at: 1.1 + Double(i) * 0.03, code: 1, repeat: true)), .clean)
        }
        XCTAssertEqual(l.observe(reading(12, at: 1.5, code: 2)), .clean)
    }

    func testLedgerDuplicateDeliveryCountedOnce() {
        var l = ledger(at: 10)
        XCTAssertEqual(l.observe(reading(11, at: 1.1, code: 7)), .clean)
        XCTAssertEqual(l.observe(reading(11, at: 1.1, code: 7)), .clean)
        XCTAssertEqual(l.observe(reading(12, at: 1.2, code: 8)), .clean)
    }

    func testLedgerCounterWraps() {
        var l = ledger(at: UInt32.max - 1)
        XCTAssertEqual(l.observe(reading(UInt32.max, at: 1.1, code: 1)), .clean)
        XCTAssertEqual(l.observe(reading(0, at: 1.2, code: 2)), .clean)
        XCTAssertEqual(l.observe(reading(2, at: 1.3, code: 3)), .unknown)
    }

    /// Hệ thống không đếm các phím bộ gõ nhận (phím do chương trình khác gõ): sau vài phím thì sổ chuyển sang
    /// `.uncounted` (chỉ còn dựa vào phím bổ trợ), rồi trở lại bình thường khi phím lại được đếm.
    func testLedgerUncountedKeys() {
        var l = ledger(at: 10)
        var verdicts: [GapVerdict] = []
        for i in 0..<10 { verdicts.append(l.observe(reading(10, at: 1.0 + Double(i) * 0.1, code: UInt16(i)))) }
        XCTAssertEqual(verdicts.prefix(5).filter { $0 == .unavailable }.count, 5, "\(verdicts)")
        XCTAssertTrue(verdicts[5...].allSatisfy { $0 == .uncounted }, "\(verdicts)")
        XCTAssertEqual(GapVerdict.uncounted.gap(modifierPressed: false), .unverified)
        XCTAssertEqual(GapVerdict.uncounted.gap(modifierPressed: true), .interrupted)
        XCTAssertEqual(l.observe(reading(11, at: 3.0, code: 50)), .clean)
    }

    /// Bộ gõ vừa gắn vào ô nhập liệu: mọi thứ trước đó (phím gõ ở app khác…) không tính.
    func testLedgerRebase() {
        var l = ledger(at: 10)
        XCTAssertEqual(l.observe(reading(11, at: 1.0, code: 1)), .clean)
        l.rebase(keyDownCount: 40)               // 29 phím ở app khác
        XCTAssertEqual(l.observe(reading(41, at: 5.0, code: 2)), .clean)
    }

    /// Ứng dụng giao phím chậm (35 ms sau lúc bấm): sổ học độ trễ đó từ các phím sạch — phím tắt đi vòng (⌘V) được tính là
    /// lỡ ngay ở phím sau nó và phím kế tiếp xác nhận, như ở ứng dụng giao nhanh. Ngưỡng cố định 20 ms: phím kế tiếp vẫn
    /// "chưa biết" (đi nguyên văn).
    func testLedgerSlowDeliveryLearnsPromptWindow() {
        for learn in [true, false] {
            var l = ledger(at: 10)
            if !learn { l.promptWindowCap = l.promptWindow }
            func key(_ count: UInt32, _ t: Double, _ code: UInt16, modifier: Bool = false) -> GapVerdict {
                l.observe(KeyReading(keyDownCount: count, timestamp: t, keyCode: code, isRepeat: false,
                                     sinceLastKeyDown: 0.035), modifierPressed: modifier)
            }
            for i in 0..<6 { XCTAssertEqual(key(11 + UInt32(i), 1.0 + Double(i) * 0.2, UInt16(i)), .clean) }
            XCTAssertEqual(key(18, 2.4, 20, modifier: true), .missed(1))      // ⌘V đi vòng rồi phím này
            XCTAssertEqual(key(19, 2.6, 21), learn ? .clean : .unknown)
        }
    }

    /// Sổ mới (chưa học), ứng dụng giao chậm (30 ms): ⌘V không được tính ngay; mỗi lần dừng tay, lần kiểm tra tính nó là lỡ
    /// và phím sau (tới sau 30 ms) huỷ — trước đây sổ kẹt ở "chưa biết" mãi (mọi phím đi nguyên văn). Phím huỷ là phím duy
    /// nhất bấm sau lần tính: sổ học độ trễ của nó, vài lần sau thì xác nhận được và sổ sạch lại.
    func testLedgerSlowDeliveryRecoversFromUnbookedBypass() {
        var l = ledger(at: 10)
        func key(_ count: UInt32, _ t: Double, _ code: UInt16, modifier: Bool = false) -> GapVerdict {
            l.observe(KeyReading(keyDownCount: count, timestamp: t, keyCode: code, isRepeat: false,
                                 sinceLastKeyDown: 0.03), modifierPressed: modifier)
        }
        XCTAssertEqual(key(11, 1.0, 1), .clean)
        XCTAssertEqual(key(13, 1.3, 2, modifier: true), .missed(1))     // chưa tính: phím này không "tới ngay" theo 20 ms
        var count: UInt32 = 13, t = 1.3, verdicts: [GapVerdict] = []
        for i in 0..<8 {
            XCTAssertEqual(l.check(keyDownCount: count, secondsSinceLastKeyDown: 0.4, now: t + 0.4), .resolved)
            count += 1
            t += 0.5
            verdicts.append(key(count, t, UInt16(10 + i)))
            if verdicts.last != .unknown { break }
        }
        XCTAssertEqual(verdicts, [.unknown, .unknown, .unknown, .missed(1)])
        XCTAssertEqual(key(count + 1, t + 0.2, 30), .clean)
    }

    /// Ngưỡng học được có trần (`promptWindowCap`): dù ứng dụng giao phím rất chậm, phím nằm chờ lúc ứng dụng treo (phím mới
    /// nhất bấm cách đây 0,2 s) không xác nhận lần tính phím lỡ (như `testLedgerStallDoesNotInterrupt`).
    func testLedgerLearnedWindowStillStopsStalls() {
        var l = ledger(at: 10)
        for i in 0..<12 {
            XCTAssertEqual(l.observe(KeyReading(keyDownCount: 11 + UInt32(i), timestamp: 1.0 + Double(i) * 0.1,
                                                keyCode: UInt16(i), isRepeat: false, sinceLastKeyDown: 0.075)), .clean)
        }
        XCTAssertEqual(l.check(keyDownCount: 23, secondsSinceLastKeyDown: 0.17, now: 2.3), .resolved)
        let i = KeyReading(keyDownCount: 24, timestamp: 2.5, keyCode: 40, isRepeat: false, sinceLastKeyDown: 0.2)
        XCTAssertEqual(l.observe(i), .unknown)
        let e = KeyReading(keyDownCount: 24, timestamp: 2.501, keyCode: 41, isRepeat: false, sinceLastKeyDown: 0.2)
        XCTAssertEqual(l.observe(e), .clean)
    }

    /// macOS 27 công bố thời điểm sự kiện ở mốc 0,5 s. Loại chưa từng xảy ra giữ thời điểm tạo phiên — trùng nhau, chỉ lệch vì
    /// lúc đọc đồng hồ (có khi vài micro giây): không được coi là các thời điểm thật khác nhau (trước đây: "tức thời", sai
    /// suốt phiên trên macOS 27).
    func testEventTimesQuantized() {
        let never = (0..<5).map { 42.637_215 + Double($0) * 3e-6 }        // 5 loại chưa xảy ra
        XCTAssertEqual(KeyLedger.eventTimesQuantized([1000.5, 1000.5, 999.0] + never), true)
        XCTAssertEqual(KeyLedger.eventTimesQuantized([1000.123_4, 1000.371_9, 998.004_1] + never), false)
        XCTAssertNil(KeyLedger.eventTimesQuantized(never))                  // mới đăng nhập: chưa biết
        XCTAssertNil(KeyLedger.eventTimesQuantized([1000.123_4] + never))
    }

    /// Mô phỏng theo thời gian: phím bấm theo nhịp ngẫu nhiên (có lúc hai phím gần như cùng lúc), hệ thống đếm lúc
    /// bấm; phím qua bộ gõ tới theo thứ tự sau độ trễ ngẫu nhiên (có lúc ứng dụng treo 20–150 ms); ~6 % phím đi vòng
    /// (một nửa có ⌘/⌃/⌥); bộ gõ hẹn kiểm tra `quietTime` sau mỗi lần đọc còn dư. Mỗi kết luận phải đúng:
    /// sạch ở phím k thì không có phím đi vòng nào bấm trước k mà chưa được báo.
    func testLedgerVerdictsAreSoundFuzz() {
        let stats = ledgerSoundFuzz(seeds: 0..<300, delivery: 0.0005...0.006)
        print("sổ phím (mô phỏng theo thời gian):", stats.sorted { $0.key < $1.key })
    }

    /// Như trên với ứng dụng giao phím chậm (25–60 ms, iTerm2 / Terminal.app bận): ngưỡng "tới ngay" học theo độ trễ đo
    /// được vẫn không báo sạch khi có phím đi vòng chưa báo; và sổ ít kẹt ở "chưa biết" hơn ngưỡng cố định 20 ms.
    func testLedgerVerdictsAreSoundWithSlowDelivery() {
        let learned = ledgerSoundFuzz(seeds: 0..<200, delivery: 0.025...0.06)
        let fixed = ledgerSoundFuzz(seeds: 0..<200, delivery: 0.025...0.06, learn: false)
        print("sổ phím (giao chậm, học ngưỡng):", learned.sorted { $0.key < $1.key })
        print("sổ phím (giao chậm, ngưỡng cố định):", fixed.sorted { $0.key < $1.key })
        let unsure = { (s: [String: Int]) in s["unknown", default: 0] + s["unknownSteady", default: 0] }
        XCTAssertGreaterThan(unsure(fixed), unsure(learned) * 3 / 2, "học ngưỡng phải bớt kẹt ở chưa biết")
    }

    /// Mô phỏng sổ phím theo thời gian (xem `testLedgerVerdictsAreSoundFuzz`); độ trễ giao phím (ngoài lúc treo) trong
    /// `delivery`. `learn`: false — ngưỡng "tới ngay" cố định (`promptWindow`).
    private func ledgerSoundFuzz(seeds: Range<Int>, delivery: ClosedRange<Double>, learn: Bool = true) -> [String: Int] {
        var stats = [String: Int]()
        for seed in seeds {
            var rng = SplitMix(state: UInt64(seed) &* 7919 &+ 17)
            var l = KeyLedger()
            if !learn { l.promptWindowCap = l.promptWindow }
            struct Press { var t: Double; var seen: Bool; var modifier: Bool; var arrive = 0.0 }
            var presses: [Press] = []
            var t = 5.0
            for _ in 0..<250 {
                let r = rng.unit()
                t += r < 0.04 ? rng.range(0, 0.003) : r < 0.3 ? rng.range(0.01, 0.06) : rng.range(0.06, 0.35)
                let bypass = rng.unit() < 0.06
                presses.append(Press(t: t, seen: !bypass, modifier: bypass && rng.unit() < 0.5))
            }
            var lastArrive = 0.0
            for i in presses.indices where presses[i].seen {
                let stall = rng.unit() < 0.04 ? rng.range(0.02, 1.0) : 0
                lastArrive = max(presses[i].t + rng.range(delivery.lowerBound, delivery.upperBound) + stall,
                                 lastArrive + 0.0002)
                presses[i].arrive = lastArrive
            }
            func counted(by time: Double) -> UInt32 { UInt32(1000 + presses.filter { $0.t <= time }.count) }
            l.rebase(keyDownCount: counted(by: 0))
            var forgivenUpTo = -Double.infinity
            var previousSeen: Press?
            var checks = Checks()
            let seenOrder = presses.filter(\.seen)
            for (n, p) in seenOrder.enumerated() {
                // các lần kiểm tra hẹn giờ tới trước phím này
                checks.run(until: p.arrive, &l) { at in
                    (counted(by: at), at - (presses.last { $0.t <= at }?.t ?? -1))
                } resolved: { stats["kiểm tra: lỡ", default: 0] += 1 }
                let modifier = presses.contains { $0.modifier && $0.t > (previousSeen?.t ?? -1) && $0.t < p.t }
                let newestPress = presses.last { $0.t <= p.arrive }?.t ?? p.t
                let v = l.observe(KeyReading(keyDownCount: counted(by: p.arrive), timestamp: p.arrive,
                                             keyCode: UInt16(n % 50), isRepeat: false,
                                             sinceLastKeyDown: p.arrive - newestPress), modifierPressed: modifier)
                stats["\(v)", default: 0] += 1
                let hidden = { (from: Double, to: Double) in
                    presses.filter { !$0.seen && $0.t > max(from, forgivenUpTo) && $0.t < to }.count
                }
                switch v {
                case .clean:
                    XCTAssertEqual(hidden(-.infinity, p.t), 0, "seed \(seed) phím \(n): báo sạch nhưng có phím đi vòng")
                case .unknownSteady:
                    // Không có phím đi vòng nào bấm sau lần đọc phím trước — trừ khi chính phím này đã được bấm trước lúc
                    // đó (đang tới), rủi ro còn lại đã biết.
                    if let prev = previousSeen, p.t > prev.arrive {
                        let after = presses.filter { !$0.seen && $0.t > prev.arrive && $0.t <= p.arrive }.count
                        XCTAssertEqual(after, 0, "seed \(seed) phím \(n): báo không có gì mới nhưng có phím đi vòng")
                    }
                case .missed, .unavailable, .uncounted:
                    // Lần tính phím lỡ lúc đọc phím k gồm mọi phím đã đếm tới lúc đó, kể cả phím đi vòng bấm trong vài
                    // mili giây giữa lúc bấm k và lúc ứng dụng nhận k (rủi ro còn lại, chấp nhận: cần hai phím gần như
                    // cùng lúc ngay tại phím có lần tính phím lỡ).
                    forgivenUpTo = p.arrive
                case .unknown:
                    break
                }
                checks.start(after: p.arrive)
                previousSeen = p
            }
        }
        return stats
    }

    /// Gõ bình thường (không phím nào đi vòng): ứng dụng không treo thì sổ không bao giờ báo lỡ, chỉ "chưa biết" khi có
    /// phím đang tới. Ứng dụng treo lâu hơn thời gian chờ (ở đây rất nặng: cứ ~33 phím một lần, tới 1 s) thì còn trùng
    /// hợp hiếm — hết treo đúng lúc vừa bấm phím đầu tiên sau lần kiểm tra — làm bỏ từ oan (chỉ mất dấu, không xoá gì):
    /// đo tỉ lệ.
    func testLedgerNoFalseMissesWhenNothingBypasses() {
        var stats = [String: Int]()
        var falseInterruptions = 0, keys = 0, falseWithoutStall = 0
        for seed in 0..<200 {
            var rng = SplitMix(state: UInt64(seed) &* 104729 &+ 3)
            var stalled = false
            var l = KeyLedger()
            var presses: [Double] = []
            var t = 5.0
            for _ in 0..<300 { t += rng.unit() < 0.3 ? rng.range(0.008, 0.05) : rng.range(0.05, 0.25); presses.append(t) }
            var arrive: [Double] = []
            var lastArrive = 0.0
            for p in presses {
                let stall = rng.unit() < 0.03 ? rng.range(0.02, 1.0) : 0
                if stall > 0.15 { stalled = true }
                lastArrive = max(p + rng.range(0.0005, 0.006) + stall, lastArrive + 0.0002)
                arrive.append(lastArrive)
            }
            func counted(by time: Double) -> UInt32 { UInt32(presses.filter { $0 <= time }.count) }
            l.rebase(keyDownCount: 0)
            var checks = Checks()
            for i in presses.indices {
                checks.run(until: arrive[i], &l) { at in
                    (counted(by: at), at - (presses.last { $0 <= at } ?? -1))
                } resolved: {}
                let newestPress = presses.last { $0 <= arrive[i] } ?? presses[i]
                let v = l.observe(KeyReading(keyDownCount: counted(by: arrive[i]), timestamp: arrive[i],
                                             keyCode: UInt16(i % 40), isRepeat: false,
                                             sinceLastKeyDown: arrive[i] - newestPress))
                stats["\(v)", default: 0] += 1
                keys += 1
                if !(v == .clean || v == .unknown || v == .unknownSteady) {
                    falseInterruptions += 1
                    if !stalled { falseWithoutStall += 1 }
                }
                checks.start(after: arrive[i])
            }
        }
        print("sổ phím (gõ thường, có lúc treo):", stats.sorted { $0.key < $1.key })
        XCTAssertEqual(falseWithoutStall, 0, "bỏ từ oan khi ứng dụng không treo lâu")
        XCTAssertTrue(Double(falseInterruptions) / Double(keys) < 0.005, "bỏ từ oan: \(falseInterruptions)/\(keys)")
        print("bỏ từ oan khi ứng dụng treo:", falseInterruptions, "/", keys, "phím")
    }

    // MARK: - Phím tắt đổi chế độ (macOS 27)

    private static let cmd: UInt64 = 0x100000
    private static let shift: UInt64 = 0x20000

    /// ⌘⇧ nhấn rồi nhả, như `LiveInput` đọc: mỗi `tick` giây từ `readingFrom` (nil: chỉ từ lúc nhấn tổ hợp) tới lúc hỏi
    /// (`release`, lúc bộ gõ nhận lần nhả). `mods`: phím bổ trợ từ mỗi thời điểm, WindowServer thấy trễ `flagLag`; `hid`: các
    /// sự kiện HID (bàn phím / chuột thật). Bộ gõ nhận tổ hợp lúc `arm`: đọc, rồi lấy mốc HID ngay sau đó (`trackHID`).
    private func hotkeyTap(hid: [Double], mods: [(t: Double, flags: UInt64)], arm: Double, release: Double,
                           readingFrom start: Double? = nil, tick: Double = 0.002, flagLag: Double = 0,
                           lastKeyAt: Double = -10) -> Bool {
        func flags(_ t: Double) -> UInt64 { mods.last { $0.t <= t - flagLag }?.flags ?? 0 }
        func latest(_ t: Double) -> Double { hid.filter { $0 <= t }.max() ?? -100 }
        var log = PressLog()
        var t = start ?? arm
        while t < arm {
            log.sample(at: t, held: [], button: false, flags: flags(t))
            t += tick
        }
        log.sample(at: arm, held: [], button: false, flags: flags(arm))
        log.startHID()
        log.noteHID(latest(arm))
        t = arm + tick
        while t < release {
            log.sample(at: t, held: [], button: false, flags: flags(t))
            log.noteHID(latest(t))
            t += tick
        }
        log.sample(at: release, held: [], button: false, flags: flags(release))
        log.noteHID(latest(release))
        return log.hotkeyTapClean(armedAt: arm, lastKeyAt: lastKeyAt)
    }

    /// Nhấn ⌘⇧ rồi nhả: các sự kiện HID sau lúc nhấn chỉ là lần nhả ⌘ và ⇧. Kể cả khi nhả cả hai giữa hai lần đọc phím bổ
    /// trợ mà lần đọc HID thấy hai sự kiện (WindowServer cập nhật phím bổ trợ trễ): mỗi phím bổ trợ giải thích một sự kiện.
    func testHotkeyCleanTap() {
        let (c, s) = (Self.cmd, Self.shift)
        XCTAssertTrue(hotkeyTap(hid: [10.000, 10.060, 10.180, 10.200],
                                mods: [(10.000, c), (10.060, c | s), (10.180, c), (10.200, 0)],
                                arm: 10.063, release: 10.204))
        XCTAssertTrue(hotkeyTap(hid: [10.000, 10.060, 10.1825, 10.188],
                                mods: [(10.000, c), (10.060, c | s), (10.1825, c), (10.188, 0)],
                                arm: 10.063, release: 10.195, tick: 0.008, flagLag: 0.0008))
    }

    /// ⌘⇧] / ⌘⇧Z bấm nhanh (lab review: ⇧ lúc 40 ms, ] lúc 60, nhả ] lúc 130, ⇧ lúc 150, ⌘ lúc 170; đang đọc 8 ms một lần):
    /// trước đây lần nhấn tổ hợp và lần nhả ⇧ "che" cả hai sự kiện của phím ] trong ±25 ms — đổi chế độ nhầm. Kể cả khi
    /// vừa gõ chữ ngay trước đó (một sự kiện lẻ có thể là lần nhả phím chữ: ở đây có hai).
    func testHotkeyFastChordIsNotATap() {
        let (c, s) = (Self.cmd, Self.shift)
        let hid = [10.000, 10.040, 10.060, 10.130, 10.150, 10.170]
        let mods: [(t: Double, flags: UInt64)] = [(10.000, c), (10.040, c | s), (10.150, c), (10.170, 0)]
        XCTAssertFalse(hotkeyTap(hid: hid, mods: mods, arm: 10.042, release: 10.172, readingFrom: 9.7, tick: 0.008))
        XCTAssertFalse(hotkeyTap(hid: hid, mods: mods, arm: 10.042, release: 10.172, readingFrom: 9.7, tick: 0.008,
                                 lastKeyAt: 9.95))
        XCTAssertFalse(hotkeyTap(hid: hid, mods: mods, arm: 10.042, release: 10.172))
    }

    /// Gõ chữ rồi nhấn ⌘⇧ ngay, nhả phím chữ sau lúc nhấn tổ hợp: một sự kiện lẻ ngay sau phím chữ đó — vẫn là nhấn trơn. Không
    /// có phím chữ nào ngay trước thì sự kiện đó là phím khác (⌘⇧ + phím ký tự).
    func testHotkeyTapRightAfterTyping() {
        let (c, s) = (Self.cmd, Self.shift)
        let hid = [9.940, 10.000, 10.040, 10.060, 10.150, 10.170]
        let mods: [(t: Double, flags: UInt64)] = [(10.000, c), (10.040, c | s), (10.150, c), (10.170, 0)]
        XCTAssertTrue(hotkeyTap(hid: hid, mods: mods, arm: 10.043, release: 10.172, lastKeyAt: 9.945))
        XCTAssertFalse(hotkeyTap(hid: hid, mods: mods, arm: 10.043, release: 10.172))
        XCTAssertFalse(hotkeyTap(hid: hid, mods: mods, arm: 10.043, release: 10.172, lastKeyAt: 9.5))
    }

    /// Ứng dụng giao tổ hợp chậm: chữ Z của ⌘⇧Z được bấm trước lúc bộ gõ nhận ⇧ (lấy mốc HID), lần nhả Z trùng một lần đọc với
    /// lần nhả ⇧. Đang đọc từ trước (gõ trong terminal): sự kiện mới nhất lúc lấy mốc là sau lần đọc thấy ⇧ được nhấn — có gì
    /// đó xen giữa, không phải nhấn trơn.
    func testHotkeyKeyPressedBeforeSlowArm() {
        let (c, s) = (Self.cmd, Self.shift)
        let hid = [10.000, 10.040, 10.046, 10.118, 10.120, 10.140]
        let mods: [(t: Double, flags: UInt64)] = [(10.000, c), (10.040, c | s), (10.120, c), (10.140, 0)]
        XCTAssertFalse(hotkeyTap(hid: hid, mods: mods, arm: 10.050, release: 10.150, readingFrom: 9.7, tick: 0.008))
        // không có Z: nhấn trơn
        XCTAssertTrue(hotkeyTap(hid: [10.000, 10.040, 10.120, 10.140], mods: mods, arm: 10.050, release: 10.150,
                                readingFrom: 9.7, tick: 0.008))
    }

    /// Giữ ⌘⇧ lâu hơn hạn theo dõi (3 s) rồi mới bấm Z: không còn đọc HID (và timer đã dừng) — không biết, không phải nhấn trơn.
    /// Trong hạn thì giữ lâu vẫn được. Lần nhấn sau bắt đầu lại từ đầu (sự kiện của lần trước không còn).
    func testHotkeyHoldBeyondTracking() {
        let both = Self.cmd | Self.shift
        var log = PressLog()
        log.sample(at: 10.0, held: [], button: false, flags: both)
        log.startHID()
        log.noteHID(9.99)
        var t = 10.0
        while t < 13.0 {
            t += 0.002
            log.sample(at: t, held: [], button: false, flags: both)
            log.noteHID(9.99)
        }
        log.endHID()
        log.sample(at: 14.0, held: [], button: false, flags: 0)       // Z lúc 13,5 không ai thấy; timer dừng: khoảng hở
        XCTAssertFalse(log.hotkeyTapClean(armedAt: 10.0, lastKeyAt: -10))
        var held = PressLog()
        held.sample(at: 20.0, held: [], button: false, flags: both)
        held.startHID()
        held.noteHID(19.99)
        held.noteHID(20.5)                                             // di chuột lúc đang giữ
        XCTAssertEqual(held.hidEvents, [20.5])
        held.sample(at: 20.6, held: [], button: false, flags: both)    // khoảng hở trước lần nhấn sau
        held.startHID()
        XCTAssertEqual(held.hidEvents, [])
        held.noteHID(20.55)
        t = 20.6
        while t < 22.6 {
            t += 0.002
            held.sample(at: t, held: [], button: false, flags: t < 22.5 ? both : 0)
            held.noteHID(t < 22.5 ? 20.55 : 22.499)
        }
        XCTAssertTrue(held.hotkeyTapClean(armedAt: 20.6, lastKeyAt: -10))
    }

    /// Mô phỏng: ⌘⇧ nhấn rồi nhả trơn, hay kèm một phím chữ (⌘⇧Z: ⇧→Z 5–80 ms, giữ Z 50–130 ms, nhả ⇧ lệch −10…+60 ms
    /// so với Z), bộ gõ nhận tổ hợp sau 1–10 ms, đọc 2 ms một lần (đang đọc từ trước: 30 %), WindowServer thấy phím bổ trợ
    /// trễ tới 1 ms; có lúc vừa gõ chữ ngay trước. Lab review đo cách cũ: đổi nhầm 12–17 %, tới 60–70 % khi vừa gõ chữ.
    func testHotkeyTapFuzz() {
        var rng = SplitMix(state: 2027)
        var stats = [String: Int]()
        let trials = 2000
        for typed in [false, true] {
            for chord in [false, true] {
                var accepted = 0
                for n in 0..<trials {
                    let (c, s) = (Self.cmd, Self.shift)
                    let shiftDown = 10 + rng.range(0.02, 0.15)
                    var hid = [10.0, shiftDown]
                    var lastKeyAt = -10.0
                    if typed {
                        let letter = 10 + rng.range(-0.25, -0.01)
                        hid += [letter, letter + rng.range(0.04, 0.16)]
                        lastKeyAt = letter + rng.range(0.001, 0.03)
                    }
                    let arm = shiftDown + rng.range(0.001, 0.01)
                    var shiftUp: Double
                    if chord {
                        let zDown = shiftDown + rng.range(0.005, 0.08), zUp = zDown + rng.range(0.05, 0.13)
                        hid += [zDown, zUp]
                        shiftUp = max(zUp + rng.range(-0.01, 0.06), zDown + 0.01)
                    } else {
                        shiftUp = shiftDown + rng.range(0.04, 0.2)
                    }
                    let cmdUp = max(shiftUp + rng.range(-0.03, 0.05), shiftDown + 0.005)
                    hid += [shiftUp, cmdUp]
                    var mods: [(t: Double, flags: UInt64)] = [(10.0, c), (shiftDown, c | s)]
                    if shiftUp < cmdUp {
                        mods += [(shiftUp, c), (cmdUp, 0)]
                    } else {
                        mods += [(cmdUp, s), (shiftUp, 0)]
                    }
                    let release = max(shiftUp, cmdUp) + rng.range(0.001, 0.03)
                    let start: Double? = n % 10 < 3 ? 9.7 + rng.range(0, 0.002) : nil
                    if hotkeyTap(hid: hid, mods: mods, arm: arm, release: release, readingFrom: start,
                                 flagLag: rng.range(0, 0.001), lastKeyAt: lastKeyAt) {
                        accepted += 1
                    }
                }
                stats["\(chord ? "⌘⇧Z" : "⌘⇧")\(typed ? " sau khi gõ" : "")"] = accepted
            }
        }
        print("phím tắt đổi chế độ (\(trials) lần mỗi loại, số lần đổi chế độ):", stats.sorted { $0.key < $1.key })
        XCTAssertGreaterThan(stats["⌘⇧", default: 0], trials * 99 / 100)
        XCTAssertGreaterThan(stats["⌘⇧ sau khi gõ", default: 0], trials * 99 / 100)
        XCTAssertGreaterThan(trials / 100, stats["⌘⇧Z", default: 0])
        XCTAssertGreaterThan(trials * 5 / 100, stats["⌘⇧Z sau khi gõ", default: 0])
    }

    // MARK: - Loại ô

    func testClientKindFromLabSignatures() {
        let textField = ["NSFont", "NSUnderline", "NSColor", "NSBackgroundColor", "NSUnderlineColor", "NSMarkedClauseSegment",
                         "NSLanguage", "NSTextInputReplacementRangeAttributeName", "NSTextAlternatives",
                         "NSTextInsertionUndoable", "NSDictationHiliteMarkedText"]
        XCTAssertEqual(ClientKind.classify(textField), .textView)
        XCTAssertEqual(ClientKind.classify(["NSDictationHiliteMarkedText"]), .terminalView)                     // Ghostty, Rex, Muxy
        XCTAssertEqual(ClientKind.classify(["NSUnderline", "NSBackgroundColor", "NSDictationHiliteMarkedText"]), .terminalView)
        XCTAssertEqual(ClientKind.classify(["NSColor", "NSBackgroundColor", "NSUnderline", "NSFont",
                                            "NSDictationHiliteMarkedText"]), .terminalView)                       // iTerm2
        XCTAssertEqual(ClientKind.classify([]), .terminalView)
        let placeholder = ["NSFont", "NSUnderline", "CTForegroundColor", "NSBackgroundColor", "NSUnderlineColor",
                           "NSMarkedClauseSegmentAttributeName", "NSGlyphInfo", "IMKIronwoodTextAlternatives",
                           "IMKTextPlaceholder"]
        XCTAssertEqual(ClientKind.classify(placeholder), .placeholder)
    }

    // MARK: - Session với sổ phím

    /// Muxy: Ctrl+A không qua bộ gõ. Gõ "echo tie", Ctrl+A, "e6": không được xoá chữ của shell (lab: "êecho tie").
    func testTerminalBypassedKeyEndsWord() {
        let p = Pty()
        p.type("echo tie")
        p.bypassLineStart()
        p.key("e", .interrupted)
        p.type("6")
        XCTAssertEqual(p.text, "êecho tie")
        let q = Pty()
        q.type("echo tie")
        q.bypassLineStart()
        q.key("x", .interrupted)
        q.type("6")
        XCTAssertEqual(q.text, "x6echo tie")
    }

    /// macOS 27: dừng tay giữa từ quá lâu thì `LiveInput` đã ngừng đọc — phím sau có khoảng không đọc, `KeyWatch` báo như có
    /// phím đi vòng (`.bypassed`), không bỏ từ ngay. Terminal cho đọc màn hình: màn hình cho thấy dòng vẫn đúng như lúc dừng
    /// tay, gõ tiếp từ đó ("Vie", dừng 6 s, "65t" → "Việt", trước đây "Vie65t"). Terminal khác: bỏ từ, như `.interrupted`.
    func testCoverageGapReportedAsBypass() {
        let s = ScreenPty()
        s.type("Vie")
        s.now += 6
        s.key("6", .bypassed)
        XCTAssertEqual(s.text, "Vie6")
        s.key("5", .none)
        s.key("t", .none)
        XCTAssertEqual(s.text, "Việt")
        let old = ScreenPty()
        old.type("Vie")
        old.now += 6
        old.key("6", .interrupted)
        old.type("5t")
        XCTAssertEqual(old.text, "Vie65t")
        for gap in [KeyGap.bypassed, .interrupted] {
            let p = Pty()
            p.type("Vie")
            p.key("6", gap)
            p.type("5t")
            XCTAssertEqual(p.text, "Vie65t")
        }
    }

    /// ⌘V giữa từ (Ghostty, mọi terminal): chữ dán không bị xoá.
    func testTerminalPasteMidWordKeepsPastedText() {
        let p = Pty()
        p.type("tie")
        p.bypassPaste("/tmp")
        p.key("6", .interrupted)
        XCTAssertEqual(p.text, "tie/tmp6")
    }

    /// Mũi tên trái không qua bộ gõ (iTerm2), view không cho biết con trỏ: sổ phím báo, không xoá nhầm.
    func testTerminalArrowBypassWithoutScreen() {
        let p = Pty()
        p.type("tie")
        p.bypassLeft()
        p.key("6", .interrupted)
        XCTAssertEqual(p.text, "ti6e")
    }

    /// Chưa chắc (phím kế tiếp đang tới): phím đi nguyên văn, phím sau khi đã chắc chắn sửa cả từ một lần.
    func testTerminalUnsureKeyIsFixedByNextKey() {
        let p = Pty()
        p.type("tie")
        p.key("6", .unsure)
        XCTAssertEqual(p.text, "tie6")
        p.key("n", .none)
        XCTAssertEqual(p.text, "tiên")
        p.type("1 ")
        XCTAssertEqual(p.text, "tiến ")
    }

    func testTerminalUnsureThenWordEnd() {
        let p = Pty()
        p.type("to")
        p.key("6", .unsure)
        p.key(" ", .none)
        XCTAssertEqual(p.text, "tô ")
        // cả phím kết thúc từ cũng chưa chắc: từ giữ nguyên văn, không xoá gì
        let q = Pty()
        q.type("to")
        q.key("6", .unsure)
        q.key(" ", .unsure)
        XCTAssertEqual(q.text, "to6 ")
        q.type("ye6u")
        XCTAssertEqual(q.text, "to6 yêu")
    }

    /// Nhiều phím liền "chưa chắc" rồi mới chắc chắn: một lần sửa đưa cả từ về đúng.
    func testTerminalSeveralUnsureKeys() {
        let p = Pty()
        p.type("Vi")
        p.key("e", .unsure)
        p.key("6", .unsure)
        p.key("5", .unsure)
        p.key("t", .none)
        XCTAssertEqual(p.text, "Việt")
    }

    /// Xoá lùi khi dòng đang khác từ của engine: vẫn chưa chắc thì theo đúng dòng (shell xoá "6"); đã chắc thì như thể
    /// không có lúc chưa chắc ("tiê" ⌫ → "ti").
    func testTerminalBackspaceWhileUnsure() {
        let p = Pty()
        p.type("tie")
        p.key("6", .unsure)
        p.backspace(gap: .unsure)
        XCTAssertEqual(p.text, "tie")
        p.type("61ng")
        XCTAssertEqual(p.text, "tiếng")
        let q = Pty()
        q.type("tie")
        q.key("6", .unsure)
        q.backspace(gap: .none)
        XCTAssertEqual(q.text, "ti")
        q.type("e61ng")
        XCTAssertEqual(q.text, "tiếng")
    }

    /// Chưa chắc rồi hoá ra có phím đi vòng: từ bị bỏ, chữ đã gõ nguyên văn giữ nguyên, không xoá gì.
    func testTerminalUnsureThenInterrupted() {
        let p = Pty()
        p.type("tie")
        p.key("6", .unsure)
        p.bypassLeft()
        p.key("n", .interrupted)
        XCTAssertEqual(p.text, "tien6")
    }

    /// Ghostty: lần sửa chưa tới (marked text rỗng còn đó) mà người dùng dán (⌘V, đi vòng bộ gõ): bỏ lần sửa, không
    /// được xoá chữ dán; phím chữ kế tiếp tự gửi (Ghostty nuốt phím khi đang soạn mà bộ gõ không đưa chữ).
    func testDeferredStaleEditDroppedAfterBypass() {
        let p = Pty()
        p.style = .deferred
        p.type("tie")
        p.runScheduledNow = false
        p.key("6", .none)
        XCTAssertTrue(p.markActive)
        XCTAssertEqual(p.text, "tie")
        p.bypassPaste("/tmp")
        XCTAssertTrue(p.session.handle(.char("x"), p, options: p.options, forceMarked: false, terminal: .deferred,
                                       gap: .interrupted))
        XCTAssertEqual(p.text, "tie/tmpx")
        XCTAssertFalse(p.markActive)
    }

    /// Ghostty: Enter tới khi lần sửa chưa tới (vài ms sau phím dấu, hoặc lần gửi bị bỏ): gửi lần sửa kèm "\r" trong một
    /// lần ghi — Enter không bị nuốt.
    func testDeferredPendingEditCarriesEnter() {
        let p = Pty()
        p.style = .deferred
        p.type("echo to")
        p.runScheduledNow = false
        p.key("6", .none)
        XCTAssertEqual(p.text, "echo to")
        XCTAssertTrue(p.session.handle(.char("\r"), p, options: p.options, forceMarked: false, terminal: .deferred,
                                       gap: .none, legacy: "\r"))
        XCTAssertEqual(p.text, "echo tô\r")
        XCTAssertFalse(p.markActive)
    }

    /// Ghostty: ⌫ tới khi lần sửa chưa tới: gửi lần sửa kèm DEL; từ vẫn theo dõi đúng để gõ tiếp.
    func testDeferredPendingEditCarriesBackspace() {
        let p = Pty()
        p.style = .deferred
        p.type("tie")
        p.runScheduledNow = false
        p.key("6", .none)
        XCTAssertTrue(p.session.handle(.backspace, p, options: p.options, forceMarked: false, terminal: .deferred,
                                       gap: .none, legacy: "\u{7f}"))
        XCTAssertEqual(p.text, "ti")
        p.runScheduledNow = true
        p.type("e65t")
        XCTAssertEqual(p.text, "tiệt")
    }

    /// Ghostty: lần sửa chưa tới, có ⌘V (đi vòng bộ gõ) rồi Enter: bỏ lần sửa (không xoá chữ dán), gỡ marked text, Enter
    /// vẫn tới shell.
    func testDeferredStaleEditDroppedBeforeEnter() {
        let p = Pty()
        p.style = .deferred
        p.type("tie")
        p.runScheduledNow = false
        p.key("6", .none)
        p.bypassPaste("/tmp")
        XCTAssertTrue(p.session.handle(.char("\r"), p, options: p.options, forceMarked: false, terminal: .deferred,
                                       gap: .interrupted, legacy: "\r"))
        XCTAssertEqual(p.text, "tie/tmp\r")
        XCTAssertFalse(p.markActive)
    }

    /// Ghostty: lần gửi hẹn giờ không gửi nếu đã có phím / click khác (có thể là ⌘V đi vòng bộ gõ): phím kế tiếp quyết định.
    func testDeferredTimerWaitsWhenInputArrived() {
        let p = Pty()
        p.style = .deferred
        p.type("tie")
        p.quiet = false
        p.key("6", .none)
        XCTAssertEqual(p.text, "tie")
        XCTAssertTrue(p.markActive)
        p.quiet = true
        p.key("n", .none)                       // phím kế tiếp (không có gì đi vòng): gửi trong keyDown của nó
        XCTAssertEqual(p.text, "tiên")
    }

    /// ⌫ khi dòng đang khác từ của engine (phím đi nguyên văn lúc chưa chắc), lúc đã chắc: sửa cả từ trong một lần ghi.
    func testBackspaceAfterUnsureKeysFixesWord() {
        let p = Pty()
        p.options = EngineOptions(method: .telex)
        p.type("Vie")
        p.key("e", .unsure)
        p.key("t", .unsure)
        XCTAssertEqual(p.text, "Vieet")
        p.backspace(gap: .none)
        XCTAssertEqual(p.text, "Viê")
        p.type("tj ")
        XCTAssertEqual(p.text, "Việt ")
        let q = Pty()
        q.type("tie")
        q.key("6", .unsure)
        q.key("1", .unsure)
        q.backspace(gap: .none)
        XCTAssertEqual(q.text, "ti")               // như gõ thường: ⌫ xoá cả chữ "ế"
        q.type("1n ")
        XCTAssertEqual(q.text, "tín ")
    }

    /// Từ có phím đi nguyên văn lúc chưa chắc, kết thúc bằng Enter khi đã chắc chắn: sửa cả từ cùng Enter trong một lần
    /// ghi — không chạy lệnh với chữ thô "to6".
    func testUnsureWordFixedTogetherWithEnter() {
        let p = Pty()
        p.type("echo to")
        p.key("6", .unsure)
        XCTAssertEqual(p.text, "echo to6")
        XCTAssertTrue(p.session.handle(.char("\r"), p, options: p.options, forceMarked: false, terminal: .inline,
                                       gap: .none, legacy: "\r"))
        XCTAssertEqual(p.text, "echo tô\r")
        // vẫn chưa chắc lúc Enter: không sửa, Enter đi thẳng
        let q = Pty()
        q.type("echo to")
        q.key("6", .unsure)
        XCTAssertFalse(q.session.handle(.char("\r"), q, options: q.options, forceMarked: false, terminal: .inline,
                                        gap: .unsure, legacy: "\r"))
        XCTAssertEqual(q.text, "echo to6")
    }

    /// Ghostty (`.deferred`): chưa chắc thì cũng không đặt marked text hay hẹn gửi gì.
    func testDeferredUnsureSendsNothing() {
        let p = Pty()
        p.style = .deferred
        p.type("tie")
        p.key("6", .unsure)
        XCTAssertEqual(p.text, "tie6")
    }
}
