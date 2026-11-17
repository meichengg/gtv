import AppKit
import Darwin
import VietEngine

/// Nhận biết ô nhập liệu của ứng dụng Java vẽ bằng AWT / Swing / JavaFX / Compose Desktop (Burp Suite, IntelliJ, Ghidra…).
///
/// View của Java (AWTView) bỏ qua `replacementRange`, và khi đang xử lý một phím mà chưa có marked text thì bỏ luôn chữ bộ gõ
/// đưa (`insertText`) rồi phát lại phím gốc cho Java (AWTView.m: `fKeyEventsNeeded`). Cách thay chữ trực tiếp của GTV không
/// bao giờ chạy ở đây ("d9" vẫn là "d9"); chỉ đường marked text (gạch chân, như bộ gõ tiếng Nhật / Trung) là Java hỗ trợ đủ.
///
/// JetBrains Runtime (IntelliJ, Android Studio, ứng dụng Compose Desktop…) thì khác: AWTView của nó chọn đúng vùng cần thay
/// (`CInputMethod.selectRange`) trước khi chèn — thay chữ trực tiếp chạy được, không cần marked text. Nhận ra bằng tên hàm đó
/// trong `libawt_lwawt.dylib` của chính bộ Java mà tiến trình đang chạy (JDK gốc không có).
///
/// Dấu hiệu: tiến trình của ô nhập liệu đã nạp máy ảo Java (`libjvm.dylib`), và ô không khai báo thuộc tính marked text nào
/// (`ClientKind.terminalView` — AWTView trả về danh sách rỗng). Ứng dụng Java dùng ô Cocoa thật (Cyberduck) hay SWT (DBeaver,
/// Eclipse) báo thuộc tính của ô văn bản: gõ như thường.
///
/// Đọc danh sách file đã map vào tiến trình (như `lsof`: không cần quyền gì với tiến trình cùng người dùng), ở luồng nền, một
/// lần cho mỗi tiến trình.
enum JavaDetector {
    /// Một tiến trình (pid có thể được dùng lại sau khi tiến trình cũ thoát: kèm thời điểm khởi động).
    private struct Process: Hashable {
        let pid: pid_t
        let start: UInt64
    }

    /// Bộ Java của một tiến trình.
    enum Runtime: Equatable {
        case none
        /// JDK gốc: AWT bỏ qua vùng thay chữ — chỉ soạn được bằng marked text.
        case stock
        /// JetBrains Runtime: AWT nhận vùng thay chữ — gõ trực tiếp như ô thường.
        case replacing
    }

    /// Một lần kiểm tra đang chạy. `result` được ghi ở luồng nền trước `leave()`, chỉ đọc sau khi `group` xong.
    private final class Check: @unchecked Sendable {
        let group = DispatchGroup()
        var result = Runtime.none
    }

    private static var cache: [Process: Runtime] = [:]
    private static var running: [Process: Check] = [:]
    /// Tiến trình đã chờ kết quả một lần (hết hạn): các phím sau không chờ nữa.
    private static var waited: Set<Process> = []
    /// Hàng đợi song song: lần quét chậm của tiến trình này (không chạy Java: đi hết vùng nhớ) không chặn tiến trình khác.
    private static let queue = DispatchQueue.global(qos: .userInitiated)

    /// Bắt đầu kiểm tra sớm (lúc gắn bộ gõ), để có kết quả trước phím đầu tiên.
    static func prefetch(_ bundleID: String) {
        guard let p = process(for: bundleID), cache[p] == nil, running[p] == nil else { return }
        start(p)
    }

    /// Bộ Java của tiến trình có ô nhập liệu. Chưa có kết quả thì chờ tối đa `wait` giây — một lần cho mỗi tiến trình (thường
    /// đã có từ lúc gắn bộ gõ); nil: chưa biết (không tìm thấy tiến trình, hay đang quét).
    static func runtime(_ bundleID: String, wait: Double) -> Runtime? {
        guard let p = process(for: bundleID) else { return nil }
        if let known = cache[p] { return known }
        let check = running[p] ?? start(p)
        let timeout: Double = waited.contains(p) ? 0 : wait
        waited.insert(p)
        guard check.group.wait(timeout: .now() + timeout) == .success else { return nil }
        return finish(p, check)
    }

    /// Trợ thủ GTV trong máy ảo Java của tiến trình có ô nhập liệu (`JavaHelper`); nil: không có. Đọc lại ở mỗi lần gọi —
    /// ô giữ focus trong cửa sổ Java đổi mà bộ gõ không được gắn lại.
    static func helper(_ bundleID: String) -> JavaWire.State? {
        guard let p = process(for: bundleID) else { return nil }
        return JavaHelper.state(pid: p.pid, start: p.start / 1_000_000)
    }

    @discardableResult
    private static func start(_ p: Process) -> Check {
        let check = Check()
        running[p] = check
        check.group.enter()
        queue.async {
            check.result = scan(p.pid)
            check.group.leave()
        }
        check.group.notify(queue: .main) { finish(p, check) }
        return check
    }

    @discardableResult
    private static func finish(_ p: Process, _ check: Check) -> Runtime {
        if let known = cache[p] { return known }
        cache[p] = check.result
        running[p] = nil
        waited.remove(p)
        switch check.result {
        case .none: break
        case .stock: DebugLog.write("tiến trình \(p.pid) chạy Java (JDK gốc): ô không khai báo thuộc tính văn bản soạn bằng marked text")
        case .replacing: DebugLog.write("tiến trình \(p.pid) chạy Java (JetBrains Runtime): gõ trực tiếp")
        }
        return check.result
    }

    /// Tiến trình của ô nhập liệu: ứng dụng đang ở trước nếu khớp (gần như luôn vậy khi gõ), không thì tìm theo bundle ID.
    /// Ứng dụng Java (install4j: Burp Suite) có khi không đăng ký bundle ID với LaunchServices: so với Info.plist trong gói.
    /// Tiến trình `java` không có gói (Ghidra chạy bằng script): launcher của OpenJDK nhúng Info.plist với bundle ID
    /// "net.java.openjdk.java", LaunchServices không có gói cho nó — so với ứng dụng đang ở trước.
    private static func process(for bundleID: String) -> Process? {
        var pid: pid_t?
        if let front = NSWorkspace.shared.frontmostApplication {
            if front.bundleIdentifier == bundleID {
                pid = front.processIdentifier
            } else if front.bundleIdentifier == nil {
                if bundleID.isEmpty {
                    pid = front.processIdentifier
                } else if let url = front.bundleURL, Bundle(url: url)?.bundleIdentifier == bundleID {
                    pid = front.processIdentifier
                }
            }
        }
        if pid == nil, !bundleID.isEmpty {
            pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
        }
        guard let pid, pid > 0 else { return nil }
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        return Process(pid: pid, start: bsd.pbi_start_tvsec &* 1_000_000 &+ bsd.pbi_start_tvusec)
    }

    /// Tìm `libjvm.dylib` trong các vùng nhớ map từ file của tiến trình. Thư viện nạp lúc chạy (dlopen) nằm ở địa chỉ thấp,
    /// trước vùng thư viện hệ thống: gặp là dừng. Có thì xem `libawt_lwawt.dylib` cùng bộ Java có nhận vùng thay chữ không.
    private static func scan(_ pid: pid_t) -> Runtime {
        var info = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        var address: UInt64 = 0
        for _ in 0..<50_000 {
            guard proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &info, size) == size else { return .none }
            let jvm: String? = withUnsafePointer(to: &info.prp_vip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { path in
                    guard path[0] != 0 else { return nil }
                    let s = String(cString: path)
                    return s.hasSuffix("/libjvm.dylib") ? s : nil
                }
            }
            if let jvm { return replaces(jvmPath: jvm) ? .replacing : .stock }
            let next = info.prp_prinfo.pri_address &+ info.prp_prinfo.pri_size
            guard next > address else { return .none }
            address = next
        }
        return .none
    }

    /// `…/lib/server/libjvm.dylib` → `…/lib/libawt_lwawt.dylib`: có tên hàm JNI `selectRange` (AWTView của JetBrains Runtime gọi
    /// nó với vùng cần thay) không. Đọc file (không map: file bị ghi đè lúc ứng dụng cập nhật thì chỉ lỗi đọc).
    private static func replaces(jvmPath: String) -> Bool {
        let lib = URL(fileURLWithPath: jvmPath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("libawt_lwawt.dylib")
        guard let data = try? Data(contentsOf: lib) else { return false }
        return data.range(of: Data([0] + Array("selectRange".utf8) + [0])) != nil
    }
}
