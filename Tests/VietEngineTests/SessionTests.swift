import XCTest
@testable import VietEngine

/// Ô nhập liệu giả, mô phỏng hành vi của ứng dụng thật.
private final class Field: TextClient {
    var units: [UInt16] = []          // văn bản (UTF-16)
    var sel = (location: 0, length: 0)
    var readable = true               // ứng dụng có cho đọc văn bản không
    var suggestions: [String] = []    // gợi ý tự động kiểu thanh địa chỉ
    /// Mô phỏng ứng dụng Qt (Telegram): chuỗi chèn vào trùng ký tự phím đang bấm thì bị coi là nhấn
    /// phím thường — bỏ qua vùng cần thay, chèn tại con trỏ.
    var qtStyle = false
    /// Mô phỏng ô nhập liệu trong trang web (Chrome, Electron): marked text bỏ qua vùng cần thay,
    /// đặt tại con trỏ; thay trực tiếp thì đúng.
    var chromiumStyle = false
    private var currentKey: Character?

    let session = Session()
    var options = EngineOptions()

    var text: String { String(decoding: units, as: UTF16.self) }

    // MARK: TextClient
    func selectedRange() -> (location: Int, length: Int)? { sel }
    func text(location: Int, length: Int) -> String? {
        guard readable, location >= 0, location + length <= units.count else { return nil }
        return String(decoding: units[location..<location + length], as: UTF16.self)
    }
    func replaceText(location: Int, length: Int, with s: String) {
        if qtStyle, let k = currentKey, s == String(k) || s.isEmpty {
            // Qt: chuỗi trùng phím đang bấm -> coi như phím thường; chuỗi rỗng -> bị bỏ qua.
            if !s.isEmpty { insertAtCursor(s) }
            return
        }
        units.replaceSubrange(location..<location + length, with: Array(s.utf16))
        sel = (location + s.utf16.count, 0)
        autocomplete()
    }
    func setMarkedText(_ text: String) {}
    func replaceViaMarkedText(location: Int, length: Int, with s: String) {
        if chromiumStyle { insertAtCursor(s); return }
        // Qt và ứng dụng Cocoa: marked text thay đúng vùng, sau đó chốt.
        units.replaceSubrange(location..<location + length, with: Array(s.utf16))
        sel = (location + s.utf16.count, 0)
    }
    func insertText(_ text: String) { insertAtCursor(text) }

    private func insertAtCursor(_ text: String) {
        units.replaceSubrange(sel.location..<sel.location + sel.length, with: Array(text.utf16))
        sel = (sel.location + text.utf16.count, 0)
        autocomplete()
    }

    // MARK: Thao tác của người dùng
    func type(_ keys: String) {
        for k in keys {
            currentKey = k
            if !session.handle(.char(k), self, options: options, forceMarked: false, qtApp: qtStyle) {
                insertText(String(k))        // ứng dụng tự xử lý phím
            }
            currentKey = nil
        }
    }

    func backspace() {
        if session.handle(.backspace, self, options: options, forceMarked: false, qtApp: qtStyle) { return }
        if sel.length > 0 {
            units.removeSubrange(sel.location..<sel.location + sel.length)
        } else if sel.location > 0 {
            let before = String(decoding: units[0..<sel.location], as: UTF16.self)
            let n = before.last!.utf16.count
            units.removeSubrange(sel.location - n..<sel.location)
            sel.location -= n
        }
        sel.length = 0
    }

    /// Cmd+A — ứng dụng tự xử lý, bộ gõ không thấy.
    func selectAll() { sel = (0, units.count) }

    private func autocomplete() {
        let t = text
        guard sel.location == units.count, !t.isEmpty,
              let s = suggestions.first(where: { $0.hasPrefix(t) && $0 != t }) else { return }
        let rest = Array(s.utf16.dropFirst(units.count))
        units += rest
        sel.length = rest.count
    }
}

/// Ô có bộ đệm chậm như Chromium / Electron: bộ gõ đọc vị trí con trỏ và chữ từ một bản chụp chỉ cập nhật khi `flush()`
/// (trang báo lại), còn phím và lần sửa của bộ gõ áp dụng ngay, theo thứ tự, lên văn bản thật. `backspaceAlways`: ⌫ luôn
/// chạy cả khi bộ gõ trả lời đã xử lý (Chromium).
private final class LaggyField: TextClient {
    var real: [UInt16] = []
    var caret = 0
    private var snap: [UInt16] = []
    private var snapCaret = 0
    var autoFlush = true
    var backspaceAlways = false
    let session = Session()
    var options = EngineOptions()

    var text: String { String(decoding: real, as: UTF16.self) }

    func flush() { snap = real; snapCaret = caret }

    func selectedRange() -> (location: Int, length: Int)? { (snapCaret, 0) }
    func text(location: Int, length: Int) -> String? {
        guard location >= 0, location + length <= snap.count else { return nil }
        return String(decoding: snap[location..<location + length], as: UTF16.self)
    }
    func replaceText(location: Int, length: Int, with s: String) {
        let end = min(location + length, real.count)
        guard location >= 0, location <= end else { return }
        real.replaceSubrange(location..<end, with: Array(s.utf16))
        caret = location + s.utf16.count
    }
    func setMarkedText(_ text: String) { XCTFail("gõ trực tiếp") }
    func replaceViaMarkedText(location: Int, length: Int, with text: String) { XCTFail("không phải Qt") }
    func insertText(_ s: String) {
        real.insert(contentsOf: Array(s.utf16), at: caret)
        caret += s.utf16.count
    }

    func type(_ keys: String) {
        for k in keys {
            if !session.handle(.char(k), self, options: options, forceMarked: false) { insertText(String(k)) }
            if autoFlush { flush() }
        }
    }

    func backspace() {
        let handled = session.handle(.backspace, self, options: options, forceMarked: false)
        if (!handled || backspaceAlways), caret > 0 {
            real.remove(at: caret - 1)
            caret -= 1
        }
        if autoFlush { flush() }
    }
}

/// Ô kiểu Qt 5: luôn báo con trỏ ở 0, không cho đọc chữ, bỏ qua vùng cần thay (chèn tại con trỏ).
private final class Qt5Field: TextClient {
    var units: [UInt16] = []
    let session = Session()
    var options = EngineOptions()
    var text: String { String(decoding: units, as: UTF16.self) }

    func selectedRange() -> (location: Int, length: Int)? { (0, 0) }
    func text(location: Int, length: Int) -> String? { nil }
    func replaceText(location: Int, length: Int, with s: String) { units += Array(s.utf16) }
    func setMarkedText(_ text: String) {}
    func replaceViaMarkedText(location: Int, length: Int, with s: String) { units += Array(s.utf16) }
    func insertText(_ s: String) { units += Array(s.utf16) }

    func type(_ keys: String) {
        for k in keys where !session.handle(.char(k), self, options: options, forceMarked: false) {
            units += Array(String(k).utf16)
        }
    }
}

/// Ô chỉ sửa được bằng phím ⌫ giả (Java AWT, Qt 5, GTK…): bỏ qua vùng thay; mọi phím (thật và giả) vào một hàng đợi và ứng dụng
/// xử lý theo thứ tự đó. Phím giả bộ gõ gửi lúc xử lý một phím được xếp sau những phím thật đã nằm sẵn trong hàng đợi (ứng dụng
/// chậm: `backlog` phím). ⌫ giả đi qua bộ gõ (báo cho Session), chữ giả thì không. `blind`: con trỏ luôn báo {0,0}.
private final class SyntheticField: TextClient {
    enum Event { case key(Character), fakeBackspace, fakeText(String), click(Int), paste(String), unseenClick(Int) }
    var units: [UInt16] = []
    var caret = 0
    var blind: Bool
    var allowPost = true
    var queue: [Event] = []
    var backlog = 0
    var commitAfterEveryKey = false
    var synthetic = true
    let session = Session()
    var options = EngineOptions()
    init(blind: Bool = false) { self.blind = blind }

    var text: String { String(decoding: units, as: UTF16.self) }

    /// SDL: con trỏ báo đứng yên ở giá trị này (vùng chọn của lần setMarkedText cũ).
    var frozenCaret: Int?
    func selectedRange() -> (location: Int, length: Int)? {
        if let f = frozenCaret { return (f, 0) }
        return blind ? (0, 0) : (caret, 0)
    }
    func text(location: Int, length: Int) -> String? { nil }
    func replaceText(location: Int, length: Int, with t: String) { insertText(t) }      // bỏ qua vùng thay
    func setMarkedText(_ t: String) { XCTFail("phím ⌫ giả không dùng marked text") }
    func replaceViaMarkedText(location: Int, length: Int, with t: String) { insertText(t) }
    func insertText(_ t: String) { units.insert(contentsOf: Array(t.utf16), at: caret); caret += t.utf16.count }
    func postKeys(deleting: Int, inserting: String) -> Bool { postKeys(prefix: "", deleting: deleting, inserting: inserting) }
    func postKeys(prefix: String, deleting: Int, inserting: String) -> Bool {
        guard allowPost else { return false }
        if !prefix.isEmpty { queue.append(.fakeText(prefix)) }
        for _ in 0..<deleting { queue.append(.fakeBackspace) }
        if !inserting.isEmpty { queue.append(.fakeText(inserting)) }
        return true
    }
    var canPostKeys: Bool { allowPost }
    /// Phím đặc biệt của người dùng (⌫, ⏎) còn trong hàng đợi, chưa tới bộ gõ (GTVInput thấy qua trạng thái phím của hệ thống).
    /// Vừa có click / ⌘V (bộ gõ không thấy): GTVInput còn thấy phím bổ trợ / nút chuột tới khi phím kế tiếp tới (sổ phím báo
    /// `.interrupted` ở phím đó).
    var interruptPending = false
    var keysQueued: Bool {
        interruptPending || queue.contains {
            switch $0 {
            case let .key(k): return k == "⌫" || k == "\n"
            case .click, .paste, .unseenClick: return true    // click / ⌘V: GTVInput thấy nút chuột, phím bổ trợ
            default: return false
            }
        }
    }
    var timers: [() -> Void] = []
    func schedule(after delay: Double, _ work: @escaping () -> Void) { timers.append(work) }
    /// Thời gian trôi: chạy các timer đã hẹn.
    func runTimers() {
        let due = timers
        timers = []
        due.forEach { $0() }
    }

    func deleteBack() {
        guard caret > 0 else { return }
        let s = String(decoding: units[..<caret], as: UTF16.self)
        let n = s.last.map { String($0).utf16.count } ?? 1
        units.removeSubrange((caret - n)..<caret)
        caret -= n
    }
    private func processOne() {
        switch queue.removeFirst() {
        case let .key(k):
            let gap: KeyGap = interruptPending ? .interrupted : .none
            interruptPending = false
            let handled = session.handle(k == "⌫" ? .backspace : .char(k), self, options: options, forceMarked: false,
                                         gap: gap, synthetic: synthetic)
            if commitAfterEveryKey { session.commitRequested(self) }
            if !handled { if k == "⌫" { deleteBack() } else { insertText(String(k)) } }
        case .fakeBackspace:
            deleteBack()
            session.syntheticBackspaceArrived()
        case let .fakeText(t):
            insertText(t)
        case let .click(loc):                                 // InputController: click → commit + fieldChanged
            caret = loc
            session.commit(self)
            session.fieldChanged()
            interruptPending = true
        case let .paste(t):                                   // ⌘V đi thẳng vào menu, không qua bộ gõ
            insertText(t)
            interruptPending = true
        case let .unseenClick(loc):                           // Java / Qt: bộ gõ không thấy click
            caret = loc
            interruptPending = true
        }
    }
    func type(_ keys: String) {
        for k in keys {
            queue.append(.key(k))
            while queue.count > backlog { processOne(); runTimers() }
        }
        while !queue.isEmpty { processOne(); runTimers() }
        for _ in 0..<5 { runTimers() }
    }
    /// Các sự kiện xếp hàng rồi ứng dụng xử lý hết.
    func drain() {
        while !queue.isEmpty { processOne(); runTimers() }
        for _ in 0..<5 { runTimers() }
    }
    /// Ô đã có sẵn chữ bộ gõ không theo dõi.
    func prefill(_ t: String) {
        units = Array(t.utf16)
        caret = units.count
    }
}

/// Ô web của Chromium (render_widget_host_view_cocoa.mm), theo đúng cách bộ đệm phía trình duyệt cập nhật:
/// - văn bản thật nằm ở trang; trang báo lại (con trỏ + chữ) cho bộ đệm sau `lag` phím;
/// - lần sửa của bộ gõ có vùng thay (ImeCommitText) chỉ tới trang, không vào bộ đệm;
/// - chèn không vùng thay (phím đi thẳng, insertText) làm bộ đệm đoán: con trỏ = vị trí trang báo lần cuối + độ dài, chữ chèn
///   vào chỗ đó (không cộng dồn);
/// - ⌫ của trang không vào bộ đệm; mọi thứ tới trang theo đúng thứ tự.
private final class ChromiumField: TextClient {
    var units: [UInt16] = []
    var caret = 0
    var cUnits: [UInt16] = []
    var cCaret = 0
    var base = 0
    var lag = 0
    var snapshots: [(units: [UInt16], caret: Int, due: Int)] = []
    var now = 0.0
    var timers: [(at: Double, work: () -> Void)] = []
    var stepMS = 80.0
    let session = Session()
    var options = EngineOptions()

    var text: String { String(decoding: units, as: UTF16.self) }

    func selectedRange() -> (location: Int, length: Int)? { (cCaret, 0) }
    func text(location: Int, length: Int) -> String? {
        let lo = max(0, location), hi = min(cUnits.count, location + length)
        guard lo < hi else { return length == 0 ? "" : nil }
        return String(decoding: cUnits[lo..<hi], as: UTF16.self)
    }
    func replaceText(location: Int, length: Int, with t: String) {
        guard location <= units.count else { return }
        let lo = location, hi = min(location + length, units.count)
        units.replaceSubrange(lo..<hi, with: Array(t.utf16))
        if caret >= hi { caret += t.utf16.count - (hi - lo) } else if caret > lo { caret = lo + t.utf16.count }
        snapshot()
    }
    func insertText(_ t: String) {
        units.insert(contentsOf: Array(t.utf16), at: caret)
        caret += t.utf16.count
        cUnits.insert(contentsOf: Array(t.utf16), at: min(base, cUnits.count))
        cCaret = base + t.utf16.count
        snapshot()
    }
    func setMarkedText(_ t: String) { XCTFail("ô web không dùng marked text") }
    func replaceViaMarkedText(location: Int, length: Int, with t: String) { XCTFail("ô web không dùng marked text") }
    func schedule(after delay: Double, _ work: @escaping () -> Void) { timers.append((now + delay, work)) }
    func currentTime() -> Double { now }

    func snapshot() { snapshots.append((units, caret, lag)) }
    func report(_ s: (units: [UInt16], caret: Int, due: Int)) { cUnits = s.units; cCaret = s.caret; base = s.caret }

    /// Thời gian trôi tới phím kế tiếp: trang báo những gì tới hạn, timer tới hạn chạy.
    func tick(_ ms: Double) {
        var steps = Int(ms / 10)
        while steps > 0 {
            steps -= 1
            now += 0.01
            let due = timers.filter { $0.at <= now + 1e-9 }
            timers.removeAll { $0.at <= now + 1e-9 }
            due.forEach { $0.work() }
        }
        let ready = snapshots.filter { $0.due <= 0 }
        snapshots = snapshots.filter { $0.due > 0 }.map { ($0.units, $0.caret, $0.due - 1) }
        ready.forEach(report)
    }

    /// Trang tự đổi chữ ngay khi xử lý phím (Notion "->" → "→", "- " ở đầu dòng → dấu đầu dòng): chữ trước con trỏ kết thúc
    /// bằng `from` thì thay bằng `to`, báo như mọi lần xử lý phím.
    var autoReplace: [(from: String, to: String)] = []

    func press(_ k: Character) {
        tick(stepMS)
        if !session.handle(.char(k), self, options: options, forceMarked: false, web: true) {
            insertText(String(k))
            for r in autoReplace where String(decoding: units[..<caret], as: UTF16.self).hasSuffix(r.from) {
                let n = r.from.utf16.count
                units.replaceSubrange((caret - n)..<caret, with: Array(r.to.utf16))
                caret += r.to.utf16.count - n
                snapshot()
                break
            }
        }
    }
    /// ⌫ của Blink xoá cả cụm (emoji ghép bằng ZWJ…); không bật thì xoá một đơn vị UTF-16.
    var graphemeBackspace = false
    /// `gap`: sổ phím báo có click / phím tắt bộ gõ không thấy trước phím này.
    func backspace(gap: KeyGap = .none) {
        tick(stepMS)
        if !session.handle(.backspace, self, options: options, forceMarked: false, gap: gap, web: true), caret > 0 {
            let n = graphemeBackspace ? (String(decoding: units[..<caret], as: UTF16.self).last.map { String($0).utf16.count } ?? 1) : 1
            units.removeSubrange((caret - n)..<caret)
            caret -= n
            snapshot()
        }
    }
    /// Trang tự đổi chữ (dán bằng chuột…) và báo ngay.
    func pageSet(_ t: String) {
        units = Array(t.utf16)
        caret = units.count
        snapshot()
        snapshots[snapshots.count - 1].due = 0
    }
    func type(_ keys: String) {
        for k in keys {
            if k == "⌫" { backspace() } else if k == "←" { arrowLeft() } else { press(k) }
        }
    }
    /// ← (InputController đưa phím mũi tên như ký tự U+F702; bộ gõ cho đi, trang dời con trỏ).
    func arrowLeft() {
        tick(stepMS)
        if !session.handle(.char("\u{F702}"), self, options: options, forceMarked: false, web: true), caret > 0 {
            caret -= 1
            snapshot()
        }
    }
    func finish() { for _ in 0..<5 { tick(100) } }
    func idle() { for _ in 0..<10 { tick(200) } }
    /// Trang tự đổi chữ bằng JavaScript (xoá ô sau khi gửi, đổi nháp…): không qua phím nên trang không báo bộ đệm.
    func jsSet(_ t: String) {
        units = Array(t.utf16)
        caret = units.count
    }
    /// Người dùng click vào chỗ khác (Chromium không đưa click cho bộ gõ); click là sự kiện nhập liệu nên trang báo ngay.
    func click(at location: Int) {
        caret = location
        snapshot()
        snapshots[snapshots.count - 1].due = 0
    }
}

/// Ô GTK 3 (gdk/quartz, imquartz.c): marked text thật, `hasMarkedText` đúng; mỗi phím chỉ giữ LẦN CHÈN CUỐI (TIC_INSERT_TEXT bị
/// ghi đè) — phím bộ gõ cho đi mà ra chữ thì AppKit chèn chữ đó, đè lên lần chốt từ của bộ gõ trong cùng phím.
/// `winit`: thay vào đó như winit 0.30 — chèn khi không có marked text thì bị bỏ; sau lần chốt, phím bộ gõ cho đi bị nuốt trừ khi
/// bộ gõ đã gỡ marked text (setMarkedText "").
private final class ToolkitField: TextClient {
    var units: [UInt16] = []
    var marked = ""
    var winit: Bool
    var pending: [String] = []          // GTK: các lần chèn trong phím đang xử lý
    var committedThisKey = false        // winit: trạng thái Committed
    let session = Session()
    var options = EngineOptions()
    init(winit: Bool = false) { self.winit = winit }

    var text: String { String(decoding: units, as: UTF16.self) }

    func selectedRange() -> (location: Int, length: Int)? { winit ? nil : (0, 0) }
    func text(location: Int, length: Int) -> String? { nil }
    func replaceText(location: Int, length: Int, with t: String) { XCTFail("không thay trực tiếp ở \(winit ? "winit" : "GTK")") }
    func replaceViaMarkedText(location: Int, length: Int, with t: String) { XCTFail("không thay trực tiếp") }
    func setMarkedText(_ t: String) {
        marked = t
        if winit, t.isEmpty { committedThisKey = false }
    }
    func insertText(_ t: String) {
        if winit {
            guard !marked.isEmpty || committedThisKey else { return }      // không có marked text: bỏ
            units += Array(t.utf16)
            committedThisKey = true
            marked = ""
            return
        }
        marked = ""
        pending.append(t)
    }
    func hasMarkedText() -> Bool { !marked.isEmpty }

    /// Một phím: `chars` là chữ phím ra (nil: phím không ra chữ như ⏎ thì ô tự xử lý thành `effect`).
    func press(_ key: Key, chars: String?, effect: String? = nil) {
        committedThisKey = false
        pending = []
        let handled = session.handle(key, self, options: options, forceMarked: true, combinedCommit: true,
                                     clearAfterCommit: winit, trustMarked: true, keyText: chars)
        if winit {
            if !handled, !committedThisKey { units += Array((chars ?? effect ?? "").utf16) }   // còn Committed: phím bị nuốt
            return
        }
        if !handled, let chars { pending.append(chars) }                    // AppKit chèn chữ của phím
        if let last = pending.last { units += Array(last.utf16) }           // chỉ giữ lần chèn cuối
        if !handled, chars == nil, let effect { units += Array(effect.utf16) }   // ⏎: GTK tự xử lý sau lần chốt
    }

    func type(_ keys: String) {
        for k in keys {
            if k == "\n" { press(.char("\r"), chars: nil, effect: "\n") } else { press(.char(k), chars: String(k)) }
        }
    }
}

/// Ô tự vẽ (GPUI, terminal nhúng…) của ứng dụng chưa kiểm chứng:
/// - `blind`: như view terminal của Herdr / Zed — con trỏ luôn báo {độ dài marked text}, `insertText` bỏ qua vùng thay (ghi
///   thêm vào cuối), không đọc được chữ;
/// - không `blind`: ô soạn thảo thật (bắt đầu trống) — báo con trỏ thật, thay đúng vùng.
private final class CustomView: TextClient {
    var units: [UInt16] = []
    var caret = 0
    var marked: Range<Int>?
    let blind: Bool
    /// Như SDL2/SDL3 (SDL_cocoakeyboard.m): con trỏ báo lại vùng chọn của lần setMarkedText gần nhất (không đổi khi chèn),
    /// insertText bỏ qua vùng thay.
    var sdl = false
    var sdlSelection = 0
    let session = Session()
    var options = EngineOptions()
    init(blind: Bool) { self.blind = blind }

    var text: String { String(decoding: units, as: UTF16.self) }

    func selectedRange() -> (location: Int, length: Int)? {
        if sdl { return (sdlSelection, 0) }
        return blind ? (marked?.count ?? 0, 0) : (caret, 0)
    }
    func text(location: Int, length: Int) -> String? {
        guard !blind, location >= 0, location + length <= units.count else { return nil }
        return String(decoding: units[location..<location + length], as: UTF16.self)
    }
    func replaceText(location: Int, length: Int, with t: String) {
        if blind || sdl { insertText(t); return }           // bỏ qua vùng thay
        units.replaceSubrange(location..<location + length, with: Array(t.utf16))
        caret = location + t.utf16.count
    }
    func replaceViaMarkedText(location: Int, length: Int, with t: String) { replaceText(location: location, length: length, with: t) }
    func setMarkedText(_ t: String) {
        if sdl, !t.isEmpty { sdlSelection = t.utf16.count }
        let r = marked ?? caret..<caret
        units.replaceSubrange(r, with: Array(t.utf16))
        marked = t.isEmpty ? nil : r.lowerBound..<(r.lowerBound + t.utf16.count)
        caret = r.lowerBound + t.utf16.count
    }
    func insertText(_ t: String) {
        let r = marked ?? caret..<caret
        units.replaceSubrange(r, with: Array(t.utf16))
        caret = r.lowerBound + t.utf16.count
        marked = nil
    }
    func hasMarkedText() -> Bool { marked != nil }

    func type(_ keys: String) {
        for k in keys where !session.handle(.char(k), self, options: options, forceMarked: false) {
            insertText(String(k))
        }
    }

    /// Phím không ra chữ: nếu bộ gõ cho đi thì ô làm `effect`.
    func press(_ key: Key, effect: () -> Void) {
        if !session.handle(key, self, options: options, forceMarked: false) { effect() }
    }
}

/// Ô nhập liệu dùng marked text như NSTextView: marked text nằm trong văn bản, `insertText` chốt nó; ứng dụng có thể tự chốt
/// phần gạch chân mà bộ gõ không thấy (JetBrains Runtime khi click, ứng dụng đổi chữ bằng chương trình…).
private final class ComposingField: TextClient {
    var units: [UInt16] = []
    var caret = 0
    var marked: Range<Int>?
    let session = Session()
    var options = EngineOptions()

    var text: String { String(decoding: units, as: UTF16.self) }

    func selectedRange() -> (location: Int, length: Int)? { (caret, 0) }
    func text(location: Int, length: Int) -> String? {
        guard location >= 0, location + length <= units.count else { return nil }
        return String(decoding: units[location..<location + length], as: UTF16.self)
    }
    func replaceText(location: Int, length: Int, with text: String) { XCTFail("chế độ gạch chân không thay chữ trực tiếp") }
    func replaceViaMarkedText(location: Int, length: Int, with text: String) { XCTFail("chế độ gạch chân") }
    func setMarkedText(_ t: String) {
        let r = marked ?? caret..<caret
        units.replaceSubrange(r, with: Array(t.utf16))
        marked = t.isEmpty ? nil : r.lowerBound..<(r.lowerBound + t.utf16.count)
        caret = r.lowerBound + t.utf16.count
    }
    func insertText(_ t: String) {
        let r = marked ?? caret..<caret
        units.replaceSubrange(r, with: Array(t.utf16))
        caret = r.lowerBound + t.utf16.count
        marked = nil
    }
    func hasMarkedText() -> Bool { marked != nil }

    func type(_ keys: String) {
        for k in keys where !session.handle(.char(k), self, options: options, forceMarked: true) {
            XCTAssertNil(marked, "phím \(k) đi thẳng khi còn marked text")
            insertText(String(k))
        }
    }

    /// Ứng dụng tự chốt phần gạch chân (con trỏ đặt ở `caretAt` nếu có).
    func appCommits(caretAt at: Int? = nil) {
        marked = nil
        if let at { caret = at }
    }
}

/// Terminal giả, dùng chế độ gạch chân: phím đi qua và chữ chốt (`insertText`) tới shell ngay, không sửa lại
/// được nữa; marked text (gạch chân) chỉ hiện trên màn hình, chưa tới shell.
private final class Terminal: TextClient {
    var shell = ""            // những gì shell đã nhận
    var marked = ""           // marked text đang hiện
    let session = Session()
    var options = EngineOptions()

    var screen: String { shell + marked }

    func selectedRange() -> (location: Int, length: Int)? { (0, 0) }
    func text(location: Int, length: Int) -> String? { nil }
    func replaceText(location: Int, length: Int, with text: String) {
        XCTFail("terminal không sửa được chữ đã gửi (thay bằng \"\(text)\")")
    }
    func setMarkedText(_ text: String) { marked = text }
    func insertText(_ text: String) { marked = ""; shell += text }
    func replaceViaMarkedText(location: Int, length: Int, with text: String) {
        XCTFail("terminal không sửa được chữ đã gửi (thay bằng \"\(text)\")")
    }

    /// Terminal (chốt sớm phần không còn đổi được); false: ứng dụng thường dùng gạch chân (giữ cả từ).
    var earlyCommit = true

    func type(_ keys: String) {
        for k in keys where !session.handle(.char(k), self, options: options, forceMarked: true, earlyCommit: earlyCommit) {
            // Bộ gõ phải chốt marked text trước khi để terminal tự xử lý phím.
            XCTAssertEqual(marked, "", "phím \(k) đi thẳng khi còn marked text")
            shell.append(k)
        }
    }

    func backspace() {
        if session.handle(.backspace, self, options: options, forceMarked: true, earlyCommit: earlyCommit) { return }
        XCTAssertEqual(marked, "", "Backspace đi thẳng khi còn marked text")
        if !shell.isEmpty { shell.removeLast() }
    }
}

/// Shell giả sau một terminal (chế độ terminal): phím đi thẳng và chuỗi `insertText` được ghi xuống shell
/// ngay; DEL (0x7F) xoá một ký tự như phím Backspace. Không được dùng marked text.
private final class Shell: TextClient {
    var line: [Character] = []       // dòng lệnh của shell (mỗi phần tử một code point)
    var writes: [String] = []        // từng lần terminal ghi xuống shell
    let session = Session()
    var options = EngineOptions()
    var style = TerminalStyle.inline

    var text: String { String(String.UnicodeScalarView(line.flatMap { $0.unicodeScalars })) }

    func selectedRange() -> (location: Int, length: Int)? { (0, 0) }
    func text(location: Int, length: Int) -> String? { nil }
    func replaceText(location: Int, length: Int, with text: String) { XCTFail("terminal: không thay được chữ") }
    /// Kiểu `.deferred` (Ghostty): chỉ được dùng marked text rỗng U+200B (không hiện) để giữ phím.
    func setMarkedText(_ text: String) {
        if text == "\u{200B}" { invisibleMarks += 1; markActive = true } else { XCTFail("terminal: không được gạch chân (\(text))") }
    }
    func insertText(_ text: String) {
        markActive = false           // insertText thay marked text (như Ghostty)
        write(text)
    }
    var markActive = false
    func hasMarkedText() -> Bool { markActive }
    func replaceViaMarkedText(location: Int, length: Int, with text: String) { XCTFail("terminal: marked text") }

    var invisibleMarks = 0
    /// false: việc hẹn giờ bị trễ (phím sau tới trước) — chạy bằng `runLater()`.
    var runScheduledNow = true
    private var later: [() -> Void] = []
    func schedule(after delay: Double, _ work: @escaping () -> Void) {
        if runScheduledNow { work() } else { later.append(work) }
    }
    func runLater() {
        let works = later
        later = []
        works.forEach { $0() }
    }

    private func write(_ s: String) {
        writes.append(s)
        for scalar in s.unicodeScalars {
            if scalar == "\u{7f}" {
                if !line.isEmpty { line.removeLast() }
            } else {
                line.append(Character(scalar))
            }
        }
    }

    func type(_ keys: String) {
        for k in keys where !session.handle(.char(k), self, options: options, forceMarked: false, terminal: style) {
            write(String(k))
        }
    }

    func backspace() {
        if !session.handle(.backspace, self, options: options, forceMarked: false, terminal: style) { write("\u{7f}") }
    }

    /// Phím đặc biệt (Ctrl+E, mũi tên…): bộ gõ không được giữ lại.
    func other() -> Bool { session.handle(.other, self, options: options, forceMarked: false, terminal: style) }

    // Terminal tự xử lý phím lặp mà không qua bộ gõ (Rex, Muxy)
    var now = 100.0
    func currentTime() -> Double { now }
    func typeRex(_ keys: String, gap: Double = 0.1) {
        for k in keys {
            if !session.handle(.char(k), self, options: options, forceMarked: false, terminal: .inline, repeatDelay: 0.4) {
                write(String(k))
            }
            now += gap
        }
    }
    func backspaceRex() {
        if !session.handle(.backspace, self, options: options, forceMarked: false, terminal: .inline, repeatDelay: 0.4) {
            write("\u{7f}")
        }
        now += 0.1
    }
    /// Giữ Backspace: các lần lặp tới shell, bộ gõ không thấy.
    func heldBackspaceRepeats(_ n: Int) {
        for _ in 0..<n { write("\u{7f}") }
        now += 0.5
    }
}

/// Ghostty 1.4.0 (macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift, src/input/key_encode.zig), phần nhập liệu:
/// - keyDown nhớ có marked text từ trước không (`markedTextBefore`) và gom chữ `insertText` trong lúc chờ bộ gõ.
///   Nhánh A (có marked text từ trước, có chữ gom được): ghi nguyên văn từng chữ (trừ ký tự điều khiển đứng riêng),
///   chỉ phát lại ↑ ↓ →. Nhánh B (có chữ): chữ thành chữ của phím; mở đầu bằng ký tự điều khiển (C0, DEL) thì bị bỏ
///   — phím chữ không ghi gì. Nhánh C (không có chữ): đang soạn (còn hoặc vừa hết marked text) thì phím bị nuốt,
///   không thì mã hoá phím như thường.
/// - `insertText` ngoài keyDown: ghi nguyên văn (Ghostty bỏ nếu không có sự kiện nào đang xử lý: `dropOutside`).
/// - Marked text chỉ có ký tự rộng 0 (U+200B) thì không vẽ gì.
/// Đồng hồ giả: Ghostty còn trong keyDown `keyDownTail` giây sau khi bộ gõ trả lời; việc hẹn giờ của bộ gõ tới hạn
/// trong khoảng đó thì chạy trong keyDown — chỗ đua đã thấy ở IME Lab.
private final class GhosttySim: TextClient {
    enum Press { case char(Character), backspace, ctrlE, enter, up, left }

    var line: [Character] = []
    var controls: [String] = []     // phím điều khiển shell nhận được (Ctrl+E, Enter, mũi tên)
    var mark = ""
    let session = Session()
    var options = EngineOptions()
    var now = 0.0
    var keyDownTail = 0.002
    var dropOutside = 0
    private var accumulator: [String]?
    private var timers: [(at: Double, seq: Int, work: () -> Void)] = []
    private var seq = 0

    var text: String { String(String.UnicodeScalarView(line.flatMap { $0.unicodeScalars })) }

    func selectedRange() -> (location: Int, length: Int)? { (0, 0) }
    func text(location: Int, length: Int) -> String? { nil }
    func replaceText(location: Int, length: Int, with text: String) { XCTFail("Ghostty: không thay được chữ") }
    func replaceViaMarkedText(location: Int, length: Int, with text: String) { XCTFail("Ghostty: marked text") }
    func setMarkedText(_ text: String) {
        XCTAssertTrue(text == "\u{200B}" || text.isEmpty, "Ghostty: không được gạch chân (\(text))")
        mark = text
    }
    func insertText(_ text: String) {
        if accumulator == nil && dropOutside > 0 { dropOutside -= 1; return }
        mark = ""
        if accumulator != nil { accumulator!.append(text); return }
        write(text)
    }
    func hasMarkedText() -> Bool { !mark.isEmpty }
    func currentTime() -> Double { now }
    func schedule(after delay: Double, _ work: @escaping () -> Void) {
        seq += 1
        timers.append((now + delay, seq, work))
    }

    private func runTimers(until t: Double) {
        while let next = timers.filter({ $0.at <= t }).min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }) {
            timers.removeAll { $0.seq == next.seq }
            now = max(now, next.at)
            next.work()
        }
    }

    /// Thời gian trôi, Ghostty rảnh (ngoài keyDown).
    func wait(_ seconds: Double) {
        let end = now + seconds
        runTimers(until: end)
        now = end
    }

    /// Phím người dùng bấm; `ledger`: sổ phím báo gì cho phím này; `gap`: thời gian tới phím sau.
    func press(_ p: Press, gap: Double = 0.04, ledger: KeyGap = .none) {
        let markedBefore = !mark.isEmpty
        accumulator = []
        let key: Key
        var legacy: String?
        switch p {
        case let .char(c): key = .char(c)
        case .backspace: key = .backspace; legacy = "\u{7f}"
        case .enter: key = .char("\r"); legacy = "\r"
        case .up: key = .char("\u{F700}")
        case .left: key = .char("\u{F702}"); legacy = "\u{1b}[D"
        case .ctrlE: key = .other; legacy = "\u{05}"
        }
        let handled = session.handle(key, self, options: options, forceMarked: false, terminal: .deferred, gap: ledger,
                                     legacy: legacy)
        runTimers(until: now + keyDownTail)          // vẫn trong keyDown
        if !handled, case let .char(c) = p { accumulator!.append(String(c)) }   // AppKit: insertText(c)
        let acc = accumulator!
        accumulator = nil
        let composing = !mark.isEmpty || markedBefore
        if markedBefore && !acc.isEmpty {
            for t in acc where !(composing && t.unicodeScalars.count == 1 && t.unicodeScalars.first!.value < 0x20) {
                write(t)
            }
            if case .up = p { write(encoded(p)) }
        } else if !acc.isEmpty {
            for t in acc where !Self.startsWithControl(t) { write(t) }
        } else if !composing {
            write(encoded(p))
        }
        wait(gap)
    }

    func type(_ keys: String, gap: Double = 0.04) {
        for k in keys { press(.char(k), gap: gap) }
    }

    private static func startsWithControl(_ t: String) -> Bool {
        guard let v = t.unicodeScalars.first?.value else { return false }
        return v < 0x20 || v == 0x7f
    }

    private func encoded(_ p: Press) -> String {
        switch p {
        case let .char(c): return String(c)
        case .backspace: return "\u{7f}"
        case .ctrlE: return "\u{05}"
        case .enter: return "\r"
        case .up: return "\u{1b}[A"
        case .left: return "\u{1b}[D"
        }
    }

    private func write(_ s: String) {
        var scalars = Array(s.unicodeScalars)[...]
        while let scalar = scalars.first {
            scalars = scalars.dropFirst()
            if scalar == "\u{7f}" {
                if !line.isEmpty { line.removeLast() }
            } else if scalar == "\u{1b}" {
                controls.append(String(String.UnicodeScalarView([scalar] + scalars)))   // chuỗi ESC tới hết
                return
            } else if scalar.value < 0x20 {
                controls.append(String(scalar))
            } else {
                line.append(Character(scalar))
            }
        }
    }

    /// Phím terminal tự xử lý mà không qua bộ gõ (vd. ⌘V dán).
    func bypassPaste(_ s: String) { write(s) }
}

/// Terminal giả có màn hình + con trỏ như iTerm2 / Terminal.app: báo vị trí con trỏ và cho đọc chữ trên màn
/// hình; chữ ghi xuống shell chỉ hiện sau khi shell in lại (`echo()`); một số phím terminal tự xử lý mà không
/// qua bộ gõ (`bypass…`).
private final class ScreenTerminal: TextClient {
    var cells: [Character] = []
    var cursor = 0
    let base = 100                     // vị trí tuyệt đối của ô đầu dòng
    var inFlight: [String] = []        // đã ghi xuống shell, chưa in lại lên màn hình
    var now = 1000.0
    let session = Session()
    var options = EngineOptions(method: .vni)

    var line: String { String(cells) }

    func selectedRange() -> (location: Int, length: Int)? { (base + cursor, 0) }
    func text(location: Int, length: Int) -> String? {
        let from = location - base, to = from + length
        guard from >= 0, to <= cells.count, from <= to else { return nil }
        return String(cells[from..<to])
    }
    func replaceText(location: Int, length: Int, with text: String) { XCTFail("terminal: không thay được chữ") }
    func setMarkedText(_ text: String) { XCTFail("terminal: không được gạch chân (\(text))") }
    func insertText(_ text: String) { inFlight.append(text) }
    func replaceViaMarkedText(location: Int, length: Int, with text: String) { XCTFail("terminal: marked text") }
    func currentTime() -> Double { now }

    /// Shell in lại mọi thứ đã nhận (DEL xoá ký tự trước con trỏ, chữ chèn tại con trỏ, ESC[D dời con trỏ sang trái).
    func echo() {
        for chunk in inFlight {
            if chunk == "\u{1b}[D" {
                cursor = max(0, cursor - 1)
                continue
            }
            for scalar in chunk.unicodeScalars {
                if scalar == "\u{7f}" {
                    if cursor > 0 { cells.remove(at: cursor - 1); cursor -= 1 }
                } else {
                    cells.insert(Character(scalar), at: cursor); cursor += 1
                }
            }
        }
        inFlight = []
    }

    /// ← không qua bộ gõ, shell chưa in lại (màn hình vẫn như cũ).
    func bypassLeftNotEchoed() { inFlight.append("\u{1b}[D") }

    /// Việc bộ gõ hẹn giờ (đo thời gian in lại…), chạy theo đồng hồ giả trong `tick`.
    var scheduled: [(due: Double, work: () -> Void)] = []
    func schedule(after delay: Double, _ work: @escaping () -> Void) { scheduled.append((now + delay, work)) }

    func tick(_ ms: Double) {
        let end = now + ms / 1000
        while let i = scheduled.indices.min(by: { scheduled[$0].due < scheduled[$1].due }), scheduled[i].due <= end {
            let item = scheduled.remove(at: i)
            now = max(now, item.due)
            item.work()
        }
        now = end
    }

    /// Gõ (mỗi phím cách nhau `ms`), shell in lại ngay sau mỗi phím nếu `echoes`; `gap`: sổ phím báo gì cho mỗi phím.
    func type(_ keys: String, ms: Double = 120, echoes: Bool = true, gap: KeyGap = .none) {
        for k in keys {
            if !session.handle(.char(k), self, options: options, forceMarked: false, terminal: .inline, gap: gap) {
                insertText(String(k))
            }
            if echoes { echo() }
            tick(ms)
        }
    }

    func bypassLeft() { cursor -= 1; tick(120) }
    func bypassLineStart() { cursor = 0; tick(120) }
    func bypassBackspace() { cells.remove(at: cursor - 1); cursor -= 1; tick(120) }
}

/// Một NSView của GPUI (cửa sổ Zed) = một client / bộ điều khiển / Session; tiêu điểm đổi giữa khung terminal (mù: con trỏ {0,0},
/// bỏ qua vùng thay) và editor (con trỏ thật) trong cùng view.
private final class SharedGPUIView: TextClient {
    let terminal = CustomView(blind: true)
    let editor = CustomView(blind: false)
    var inEditor = false
    var target: CustomView { inEditor ? editor : terminal }
    let session = Session()
    var options = EngineOptions()
    var editorMarkedCalls = 0
    func selectedRange() -> (location: Int, length: Int)? { target.selectedRange() }
    func text(location: Int, length: Int) -> String? { target.text(location: location, length: length) }
    func replaceText(location: Int, length: Int, with t: String) { target.replaceText(location: location, length: length, with: t) }
    func replaceViaMarkedText(location: Int, length: Int, with t: String) {
        target.replaceViaMarkedText(location: location, length: length, with: t)
    }
    func setMarkedText(_ t: String) {
        if inEditor, !t.isEmpty { editorMarkedCalls += 1 }
        target.setMarkedText(t)
    }
    func insertText(_ t: String) { target.insertText(t) }
    func hasMarkedText() -> Bool { target.hasMarkedText() }
    func type(_ keys: String) {
        for k in keys where !session.handle(.char(k), self, options: options, forceMarked: false) { target.insertText(String(k)) }
    }
}

final class SessionTests: XCTestCase {
    func testTypingThroughSession() {
        let f = Field()
        f.type("Tooi yeeu tieengs Vieetj, ddepj lawms!")
        XCTAssertEqual(f.text, "Tôi yêu tiếng Việt, đẹp lắm!")
    }

    /// Gõ, Cmd+A, Delete, gõ lại — bộ gõ không thấy Cmd+A.
    func testSelectAllDeleteRetype() {
        let cases: [(String, String, String)] = [
            ("uw", "uw", "ư"), ("ow", "ow", "ơ"), ("ee", "ee", "ê"), ("w", "w", "ư"),
            ("oo thees", "oo", "ô"), ("dd", "dd", "đ"), ("vieetj", "aa", "â"),
        ]
        for readable in [true, false] {
            for (first, again, expected) in cases {
                let f = Field()
                f.readable = readable
                f.type(first)
                f.selectAll()
                f.backspace()
                f.type(again)
                XCTAssertEqual(f.text, expected, "\(first) -> \(again), readable=\(readable)")
            }
        }
    }

    /// Cmd+A rồi gõ đè luôn (không xoá).
    func testSelectAllOverwrite() {
        for readable in [true, false] {
            let f = Field()
            f.readable = readable
            f.type("ow")
            f.selectAll()
            f.type("uw")
            XCTAssertEqual(f.text, "ư", "readable=\(readable)")
        }
    }

    /// Thanh địa chỉ có gợi ý tự động đang bôi đen sau con trỏ.
    func testAutocomplete() {
        let f = Field()
        f.suggestions = ["dantri.com.vn", "oops.com", "tuoitre.vn"]
        f.type("dd")
        XCTAssertEqual(f.text, "đ")
        let g = Field()
        g.suggestions = f.suggestions
        g.type("oo")
        XCTAssertEqual(g.text, "ô")
        let h = Field()
        h.suggestions = f.suggestions
        h.type("tuoi")
        XCTAssertEqual(h.text, "tuoitre.vn")
        h.type("o")                          // gợi ý "tre.vn" đang bôi đen bị thay luôn
        XCTAssertEqual(h.text, "tuôi")
    }

    /// Backspace khi có gợi ý tự động: chỉ xoá gợi ý, từ đang gõ giữ nguyên.
    func testBackspaceOnSuggestion() {
        let f = Field()
        f.suggestions = ["vietnamnet.vn"]
        f.type("vie")
        XCTAssertEqual(f.text, "vietnamnet.vn")
        f.backspace()
        XCTAssertEqual(f.text, "vie")
        f.type("e")
        XCTAssertEqual(f.text, "viê")
    }

    /// Văn bản đổi ngoài tầm bộ gõ (Cmd+Z, dán...) ở giữa từ.
    func testExternalEdit() {
        let f = Field()
        f.type("tieng")
        f.units = Array("xin chao".utf16)
        f.sel = (8, 0)
        f.type("f")
        XCTAssertEqual(f.text, "xin chào")
    }

    /// Telegram (Qt): "[[" từng ra "ơ[" vì chuỗi thay vào trùng ký tự phím vừa bấm.
    func testQtStyleApp() {
        let cases: [(String, String)] = [
            ("[[", "["), ("]]", "]"), ("[[[", "[["), ("ww", "w"), ("t[[", "t["),
            ("vieetj", "việt"), ("dduwowngf", "đường"), ("ass", "as"), ("aaa", "aa"),
        ]
        for (keys, expected) in cases {
            let f = Field()
            f.qtStyle = true
            f.type(keys)
            XCTAssertEqual(f.text, expected, keys)
        }
    }

    /// Ô nhập liệu trong trang web (ô "Ask Google" của Chrome, Claude desktop): bản 1.10.4 dùng marked
    /// text cho "[[" ở mọi ứng dụng nên ra "ơ[". Chỉ ứng dụng Qt mới dùng marked text.
    func testChromiumWebField() {
        let cases: [(String, String)] = [
            ("[[", "["), ("]]", "]"), ("ww", "w"), ("t[[", "t["), ("vieetj", "việt"), ("dduwowngf", "đường"),
        ]
        for (keys, expected) in cases {
            let f = Field()
            f.chromiumStyle = true
            f.type(keys)
            XCTAssertEqual(f.text, expected, keys)
        }
    }

    /// Xoá lùi vào một từ đã gõ xong rồi gõ tiếp: "hoirr " → xoá " ", "r" → "hoi" → gõ "r" → "hỏi".
    func testContinueWordAfterBackspace() {
        let f = Field()
        f.type("hoirr ")
        XCTAssertEqual(f.text, "hoir ")
        f.backspace(); f.backspace()
        XCTAssertEqual(f.text, "hoi")
        f.type("r")
        XCTAssertEqual(f.text, "hỏi")

        let g = Field()
        g.type("viet ")
        g.backspace(); g.backspace()          // "vie"
        g.type("etj")
        XCTAssertEqual(g.text, "việt")

        let h = Field()
        h.type("toi ")
        h.backspace()                         // xoá dấu cách, còn "toi"
        h.type("f")
        XCTAssertEqual(h.text, "tòi")

        // Gõ sau dấu cách vẫn là từ mới, không nối vào từ trước
        let k = Field()
        k.type("toi f")
        XCTAssertEqual(k.text, "toi f")

        // Ứng dụng không cho đọc văn bản: không đọc lại được, gõ như từ mới (không ghi sai chỗ)
        let m = Field()
        m.readable = false
        m.type("hoirr ")
        m.backspace(); m.backspace()
        m.type("r")
        XCTAssertEqual(m.text, "hoir")
    }

    /// InputMethodKit / ứng dụng gọi `commitComposition` giữa từ mà ô nhập liệu không mất focus. Gõ trực tiếp, từ vẫn nằm
    /// nguyên trước con trỏ: giữ từ — 'd' rồi '9' vẫn ra "đ" (TinyCast: "d9ẳng").
    func testCommitRequestKeepsDirectWord() {
        let f = Field()
        f.options.method = .vni
        f.type("d")
        f.session.commitRequested(f)
        f.type("9a38ng")
        XCTAssertEqual(f.text, "đẳng")

        // Ứng dụng đã tự đổi văn bản: bỏ từ, không sửa nhầm chữ khác.
        let g = Field()
        g.options.method = .vni
        g.type("d")
        g.units = Array("x".utf16)
        g.sel = (1, 0)
        g.session.commitRequested(g)
        g.type("9")
        XCTAssertEqual(g.text, "x9")

        // Không đọc được văn bản: không chắc từ còn nguyên — bỏ từ như trước.
        let h = Field()
        h.options.method = .vni
        h.readable = false
        h.type("d")
        h.session.commitRequested(h)
        h.type("9")
        XCTAssertEqual(h.text, "d9")

        // Đang bôi đen (gợi ý tự động sau con trỏ…): bỏ từ.
        let k = Field()
        k.type("vie")
        k.selectAll()
        k.session.commitRequested(k)
        k.type("e")
        XCTAssertEqual(k.text, "e")
    }

    func testBackspaceInWord() {
        let f = Field()
        f.type("vieetj")
        f.backspace()
        f.backspace()
        XCTAssertEqual(f.text, "vi")
        f.type("eets")
        XCTAssertEqual(f.text, "viết")
    }

    // MARK: - Terminal (chế độ gạch chân)

    func testTerminalVietnamese() {
        let telex = Terminal()
        telex.type("Tooi yeeu tieengs Vieetj, ddepj lawms! Nguowif, Ddaof, quys, gif, ww.")
        XCTAssertEqual(telex.shell, "Tôi yêu tiếng Việt, đẹp lắm! Người, Đào, quý, gì, w.")
        XCTAssertEqual(telex.marked, "")

        let vni = Terminal()
        vni.options.method = .vni
        vni.type("To6i ye6u tie61ng Vie65t, d9e5p la81m! git commit -m \"Su73a lo64i\"")
        XCTAssertEqual(vni.shell, "Tôi yêu tiếng Việt, đẹp lắm! git commit -m \"Sửa lỗi\"")
        XCTAssertEqual(vni.marked, "")
    }

    /// Issue #2: lệnh tiếng Anh phải tới shell ngay khi gõ (để hiện gợi ý lệnh), không bị giữ trong phần
    /// gạch chân tới khi gõ dấu cách. Chỉ phần còn có thể thêm dấu mới bị giữ lại.
    func testTerminalSendsKeysEarly() {
        // (kiểu gõ, phím, shell đã nhận, đang gạch chân)
        let cases: [(InputMethod, String, String, String)] = [
            (.telex, "ls -la", "ls -l", "a"),           // "la" có thể thành "là"
            (.telex, "brew", "brew", ""),               // "br" không phải tiếng Việt: chốt ngay
            (.telex, "cd ~/Downloads", "cd ~/Downloads", ""),
            (.telex, "git st", "git st", ""),
            (.telex, "git status", "git status", ""),
            (.telex, "npm", "npm", ""),
            (.telex, "echo", "echo", ""),
            (.telex, "text", "text", ""),               // "tẽ" + t: khôi phục rồi chốt
            (.telex, "make", "make", ""),
            (.telex, "git", "g", "it"),                 // còn có thể thành "gít"
            (.telex, "nguowif", "ng", "ười"),
            (.telex, "dd", "", "đ"),                    // d có thể thành đ
            (.telex, "w", "", "ư"),
            (.vni, "ls -la", "ls -l", "a"),
            (.vni, "cd ~/Downloads", "cd ~/Downloads", ""),
            (.vni, "git checkout -b fix2", "git checkout -b fix2", ""),
            (.vni, "nguo7i2", "ng", "ười"),
        ]
        for (method, keys, shell, marked) in cases {
            let t = Terminal()
            t.options.method = method
            t.type(keys)
            XCTAssertEqual(t.shell, shell, "\(method) \(keys)")
            XCTAssertEqual(t.marked, marked, "\(method) \(keys)")
        }
    }

    /// Ứng dụng thường dùng gạch chân (bật tay, ứng dụng không báo con trỏ): giữ cả từ trong phần gạch chân như
    /// bản gốc, nên sửa chữ bằng ⌫ rồi thêm dấu vẫn đúng.
    /// Ứng dụng Java (AWT: Burp Suite…) chỉ gõ được bằng marked text: bộ gõ không bao giờ sửa chữ đã chốt (`Terminal` báo lỗi
    /// nếu có) và không để phím đi thẳng khi còn marked text (Java sẽ phát lại phím gốc). Cùng các bài với IME Lab (`apps`).
    func testJavaStyleMarkedTyping() {
        let cases: [(InputMethod, String, String)] = [
            (.vni, "Vie65t Nam, d9a5i ho5c d9a38ng ", "Việt Nam, đại học đẳng "),
            (.telex, "Vieetj Nam, ddaij hocj ", "Việt Nam, đại học "),
            (.vni, "tie61ng<<<e65t ", "tiệt "),
            (.vni, "d9a38ng, vie65t.", "đẳng, việt."),
        ]
        for (method, keys, expect) in cases {
            let t = Terminal()
            t.earlyCommit = false
            t.options.method = method
            for k in keys { if k == "<" { t.backspace() } else { t.type(String(k)) } }
            XCTAssertEqual(t.screen, expect, "\(method) \(keys)")
            XCTAssertEqual(t.marked, "", "\(keys): từ cuối phải được chốt bằng dấu câu / dấu cách")
        }
    }

    /// ⌫ làm dời dấu thanh (kiểu cũ "hoàn" ⌫ → "hòa"): bộ gõ thay phần đổi nhưng để chính ứng dụng xoá ký tự cuối — đúng cả
    /// khi ứng dụng vẫn chạy ⌫ của nó sau lần thay của bộ gõ (Chromium; IME Lab: "hoafn⌫" từng ra "hò").
    func testBackspaceToneMoveNeverDeletesTwice() {
        for always in [false, true] {
            let f = LaggyField()
            f.backspaceAlways = always
            f.type("hoafn")
            f.backspace()
            f.type(" ")
            XCTAssertEqual(f.text, "hòa ", "ứng dụng luôn chạy ⌫: \(always)")

            let g = LaggyField()
            g.backspaceAlways = always
            g.options.method = .vni
            g.type("toa1n")
            g.backspace()
            g.type(" ")
            XCTAssertEqual(g.text, "tóa ", "VNI, ứng dụng luôn chạy ⌫: \(always)")
        }
        // Ô thường vẫn như cũ.
        let h = Field()
        h.type("hoafn")
        h.backspace()
        h.type(" ")
        XCTAssertEqual(h.text, "hòa ")
    }

    /// Ô có bộ đệm chậm (Chromium khi trang chậm): bộ gõ đọc thấy trạng thái cũ thì không đoán — chữ đi nguyên văn, không bao
    /// giờ thay sai chỗ, đảo thứ tự phím hay xoá chữ không do nó gõ.
    func testLaggyClientNeverEditsFromStaleView() {
        // 'h' chưa được trang báo lại khi 'w' tới: không chèn "ư" trước 'h' ("toi nưh").
        let f = LaggyField()
        f.type("toi n")
        f.autoFlush = false
        f.type("hw")
        f.flush()
        f.autoFlush = true
        f.type(" ")
        XCTAssertEqual(f.text, "toi nhw ")

        // ⌫ chưa được báo lại khi 's' tới: không đọc lại "tieng" rồi thay đè lên chữ sau từ ("tiếngabc").
        let g = LaggyField()
        g.type("tieng abc")
        g.caret = 5
        g.flush()
        g.type("")                                  // con trỏ dời: từ mới bắt đầu ở phím sau
        let start = Session()
        _ = start
        g.autoFlush = false
        g.backspace()
        g.type("s")
        g.flush()
        XCTAssertTrue(g.text.hasSuffix(" abc"), "chữ sau từ phải còn nguyên: \(g.text)")
        XCTAssertFalse(g.text.contains("ếngabc"))

        // Lần thay e → ê chưa được báo lại khi 's' tới: không đọc lại "tie" rồi thay thành "tíe" (mất mũ).
        let h = LaggyField()
        h.type("tie")
        h.autoFlush = false
        h.type("es")
        h.flush()
        XCTAssertNotEqual(h.text, "tíe")
        XCTAssertTrue(h.text == "tiês" || h.text == "tiế", h.text)

        // Bình thường (trang báo lại kịp): gõ đúng cả câu, kể cả ⌫ trong từ.
        let k = LaggyField()
        k.type("Tooi yeeu tieengs Vieetj ")
        XCTAssertEqual(k.text, "Tôi yêu tiếng Việt ")
    }

    /// Ô kiểu Qt 5 (con trỏ luôn báo 0, bỏ qua vùng cần thay): không bao giờ chèn ư / ơ vào giữa từ ("awesome" → "aưesome");
    /// thấy rồi thì các từ sau gõ bằng marked text (GTVInput còn nhận ra Qt 5 trước cả từ đầu tiên, xem `AppToolkit`).
    /// Java (Burp…), Qt 5, GTK: gõ bằng phím ⌫ giả — đúng chữ, không marked text, kể cả khi ứng dụng chậm hơn tốc độ gõ (phím
    /// thật kế tiếp tới trước phím giả: IME Lab "Vieệ") và khi ứng dụng chốt từ sau mọi phím (Java).
    func testSyntheticKeysTypeWithoutUnderline() {
        let cases: [(InputMethod, String, String)] = [
            (.vni, "d9a38ng ", "đẳng "),
            (.vni, "Vie65t Nam, to6i ye6u tie61ng Vie65t d9a5i ho5c. ", "Việt Nam, tôi yêu tiếng Việt đại học. "),
            (.telex, "Vieetj Nam ddaij hocj tieengs Vieetj nguwowif ", "Việt Nam đại học tiếng Việt người "),
            (.telex, "hoafn⌫ ", "hòa "),
            (.vni, "tie61ng⌫⌫⌫e65t ", "tiệt "),
            (.telex, "text password coffee ", "text password coffee "),
            (.vni, "ho6i ⌫3 ", "hổi "),
            // ⌫ thật bấm ngay sau phím sửa, tới ứng dụng trước các phím giả (bộ gõ nhận ra theo thời điểm bấm).
            (.vni, "ho5⌫a ", "ha "), (.vni, "d9⌫a ", "a "), (.telex, "vieetj⌫⌫⌫ ", "v "), (.telex, "ddi⌫⌫a ", "a "),
            // Telex "w" đứng riêng: lần sửa chỉ chèn.
            (.telex, "w w ", "ư ư "),
        ]
        for (method, keys, expect) in cases {
            for backlog in 0...3 {
                for commitEveryKey in [false, true] {
                    let f = SyntheticField()
                    f.backlog = backlog
                    f.commitAfterEveryKey = commitEveryKey
                    f.options.method = method
                    f.type(keys)
                    XCTAssertEqual(f.text, expect, "\(method) \(keys) backlog \(backlog) commit \(commitEveryKey)")
                }
            }
        }
        // Không có quyền gửi phím: không chèn chữ rác — phím đi nguyên văn.
        let g = SyntheticField()
        g.allowPost = false
        g.options.method = .vni
        g.type("d9a38ng ")
        XCTAssertEqual(g.text, "d9a38ng ")
    }

    /// Review cc5ec9b (phím ⌫ giả): ⌫ hai lần sau từ + dấu cách chỉ xoá dấu cách và ký tự cuối; click / ⌘V bấm trước khi ứng dụng
    /// xử lý phím dấu: phím sửa không gửi (không xoá chỗ click / chữ dán).
    func testSyntheticBackspaceIntoWordAndClickBeforeEdit() {
        let cases: [(InputMethod, String, String, String)] = [
            (.telex, "", "tieengs ⌫⌫ ", "tiến "), (.telex, "", "xin chaof ⌫⌫ ", "xin chà "), (.vni, "", "Vie65t ⌫⌫x", "Việx"),
            (.telex, "abc ", "ddaay ⌫⌫", "abc đâ"), (.telex, "", "tieengs ⌫⌫⌫ ", "tiế "),
        ]
        for (method, pre, keys, expect) in cases {
            for backlog in 0...3 {
                for commit in [false, true] {
                    let f = SyntheticField()
                    f.options.method = method
                    f.backlog = backlog
                    f.commitAfterEveryKey = commit
                    f.prefill(pre)
                    f.type(keys)
                    XCTAssertEqual(f.text, expect, "\(keys.debugDescription) backlog \(backlog) commit \(commit)")
                }
            }
        }
        let f = SyntheticField()
        f.options.method = .telex
        f.prefill("hello world ")
        f.type("a")
        f.queue.append(.key("s"))
        f.queue.append(.click(5))
        f.drain()
        XCTAssertEqual(f.text, "hello world as")
        let g = SyntheticField()
        g.options.method = .telex
        g.prefill("x ")
        g.type("a")
        g.queue.append(.key("s"))
        g.queue.append(.paste("PASTE"))
        g.drain()
        XCTAssertEqual(g.text, "x asPASTE")
    }

    /// Review e4867fb: click bộ gõ không thấy ngay sau phím dấu rồi ngừng tay — lần sửa đang hoãn không bao giờ gửi tới chỗ click;
    /// giữ ⌫ (lặp phím) rồi nhả: còn lần lặp chưa tới thì vẫn hoãn.
    func testSyntheticUnseenClickAndAutoRepeat() {
        let f = SyntheticField()
        f.options.method = .telex
        f.prefill("hello world ")
        f.type("a")
        f.queue.append(.key("s"))
        f.queue.append(.unseenClick(5))
        f.drain()
        for _ in 0..<100 { f.runTimers() }
        XCTAssertEqual(f.text, "hello world as")
        var log = PressLog()
        var t = 20.0
        log.sample(at: t, held: [], button: false, flags: 0)
        for _ in 0..<5 { t += 0.008; log.sample(at: t, held: [], button: false, flags: 0) }
        let pressAt = t + 0.008
        for _ in 0..<60 { t += 0.008; log.sample(at: t, held: [51], button: false, flags: 0) }   // giữ ⌫ 0,48 s
        log.keyReceived(51, at: pressAt, isRepeat: false)
        t += 0.008
        log.sample(at: t, held: [], button: false, flags: 0)                                        // nhả
        XCTAssertTrue(log.userKeysPending(now: t + 0.05, since: t - 0.03), "lần lặp tạo trước lúc nhả có thể chưa tới")
        XCTAssertFalse(log.userKeysPending(now: t + 0.05, since: t + 0.04), "đã có phím bấm sau lúc nhả tới")
        var click = PressLog()
        var u = 30.0
        click.sample(at: u, held: [], button: false, flags: 0)
        u += 0.008
        click.sample(at: u, held: [], button: true, flags: 0)
        u += 0.008
        click.sample(at: u, held: [], button: false, flags: 0)
        XCTAssertTrue(click.userKeysPending(now: u + 5, since: u), "click chưa được phím sau xử lý không hết hạn")
    }

    /// Review a3b1690 (phím ⌫ giả): ⌫ lùi về từ không nạp lại được (dài hơn 12 chữ, chữ lạ) rồi gõ tiếp — từ vẫn nguyên, không bị xoá.
    func testSyntheticResumeUnseedableWord() {
        let cases: [(InputMethod, String, String, String)] = [
            (.telex, "", "documentation ⌫, ", "documentation, "), (.vni, "", "international ⌫s ", "internationals "),
            (.telex, "x ", "configuration ⌫.", "x configuration."), (.vni, "", "naïve ⌫s ", "naïves "),
            (.vni, "x ", "understanding ⌫s", "x understandings"),
        ]
        for (method, pre, keys, expect) in cases {
            for backlog in 0...2 {
                let f = SyntheticField()
                f.options.method = method
                f.backlog = backlog
                f.prefill(pre)
                f.type(keys)
                XCTAssertEqual(f.text, expect, "\(keys.debugDescription) backlog \(backlog)")
            }
        }
    }

    /// Sổ nhấn phím: lần nhấn phím không bao giờ tới bộ gõ (phím tắt toàn hệ thống) thôi được coi là đang chờ sau 1 s; phím đang
    /// giữ sau khoảng không đọc không làm lần nhấn thật kế tiếp bị coi là đã nhận.
    func testPressLogUserKeysPending() {
        var log = PressLog()
        var t = 50.0
        log.sample(at: t, held: [], button: false, flags: 0)
        t += 0.008
        log.sample(at: t, held: [123], button: false, flags: 0)
        XCTAssertTrue(log.userKeysPending(now: t, since: t - 1))
        t += 0.008
        log.sample(at: t, held: [], button: false, flags: 0)
        XCTAssertTrue(log.userKeysPending(now: t + 0.5, since: t))
        XCTAssertFalse(log.userKeysPending(now: t + 1.5, since: t))
        var g = PressLog()
        var u = 10.0
        g.sample(at: u, held: [51], button: false, flags: 0)        // lần đọc đầu sau khoảng hở: đang giữ ⌫, không ghi lần nhấn
        g.keyReceived(51, at: u, isRepeat: false)
        u += 0.008
        g.sample(at: u, held: [], button: false, flags: 0)
        for _ in 0..<20 { u += 0.008; g.sample(at: u, held: [], button: false, flags: 0) }
        u += 0.008
        g.sample(at: u, held: [51], button: false, flags: 0)        // lần nhấn thật kế tiếp
        XCTAssertTrue(g.pending.contains { $0.key == 51 })
    }

    /// Có quyền gửi phím: ô đã nhận là ô mù giữ cách gõ bằng phím ⌫ giả kể cả khi về sau ô báo con trỏ thật (ô chậm vừa báo
    /// kịp) — đổi cách gõ giữa chừng làm hỏng chữ, phím giả còn đang tới xoá vào từ sau (review).
    func testBlindLatchWithPermissionStays() {
        for backlog in 0...2 {
            let f = SyntheticField(blind: true)
            f.synthetic = false
            f.backlog = backlog
            f.options.method = .telex
            f.type("tieengs ")
            XCTAssertTrue(f.session.blindLatched)
            f.blind = false                                   // ô bắt đầu báo con trỏ thật
            f.type("nam vieejt ")
            XCTAssertEqual(f.text, "tiếng nam việt ", "backlog \(backlog)")
            XCTAssertTrue(f.session.blindLatched)
        }
    }

    /// ⌫ / ⏎ của người dùng bấm ngay sau phím sửa, tới ứng dụng trước phím giả (ứng dụng chậm), trong ô có sẵn chữ: phím giả
    /// không xoá lố vào chữ có sẵn (review: "abc " + "is⌫x " ra "abcx "). Lần sửa chỉ chèn khi phần theo dõi trống cũng có ⌫ đi
    /// qua bộ gõ để biết lúc chữ giả tới.
    func testSyntheticNeverDeletesPriorText() {
        let cases: [(InputMethod, String, String, String)] = [
            (.telex, "abc ", "is⌫x ", "abc x "), (.vni, "abc\n", "d9⌫a ", "abc\na "), (.telex, "", "xyz\naa⌫b ", "xyz\nb "),
            (.telex, "abc\n", "ddi⌫⌫a ", "abc\na "), (.telex, "", "efi⌫⌫gegart ", "egegart "),
            (.telex, "x\n", "ask⌫⌫nd ", "x\nand "), (.telex, "x\n", "ask⌫⌫⌫ok ", "x\nok "), (.telex, "", "ux⌫⌫n ", "n "),
        ]
        for (method, pre, keys, expect) in cases {
            for backlog in 0...3 {
                for commit in [false, true] {
                    let f = SyntheticField()
                    f.options.method = method
                    f.backlog = backlog
                    f.commitAfterEveryKey = commit
                    f.prefill(pre)
                    f.type(keys)
                    XCTAssertEqual(f.text, expect, "\(keys.debugDescription) backlog \(backlog) commit \(commit)")
                }
            }
        }
        // ⌫ của người dùng nhiều hơn phần theo dõi lúc ứng dụng chậm: ⌫ thừa xoá vào chữ bộ gõ còn nợ — có thể thiếu một lần xoá,
        // không bao giờ xoá lố vào chữ có sẵn.
        let lenient: [(InputMethod, String, String, [String])] = [
            (.telex, "ab ", "ux⌫⌫n ", ["abn ", "ab n "]), (.vni, "ab ", "d9⌫⌫⌫x ", ["ax ", "abx ", "ab x "]),
            (.telex, "xin ", "chaof⌫⌫⌫⌫⌫ ", ["xin ", "xin c ", "xin  "]),
        ]
        for (method, pre, keys, ok) in lenient {
            for backlog in 0...3 {
                let f = SyntheticField()
                f.options.method = method
                f.backlog = backlog
                f.prefill(pre)
                f.type(keys)
                XCTAssertTrue(ok.contains(f.text), "\(keys.debugDescription) backlog \(backlog): \(f.text.debugDescription)")
            }
        }
    }

    /// Ô tự vẽ không cho biết con trỏ (chưa được nhận ra trước): bộ gõ phát hiện ở phím sửa đầu tiên và chuyển sang phím ⌫
    /// giả — không từ nào mất dấu, không gạch chân.
    func testBlindViewSwitchesToSyntheticKeys() {
        for method in [InputMethod.vni, .telex] {
            let f = SyntheticField(blind: true)
            f.synthetic = false
            f.options.method = method
            f.type(method == .vni ? "d9a82ng tie61ng vie65t " : "ddawngf tieengs vieejt ")
            XCTAssertEqual(f.text, "đằng tiếng việt ", "\(method)")
            XCTAssertTrue(f.session.blindLatched)
        }
    }

    /// Electron / Chrome khi trang chậm (bộ đệm chậm 0–3 phím, phím cách nhau 10–120 ms): không bao giờ bỏ dấu, không sửa sai
    /// chỗ (người dùng: "d9a38ng" ra "đa38ng" / "đả8ng").
    func testChromiumLagNeverDropsTones() {
        let cases: [(InputMethod, String, String)] = [
            (.vni, "d9a38ng ", "đẳng "),
            (.vni, "Vie65t Nam, to6i ye6u tie61ng Vie65t d9a5i ho5c. ", "Việt Nam, tôi yêu tiếng Việt đại học. "),
            (.telex, "Vieetj Nam ddaij hocj tieengs Vieetj nguwowif ", "Việt Nam đại học tiếng Việt người "),
            (.telex, "hoafn⌫ ", "hòa "),
            (.vni, "tie61ng⌫⌫⌫e65t ", "tiệt "),
            (.telex, "text password coffee ", "text password coffee "),
            (.vni, "ho6i⌫⌫oi3 ", "hỏi "),
            (.vni, "ho6i⌫⌫i3 ", "hỉ "),
        ]
        for (method, keys, expect) in cases {
            for lag in 0...3 {
                for step in [10.0, 45.0, 120.0] {
                    let f = ChromiumField()
                    f.options.method = method
                    f.lag = lag
                    f.stepMS = step
                    f.type(keys)
                    f.finish()
                    XCTAssertEqual(f.text, expect, "\(method) \(keys) lag \(lag) step \(step)")
                }
            }
        }
    }

    /// Click lùi vào giữa văn bản (Chromium không đưa click cho bộ gõ) rồi gõ: từ mới ở chỗ click, không sửa vào chỗ cũ. ⌫ lùi qua
    /// dấu cách về từ trước rồi gõ dấu: gõ tiếp từ đó.
    func testChromiumClickAndBackspaceIntoPreviousWord() {
        for lag in 0...1 {
            let f = ChromiumField()
            f.options.method = .vni
            f.lag = lag
            f.type("abc def ")
            f.finish()
            f.click(at: 2)
            f.tick(300)
            f.type("d9")
            f.finish()
            XCTAssertEqual(f.text, "abđc def ", "click lag \(lag)")

        }
        // ⌫ khi đã ngừng gõ (chuỗi đã hết) rồi gõ dấu ngay, lúc trang chưa báo lần xoá: chữ vừa xoá không sống lại.
        for lag in 0...2 {
            for step in [10.0, 45.0, 120.0] {
                let h = ChromiumField()
                h.options.method = .vni
                h.lag = lag
                h.stepMS = step
                h.type("hoc ")
                h.finish()
                h.tick(1500)
                h.type("⌫⌫5 ")
                h.finish()
                XCTAssertEqual(h.text, "họ ", "⌫ sau khi ngừng lag \(lag) step \(step)")
            }
        }
        let cases: [(InputMethod, String, String)] = [
            (.vni, "toi ⌫6 ", "tôi "), (.vni, "hoc ⌫5 ", "học "), (.vni, "ma ⌫⌫a1 ", "má "), (.vni, "to6i ⌫⌫⌫a ", "ta "),
            (.vni, "d9i ⌫⌫a8ng ", "đăng "), (.telex, "hoc ⌫j ", "học "), (.telex, "ddi ⌫⌫ ⌫as ", "đá "),
        ]
        for (method, keys, expect) in cases {
            for lag in 0...3 {
                for step in [10.0, 45.0, 120.0] {
                    let g = ChromiumField()
                    g.options.method = method
                    g.lag = lag
                    g.stepMS = step
                    g.type(keys)
                    g.finish()
                    XCTAssertEqual(g.text, expect, "\(keys) lag \(lag) step \(step)")
                }
            }
        }
    }

    /// Trang chậm sau một lúc ngừng gõ: các phím đi thẳng chưa báo chồng lên nhau trong bộ đệm (mỗi lần đoán chèn vào cùng một
    /// chỗ) — chữ sau con trỏ là các lần đoán, không phải dấu hiệu click lùi.
    func testChromiumStackedGuessesAreNotClicks() {
        let cases: [(InputMethod, String, String, String)] = [
            (.vni, "abc", "  ho5c ", "abc  học "), (.vni, "Xin chao.", "  To6i d9i ", "Xin chao.  Tôi đi "),
            (.telex, "abc", "  Tooi ddi ", "abc  Tôi đi "), (.vni, "abc", "..d9i ", "abc..đi "),
            (.telex, "Hello world. ", "te⌫ext ", "Hello world. text "), (.telex, "", "vep⌫ef ", "về "),
            (.vni, "", "cuuo⌫71 ", "cứu "),
        ]
        for (method, prefix, keys, expect) in cases {
            for lag in 0...6 {
                for step in [10.0, 45.0, 120.0] {
                    let f = ChromiumField()
                    f.options.method = method
                    f.lag = lag
                    f.stepMS = step
                    f.type(prefix)
                    f.finish()
                    f.tick(1500)
                    f.type(keys)
                    f.finish()
                    XCTAssertEqual(f.text, expect, "\(keys) lag \(lag) step \(step)")
                }
            }
        }
    }

    /// ⌫ ở ô web (review): click về ranh giới từ rồi gõ; click rồi ⌫ qua dấu cách; ⌫ lùi qua đầu chuỗi; ⌫ nhiều hơn chữ đã đọc;
    /// ⌫ ngay sau mũi tên / ⏎; ⌫ lùi vào từ trước khi gõ liền. Không bao giờ sửa sai chỗ, chữ đã xoá không sống lại.
    func testChromiumBackspaceCases() {
        func run(_ method: InputMethod, _ steps: [(String, Bool)], lag: Int, step: Double) -> String {
            let f = ChromiumField()
            f.options.method = method
            f.lag = lag
            f.stepMS = step
            for (keys, pause) in steps {
                if keys.hasPrefix("@") {
                    f.click(at: Int(keys.dropFirst())!)
                    f.tick(300)
                    continue
                }
                f.type(keys)
                if pause { f.finish(); f.idle() }
            }
            f.finish()
            return f.text
        }
        let exact: [(InputMethod, [(String, Bool)], String)] = [
            (.vni, [("toi di ", false), ("", true), ("@4", false), ("d9 ", false)], "toi đ di "),
            (.telex, [("toi di ", false), ("", true), ("@4", false), ("dd ", false)], "toi đ di "),
            (.vni, [("hoc ban ", true), ("@4", false), ("⌫5 ", false)], "học ban "),
            (.telex, [("hoc ban ", true), ("@4", false), ("⌫j ", false)], "học ban "),
            (.vni, [("abc dep ", true), ("g⌫⌫⌫⌫a1 ", false)], "abc dá "),
            (.telex, [("Toi la ", true), ("x⌫⌫⌫af ", false)], "Toi là "),
            (.telex, [("ban ", true), ("⌫⌫⌫⌫⌫⌫s ", false)], "s "),
            (.vni, [("Xin chao,", true), (String(repeating: "⌫", count: 12) + "to6i d9i ho5c ", false)], "tôi đi học "),
            (.vni, [("Xin chao ban, mot hai ba bon nam sau bay tam chin ", true),
                    (String(repeating: "⌫", count: 38) + "5 ", false)], "Xin chao bạn "),
            (.vni, [("hoc ⌫⌫5 ", false)], "họ "),
            (.vni, [("toi di hoc ⌫⌫⌫⌫⌫⌫⌫⌫6 ", false)], "tôi "),
        ]
        let either: [(InputMethod, String, [String])] = [
            (.vni, "hoc ban ←⌫5", ["hoc bạ ", "hoc ba5 "]),
            (.vni, "Chao ban nhe←←←←⌫5", ["Chao bạ nhe", "Chao ba5 nhe"]),
            (.vni, "di hoc\r⌫⌫5", ["di\nhọ", "di\nho5", "di họ", "di ho5"]),
        ]
        for lag in 0...6 {
            for step in [10.0, 45.0, 120.0] {
                for (method, steps, expect) in exact {
                    XCTAssertEqual(run(method, steps, lag: lag, step: step), expect, "\(steps) lag \(lag) step \(step)")
                }
                for (method, keys, ok) in either {
                    let got = run(method, [(keys, false)], lag: lag, step: step)
                    XCTAssertTrue(ok.contains(got), "\(keys.debugDescription) lag \(lag) step \(step): \(got.debugDescription)")
                }
            }
        }
    }

    /// Review 811e85c: click giữa từ rồi ⌫; chuỗi bắt đầu từ bộ đệm cũ sau ← / ⏎ / ⌫ đi thẳng; click + ⌫ có gap; ⌫ lùi qua emoji.
    /// Ra đúng hoặc đi nguyên văn — không bao giờ sửa vào chữ khác, chữ đã xoá không sống lại.
    func testChromiumStaleStartAndMidWordClick() {
        typealias Case = (InputMethod, (ChromiumField) -> Void, [String])
        let cases: [Case] = [
            (.telex, { f in f.type("xin chao ban"); f.finish(); f.finish(); f.click(at: 8); f.tick(300); f.type("⌫s") },
             ["xin chá ban", "xin chas ban"]),
            (.vni, { f in f.type("Viet Nam la"); f.finish(); f.finish(); f.click(at: 4); f.tick(300); f.type("⌫⌫e65t") },
             ["Việt Nam la", "Vie65t Nam la"]),
            (.vni, { f in f.type("toi di hoc"); f.finish(); f.finish(); f.click(at: 6); f.tick(300); f.type("⌫⌫d9i") },
             ["toi đi hoc", "toi d9i hoc"]),
            (.vni, { f in f.type("toi di hoc"); f.finish(); f.finish(); f.click(at: 4); f.tick(300); f.type("⌫5 ") },
             ["tọi di hoc", "toi5 di hoc"]),
            (.telex, { f in f.type("xin chao←aa ") }, ["xin chaâ o", "xin chaaa o"]),
            (.vni, { f in f.type("xin chao←a2 ") }, ["xin chaà o", "xin chaa2 o"]),
            (.telex, { f in f.type("hoa←oo ") }, ["hoô a", "hooo a"]),
            (.telex, { f in f.type("Viet Nam←aj ") }, ["Viet Naạ m", "Viet Naaj m"]),
            (.telex, { f in f.type("cho a\r⌫aa ") }, ["cho aâ ", "cho aaa "]),
            (.telex, { f in f.type("da\r⌫⌫dd ") }, ["dđ ", "ddd "]),
            (.telex, { f in f.type("xin chao←⌫uw ") }, ["xin chư o", "xin chuw o"]),
            (.vni, { f in f.type("toi di hoc ←⌫a1 ") }, ["toi di hoá  ", "toi di hoa1  "]),
            (.telex, { f in f.type("xin chao←⌫⌫w ") }, ["xin cư o", "xin cw o"]),
            (.telex, { f in f.type("xin chao\r⌫⌫⌫w ") }, ["xin chư ", "xin chw "]),
            (.vni, { f in f.type("toi di hoc "); f.finish(); f.click(at: 4); f.tick(300); f.backspace(gap: .interrupted); f.type("⌫d9 ") },
             ["tođ di hoc ", "tod9 di hoc "]),
            (.vni, { f in f.type("toi di hoc "); f.finish(); f.click(at: 7); f.tick(300); f.backspace(gap: .interrupted); f.type("a1 ") },
             ["toi diá hoc ", "toi dia1 hoc "]),
            (.telex, { f in f.type("abc←w ") }, ["abư c", "abw c"]),
            (.telex, { f in f.graphemeBackspace = true; f.type("haha "); f.idle(); f.pageSet("haha 🤦‍♂️"); f.finish(); f.idle()
                       f.type("xy⌫⌫⌫⌫aa ") }, ["hahaâ ", "hahaaa "]),
            (.vni, { f in f.graphemeBackspace = true; f.type("ban "); f.idle(); f.pageSet("ban 🏳️‍🌈"); f.finish(); f.idle()
                       f.type("xy⌫⌫⌫⌫a1 ") }, ["bána ", "bana1 ", "bán "]),
        ]
        for (i, (method, run, ok)) in cases.enumerated() {
            for lag in 0...6 {
                for step in [10.0, 45.0, 120.0] {
                    let f = ChromiumField()
                    f.options.method = method
                    f.lag = lag
                    f.stepMS = step
                    run(f)
                    f.finish()
                    XCTAssertTrue(ok.contains(f.text), "case \(i) lag \(lag) step \(step): \(f.text.debugDescription)")
                }
            }
        }
    }

    /// Review cc5ec9b (ô web): click chỗ khác giữa từ rồi gõ tiếp; click về trước đầu chuỗi rồi ⌫; ⌫ trên chữ Unicode tổ hợp; ⌫ lùi
    /// về từ trước có ngừng tay. Ra đúng hoặc đi nguyên văn — không sửa vào chữ khác.
    func testChromiumReviewCc5ec9b() {
        typealias Case = (InputMethod, (ChromiumField) -> Void, [String])
        let cases: [Case] = [
            (.vni, { f in f.type("toi di"); f.finish(); f.idle(); f.click(at: 2); f.tick(300); f.type("a1 ") }, ["toá i di", "toa1 i di"]),
            (.telex, { f in f.type("toi di"); f.finish(); f.idle(); f.click(at: 2); f.tick(300); f.type("as ") }, ["toá i di", "toas i di"]),
            (.telex, { f in f.type("toi di"); f.finish(); f.idle(); f.click(at: 4); f.tick(300); f.type("vaf ") }, ["toi và di", "toi vaf di"]),
            (.vni, { f in f.type("toi di"); f.finish(); f.idle(); f.click(at: 4); f.tick(300); f.type("d9a4 ") }, ["toi dã di", "toi d9a4 di"]),
            (.vni, { f in f.pageSet("Hello world "); f.finish(); f.idle(); f.type("abc "); f.finish(); f.click(at: 5); f.type("⌫a1 ") },
             ["Hellá  world abc ", "Hella1  world abc "]),
            (.telex, { f in f.pageSet("Hello world "); f.finish(); f.idle(); f.type("abc "); f.finish(); f.click(at: 5); f.type("⌫as ") },
             ["Hellá  world abc ", "Hellas  world abc "]),
            (.vni, { f in f.pageSet("xin cha\u{300}o"); f.finish(); f.idle(); f.type("⌫⌫⌫a1o ") }, ["xin cháo ", "xin cha1o "]),
            (.telex, { f in f.type("toi di hoc ⌫"); f.finish(); f.idle(); f.type("j ") }, ["toi di học "]),
            (.vni, { f in f.type("Viet Nam ⌫⌫⌫⌫⌫⌫"); f.finish(); f.idle(); f.type("65t ") }, ["Việt "]),
            (.telex, { f in f.type("Xin chao "); f.finish(); f.idle(); f.type("ba⌫⌫⌫f ") }, ["Xin chào "]),
            (.vni, { f in f.type("Viet "); f.finish(); f.idle(); f.type("Nam⌫⌫⌫⌫⌫65t ") }, ["Việt "]),
        ]
        for (i, (method, run, ok)) in cases.enumerated() {
            for lag in 0...6 {
                for step in [10.0, 45.0, 120.0] {
                    let f = ChromiumField()
                    f.options.method = method
                    f.lag = lag
                    f.stepMS = step
                    run(f)
                    f.finish()
                    XCTAssertTrue(ok.contains(f.text), "case \(i) lag \(lag) step \(step): \(f.text.debugDescription)")
                }
            }
        }
    }

    /// Review e4867fb (ô web): trang chậm 6 phím với nhiều trạng thái mỗi phím; click trên trang bận (trang báo click sau khi xử
    /// lý xong phím trước); cửa sổ đọc lại bắt đầu giữa một emoji.
    func testChromiumReviewE4867fb() {
        for lag in 0...6 {
            for step in [10.0, 45.0, 120.0] {
                for (method, keys, expect) in [(InputMethod.telex, "toi ddirw⌫⌫ nhes ", "toi đi nhé "),
                                               (.telex, "toi Virw⌫⌫eetj nhes ", "toi Việt nhé "),
                                               (.vni, "toi d9i1o⌫⌫ nhe1 ", "toi đi nhé ")] {
                    let f = ChromiumField()
                    f.options.method = method
                    f.lag = lag
                    f.stepMS = step
                    f.type(keys)
                    f.finish()
                    XCTAssertEqual(f.text, expect, "\(keys) lag \(lag) step \(step)")
                }
                // Click được báo theo thứ tự (sau khi trang xử lý xong phím trước), phím đầu sau click có gap.
                let g = ChromiumField()
                g.options.method = .telex
                g.lag = lag
                g.stepMS = step
                g.type("toi di hoc")
                g.tick(300)
                g.caret = 3
                g.snapshot()
                g.tick(200)
                g.tick(g.stepMS)
                if !g.session.handle(.char("s"), g, options: g.options, forceMarked: false, gap: .interrupted, web: true) {
                    g.insertText("s")
                }
                g.type(" ")
                g.finish()
                XCTAssertTrue(["tois  di hoc", "tó  di hoc"].contains(g.text), "click lag \(lag) step \(step): \(g.text)")
            }
        }
        for lag in 0...2 {
            for step in [30.0, 80.0] {
                let f = ChromiumField()
                f.options.method = .telex
                f.graphemeBackspace = true
                f.pageSet("ban 😀" + String(repeating: "x", count: 47))
                f.finish()
                f.idle()
                f.lag = lag
                f.stepMS = step
                f.type(String(repeating: "⌫", count: 50) + "s ")
                f.finish()
                XCTAssertTrue(["bá ", "bas "].contains(f.text), "emoji lag \(lag) step \(step): \(f.text)")
            }
        }
    }

    /// Review a3b1690 (ô web): click bộ gõ không thấy sau lúc ngừng tay; ← rồi gõ trên trang chậm; ⏎ rồi gõ chữ giống dòng trên khi
    /// trang chậm; click được báo sau ⌫ đầu. Ra đúng hoặc đi nguyên văn — không sửa vào chữ khác.
    func testChromiumReviewA3b1690() {
        typealias Case = (InputMethod, (ChromiumField) -> Void, [String])
        func clickInOrder(_ f: ChromiumField, _ at: Int) { f.caret = at; f.snapshot(); f.tick(300) }
        let cases: [Case] = [
            (.vni, { f in f.type("toi di hoc "); f.finish(); f.idle(); clickInOrder(f, 7); f.backspace(gap: .interrupted); f.type("⌫5 ") },
             ["toi d5 hoc "]),
            (.telex, { f in f.type("xin chao ban "); f.finish(); f.idle(); clickInOrder(f, 8); f.backspace(gap: .interrupted)
                       f.type("f ") }, ["xin chaf  ban ", "xin chà  ban "]),
            (.telex, { f in f.type("toi hoc←←←va ddi ") }, ["toi va đi hoc", "toi va ddi hoc"]),
            (.telex, { f in f.type("toi\roir ") }, ["toi\rỏi ", "toi\roir "]),
            (.vni, { f in f.type("toi\roi3 ") }, ["toi\rỏi ", "toi\roi3 "]),
            (.telex, { f in f.type("toi di hocj\rcos ") }, ["toi di học\rcó ", "toi di học\rcos "]),
            (.vni, { f in f.type("nao\rnao2 ") }, ["nao\rnào ", "nao\rnao2 "]),
            (.vni, { f in f.type("hoi3\rhoi3 ") }, ["hỏi\rhỏi ", "hỏi\rhoi3 "]),
            (.vni, { f in f.type("toi di hoc "); f.finish(); f.caret = 7; f.snapshot(); f.snapshots[f.snapshots.count - 1].due = 2
                       f.tick(150); f.type("⌫⌫5 ") }, ["toi d5 hoc ", "toi dọ hoc "]),
        ]
        for (i, (method, run, ok)) in cases.enumerated() {
            for lag in 0...6 {
                for step in [10.0, 45.0, 120.0] {
                    let f = ChromiumField()
                    f.options.method = method
                    f.lag = lag
                    f.stepMS = step
                    run(f)
                    f.finish()
                    XCTAssertTrue(ok.contains(f.text), "case \(i) lag \(lag) step \(step): \(f.text.debugDescription)")
                }
            }
        }
    }

    /// Gõ chèn trước chữ có sẵn (VS Code tự đóng ngoặc / nháy): chữ có sẵn sau con trỏ trùng chữ vừa gõ mà trang chưa báo — không
    /// phải click lùi.
    func testChromiumTypingBeforeExistingText() {
        typealias Case = (InputMethod, String, Int, String, [String])
        let cases: [Case] = [
            (.vni, "oc", 0, "ho⌫a1 ", ["há oc"]), (.telex, "oc", 0, "ho⌫as ", ["há oc"]),
            (.telex, "an com", 2, "chaof gif Vieetj ", ["anchào gì Việt  com"]),
            (.telex, "\")", 0, "xin chaof", ["xin chào\")"]),
            (.telex, ")", 0, "ddi ddaau", ["đi đâu)"]),
            (.vni, "\"", 0, "Vie65t Nam d9e5p", ["Việt Nam đẹp\""]),
        ]
        for (method, pre, at, keys, ok) in cases {
            for lag in 0...6 {
                for step in [10.0, 45.0, 120.0] {
                    let f = ChromiumField()
                    f.options.method = method
                    f.pageSet(pre)
                    f.finish()
                    f.idle()
                    f.click(at: at)
                    f.finish()
                    f.idle()
                    f.lag = lag
                    f.stepMS = step
                    f.type(keys)
                    f.finish()
                    XCTAssertTrue(ok.contains(f.text), "\(pre.debugDescription) \(keys.debugDescription) lag \(lag) step \(step): \(f.text.debugDescription)")
                }
            }
        }
    }

    /// Fuzz: gõ chèn giữa chữ có sẵn (sau click) ở mọi độ chậm 0–6 — cùng kết quả như trang không chậm, chữ có sẵn không bị đụng.
    func testChromiumFuzzTypingInsideText() {
        var seed: UInt64 = 12345
        func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        let words = ["chaof", "gif", "Vieetj", "ddi", "hocj", "ddaau", "nhes", "toi", "xin", "an", "com", "tieengs", "ddepj", "ban"]
        let pres = ["an com", "\")", ")", "oc", "abc def", " xyz", "\""]
        var diverge = 0, corrupt = 0
        for _ in 0..<300 {
            let pre = pres[rnd(pres.count)]
            let at = rnd(pre.utf16.count + 1)
            var keys = ""
            for _ in 0..<(1 + rnd(4)) { keys += words[rnd(words.count)] + (rnd(4) == 0 ? "⌫" : "") + " " }
            var results: [String] = []
            for lag in 0...6 {
                let f = ChromiumField()
                f.options.method = .telex
                f.pageSet(pre); f.finish(); f.idle(); f.click(at: at); f.finish(); f.idle()
                f.lag = lag; f.stepMS = 45
                f.type(keys); f.finish()
                results.append(f.text)
                let head = String(decoding: Array(pre.utf16)[..<at], as: UTF16.self)
                let tail = String(decoding: Array(pre.utf16)[at...], as: UTF16.self)
                if !f.text.hasPrefix(head) || !f.text.hasSuffix(tail) {
                    corrupt += 1
                    print("CORRUPT", pre.debugDescription, at, keys.debugDescription, lag, f.text.debugDescription)
                }
            }
            if Set(results).count > 1 {
                diverge += 1
                if diverge <= 5 { print("DIVERGE", pre.debugDescription, at, keys.debugDescription, results.map { $0.debugDescription }) }
            }
        }
        XCTAssertEqual(diverge, 0)
        XCTAssertEqual(corrupt, 0)
    }

    /// Fuzz: câu có ⏎ / ← / ⌫ ở mọi độ chậm 0–6, so với trang không chậm — chỉ được khác ở chỗ phím dấu đi nguyên văn (thêm chữ),
    /// không bao giờ mất chữ hay dấu rơi sai chỗ.
    func testChromiumFuzzNeverCorrupts() {
        var seed: UInt64 = 777
        func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        let words = ["chaof", "gif", "Vieetj", "ddi", "hocj", "ddaau", "nhes", "toi", "xin", "an", "com", "tieengs", "ddepj", "ban", "aa", "oo"]
        var bad = 0, total = 0, literal = 0, same = 0
        var perLag = [Int](repeating: 0, count: 7)
        for _ in 0..<400 {
            var keys = ""
            for _ in 0..<(2 + rnd(5)) {
                keys += words[rnd(words.count)]
                switch rnd(8) { case 0: keys += "⌫"; case 1: keys += "⌫⌫"; case 2: keys += "←"; case 3: keys += "\r"; default: break }
                keys += " "
            }
            // Kết quả đúng: gõ ở ô Cocoa thật (trực tiếp) — chuẩn.
            for lag in 0...6 {
                for step in [10.0, 80.0] {
                    total += 1
                    let f = ChromiumField()
                    f.options.method = .telex
                    f.lag = lag; f.stepMS = step
                    f.type(keys); f.finish()
                    let g = ChromiumField()
                    g.options.method = .telex
                    g.type(keys); g.finish()           // lag 0 nhịp 80: tham chiếu
                    if f.text != g.text {
                        if f.text.count < g.text.count {
                            bad += 1
                            if bad <= 6 { print("BAD", keys.debugDescription, lag, step, f.text.debugDescription, "ref", g.text.debugDescription) }
                        } else if f.text.count == g.text.count {
                            same += 1
                            if same <= 10 { print("SAME", keys.debugDescription, lag, step, f.text.debugDescription, "ref", g.text.debugDescription) }
                        } else { literal += 1; perLag[lag] += 1 }
                    }
                }
            }
        }
        XCTAssertEqual(bad, 0, "mất chữ")
        XCTAssertEqual(same, 0, "dấu rơi sai chỗ")
        XCTAssertEqual(perLag[0], 0)
        _ = (total, literal)
    }

    /// Phím ⌫ giả tới bộ gõ không được coi là lần nhấn ⌫ của người dùng (sổ nhấn phím): ⌫ thật bấm sau đó vẫn là phím chưa tới;
    /// ⌫ thật đang chờ không bị ⌫ giả tới lấy mất.
    func testSyntheticBackspaceDoesNotConsumeUserPress() {
        var log = PressLog()
        var t = 100.0
        log.sample(at: t, held: [], button: false, flags: 0)
        for _ in 0..<5 { t += 0.008; log.sample(at: t, held: [], button: false, flags: 0) }
        log.syntheticKeyArrived(51, since: t - 0.01, at: t)
        for _ in 0..<10 { t += 0.008; log.sample(at: t, held: [], button: false, flags: 0) }
        for _ in 0..<3 { t += 0.008; log.sample(at: t, held: [51], button: false, flags: 0) }
        XCTAssertTrue(log.pending.contains { $0.key == 51 }, "⌫ thật bị nuốt")
        let realAt = t
        t += 0.05
        log.syntheticKeyArrived(51, since: realAt + 0.01, at: realAt + 0.02)             // ⌫ giả gửi sau lần nhấn thật
        XCTAssertTrue(log.pending.contains { $0.key == 51 }, "⌫ giả lấy mất lần nhấn ⌫ thật")
        for _ in 0..<3 { t += 0.008; log.sample(at: t, held: [], button: false, flags: 0) }
        t += 0.008
        log.sample(at: t, held: [51], button: false, flags: 0)        // trạng thái phím của ⌫ giả đọc được (máy chậm)
        log.syntheticKeyArrived(51, since: t - 0.004, at: t - 0.003)
        XCTAssertEqual(log.pending.filter { $0.key == 51 }.count, 1, "lần nhấn của ⌫ giả còn lại")
        log.keyReceived(51, at: t + 0.01, isRepeat: false)            // ⌫ thật tới
        XCTAssertFalse(log.pending.contains { $0.key == 51 })
        var w = PointerWatch()
        w.rebase(10)
        XCTAssertEqual(w.newClicks(12), 2)
        XCTAssertEqual(w.newClicks(12), 0)
    }

    /// Click / phím tắt bộ gõ không thấy được báo muộn (macOS 27: bộ đếm click công bố mỗi 0,5 s) ở đầu một từ khi trang chậm:
    /// không bắt đầu lại chuỗi ở con trỏ cũ của bộ đệm (sửa sai chỗ).
    /// Giới hạn: trang chậm từ 2 phím và chưa báo gì sau lúc có gap thì không phân biệt được với click thật trên trang bận — từ đó
    /// đi nguyên văn (không đoán vị trí).
    func testChromiumLateGapKeepsChain() {
        for lag in 0...6 {
            for step in [10.0, 45.0, 120.0] {
                let f = ChromiumField()
                f.options.method = .vni
                f.lag = lag
                f.stepMS = step
                let keys = Array("to6i d9i ho5c ")
                for (i, k) in keys.enumerated() {
                    f.tick(f.stepMS)
                    let gap: KeyGap = i == 5 || i == 9 ? .bypassed : .none
                    if !f.session.handle(.char(k), f, options: f.options, forceMarked: false, gap: gap, web: true) {
                        f.insertText(String(k))
                    }
                }
                f.finish()
                if lag <= 1 {
                    XCTAssertEqual(f.text, "tôi đi học ", "lag \(lag) step \(step)")
                } else {
                    XCTAssertTrue(["tôi đi học ", "tôi d9i học ", "tôi đi ho5c ", "tôi d9i ho5c "].contains(f.text),
                                  "lag \(lag) step \(step): \(f.text)")
                }
            }
        }
    }

    /// ⌫ ngay sau ⏎ (bộ đệm chưa có ⏎): không dựng từ theo bộ đệm cũ rồi sửa vào chữ người dùng không đụng tới.
    func testChromiumBackspaceRightAfterEnter() {
        for lag in 0...2 {
            for step in [10.0, 45.0, 120.0] {
                for (keys, expect) in [("ba\r⌫⌫a2 ", ["bà ", "ba2 "]), ("xin chao\r⌫⌫⌫a2o ", ["xin chào ", "xin cha2o "])] {
                    let f = ChromiumField()
                    f.options.method = .vni
                    f.lag = lag
                    f.stepMS = step
                    f.type(keys)
                    f.finish()
                    XCTAssertTrue(expect.contains(f.text), "\(keys.debugDescription) lag \(lag) step \(step): \(f.text)")
                }
            }
        }
    }

    /// Trang tự đổi chữ khi xử lý phím (Notion, Slack, Discord): bộ đệm cho thấy chữ khác chuỗi của bộ gõ — không coi là trang
    /// chậm, không sửa vào vị trí cũ.
    /// Giới hạn: trang vừa tự đổi chữ vừa chậm từ 2 phím trở lên thì lúc sửa, bộ đệm chưa cho thấy lần đổi chữ (chỉ có trạng
    /// thái cũ của chính chuỗi) — không phân biệt được với trang chậm.
    func testChromiumPageRewritesTextWhileTyping() {
        for lag in 0...1 {
            for step in [10.0, 45.0, 120.0] {
                let f = ChromiumField()
                f.options.method = .vni
                f.lag = lag
                f.stepMS = step
                f.autoReplace = [("->", "→")]
                f.type("abc ->d9i ho5c ")
                f.finish()
                XCTAssertEqual(f.text, "abc →đi học ", "arrow lag \(lag) step \(step)")

                let g = ChromiumField()
                g.options.method = .vni
                g.lag = lag
                g.stepMS = step
                g.autoReplace = [("- ", "")]
                g.type("- to6i d9i ho5c ")
                g.finish()
                XCTAssertEqual(g.text, "tôi đi học ", "bullet lag \(lag) step \(step)")
            }
        }
    }

    /// Trang xoá ô bằng JavaScript (không báo bộ đệm) rồi người dùng gõ tiếp: không coi đó là trang chậm (lab: mọi phím dấu biến
    /// mất vì lần sửa gửi tới vị trí cũ, ngoài văn bản).
    /// Giới hạn: trang đổi chữ mà không báo VÀ trang chậm hơn một phím ngay đó thì bộ đệm chỉ là lần đoán của Chromium trên vị trí
    /// cũ — không phân biệt được với trạng thái đúng; lần sửa đầu có thể mất, các phím sau đọc lại từ và không bỏ dấu.
    func testChromiumPageClearsFieldBetweenWords() {
        for idle in [0.1, 2.0] {
            for lag in 0...2 {
                let f = ChromiumField()
                f.options.method = .vni
                f.lag = lag
                f.type("khoi dong ")
                f.finish()
                f.jsSet("")
                f.tick(idle * 1000)
                f.type("d9a38ng ")
                f.finish()
                if lag == 0 || (idle > 1 && lag == 1) {
                    XCTAssertEqual(f.text, "đẳng ", "idle \(idle) lag \(lag)")
                } else {
                    // Tệ nhất: phím đi nguyên văn — không bao giờ xoá / sửa nhầm chữ.
                    XCTAssertTrue(["đẳng ", "dẳng ", "da38ng "].contains(f.text), "idle \(idle) lag \(lag): \(f.text)")
                }
            }
        }
    }

    /// Ô được trang tự focus và điền nháp (trang chưa từng báo: bộ đệm {0,0} rỗng): lần sửa đầu chờ trang báo rồi mới sửa,
    /// không sửa chữ đầu của nháp ("Hello" + "d9" phải ra "Hellođ", không phải "đellod"). Giới hạn còn lại: trang chậm tới mức
    /// chưa báo cả phím đầu khi phím thứ ba tới (trễ 2 phím) thì bộ đệm chỉ là lần đoán, không phân biệt được với ô trống.
    func testChromiumUnreportedDraftNeverEditsWrongPlace() {
        for lag in 0...1 {
            for step in [10.0, 80.0] {
                let f = ChromiumField()
                f.units = Array("Hello ".utf16)
                f.caret = 6
                f.lag = lag
                f.stepMS = step
                f.options.method = .vni
                f.type("d9a38ng ")
                f.finish()
                XCTAssertEqual(f.text, "Hello đẳng ", "lag \(lag) step \(step)")
            }
        }
    }

    /// Ô soạn thảo thật (GPUI, Qt 6…): End bấm ở đầu ô (con trỏ {0,0}) không được để lại chế độ gạch chân — ⌫ rồi gõ dấu vẫn
    /// nạp lại từ trước con trỏ ("hoi" + r → "hỏi").
    func testNonWordKeyAtCaretZeroKeepsContinueWord() {
        let f = CustomView(blind: false)
        f.type("hoi x")
        XCTAssertEqual(f.text, "hoi x")
        f.press(.char("\u{F729}")) { f.caret = 0 }                       // Home
        f.press(.char("\u{F72B}")) { f.caret = f.units.count }           // End
        for _ in 0..<2 {
            f.press(.backspace) { f.units.remove(at: f.caret - 1); f.caret -= 1 }
        }
        f.type("r ")
        XCTAssertEqual(f.text, "hỏi ")
        // Ô soạn thảo thật: dấu cách rồi ⌫ đưa con trỏ về chỗ cũ — không bị coi là ô mù (vẫn gõ trực tiếp).
        let g = CustomView(blind: false)
        g.type("ab ")
        g.press(.backspace) { g.units.remove(at: g.caret - 1); g.caret -= 1 }
        g.type("x")
        XCTAssertEqual(g.text, "abx")
        XCTAssertNil(g.marked, "ô thật bị coi là ô mù sau dấu cách + ⌫")
    }

    /// Cờ ô mù không dính cả cửa sổ: khung terminal mù rồi sang editor thật của cùng view (Zed) — editor gõ thẳng như thường
    /// (click: InputController báo `fieldChanged`; không có click thì từ đầu tiên ô báo con trỏ khác là đủ).
    func testBlindLatchDoesNotLeakToRealField() {
        let ref = SharedGPUIView()
        ref.inEditor = true
        ref.type("xin vieejt nam ")
        for click in [true, false] {
            let v = SharedGPUIView()
            v.type("ls ")
            XCTAssertTrue(v.session.blindLatched)
            v.editor.type("xin ")                         // chữ có sẵn trong editor
            v.editor.units = Array("xin ".utf16); v.editor.caret = 4
            v.session.commit(v)
            if click { v.session.fieldChanged() }
            v.inEditor = true
            v.type("vieejt nam ")
            XCTAssertEqual(v.editor.text, "xin việt nam ", "click \(click)")
            XCTAssertEqual(v.editorMarkedCalls, 0, "click \(click)")
            XCTAssertFalse(v.session.blindLatched, "click \(click)")
        }
        XCTAssertEqual(ref.editorMarkedCalls, 0)
    }

    /// Ô chậm (bộ đệm) báo {0,0} ở phím thứ hai của ô trống: không bị coi là ô mù mãi — từ sau gõ thẳng, không gạch chân.
    func testSlowFieldAtStartIsNotBlindForever() {
        let f = LaggyField()
        f.options.method = .telex
        f.autoFlush = false
        f.type("d")
        f.type("d")
        f.flush()
        f.type("a")
        f.flush()
        f.type(" ")
        f.flush()
        f.autoFlush = true
        f.type("vieejt nam ")
        XCTAssertTrue(f.text.hasSuffix("việt nam "), f.text)
        XCTAssertFalse(f.session.blindLatched)
    }

    /// Ô SDL (con trỏ báo đứng yên ở vùng chọn cũ, khác 0) có quyền gửi phím: nhận ra ô mù, gõ bằng phím ⌫ giả, giữ cho các từ sau.
    func testFrozenCaretViewUsesSyntheticKeys() {
        let f = SyntheticField(blind: true)
        f.frozenCaret = 3
        f.synthetic = false
        f.options.method = .vni
        f.type("d9a38ng tie61ng vie65t ")
        XCTAssertEqual(f.text, "đẳng tiếng việt ")
        XCTAssertTrue(f.session.blindLatched)
    }

    /// Ứng dụng được nhận ra (Java, Qt…) giữa từ đầu tiên: đổi sang phím ⌫ giả không nhân đôi các chữ đã đi thẳng.
    func testSwitchToSyntheticMidWordKeepsLetters() {
        for split in 1...3 {
            let f = SyntheticField()
            f.options.method = .telex
            f.synthetic = false
            let keys = Array("vieejt nam ")
            f.type(String(keys[..<split]))
            f.synthetic = true
            f.type(String(keys[split...]))
            XCTAssertFalse(f.text.contains("vv") || f.text.hasPrefix("vivi") || f.text.hasPrefix("vievi"), "\(split): \(f.text)")
            XCTAssertTrue(f.text.hasSuffix(" nam "), "\(split): \(f.text)")
        }
    }

    /// Ô mù khi chưa có quyền gửi phím (Trợ năng): từ đầu tiên lộ ra là ô mù đi nguyên văn phần còn lại, các từ sau gạch chân
    /// (không đi nguyên văn mãi).
    func testBlindViewWithoutPermissionFallsBackToMarked() {
        let f = CustomView(blind: true)
        f.options.method = .vni
        f.type("d9a82ng tie61ng vie65t ")
        XCTAssertTrue(f.text.hasSuffix("tiếng việt "), f.text)
        XCTAssertTrue(f.session.blindLatched)
    }

    /// GTK (CherryTree…) và winit (egui, iced, Alacritty): từ đang gạch chân được chốt cùng chữ của phím kết thúc từ trong một lần
    /// chèn; ⏎ ngay sau từ vẫn có tác dụng (winit: gỡ marked text để không bị nuốt).
    func testGtkAndWinitKeepWordAndTerminator() {
        for winit in [false, true] {
            let f = ToolkitField(winit: winit)
            f.type("vieejt nam, ddaij hocj.\nxong ")
            XCTAssertEqual(f.text, "việt nam, đại học.\nxong ", winit ? "winit" : "GTK")
            let g = ToolkitField(winit: winit)
            g.options.method = .vni
            g.type("vie65t\nd9a82ng ")
            XCTAssertEqual(g.text, "việt\nđằng ", winit ? "winit" : "GTK")
        }
    }

    func testQt5StyleFieldNeverInsertsMidWord() {
        for c in ["awesome", "how", "hello"] {
            let f = Qt5Field()
            f.type(c + " ")
            XCTAssertEqual(f.text, c + " ", c)
        }
        // Ô không cho biết con trỏ mà không được nhận ra trước (Qt 5 được nhận ra theo bộ công cụ), chưa có quyền gửi phím:
        // không bao giờ chèn chữ rác giữa từ; từ lộ ra là ô mù xong thì gõ bằng gạch chân.
        let g = Qt5Field()
        g.options.method = .vni
        g.type("ab vie65t ")
        XCTAssertEqual(g.text, "ab việt ")
    }

    /// Ứng dụng tự chốt phần gạch chân giữa từ: gõ tiếp là từ mới, không dựng lại cả từ ở chỗ mới (thành chữ đôi "việviệt").
    func testMarkedTextEndedByAppStartsNewWord() {
        let f = ComposingField()
        f.options.method = .vni
        f.type("vie65")
        XCTAssertEqual(f.text, "việ")
        f.appCommits()
        f.type("t ")
        XCTAssertEqual(f.text, "việt ")

        // Click sang chỗ khác (ứng dụng tự chốt rồi dời con trỏ về đầu dòng).
        let g = ComposingField()
        g.options.method = .vni
        g.type("to6i ")
        g.type("vie6")
        g.appCommits(caretAt: 0)
        g.type("a1 ")
        XCTAssertEqual(g.text, "á tôi viê")

        // Bình thường (ứng dụng không tự chốt): vẫn gõ đúng cả câu, kể cả xoá lùi trong từ.
        let h = ComposingField()
        h.options.method = .vni
        h.type("Vie65t Nam d9a38ng ")
        XCTAssertEqual(h.text, "Việt Nam đẳng ")
    }

    func testMarkedAppKeepsWholeWordForBackspaceFixes() {
        let cases: [(InputMethod, String, String)] = [
            (.telex, "anht<f", "ành"), (.telex, "tooss<f", "tồ"), (.telex, "hocx<j", "học"),
            (.telex, "hocf<j", "học"), (.telex, "demw<<tej", "dệt"), (.telex, "tooss<s", "tố"),
            (.telex, "shoq<w", "show"), (.telex, "knoq<w", "know"),
            (.vni, "anht<2", "ành"), (.vni, "to611<2", "tồ"),
        ]
        for (method, keys, expect) in cases {
            let t = Terminal()
            t.earlyCommit = false
            t.options.method = method
            for k in keys { if k == "<" { t.backspace() } else { t.type(String(k)) } }
            XCTAssertEqual(t.screen, expect, "\(method) \(keys)")
        }
    }

    /// Terminal gạch chân: từ đã chốt (không phải tiếng Việt), ⌫ rồi gõ tiếp vẫn là chữ thường, không biến đổi
    /// giữa từ; xoá hết từ đã chốt thì từ gõ sau đó lại có dấu.
    func testTerminalLiteralWordBackspace() {
        let t = Terminal()
        t.type("shoq")
        t.backspace()
        t.type("w ")
        XCTAssertEqual(t.screen, "show ")
        let u = Terminal()
        u.type("ls")
        u.backspace()
        u.backspace()
        u.type("vieets ")
        XCTAssertEqual(u.shell, "viết ")
    }

    func testTerminalBackspace() {
        let t = Terminal()
        t.type("tooi")
        XCTAssertEqual(t.shell, "t")
        XCTAssertEqual(t.screen, "tôi")
        t.backspace()                     // xoá trong phần gạch chân
        XCTAssertEqual(t.screen, "tô")
        t.type("s")
        XCTAssertEqual(t.screen, "tố")
        t.backspace()
        XCTAssertEqual(t.screen, "t")
        XCTAssertEqual(t.marked, "")
        t.backspace()                     // "t" đã ở shell: terminal tự xoá
        XCTAssertEqual(t.screen, "")
        t.type("ddi ")
        XCTAssertEqual(t.shell, "đi ")

        // Xoá phụ âm đầu đã gửi rồi gõ tiếp
        let u = Terminal()
        u.type("thx")
        XCTAssertEqual(u.shell, "thx")
        let v = Terminal()
        v.type("tr")
        v.backspace()
        v.type("hoaf")
        XCTAssertEqual(v.shell, "th")
        XCTAssertEqual(v.screen, "thòa")

        // Từ đã chốt (không phải tiếng Việt), xoá lùi rồi gõ tiếp: không ghi sai chỗ
        let w = Terminal()
        w.type("dock")
        XCTAssertEqual(w.shell, "dock")
        w.backspace()
        w.type("s ")
        XCTAssertEqual(w.shell, "docs ")
    }

    /// Click chuột / mất focus: chỉ chốt phần đang gạch chân, không gửi lại phần đã tới shell.
    func testTerminalCommit() {
        let t = Terminal()
        t.type("nguowif")
        t.session.commit(t)
        XCTAssertEqual(t.shell, "người")
        XCTAssertEqual(t.marked, "")
        t.type("ls")
        t.session.commit(t)
        XCTAssertEqual(t.shell, "ngườils")
    }

    // MARK: - Chế độ terminal (không gạch chân)

    func testTerminalModeVietnamese() {
        for style in TerminalStyle.allCases {
            let telex = Shell()
            telex.style = style
            telex.type("Tooi yeeu tieengs Vieetj, ddepj lawms! Nguowif, Ddaof, quys, gif, ww, text, windows.")
            XCTAssertEqual(telex.text, "Tôi yêu tiếng Việt, đẹp lắm! Người, Đào, quý, gì, w, text, windows.", "\(style)")

            let vni = Shell()
            vni.style = style
            vni.options.method = .vni
            vni.type("To6i ye6u tie61ng Vie65t, d9e5p la81m! git commit -m \"Su73a lo64i\" ls -la")
            XCTAssertEqual(vni.text, "Tôi yêu tiếng Việt, đẹp lắm! git commit -m \"Sửa lỗi\" ls -la", "\(style)")
        }
    }

    /// Issue #2: mọi phím tới shell ngay khi gõ (gợi ý của fish hiện ngay), Ctrl+E không bị giữ lại.
    func testTerminalModeKeysReachShellImmediately() {
        let t = Shell()
        t.options.method = .vni
        for (i, k) in "./suo".enumerated() {
            t.type(String(k))
            XCTAssertEqual(t.text, String(Array("./suo")[0...i]))
        }
        XCTAssertFalse(t.other(), "Ctrl+E phải tới shell")
        t.type("x")
        XCTAssertEqual(t.text, "./suox")
    }

    /// Mỗi lần sửa là một lần ghi: xoá và chữ mới tới shell cùng lúc (shell vẽ lại một lần, không nháy).
    func testTerminalModeEditsAreSingleWrites() {
        let t = Shell()
        t.type("tieengs Vieetj nguowif")
        let edits = t.writes.filter { $0.contains("\u{7f}") }
        XCTAssertFalse(edits.isEmpty)
        for w in edits {
            XCTAssertFalse(w.hasSuffix("\u{7f}"), "sửa phải kèm chữ mới trong cùng lần ghi: \(w.debugDescription)")
            XCTAssertNotEqual(w.unicodeScalars.first, "\u{7f}", "kiểu inline mở đầu bằng ký tự thường: \(w.debugDescription)")
        }
    }

    func testTerminalModeBackspace() {
        let t = Shell()
        t.options.method = .vni
        t.type("tie61ng")
        XCTAssertEqual(t.text, "tiếng")
        t.backspace(); t.backspace(); t.backspace()
        XCTAssertEqual(t.text, "ti")
        t.type("e65t ")
        XCTAssertEqual(t.text, "tiệt ")

        // Xoá hết rồi gõ lại
        let u = Shell()
        u.type("dd")
        u.backspace()
        XCTAssertEqual(u.text, "")
        u.type("ddi")
        XCTAssertEqual(u.text, "đi")
    }

    /// Rex/Muxy: giữ Backspace, phím lặp không qua bộ gõ — sau đó không được xoá theo từ cũ.
    func testTerminalHeldBackspaceRepeatsBypass() {
        let t = Shell()
        t.options.method = .vni
        t.typeRex("tie61ng")
        XCTAssertEqual(t.text, "tiếng")
        t.backspaceRex()                  // bộ gõ thấy lần đầu
        t.heldBackspaceRepeats(2)         // 2 lần lặp đi thẳng
        XCTAssertEqual(t.text, "ti")
        t.typeRex("e65t ")
        XCTAssertEqual(t.text, "tiệt ")

        // Backspace một lần rồi gõ dấu ngay (không kịp lặp): vẫn sửa đúng từ đang gõ
        let u = Shell()
        u.options.method = .vni
        u.typeRex("tien")
        u.backspaceRex()
        u.typeRex("6")
        XCTAssertEqual(u.text, "tiê")
    }

    /// Ghostty (kiểu .deferred): giữ phím bằng marked text rỗng rồi gửi xoá + chữ mới sau keyDown.
    func testTerminalModeDeferred() {
        for now in [true, false] {
            let t = Shell()
            t.style = .deferred
            t.options.method = .vni
            t.runScheduledNow = now
            t.type("To6i ye6u tie61ng Vie65t, d9e5p la81m! ls -la ./suo")
            t.runLater()
            XCTAssertEqual(t.text, "Tôi yêu tiếng Việt, đẹp lắm! ls -la ./suo", "chạy ngay=\(now)")
            XCTAssertGreaterThan(t.invisibleMarks, 0)
        }
        // Phím sau tới trước khi lần sửa trước kịp gửi: lần sửa vẫn tới shell trước phím đó.
        let u = Shell()
        u.style = .deferred
        u.options.method = .vni
        u.runScheduledNow = false
        u.type("tie6")
        XCTAssertEqual(u.text, "tie")       // chưa gửi
        u.type("n")
        XCTAssertEqual(u.text, "tiên")
        u.runLater()                        // lần gửi cũ đến muộn: không gửi lại
        XCTAssertEqual(u.text, "tiên")
    }

    /// Ghostty: lần sửa tới lúc Ghostty còn trong keyDown của chính phím đó thì bị bỏ (IME Lab: mất ~4% lần sửa khi
    /// gửi ngay). Gửi trễ `deferDelay` thì luôn tới, kể cả khi Ghostty ra khỏi keyDown chậm vài mili giây.
    func testGhosttyDeferredSendWaitsForKeyDownToEnd() {
        let words = "Vie65t Nam, to6i ye6u tie61ng Vie65t d9a5i ho5c."
        let expect = "Việt Nam, tôi yêu tiếng Việt đại học."
        for tail in [0.0002, 0.001, 0.004] {
            let g = GhosttySim()
            g.options.method = .vni
            g.keyDownTail = tail
            g.type(words)
            XCTAssertEqual(g.text, expect, "Ghostty ra khỏi keyDown sau \(tail * 1000) ms")
            XCTAssertEqual(g.mark, "")
        }
        // Gửi ngay như bản cũ: mô phỏng tái hiện đúng lỗi đã thấy ở IME Lab.
        let saved = Session.deferDelay
        defer { Session.deferDelay = saved }
        Session.deferDelay = 0
        let g = GhosttySim()
        g.options.method = .vni
        g.keyDownTail = 0.0002
        g.type(words)
        XCTAssertNotEqual(g.text, expect)
    }

    /// Ghostty, gõ rất nhanh (phím sau tới trước khi lần sửa kịp gửi): lần sửa đi cùng phím sau, đúng thứ tự.
    func testGhosttyDeferredFastTyping() {
        for method in [InputMethod.vni, .telex] {
            let g = GhosttySim()
            g.options.method = method
            g.keyDownTail = 0.0005
            g.type(method == .vni ? "Vie65t Nam, to6i ye6u tie61ng Vie65t d9a5i ho5c."
                                  : "Vieetj Nam, tooi yeeu tieengs Vieetj ddaij hocj.", gap: 0.001)
            g.wait(0.1)
            XCTAssertEqual(g.text, "Việt Nam, tôi yêu tiếng Việt đại học.", "\(method)")
            XCTAssertEqual(g.mark, "")
        }
    }

    /// Ghostty bỏ insertText ngoài keyDown khi không có sự kiện nào đang xử lý: marked text rỗng còn nguyên thì gửi
    /// lại; bỏ cả 3 lần thì phím kế tiếp mang lần sửa tới (lúc đó Ghostty ghi nguyên văn).
    func testGhosttyDeferredResendWhenDropped() {
        let g = GhosttySim()
        g.options.method = .vni
        g.type("tie")
        g.dropOutside = 1
        g.press(.char("6"), gap: 0.1)
        XCTAssertEqual(g.text, "tiê")
        XCTAssertEqual(g.mark, "")
        g.dropOutside = 10
        g.press(.char("1"), gap: 0.2)
        XCTAssertEqual(g.text, "tiê")
        XCTAssertEqual(g.mark, "\u{200B}")
        g.dropOutside = 0
        g.type("ng")
        XCTAssertEqual(g.text, "tiếng")
        XCTAssertEqual(g.mark, "")
    }

    /// Ghostty: Ctrl+E, ↑, Enter sau chữ có dấu (gõ bình thường) tới shell, không bị nuốt.
    func testGhosttyDeferredControlKeysPass() {
        let g = GhosttySim()
        g.options.method = .vni
        g.type("./suo")
        g.press(.ctrlE)
        g.type(" tie6")
        g.press(.ctrlE)
        g.press(.up)
        g.press(.enter)
        XCTAssertEqual(g.text, "./suo tiê")
        XCTAssertEqual(g.controls, ["\u{05}", "\u{05}", "\u{1b}[A", "\r"])
    }

    /// Bảng mã Unicode tổ hợp: terminal vẫn nhận chữ dựng sẵn (shell xoá cả chữ lẫn dấu bằng một DEL, xoá theo
    /// code point sẽ xoá lố ra ngoài từ).
    func testTerminalModeCombiningCharsetUsesPrecomposed() {
        for style in TerminalStyle.allCases {
            let t = Shell()
            t.style = style
            t.options.charset = .unicodeCombining
            t.line = Array("echo X ")
            t.type("asa ass tiesnge pass ")
            t.runLater()
            XCTAssertEqual(t.text, "echo X ấ as tiếng pas ", "\(style)")   // Telex: ss huỷ dấu
            XCTAssertTrue(t.writes.allSatisfy { !$0.unicodeScalars.contains { (0x300...0x323).contains($0.value) } })
        }
    }

    /// Phím đặc biệt (mũi tên, Ctrl+…) giữa từ: bộ gõ thôi theo dõi từ, không xoá nhầm chữ của shell.
    func testTerminalModeNeverDeletesShellText() {
        let t = Shell()
        t.line = Array("echo ")
        t.type("vie")
        _ = t.other()                 // vd. Ctrl+A rồi Ctrl+E, shell đổi chỗ con trỏ
        t.type("6")
        XCTAssertEqual(t.text, "echo vie6")
    }
    // MARK: - Terminal: phím terminal tự xử lý, không qua bộ gõ

    /// iTerm2: mũi tên không qua bộ gõ. Gõ "tie", ←, "6": không được xoá nhầm (chữ "e" sau con trỏ còn đó).
    func testTerminalGuardArrowBypass() {
        let t = ScreenTerminal()
        t.type("tie")
        t.bypassLeft()
        t.type("6")
        XCTAssertEqual(t.line, "ti6e")
    }

    /// Terminal.app: Backspace không qua bộ gõ. Gõ "tie61ng", xoá 3 lần, gõ tiếp "e65t ": đọc lại từ trên màn hình.
    func testTerminalGuardBackspaceBypass() {
        let t = ScreenTerminal()
        t.type("tie61ng")
        XCTAssertEqual(t.line, "tiếng")
        t.bypassBackspace(); t.bypassBackspace(); t.bypassBackspace()
        t.type("e65t ")
        XCTAssertEqual(t.line, "tiệt ")
    }

    /// Ctrl+A không qua bộ gõ: con trỏ về đầu dòng, phím dấu tiếp theo không xoá chữ phía sau.
    func testTerminalGuardLineStartBypass() {
        let t = ScreenTerminal()
        t.type("tie")
        t.bypassLineStart()
        t.type("6")
        XCTAssertEqual(t.line, "6tie")
    }

    /// Terminal.app: ⌫ không qua bộ gõ; gõ tiếp liền tay (sổ phím chưa chắc: "chưa biết" ở mọi phím sau đó). Màn hình cho
    /// thấy đúng từ nằm trước con trỏ thì vẫn thêm dấu được — không phải chờ dừng tay.
    func testTerminalScreenConfirmsWordWhenUnsure() {
        let t = ScreenTerminal()
        t.type("tie61ng", ms: 45)
        XCTAssertEqual(t.line, "tiếng")
        t.bypassBackspace(); t.bypassBackspace(); t.bypassBackspace()
        t.type("e", ms: 45, gap: .unsure)                  // phím đầu sau ⌫: có phím chưa thấy mới
        t.type("65t ", ms: 45, gap: .unsureSteady)         // không có gì mới kể từ phím trước
        XCTAssertEqual(t.line, "tiệt ")
        // Mũi tên trái (không qua bộ gõ) rồi gõ liền: màn hình không khớp → bỏ từ, không xoá gì.
        let u = ScreenTerminal()
        u.type("tie", ms: 45)
        u.bypassLeft()
        u.type("6", ms: 45, gap: .unsure)
        XCTAssertEqual(u.line, "ti6e")
        // ← chưa được shell in lại (màn hình còn cũ, vẫn "khớp"): phím ngay sau đó có phím chưa thấy mới → không tin màn
        // hình, không xoá gì (DEL sẽ rơi vào chỗ con trỏ mới).
        let v = ScreenTerminal()
        v.type("tie", ms: 45)
        v.bypassLeftNotEchoed()
        v.type("6", ms: 2, echoes: false, gap: .unsure)
        v.echo()
        XCTAssertEqual(v.line, "ti6e")
    }

    /// iTerm2 / Terminal.app: ứng dụng treo rồi các phím tới dồn (shell chưa kịp in lại phím nào): sổ phím "chưa biết"
    /// cho tới phím cuối — màn hình lệch chỉ vì chưa in kịp, không được bỏ từ; phím cuối (sạch) sửa cả từ một lần.
    func testTerminalScreenLagDuringStallBurst() {
        let t = ScreenTerminal()
        t.type("Vi", ms: 120)
        t.type("e6", ms: 0.3, echoes: false, gap: .unsure)
        t.type("5", ms: 0.3, echoes: false, gap: .unsure)
        t.type("t", ms: 0.3, echoes: false, gap: .none)
        t.echo()
        t.type(" Nam", ms: 120)
        XCTAssertEqual(t.line, "Việt Nam")
    }

    /// Ghostty: Enter / Ctrl+E bấm khi lần sửa dấu còn chờ (vài ms sau phím dấu): gửi kèm lần sửa trong một lần ghi —
    /// Ghostty không nuốt phím, thứ tự đúng.
    func testGhosttyPendingEditCarriesControlKeys() {
        let g = GhosttySim()
        g.options = EngineOptions(method: .vni)
        g.type("echo to")
        g.press(.char("6"), gap: 0.001)
        g.press(.enter)
        XCTAssertEqual(g.text, "echo tô")
        XCTAssertEqual(g.controls, ["\r"])
        let h = GhosttySim()
        h.options = EngineOptions(method: .vni)
        h.type("echo to")
        h.press(.char("6"), gap: 0.001)
        h.press(.ctrlE)                                     // ⌃ của chính phím này: sổ phím vẫn báo sạch
        XCTAssertEqual(h.text, "echo tô")
        XCTAssertEqual(h.controls, ["\u{05}"])
        XCTAssertTrue(h.mark.isEmpty)
    }

    /// Ghostty (không đọc được màn hình): click dời con trỏ ở dấu nhắc fish (bộ gõ thấy qua trạng thái nút chuột: phím sau
    /// nhận `.bypassed`): bỏ từ cũ, phím này bắt đầu từ mới — không gửi DEL nào theo từ cũ.
    func testGhosttyBypassStartsFreshWord() {
        let g = GhosttySim()
        g.options = EngineOptions(method: .vni)
        g.type("echo tie")
        g.press(.char("6"), ledger: .bypassed)
        XCTAssertEqual(g.text, "echo tie6")
        g.type(" to6i")
        XCTAssertEqual(g.text, "echo tie6 tôi")
    }

    /// Ghostty: từ có phím đi nguyên văn lúc chưa chắc rồi Enter (đã chắc): sửa cả từ cùng Enter trong keyDown — Ghostty
    /// ghi chữ của phím Enter mở đầu bằng ký tự thường.
    func testGhosttyUnsureWordFixedWithEnter() {
        let g = GhosttySim()
        g.options = EngineOptions(method: .vni)
        g.type("echo to")
        g.press(.char("6"), ledger: .unsure)
        g.press(.enter)
        XCTAssertEqual(g.text, "echo tô")
        XCTAssertEqual(g.controls, ["\r"])
    }

    /// Ghostty: lần sửa còn chờ, người dùng dán (⌘V, đi vòng bộ gõ) rồi bấm Enter: bỏ lần sửa (không xoá chữ dán), gỡ
    /// marked text, Enter vẫn tới shell (gửi kèm ký tự mồi bị xoá ngay: "\r" đứng riêng thì Ghostty bỏ); không kẹt: các phím
    /// sau tới bình thường.
    func testGhosttyStaleEditDroppedNoStuckMark() {
        let g = GhosttySim()
        g.options = EngineOptions(method: .vni)
        g.type("tie")
        g.press(.char("6"), gap: 0.001)
        g.bypassPaste("/tmp")
        g.press(.enter, ledger: .interrupted)
        XCTAssertEqual(g.text, "tie/tmp")
        XCTAssertTrue(g.mark.isEmpty)
        XCTAssertEqual(g.controls, ["\r"])
        g.press(.enter)
        g.press(.up)
        XCTAssertEqual(g.controls, ["\r", "\r", "\u{1b}[A"])
        // phím chữ thì tự gửi
        let h = GhosttySim()
        h.options = EngineOptions(method: .vni)
        h.type("tie")
        h.press(.char("6"), gap: 0.001)
        h.bypassPaste("/tmp")
        h.press(.char("x"), ledger: .interrupted)
        XCTAssertEqual(h.text, "tie/tmpx")
        XCTAssertTrue(h.mark.isEmpty)
        // ⌫ cũng tới shell: xoá ký tự cuối của chữ dán
        let b = GhosttySim()
        b.options = EngineOptions(method: .vni)
        b.type("tie")
        b.press(.char("6"), gap: 0.001)
        b.bypassPaste("/tmp")
        b.press(.backspace, ledger: .interrupted)
        XCTAssertEqual(b.text, "tie/tm")
        XCTAssertTrue(b.mark.isEmpty)
    }

    /// Ghostty: từ không phải tiếng Việt kết thúc bằng Enter (sổ phím sạch) vẫn được khôi phục — "nvm use", không phải
    /// "nvm úe" — trong cùng lần ghi với Enter.
    func testGhosttyEnterRestoresWord() {
        let g = GhosttySim()
        g.options = EngineOptions(method: .telex)
        g.type("nvm use")
        g.press(.enter)
        XCTAssertEqual(g.text, "nvm use")
        XCTAssertEqual(g.controls, ["\r"])
        XCTAssertTrue(g.mark.isEmpty)
    }

    /// Shell chưa kịp in lại chữ vừa gõ (gõ nhanh, ssh): con trỏ đứng sau là bình thường, vẫn thêm dấu đúng.
    func testTerminalGuardEchoLag() {
        let t = ScreenTerminal()
        t.type("tie6", ms: 30, echoes: false)
        t.echo()
        XCTAssertEqual(t.line, "tiê")
        let u = ScreenTerminal()
        u.type("Vie65t Nam to6i", ms: 20, echoes: false)
        u.echo()
        XCTAssertEqual(u.line, "Việt Nam tôi")
    }

    /// iTerm2/Terminal.app, sổ phím chứng minh không có phím nào đi vòng: màn hình lệch chỉ vì shell chưa in lại. fish
    /// hiện gợi ý "n" sau con trỏ; gõ "n" rồi "1" ngay (shell chưa in "n"): không được hiểu nhầm là con trỏ nằm giữa từ
    /// "tiê|n" (DEL sẽ xoá chữ "n" vừa gõ, ra "tiêế").
    func testTerminalGuardFishSuggestionWithEchoLag() {
        let t = ScreenTerminal()
        t.type("tie6")
        t.cells.append("n")                     // gợi ý của fish, sau con trỏ
        t.type("n", ms: 2, echoes: false)
        t.type("1", ms: 2, echoes: false)
        t.echo()
        XCTAssertEqual(String(t.cells[..<t.cursor]), "tiến")
    }

    /// Gõ bình thường (shell in lại ngay): kết quả như không có kiểm tra con trỏ.
    func testTerminalGuardNormalTyping() {
        let t = ScreenTerminal()
        t.type("To6i ye6u tie61ng Vie65t, d9e5p la81m!")
        XCTAssertEqual(t.line, "Tôi yêu tiếng Việt, đẹp lắm!")
    }
}
