import Darwin
#if canImport(VietEngine)
import VietEngine
#endif

/// Nạp một agent Java vào máy ảo HotSpot ĐANG CHẠY, qua cổng attach của chính máy ảo đó — cổng mà `jcmd`, `jstack`, VisualVM
/// và các profiler dùng (`com.sun.tools.attach.VirtualMachine.loadAgent`). GTV dùng nó để đưa trợ thủ Java (`JavaHelper`)
/// vào ứng dụng Java không có dòng `-javaagent` trong cấu hình.
///
/// Cách máy ảo mở cổng: nhận SIGQUIT mà thấy file `.attach_pid<pid>` (của cùng người dùng) trong thư mục tạm thì nó mở
/// socket `.java_pid<pid>` ở đó thay vì in danh sách luồng. Sau đó là giao thức `JavaAttachWire`.
///
/// SIGQUIT chỉ được gửi khi tiến trình đang BẮT tín hiệu đó: máy ảo chạy với `-Xrs` không bắt, và hành động mặc định của
/// SIGQUIT là kết thúc tiến trình. Mọi lời gọi ở đây có thể chặn tới vài giây (máy ảo đang bận): không gọi trên luồng xử lý phím.
enum JavaAttach {
    enum Outcome: Equatable {
        case loaded
        /// Không thử: gửi tín hiệu cho tiến trình này không an toàn hoặc vô ích.
        case skipped(String)
        /// Không tới được máy ảo trong thời gian chờ (nó đang bận — khởi động, dọn bộ nhớ, bị trình gỡ lỗi giữ — hoặc đã tắt
        /// cơ chế attach): lát nữa thử lại có thể được.
        case unreachable(String)
        /// Máy ảo đã trả lời là không nạp: hỏi lại cũng vậy.
        case failed(String)
    }

    /// `start`: thời điểm khởi động của tiến trình (micro giây, như `proc_bsdinfo`) — pid đã sang tiến trình khác thì thôi.
    /// `wait`: thời gian tối đa chờ máy ảo mở cổng sau tín hiệu.
    static func loadAgent(pid: pid_t, start: UInt64?, jar: String, wait: Double = 5) -> Outcome {
        guard let request = JavaAttachWire.loadRequest(agentJar: jar) else {
            return .skipped("đường dẫn file trợ thủ có ký tự không gửi được")
        }
        guard access(jar, R_OK) == 0 else { return .skipped("không đọc được file trợ thủ") }
        guard let directory = temporaryDirectory() else { return .skipped("không rõ thư mục tạm của người dùng") }
        let socketPath = "\(directory).java_pid\(pid)"

        var fd = connect(socketPath)
        if fd < 0 {
            let trigger = "\(directory).attach_pid\(pid)"
            let file = open(trigger, O_CREAT | O_WRONLY | O_CLOEXEC, 0o600)
            guard file >= 0 else { return .failed("không tạo được file báo attach (errno \(errno))") }
            close(file)
            defer { unlink(trigger) }
            // Kiểm tra ngay trước khi gửi: đúng tiến trình đó, của mình, và đang bắt SIGQUIT.
            if let reason = unsafeToSignal(pid, start: start) { return .skipped(reason) }
            guard kill(pid, SIGQUIT) == 0 else { return .failed("không gửi được tín hiệu (errno \(errno))") }
            let deadline = now() + wait
            repeat {
                usleep(5_000)
                fd = connect(socketPath)
            } while fd < 0 && now() < deadline
            guard fd >= 0 else {
                return .unreachable("máy ảo không mở cổng attach (đang bận, đã tắt cơ chế attach, hoặc chạy trong sandbox)")
            }
        }
        defer { close(fd) }

        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { return .failed("cổng attach không phải của người dùng này") }
        guard send(fd, request) else { return .unreachable("không gửi được lệnh (errno \(errno))") }
        let reply = receive(fd)
        // Lệnh đã gửi mà hết thời gian chờ vẫn chưa có chữ nào: máy ảo có thể chạy nó sau — trợ thủ tự báo sự có mặt, và nạp
        // lần nữa không sao (trợ thủ chỉ khởi động một lần).
        guard !reply.isEmpty else { return .unreachable("máy ảo không trả lời") }
        switch JavaAttachWire.reply(reply) {
        case .loaded: return .loaded
        case .refused(let said): return .failed(said)
        }
    }

    /// Lý do không được gửi SIGQUIT cho `pid`; nil: gửi được.
    private static func unsafeToSignal(_ pid: pid_t, start: UInt64?) -> String? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return "tiến trình đã thoát" }
        if let start, bsd.pbi_start_tvsec &* 1_000_000 &+ bsd.pbi_start_tvusec != start { return "tiến trình đã thoát" }
        guard bsd.pbi_uid == getuid() else { return "tiến trình của người dùng khác" }
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &length, nil, 0) == 0, length > 0 else { return "tiến trình đã thoát" }
        guard info.kp_proc.p_sigcatch & (1 << UInt32(SIGQUIT - 1)) != 0 else {
            return "tiến trình không bắt SIGQUIT (máy ảo chạy với -Xrs, hoặc không phải HotSpot)"
        }
        return nil
    }

    /// Thư mục tạm của người dùng như HotSpot tìm (`os::get_temp_directory` trên macOS), có dấu "/" ở cuối.
    private static func temporaryDirectory() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard n > 1, n <= buffer.count else { return nil }
        let path = String(cString: buffer)
        return path.hasSuffix("/") ? path : path + "/"
    }

    private static func now() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_MONOTONIC, &t)
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
    }

    /// Nối tới socket Unix `path`; -1: chưa có ai nghe ở đó (kể cả file socket cũ của một tiến trình đã thoát).
    private static func connect(_ path: String) -> Int32 {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard connected == 0 else {
            close(fd)
            return -1
        }
        // Máy ảo đang bận (dừng ở điểm an toàn, bị trình gỡ lỗi giữ) không trả lời: không chờ mãi; ghi vào socket đã đóng
        // không được làm bộ gõ nhận SIGPIPE.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private static func send(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                sent += n
            } else if n < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    /// Đọc tới khi máy ảo đóng socket (nó đóng sau khi lệnh xong); tối đa 4 KB.
    private static func receive(_ fd: Int32) -> [UInt8] {
        var reply: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1024)
        while reply.count < 4096 {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                reply.append(contentsOf: chunk[0..<n])
            } else if n < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        return reply
    }
}
