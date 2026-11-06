/// Tín hiệu cho chế độ terminal: phát hiện phím / click / cuộn mà bộ gõ không thấy giữa hai phím, và loại ô
/// nhập liệu. Phần thuần (không gọi hệ thống) để test trực tiếp; GTVInput đọc số liệu của WindowServer rồi đưa vào.

/// Giữa phím trước và phím này có gì bộ gõ không thấy không (xem `Session.handle(gap:)`).
public enum KeyGap: Equatable, Sendable {
    /// Bộ gõ thấy mọi phím từ phím trước tới phím này.
    case none
    /// Có thể có phím đi vòng bộ gõ (thường chỉ là phím kế tiếp đã bấm mà chưa tới): chưa được xoá gì cho tới khi
    /// chắc chắn.
    case unsure
    /// Như `.unsure`, nhưng không có thêm phím nào chưa thấy kể từ phím trước, và phím này tới ngay: phím đi vòng (nếu
    /// có) đã được ứng dụng xử lý ngay sau phím trước. Terminal cho đọc màn hình (iTerm2, Terminal.app): khi đã qua thời
    /// gian shell in lại kể từ phím trước, màn hình cho thấy tác dụng của chúng (xem `Session.judgeSuspect`).
    case unsureSteady
    /// Có phím hay click bộ gõ không thấy: con trỏ có thể đã đổi chỗ, bỏ từ đang theo dõi.
    case interrupted
    /// Sổ phím không dùng được (hệ thống không đếm các phím bộ gõ nhận): coi như không có gì, nhưng không phải bằng
    /// chứng (giữ các kiểm tra khác, vd. đọc màn hình).
    case unverified
    /// Có phím đặc biệt (⌫, mũi tên, Tab…) hay click bộ gõ không nhận, được ứng dụng xử lý trước phím này (hoặc chưa
    /// chắc là trước hay sau — báo lại ở các phím sau cho tới khi chắc): từ đang theo dõi không còn đúng. Terminal cho đọc
    /// màn hình (iTerm2, Terminal.app) thì phím đi nguyên văn và màn hình quyết định sau (từ bắt đầu lại từ các phím
    /// nguyên văn, hay từ cũ vẫn đúng — xem `Session.judgeSuspect`); terminal khác thì bỏ từ.
    case bypassed

    /// Lần sửa đang chờ (kiểu `.deferred`) có thể đã lỗi thời: có phím tắt / phím đặc biệt / click bộ gõ không thấy.
    public var drops: Bool {
        switch self {
        case .interrupted, .bypassed: return true
        default: return false
        }
    }
}

/// Một lần đọc bộ đếm phím của WindowServer, lấy lúc bộ gõ nhận một keyDown.
public struct KeyReading: Equatable, Sendable {
    /// `CGEventSourceCounterForEventType(.combinedSessionState, .keyDown)`: số keyDown hệ thống đã thấy
    /// (không đếm phím lặp).
    public var keyDownCount: UInt32
    /// Thời điểm của phím này (`NSEvent.timestamp`, giây kể từ lúc khởi động — cùng đồng hồ với
    /// `ProcessInfo.systemUptime`). IME Lab: đây là lúc ứng dụng nhận phím, muộn hơn lúc bấm 1–60 ms.
    public var timestamp: Double
    public var keyCode: UInt16
    public var isRepeat: Bool
    /// Lúc đọc xong bộ đếm (`ProcessInfo.systemUptime`). Mặc định: `timestamp`.
    public var readAt: Double
    /// `CGEventSourceSecondsSinceLastEventType(.keyDown)`, đọc TRƯỚC bộ đếm: phím này vừa được bấm (ứng dụng đưa tới
    /// ngay) hay đã nằm chờ trong ứng dụng (ứng dụng bận). nil: không biết.
    public var sinceLastKeyDown: Double?

    public init(keyDownCount: UInt32, timestamp: Double, keyCode: UInt16, isRepeat: Bool, readAt: Double? = nil,
                sinceLastKeyDown: Double? = nil) {
        self.keyDownCount = keyDownCount
        self.timestamp = timestamp
        self.keyCode = keyCode
        self.isRepeat = isRepeat
        self.readAt = readAt ?? timestamp
        self.sinceLastKeyDown = sinceLastKeyDown
    }
}

public enum GapVerdict: Equatable, Sendable {
    /// Không phím nào đi vòng bộ gõ kể từ lần chắc chắn trước (số hệ thống đếm đúng bằng số bộ gõ thấy).
    case clean
    /// Hệ thống đã đếm nhiều phím hơn bộ gõ thấy: phím đang tới (gõ nhanh, ứng dụng bận) hay phím đi vòng — chưa biết.
    case unknown
    /// Như `.unknown`, nhưng số dư không đổi và hệ thống chỉ đếm thêm đúng phím này kể từ phím trước.
    case unknownSteady
    /// Có n phím đi vòng bộ gõ trước phím này (n = 0: có phím tắt ⌘/⌃/⌥, có thể đã tới bộ gõ).
    case missed(Int)
    /// Chưa có mốc, hoặc bộ gõ thấy nhiều phím hơn hệ thống đếm: không biết gì.
    case unavailable
    /// Hệ thống không đếm các phím bộ gõ nhận (phím do chương trình khác gõ: osascript, công cụ điều khiển từ xa…):
    /// sổ không dùng được, chỉ còn dựa vào phím bổ trợ (xem `gap`).
    case uncounted

    /// `modifierPressed`: ⌘/⌃/⌥ được nhấn kể từ phím trước (phím tắt đi vòng bộ gõ hay có bổ trợ: ⌘V, Ctrl+A…).
    public func gap(modifierPressed: Bool = false) -> KeyGap {
        switch self {
        case .clean: return .none
        case .unknown: return .unsure
        case .unknownSteady: return .unsureSteady
        case .missed, .unavailable: return .interrupted
        case .uncounted: return modifierPressed ? .interrupted : .unverified
        }
    }
}

/// Sổ phím: so số keyDown WindowServer đếm được với số keyDown bộ gõ nhận được. Không cần event tap (không
/// chặn phím, không xin quyền): phím đi vòng bộ gõ (⌘V, mũi tên / Ctrl+A ở iTerm2, Tab / Ctrl+A ở Muxy, mọi phím
/// đặc biệt ở Terminal.app, phím gõ ở ứng dụng khác…) làm số đếm vượt số bộ gõ thấy.
///
/// Số dư dương chưa cho biết là phím đi vòng hay chỉ là phím đang tới (bấm rồi mà ứng dụng chưa đưa tới bộ gõ — gõ
/// nhanh, ứng dụng bận): `.unknown`, phím đi nguyên văn. Phím đang tới thì sẽ tới và số dư về 0 (`.clean`); phím đi
/// vòng thì không bao giờ tới: khi đã `quietTime` không có phím nào được bấm mà số dư vẫn còn, lần kiểm tra hẹn giờ
/// (`check`, GTVInput hẹn vài lần sau mỗi phím) tính chúng là phím lỡ, báo ở phím kế tiếp. Có ⌘/⌃/⌥ (phím tắt) thì
/// tính là lỡ ngay.
///
/// Không bao giờ báo `.clean` khi có phím đi vòng chưa được báo: `.clean` chỉ khi số dư đúng bằng 0. Không dùng
/// thời điểm của sự kiện phím để đoán phím nào mới nhất (lệch so với lúc bấm). Một bản sổ cho cả bộ gõ.
public struct KeyLedger {
    /// Hẹn kiểm tra lại sau bấy nhiêu giây khi còn phím chưa thấy; chỉ kết luận khi đã bấy nhiêu giây không có phím
    /// nào được bấm (phím đang tới lúc đó, nếu có, phải tới trong khoảng này — trừ khi ứng dụng treo lâu hơn).
    public var quietTime = 0.15
    /// `.unavailable` liên tiếp bấy nhiêu lần thì coi là hệ thống không đếm các phím bộ gõ nhận (`.uncounted`).
    public var uncountedAfter = 6
    /// Mọi lần tính phím lỡ (lúc kiểm tra hẹn giờ, hay lúc đọc phím có phím tắt) chỉ là tạm: có thể nó gồm cả phím
    /// đang nằm chờ trong ứng dụng (treo) hay phím bấm gần như cùng lúc còn đang tới. Chỉ giữ nếu phím tới tiếp theo là
    /// phím duy nhất được bấm từ lần tính đó và tới ngay (phím mới nhất bấm cách đây không quá ngần này, giây); không thì
    /// huỷ, như chưa từng tính — các phím đó lại là "chưa thấy" (sổ "chưa biết": không DEL), một phím đi vòng thật không
    /// bao giờ bị "bù" mất. Đây là ngưỡng nhỏ nhất: ứng dụng giao phím chậm thì ngưỡng theo độ trễ đo được.
    public var promptWindow = 0.02
    /// Ngưỡng "tới ngay" lớn nhất học được. Ứng dụng giao phím chậm (iTerm2 / Terminal.app bận: 25–60 ms) thì với ngưỡng cố
    /// định không phím nào "tới ngay": lần tính phím lỡ không bao giờ được xác nhận, sổ kẹt ở "chưa biết" (mọi phím đi nguyên
    /// văn). Vẫn xa dưới các lần treo mà quy tắc trên chặn (phím nằm chờ: từ `quietTime` trở lên).
    public var promptWindowCap = 0.08
    /// Độ trễ giao phím gần đây (thời gian từ lúc bấm của phím chắc là phím mới nhất được bấm), mới nhất ở cuối.
    private var deliveries: [Double] = []
    /// p90 của `deliveries` + 10 ms (0: chưa đủ số liệu).
    private var learnedWindow = 0.0

    private var lastRaw: UInt32?
    private var unwrapped: Int64 = 0
    private var seen: Int64 = 0
    private var base: Int64?
    private var missedExact: Int64 = 0
    private var last: (timestamp: Double, keyCode: UInt16)?
    /// Loạt phím "chưa biết" hiện tại: số phím của loạt, lúc đọc phím đầu (đồng hồ của bộ gõ: phím dồn ra sau khi ứng
    /// dụng hết treo mang thời điểm cũ).
    private var run: (keys: Int, startedAt: Double)?
    /// Kết luận của lần kiểm tra hẹn giờ, báo ở phím kế tiếp.
    private var resolved: GapVerdict?
    /// Lần tính phím lỡ chưa được xác nhận (`promptWindow`): bộ đếm lúc đó, số phím đã tính, lúc tính (đồng hồ của bộ gõ).
    private var provisional: (count: Int64, excess: Int64, at: Double)?
    /// Bộ đếm và số dư (sau khi đã kết luận) ở lần đọc trước, cho `.unknownSteady`.
    private var previous: (count: Int64, excess: Int64)?
    /// Số lần `.unavailable` liên tiếp.
    public private(set) var unavailableRun = 0

    /// Chẩn đoán (test, IME Lab): bộ đếm, số phím đã thấy, mốc, số đã tính là lỡ, lần tính còn chờ xác nhận.
    public var debugState: String {
        "đếm \(unwrapped) thấy \(seen) mốc \(base.map(String.init) ?? "-") lỡ \(missedExact)"
            + (provisional.map { " tạm(\($0.count),\($0.excess))" } ?? "") + (resolved != nil ? " chờ-báo" : "")
            + (learnedWindow > promptWindow ? " ngưỡng \(Int(learnedWindow * 1000)) ms" : "")
    }

    public init() {}

    /// Các lần kiểm tra hẹn giờ sau mỗi phím (giây kể từ phím đó): phím đi vòng bộ gõ lúc người dùng dừng tay (Tab tự
    /// hoàn thành, mũi tên…) được biết trước khi gõ tiếp.
    public static let checkDelays: [Double] = [0.16, 0.3, 0.6, 1.2, 2.4]

    /// Bộ đếm và thời điểm sự kiện của WindowServer (`CGEventSourceSecondsSinceLastEventType`…) cập nhật ngay, hay chỉ được
    /// công bố mỗi `quantum` giây với thời điểm làm tròn xuống bội của nó, kể từ lúc khởi động (macOS 27: sổ phím không
    /// dùng được). `times`: thời điểm sự kiện cuối của vài loại sự kiện, mỗi cái tính với đồng hồ đọc ngay sau lần hỏi. Loại
    /// chưa từng xảy ra giữ thời điểm tạo phiên đăng nhập: nhiều loại trùng nhau (chỉ lệch vì lúc đọc đồng hồ, tới vài chục
    /// micro giây) — không phải bằng chứng gì. true: làm tròn; false: tức thời; nil: chưa đủ dữ liệu (vd. mới đăng nhập).
    public static func eventTimesQuantized(_ times: [Double], quantum: Double = 0.5) -> Bool? {
        func onGrid(_ t: Double) -> Bool {
            let off = abs(t.truncatingRemainder(dividingBy: quantum))
            return min(off, quantum - off) < 0.0002
        }
        let distinct = times.filter { t in times.filter { abs($0 - t) < 50e-6 }.count == 1 }
        let quantized = times.filter(onGrid).count
        let exact = distinct.filter { !onGrid($0) }.count
        if quantized >= 3 || (quantized >= 2 && exact == 0) { return true }
        if exact >= 2 && quantized <= 1 { return false }
        return nil
    }

    /// Lấy mốc tại đây (bộ gõ vừa gắn vào ô nhập liệu, click…): những gì xảy ra trước đó không còn liên quan.
    public mutating func rebase(keyDownCount: UInt32) {
        let u = advance(keyDownCount)
        base = u - seen
        missedExact = 0
        run = nil
        resolved = nil
        provisional = nil
        previous = nil
    }

    /// Vị trí (theo bộ đếm, cùng miền với `unwrapped(_:)`) của phím cuối cùng đã được xử lý xong theo sổ: mốc + số phím
    /// bộ gõ đã thấy + số phím đã tính là lỡ. Phím đặc biệt mà lúc thấy nó được nhấn bộ đếm là c thì đã được ứng dụng xử
    /// lý trước phím vừa đọc nếu c không vượt quá giá trị này (xem `KeyWatch`). nil: chưa có mốc.
    public var accounted: Int64? { base.map { $0 + seen + missedExact } }

    /// Giá trị bộ đếm `raw` (đọc trước lần đọc gần nhất) trong miền đã mở vòng.
    public func unwrapped(_ raw: UInt32) -> Int64 {
        guard let lastRaw else { return Int64(raw) }
        return unwrapped - Int64(lastRaw &- raw)
    }

    /// GTVInput thấy `n` phím đặc biệt được nhấn trước phím vừa đọc mà bộ gõ không nhận (`PressLog`): tính chúng là phím
    /// lỡ ngay (không cần chờ lúc yên tay), phần chưa được tính.
    /// Bộ gõ vừa gửi `n` phím giả sẽ không tới bộ gõ (chữ gõ giả của `SyntheticKeys`): bộ đếm hệ thống sẽ tính chúng — coi
    /// như đã thấy, không phải phím đi vòng.
    public mutating func expectUnseen(_ n: Int) {
        guard n > 0 else { return }
        seen += Int64(n)
    }

    public mutating func noteBypassed(_ n: Int) {
        guard let base, n > 0 else { return }
        let excess = unwrapped - seen - base - missedExact
        missedExact += min(Int64(n), max(0, excess))
        run = nil
        previous = (unwrapped, 0)
    }

    /// `modifierPressed`: ⌘/⌃/⌥ được nhấn kể từ phím trước. `keyHasModifier`: chính phím này có ⌘/⌃/⌥ (bộ gõ nhận được
    /// phím tắt, vd. Ctrl+E ở Ghostty — phím bổ trợ đó là của nó, không phải của một phím tắt đi vòng).
    public mutating func observe(_ r: KeyReading, modifierPressed: Bool = false, keyHasModifier: Bool = false) -> GapVerdict {
        let verdict = classify(r, modifierPressed: modifierPressed, keyHasModifier: keyHasModifier)
        switch verdict {
        case .unknown, .unknownSteady: previous = (unwrapped, unwrapped - seen - (base ?? 0) - missedExact)
        case .unavailable, .uncounted: previous = nil
        default: previous = (unwrapped, 0)
        }
        return verdict
    }

    private mutating func classify(_ r: KeyReading, modifierPressed: Bool, keyHasModifier: Bool) -> GapVerdict {
        let prior = previous
        let u = advance(r.keyDownCount)
        // Cùng một sự kiện tới bộ gõ hai lần thì chỉ tính một.
        let duplicate = last.map { $0.timestamp == r.timestamp && $0.keyCode == r.keyCode } ?? false
        // Phím tới theo nhịp gõ (không phải loạt phím dồn ra sau lúc ứng dụng treo, cách nhau dưới 1 ms).
        let paced = last.map { r.timestamp - $0.timestamp >= 0.02 } ?? true
        if !r.isRepeat && !duplicate { seen += 1 }
        last = (r.timestamp, r.keyCode)
        var resolution = resolved
        resolved = nil
        // Phím này vừa được bấm và ứng dụng đưa tới ngay (không có phím nào đang nằm chờ trong ứng dụng).
        let prompt = !r.isRepeat && !duplicate && (r.sinceLastKeyDown ?? 0) <= max(promptWindow, learnedWindow)
        // Lần tính bị huỷ bởi một phím không được đếm mà lại tới ngay (phím do chương trình gõ): phím đó "bù" đúng phím đi
        // vòng, số dư về 0 mà phím đi vòng chưa được báo — không được báo sạch.
        var cancelledByUncounted = false
        if let p = provisional {
            provisional = nil
            // Phím xác nhận phải là phím bấm sau lần tính: duy nhất được đếm thêm, tới ngay, và (nếu thời điểm sự kiện là
            // lúc bấm) có thời điểm sau lần tính — phím cũ nằm chờ trong ứng dụng thì không.
            if !(prompt && u - p.count == 1 && r.timestamp > p.at) {
                // Phím duy nhất bấm sau lần tính mà tới sau ngưỡng: thường là ứng dụng giao phím chậm — học độ trễ đó, không
                // thì sổ kẹt ở "chưa biết" mãi (phím nằm chờ lúc treo thì lâu hơn `promptWindowCap`, không tính).
                if !prompt, u - p.count == 1, r.timestamp > p.at, !r.isRepeat, !duplicate, let since = r.sinceLastKeyDown {
                    noteDelivery(since)
                }
                missedExact -= p.excess        // như chưa từng tính: các phím đó vẫn là "chưa thấy"
                resolution = nil
                cancelledByUncounted = prompt && u == p.count
            }
        }
        let surplus = u - seen

        guard let base else {
            self.base = surplus
            missedExact = 0
            return unavailable()
        }
        let excess = surplus - base - missedExact
        if excess < 0 {
            // Bộ gõ thấy nhiều phím hơn số phím chưa được tính (phím đã tính là lỡ, hay đã nằm trong mốc, mà thật ra đang
            // tới; phím do chương trình khác gõ không được đếm): sửa phần thừa — huỷ phần đã tính là lỡ trước, rồi tới mốc
            // (về số dư, như lấy mốc mới). Chỉ phím tới theo nhịp gõ mới tính vào chuỗi "hệ thống không đếm"
            // (`uncountedAfter`: phím do chương trình gõ, điều khiển từ xa): loạt phím dồn ra sau lúc ứng dụng treo (đã nằm
            // trong mốc) thì không.
            let deficit = -excess
            let unbook = min(deficit, missedExact)
            missedExact -= unbook
            self.base = base - (deficit - unbook)
            return unavailable(countsTowardUncounted: paced)
        }
        if cancelledByUncounted && excess == 0 {
            run = nil
            return .unavailable
        }
        unavailableRun = 0
        if modifierPressed && (excess > 0 || !keyHasModifier) {
            // Phím tắt có ⌘/⌃/⌥ kể từ phím trước (⌘V, Ctrl+A…): đi vòng bộ gõ hay không, con trỏ có thể đã đổi chỗ.
            if prompt { return book(excess, surplus: surplus, base: base, at: r.timestamp) }
            return .missed(Int(excess))        // bỏ từ; số dư để lần kiểm tra lúc yên tay kết luận
        }
        if excess > 0 && resolution != nil {
            // Lại có phím chưa thấy sau lần kiểm tra: tính hết là lỡ.
            if prompt { return book(excess, surplus: surplus, base: base, at: r.timestamp) }
            return .missed(Int(excess))
        }
        if let resolution {
            run = nil
            return resolution
        }
        if excess == 0 {
            run = nil
            // Không còn phím nào chưa thấy: phím này là phím mới nhất được bấm, thời gian từ lúc bấm là độ trễ giao phím.
            if !r.isRepeat && !duplicate, let since = r.sinceLastKeyDown { noteDelivery(since) }
            return .clean
        }
        if var current = run {
            current.keys += 1
            run = current
        } else {
            run = (1, r.readAt)
        }
        // Không thêm phím nào chưa thấy kể từ phím trước: số dư như cũ và hệ thống chỉ đếm thêm đúng phím này.
        // Phím tới ngay (không nằm chờ lúc ứng dụng treo): phím đi vòng đếm từ lần đọc trước đã được xử lý ngay sau phím trước.
        if let prior, prior.excess == excess, u - prior.count == 1, prompt { return .unknownSteady }
        return .unknown
    }

    private mutating func book(_ excess: Int64, surplus: Int64, base: Int64, at: Double) -> GapVerdict {
        missedExact = surplus - base
        run = nil
        if excess > 0 { provisional = (unwrapped, excess, at) }
        return .missed(Int(excess))
    }

    /// Một độ trễ giao phím đo được. Lâu hơn `promptWindowCap` thì không phải độ trễ giao phím mà là ứng dụng treo: bỏ qua.
    private mutating func noteDelivery(_ since: Double) {
        guard since >= 0, since <= promptWindowCap else { return }
        deliveries.append(since)
        if deliveries.count > 32 { deliveries.removeFirst() }
        guard deliveries.count >= 4 else { return }
        let sorted = deliveries.sorted()
        learnedWindow = min(promptWindowCap, sorted[min(sorted.count - 1, sorted.count * 9 / 10)] + 0.01)
    }

    public enum CheckResult: Equatable, Sendable {
        /// Không có gì cần kết luận.
        case none
        /// Vừa có phím được bấm: hẹn lại.
        case wait
        /// Đã tính các phím chưa thấy là phím lỡ; phím kế tiếp sẽ được báo.
        case resolved
    }

    /// Lần kiểm tra hẹn giờ (không có lần đọc nào xen giữa): còn phím đã đếm mà bộ gõ chưa thấy, và đã `quietTime`
    /// không có phím nào được bấm, thì đó là phím đi vòng bộ gõ.
    /// `secondsSinceLastKeyDown`: `CGEventSourceSecondsSinceLastEventType(.keyDown)`, đọc SAU bộ đếm: phím bấm xen giữa hai
    /// lần đọc thì không được đếm mà lại làm "chưa yên" — không bao giờ bị tính nhầm là phím lỡ.
    /// `now`: lúc kiểm tra (`ProcessInfo.systemUptime`, cùng đồng hồ với `NSEvent.timestamp`).
    public mutating func check(keyDownCount: UInt32, secondsSinceLastKeyDown: Double,
                               now: Double = -.infinity) -> CheckResult {
        // Còn một lần tính phím lỡ chờ phím sau xác nhận: không tính chồng lên (phím sau sẽ giữ hay huỷ nó).
        guard let base, resolved == nil, provisional == nil else { return .none }
        let u = advance(keyDownCount)
        let excess = u - seen - base - missedExact
        guard excess > 0 else { return .none }
        guard secondsSinceLastKeyDown >= quietTime else { return .wait }
        run = nil
        missedExact = u - seen - base
        provisional = (u, excess, now)
        // Không nói được phím lỡ được bấm trước hay sau phím "chưa biết" (phím bấm ngay sau một phím vẫn có thể được
        // đếm trước lúc bộ gõ đọc phím đó): chỉ báo là có phím lỡ.
        resolved = .missed(Int(excess))
        return .resolved
    }

    private mutating func advance(_ raw: UInt32) -> Int64 {
        if let lastRaw {
            unwrapped += Int64(raw &- lastRaw)   // bộ đếm 32 bit có thể quay vòng
        } else {
            unwrapped = Int64(raw)
        }
        lastRaw = raw
        return unwrapped
    }

    private mutating func unavailable(countsTowardUncounted: Bool = true) -> GapVerdict {
        run = nil
        provisional = nil
        if countsTowardUncounted { unavailableRun += 1 }
        return unavailableRun >= uncountedAfter ? .uncounted : .unavailable
    }
}

/// Terminal cho đọc màn hình (iTerm2, Terminal.app): shell in lại chữ bộ gõ gửi chậm bao lâu, đo từ chính các lần gõ. Màn
/// hình lệch trong khoảng `bound` kể từ lần gửi cuối có thể chỉ là chưa in kịp; quá khoảng đó thì màn hình đã in hết những
/// gì bộ gõ gửi (và mọi phím terminal tự xử lý trước đó), lệch là do thứ khác.
///
/// Chỉ học từ lần lệch về sau được màn hình cho thấy là chưa in kịp (lần đối chiếu kế tiếp khớp), không từ lần lệch vì
/// phím đi vòng: nếu không, mỗi lần ⌫ ở Terminal.app sẽ làm `bound` dài ra và che mất các lần ⌫ sau.
struct EchoClock {
    /// Chưa đo được gì.
    static let unknown = 0.15
    static let floor = 0.015
    static let cap = 0.35

    /// Thời gian in lại đo trực tiếp (`Session.probeEcho`: xem lại màn hình sau 4, 8, 16… 256 ms cho tới khi thấy chữ vừa
    /// gửi — mỗi số là cận trên của lần đó), mới nhất ở cuối.
    private var measured: [Double] = []
    /// Các lần lệch về sau được biết là chưa in kịp (giây kể từ lần gửi cuối: cận dưới của lần đó), mới nhất ở cuối.
    private var lagSamples: [Double] = []
    /// Lần lệch gần nhất, chờ lần đối chiếu sau để biết có phải chưa in kịp không.
    private var pendingLag: Double?
    /// Số lần lệch liền nhau dù đã lâu sau lần gửi cuối.
    private var strikes = 0

    var bound: Double {
        guard !measured.isEmpty || !lagSamples.isEmpty else { return Self.unknown }
        let fromMeasured = (measured.max() ?? 0) * 1.5 + 0.005
        let fromLags = lagSamples.max().map { $0 * 1.5 + 0.01 } ?? 0
        return min(Self.cap, max(Self.floor, fromMeasured, fromLags))
    }

    /// Số lần đo trực tiếp đang giữ.
    var measurements: Int { measured.count }

    /// Sổ phím sạch mà màn hình vẫn lệch lâu hơn chừng này kể từ lần gửi cuối thì không phải chưa in kịp (ứng dụng không in
    /// lại chữ gõ: vim ở normal mode, ô mật khẩu; hay con trỏ thật ở chỗ khác: ứng dụng toàn màn hình). Chưa đo được gì thì
    /// chờ tới `cap`: qua ssh in lại 200–300 ms mà gõ liền tay thì không có lần đối chiếu nào khớp để đo — chờ ít hơn thì phím
    /// nào cũng bỏ từ.
    var mismatchLimit: Double {
        measured.isEmpty && lagSamples.isEmpty ? Self.cap : max(Self.unknown, bound)
    }

    /// Màn hình có đang cho thấy chữ bộ gõ gửi trước con trỏ không. Không, khi ứng dụng toàn màn hình vẽ con trỏ riêng
    /// và để con trỏ thật của terminal ở chỗ khác (Claude Code, vim…): đối chiếu với màn hình lúc đó vô nghĩa — coi như
    /// terminal không cho đọc màn hình, cho tới khi màn hình lại khớp.
    var tracking: Bool { strikes < 2 }

    /// Một lần đo trực tiếp: chữ vừa gửi đã hiện sau `latency` giây.
    mutating func measured(_ latency: Double) {
        measured.append(latency)
        if measured.count > 16 { measured.removeFirst() }
    }

    /// Một lần đối chiếu màn hình với chữ bộ gõ đã gửi (lúc có phím): `visible` — màn hình cho thấy đúng như vậy; `after` —
    /// giây kể từ lần gửi cuối.
    mutating func observe(visible: Bool, after: Double) {
        guard visible else {
            pendingLag = max(pendingLag ?? 0, after)
            // Cùng ngưỡng với lúc bỏ từ (`Session.guardCursor`): lần lệch nào đủ lâu để bỏ từ cũng tính — không thì người gõ đều
            // tay ngay dưới ngưỡng cũ bị bỏ từ ở mọi phím mà màn hình vẫn được coi là theo dõi được.
            if after >= mismatchLimit { strikes += 1 }
            return
        }
        strikes = 0
        if let lag = pendingLag {
            lagSamples.append(lag)
            if lagSamples.count > 12 { lagSamples.removeFirst() }
            pendingLag = nil
        }
    }
}

/// Các lần nhấn phím đặc biệt (không phải ký tự) và nút chuột, đối chiếu với các phím bộ gõ nhận. GTVInput đọc trạng thái
/// phím / nút chuột / phím bổ trợ của WindowServer liên tục lúc cần (`LiveInput`): các trạng thái này cập nhật ngay cho mọi
/// tiến trình, không cần quyền — kể cả trên macOS 27, nơi bộ đếm và thời điểm sự kiện chỉ được công bố mỗi 0,5 s.
///
/// Phím đặc biệt được nhấn mà bộ gõ không nhận là phím terminal tự xử lý (⌫ / Tab / mũi tên ở Terminal.app, mũi tên ở
/// iTerm2, Tab ở Muxy…); nút chuột là click. Ứng dụng xử lý phím theo đúng thứ tự bấm: phím bấm trước một phím bộ gõ
/// nhận thì (nếu tới bộ gõ) phải tới trước nó.
public struct PressLog {
    public struct Press: Equatable, Sendable {
        /// Mã phím; nil: nút chuột.
        public var key: UInt16?
        /// Lần đọc đầu tiên thấy đang giữ (muộn hơn lúc nhấn không quá một chu kỳ đọc).
        public var at: Double
        /// Lần đọc ngay trước đó, lúc chưa giữ: lần nhấn xảy ra sau lúc này.
        public var after: Double
        /// Bộ đếm keyDown của WindowServer lúc đó (macOS 26: cập nhật ngay — sắp được thứ tự so với các phím bộ gõ nhận,
        /// xem `KeyWatch`; macOS 27 thì chỉ công bố mỗi 0,5 s, không dùng).
        public var count: UInt32 = 0

        public init(key: UInt16?, at: Double, after: Double = -.infinity, count: UInt32 = 0) {
            self.key = key
            self.at = at
            self.after = after
            self.count = count
        }
    }

    /// Một lần đổi phím bổ trợ: đọc thấy lúc `at`, lần đọc ngay trước đó (chưa đổi) lúc `after`; `keys`: số phím bổ trợ
    /// đổi trạng thái (nhả cả ⌘ lẫn ⇧ giữa hai lần đọc: 2).
    public struct FlagChange: Equatable, Sendable {
        public var after: Double
        public var at: Double
        public var keys: Int

        public init(after: Double, at: Double, keys: Int = 1) {
            self.after = after
            self.at = at
            self.keys = keys
        }
    }

    /// Lần nhấn chưa đối chiếu được với phím nào bộ gõ nhận (gồm mọi click).
    public private(set) var pending: [Press] = []
    /// Mọi lần nhấn gần đây (cho phím tắt đổi chế độ, thao tác của người dùng).
    public private(set) var history: [Press] = []
    /// Các lần đổi phím bổ trợ gần đây.
    public private(set) var flagChanges: [FlagChange] = []
    /// Các lần nhấn thêm phím bổ trợ (⌘ ⌃ ⌥ ⇧ fn, caps lock) gần đây — nhả thì không tính.
    public private(set) var flagPresses: [Double] = []
    /// Đọc liên tục (không hở quá `maxGap`) từ lúc này tới lần đọc cuối; nil: chưa đọc.
    public private(set) var coveredSince: Double?
    public private(set) var lastSample: Double?
    /// Hai lần đọc cách nhau quá bấy nhiêu giây thì coi là có khoảng hở (không biết gì xảy ra giữa chúng).
    public var maxGap = 0.05
    /// Giữ lại bấy nhiêu giây.
    public var keep = 8.0

    /// Phím bộ gõ đã nhận mà chưa thấy lần nhấn (phím tới bộ gõ trước lần đọc kế tiếp).
    private var received: [(key: UInt16, at: Double)] = []
    private var held: Set<UInt16> = []
    private var button = false
    private var flags: UInt64?

    /// Phím tắt đổi chế độ (macOS 27, xem `hotkeyTapClean`): thời điểm các sự kiện HID mới (bàn phím / chuột thật,
    /// `HIDIdleTime`) kể từ mốc lấy lúc nhấn tổ hợp (`startHID`).
    public private(set) var hidEvents: [Double] = []
    /// Lần đọc lúc nhấn tổ hợp; nil: không theo dõi.
    public private(set) var hidSince: Double?
    /// Mọi lần đọc từ `hidSince` tới giờ đều đọc cả HID (chưa hết hạn theo dõi).
    public private(set) var hidActive = false
    /// Hai sự kiện HID cách nhau dưới bấy nhiêu giây tính là một: sai số của lần đọc (`HIDIdleTime` tính với đồng hồ đọc trước
    /// và sau lời gọi kernel, lệch dưới 0,25 ms).
    public var hidDeadband = 0.002
    /// Sự kiện HID mới nhất lúc nhấn tổ hợp (mốc).
    private var hidBaseline: Double?
    private var lastHID: Double?
    /// Lần đổi phím bổ trợ đọc thấy cuối cùng trước lúc nhấn tổ hợp, khi đã đọc liên tục từ trước nó: chính lần nhấn đủ tổ hợp.
    private var armChange: FlagChange?
    /// WindowServer cập nhật trạng thái phím bổ trợ sau sự kiện HID của nó một chút: sự kiện có thể được đọc thấy trước lần
    /// đọc thấy phím bổ trợ đổi.
    private static let flagLag = 0.004

    public init() {}

    /// Đang giữ phím đặc biệt hay nút chuột nào (theo lần đọc cuối).
    public var anyHeld: Bool { !held.isEmpty || button }

    /// Phím bổ trợ theo lần đọc cuối.
    public var lastFlags: UInt64? { flags }

    /// Một lần đọc lúc `t`: các phím đặc biệt đang giữ, có nút chuột nào đang giữ không, phím bổ trợ, bộ đếm keyDown.
    public mutating func sample(at t: Double, held keys: Set<UInt16>, button pressed: Bool, flags f: UInt64,
                                keyDownCount: UInt32 = 0) {
        guard let last = lastSample, t - last <= maxGap else {
            // Sau khoảng hở: không biết phím / nút đang giữ được nhấn lúc nào (vd. chính cú click làm đổi ứng dụng) — không
            // tính là lần nhấn mới; ai cần biết khoảng hở thì hỏi `covered(since:)`.
            coveredSince = t
            lastSample = t
            held = keys
            button = pressed
            flags = f
            prune(before: t - keep)
            return
        }
        guard t >= last else { return }         // lần đọc cũ hơn lần đọc cuối: không có gì mới
        lastSample = t
        for k in keys.subtracting(held).sorted() {
            let press = Press(key: k, at: t, after: last, count: keyDownCount)
            history.append(press)
            if let i = received.firstIndex(where: { $0.key == k }) {
                received.remove(at: i)          // bộ gõ đã nhận phím này rồi
            } else {
                pending.append(press)
            }
        }
        held = keys
        if pressed && !button {
            let press = Press(key: nil, at: t, after: last, count: keyDownCount)
            history.append(press)
            pending.append(press)
        }
        button = pressed
        if let old = flags, old != f {
            flagChanges.append(FlagChange(after: last, at: t, keys: (old ^ f).nonzeroBitCount))
            if f & ~old != 0 { flagPresses.append(t) }
        }
        flags = f
        prune(before: t - keep)
    }

    /// Bộ gõ nhận keyDown `key` (lúc `at`, thời điểm sự kiện).
    /// Phím giả của bộ gõ (⌫ gửi bằng CGEventPost lúc `since`) vừa tới: không phải phím người dùng. Bỏ mọi lần nhấn phím đó đọc
    /// thấy từ lúc gửi (máy chậm thì trạng thái phím của phím giả cũng đọc được — để lại thì sổ phím coi là phím đi vòng bộ gõ).
    /// ⌫ thật bấm trước lúc gửi đã tới bộ gõ trước phím giả (cùng hàng đợi) nên không bị bỏ nhầm. Không ghi vào danh sách phím đã
    /// nhận (sẽ nuốt lần nhấn thật sau đó).
    public mutating func syntheticKeyArrived(_ key: UInt16, since: Double) {
        pending.removeAll { $0.key == key && $0.at >= since }
    }

    /// Có phím người dùng bấm mà chưa tới bộ gõ — đang nằm trong hàng đợi của ứng dụng, trước mọi phím gửi bây giờ: lần nhấn
    /// phím đặc biệt / click đang chờ (trong `maxAge` giây — phím không bao giờ tới bộ gõ, như phím tắt toàn hệ thống, thì thôi),
    /// phím đặc biệt đang giữ (lặp phím tạo thêm phím), phím bổ trợ nhấn sau phím vừa nhận lúc `since` (⌘V, ⌘A…).
    public func userKeysPending(now: Double, since: Double, maxAge: Double = 1) -> Bool {
        if pending.contains(where: { $0.at > now - maxAge }) { return true }
        if !held.isEmpty { return true }
        return flagPresses.contains { $0 > since }
    }

    public mutating func keyReceived(_ key: UInt16, at: Double, isRepeat: Bool) {
        if let i = pending.firstIndex(where: { $0.key == key }) {
            pending.remove(at: i)
        } else if !isRepeat, !held.contains(key) {
            // Đang giữ mà không có lần nhấn nào chờ (lần đọc sau khoảng hở không ghi lần nhấn): không ghi nhận — ghi thì lần nhấn
            // thật kế tiếp của phím này bị coi là đã nhận.
            received.append((key, at))
        }
        received.removeAll { $0.at < at - 1 }
    }

    /// Lấy ra (theo thứ tự) các lần nhấn đang chờ thoả `condition`.
    public mutating func take(where condition: (Press) -> Bool) -> [Press] {
        let taken = pending.filter(condition)
        pending.removeAll(where: condition)
        return taken
    }

    /// Đối chiếu các lần nhấn đang chờ với phím bộ gõ vừa nhận (thời điểm sự kiện `stamp`) khi không có bộ đếm tức thời để
    /// sắp thứ tự (macOS 27). `taken`: lấy ra các lần nhấn chắc là trước phím — đọc thấy sớm hơn `stamp` quá `maxDelivery`
    /// (độ trễ giao phím lớn nhất) — trừ khi phím nằm trong loạt phím dồn ra sau lúc ứng dụng treo (`burst`: có thể đã được
    /// bấm từ trước đó). `uncertain`: còn lần nhấn có thể trước phím. Lần nhấn mà một lần đọc từ `stamp` trở đi vẫn thấy chưa
    /// giữ thì chắc là sau phím (dù `stamp` là lúc bấm hay lúc ứng dụng nhận phím): để lại cho phím sau, không báo.
    /// `clicksOnly`: mọi phím đặc biệt đều qua bộ gõ (đường phím ⌫ giả) — lần nhấn phím chưa tới chỉ là phím sắp tới, không phải
    /// phím đi vòng; chỉ xét click.
    public mutating func order(keyAt stamp: Double, maxDelivery: Double, burst: Bool,
                               clicksOnly: Bool = false) -> (taken: [Press], uncertain: Bool) {
        let taken = burst ? [] : take { (!clicksOnly || $0.key == nil) && $0.at <= stamp - maxDelivery }
        return (taken, pending.contains { (!clicksOnly || $0.key == nil) && $0.after < stamp })
    }

    /// Bỏ mọi lần nhấn đang chờ và phím đã nhận chưa đối chiếu (đổi ô nhập liệu, click bộ gõ thấy…).
    public mutating func forget() {
        pending = []
        received = []
    }

    /// Có lần nhấn phím đặc biệt / nút chuột nào trong [from, to] không.
    public func pressed(from: Double, to: Double) -> Bool {
        history.contains { $0.at >= from && $0.at <= to }
    }

    /// Có lần đổi phím bổ trợ nào trong [from, to] không.
    public func flagsChanged(from: Double, to: Double) -> Bool {
        flagChanges.contains { $0.at >= from && $0.at <= to }
    }

    /// Có lần nhấn thêm phím bổ trợ nào trong [from, to] không.
    public func flagsPressed(from: Double, to: Double) -> Bool {
        flagPresses.contains { $0 >= from && $0 <= to }
    }

    /// Đã đọc liên tục từ trước `t` tới lần đọc cuối.
    public func covered(since t: Double) -> Bool {
        guard let from = coveredSince else { return false }
        return from <= t
    }

    private mutating func prune(before t: Double) {
        history.removeAll { $0.at < t }
        pending.removeAll { $0.at < t }
        flagChanges.removeAll { $0.at < t }
        flagPresses.removeAll { $0 < t }
    }

    // MARK: Phím tắt đổi chế độ (macOS 27)

    /// Vừa nhấn tổ hợp phím tắt đổi chế độ, ngay sau một lần đọc: bắt đầu theo dõi HID lại từ đầu. Lần `noteHID` kế tiếp là
    /// mốc: mọi sự kiện tới lúc đó (kể cả chính lần nhấn phím bổ trợ) không tính.
    public mutating func startHID() {
        hidEvents = []
        hidBaseline = nil
        lastHID = nil
        hidSince = lastSample
        hidActive = lastSample != nil
        armChange = flagChanges.last.flatMap { covered(since: $0.after) ? $0 : nil }
    }

    /// Một lần đọc `HIDIdleTime` lúc đang theo dõi: `event` là thời điểm sự kiện HID mới nhất.
    public mutating func noteHID(_ event: Double) {
        guard hidActive else { return }
        guard let last = lastHID else {
            hidBaseline = event
            lastHID = event
            return
        }
        if event > last + hidDeadband { hidEvents.append(event) }
        if event > last { lastHID = event }
    }

    /// Hết hạn theo dõi HID: sự kiện sau đó không còn thấy.
    public mutating func endHID() {
        hidActive = false
    }

    /// Tổ hợp phím tắt đổi chế độ nhấn lúc `armedAt` (lúc bộ gõ nhận) rồi nhả (lần đọc cuối) có phải là nhấn "trơn" không:
    /// không có phím, click hay di chuột nào xen vào (⌘⇧Z, ⌘⇧4, ⌘⇧←, ⌘⇧+click…).
    /// - Phím đặc biệt, nút chuột: lần nhấn đọc thấy từ lúc nhấn đủ tổ hợp.
    /// - Phím ký tự, di chuột: sự kiện HID không lần đổi phím bổ trợ nào giải thích được. Mỗi phím bổ trợ đổi trạng thái (nhả
    ///   ⌘, ⇧…) giải thích nhiều nhất một sự kiện, nằm giữa lần đọc trước lần đổi và lần đọc thấy nó: một lần nhả phím bổ trợ
    ///   không che được chữ Z của ⌘⇧Z bấm nhanh. Sự kiện mới nhất lúc nhấn tổ hợp (mốc) mà sau lần đọc thấy tổ hợp được nhấn:
    ///   có gì đó xen giữa lúc nhấn và lúc ứng dụng đưa tổ hợp tới bộ gõ (ứng dụng giao chậm).
    /// - Một sự kiện lẻ không quá 0,2 s sau phím bộ gõ nhận cuối (`lastKeyAt`) có thể chỉ là lần nhả phím đó (giữ phím chữ
    ///   lâu hơn thế hiếm; rộng hơn thì chữ Z của ⌘⇧Z gõ ngay sau một từ dễ lọt).
    /// Không đọc liên tục (cả HID) suốt lúc giữ (giữ quá hạn theo dõi, khoảng hở) thì không biết: không phải nhấn trơn.
    public func hotkeyTapClean(armedAt: Double, lastKeyAt: Double) -> Bool {
        guard hidActive, let since = hidSince, let now = lastSample, covered(since: since) else { return false }
        if pressed(from: min(armedAt, armChange?.at ?? armedAt), to: now) { return false }
        var foreign: [Double] = []
        if let change = armChange, let baseline = hidBaseline, baseline > change.at + 0.001 { foreign.append(baseline) }
        var changes = flagChanges.filter { $0.after >= since }
        for event in hidEvents {
            if let i = changes.firstIndex(where: { $0.keys > 0 && event > $0.after - Self.flagLag
                                                    && event <= $0.at + 0.0005 }) {
                changes[i].keys -= 1
            } else {
                foreign.append(event)
            }
        }
        return foreign.isEmpty || (foreign.count == 1 && foreign[0] <= lastKeyAt + 0.2)
    }
}

/// Click kể từ phím trước (tổng bộ đếm `left/right/otherMouseDown` của WindowServer): terminal không đưa click cho
/// bộ gõ (Ghostty dời con trỏ dòng lệnh khi click). Không tính cuộn: cuộn (cả cuộn quán tính, ở màn hình khác) quá
/// thường gặp, bỏ từ mỗi lần cuộn thì mất dấu.
public struct PointerWatch {
    private var last: UInt32?
    /// Click ngay trước phím trước mà `PressLog` không thấy: có thể đã xảy ra sau phím đó — báo cả ở phím này.
    private var carry = false
    /// macOS 27: bộ đếm và thời điểm click chỉ được công bố mỗi `quantum` giây, thời điểm làm tròn xuống. Click công bố
    /// sau lúc lấy mốc mà thời điểm không sau ô `quantum` chứa mốc — thường là chính click làm ô nhận focus — không tính.
    private var absorb: (upTo: Double, quantum: Double)?

    public init() {}

    /// Lấy mốc lúc `t` (bộ gõ vừa gắn vào ô nhập liệu, click bộ gõ thấy…). `quantum`: chu kỳ công bố (macOS 27).
    public mutating func rebase(_ total: UInt32, at t: Double = 0, quantum: Double? = nil) {
        last = total
        carry = false
        if let q = quantum, q > 0 {
            absorb = (upTo: (t / q).rounded(.down) * q, quantum: q)
        } else {
            absorb = nil
        }
    }

    /// Có click kể từ lần trước không. `lastClickAt`: thời điểm click cuối hệ thống công bố (chỉ hỏi khi bộ đếm đổi).
    public mutating func changed(_ total: UInt32, lastClickAt: @autoclosure () -> Double? = nil) -> Bool {
        defer { last = total }
        return differs(total, lastClickAt: lastClickAt())
    }

    /// Số click mới kể từ lần trước (0 nếu là click được bỏ qua khi lấy mốc), và ghi nhận.
    public mutating func newClicks(_ total: UInt32, lastClickAt: @autoclosure () -> Double? = nil) -> Int {
        defer { last = total }
        guard differs(total, lastClickAt: lastClickAt()), let last else { return 0 }
        return Int(total &- last)
    }

    /// Như `changed` nhưng không ghi nhận.
    public func differs(_ total: UInt32, lastClickAt: @autoclosure () -> Double? = nil) -> Bool {
        guard let last, last != total else { return false }
        if let absorb, let at = lastClickAt(), at < absorb.upTo + absorb.quantum / 2 { return false }
        return true
    }

    /// Phím bộ gõ vừa nhận (bộ đếm cập nhật ngay, macOS 26): có click kể từ phím trước không — kể cả click ngay trước phím
    /// trước (`recentClick`: trong độ trễ giao phím) mà có thể đã xảy ra sau nó. `sampled`: `PressLog` đã thấy nút chuột được
    /// nhấn — đã sắp thứ tự với phím này, hay còn chờ để báo ở phím sau: không cần báo thêm lần nữa ở phím sau.
    public mutating func moved(_ total: UInt32, recentClick: @autoclosure () -> Bool, sampled: Bool) -> Bool {
        let clicked = changed(total)
        let moved = clicked || carry
        carry = clicked && !sampled && recentClick()
        return moved
    }
}

/// Loại ô nhập liệu, theo các thuộc tính marked text ô đó nhận (`validAttributesForMarkedText`). Ô văn bản của
/// AppKit (NSTextView, NSTextField: thanh Find, command palette, hộp thoại đổi tên…) nhận cả thuộc tính của văn bản
/// nhiều đoạn; view terminal thì chỉ nhận vài thuộc tính hiển thị. IME Lab (macOS 26) đo được:
/// - Ghostty, Rex, Muxy: `[NSDictationHiliteMarkedText]`
/// - Terminal.app: `[NSUnderline, NSBackgroundColor, NSDictationHiliteMarkedText]`
/// - iTerm2: `[NSColor, NSBackgroundColor, NSUnderline, NSFont, NSDictationHiliteMarkedText]`
/// - ô văn bản (cả trong các app trên): `[NSFont, NSUnderline, NSColor, NSBackgroundColor, NSUnderlineColor,
///   NSMarkedClauseSegment, NSLanguage, NSTextInputReplacementRangeAttributeName, NSTextAlternatives, …]`
/// - lúc chưa có ô thật, InputMethodKit đưa một ô tạm có `IMKTextPlaceholder`.
public enum ClientKind: Equatable, Sendable {
    /// Ô văn bản: thay chữ được như ứng dụng thường.
    case textView
    /// View terminal: gõ kiểu terminal (`TerminalStyle`).
    case terminalView
    /// Ô tạm của InputMethodKit: hỏi lại khi có phím.
    case placeholder

    static let textMarkers: Set<String> = [
        "NSMarkedClauseSegment", "NSTextAlternatives", "NSTextInputReplacementRangeAttributeName", "NSGlyphInfo",
        "NSTextInsertionUndoable", "NSAttachment", "NSLanguage",
    ]

    public static func classify(_ attributes: [String]) -> ClientKind {
        if attributes.contains("IMKTextPlaceholder") { return .placeholder }
        return attributes.contains(where: textMarkers.contains) ? .textView : .terminalView
    }
}
