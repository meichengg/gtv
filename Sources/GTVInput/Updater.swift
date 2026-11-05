import AppKit
import Sparkle

/// Tự động cập nhật bằng Sparkle.
///
/// Chạy trong tiến trình bộ gõ (luôn chạy ngầm, nên kiểm tra định kỳ được) nhưng cập nhật
/// **GTV.app** trong Applications: GTV.app là bundle chứa cấu hình Sparkle (SUFeedURL, SUPublicEDKey)
/// và là bundle được thay khi cài bản mới. Cài xong, bộ gõ chạy GTV.app; GTV.app cập nhật bộ gõ
/// tại chỗ như mọi lần mở.
///
/// Thông tin bản mới: `appcast.xml` đính kèm release mới nhất trên GitHub (workflow Release tạo và ký
/// bằng khoá EdDSA).
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    private var updater: SPUUpdater?
    private var userDriver: SPUStandardUserDriver?
    private var hostURL: URL?
    /// Đang đợi người dùng ngừng gõ để chạy GTV.app cập nhật bộ gõ.
    private var syncPending = false
    /// Bản mới Sparkle tìm thấy mà người dùng chưa xem: menu đổi "Kiểm tra cập nhật…" thành lời nhắc.
    private(set) var pendingVersion: String?

    var isAvailable: Bool { updater != nil }

    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    func start() {
        // Không cập nhật được bản chạy thẳng từ DMG (ổ chỉ đọc) hay bị App Translocation.
        guard let appURL = Settings.launcherURL(), !Self.isTemporaryLocation(appURL), let host = Bundle(url: appURL) else {
            DebugLog.write("Sparkle: không có GTV.app phù hợp để cập nhật")
            return
        }
        hostURL = appURL
        syncInputMethodIfNeeded()
        // GTV.app đời cũ chưa có cấu hình Sparkle.
        guard host.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            DebugLog.write("Sparkle: \(appURL.path) không có SUFeedURL")
            return
        }
        let driver = SPUStandardUserDriver(hostBundle: host, delegate: self)
        let updater = SPUUpdater(hostBundle: host, applicationBundle: host, userDriver: driver, delegate: self)
        do {
            try updater.start()
            self.userDriver = driver
            self.updater = updater
            DebugLog.write("Sparkle: đã khởi động cho \(appURL.path), phiên bản \(host.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?")")
        } catch {
            DebugLog.write("Sparkle: không khởi động được: \(error.localizedDescription)")
        }
    }

    /// Ổ chỉ đọc (DMG) hay đường dẫn tạm của App Translocation. (Ổ ngoài ghi được, vd. /Volumes/…/Applications, vẫn cập nhật
    /// được.)
    static func isTemporaryLocation(_ url: URL) -> Bool {
        if url.path.contains("/AppTranslocation/") { return true }
        return (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
    }

    /// Thời điểm build của một bản bộ gõ (giây UTC), đọc mới trên đĩa: khoá GTVBuildStamp do build.sh ghi; bản build không
    /// qua build.sh (Xcode, IME Lab) thì lấy lúc sửa file thực thi (chép bằng ditto, Sparkle, DMG đều giữ nguyên). GTV.app so
    /// đúng như vậy trước khi cài đè (Sources/GTVLauncher), nên hai bên không bao giờ lệch nhau.
    static func buildStamp(_ app: URL) -> Double? {
        if let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
           let text = info["GTVBuildStamp"] as? String, let stamp = Double(text), stamp > 0 {
            return stamp
        }
        let exe = app.appendingPathComponent("Contents/MacOS/GTVInput").path
        return ((try? FileManager.default.attributesOfItem(atPath: exe))?[.modificationDate] as? Date)?.timeIntervalSince1970
    }

    /// Thời điểm build của bộ gõ đi kèm GTV.app trên đĩa, nếu mới hơn bộ gõ đang chạy (vd. Sparkle vừa cài GTV.app mới, hay
    /// người dùng kéo GTV.app mới vào Applications mà chưa mở). Bản build không cũ hơn thì không đụng tới: không bao giờ
    /// thay bộ gõ bằng bản cũ hơn.
    private func newerBundledStamp() -> Double? {
        guard let host = hostURL,
              let theirs = Self.buildStamp(host.appendingPathComponent("Contents/Resources/GTVInput.app")),
              let ours = Self.buildStamp(Bundle.main.bundleURL), theirs > ours else { return nil }
        return theirs
    }

    private static var secondsSinceKeyDown: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }

    /// GTV.app mới hơn bộ gõ đang chạy: chạy GTV.app để nó cập nhật bộ gõ tại chỗ (tiến trình này sẽ bị thay bằng bản mới).
    /// Đợi người dùng ngừng gõ: GTV.app tắt bộ gõ cũ sau khi đã chép xong bản mới, phím gõ đúng lúc đó có thể lạc. Mỗi bản
    /// chỉ chạy lại sau 10 phút: GTV.app lỗi (vd. đĩa đầy) thì bộ gõ cũ chạy tiếp, không thành vòng lặp mỗi lần bộ gõ khởi
    /// động.
    private func syncInputMethodIfNeeded() {
        guard !syncPending else { return }
        syncPending = true
        syncWhenIdle(since: Date())
    }

    private func syncWhenIdle(since start: Date) {
        guard let target = newerBundledStamp() else {
            syncPending = false
            return
        }
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        if defaults.double(forKey: "launcherRunStamp") == target, now - defaults.double(forKey: "launcherRunAt") < 600 {
            DebugLog.write("GTV.app (\(target)) vừa được chạy để cập nhật bộ gõ, chưa chạy lại")
            syncPending = false
            return
        }
        if Self.secondsSinceKeyDown < 2 && Date().timeIntervalSince(start) < 300 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.syncWhenIdle(since: start) }
            return
        }
        syncPending = false
        defaults.set(target, forKey: "launcherRunStamp")
        defaults.set(now, forKey: "launcherRunAt")
        DebugLog.write("GTV.app (\(target)) mới hơn bộ gõ: chạy GTV.app để cập nhật bộ gõ")
        Settings.runLauncher(["--from-input-method"])
    }

    /// Sparkle chỉ mở lại app sau khi cài nếu app đó đang chạy; GTV.app thường không chạy (bộ gõ mới là
    /// tiến trình chạy ngầm), nên tự theo dõi: khi GTV.app trên đĩa đã là bản mới thì chạy nó.
    private func watchForInstall(deadline: Date) {
        if newerBundledStamp() != nil {
            syncInputMethodIfNeeded()
        } else if Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.watchForInstall(deadline: deadline)
            }
        }
    }

    /// Người dùng chọn "Kiểm tra cập nhật…" (hay lời nhắc có bản mới): Sparkle hiện cửa sổ ở trước.
    func checkForUpdates() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        updater?.checkForUpdates()
    }

    // MARK: - SPUUpdaterDelegate

    /// Cho phép đổi nguồn appcast để thử nghiệm: `defaults write com.gtv.inputmethod.GTV updateFeedURL <url>`.
    func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "updateFeedURL")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        DebugLog.write("Sparkle: bắt đầu cài \(item.displayVersionString) (build \(item.versionString))")
        watchForInstall(deadline: Date().addingTimeInterval(120))
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// GTV là bộ gõ chạy nền: cửa sổ của Sparkle không được giành phím người dùng đang gõ.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// `immediateFocus`: Sparkle muốn kích hoạt bộ gõ và hiện bản mới ở trước — vì app vừa khởi động (bộ gõ thì thường do
    /// chính phím người dùng đang gõ) hoặc máy đã rảnh một lúc. Chỉ cho khi người dùng rảnh tay thật (không phím, không
    /// chuột 2 phút); không thì chỉ nhắc trong menu bộ gõ, lần kiểm tra sau Sparkle hỏi lại. Không cần focus thì Sparkle
    /// hiện cửa sổ phía sau ứng dụng khác, không lấy phím.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        guard immediateFocus else { return true }
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) >= 120
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard !state.userInitiated else { return }
        pendingVersion = update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}
