import AppKit
import CoreGraphics
import VietEngine

/// Sổ phím và bộ đếm click / cuộn, dùng chung cho mọi ô nhập liệu (WindowServer đếm chung mọi ứng dụng). Chỉ đọc
/// bộ đếm sự kiện của hệ thống: không event tap, không chặn hay tạo phím, không cần quyền gì.
final class KeyWatch {
    static let shared = KeyWatch()

    private var ledger = KeyLedger()
    private var pointer = PointerWatch()

    private init() {
        // Lần gọi đầu có thể lệch vài chục mili giây: gọi trước một lần.
        _ = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        _ = pointer.changed(Self.pointerCount())
    }

    /// Gọi với mọi keyDown bộ gõ nhận (cả ở chế độ E, ứng dụng loại trừ), trước khi xử lý phím: giữa phím trước
    /// mà bộ gõ thấy và phím này có phím / click / cuộn nào bộ gõ không thấy không (xem `GapVerdict`).
    func observe(_ event: NSEvent) -> (verdict: GapVerdict, pointerMoved: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        // Thời điểm phím mới nhất trước, rồi mới tới bộ đếm (xem `KeyReading.lastKeyDownAt`).
        let lastKeyDownAt = now - CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let count = CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
        let readAt = ProcessInfo.processInfo.systemUptime
        let verdict = ledger.observe(KeyReading(keyDownCount: count, timestamp: event.timestamp, keyCode: event.keyCode,
                                                isRepeat: event.isARepeat, lastKeyDownAt: lastKeyDownAt, readAt: readAt))
        let pointerMoved = pointer.changed(Self.pointerCount())
        #if DEBUG
        // IME Lab: độ lệch giữa phím mới nhất của hệ thống và phím này (≈ 0 khi không còn phím nào đang tới) để
        // kiểm tra đồng hồ của hai nguồn khớp nhau.
        let lead = (lastKeyDownAt - event.timestamp) * 1000
        let delivery = (readAt - event.timestamp) * 1000
        DebugLog.write("sổ phím: \(verdict)\(pointerMoved ? ", có click/cuộn" : "") phím \(event.keyCode)\(event.isARepeat ? " (lặp)" : "") lệch \(String(format: "%.3f", lead)) ms, tới sau \(String(format: "%.2f", delivery)) ms, đếm \(count)")
        #endif
        return (verdict, pointerMoved)
    }

    private static func pointerCount() -> UInt32 {
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        return types.reduce(0) { $0 &+ CGEventSource.counterForEventType(.combinedSessionState, eventType: $1) }
    }
}
