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
    func setMarkedText(_ text: String) { XCTFail("terminal: không được gạch chân (\(text))") }
    func insertText(_ text: String) { write(text) }
    func replaceViaMarkedText(location: Int, length: Int, with text: String) { XCTFail("terminal: marked text") }

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

final class SignalsTests: XCTestCase {
    // MARK: - Sổ phím

    private func reading(_ count: UInt32, at t: Double, newest: Double? = nil, code: UInt16 = 0,
                         repeat isRepeat: Bool = false) -> KeyReading {
        KeyReading(keyDownCount: count, timestamp: t, keyCode: code, isRepeat: isRepeat, lastKeyDownAt: newest ?? t)
    }

    func testLedgerCleanWhenEveryKeySeen() {
        var l = KeyLedger()
        XCTAssertEqual(l.observe(reading(1000, at: 1.0)), .unavailable)      // chưa có mốc
        for i in 1...20 {
            XCTAssertEqual(l.observe(reading(1000 + UInt32(i), at: 1.0 + Double(i) * 0.1, code: UInt16(i))), .clean)
        }
    }

    func testLedgerMissedWhenKeyBypassesIME() {
        var l = KeyLedger()
        _ = l.observe(reading(10, at: 1.0))
        XCTAssertEqual(l.observe(reading(11, at: 1.1, code: 1)), .clean)
        // ⌘V (đi vòng bộ gõ) rồi một phím chữ
        XCTAssertEqual(l.observe(reading(13, at: 1.3, code: 2)), .missed(1))
        XCTAssertEqual(l.observe(reading(14, at: 1.4, code: 3)), .clean)
        // ba phím đi vòng
        XCTAssertEqual(l.observe(reading(18, at: 1.8, code: 4)), .missed(3))
        XCTAssertEqual(l.observe(reading(19, at: 1.9, code: 5)), .clean)
    }

    /// Phím kế tiếp đã bấm nhưng chưa tới bộ gõ: chưa biết, rồi rõ ở phím sau.
    func testLedgerUnknownWhileNextKeyInFlight() {
        var l = KeyLedger()
        _ = l.observe(reading(10, at: 1.0))
        XCTAssertEqual(l.observe(reading(12, at: 1.1, newest: 1.112, code: 1)), .unknown)
        XCTAssertEqual(l.observe(reading(12, at: 1.112, code: 2)), .clean)
    }

    /// Một phím đi vòng trong lúc có phím đang tới: chưa biết, rồi thành phím lỡ ở phím mới nhất.
    func testLedgerMissedResolvedAfterUnknown() {
        var l = KeyLedger()
        _ = l.observe(reading(10, at: 1.0))
        XCTAssertEqual(l.observe(reading(13, at: 1.1, newest: 1.15, code: 1)), .unknown)
        XCTAssertEqual(l.observe(reading(13, at: 1.15, code: 2)), .missed(1))
        XCTAssertEqual(l.observe(reading(14, at: 1.3, code: 3)), .clean)
    }

    func testLedgerRepeatsAreNotCounted() {
        var l = KeyLedger()
        _ = l.observe(reading(10, at: 1.0))
        XCTAssertEqual(l.observe(reading(11, at: 1.1, code: 1)), .clean)
        for i in 1...5 {   // hệ thống không đếm phím lặp
            XCTAssertEqual(l.observe(reading(11, at: 1.1 + Double(i) * 0.03, code: 1, repeat: true)), .clean)
        }
        XCTAssertEqual(l.observe(reading(12, at: 1.5, code: 2)), .clean)
    }

    func testLedgerDuplicateDeliveryCountedOnce() {
        var l = KeyLedger()
        _ = l.observe(reading(10, at: 1.0))
        XCTAssertEqual(l.observe(reading(11, at: 1.1, code: 7)), .clean)
        XCTAssertEqual(l.observe(reading(11, at: 1.1, code: 7)), .clean)
        XCTAssertEqual(l.observe(reading(12, at: 1.2, code: 8)), .clean)
    }

    func testLedgerCounterWraps() {
        var l = KeyLedger()
        _ = l.observe(reading(UInt32.max - 1, at: 1.0))
        XCTAssertEqual(l.observe(reading(UInt32.max, at: 1.1, code: 1)), .clean)
        XCTAssertEqual(l.observe(reading(0, at: 1.2, code: 2)), .clean)
        XCTAssertEqual(l.observe(reading(2, at: 1.3, code: 3)), .missed(1))
    }

    /// Bộ gõ thấy nhiều hơn hệ thống đếm (phím giả gửi thẳng vào tiến trình): không biết, lấy mốc lại.
    func testLedgerSeenMoreThanCountedRebases() {
        var l = KeyLedger()
        _ = l.observe(reading(10, at: 1.0))
        XCTAssertEqual(l.observe(reading(10, at: 1.1, code: 1)), .unavailable)
        XCTAssertEqual(l.observe(reading(11, at: 1.2, code: 2)), .unavailable)   // mốc mới
        XCTAssertEqual(l.observe(reading(12, at: 1.3, code: 3)), .clean)
    }

    /// Đồng hồ lệch (không bao giờ thấy "phím mới nhất"): không kẹt ở "chưa biết", sau vài phím thành phím lỡ.
    func testLedgerUnknownDoesNotLastForever() {
        var l = KeyLedger()
        var verdicts: [GapVerdict] = []
        for i in 0..<40 {
            let t = 1.0 + Double(i) * 0.1
            verdicts.append(l.observe(reading(100 + UInt32(i) + (i >= 25 ? 1 : 0), at: t, newest: t + 0.01, code: UInt16(i))))
        }
        // có mốc (sau 20 lần), sạch khi không lỡ phím, rồi phím lỡ ở i = 25 được báo trong vài phím, không có lần
        // "sạch" nào trước đó
        XCTAssertTrue(verdicts[20..<25].allSatisfy { $0 == .clean }, "\(verdicts)")
        guard let m = verdicts.firstIndex(of: .missed(1)) else { return XCTFail("\(verdicts)") }
        XCTAssertTrue(m > 25 && m < 34, "\(verdicts)")
        XCTAssertTrue(verdicts[25..<m].allSatisfy { $0 == .unknown }, "\(verdicts)")
        XCTAssertTrue(verdicts[(m + 1)...].allSatisfy { $0 == .clean }, "\(verdicts)")
    }

    /// Hai phím bấm gần như cùng lúc: phím đầu tưởng là mới nhất nên phím sau (đang tới) bị tính là lỡ. Phím đi vòng
    /// ngay sau đó không được bị "trừ lại" thành sạch.
    func testLedgerNearSimultaneousKeysNeverHideBypass() {
        var l = KeyLedger()
        _ = l.observe(reading(10, at: 1.0))
        XCTAssertEqual(l.observe(reading(11, at: 1.1, code: 1)), .clean)
        // phím 2 bấm ở 1.2, phím 3 ở 1.2005 (đang tới), phím đi vòng ở 1.201
        XCTAssertEqual(l.observe(reading(13, at: 1.2, newest: 1.2005, code: 2)), .missed(1))
        XCTAssertNotEqual(l.observe(reading(14, at: 1.2005, newest: 1.201, code: 3)), .clean)
    }

    /// Đồng hồ đã khớp (nhiều lần đọc sạch với phím mới nhất trùng phím này): dư đúng 1 mà có một phím mới hơn → phím
    /// dư là phím mới hơn đó, không phím nào đi vòng trước phím này.
    func testLedgerCleanBeforeOnceClocksAgree() {
        var l = KeyLedger()
        _ = l.observe(reading(10, at: 1.0))
        for i in 1...10 { XCTAssertEqual(l.observe(reading(10 + UInt32(i), at: 1.0 + Double(i) * 0.1, code: UInt16(i))), .clean) }
        XCTAssertEqual(l.observe(reading(22, at: 2.1, newest: 2.112, code: 20)), .cleanBefore)
        XCTAssertEqual(l.observe(reading(22, at: 2.112, code: 21)), .clean)
        // phím mới hơn hoá ra là phím đi vòng: phím sau biết ngay
        XCTAssertEqual(l.observe(reading(24, at: 2.3, newest: 2.31, code: 22)), .cleanBefore)
        XCTAssertEqual(l.observe(reading(25, at: 2.5, code: 23)), .missed(1))
        // dư 2 thì không đoán được
        XCTAssertEqual(l.observe(reading(28, at: 2.7, newest: 2.72, code: 24)), .unknown)
    }

    /// Mô phỏng: phím bấm theo nhịp ngẫu nhiên (có cả hai phím gần như cùng lúc), hệ thống đếm lúc bấm, phím qua bộ gõ
    /// tới theo thứ tự sau độ trễ ngẫu nhiên, ~6 % phím đi vòng; đồng hồ của sự kiện phím lệch đủ kiểu so với đồng hồ
    /// của hệ thống. Mỗi lần sổ báo sạch thì mọi phím đi vòng (từ lần bỏ từ trước) đều đã được báo; báo "sạch tới phím
    /// này" thì không có phím đi vòng nào bấm trước phím này.
    func testLedgerNeverReportsCleanAfterBypassFuzz() {
        for offset in [0, 0.0005, -0.0005, 0.005, -0.005, 0.04, -0.04] {
            var stats = [String: Int]()
            for seed in 0..<150 {
                var rng = SplitMix(state: UInt64(seed) &* 7919 &+ UInt64(abs(offset) * 1e5))
                var ledger = KeyLedger()
                var presses: [(t: Double, seen: Bool)] = []
                var t = 5.0
                for _ in 0..<250 {
                    let r = rng.unit()
                    t += r < 0.05 ? rng.range(0, 0.002) : r < 0.3 ? rng.range(0.005, 0.05) : rng.range(0.05, 0.3)
                    presses.append((t, rng.unit() >= 0.06))
                }
                let start = UInt32.max - 100   // cho bộ đếm quay vòng giữa chừng
                var delivered = 0.0
                var forgivenUpTo = -Double.infinity
                for (i, p) in presses.enumerated() where p.seen {
                    let latency = rng.unit() < 0.05 ? rng.range(0.02, 0.06) : rng.range(0.0003, 0.015)
                    delivered = max(p.t + latency, delivered + 0.0001)
                    let counted = presses.filter { $0.t <= delivered }
                    let r = KeyReading(keyDownCount: start &+ UInt32(counted.count), timestamp: p.t + offset,
                                       keyCode: UInt16(i % 50), isRepeat: false, lastKeyDownAt: counted.last!.t,
                                       readAt: delivered)
                    let v = ledger.observe(r)
                    stats["\(v)", default: 0] += 1
                    switch v {
                    case .clean:
                        let hidden = presses.filter { !$0.seen && $0.t > forgivenUpTo && $0.t <= delivered }
                        XCTAssertTrue(hidden.isEmpty, "lệch \(offset) seed \(seed) phím \(i): báo sạch, có \(hidden.count) phím đi vòng")
                    case .cleanBefore:
                        let hidden = presses.filter { !$0.seen && $0.t > forgivenUpTo && $0.t < p.t }
                        XCTAssertTrue(hidden.isEmpty, "lệch \(offset) seed \(seed) phím \(i): báo sạch tới phím này, có \(hidden.count) phím đi vòng trước nó")
                    case .missed, .unavailable:
                        forgivenUpTo = counted.last!.t
                    case .unknown:
                        break
                    }
                }
            }
            print("sổ phím (mô phỏng, đồng hồ lệch \(offset * 1000) ms):", stats.sorted { $0.key < $1.key })
        }
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

    /// Xoá lùi khi dòng đang khác từ của engine: theo đúng dòng.
    func testTerminalBackspaceWhileUnsure() {
        let p = Pty()
        p.type("tie")
        p.key("6", .unsure)
        p.backspace(gap: .none)        // shell xoá "6"
        XCTAssertEqual(p.text, "tie")
        p.type("61ng")
        XCTAssertEqual(p.text, "tiếng")
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

    /// Ghostty (`.deferred`): chưa chắc thì cũng không đặt marked text hay hẹn gửi gì.
    func testDeferredUnsureSendsNothing() {
        let p = Pty()
        p.style = .deferred
        p.type("tie")
        p.key("6", .unsure)
        XCTAssertEqual(p.text, "tie6")
    }
}
