// Ô nhập liệu Cocoa (NSTextView) cho IME Lab — chỉ chạy trên máy ảo CI.
//   field <file>: ghi nội dung ô ra <file> mỗi khi đổi; <file>.ready khi ô đã sẵn sàng nhận phím.
// Mỗi lần ứng dụng bị rời đi (lab chuyển sang Finder rồi mở lại) thì xoá chữ, như bảng tìm kiếm kiểu
// TinyCast / Spotlight: lab gõ ngay khi cửa sổ vừa hiện (phím đầu có thể tới trước lời gọi setValue của InputMethodKit).
import Cocoa

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let ready = URL(fileURLWithPath: CommandLine.arguments[1] + ".ready")
/// Lab tạo file này để xoá chữ trong ô (không dùng phím tắt: đó cũng là thứ cần kiểm tra).
let clear = URL(fileURLWithPath: CommandLine.arguments[1] + ".clear")

final class Delegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    var window: NSWindow!
    var text: NSTextView!

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
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        NSApp.mainMenu = Self.menu()
        NSApp.activate(ignoringOtherApps: true)
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, FileManager.default.fileExists(atPath: clear.path) else { return }
            try? FileManager.default.removeItem(at: clear)
            self.text.string = ""
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
        window.makeFirstResponder(text)
        try? "ready".write(to: ready, atomically: true, encoding: .utf8)
    }

    /// Xoá chữ lúc rời đi (không phải lúc quay lại: phím gõ ngay khi vừa kích hoạt không được bị xoá theo).
    func applicationDidResignActive(_ notification: Notification) {
        try? FileManager.default.removeItem(at: ready)
        text.string = ""
        dump()
    }

    func textDidChange(_ notification: Notification) { dump() }

    func dump() { try? text.string.write(to: out, atomically: true, encoding: .utf8) }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
