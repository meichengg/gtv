import Foundation

/// Nhật ký chẩn đoán.
enum DebugLog {
    private static let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")

    /// Nhật ký đầy đủ (có cả chữ đang gõ), chỉ có trong bản Debug: ~/Library/Logs/GTV-debug.log
    static func write(_ message: @autoclosure () -> String) {
        #if DEBUG
        append(message(), to: logs.appendingPathComponent("GTV-debug.log"))
        #endif
    }

    /// Sự kiện KHÔNG chứa chữ người dùng gõ (gắn / rời ô, loại ô, đường gõ, đổi chế độ và lý do). Bản Debug ghi chung vào
    /// nhật ký đầy đủ. Bản phát hành chỉ ghi khi người dùng bật:
    ///   defaults write com.gtv.inputmethod.GTV trace -bool true
    /// vào ~/Library/Logs/GTV-trace.log (tối đa 1 MB, giữ thêm một file cũ) — để lần ra lỗi chỉ gặp trên máy thật.
    static func event(_ message: @autoclosure () -> String) {
        #if DEBUG
        append(message(), to: logs.appendingPathComponent("GTV-debug.log"))
        #else
        guard UserDefaults.standard.bool(forKey: "trace") else { return }
        let url = logs.appendingPathComponent("GTV-trace.log")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1 << 20 {
            let old = logs.appendingPathComponent("GTV-trace.1.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        append(message(), to: url)
        #endif
    }

    private static func append(_ message: String, to url: URL) {
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
