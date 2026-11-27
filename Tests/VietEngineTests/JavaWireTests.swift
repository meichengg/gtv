import XCTest
@testable import VietEngine

/// Giao ước với trợ thủ Java (JavaHelper/): bên Java đọc đúng những chuỗi này (JavaHelper/test, `Wire.parse`).
final class JavaWireTests: XCTestCase {
    func testEncodeReplacement() {
        XCTAssertEqual(JavaWire.encode(location: 12, length: 3, text: "đẳng"), "\u{7f}12\u{7f}3\u{7f}đẳng")
        XCTAssertEqual(JavaWire.encode(location: 0, length: 1, text: "đ"), "\u{7f}0\u{7f}1\u{7f}đ")
    }

    func testEncodeAtCaret() {
        XCTAssertEqual(JavaWire.encode(location: nil, length: 0, text: "ư"), "\u{7f}\u{7f}\u{7f}ư")
    }

    func testEncodeDeletionOnly() {
        XCTAssertEqual(JavaWire.encode(location: 5, length: 2, text: ""), "\u{7f}5\u{7f}2\u{7f}")
    }

    /// AWT chỉ chuyển chuỗi dài hơn một đơn vị UTF-16 cho Java khi đang xử lý phím.
    func testEncodedStringIsNeverOneUnit() {
        for text in ["", "a", "ư", "đẳng"] {
            XCTAssertGreaterThan(JavaWire.encode(location: nil, length: 0, text: text).utf16.count, 1)
            XCTAssertGreaterThan(JavaWire.encode(location: 0, length: 0, text: text).utf16.count, 1)
        }
    }

    func testStateRecord() {
        let record = Array("GTVJ1 D 42 1794900000".utf8) + [UInt8](repeating: 0x20, count: 42) + [0x0a]
        XCTAssertEqual(JavaWire.state(record), JavaWire.State(focus: .direct, serial: 42, start: 1_794_900_000))
        XCTAssertEqual(JavaWire.state(Array("GTVJ1 C 0 0\n".utf8)), JavaWire.State(focus: .compose, serial: 0, start: 0))
        XCTAssertEqual(JavaWire.state(Array("GTVJ1 N 7 5\n".utf8)), JavaWire.State(focus: JavaWire.Focus.none, serial: 7, start: 5))
    }

    func testStateRecordRejectsGarbage() {
        XCTAssertNil(JavaWire.state([UInt8](repeating: 0, count: 64)))
        XCTAssertNil(JavaWire.state(Array("GTVJ2 D 1 1\n".utf8)))
        XCTAssertNil(JavaWire.state(Array("GTVJ1 X 1 1\n".utf8)))
        XCTAssertNil(JavaWire.state(Array("GTVJ1 D x 1\n".utf8)))
        XCTAssertNil(JavaWire.state(Array("GTVJ1 D 1\n".utf8)))
    }

    // MARK: - Tự nạp trợ thủ vào máy ảo đang chạy (giao thức attach của HotSpot)

    /// Đúng dạng `VirtualMachine.loadAgent` của JDK gửi: bản giao thức, lệnh, ba tham số, mỗi chuỗi kết thúc bằng NUL.
    func testAttachLoadRequest() {
        let request = JavaAttachWire.loadRequest(agentJar: "/Users/a b/Library/GTV/gtv-java-helper.jar")
        XCTAssertEqual(request.map { String(decoding: $0, as: UTF8.self) },
                       "1\u{0}load\u{0}instrument\u{0}false\u{0}/Users/a b/Library/GTV/gtv-java-helper.jar\u{0}")
        XCTAssertEqual(request?.filter { $0 == 0 }.count, 5)
    }

    /// Máy ảo tách "<file>=<tham số>" ở dấu "=" đầu tiên: đường dẫn có "=" sẽ nạp nhầm file khác.
    func testAttachLoadRequestRejectsUnsendablePaths() {
        XCTAssertNil(JavaAttachWire.loadRequest(agentJar: ""))
        XCTAssertNil(JavaAttachWire.loadRequest(agentJar: "/tmp/a=b/gtv-java-helper.jar"))
        XCTAssertNil(JavaAttachWire.loadRequest(agentJar: "/tmp/a\u{0}b.jar"))
    }

    func testAttachReplyLoaded() {
        XCTAssertEqual(JavaAttachWire.reply(Array("0\nreturn code: 0\n".utf8)), .loaded)     // JDK 9 trở lên
        XCTAssertEqual(JavaAttachWire.reply(Array("0\n0\n".utf8)), .loaded)                   // JDK 8
    }

    /// Lời của máy ảo Java 25 khi chạy với -XX:-EnableDynamicAgentLoading, và các kiểu hỏng khác: không bao giờ coi là đã nạp.
    func testAttachReplyRefused() {
        let disabled = "Dynamic agent loading is not enabled. Use -XX:+EnableDynamicAgentLoading to launch target VM."
        XCTAssertEqual(JavaAttachWire.reply(Array("100\n\(disabled)\n".utf8)), .refused(disabled))
        XCTAssertEqual(JavaAttachWire.reply(Array("0\nreturn code: 102\n".utf8)), .refused("return code: 102"))
        XCTAssertEqual(JavaAttachWire.reply(Array("0\n100\n".utf8)), .refused("100"))
        XCTAssertEqual(JavaAttachWire.reply(Array("101\n".utf8)), .refused("mã 101"))
        XCTAssertEqual(JavaAttachWire.reply([UInt8]()), .refused("máy ảo không trả lời"))
        XCTAssertEqual(JavaAttachWire.reply(Array("0\n".utf8)), .refused("máy ảo không cho biết agent đã chạy chưa"))
        XCTAssertEqual(JavaAttachWire.reply(Array("0\nkhông phải số\n".utf8)), .refused("không phải số"))
    }

    /// Lời từ chối đi vào nhật ký: cắt bớt, không chép nguyên một trả lời dài.
    func testAttachReplyIsBounded() {
        let long = String(repeating: "x", count: 5000)
        guard case .refused(let said) = JavaAttachWire.reply(Array("1\n\(long)\n".utf8)) else { return XCTFail("phải là từ chối") }
        XCTAssertEqual(said.count, 200)
    }
}
