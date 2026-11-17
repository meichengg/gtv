/// Giao ước giữa GTV và trợ thủ Java của nó (JavaHelper/, nạp vào máy ảo Java bằng `-javaagent`).
///
/// AWT của JDK gốc bỏ qua vùng cần thay mà bộ gõ gửi kèm chữ (`insertText:replacementRange:`), nhưng chuyển nguyên chuỗi đó
/// thành một InputMethodEvent đã chốt. Khi trong máy ảo có trợ thủ, GTV ghi vùng cần thay vào đầu chuỗi; trợ thủ đọc nó trên
/// luồng sự kiện của Java, chọn đúng vùng đó trong ô văn bản rồi cho ô chèn phần chữ — như JetBrains Runtime tự làm
/// (`CInputMethod.selectRange`). Mọi vị trí tính theo UTF-16.
public enum JavaWire {
    /// Dấu ngăn: DEL. Chuỗi chốt bắt đầu bằng ký tự điều khiển thì Swing bỏ qua cả chuỗi nếu trợ thủ không có mặt
    /// (DefaultKeyTypedAction) — không có chữ rác nào vào văn bản.
    public static let mark: Character = "\u{7f}"

    /// `DEL [vị trí] DEL [độ dài] DEL chữ`. `location` nil: chèn tại con trỏ (đè lên vùng đang chọn).
    /// Chuỗi luôn dài hơn một đơn vị UTF-16: AWT chỉ chuyển chuỗi như vậy cho Java khi đang xử lý phím (chuỗi một ký tự thì
    /// nó bỏ, phát lại phím gốc).
    public static func encode(location: Int?, length: Int, text: String) -> String {
        guard let location else { return "\(mark)\(mark)\(mark)\(text)" }
        return "\(mark)\(max(0, location))\(mark)\(max(0, length))\(mark)\(text)"
    }

    /// Điều trợ thủ báo cho GTV: `GTVJ1 <D|C> <số lần đổi focus> <giây khởi động tiến trình>` (bản ghi 64 byte ASCII trong
    /// ~/Library/Caches/com.gtv.inputmethod.GTV/java/<pid>).
    public struct State: Equatable, Sendable {
        /// Ô đang giữ focus là ô văn bản Swing / AWT sửa được: thay chữ trực tiếp qua trợ thủ.
        public var direct: Bool
        /// Số lần ô giữ focus đổi — kể cả giữa hai ô trong cùng cửa sổ, việc bộ gõ không tự thấy.
        public var serial: Int
        /// Thời điểm tiến trình Java khởi động (giây); 0: không rõ.
        public var start: Int

        public init(direct: Bool, serial: Int, start: Int) {
            self.direct = direct
            self.serial = serial
            self.start = start
        }
    }

    public static func state<S: Sequence>(_ record: S) -> State? where S.Element == UInt8 {
        let fields = String(decoding: Array(record), as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\0" })
        guard fields.count >= 4, fields[0] == "GTVJ1", fields[1] == "D" || fields[1] == "C",
              let serial = Int(fields[2]), let start = Int(fields[3]) else { return nil }
        return State(direct: fields[1] == "D", serial: serial, start: start)
    }
}
