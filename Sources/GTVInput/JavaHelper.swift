import AppKit
import Darwin
import VietEngine

/// Trợ thủ Java của GTV (JavaHelper/ trong mã nguồn, `gtv-java-helper.jar` trong gói bộ gõ).
///
/// Ứng dụng Java chạy JDK gốc (Burp Suite, Ghidra, JMeter…) không cho bộ gõ thay chữ đã gõ: AWT bỏ qua vùng cần thay, nên
/// chỉ soạn từng từ được — Swing tự gạch chân phần đang soạn, và AWT nuốt phím tắt / mũi tên bấm ngay sau từ. Có trợ thủ
/// trong máy ảo của ứng dụng thì AWT nhận vùng cần thay như JetBrains Runtime: GTV thay chữ trực tiếp, không còn gì "đang soạn".
///
/// Trợ thủ vào máy ảo bằng một trong hai đường:
/// - GTV tự nạp nó vào máy ảo đang chạy (`autoLoad`, qua cổng attach của máy ảo — `JavaAttach`) lần đầu thấy ứng dụng đó có ô
///   nhập liệu. Không cần cấu hình gì ở ứng dụng, nên không mất khi ứng dụng cập nhật hay ghi lại file tham số JVM của nó.
/// - Dòng `-javaagent:<đường dẫn>` trong tham số JVM của ứng dụng: cho máy ảo không cho nạp agent lúc chạy.
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

    /// Một máy ảo đã được thử tự nạp trợ thủ (pid có thể được dùng lại: kèm thời điểm khởi động, micro giây).
    private struct Target: Hashable {
        let pid: pid_t
        let start: UInt64
    }

    /// Việc tự nạp vào một máy ảo: kết quả lần thử gần nhất (nil: đang nạp), số lần đã thử, lúc bắt đầu lần gần nhất.
    private struct Load {
        var outcome: JavaAttach.Outcome?
        var attempts: Int
        var began: UInt64
    }

    /// Chỉ dùng trên luồng chính.
    private static var loads: [Target: Load] = [:]
    private static let loadQueue = DispatchQueue(label: "gtv.java-helper-load", qos: .userInitiated)
    /// Máy ảo không tới được (đang bận) thì thử lại, thưa và có hạn: mỗi lần thử một máy ảo đã tắt cơ chế attach là một lần
    /// nó in danh sách luồng ra stdout. Máy ảo đã trả lời "không" thì không hỏi lại.
    private static let maxAttempts = 3
    private static let retryAfter: UInt64 = 10_000_000_000

    /// Người dùng cho GTV tự nạp trợ thủ vào ứng dụng Java (mặc định bật). Đọc thẳng UserDefaults: IME Lab đổi bằng
    /// `defaults write` giữa hai lượt.
    static var autoLoads: Bool {
        get { UserDefaults.standard.object(forKey: "javaAutoHelper") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "javaAutoHelper") }
    }

    /// Tự nạp trợ thủ vào máy ảo (JDK gốc) của tiến trình `pid` nếu nó chưa có — ở luồng nền. Nạp xong thì trợ thủ tự ghi file
    /// trạng thái; phím kế tiếp vào ô Java thấy nó (`state`). Gọi được ở mỗi phím: đã thử rồi thì chỉ là một lần tra bảng.
    static func autoLoad(pid: pid_t, start: UInt64) {
        let target = Target(pid: pid, start: start)
        let now = DispatchTime.now().uptimeNanoseconds
        var attempts = 0
        if let load = loads[target] {
            guard case .unreachable? = load.outcome, load.attempts < maxAttempts, now - load.began >= retryAfter else { return }
            attempts = load.attempts
        }
        guard autoLoads, state(pid: pid, start: start / 1_000_000) == nil else { return }
        if loads.count > 64 { loads = loads.filter { kill($0.key.pid, 0) == 0 } }
        loads[target] = Load(outcome: nil, attempts: attempts + 1, began: now)
        if !FileManager.default.fileExists(atPath: jarURL.path) { installJar() }
        let jar = jarURL.path
        loadQueue.async {
            let outcome = JavaAttach.loadAgent(pid: pid, start: start, jar: jar)
            let ms = (DispatchTime.now().uptimeNanoseconds - now) / 1_000_000
            DispatchQueue.main.async {
                loads[target]?.outcome = outcome
                switch outcome {
                case .loaded: DebugLog.event("trợ thủ Java: đã tự nạp vào tiến trình \(pid) (\(ms) ms)")
                case .skipped(let why): DebugLog.event("trợ thủ Java: không tự nạp vào tiến trình \(pid): \(why)")
                case .unreachable(let why):
                    DebugLog.event("trợ thủ Java: chưa nạp được vào tiến trình \(pid) (lần \(attempts + 1)/\(maxAttempts), \(ms) ms): \(why)")
                case .failed(let why): DebugLog.event("trợ thủ Java: tiến trình \(pid) không nạp (\(ms) ms): \(why)")
                }
            }
        }
    }

    /// Vì sao GTV không tự nạp được trợ thủ vào máy ảo đó; nil: chưa thử, đang nạp, hay đã nạp.
    static func loadFailure(pid: pid_t, start: UInt64) -> String? {
        switch loads[Target(pid: pid, start: start)]?.outcome {
        case .skipped(let why)?, .unreachable(let why)?, .failed(let why)?: return why
        default: return nil
        }
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

    /// Hướng dẫn nạp trợ thủ vào ứng dụng Java `name` bằng dòng cấu hình — cho máy ảo GTV không tự nạp được (`failure`: lý
    /// do, nếu GTV đã thử). Không dùng runModal: tiến trình này còn là bộ gõ.
    static func showInstructions(appName name: String, failure: String?) {
        installJar()
        let alert = NSAlert()
        alert.messageText = "Gõ thẳng trong \(name)"
        let tried = failure.map { "GTV đã thử tự nạp trợ thủ vào Java của \(name) nhưng không được: \($0).\n\n" }
            ?? (autoLoads ? "" : "Mục \"Tự nạp trợ thủ vào ứng dụng Java\" đang tắt: bật nó thì GTV tự lo việc dưới đây.\n\n")
        alert.informativeText = """
            \(name) chạy Java (JDK gốc): Java không cho bộ gõ thay chữ đã gõ, nên GTV phải soạn từng từ — từ đang soạn bị \
            gạch chân, phím tắt và mũi tên bấm ngay sau từ bị Java bỏ qua.

            \(tried)Để gõ thẳng như ứng dụng thường, thêm dòng sau vào tham số JVM của \(name) rồi mở lại nó:

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
