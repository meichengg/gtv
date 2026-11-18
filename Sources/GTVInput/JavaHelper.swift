import AppKit
import Darwin
import VietEngine

/// Trợ thủ Java của GTV (JavaHelper/ trong mã nguồn, `gtv-java-helper.jar` trong gói bộ gõ).
///
/// Ứng dụng Java chạy JDK gốc (Burp Suite, Ghidra, JMeter…) không cho bộ gõ thay chữ đã gõ: AWT bỏ qua vùng cần thay, nên
/// chỉ soạn từng từ được — Swing tự gạch chân phần đang soạn, và AWT nuốt phím tắt / mũi tên bấm ngay sau từ. Nạp trợ thủ
/// vào máy ảo của ứng dụng (thêm `-javaagent:<đường dẫn>` vào tham số JVM của nó) thì AWT nhận vùng cần thay như JetBrains
/// Runtime: GTV thay chữ trực tiếp, không còn gì "đang soạn".
///
/// Trợ thủ báo sự có mặt của nó qua một file nhỏ theo pid (`JavaWire.State`); GTV đọc file đó ở mỗi phím gõ vào ô Java.
enum JavaHelper {
    /// Cạnh file .jar, không trong Library/Caches (công cụ dọn bộ đệm xoá nó thì GTV tưởng trợ thủ không có mặt).
    private static let stateDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/GTV/state").path

    /// Nơi đặt file .jar để tham số JVM của ứng dụng trỏ tới: đường dẫn không đổi qua các lần cập nhật GTV và không có dấu
    /// cách (file tham số JVM và JAVA_TOOL_OPTIONS tách tham số theo dấu cách).
    static let jarURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/GTV/gtv-java-helper.jar")

    /// Dòng tham số JVM nạp trợ thủ.
    static var agentOption: String { "-javaagent:\(jarURL.path)" }

    /// Trạng thái trợ thủ của tiến trình `pid` (khởi động lúc `start` giây); nil: máy ảo đó không có trợ thủ.
    static func state(pid: pid_t, start: UInt64) -> JavaWire.State? {
        let fd = open("\(stateDirectory)/\(pid)", O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var record = [UInt8](repeating: 0, count: 64)
        let n = pread(fd, &record, record.count, 0)
        guard n > 0, let state = JavaWire.state(record[0..<n]) else { return nil }
        // File cũ của một tiến trình đã thoát mà pid được dùng lại: giờ khởi động không khớp.
        if state.start != 0, abs(Int64(state.start) - Int64(start)) > 5 { return nil }
        return state
    }

    /// Chép file .jar đi kèm bộ gõ ra `jarURL` (lúc bộ gõ khởi động): tham số JVM của các ứng dụng luôn trỏ tới bản mới
    /// nhất. Ghi ra file tạm rồi đổi tên: máy ảo đang chạy vẫn giữ bản nó đã mở.
    static func installJar() {
        guard let bundled = Bundle.main.url(forResource: "gtv-java-helper", withExtension: "jar"),
              let data = try? Data(contentsOf: bundled) else {
            DebugLog.event("trợ thủ Java: gói bộ gõ không có gtv-java-helper.jar")
            return
        }
        let fm = FileManager.default
        if let current = try? Data(contentsOf: jarURL), current == data { return }
        do {
            try fm.createDirectory(at: jarURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temp = jarURL.deletingLastPathComponent().appendingPathComponent(".gtv-java-helper.\(getpid()).tmp")
            try data.write(to: temp)
            if rename(temp.path, jarURL.path) != 0 {
                try? fm.removeItem(at: temp)
                DebugLog.event("trợ thủ Java: không đặt được \(jarURL.path) (errno \(errno))")
                return
            }
            DebugLog.event("trợ thủ Java: đã đặt \(jarURL.path)")
        } catch {
            DebugLog.event("trợ thủ Java: không chép được: \(error.localizedDescription)")
        }
    }

    /// Hướng dẫn nạp trợ thủ vào ứng dụng Java `name`. Không dùng runModal: tiến trình này còn là bộ gõ.
    static func showInstructions(appName name: String) {
        installJar()
        let alert = NSAlert()
        alert.messageText = "Gõ thẳng trong \(name)"
        alert.informativeText = """
            \(name) chạy Java (JDK gốc): Java không cho bộ gõ thay chữ đã gõ, nên GTV phải soạn từng từ — từ đang soạn bị \
            gạch chân, phím tắt và mũi tên bấm ngay sau từ bị Java bỏ qua.

            Để gõ thẳng như ứng dụng thường, thêm dòng sau vào tham số JVM của \(name) rồi mở lại nó:

            \(agentOption)

            • Burp Suite: file user.vmoptions (cạnh vmoptions.txt trong gói ứng dụng), mỗi tham số một dòng.
            • Ghidra: dòng VMARGS trong support/launch.properties.
            • Ứng dụng khác: file .vmoptions của nó, hoặc biến môi trường JAVA_TOOL_OPTIONS.

            Dòng này nạp gtv-java-helper.jar (đi kèm GTV) vào Java của ứng dụng (Java 11 trở lên; Java cũ hơn bỏ qua trợ thủ \
            và vẫn soạn từng từ). Đừng xoá file đó khi dòng trên còn trong cấu hình: Java sẽ không khởi động được.
            """
        alert.addButton(withTitle: "Chép dòng cấu hình")
        alert.addButton(withTitle: "Đóng")
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        alert.window.center()
        alert.window.makeKeyAndOrderFront(nil)
        // Nút đầu chép dòng cấu hình; cả hai đều đóng hộp thoại.
        let copier = AlertCopier(text: agentOption, window: alert.window)
        for (index, button) in alert.buttons.enumerated() {
            button.target = copier
            button.action = index == 0 ? #selector(AlertCopier.copy(_:)) : #selector(AlertCopier.close(_:))
        }
        openAlert = (alert, copier)
    }

    /// Giữ hộp thoại đang mở (không modal nên không ai khác giữ nó).
    private static var openAlert: (NSAlert, AlertCopier)?

    private final class AlertCopier: NSObject {
        let text: String
        weak var window: NSWindow?

        init(text: String, window: NSWindow) {
            self.text = text
            self.window = window
        }

        @objc func copy(_ sender: Any?) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            close(sender)
        }

        @objc func close(_ sender: Any?) {
            window?.orderOut(nil)
            DispatchQueue.main.async { JavaHelper.openAlert = nil }
        }
    }
}
