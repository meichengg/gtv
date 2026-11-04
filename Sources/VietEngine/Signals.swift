/// Tín hiệu cho chế độ terminal: phát hiện phím / click / cuộn mà bộ gõ không thấy giữa hai phím, và loại ô
/// nhập liệu. Phần thuần (không gọi hệ thống) để test trực tiếp; GTVInput đọc số liệu của WindowServer rồi đưa vào.

/// Giữa phím trước và phím này có gì bộ gõ không thấy không (xem `Session.handle(gap:)`).
public enum KeyGap: Equatable, Sendable {
    /// Bộ gõ thấy mọi phím từ phím trước tới phím này.
    case none
    /// Có thể có phím đi vòng bộ gõ (thường chỉ là phím kế tiếp đã bấm mà chưa tới): chưa được xoá gì cho tới khi
    /// chắc chắn.
    case unsure
    /// Có phím, click hay cuộn mà bộ gõ không thấy: con trỏ có thể đã đổi chỗ, bỏ từ đang theo dõi.
    case interrupted
}

/// Một lần đọc bộ đếm phím của WindowServer, lấy lúc bộ gõ nhận một keyDown.
public struct KeyReading: Equatable, Sendable {
    /// `CGEventSourceCounterForEventType(.combinedSessionState, .keyDown)`: số keyDown hệ thống đã thấy
    /// (không đếm phím lặp).
    public var keyDownCount: UInt32
    /// Thời điểm của chính phím này (`NSEvent.timestamp`, giây kể từ lúc khởi động).
    public var timestamp: Double
    public var keyCode: UInt16
    public var isRepeat: Bool
    /// Thời điểm của keyDown mới nhất hệ thống thấy: `now − CGEventSourceSecondsSinceLastEventType(.keyDown)`.
    /// Phải đọc TRƯỚC bộ đếm: một phím bấm xen giữa hai lần đọc khi đó chỉ có thể làm kết quả bớt chắc chắn.
    public var lastKeyDownAt: Double
    /// Lúc đọc xong bộ đếm (đồng hồ của tiến trình, `ProcessInfo.systemUptime`). Mặc định: `lastKeyDownAt`.
    public var readAt: Double

    public init(keyDownCount: UInt32, timestamp: Double, keyCode: UInt16, isRepeat: Bool, lastKeyDownAt: Double,
                readAt: Double? = nil) {
        self.keyDownCount = keyDownCount
        self.timestamp = timestamp
        self.keyCode = keyCode
        self.isRepeat = isRepeat
        self.lastKeyDownAt = lastKeyDownAt
        self.readAt = readAt ?? lastKeyDownAt
    }
}

public enum GapVerdict: Equatable, Sendable {
    /// Không phím nào đi vòng bộ gõ kể từ lần chứng minh trước (số hệ thống đếm đúng bằng số bộ gõ thấy).
    case clean
    /// Không phím nào đi vòng bộ gõ TRƯỚC phím này; có đúng một phím bấm sau phím này, hệ thống đã đếm mà bộ gõ chưa
    /// thấy (đang tới, hoặc đi vòng — nhưng ứng dụng chưa xử lý nó). Đủ để sửa chữ ngay trong lúc xử lý phím này;
    /// không đủ cho lần sửa gửi sau (`.deferred`), lúc đó phím kia có thể đã được xử lý.
    case cleanBefore
    /// Có n phím hệ thống thấy mà bộ gõ không thấy (phím này là phím mới nhất nên con số là chính xác).
    case missed(Int)
    /// Hệ thống đã thấy nhiều phím hơn nhưng có phím mới hơn phím này: có thể chỉ là phím kế tiếp đang tới.
    case unknown
    /// Chưa có mốc, hoặc số liệu không khớp (bộ gõ thấy nhiều hơn hệ thống đếm): không biết gì.
    case unavailable

    /// `editsLater`: lần sửa chữ được gửi sau khi phím này xử lý xong (`TerminalStyle.deferred`).
    public func gap(editsLater: Bool) -> KeyGap {
        switch self {
        case .clean: return .none
        case .cleanBefore: return editsLater ? .unsure : .none
        case .unknown: return .unsure
        case .missed, .unavailable: return .interrupted
        }
    }
}

/// Sổ phím: so số keyDown WindowServer đếm được với số keyDown bộ gõ nhận được. Không cần event tap (không
/// chặn phím, không xin quyền): phím đi vòng bộ gõ (⌘V, mũi tên / Ctrl+A ở iTerm2, Tab / Ctrl+A ở Muxy, mọi phím
/// đặc biệt ở Terminal.app, phím gõ ở ứng dụng khác…) làm số đếm vượt số bộ gõ thấy.
///
/// Không bao giờ báo `.clean` sai: `.clean` chỉ khi số dư đúng bằng 0, bất kể đồng hồ. Số dư dương chỉ được tính
/// là phím lỡ khi phím này là phím mới nhất hệ thống thấy (không còn phím nào đang trên đường tới); không thì
/// `.unknown`, và lần đọc sau sẽ rõ. Một bản sổ cho cả bộ gõ (WindowServer đếm chung mọi ứng dụng).
///
/// Phím đã tính là lỡ không bao giờ được "trừ lại": nếu hoá ra đó là phím đang tới (hai phím bấm gần như cùng lúc)
/// thì sổ lấy mốc lại, vì một phím đi vòng thật có thể bù đúng vào chỗ trừ đó.
public struct KeyLedger {
    /// Phím này là phím mới nhất nếu keyDown mới nhất của hệ thống không muộn hơn nó quá ngần này (giây).
    public var newestThreshold = 0.001
    /// `.unknown` kéo dài bấy nhiêu lần đọc, hoặc bấy nhiêu giây, thì coi là đã lỡ phím: không kẹt mãi khi đồng
    /// hồ của hai nguồn lệch nhau (không bao giờ thấy "phím mới nhất").
    public var maxUnknownRun = 8
    public var maxUnknownAge = 0.5
    /// Sau một lần tính phím lỡ, phím tới tiếp theo bấm trước lúc đọc sổ lần đó (hoặc, khi đồng hồ chưa được xác
    /// nhận là khớp, bấm cách phím trước không quá ngần này — giây) thì có thể chính là phím vừa bị tính là lỡ: lấy
    /// mốc lại.
    public var inFlightWindow = 0.05
    /// Chưa có mốc sau bấy nhiêu lần đọc liên tiếp thì lấy mốc ở lần đọc bất kỳ.
    public var maxUnavailableRun = 20
    /// Dư đúng 1 mà phím mới nhất của hệ thống muộn hơn phím này trong khoảng này (giây): phím dư chính là phím mới
    /// hơn đó (đã được đếm, vì thời điểm phím mới nhất được đọc trước bộ đếm) → `.cleanBefore`. Cận trên loại phím
    /// lặp (hệ thống không đếm phím lặp, mà phím lặp chỉ bắt đầu sau ≥ 150 ms). Chỉ dùng khi đồng hồ của sự kiện
    /// phím khớp đồng hồ của WindowServer (`alignedReadings`).
    public var newerThreshold = 0.004
    public var newerMaxLead = 0.1
    /// Số lần đọc "sạch" liên tiếp mà phím mới nhất của hệ thống trùng thời điểm phím này (đồng hồ khớp) cần có
    /// trước khi dùng `.cleanBefore`. Một lần đọc sạch mà lệch là đồng hồ không khớp: đếm lại từ đầu.
    public var requiredAlignment = 8

    private var lastRaw: UInt32?
    private var unwrapped: Int64 = 0
    private var seen: Int64 = 0
    private var base: Int64?
    private var missedExact: Int64 = 0
    /// Lần đọc trước đã tính phím lỡ: lúc đọc sổ lần đó.
    private var bookedAt: Double?
    private var last: (timestamp: Double, keyCode: UInt16)?
    private var unknownRun = 0
    private var firstUnknownAt = 0.0
    private var aligned = 0
    /// Số lần `.unavailable` liên tiếp (chẩn đoán).
    public private(set) var unavailableRun = 0

    public init() {}

    public mutating func observe(_ r: KeyReading) -> GapVerdict {
        if let lastRaw {
            unwrapped += Int64(r.keyDownCount &- lastRaw)   // bộ đếm 32 bit có thể quay vòng
        } else {
            unwrapped = Int64(r.keyDownCount)
        }
        lastRaw = r.keyDownCount
        // Cùng một sự kiện tới bộ gõ hai lần thì chỉ tính một.
        let duplicate = last.map { $0.timestamp == r.timestamp && $0.keyCode == r.keyCode } ?? false
        if !r.isRepeat && !duplicate { seen += 1 }
        let previous = last?.timestamp
        last = (r.timestamp, r.keyCode)
        let surplus = unwrapped - seen
        let lead = r.lastKeyDownAt - r.timestamp
        let newest = lead <= newestThreshold

        if let bookedAt {
            // Phím bấm trước lúc đọc sổ lần tính phím lỡ thì có thể đã được tính trong đó. Đồng hồ chưa được xác nhận
            // là khớp thì thêm điều kiện thời gian rộng (so hai phím với nhau, cùng một đồng hồ).
            self.bookedAt = nil
            let close = previous.map { r.timestamp - $0 <= inFlightWindow } ?? true
            if r.timestamp <= bookedAt || (aligned < requiredAlignment && close) {
                base = nil
            }
        }
        guard let base else {
            // Lấy mốc ở lần đọc "mới nhất" đầu tiên. Khoảng trước mốc thì không biết gì. Mãi không thấy phím mới
            // nhất (đồng hồ lệch) thì lấy mốc ở lần đọc bất kỳ: phím đang trên đường tới lúc đó, nếu có, chỉ làm sổ
            // thấy "bộ gõ thấy nhiều hơn" rồi lấy mốc lại — không bao giờ thành báo sạch sai.
            unknownRun = 0
            unavailableRun += 1
            guard newest || unavailableRun >= maxUnavailableRun else { return .unavailable }
            self.base = surplus
            missedExact = 0
            return .unavailable
        }
        let excess = surplus - base - missedExact
        if excess < 0 {
            // Bộ gõ thấy nhiều hơn hệ thống đếm: lấy mốc mới ở lần đọc mới nhất sau.
            self.base = nil
            unavailableRun += 1
            unknownRun = 0
            return .unavailable
        }
        unavailableRun = 0
        if excess == 0 {
            unknownRun = 0
            if !r.isRepeat { aligned = abs(lead) <= newestThreshold ? min(aligned + 1, 1000) : 0 }
            return .clean
        }
        if newest {
            return book(excess, surplus: surplus, base: base, at: r.readAt)
        }
        if excess == 1, aligned >= requiredAlignment, lead > newerThreshold, lead < newerMaxLead {
            return .cleanBefore      // sổ không đổi: phím sau sẽ cho biết phím dư là gì
        }
        if unknownRun == 0 { firstUnknownAt = r.timestamp }
        unknownRun += 1
        if unknownRun >= maxUnknownRun || r.timestamp - firstUnknownAt > maxUnknownAge {
            return book(excess, surplus: surplus, base: base, at: r.readAt)
        }
        return .unknown
    }

    private mutating func book(_ excess: Int64, surplus: Int64, base: Int64, at readAt: Double) -> GapVerdict {
        missedExact = surplus - base
        bookedAt = readAt
        unknownRun = 0
        return .missed(Int(excess))
    }
}

/// Click / cuộn kể từ phím trước (tổng bộ đếm `left/right/otherMouseDown` + `scrollWheel` của WindowServer).
/// Cuộn cũng tính: nvim (`mouse=nvi`) dời con trỏ khi cuộn, tmux (`mouse on`) vào chế độ copy.
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
