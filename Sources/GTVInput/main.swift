import Cocoa
import InputMethodKit

// Việc cài đặt/đăng ký bộ gõ do GTV.app (Sources/GTVLauncher) đảm nhiệm.
let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String
    ?? "com.gtv.inputmethod.GTV_Connection"
let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)

DebugLog.write("khởi động")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // không hiện trên Dock
StatusController.shared.start()
_ = Modes.shared
Updater.shared.start()
JavaHelper.installJar()
withExtendedLifetime(server) {
    app.run()
}
