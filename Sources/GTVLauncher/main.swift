// GTV.app (trong /Applications): cài hoặc cập nhật bộ gõ ẩn vào ~/Library/Input Methods,
// chọn nó làm bộ gõ hiện tại, khởi động nó (biểu tượng V/E hiện trên thanh menu) rồi thoát.
//
// Lưu ý: không bao giờ xoá thư mục bộ gõ đã cài. Khi thư mục biến mất, macOS gỡ GTV khỏi danh sách
// bộ gõ và lần bật lại sẽ phải hỏi người dùng. Vì vậy chỉ thay phần bên trong (Contents), và chỉ bật
// bộ gõ khi nó chưa được bật.
//
// Tham số (người dùng mở GTV.app hay mục đăng nhập chạy nó thì không có):
//   --from-input-method  bộ gõ chạy (GTV.app trên đĩa mới hơn, vd. Sparkle vừa cài): chỉ cập nhật bộ gõ, không hiện hộp
//                        thoại, không giành input source người dùng đang dùng.
//   --sync-login-item    bộ gõ chạy khi người dùng bật/tắt "Chọn GTV khi đăng nhập".
//   --uninstall          uninstall.sh chạy trước khi xoá file.
import Carbon
import Cocoa
import Security
import ServiceManagement

let inputID = "com.gtv.inputmethod.GTV"
let fm = FileManager.default
let bundled = Bundle.main.resourceURL!.appendingPathComponent("GTVInput.app")
let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods")
let installed = dir.appendingPathComponent("GTVInput.app")
let legacy = dir.appendingPathComponent("GTV.app")   // bản cài trước đây (chỉ có bộ gõ)
/// Chỗ chép tạm bản mới và file khoá: cùng ổ với ~/Library/Input Methods (đổi chỗ được bằng rename) nhưng ngoài thư mục
/// đó (macOS quét nó tìm bộ gõ).
let work = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.gtv.GTV")
let stageDir = work.appendingPathComponent("stage")
let background = CommandLine.arguments.contains("--from-input-method")
/// GTV.app chạy từ DMG (ổ chỉ đọc) hoặc bị App Translocation (mở thẳng từ thư mục tải về): đường dẫn sẽ biến mất.
let temporaryLocation: Bool = {
    let url = Bundle.main.bundleURL
    if url.path.contains("/AppTranslocation/") { return true }
    return (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
}()
/// Chỉ bản nằm cố định trong Applications được đăng ký mở khi đăng nhập (bản trong DMG, thư mục tải về hay thư mục build
/// sẽ biến mất hoặc cũ đi).
let stableLocation: Bool = {
    let path = Bundle.main.bundleURL.path
    return !temporaryLocation && (path.hasPrefix("/Applications/")
        || path.hasPrefix(fm.homeDirectoryForCurrentUser.path + "/Applications/"))
}()
var lockFD: Int32 = -1

/// Đồng bộ mục "Mở khi đăng nhập" của GTV.app với cài đặt "Chọn GTV khi đăng nhập" (lưu trong cài đặt của bộ gõ, mặc định
/// bật), rồi ghi trạng thái thật vào cài đặt của bộ gõ để menu hiện đúng. Khi đăng nhập, GTV.app chạy và chọn GTV nếu đang
/// ở bộ gõ khác.
/// `userRequest`: người dùng vừa bật/tắt trong menu. Ngoài lúc đó chỉ tự đăng ký một lần (lần cài đầu): mục đăng nhập bị
/// gỡ hay bị tắt trong Cài đặt hệ thống là ý người dùng, không thêm lại.
func syncLoginItem(userRequest: Bool) {
    guard #available(macOS 13.0, *), stableLocation else { return }
    let prefs = UserDefaults(suiteName: inputID)
    let want = prefs?.object(forKey: "selectAtLogin") as? Bool ?? true
    let own = UserDefaults.standard
    let service = SMAppService.mainApp
    do {
        switch service.status {
        case .enabled:
            own.set(true, forKey: "loginItemRegistered")
            if !want { try service.unregister() }
        case .requiresApproval:
            // Người dùng đã tắt GTV trong Cài đặt hệ thống → Mục đăng nhập: chỉ họ bật lại được ở đó.
            if !want {
                try service.unregister()
            } else if userRequest {
                SMAppService.openSystemSettingsLoginItems()
                // Đợi người dùng bật lại ở đó (tối đa 2 phút) để ghi đúng trạng thái cho menu.
                let deadline = Date().addingTimeInterval(120)
                while service.status != .enabled && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                }
            }
        default:
            if want && (userRequest || !own.bool(forKey: "loginItemRegistered")) {
                try service.register()
                own.set(true, forKey: "loginItemRegistered")
            }
        }
    } catch {
        NSLog("GTV: không cập nhật được mục Mở khi đăng nhập: \(error.localizedDescription)")
    }
    let status: String
    switch service.status {
    case .enabled: status = "enabled"
    case .requiresApproval: status = "requiresApproval"
    default: status = "notRegistered"
    }
    prefs?.set(status, forKey: "loginItemStatus")
}

/// Trước khi xoá file (uninstall.sh): rời GTV và tắt các nguồn nhập của nó (để hệ thống không mở lại bộ gõ đã bị xoá,
/// cũng không giữ nó làm bộ gõ đang chọn), gỡ mục "Mở khi đăng nhập".
func uninstall() {
    if #available(macOS 13.0, *) { try? SMAppService.mainApp.unregister() }
    if isGTVSelected(), let abc = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
        TISEnableInputSource(abc)
        TISSelectInputSource(abc)
    }
    for src in inputSources() where flag(src, kTISPropertyInputSourceIsEnabled) {
        TISDisableInputSource(src)
    }
}

if CommandLine.arguments.contains("--sync-login-item") {
    syncLoginItem(userRequest: true)
    exit(0)
}
if CommandLine.arguments.contains("--uninstall") {
    uninstall()
    exit(0)
}

/// Chạy từ bộ gõ (`--from-input-method`) thì không hiện hộp thoại: lỗi chỉ ghi log, bộ gõ cũ vẫn chạy và sẽ thử lại sau.
func fail(_ message: String) -> Never {
    unlockInstall()   // đừng bắt GTV.app khác đợi trong lúc hộp thoại còn mở
    if background {
        NSLog("GTV: \(message)")
        exit(1)
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Không khởi động được GTV"
    alert.informativeText = message
    alert.runModal()
    exit(1)
}

/// Chỉ một GTV.app cài bộ gõ một lúc (vd. mục đăng nhập và bộ gõ cùng chạy GTV.app): bản tới sau đợi rồi so lại, sẽ thấy
/// bộ gõ đã giống và bỏ qua. Khoá tự nhả khi tiến trình thoát.
func lockInstall() -> Bool {
    try? fm.createDirectory(at: work, withIntermediateDirectories: true)
    lockFD = open(work.appendingPathComponent("install.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    guard lockFD >= 0 else { return true }   // không tạo được file khoá: cài như trước
    let deadline = Date().addingTimeInterval(60)
    while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        if Date() >= deadline { return false }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return true
}

func unlockInstall() {
    guard lockFD >= 0 else { return }
    flock(lockFD, LOCK_UN)
    close(lockFD)
    lockFD = -1
}

/// Hai bản có giống hệt nhau không (so sánh file thực thi và Info.plist).
func sameBuild(_ a: URL, _ b: URL) -> Bool {
    for path in ["Contents/MacOS/GTVInput", "Contents/Info.plist"] {
        guard let x = fm.contents(atPath: a.appendingPathComponent(path).path),
              let y = fm.contents(atPath: b.appendingPathComponent(path).path), x == y else { return false }
    }
    return true
}

/// Thời điểm build của một bản bộ gõ (giây UTC): khoá GTVBuildStamp do build.sh ghi; bản build không qua build.sh (Xcode,
/// IME Lab) thì lấy lúc sửa file thực thi (chép bằng ditto, Sparkle, DMG đều giữ nguyên). Mọi bản build đều có cùng
/// CFBundleVersion nếu không qua build.sh nên không dùng được nó. Updater của bộ gõ so đúng như vậy.
func buildStamp(_ app: URL) -> Double? {
    if let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
       let text = info["GTVBuildStamp"] as? String, let stamp = Double(text), stamp > 0 {
        return stamp
    }
    let exe = app.appendingPathComponent("Contents/MacOS/GTVInput").path
    return ((try? fm.attributesOfItem(atPath: exe))?[.modificationDate] as? Date)?.timeIntervalSince1970
}

/// GTV.app này mang bộ gõ cũ hơn bộ gõ đã cài (vd. DMG cũ còn trong thư mục tải về, bản build cũ, mục đăng nhập trỏ tới
/// bản cũ). Không biết thì coi như không cũ hơn (cài như trước).
func bundledIsOlder() -> Bool {
    guard let mine = buildStamp(bundled), let theirs = buildStamp(installed) else { return false }
    return mine < theirs
}

func describe(_ app: URL) -> String {
    let version = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"]
        as? String ?? "?"
    guard let stamp = buildStamp(app) else { return version }
    let format = DateFormatter()
    format.dateFormat = "dd/MM/yyyy HH:mm"
    return "\(version), build lúc \(format.string(from: Date(timeIntervalSince1970: stamp)))"
}

/// Người dùng mở một GTV.app cũ hơn bộ gõ đang dùng: hỏi trước khi cài đè (mặc định giữ bản đang dùng).
func confirmDowngrade() -> Bool {
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "GTV này cũ hơn bộ gõ đang dùng"
    alert.informativeText = """
        Bộ gõ đang dùng: \(describe(installed)).
        GTV này: \(describe(bundled)).

        Giữ bộ gõ đang dùng, hay cài bản cũ hơn này đè lên?
        """
    alert.addButton(withTitle: "Giữ bản đang dùng")
    alert.addButton(withTitle: "Cài bản này")
    return alert.runModal() == .alertSecondButtonReturn
}

func stopRunningInput() {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: inputID)
    apps.forEach { $0.forceTerminate() }
    let deadline = Date().addingTimeInterval(3)
    while apps.contains(where: { !$0.isTerminated }) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}

/// Người dùng đã cho phép mở GTV.app; bản bộ gõ chép ra không cần bị Gatekeeper hỏi lại.
func clearQuarantine(_ url: URL) {
    let subpaths = (try? fm.subpathsOfDirectory(atPath: url.path)) ?? []
    for p in [url.path] + subpaths.map({ url.appendingPathComponent($0).path }) {
        removexattr(p, "com.apple.quarantine", XATTR_NOFOLLOW)
    }
}

/// Chữ ký (ad-hoc hay Developer ID) của bundle còn khớp nội dung, kể cả Sparkle.framework bên trong.
func validSignature(_ app: URL) -> Bool {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
    let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
    return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
}

/// Chép bản đi kèm ra chỗ tạm và kiểm nó. Lỗi ở bước này (vd. đĩa đầy) không đụng tới bộ gõ đang chạy.
func stageBundled() throws -> URL {
    try? fm.removeItem(at: stageDir)
    try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
    let staged = stageDir.appendingPathComponent("GTVInput.app")
    try fm.copyItem(at: bundled, to: staged)   // APFS: bản sao clone, gần như không tốn chỗ
    clearQuarantine(staged)
    // Bản build không ký thì không kiểm được: cài như trước.
    if !validSignature(staged) && validSignature(bundled) {
        throw NSError(domain: "GTV", code: 1, userInfo: [NSLocalizedDescriptionKey: "bản chép ra không khớp chữ ký"])
    }
    return staged
}

/// Thay bộ gõ đã cài bằng bản đã chép ra. APFS: đổi chỗ nguyên khối hai thư mục Contents — thư mục GTVInput.app giữ nguyên
/// (macOS không gỡ bộ gõ) và không lúc nào có bundle nửa cũ nửa mới; bộ gõ cũ vẫn chạy bằng file đã nạp, mọi lần mở lại
/// sau đó là bản mới. Ổ không đổi chỗ được (HFS+): rsync từng file (mỗi file ghi ra file tạm rồi mới đổi tên); chép cả
/// file cùng cỡ cùng giờ sửa (HFS+ chỉ lưu giờ sửa tới giây: Info.plist của hai bản build có thể trùng cả hai).
func replaceInstalled(with staged: URL) throws {
    let new = staged.appendingPathComponent("Contents").path
    let old = installed.appendingPathComponent("Contents").path
    if renamex_np(new, old, UInt32(RENAME_SWAP)) == 0 { return }
    if !fm.fileExists(atPath: old), rename(new, old) == 0 { return }   // bản đã cài hỏng, không có Contents
    let rsync = Process()
    rsync.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
    rsync.arguments = ["-a", "--ignore-times", "--delete", staged.path + "/", installed.path + "/"]
    try rsync.run()
    rsync.waitUntilExit()
    guard rsync.terminationStatus == 0 else {
        throw NSError(domain: "GTV", code: Int(rsync.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "rsync lỗi \(rsync.terminationStatus)"])
    }
}

func inputSources() -> [TISInputSource] {
    let filter = [kTISPropertyBundleID as String: inputID] as CFDictionary
    return TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] ?? []
}

func property(_ src: TISInputSource, _ key: CFString) -> AnyObject? {
    guard let p = TISGetInputSourceProperty(src, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue()
}

func flag(_ src: TISInputSource, _ key: CFString) -> Bool {
    (property(src, key) as? NSNumber)?.boolValue ?? false
}

// Chạy ngầm từ bộ gõ: chỉ chọn lại GTV nếu người dùng đang ở GTV (bộ gõ cũ bị tắt có thể làm macOS chuyển sang ABC).
let wasGTV = isGTVSelected()

// 1. Cài / cập nhật
guard lockInstall() else {
    if background { exit(0) }
    fail("Một GTV khác đang cài bộ gõ. Hãy đợi một lát rồi mở GTV lần nữa.")
}
var updated = false
/// Lúc bộ gõ đã cài được thay: tiến trình bộ gõ mở trước lúc này là bản cũ.
var replacedAt: Date?
do {
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    if fm.fileExists(atPath: legacy.path) {
        stopRunningInput()
        try fm.removeItem(at: legacy)
    }
    if !fm.fileExists(atPath: installed.path) {
        try fm.moveItem(at: try stageBundled(), to: installed)
        updated = true
    } else if !sameBuild(bundled, installed) {
        // Bản đi kèm cũ hơn: chạy ngầm thì bỏ qua, người dùng mở GTV.app thì hỏi.
        if !bundledIsOlder() || (!background && confirmDowngrade()) {
            try replaceInstalled(with: try stageBundled())
            replacedAt = Date()
            // Chỉ tắt bộ gõ cũ khi bản mới đã nằm đúng chỗ: chép hay kiểm lỗi thì bộ gõ cũ chạy tiếp, vẫn gõ được.
            stopRunningInput()
            updated = true
        }
    }
    if updated { removexattr(installed.path, "com.apple.quarantine", XATTR_NOFOLLOW) }
    try? fm.removeItem(at: stageDir)   // sau khi đổi chỗ, ở đây là bản cũ
} catch {
    try? fm.removeItem(at: stageDir)
    fail("Không cài được bộ gõ vào \(dir.path): \(error.localizedDescription)")
}

// 2. Đăng ký (lần đầu hoặc sau khi cập nhật, để macOS đọc lại Info.plist)
var sources = inputSources()
if updated || sources.isEmpty {
    let status = TISRegisterInputSource(installed as CFURL)
    guard status == noErr else { fail("Đăng ký bộ gõ thất bại (mã lỗi \(status)).") }
    for _ in 0..<40 {
        sources = inputSources()
        if sources.contains(where: { property($0, kTISPropertyInputSourceID) as? String == inputID + ".vi" }) { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}
guard !sources.isEmpty else {
    fail("Đã cài bộ gõ nhưng macOS chưa nhận. Hãy đăng xuất rồi đăng nhập lại, sau đó mở GTV lần nữa.")
}
unlockInstall()
// Chạy ngầm mà không có gì để thay: bộ gõ đang chạy đã là bản này.
if background && !updated { exit(0) }

// 3. Bật (chỉ khi chưa bật — macOS sẽ hỏi người dùng ở lần đầu; chạy ngầm thì không hỏi) rồi chọn GTV.
func vietnameseEnabled() -> Bool {
    inputSources().contains {
        property($0, kTISPropertyInputSourceID) as? String == inputID + ".vi" && flag($0, kTISPropertyInputSourceIsEnabled)
    }
}
if !background {
    var requestedEnable = false
    for src in sources where !flag(src, kTISPropertyInputSourceIsEnabled) && flag(src, kTISPropertyInputSourceIsEnableCapable) {
        TISEnableInputSource(src)
        requestedEnable = true
    }
    if requestedEnable && !vietnameseEnabled() {
        // macOS có thể đang hiện hộp thoại xin phép: đợi người dùng trả lời (tối đa 1 phút).
        let deadline = Date().addingTimeInterval(60)
        while !vietnameseEnabled() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        if !vietnameseEnabled() { showManualSetup() }
    }
}

/// Đường lui khi macOS không cho bật bộ gõ bằng lệnh: hướng dẫn người dùng thêm bằng tay.
func showManualSetup() {
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Thêm bộ gõ GTV"
    alert.informativeText = """
        macOS chưa bật bộ gõ GTV. Hãy thêm bằng tay:
        Cài đặt hệ thống → Bàn phím → Nguồn đầu vào → Sửa… → + → Tiếng Việt → \
        chọn "Vietnamese (GTV)" và "English (GTV)" → Thêm.

        Nếu không thấy GTV trong danh sách, hãy đăng xuất rồi đăng nhập lại và mở GTV lần nữa.
        """
    alert.addButton(withTitle: "Mở Cài đặt Bàn phím")
    alert.addButton(withTitle: "Để sau")
    if alert.runModal() == .alertFirstButtonReturn,
       let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
        NSWorkspace.shared.open(url)
    }
}
// Chọn chế độ Tiếng Việt (bộ gõ có 2 chế độ: <id>.vi và <id>.en) — trừ khi đang ở GTV rồi
// (vd. lần trước đăng xuất khi đang ở English (GTV) thì giữ nguyên).
@Sendable func isGTVSelected() -> Bool {
    guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
    return property(current, kTISPropertyBundleID) as? String == inputID
}
@Sendable func selectVietnamese() {
    let vietnameseMode = inputSources().first { property($0, kTISPropertyInputSourceID) as? String == inputID + ".vi" }
    if let target = vietnameseMode ?? inputSources().first(where: { flag($0, kTISPropertyInputSourceIsSelectCapable) }) {
        TISSelectInputSource(target)
    }
}
/// Người dùng mở GTV.app (hay mục đăng nhập chạy nó) là để dùng GTV; chạy ngầm từ bộ gõ (vd. Sparkle vừa cài xong) thì
/// không giành input source người dùng đang dùng (tiếng Nhật, ABC…).
let selects = !background || wasGTV
if selects && !isGTVSelected() { selectVietnamese() }
if !background { syncLoginItem(userRequest: false) }

// GTV.app chạy từ DMG hay bị App Translocation: bộ gõ đã cài và dùng được, nhưng nhắc chuyển GTV vào Applications (bản
// ở đó mới tự cập nhật và tự chọn GTV khi đăng nhập được).
if !background && temporaryLocation {
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Hãy chuyển GTV vào Applications"
    alert.informativeText = """
        GTV đang chạy từ file .dmg hoặc thư mục tải về. Bộ gõ đã được cài và dùng được ngay, nhưng để GTV tự cập nhật \
        và tự chọn khi đăng nhập, hãy kéo GTV vào thư mục Applications rồi mở GTV từ đó.
        """
    alert.runModal()
}

// Sau khi cập nhật: khởi động lại menu bộ gõ của macOS (hệ thống tự mở lại ngay) để nó đọc lại
// tên và icon mới của GTV, không phải đợi đăng nhập lại.
if updated {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextInputMenuAgent")
        .forEach { $0.terminate() }
}

// Bộ gõ cũ được mở lại ngay trước lúc thay mà lúc tắt chưa thấy: tắt nốt để không chạy bản cũ tới lần đăng xuất.
if let replacedAt {
    NSRunningApplication.runningApplications(withBundleIdentifier: inputID)
        .filter { ($0.launchDate ?? .distantFuture) < replacedAt }
        .forEach { $0.forceTerminate() }
}

// 4. Khởi động ngay để biểu tượng V/E hiện lên (nếu đang chạy thì không mở thêm).
let config = NSWorkspace.OpenConfiguration()
config.activates = false
NSWorkspace.shared.openApplication(at: installed, configuration: config) { _, error in
    if let error { NSLog("GTV: không mở được bộ gõ: \(error.localizedDescription)") }
    DispatchQueue.main.async {
        if selects { ensureSelected(attempts: 10) } else { exit(0) }
    }
}

/// Sau khi bộ gõ cũ bị tắt để cập nhật, macOS có thể tự chuyển sang ABC chậm hơn lệnh chọn ở trên.
func ensureSelected(attempts: Int) {
    let ok = isGTVSelected()
    if ok && attempts < 8 { exit(0) }   // đã đứng yên ở GTV một lúc
    if !ok { selectVietnamese() }
    if attempts == 0 { exit(0) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { ensureSelected(attempts: attempts - 1) }
}

RunLoop.main.run(until: Date().addingTimeInterval(10))
exit(0)
