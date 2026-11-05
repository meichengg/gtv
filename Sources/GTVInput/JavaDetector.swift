import AppKit
import Darwin

/// Nhận biết ô nhập liệu của ứng dụng Java vẽ bằng AWT / Swing / JavaFX / Compose Desktop (Burp Suite, IntelliJ, Ghidra…).
///
/// View của Java (AWTView) bỏ qua `replacementRange`, và khi đang xử lý một phím mà chưa có marked text thì bỏ luôn chữ bộ gõ
/// đưa (`insertText`) rồi phát lại phím gốc cho Java (AWTView.m: `fKeyEventsNeeded`). Cách thay chữ trực tiếp của GTV không
/// bao giờ chạy ở đây ("d9" vẫn là "d9"); chỉ đường marked text (gạch chân, như bộ gõ tiếng Nhật / Trung) là Java hỗ trợ đủ.
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

    /// Một lần kiểm tra đang chạy. `result` được ghi ở luồng nền trước `leave()`, chỉ đọc sau khi `group` xong.
    private final class Check: @unchecked Sendable {
        let group = DispatchGroup()
        var result = false
    }

    private static var cache: [Process: Bool] = [:]
    private static var running: [Process: Check] = [:]
    private static let queue = DispatchQueue(label: "gtv.java-detector", qos: .userInitiated)

    /// Bắt đầu kiểm tra sớm (lúc gắn bộ gõ), để có kết quả trước phím đầu tiên.
    static func prefetch(_ bundleID: String) {
        guard let p = process(for: bundleID), cache[p] == nil, running[p] == nil else { return }
        start(p)
    }

    /// Ô nhập liệu thuộc tiến trình chạy máy ảo Java không. Chưa có kết quả thì chờ tối đa `wait` giây (chỉ ở phím đầu tiên
    /// của mỗi tiến trình, và thường đã có từ lúc gắn bộ gõ); nil: chưa biết (không tìm thấy tiến trình, hay hết hạn chờ).
    static func usesJVM(_ bundleID: String, wait: Double) -> Bool? {
        guard let p = process(for: bundleID) else { return nil }
        if let known = cache[p] { return known }
        let check = running[p] ?? start(p)
        guard check.group.wait(timeout: .now() + wait) == .success else { return nil }
        return finish(p, check)
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
    private static func finish(_ p: Process, _ check: Check) -> Bool {
        if let known = cache[p] { return known }
        cache[p] = check.result
        running[p] = nil
        if check.result {
            DebugLog.write("tiến trình \(p.pid) chạy máy ảo Java: ô không khai báo thuộc tính văn bản sẽ gõ bằng marked text")
        }
        return check.result
    }

    /// Tiến trình của ô nhập liệu: ứng dụng đang ở trước nếu khớp (gần như luôn vậy khi gõ), không thì tìm theo bundle ID.
    /// Ứng dụng Java (install4j: Burp Suite) có khi không đăng ký bundle ID với LaunchServices: so với Info.plist trong gói.
    /// Tiến trình `java` không có gói (Ghidra chạy bằng script): bundle ID rỗng.
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

    /// Có `libjvm.dylib` trong các vùng nhớ map từ file của tiến trình không. Thư viện nạp lúc chạy (dlopen) nằm ở địa chỉ
    /// thấp, trước vùng thư viện hệ thống: gặp là dừng.
    private static func scan(_ pid: pid_t) -> Bool {
        var info = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        var address: UInt64 = 0
        for _ in 0..<50_000 {
            guard proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &info, size) == size else { return false }
            let isJVM = withUnsafePointer(to: &info.prp_vip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { path in
                    path[0] != 0 && String(cString: path).hasSuffix("/libjvm.dylib")
                }
            }
            if isJVM { return true }
            let next = info.prp_prinfo.pri_address &+ info.prp_prinfo.pri_size
            guard next > address else { return false }
            address = next
        }
        return false
    }
}
