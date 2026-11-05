// Ô nhập liệu Cocoa (NSTextView) cho IME Lab — chỉ chạy trên máy ảo CI.
//   field <file>: ghi nội dung ô ra <file> mỗi khi đổi; <file>.ready khi ô đã sẵn sàng nhận phím.
//   field <file> --blind: thay NSTextView bằng một view tự vẽ như view terminal của GPUI (Herdr, Zed) / ứng dụng Rust: không
//   khai báo thuộc tính marked text, con trỏ báo bằng độ dài marked text (0 khi không gõ dở), insertText bỏ qua vùng thay và
//   ghi chữ vào dòng như shell (DEL xoá lùi) — GTV chưa biết ứng dụng này: phải gõ đúng mà không từ nào đi nguyên văn.
// Mỗi lần ứng dụng bị rời đi (lab chuyển sang Finder rồi mở lại) thì xoá chữ, như bảng tìm kiếm kiểu
// TinyCast / Spotlight: lab gõ ngay khi cửa sổ vừa hiện (phím đầu có thể tới trước lời gọi setValue của InputMethodKit).
import Cocoa

let blindMode = CommandLine.arguments.contains("--blind")

/// View tự vẽ "mù con trỏ" (xem đầu file). Văn bản là một dòng lệnh: `line` + vị trí `cursor`.
final class BlindView: NSView, NSTextInputClient {
    var line: [Character] = []
    var cursor = 0
    var marked = ""
    var changed: () -> Void = {}

    override var acceptsFirstResponder: Bool { true }

    var text: String { String(line) }

    func write(_ s: String) {
        for ch in s {
            switch ch {
            case "\u{7f}": if cursor > 0 { line.remove(at: cursor - 1); cursor -= 1 }
            case "\r", "\n": line.insert("\n", at: cursor); cursor += 1
            default:
                guard ch.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { continue }
                line.insert(ch, at: cursor); cursor += 1
            }
        }
        changed()
    }

    override func keyDown(with event: NSEvent) {
        if inputContext?.handleEvent(event) == true { return }
        switch event.keyCode {
        case 51: write("\u{7f}")
        case 123: cursor = max(0, cursor - 1)
        case 124: cursor = min(line.count, cursor + 1)
        case 36, 76: write("\n")
        default: if let s = event.characters { write(s) }
        }
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(deleteBackward(_:)): write("\u{7f}")
        case #selector(moveLeft(_:)): cursor = max(0, cursor - 1)
        case #selector(moveRight(_:)): cursor = min(line.count, cursor + 1)
        case #selector(insertNewline(_:)): write("\n")
        default: break
        }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        marked = ""
        write((string as? NSAttributedString)?.string ?? (string as? String) ?? "")
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        needsDisplay = true
    }
    func unmarkText() { marked = "" }
    func selectedRange() -> NSRange { NSRange(location: marked.utf16.count, length: 0) }
    func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count) }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let units = Array(marked.utf16)
        let lo = min(range.location, units.count), hi = min(range.location + range.length, units.count)
        actualRange?.pointee = NSRange(location: lo, length: hi - lo)
        return NSAttributedString(string: String(decoding: units[lo..<hi], as: UTF16.self))
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(NSRect(x: 10, y: 10, width: 10, height: 20), to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        (text + marked).draw(at: NSPoint(x: 10, y: 10), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
    }
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let ready = URL(fileURLWithPath: CommandLine.arguments[1] + ".ready")
/// Lab tạo file này để xoá chữ trong ô (không dùng phím tắt: đó cũng là thứ cần kiểm tra).
let clear = URL(fileURLWithPath: CommandLine.arguments[1] + ".clear")

final class Delegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    var window: NSWindow!
    var text: NSTextView!
    var blind: BlindView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 240, y: 360, width: 640, height: 160),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "GTV Lab field"
        text = NSTextView(frame: window.contentView!.bounds)
        text.autoresizingMask = [.width, .height]
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.font = NSFont.systemFont(ofSize: 18)
        text.delegate = self
        window.contentView!.addSubview(text)
        if blindMode {
            let v = BlindView(frame: window.contentView!.bounds)
            v.autoresizingMask = [.width, .height]
            v.changed = { [weak self, weak v] in v?.needsDisplay = true; self?.dump() }
            text.removeFromSuperview()
            window.contentView!.addSubview(v)
            blind = v
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(blind ?? text)
        NSApp.mainMenu = Self.menu()
        NSApp.activate(ignoringOtherApps: true)
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, FileManager.default.fileExists(atPath: clear.path) else { return }
            try? FileManager.default.removeItem(at: clear)
            self.text.string = ""
            self.blind?.line = []
            self.blind?.cursor = 0
            self.blind?.marked = ""
            self.dump()
        }
    }

    /// Menu Edit để ⌘A / ⌘C / ⌘V chạy như ứng dụng thật (phím tắt qua menu: bộ gõ không thấy).
    static func menu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = edit
        return main
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(blind ?? text)
        try? "ready".write(to: ready, atomically: true, encoding: .utf8)
    }

    /// Xoá chữ lúc rời đi (không phải lúc quay lại: phím gõ ngay khi vừa kích hoạt không được bị xoá theo).
    func applicationDidResignActive(_ notification: Notification) {
        try? FileManager.default.removeItem(at: ready)
        text.string = ""
        blind?.line = []
        blind?.cursor = 0
        blind?.marked = ""
        dump()
    }

    func textDidChange(_ notification: Notification) { dump() }

    func dump() { try? (blind?.text ?? text.string).write(to: out, atomically: true, encoding: .utf8) }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
