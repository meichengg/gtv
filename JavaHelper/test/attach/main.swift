// Chạy `JavaAttach` (mã của bộ gõ) với một máy ảo thật:  attach <pid> <file .jar>  — in kết quả, xem test.sh.
import Darwin

guard CommandLine.arguments.count == 3, let pid = pid_t(CommandLine.arguments[1]) else {
    print("dùng: attach <pid> <file .jar>")
    exit(2)
}
switch JavaAttach.loadAgent(pid: pid, start: nil, jar: CommandLine.arguments[2], wait: 2) {
case .loaded: print("loaded")
case .skipped(let why): print("skipped: \(why)")
case .unreachable(let why): print("unreachable: \(why)")
case .failed(let why): print("failed: \(why)")
}
