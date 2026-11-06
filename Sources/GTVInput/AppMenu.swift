import AppKit
import UniformTypeIdentifiers

/// Menu cài đặt, dùng cho cả biểu tượng V/E trên thanh menu và menu bộ gõ của macOS.
enum AppMenu {
    private enum Tag: Int {
        case enabled = 1
        case telex = 10, vni, simpleTelex
        case unicode = 20, combining, tcvn3
        case modernTone = 30, autoRestore
        case markedApp = 40, markedAlways
        case hotkey = 50   // 50 + ToggleHotkey.rawValue
        case excludeCurrent = 60, addExcluded
        case showStatusIcon = 70, playSwitchSound, selectAtLogin, checkForUpdates, autoCheckUpdates, grantAccessibility
        case quit = 99
        case removeExcluded = 1000   // 1000 + vị trí trong `shownExcluded`
    }

    /// Danh sách loại trừ theo đúng thứ tự đã hiện ở lần dựng menu gần nhất (tag của mục = vị trí trong danh sách này).
    /// Không sắp lại lúc bấm: tên dùng để sắp đổi theo ứng dụng có đang chạy không (vd. "Code" / "Visual Studio Code"),
    /// sắp lại có thể ra thứ tự khác và bỏ loại trừ nhầm ứng dụng.
    private static var shownExcluded: [String] = []

    /// `standalone`: menu của biểu tượng V/E trên thanh menu (dùng menu con).
    /// Menu bộ gõ của macOS được chép sang tiến trình khác để hiển thị: chỉ dựa vào `tag`
    /// (representedObject có thể mất) và trải phẳng các nhóm thay vì dùng menu con.
    static func build(target: AnyObject, action: Selector, appBundleID: String, standalone: Bool) -> NSMenu {
        let s = Settings.shared
        let o = s.options
        let menu = NSMenu()

        // Tên ứng dụng: tra một lần cho mỗi ứng dụng mỗi lần dựng menu, từ một ảnh chụp danh sách ứng dụng đang chạy (tra
        // ngay trong hàm so sánh khi sắp xếp là O(n log n) lần quét tiến trình và hỏi LaunchServices).
        var running: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, running[id] == nil { running[id] = app }
        }
        var names: [String: String] = [:]
        func appName(_ id: String) -> String {
            if let name = names[id] { return name }
            let name = running[id]?.localizedName ?? AppMenu.fileName(id)
            names[id] = name
            return name
        }

        func item(_ title: String, _ tag: Int, _ on: Bool, indent: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.tag = tag
            item.state = on ? .on : .off
            if indent { item.indentationLevel = 1 }
            return item
        }
        func add(_ title: String, _ tag: Tag, _ on: Bool, indent: Bool = false) {
            menu.addItem(item(title, tag.rawValue, on, indent: indent))
        }
        func header(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        /// Nhóm mục: menu con (`submenu`), hoặc tiêu đề + các mục thụt lề.
        func group(_ title: String, _ items: [NSMenuItem], submenu: Bool) {
            if submenu {
                let sub = NSMenu()
                items.forEach { $0.indentationLevel = 0; sub.addItem($0) }
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                parent.submenu = sub
                menu.addItem(parent)
            } else {
                header(title)
                items.forEach { $0.indentationLevel = 1; menu.addItem($0) }
            }
        }

        // Phiên bản: dòng mờ ngay dưới tiêu đề "GTV" của menu bộ gõ. (Không gắn vào tên bộ gõ vì macOS
        // giữ tên trong bộ đệm tới khi đăng xuất, sau mỗi lần cập nhật sẽ hiện phiên bản cũ.)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        header("Phiên bản \(version)")
        if Updater.shared.isAvailable {
            // Bản mới tìm thấy lúc người dùng đang gõ: Sparkle không giành focus, chỉ nhắc ở đây.
            add(Updater.shared.pendingVersion.map { "Có bản mới \($0): cài đặt…" } ?? "Kiểm tra cập nhật…",
                .checkForUpdates, false)
        }

        if !SyntheticKeys.shared.available {
            // Java (Burp…), Qt 5, GTK, LibreOffice… chỉ sửa được chữ bằng phím ⌫ giả, cần quyền Trợ năng; chưa có thì các ứng
            // dụng đó gõ bằng gạch chân.
            add("Gõ không gạch chân trong Java, Qt 5, GTK…: cấp quyền Trợ năng…", .grantAccessibility, false)
        }

        let hint = s.hotkey == .none ? "" : "   (\(s.hotkey.title.prefix(2)))"
        add("Gõ tiếng Việt" + hint, .enabled, Modes.shared.vietnamese && InputSources.isGTVSelected)
        menu.addItem(.separator())
        header("Kiểu gõ")
        add("Telex", .telex, o.method == .telex, indent: true)
        add("VNI", .vni, o.method == .vni, indent: true)
        add("Telex đơn giản", .simpleTelex, o.method == .simpleTelex, indent: true)
        menu.addItem(.separator())
        header("Bảng mã")
        add("Unicode dựng sẵn", .unicode, o.charset == .unicode, indent: true)
        add("Unicode tổ hợp", .combining, o.charset == .unicodeCombining, indent: true)
        add("TCVN3 (ABC)", .tcvn3, o.charset == .tcvn3, indent: true)
        menu.addItem(.separator())
        add("Đặt dấu kiểu mới (hoà, thuý)", .modernTone, o.modernToneStyle)
        add("Tự khôi phục từ không phải tiếng Việt", .autoRestore, o.autoRestore)
        menu.addItem(.separator())
        group("Phím chuyển Anh/Việt", ToggleHotkey.menuOrder.map {
            item($0.title, Tag.hotkey.rawValue + $0.rawValue, s.hotkey == $0)
        }, submenu: standalone)
        add("Phát âm thanh khi chuyển Anh/Việt", .playSwitchSound, s.playSwitchSound)

        menu.addItem(.separator())
        if !appBundleID.isEmpty {
            // Ghi luôn ứng dụng vào mục menu: lúc bấm, ứng dụng "đang ở trước" có thể đã khác.
            let i = item("Không gõ tiếng Việt trong \(appName(appBundleID))", Tag.excludeCurrent.rawValue,
                         s.excludedApps.contains(appBundleID))
            i.representedObject = appBundleID
            menu.addItem(i)
        }
        shownExcluded = s.excludedApps.map { ($0, appName($0)) }
            .sorted {
                let order = $0.1.localizedCaseInsensitiveCompare($1.1)
                return order == .orderedSame ? $0.0 < $1.0 : order == .orderedAscending
            }
            .map(\.0)
        var excludedItems: [NSMenuItem] = shownExcluded.enumerated().map { index, id in
            let i = item(appName(id), Tag.removeExcluded.rawValue + index, true)
            i.toolTip = "Bấm để gõ tiếng Việt lại trong ứng dụng này"
            i.image = appIcon(id)
            i.representedObject = id
            return i
        }
        if !excludedItems.isEmpty { excludedItems.append(.separator()) }
        excludedItems.append(item("Thêm ứng dụng…", Tag.addExcluded.rawValue, false))
        group("Ứng dụng không gõ tiếng Việt (\(s.excludedApps.count))", excludedItems, submenu: true)

        menu.addItem(.separator())
        if !appBundleID.isEmpty {
            let terminal = Settings.knownTerminals.contains(appBundleID)
            let i = item(terminal ? "Gạch chân khi gõ trong \(appName(appBundleID))"
                                  : "Dùng gạch chân cho \(appName(appBundleID))",
                         Tag.markedApp.rawValue, s.useMarked(for: appBundleID) && !s.alwaysMarked)
            if terminal {
                i.toolTip = "Mặc định GTV gõ thẳng xuống shell, không gạch chân. Bật nếu terminal này gõ sai."
            }
            i.representedObject = appBundleID
            menu.addItem(i)
        }
        add("Luôn dùng gạch chân (tương thích tối đa)", .markedAlways, s.alwaysMarked)

        menu.addItem(.separator())
        // Mục đăng nhập dùng SMAppService (macOS 13+), do GTV.app trong Applications đăng ký.
        if #available(macOS 13.0, *) {
            if let launcher = Settings.launcherURL(), Settings.isInApplications(launcher) {
                let i = item("Chọn GTV khi đăng nhập", Tag.selectAtLogin.rawValue, s.selectsAtLogin)
                if s.selectAtLogin && s.loginItemStatus == "requiresApproval" {
                    i.toolTip = "GTV đang bị tắt trong Cài đặt hệ thống → Cài đặt chung → Mục đăng nhập. Bấm để mở và bật lại."
                }
                menu.addItem(i)
            } else {
                header("Chọn GTV khi đăng nhập: cần GTV trong Applications")
            }
        }
        if Updater.shared.isAvailable {
            add("Tự động kiểm tra cập nhật", .autoCheckUpdates, Updater.shared.automaticallyChecks)
        }
        add("Hiện biểu tượng GTV trên thanh menu", .showStatusIcon, s.showStatusIcon)
        add("Thoát GTV", .quit, false)
        return menu
    }

    static func perform(_ item: NSMenuItem, appBundleID fallbackAppID: String) {
        let s = Settings.shared
        let appBundleID = item.representedObject as? String ?? fallbackAppID
        if item.tag >= Tag.removeExcluded.rawValue {
            let index = item.tag - Tag.removeExcluded.rawValue
            let shown = shownExcluded.indices.contains(index) ? shownExcluded[index] : nil
            if let id = item.representedObject as? String ?? shown { s.setExcluded([id], false) }
            return
        }
        if let hotkey = ToggleHotkey(rawValue: item.tag - Tag.hotkey.rawValue),
           item.tag >= Tag.hotkey.rawValue, item.tag < Tag.hotkey.rawValue + ToggleHotkey.allCases.count {
            s.hotkey = hotkey
            return
        }
        guard let tag = Tag(rawValue: item.tag) else { return }
        switch tag {
        case .enabled:
            Modes.shared.toggle()
        case .telex: s.update { $0.method = .telex }
        case .vni: s.update { $0.method = .vni }
        case .simpleTelex: s.update { $0.method = .simpleTelex }
        case .unicode: s.update { $0.charset = .unicode }
        case .combining: s.update { $0.charset = .unicodeCombining }
        case .tcvn3: s.update { $0.charset = .tcvn3 }
        case .modernTone: s.update { $0.modernToneStyle.toggle() }
        case .autoRestore: s.update { $0.autoRestore.toggle() }
        case .grantAccessibility:
            _ = CGRequestPostEventAccess()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        case .markedApp: s.toggleMarked(for: appBundleID)
        case .markedAlways: s.alwaysMarked.toggle()
        case .hotkey, .removeExcluded: break
        case .excludeCurrent:
            s.setExcluded([appBundleID], !s.excludedApps.contains(appBundleID))
        case .addExcluded:
            // Đợi menu đóng hẳn rồi mới mở hộp thoại.
            DispatchQueue.main.async { chooseAppsToExclude() }
        case .showStatusIcon:
            s.showStatusIcon.toggle()
        case .playSwitchSound:
            s.playSwitchSound.toggle()
        case .selectAtLogin:
            // Theo dấu tích đang hiện (trạng thái thật), không theo cài đặt: người dùng tắt GTV trong Cài đặt hệ thống thì
            // mục hiện tắt, bấm vào là muốn bật lại.
            s.selectAtLogin = !s.selectsAtLogin
        case .checkForUpdates:
            // Đợi menu đóng hẳn rồi mới mở cửa sổ của Sparkle.
            DispatchQueue.main.async { Updater.shared.checkForUpdates() }
        case .autoCheckUpdates:
            Updater.shared.automaticallyChecks.toggle()
        case .quit:
            InputSources.selectSystemKeyboard()
            NSApp.terminate(nil)
        }
    }

    /// Không dùng runModal: tiến trình này còn là bộ gõ, chặn vòng lặp chính sẽ làm treo việc gõ phím.
    private static func chooseAppsToExclude() {
        let panel = NSOpenPanel()
        panel.title = "Chọn ứng dụng không gõ tiếng Việt"
        panel.prompt = "Thêm"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.level = .floating
        panel.begin { response in
            guard response == .OK else { return }
            let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            Settings.shared.setExcluded(ids, true)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private static var iconCache: [String: NSImage] = [:]

    /// Icon ứng dụng 16×16 dạng ảnh bitmap (@1x, @2x). Menu bộ gõ của macOS được chép sang tiến
    /// trình khác để hiển thị; icon hệ thống (IconRef) từ NSWorkspace không chép qua được nên bị mất.
    private static func appIcon(_ bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let source = NSWorkspace.shared.icon(forFile: url.path)
        let image = NSImage(size: NSSize(width: 16, height: 16))
        for scale in [1, 2] {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16 * scale, pixelsHigh: 16 * scale,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = NSSize(width: 16, height: 16)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        iconCache[bundleID] = image
        return image
    }

    /// Tên ứng dụng không chạy: tên gói .app (ứng dụng đang chạy dùng localizedName, xem `build`).
    private static func fileName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
            .deletingPathExtension().lastPathComponent ?? bundleID
    }
}
