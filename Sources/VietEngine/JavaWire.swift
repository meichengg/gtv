/// Giao ước giữa GTV và trợ thủ Java của nó (JavaHelper/, nạp vào máy ảo Java bằng `-javaagent`).
///
/// AWT của JDK gốc bỏ qua vùng cần thay mà bộ gõ gửi kèm chữ (`insertText:replacementRange:`), nhưng chuyển nguyên chuỗi đó
/// thành một InputMethodEvent đã chốt. Khi trong máy ảo có trợ thủ, GTV ghi vùng cần thay vào đầu chuỗi; trợ thủ đọc nó trên
/// luồng sự kiện của Java, chọn đúng vùng đó trong ô văn bản rồi cho ô chèn phần chữ — như JetBrains Runtime tự làm
/// (`CInputMethod.selectRange`). Mọi vị trí tính theo UTF-16.
public enum JavaWire {
    /// Dấu ngăn: DEL. Chỉ gửi dạng này khi file trạng thái của máy ảo cho biết trợ thủ đang có mặt (`JavaHelper.state`):
    /// không có trợ thủ thì ô Swing chỉ bỏ riêng ký tự DEL, các chữ số của vị trí / độ dài vẫn vào văn bản.
    public static let mark: Character = "\u{7f}"

    /// `DEL [vị trí] DEL [độ dài] DEL chữ`. `location` nil: chèn tại con trỏ (đè lên vùng đang chọn).
    /// Chuỗi luôn dài hơn một đơn vị UTF-16: AWT chỉ chuyển chuỗi như vậy cho Java khi đang xử lý phím (chuỗi một ký tự thì
    /// nó bỏ, phát lại phím gốc).
    public static func encode(location: Int?, length: Int, text: String) -> String {
        guard let location else { return "\(mark)\(mark)\(mark)\(text)" }
        return "\(mark)\(max(0, location))\(mark)\(max(0, length))\(mark)\(text)"
    }

    /// Ô đang giữ focus trong cửa sổ Java là loại gì với bộ gõ.
    public enum Focus: Equatable, Sendable {
        /// Ô văn bản Swing / AWT sửa được: thay chữ trực tiếp qua trợ thủ.
        case direct
        /// Ô tự vẽ của ứng dụng: soạn từng từ như khi không có trợ thủ.
        case compose
        /// Không nhận chữ (bảng, cây, nút, tab, ô văn bản chỉ đọc, không ô nào): phím là lệnh của ứng dụng — để đi thẳng.
        case none
    }

    /// Điều trợ thủ báo cho GTV: `GTVJ1 <D|C|N> <số lần đổi focus> <giây khởi động tiến trình>` (bản ghi 64 byte ASCII trong
    /// ~/Library/GTV/state/<pid>).
    public struct State: Equatable, Sendable {
        public var focus: Focus
        /// Số lần ô giữ focus đổi — kể cả giữa hai ô trong cùng cửa sổ, việc bộ gõ không tự thấy.
        public var serial: Int
        /// Thời điểm tiến trình Java khởi động (giây); 0: không rõ.
        public var start: Int

        public init(focus: Focus, serial: Int, start: Int) {
            self.focus = focus
            self.serial = serial
            self.start = start
        }
    }

    public static func state<S: Sequence>(_ record: S) -> State? where S.Element == UInt8 {
        let fields = String(decoding: Array(record), as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\0" })
        guard fields.count >= 4, fields[0] == "GTVJ1", let serial = Int(fields[2]), let start = Int(fields[3]) else { return nil }
        let focus: Focus
        switch fields[1] {
        case "D": focus = .direct
        case "C": focus = .compose
        case "N": focus = .none
        default: return nil
        }
        return State(focus: focus, serial: serial, start: start)
    }
}

/// Giao thức attach của HotSpot (bản 1) — phần GTV dùng để tự nạp trợ thủ vào một máy ảo Java đang chạy (`JavaAttach` trong
/// GTVInput), như `VirtualMachine.loadAgent` của JDK. Yêu cầu là các chuỗi kết thúc bằng NUL: bản giao thức, tên lệnh, rồi
/// đúng ba tham số. Trả lời là một dòng mã kết quả của lệnh (0: máy ảo đã chạy lệnh), sau đó là phần chữ lệnh in ra.
public enum JavaAttachWire {
    /// Lệnh nạp một agent Java: `load instrument false <file .jar>`.
    /// nil: đường dẫn không gửi được — thư viện instrument của máy ảo tách "<file>=<tham số>" ở dấu "=" đầu tiên.
    public static func loadRequest(agentJar: String) -> [UInt8]? {
        guard !agentJar.isEmpty, !agentJar.utf8.contains(0), !agentJar.utf8.contains(UInt8(ascii: "=")) else { return nil }
        var bytes: [UInt8] = []
        for field in ["1", "load", "instrument", "false", agentJar] {
            bytes.append(contentsOf: field.utf8)
            bytes.append(0)
        }
        return bytes
    }

    public enum Reply: Equatable, Sendable {
        case loaded
        /// Máy ảo không nạp (đã tắt việc nạp agent lúc chạy, thiếu module java.instrument, agent báo lỗi…), kèm lời nó nói.
        case refused(String)
    }

    /// Đọc trả lời của lệnh `load`. Sau dòng mã kết quả, JDK 9 trở lên in "return code: <n>" (n: giá trị Agent_OnAttach trả
    /// về, 0 là agent đã chạy), JDK 8 chỉ in "<n>".
    public static func reply<S: Sequence>(_ bytes: S) -> Reply where S.Element == UInt8 {
        let lines = String(decoding: Array(bytes), as: UTF8.self)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { String($0.drop(while: { $0 == " " })) }
        guard let status = lines.first else { return .refused("máy ảo không trả lời") }
        let said = String(lines.dropFirst().joined(separator: " ").prefix(200))
        guard status == "0" else { return .refused(said.isEmpty ? "mã \(status)" : said) }
        guard lines.count > 1 else { return .refused("máy ảo không cho biết agent đã chạy chưa") }
        let prefix = "return code: "
        let code = lines[1].hasPrefix(prefix) ? String(lines[1].dropFirst(prefix.count)) : lines[1]
        return Int(code) == 0 ? .loaded : .refused(said)
    }
}
