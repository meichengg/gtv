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
    /// Như `.interrupted`, nhưng phím / click đó đã đủ lâu (`settledFor` giây trước phím này): terminal cho đọc màn hình
    /// (iTerm2, Terminal.app) thì đọc lại từ đang nằm trước con trỏ để gõ tiếp, khi màn hình đã kịp in lại (vd. ⌫ ở
    /// Terminal.app rồi gõ lại dấu).
    case reread(settledFor: Double)

    /// Bỏ từ đang theo dõi (`.interrupted`, `.reread`).
    public var drops: Bool {
        switch self {
        case .interrupted, .reread: return true
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
    /// bao giờ bị "bù" mất.
    public var promptWindow = 0.02

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
    }

    public init() {}

    /// Các lần kiểm tra hẹn giờ sau mỗi phím (giây kể từ phím đó): phím đi vòng bộ gõ lúc người dùng dừng tay (Tab tự
    /// hoàn thành, mũi tên…) được biết trước khi gõ tiếp.
    public static let checkDelays: [Double] = [0.16, 0.3, 0.6, 1.2, 2.4]

    /// Lấy mốc tại đây (bộ gõ vừa gắn vào ô nhập liệu, click…): những gì xảy ra trước đó không còn liên quan.
    public mutating func rebase(keyDownCount: UInt32) {
        let u = advance(keyDownCount)
        base = u - seen
        missedExact = 0
        run = nil
        resolved = nil
        provisional = nil
        previous = nil
        unavailableRun = 0
    }

    /// GTVInput thấy `n` phím đặc biệt được nhấn trước phím vừa đọc mà bộ gõ không nhận (`PressLog`): tính chúng là phím
    /// lỡ ngay (không cần chờ lúc yên tay), phần chưa được tính.
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
        if !r.isRepeat && !duplicate { seen += 1 }
        last = (r.timestamp, r.keyCode)
        var resolution = resolved
        resolved = nil
        // Phím này vừa được bấm và ứng dụng đưa tới ngay (không có phím nào đang nằm chờ trong ứng dụng).
        let prompt = !r.isRepeat && !duplicate && (r.sinceLastKeyDown ?? 0) <= promptWindow
        // Lần tính bị huỷ bởi một phím không được đếm mà lại tới ngay (phím do chương trình gõ): phím đó "bù" đúng phím đi
        // vòng, số dư về 0 mà phím đi vòng chưa được báo — không được báo sạch.
        var cancelledByUncounted = false
        if let p = provisional {
            provisional = nil
            // Phím xác nhận phải là phím bấm sau lần tính: duy nhất được đếm thêm, tới ngay, và (nếu thời điểm sự kiện là
            // lúc bấm) có thời điểm sau lần tính — phím cũ nằm chờ trong ứng dụng thì không.
            if !(prompt && u - p.count == 1 && r.timestamp > p.at) {
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
            // (về số dư, như lấy mốc mới). Chỉ phím tới ngay mới tính vào chuỗi "hệ thống không đếm" (`uncountedAfter`):
            // phím dồn ra sau lúc ứng dụng treo (đã nằm trong mốc) thì không.
            let deficit = -excess
            let unbook = min(deficit, missedExact)
            missedExact -= unbook
            self.base = base - (deficit - unbook)
            return unavailable(countsTowardUncounted: prompt)
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
    /// Shell in lại ngay (máy local): vẫn chừa một khoảng cho lúc shell bận.
    static let floor = 0.03
    static let cap = 0.35

    /// Số lần màn hình đã in hết sau không quá 0,12 s kể từ lần gửi cuối.
    private var quickHits = 0
    /// Các lần lệch về sau được biết là chưa in kịp (giây kể từ lần gửi cuối), mới nhất ở cuối.
    private var lagSamples: [Double] = []
    /// Lần lệch gần nhất, chờ lần đối chiếu sau để biết có phải chưa in kịp không.
    private var pendingLag: Double?
    /// Số lần lệch liền nhau dù đã lâu sau lần gửi cuối.
    private var strikes = 0

    var bound: Double {
        if let worst = lagSamples.max() { return min(Self.cap, max(Self.floor, worst * 1.5 + 0.01)) }
        return quickHits >= 3 ? Self.floor : Self.unknown
    }

    /// Màn hình có đang cho thấy chữ bộ gõ gửi trước con trỏ không. Không, khi ứng dụng toàn màn hình vẽ con trỏ riêng
    /// và để con trỏ thật của terminal ở chỗ khác (Claude Code, vim…): đối chiếu với màn hình lúc đó vô nghĩa — coi như
    /// terminal không cho đọc màn hình, cho tới khi màn hình lại khớp.
    var tracking: Bool { strikes < 2 }

    /// Một lần đối chiếu màn hình với chữ bộ gõ đã gửi: `visible` — màn hình cho thấy đúng như vậy; `after` — giây kể
    /// từ lần gửi cuối.
    mutating func observe(visible: Bool, after: Double) {
        guard visible else {
            pendingLag = max(pendingLag ?? 0, after)
            if after >= 0.25 { strikes += 1 }
            return
        }
        strikes = 0
        if let lag = pendingLag {
            lagSamples.append(lag)
            if lagSamples.count > 12 { lagSamples.removeFirst() }
            pendingLag = nil
        }
        if after <= 0.12 { quickHits += 1 }
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
    }

    /// Lần nhấn chưa đối chiếu được với phím nào bộ gõ nhận (gồm mọi click).
    public private(set) var pending: [Press] = []
    /// Mọi lần nhấn gần đây (cho phím tắt đổi chế độ, thao tác của người dùng).
    public private(set) var history: [Press] = []
    /// Các lần đổi phím bổ trợ gần đây (lúc đọc).
    public private(set) var flagChanges: [Double] = []
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

    public init() {}

    /// Một lần đọc lúc `t`: các phím đặc biệt đang giữ, có nút chuột nào đang giữ không, phím bổ trợ.
    public mutating func sample(at t: Double, held keys: Set<UInt16>, button pressed: Bool, flags f: UInt64) {
        if let last = lastSample, t - last <= maxGap {} else {
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
        lastSample = t
        for k in keys.subtracting(held).sorted() {
            let press = Press(key: k, at: t)
            history.append(press)
            if let i = received.firstIndex(where: { $0.key == k }) {
                received.remove(at: i)          // bộ gõ đã nhận phím này rồi
            } else {
                pending.append(press)
            }
        }
        held = keys
        if pressed && !button {
            let press = Press(key: nil, at: t)
            history.append(press)
            pending.append(press)
        }
        button = pressed
        if let old = flags, old != f { flagChanges.append(t) }
        flags = f
        prune(before: t - keep)
    }

    /// Bộ gõ nhận keyDown `key` (lúc `at`, thời điểm sự kiện).
    public mutating func keyReceived(_ key: UInt16, at: Double, isRepeat: Bool) {
        if let i = pending.firstIndex(where: { $0.key == key }) {
            pending.remove(at: i)
        } else if !isRepeat {
            received.append((key, at))
        }
        received.removeAll { $0.at < at - 1 }
    }

    /// Các lần nhấn (phím bộ gõ không nhận, click) trước phím vừa tới lúc `at` — sớm hơn `at - lead`, để không tính nhầm
    /// phím bấm ngay sau phím này (ứng dụng xử lý sau nó) — lấy ra khỏi danh sách chờ.
    public mutating func takeMissed(before at: Double, lead: Double = 0.01) -> [Press] {
        let missed = pending.filter { $0.at <= at - lead }
        pending.removeAll { $0.at <= at - lead }
        return missed
    }

    /// Có lần nhấn phím đặc biệt / nút chuột nào trong [from, to] không.
    public func pressed(from: Double, to: Double) -> Bool {
        history.contains { $0.at >= from && $0.at <= to }
    }

    /// Có lần đổi phím bổ trợ nào trong [from, to] không.
    public func flagsChanged(from: Double, to: Double) -> Bool {
        flagChanges.contains { $0 >= from && $0 <= to }
    }

    /// Đã đọc liên tục từ trước `t` tới lần đọc cuối.
    public func covered(since t: Double) -> Bool {
        guard let from = coveredSince else { return false }
        return from <= t
    }

    private mutating func prune(before t: Double) {
        history.removeAll { $0.at < t }
        pending.removeAll { $0.at < t }
        flagChanges.removeAll { $0 < t }
    }
}

/// Click kể từ phím trước (tổng bộ đếm `left/right/otherMouseDown` của WindowServer): terminal không đưa click cho
/// bộ gõ (Ghostty dời con trỏ dòng lệnh khi click). Không tính cuộn: cuộn (cả cuộn quán tính, ở màn hình khác) quá
/// thường gặp, bỏ từ mỗi lần cuộn thì mất dấu.
public struct PointerWatch {
    private var last: UInt32?

    public init() {}

    public mutating func changed(_ total: UInt32) -> Bool {
        defer { last = total }
        return last.map { $0 != total } ?? false
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
