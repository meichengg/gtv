import AppKit

/// Nhận biết bộ công cụ giao diện của ứng dụng để chọn cách gõ hợp (một lần cho mỗi ứng dụng, ở luồng nền):
/// - Qt (Telegram Desktop, OBS…): cách thay riêng khi chuỗi thay vào trùng phím vừa bấm (xem `Session.replace`).
/// - Qt 5 (VLC 3, KeePassXC, Wireshark, VirtualBox 6…): ô luôn báo con trỏ ở 0 và bỏ qua vùng cần thay
///   (qnsview_complextext.mm) — chỉ gõ được bằng marked text.
/// - LibreOffice (VCL): con trỏ luôn báo ở 0 — marked text.
/// - Emacs (bản NS) và MacVim: bỏ qua vùng cần thay — marked text.
/// - GTK 3 / 4 (CherryTree, GIMP, Inkscape 1.x…, gdk/quartz): con trỏ giả, chỉ dùng độ dài vùng thay, mỗi phím chỉ giữ lần chèn
///   chữ cuối cùng — marked text, chữ chốt từ gửi cùng phím kết thúc từ (`combinedCommit`).
/// - winit (egui/eframe, iced, Alacritty…): bỏ chữ chèn khi không có marked text, nuốt phím ngay sau lần chốt — marked text,
///   `combinedCommit`, gỡ marked text sau khi chốt bằng phím không ra chữ.
/// - SwiftTerm (Iruka, ứng dụng SSH / agent nhúng terminal): view terminal bỏ qua vùng thay, con trỏ là chỉ số ô màn hình —
///   marked text nếu không phải terminal đã kiểm chứng (bản mới khai báo thuộc tính như ô văn bản: xem `swiftTermView`).
/// - Flutter: ô văn bản thay đúng vùng, con trỏ thật (FlutterTextInputPlugin là NSTextView) nhưng không khai báo thuộc tính
///   marked text nào — không gõ từ đầu ở ô trống bằng marked text (flutter#194199); terminal xterm.dart thì có.
/// Đọc mã nguồn từng bộ (IME toolkit audit 2026-11-05).
///
/// Dấu hiệu: framework / thư viện trong gói, hoặc chuỗi trong file chạy (Qt liên kết tĩnh như Telegram: tên lớp "QNSView";
/// Qt 5: "qt_version_tag_5"; GTK: đường dẫn thư viện; winit: lớp "WinitView"; SwiftTerm: "_TtC9SwiftTerm12TerminalView").
/// Trong lúc chưa có kết quả thì coi như ứng dụng thường.
enum AppToolkit {
    struct Profile: Equatable, Sendable, CustomStringConvertible {
        var qt = false
        /// Chỉ gõ được bằng marked text (gạch chân).
        var markedOnly = false
        /// Chốt từ đang gạch chân cùng chữ của phím kết thúc từ trong một lần `insertText` (GTK, winit).
        var combinedCommit = false
        /// Sau khi chốt bằng phím không ra chữ (⏎, ⇥, mũi tên…), gỡ marked text để ô không nuốt phím đó (winit).
        var clearAfterCommit = false
        /// Ô báo đúng `hasMarkedText` ngay từ đầu: không còn marked text là ô đã tự chốt / bỏ nó (GTK, winit).
        var trustMarked = false
        var flutter = false
        /// Ứng dụng Flutter có terminal xterm.dart (ô terminal chốt rồi đặt lại về rỗng — gõ bằng marked text).
        var flutterTerminal = false
        var swiftTerm = false
        var gtk = false
        var winit = false

        var description: String {
            "qt=\(qt) gtk=\(gtk) winit=\(winit) markedOnly=\(markedOnly) combined=\(combinedCommit) flutter=\(flutter)/\(flutterTerminal) swiftTerm=\(swiftTerm)"
        }
    }

    private static var cache: [String: Profile] = [:]
    private static var pending: Set<String> = []
    private static let queue = DispatchQueue(label: "gtv.app-toolkit", qos: .utility)

    /// Ứng dụng bỏ qua vùng cần thay, biết qua bundle ID.
    private static let markedBundleIDs: Set<String> = ["org.gnu.Emacs", "org.vim.MacVim"]

    static func isQt(_ bundleID: String) -> Bool { profile(bundleID).qt }

    /// Hồ sơ của ứng dụng; lần đầu thì bắt đầu kiểm tra ở luồng nền và tạm coi như ứng dụng thường.
    static func profile(_ bundleID: String) -> Profile {
        if let known = cache[bundleID] { return known }
        guard !bundleID.isEmpty, !pending.contains(bundleID) else { return Profile() }
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        guard let app else {
            // Không có gói (vd. tiến trình `java` chạy bằng script): nhớ luôn, khỏi tra LaunchServices ở mỗi phím.
            let p = Profile(markedOnly: markedBundleIDs.contains(bundleID))
            cache[bundleID] = p
            return p
        }
        pending.insert(bundleID)
        queue.async {
            let result = detect(app, bundleID: bundleID)
            DispatchQueue.main.async {
                cache[bundleID] = result
                pending.remove(bundleID)
                if result != Profile() { DebugLog.write("\(bundleID): \(result)") }
            }
        }
        return Profile()
    }

    private static func detect(_ app: URL, bundleID: String) -> Profile {
        var p = Profile(markedOnly: markedBundleIDs.contains(bundleID))
        guard let bundle = Bundle(url: app) else { return p }
        let fm = FileManager.default
        let contents = bundle.bundlePath + "/Contents/"
        let frameworks = contents + "Frameworks/"
        if fm.fileExists(atPath: frameworks + "libvcllo.dylib") { p.markedOnly = true }      // LibreOffice
        for name in ["QtCore.framework", "QtGui.framework"] where fm.fileExists(atPath: frameworks + name) {
            p.qt = true
            if fm.fileExists(atPath: frameworks + name + "/Versions/5") { p.markedOnly = true }
        }
        if fm.fileExists(atPath: frameworks + "FlutterMacOS.framework") {
            p.flutter = true
            // Snapshot Dart (AOT) giữ tên gói; bản build --obfuscate thì không thấy (coi như không có terminal).
            p.flutterTerminal = !search(URL(fileURLWithPath: frameworks + "App.framework/App"), for: ["package:xterm/"]).isEmpty
        }
        // GTK đóng gói bằng gtk-mac-bundler để thư viện ở Contents/Resources/lib.
        for dir in [frameworks, contents + "Resources/lib/"] {
            let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            if names.contains(where: { $0.hasPrefix("libgtk-3") || $0.hasPrefix("libgdk-3") || $0.hasPrefix("libgtk-4") }) {
                p.gtk = true
            }
        }
        if fm.fileExists(atPath: frameworks + "SwiftTerm.framework") { p.swiftTerm = true }
        if let exe = bundle.executableURL {
            let found = search(exe, for: ["QNSView", "qt_version_tag_5", "libgtk-3.0", "libgdk-3.0", "libgtk-4.", "WinitView",
                                          "_TtC9SwiftTerm12TerminalView"])
            if !p.qt, found.contains("QNSView") {
                p.qt = true
                if found.contains("qt_version_tag_5") { p.markedOnly = true }
            }
            if !found.isDisjoint(with: ["libgtk-3.0", "libgdk-3.0", "libgtk-4."]) { p.gtk = true }
            if found.contains("WinitView") { p.winit = true }
            if found.contains("_TtC9SwiftTerm12TerminalView") { p.swiftTerm = true }
        }
        if p.gtk || p.winit {
            p.markedOnly = true
            p.combinedCommit = true
            p.trustMarked = true
        }
        if p.winit { p.clearAfterCommit = true }
        return p
    }

    /// Tìm các chuỗi trong file, đọc theo từng khối 4 MB. Không map file vào bộ nhớ: file trên ổ ngoài bị ngắt, hay bị ghi đè
    /// lúc ứng dụng cập nhật, thì map sẽ làm bộ gõ chết vì SIGBUS; đọc thì chỉ ném lỗi.
    private static func search(_ url: URL, for needles: [String]) -> Set<String> {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let patterns = needles.map { ($0, Array($0.utf8)) }
        let overlap = (patterns.map { $0.1.count }.max() ?? 1) - 1
        var found = Set<String>()
        var carry = Data()
        while found.count < patterns.count {
            guard let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty else { break }
            let data = carry + chunk
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                for (name, bytes) in patterns where !found.contains(name) {
                    let hit = bytes.withUnsafeBytes { n in memmem(base, raw.count, n.baseAddress, n.count) != nil }
                    if hit { found.insert(name) }
                }
            }
            carry = data.suffix(overlap)
        }
        return found
    }
}
