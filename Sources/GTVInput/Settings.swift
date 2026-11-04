import AppKit
import VietEngine
import notify

extension Notification.Name {
    static let gtvSettingsChanged = Notification.Name("GTVSettingsChanged")
    static let gtvExcludedAppsChanged = Notification.Name("GTVExcludedAppsChanged")
}

/// Phím tắt chuyển Anh/Việt (nhấn rồi nhả tổ hợp phím bổ trợ).
enum ToggleHotkey: Int, CaseIterable {
    case none = 0, controlShift, optionShift, commandShift

    /// Thứ tự hiển thị trong menu.
    static let menuOrder: [ToggleHotkey] = [.commandShift, .controlShift, .optionShift, .none]

    var flags: NSEvent.ModifierFlags? {
        switch self {
        case .none: return nil
        case .controlShift: return [.control, .shift]
        case .optionShift: return [.option, .shift]
        case .commandShift: return [.command, .shift]
        }
    }

    var title: String {
        switch self {
        case .none: return "Không dùng"
        case .controlShift: return "⌃⇧  Control + Shift"
        case .optionShift: return "⌥⇧  Option + Shift"
        case .commandShift: return "⌘⇧  Command + Shift"
        }
    }
}

/// Cài đặt dùng chung cho mọi ô nhập liệu (lưu trong UserDefaults của bộ gõ).
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    /// Ứng dụng mặc định dùng chế độ gạch chân (marked text): các terminal không hỗ trợ
    /// thay thế văn bản đã nhập.
    static let defaultMarkedApps = [
        "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "io.alacritty",
        "com.github.wez.wezterm", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
    ]

    private(set) var options: EngineOptions
    var alwaysMarked: Bool {
        didSet { defaults.set(alwaysMarked, forKey: "alwaysMarked") }
    }
    var hotkey: ToggleHotkey {
        didSet { defaults.set(hotkey.rawValue, forKey: "hotkey"); changed() }
    }
    private(set) var markedApps: Set<String>
    /// Phát âm báo của hệ thống khi người dùng chuyển Anh/Việt (phím tắt, menu).
    var playSwitchSound: Bool {
        didSet { defaults.set(playSwitchSound, forKey: "playSwitchSound") }
    }
    /// GTV.app nằm trong "Mở khi đăng nhập": khi đăng nhập tự chọn GTV nếu đang ở bộ gõ khác.
    var selectAtLogin: Bool {
        didSet {
            defaults.set(selectAtLogin, forKey: "selectAtLogin")
            defaults.synchronize()
            Settings.runLauncher(["--sync-login-item"])
        }
    }

    /// Chạy GTV.app (launcher) với tham số — việc đăng ký "Mở khi đăng nhập" phải do chính GTV.app làm.
    /// Vị trí GTV.app. Ưu tiên bản trong Applications (máy phát triển còn có các bản build khác cùng
    /// bundle ID).
    static func launcherURL() -> URL? {
        let fm = FileManager.default
        let candidates = ["/Applications/GTV.app", fm.homeDirectoryForCurrentUser.path + "/Applications/GTV.app"]
            .map { URL(fileURLWithPath: $0) }.filter { fm.fileExists(atPath: $0.path) }
        return candidates.first ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.gtv.GTV")
    }

    static func runLauncher(_ arguments: [String]) {
        guard let app = launcherURL(), let exe = Bundle(url: app)?.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = arguments
        try? p.run()
    }

    /// Biểu tượng V/E riêng của GTV (mặc định ẩn: menu bộ gõ của macOS đã có đủ).
    var showStatusIcon: Bool {
        didSet { defaults.set(showStatusIcon, forKey: "showStatusIcon"); changed() }
    }
    /// Ứng dụng không gõ tiếng Việt: GTV tự chuyển sang chế độ tiếng Anh (xem Modes).
    private(set) var excludedApps: Set<String>

    private init() {
        defaults.register(defaults: [
            "method": InputMethod.telex.rawValue,
            "charset": Charset.unicode.rawValue,
            "modernToneStyle": false,
            "autoRestore": true,
            "alwaysMarked": false,
            "hotkey": ToggleHotkey.commandShift.rawValue,
            "markedApps": Settings.defaultMarkedApps,
            "excludedApps": [String](),
            "showStatusIcon": false,
            "playSwitchSound": true,
            "selectAtLogin": true,
        ])
        alwaysMarked = defaults.bool(forKey: "alwaysMarked")
        hotkey = ToggleHotkey(rawValue: defaults.integer(forKey: "hotkey")) ?? .commandShift
        markedApps = Set(defaults.stringArray(forKey: "markedApps") ?? [])
        underlineTerminals = Set(defaults.stringArray(forKey: "underlineTerminals") ?? [])
        showStatusIcon = defaults.bool(forKey: "showStatusIcon")
        playSwitchSound = defaults.bool(forKey: "playSwitchSound")
        selectAtLogin = defaults.bool(forKey: "selectAtLogin")
        excludedApps = Set(defaults.stringArray(forKey: "excludedApps") ?? [])
        options = EngineOptions(
            method: InputMethod(rawValue: defaults.integer(forKey: "method")) ?? .telex,
            charset: Charset(rawValue: defaults.integer(forKey: "charset")) ?? .unicode,
            modernToneStyle: defaults.bool(forKey: "modernToneStyle"),
            autoRestore: defaults.bool(forKey: "autoRestore"))
        #if DEBUG
        // IME Lab: `defaults write …` rồi `notifyutil -p com.gtv.lab.reload` để đổi cài đặt mà không phải
        // tắt bộ gõ.
        var token: Int32 = 0
        notify_register_dispatch("com.gtv.lab.reload", &token, .main) { _ in Settings.shared.reloadForLab() }
        #endif
    }

    #if DEBUG
    private func reloadForLab() {
        defaults.synchronize()
        alwaysMarked = defaults.bool(forKey: "alwaysMarked")
        markedApps = Set(defaults.stringArray(forKey: "markedApps") ?? [])
        underlineTerminals = Set(defaults.stringArray(forKey: "underlineTerminals") ?? [])
        excludedApps = Set(defaults.stringArray(forKey: "excludedApps") ?? [])
        options = EngineOptions(
            method: InputMethod(rawValue: defaults.integer(forKey: "method")) ?? .telex,
            charset: Charset(rawValue: defaults.integer(forKey: "charset")) ?? .unicode,
            modernToneStyle: defaults.bool(forKey: "modernToneStyle"),
            autoRestore: defaults.bool(forKey: "autoRestore"))
        Session.deferDelay = defaults.object(forKey: "deferDelayMs") == nil
            ? Session.defaultDeferDelay : defaults.double(forKey: "deferDelayMs") / 1000
        DebugLog.write("lab: nạp lại cài đặt, method=\(options.method), terminalStyle=\(terminalMode), markedApps=\(markedApps.count), deferDelay=\(Session.deferDelay)")
    }
    #endif

    private func changed() {
        NotificationCenter.default.post(name: .gtvSettingsChanged, object: nil)
    }

    func update(_ change: (inout EngineOptions) -> Void) {
        change(&options)
        defaults.set(options.method.rawValue, forKey: "method")
        defaults.set(options.charset.rawValue, forKey: "charset")
        defaults.set(options.modernToneStyle, forKey: "modernToneStyle")
        defaults.set(options.autoRestore, forKey: "autoRestore")
    }

    /// Gạch chân (marked text): bật cho mọi ứng dụng, cho ứng dụng thường người dùng chọn (`markedApps`), hoặc
    /// cho terminal người dùng muốn gạch chân (`underlineTerminals`). Với terminal, `markedApps` (danh sách
    /// mặc định cũ) không còn tác dụng: terminal gõ thẳng không gạch chân, xem `terminalStyle(for:)`.
    func useMarked(for bundleID: String) -> Bool {
        if alwaysMarked { return true }
        return Self.knownTerminals.contains(bundleID) ? underlineTerminals.contains(bundleID) : markedApps.contains(bundleID)
    }

    /// Terminal đã kiểm chứng (IME Lab trên máy macOS thật và/hoặc đọc mã nguồn): gõ thẳng xuống shell, không
    /// gạch chân (xem `Session.handleTerminal`). Chỉ dùng cho terminal đã kiểm chứng: ở ứng dụng khác (vd. trình
    /// soạn thảo, hay terminal có ô nhập liệu riêng như Warp), ký tự xoá DEL sẽ thành chữ rác.
    static let knownTerminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.superlogical.rex",
        "com.muxy.app", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
    ]

    /// Mọi terminal (kể cả terminal chưa kiểm chứng, chỉ dùng gạch chân): khi gõ có gạch chân thì chốt sớm phần
    /// không còn đổi được để shell thấy chữ ngay (xem `Session.handle(earlyCommit:)`).
    static let terminalApps: Set<String> = knownTerminals.union(defaultMarkedApps)
        .union(["co.zeit.hyper", "org.tabby", "dev.warp.Warp-Preview"])

    /// Terminal có ô văn bản (thanh Find) mà khi gõ vào bộ gõ không được gắn lại (không có `activateServer`), nên không
    /// phân biệt được qua thuộc tính marked text; view terminal của chúng luôn báo con trỏ ở 0 (IME Lab, Muxy 2.3), ô văn
    /// bản thì báo vị trí thật.
    static let cursorlessTerminals: Set<String> = ["com.muxy.app"]

    /// Terminal tự xử lý phím lặp (giữ phím) mà không qua bộ gõ, và không cho biết vị trí con trỏ.
    static let repeatBypassTerminals: Set<String> = ["com.superlogical.rex", "com.muxy.app"]

    /// Thời gian giữ phím trước khi phím bắt đầu lặp (cài đặt bàn phím của macOS; đơn vị 15 ms).
    var keyRepeatDelay: Double {
        let v = UserDefaults.standard.double(forKey: "InitialKeyRepeat")
        return v > 0 ? v * 0.015 : 0.25
    }

    /// Terminal người dùng muốn gõ có gạch chân (như trước) thay vì gõ thẳng.
    private(set) var underlineTerminals: Set<String>

    /// Cách gõ trong terminal: nil nếu không phải terminal đã biết hoặc đang dùng gạch chân.
    func terminalStyle(for bundleID: String) -> TerminalStyle? {
        guard Self.knownTerminals.contains(bundleID), !useMarked(for: bundleID) else { return nil }
        switch terminalMode {
        case "marked", "direct": return nil
        case let mode: return TerminalStyle(rawValue: mode) ?? Self.defaultTerminalStyle(for: bundleID)
        }
    }

    /// Ghi đè cách gõ trong terminal (để thử nghiệm, IME Lab): "auto" (mặc định), "inline", "inlineBare",
    /// "deferred", "marked" (gạch chân), "direct" (thay chữ như ứng dụng thường).
    var terminalMode: String { defaults.string(forKey: "terminalStyle") ?? "auto" }

    /// Ghostty: trong keyDown bỏ chữ có ký tự điều khiển khi shell bật kitty keyboard protocol, nên dùng kiểu
    /// `.deferred`; terminal khác (kể cả Rex — Rex vẽ marked text rỗng thành một ô gạch chân) ghi nguyên chuỗi
    /// `.inline` một lần.
    static let ghosttyLikeTerminals: Set<String> = ["com.mitchellh.ghostty"]

    static func defaultTerminalStyle(for bundleID: String) -> TerminalStyle {
        ghosttyLikeTerminals.contains(bundleID) ? .deferred : .inline
    }

    func toggleMarked(for bundleID: String) {
        guard !bundleID.isEmpty else { return }
        if Self.knownTerminals.contains(bundleID) {
            if underlineTerminals.contains(bundleID) { underlineTerminals.remove(bundleID) } else { underlineTerminals.insert(bundleID) }
            defaults.set(underlineTerminals.sorted(), forKey: "underlineTerminals")
            return
        }
        if markedApps.contains(bundleID) { markedApps.remove(bundleID) } else { markedApps.insert(bundleID) }
        defaults.set(markedApps.sorted(), forKey: "markedApps")
    }

    func setExcluded(_ bundleIDs: [String], _ excluded: Bool) {
        for id in bundleIDs where !id.isEmpty {
            if excluded { excludedApps.insert(id) } else { excludedApps.remove(id) }
        }
        defaults.set(excludedApps.sorted(), forKey: "excludedApps")
        NotificationCenter.default.post(name: .gtvExcludedAppsChanged, object: nil)
    }
}
