import AppKit
import CoreGraphics
import VietEngine

/// Sổ phím và bộ đếm click, dùng chung cho mọi ô nhập liệu (WindowServer đếm chung mọi ứng dụng). Chỉ đọc bộ đếm
/// sự kiện của hệ thống: không event tap, không chặn hay tạo phím, không cần quyền gì.
final class KeyWatch {
    static let shared = KeyWatch()

    private var ledger = KeyLedger()
    private var pointer = PointerWatch()
    /// ⌘/⌃/⌥ được nhấn kể từ keyDown trước (theo flagsChanged bộ gõ nhận).
    private var modifierPressed = false
    /// Click được thấy ở lần đọc trước: có thể nó xảy ra sau phím đó (bấm phím rồi click ngay, trước lúc bộ gõ đọc bộ
    /// đếm), nên phím sau cũng coi là bị ngắt.
    private var pointerCarry = false
    /// Số lần đọc: lần kiểm tra hẹn giờ chỉ chạy nếu không có phím nào tới sau lần đọc đã hẹn nó.
    private var readings = 0
    private var checkTimer: DispatchSourceTimer?

    private init() {
        rebase()
    }

    private static func keyDownCount() -> UInt32 {
        CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
    }

    private static func secondsSinceKeyDown() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }

    /// Bộ gõ vừa gắn vào một ô nhập liệu, hoặc vừa có click: những gì xảy ra trước đó không còn liên quan.
    func rebase() {
        checkTimer?.cancel()
        checkTimer = nil
        ledger.rebase(keyDownCount: Self.keyDownCount())
        modifierPressed = false
        pointerCarry = false
        _ = pointer.changed(Self.pointerCount())
    }

    /// flagsChanged bộ gõ nhận. Phím tắt có ⌘/⌃/⌥ đi vòng bộ gõ (⌘V, Ctrl+A…): sổ phím tính là lỡ ngay, không chờ.
    func noteModifiers(_ flags: NSEvent.ModifierFlags) {
        if !flags.isDisjoint(with: [.command, .control, .option]) { modifierPressed = true }
    }

    /// Gọi với mọi keyDown bộ gõ nhận (cả ở chế độ E, ứng dụng loại trừ), trước khi xử lý phím: giữa phím trước
    /// mà bộ gõ thấy và phím này có phím / click nào bộ gõ không thấy không.
    func observe(_ event: NSEvent) -> KeyGap {
        readings += 1
        checkTimer?.cancel()
        checkTimer = nil
        let count = Self.keyDownCount()
        let modifier = modifierPressed
        modifierPressed = false
        let verdict = ledger.observe(KeyReading(keyDownCount: count, timestamp: event.timestamp, keyCode: event.keyCode,
                                                isRepeat: event.isARepeat, readAt: ProcessInfo.processInfo.systemUptime),
                                     modifierPressed: modifier)
        let clicked = pointer.changed(Self.pointerCount())
        let pointerMoved = clicked || pointerCarry
        // Click ngay trước lúc ứng dụng nhận phím này (thời điểm phím muộn hơn lúc bấm tới ~60 ms) có thể đã xảy ra sau
        // khi bấm phím: phím sau cũng coi là bị ngắt. Click từ trước đó thì không.
        pointerCarry = clicked && Self.secondsSinceClick() < ProcessInfo.processInfo.systemUptime - event.timestamp + 0.06
        scheduleCheck(step: 0, reading: readings, since: event.timestamp)
        #if DEBUG
        let delivery = (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000
        DebugLog.write("sổ phím: \(verdict)\(pointerMoved ? ", có click" : "")\(modifier ? ", có ⌘/⌃/⌥" : "") phím \(event.keyCode)\(event.isARepeat ? " (lặp)" : "") đếm \(count), tới sau \(String(format: "%.2f", delivery)) ms")
        #endif
        return pointerMoved ? .interrupted : verdict.gap(modifierPressed: modifier)
    }

    /// Sau mỗi phím, kiểm tra vài lần (`KeyLedger.checkDelays`) xem có phím đi vòng bộ gõ không (còn phím đã đếm mà bộ
    /// gõ chưa thấy, lúc không có phím nào được bấm). Phím mới tới thì bỏ các lần còn lại.
    private func scheduleCheck(step: Int, reading: Int, since keyTime: Double, retry: Double? = nil, waits: Int = 0) {
        guard step < KeyLedger.checkDelays.count else { return }
        let due = retry ?? keyTime + KeyLedger.checkDelays[step] - ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(0.01, due), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self, self.readings == reading else { return }
            self.checkTimer = nil
            let since = Self.secondsSinceKeyDown()           // trước bộ đếm
            let result = self.ledger.check(keyDownCount: Self.keyDownCount(), secondsSinceLastKeyDown: since)
            switch result {
            case .resolved:
                #if DEBUG
                DebugLog.write("sổ phím: kiểm tra (phím cuối cách \(Int(since * 1000)) ms): có phím đi vòng bộ gõ")
                #endif
            case .wait where waits < 2:
                // vừa có phím được bấm (ở đâu đó) mà bộ gõ chưa thấy: thử lại khi đã yên
                self.scheduleCheck(step: step, reading: reading, since: keyTime,
                                   retry: max(0.02, self.ledger.quietTime - since), waits: waits + 1)
            case .wait:
                self.scheduleCheck(step: step + 1, reading: reading, since: keyTime)
            case .none:
                self.scheduleCheck(step: step + 1, reading: reading, since: keyTime)
            }
        }
        checkTimer = timer
        timer.resume()
    }

    private static func secondsSinceClick() -> Double {
        [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }

    private static func pointerCount() -> UInt32 {
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types.reduce(0) { $0 &+ CGEventSource.counterForEventType(.combinedSessionState, eventType: $1) }
    }
}
