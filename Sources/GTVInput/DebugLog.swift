import Foundation

/// Nhật ký chẩn đoán.
enum DebugLog {
    private static let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    /// Ghi file ở hàng đợi riêng, lần lượt: bật nhật ký thì mỗi phím là một dòng — không mở / ghi / đóng file trên luồng
    /// chính (luồng xử lý phím).
    private static let queue = DispatchQueue(label: "gtv.debug-log", qos: .utility)

    /// Nhật ký đầy đủ (có cả chữ đang gõ), chỉ có trong bản Debug: ~/Library/Logs/GTV-debug.log
    static func write(_ message: @autoclosure () -> String) {
        #if DEBUG
        append(message(), to: logs.appendingPathComponent("GTV-debug.log"), limit: nil)
        #endif
    }

    /// Sự kiện KHÔNG chứa chữ người dùng gõ (gắn / rời ô, loại ô, đường gõ, đổi chế độ và lý do). Bản Debug ghi chung vào
    /// nhật ký đầy đủ. Bản phát hành chỉ ghi khi người dùng bật:
    ///   defaults write com.gtv.inputmethod.GTV trace -bool true
    /// vào ~/Library/Logs/GTV-trace.log (tối đa 1 MB, giữ thêm một file cũ) — để lần ra lỗi chỉ gặp trên máy thật.
    static func event(_ message: @autoclosure () -> String) {
        #if DEBUG
        append(message(), to: logs.appendingPathComponent("GTV-debug.log"), limit: nil)
        #else
        guard UserDefaults.standard.bool(forKey: "trace") else { return }
        append(message(), to: logs.appendingPathComponent("GTV-trace.log"), limit: 1 << 20)
        #endif
    }

    /// Dòng được dựng (và đóng dấu giờ) ngay tại nơi gọi; phần ghi file chạy sau, đúng thứ tự. Mọi lỗi ghi (đĩa đầy, file bị
    /// khoá, thư mục mất) đều bỏ qua: nhật ký không bao giờ được làm bộ gõ dừng — `seekToEndOfFile()` / `write(_:)` kiểu cũ
    /// ném NSException khi ghi lỗi, không ai bắt thì tiến trình chết ở mỗi phím.
    private static func append(_ message: String, to url: URL, limit: Int?) {
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if let limit, let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit {
                let old = url.deletingPathExtension().appendingPathExtension("1.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                guard (try? handle.seekToEnd()) != nil else { return }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
