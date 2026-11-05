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

    /// Đọc trạng thái phím đặc biệt / nút chuột: phím bộ gõ nhận được đối chiếu, phím terminal tự xử lý và click thì không.
    func testPressLogMatchesKeysAndFindsBypass() {
        var p = PressLog()
        p.maxGap = 1                                                              // đọc thưa cho gọn: không có khoảng hở
        p.sample(at: 1.000, held: [], button: false, flags: 0)
        p.sample(at: 1.008, held: [51], button: false, flags: 0)                // ⌫ được nhấn…
        p.keyReceived(51, at: 1.010, isRepeat: false)                            // …và tới bộ gõ (Ghostty)
        p.sample(at: 1.016, held: [], button: false, flags: 0)
        p.keyReceived(0, at: 1.100, isRepeat: false)
        XCTAssertTrue(p.takeMissed(before: 1.100).isEmpty)
        p.sample(at: 1.200, held: [123], button: false, flags: 0)               // ← (Terminal.app không đưa bộ gõ)
        p.sample(at: 1.208, held: [], button: false, flags: 0)
        p.keyReceived(14, at: 1.300, isRepeat: false)
        XCTAssertEqual(p.takeMissed(before: 1.300), [PressLog.Press(key: 123, at: 1.200)])
        XCTAssertTrue(p.takeMissed(before: 1.400).isEmpty)                       // đã lấy ra
        p.sample(at: 1.248, held: [], button: true, flags: 0)                    // click
        p.keyReceived(15, at: 1.400, isRepeat: false)
        XCTAssertEqual(p.takeMissed(before: 1.400), [PressLog.Press(key: nil, at: 1.248)])
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
        XCTAssertTrue(p.takeMissed(before: 1.028).isEmpty)                       // …chưa chắc là trước hay sau nó
        XCTAssertEqual(p.takeMissed(before: 1.2).map(\.key), [48])
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

    /// Mô phỏng theo thời gian: phím bấm theo nhịp ngẫu nhiên (có lúc hai phím gần như cùng lúc), hệ thống đếm lúc
    /// bấm; phím qua bộ gõ tới theo thứ tự sau độ trễ ngẫu nhiên (có lúc ứng dụng treo 20–150 ms); ~6 % phím đi vòng
    /// (một nửa có ⌘/⌃/⌥); bộ gõ hẹn kiểm tra `quietTime` sau mỗi lần đọc còn dư. Mỗi kết luận phải đúng:
    /// sạch ở phím k thì không có phím đi vòng nào bấm trước k mà chưa được báo.
    func testLedgerVerdictsAreSoundFuzz() {
        var stats = [String: Int]()
        for seed in 0..<300 {
            var rng = SplitMix(state: UInt64(seed) &* 7919 &+ 17)
            var l = KeyLedger()
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
                lastArrive = max(presses[i].t + rng.range(0.0005, 0.006) + stall, lastArrive + 0.0002)
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
        print("sổ phím (mô phỏng theo thời gian):", stats.sorted { $0.key < $1.key })
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

    /// Ghostty: lần sửa chưa tới, có ⌘V (đi vòng bộ gõ) rồi Enter: bỏ lần sửa (không xoá chữ dán), gỡ marked text.
    func testDeferredStaleEditDroppedBeforeEnter() {
        let p = Pty()
        p.style = .deferred
        p.type("tie")
        p.runScheduledNow = false
        p.key("6", .none)
        p.bypassPaste("/tmp")
        XCTAssertTrue(p.session.handle(.char("\r"), p, options: p.options, forceMarked: false, terminal: .deferred,
                                       gap: .interrupted, legacy: "\r"))
        XCTAssertEqual(p.text, "tie/tmp")
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
