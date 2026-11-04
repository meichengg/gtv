/// Tín hiệu cho chế độ terminal: phát hiện phím / click / cuộn mà bộ gõ không thấy giữa hai phím, và loại ô
/// nhập liệu. Phần thuần (không gọi hệ thống) để test trực tiếp; GTVInput đọc số liệu của WindowServer rồi đưa vào.

/// Giữa phím trước và phím này có gì bộ gõ không thấy không (xem `Session.handle(gap:)`).
public enum KeyGap: Equatable, Sendable {
    /// Bộ gõ thấy mọi phím từ phím trước tới phím này.
    case none
    /// Có thể có phím đi vòng bộ gõ (thường chỉ là phím kế tiếp đã bấm mà chưa tới): chưa được xoá gì cho tới khi
    /// chắc chắn.
    case unsure
    /// Như `.unsure`, nhưng không có thêm phím nào chưa thấy kể từ phím trước: phím đi vòng (nếu có) đã được bấm trước
    /// phím trước. Terminal cho đọc màn hình (iTerm2, Terminal.app): màn hình đã in lại phím trước thì cũng đã in lại
    /// mọi thứ trước nó — khớp từ đang theo dõi là đủ chứng minh.
    case unsureSteady
    /// Có phím hay click bộ gõ không thấy: con trỏ có thể đã đổi chỗ, bỏ từ đang theo dõi.
    case interrupted
    /// Sổ phím không dùng được (hệ thống không đếm các phím bộ gõ nhận): coi như không có gì, nhưng không phải bằng
    /// chứng (giữ các kiểm tra khác, vd. đọc màn hình).
    case unverified
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

    public init(keyDownCount: UInt32, timestamp: Double, keyCode: UInt16, isRepeat: Bool, readAt: Double? = nil) {
        self.keyDownCount = keyDownCount
        self.timestamp = timestamp
        self.keyCode = keyCode
        self.isRepeat = isRepeat
        self.readAt = readAt ?? timestamp
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
    public var quietTime = 0.3
    /// Loạt "chưa biết" kéo dài quá bấy nhiêu giây (gõ liền tay, không có lúc nào ngừng đủ lâu) thì tính là lỡ.
    public var maxUnknownAge = 0.6
    /// `.unavailable` liên tiếp bấy nhiêu lần thì coi là hệ thống không đếm các phím bộ gõ nhận (`.uncounted`).
    public var uncountedAfter = 6
    /// Lần tính phím lỡ lúc đọc phím k có thể gồm cả phím bấm ngay sau k còn đang tới. Phím tới tiếp theo mà ứng dụng
    /// nhận trong khoảng này (giây) sau lần đọc đó thì có thể chính là phím ấy: không biết (bỏ từ), lấy mốc lại — không
    /// bao giờ "trừ lại", vì một phím đi vòng thật có thể bù đúng vào đó.
    public var inFlightWindow = 0.03

    private var lastRaw: UInt32?
    private var unwrapped: Int64 = 0
    private var seen: Int64 = 0
    private var base: Int64?
    private var missedExact: Int64 = 0
    private var last: (timestamp: Double, keyCode: UInt16)?
    /// Loạt phím "chưa biết" hiện tại: số phím của loạt, thời điểm phím đầu.
    private var run: (keys: Int, startedAt: Double)?
    /// Kết luận của lần kiểm tra hẹn giờ, báo ở phím kế tiếp.
    private var resolved: GapVerdict?
    /// Lúc đọc phím có lần tính phím lỡ gần nhất (xem `inFlightWindow`).
    private var bookedAt: Double?
    /// Bộ đếm và số dư (sau khi đã kết luận) ở lần đọc trước, cho `.unknownSteady`.
    private var previous: (count: Int64, excess: Int64)?
    /// Số lần `.unavailable` liên tiếp.
    public private(set) var unavailableRun = 0

    public init() {}

    /// Các lần kiểm tra hẹn giờ sau mỗi phím (giây kể từ phím đó): phím đi vòng bộ gõ lúc người dùng dừng tay (Tab tự
    /// hoàn thành, mũi tên…) được biết trước khi gõ tiếp.
    public static let checkDelays: [Double] = [0.32, 0.6, 1.2, 2.4, 4.8]

    /// Lấy mốc tại đây (bộ gõ vừa gắn vào ô nhập liệu, click…): những gì xảy ra trước đó không còn liên quan.
    public mutating func rebase(keyDownCount: UInt32) {
        let u = advance(keyDownCount)
        base = u - seen
        missedExact = 0
        run = nil
        resolved = nil
        bookedAt = nil
        previous = nil
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
        let resolution = resolved
        resolved = nil
        let surplus = u - seen
        if let booked = bookedAt {
            bookedAt = nil
            if r.timestamp - booked <= inFlightWindow { base = nil }
        }

        guard let base else {
            self.base = surplus
            return unavailable()
        }
        let excess = surplus - base - missedExact
        if excess < 0 {
            // Bộ gõ thấy nhiều hơn hệ thống đếm (phím đang tới bị tính là lỡ, phím giả không được đếm): mốc mới.
            self.base = surplus
            return unavailable()
        }
        unavailableRun = 0
        if modifierPressed && (excess > 0 || !keyHasModifier) {
            // Phím tắt có ⌘/⌃/⌥ kể từ phím trước (⌘V, Ctrl+A…): đi vòng bộ gõ hay không, con trỏ có thể đã đổi chỗ.
            return book(excess, surplus: surplus, base: base, at: r.readAt)
        }
        if excess > 0 && resolution != nil {
            // Lại có phím chưa thấy sau lần kiểm tra: tính hết là lỡ.
            return book(excess, surplus: surplus, base: base, at: r.readAt)
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
            if r.timestamp - current.startedAt > maxUnknownAge {
                return book(excess, surplus: surplus, base: base, at: r.readAt)
            }
            run = current
        } else {
            run = (1, r.timestamp)
        }
        // Không thêm phím nào chưa thấy kể từ phím trước: số dư như cũ và hệ thống chỉ đếm thêm đúng phím này.
        if let prior, prior.excess == excess, u - prior.count == 1 { return .unknownSteady }
        return .unknown
    }

    private mutating func book(_ excess: Int64, surplus: Int64, base: Int64, at readAt: Double) -> GapVerdict {
        missedExact = surplus - base
        run = nil
        if excess > 0 { bookedAt = readAt }
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
    public mutating func check(keyDownCount: UInt32, secondsSinceLastKeyDown: Double) -> CheckResult {
        guard let base, resolved == nil else { return .none }
        let u = advance(keyDownCount)
        let excess = u - seen - base - missedExact
        guard excess > 0 else { return .none }
        guard secondsSinceLastKeyDown >= quietTime else { return .wait }
        run = nil
        missedExact = u - seen - base
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

    private mutating func unavailable() -> GapVerdict {
        missedExact = 0
        run = nil
        bookedAt = nil
        unavailableRun += 1
        return unavailableRun >= uncountedAfter ? .uncounted : .unavailable
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
