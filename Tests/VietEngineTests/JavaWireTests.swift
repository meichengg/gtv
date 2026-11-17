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
        XCTAssertEqual(JavaWire.state(record), JavaWire.State(direct: true, serial: 42, start: 1_794_900_000))
        XCTAssertEqual(JavaWire.state(Array("GTVJ1 C 0 0\n".utf8)), JavaWire.State(direct: false, serial: 0, start: 0))
    }

    func testStateRecordRejectsGarbage() {
        XCTAssertNil(JavaWire.state([UInt8](repeating: 0, count: 64)))
        XCTAssertNil(JavaWire.state(Array("GTVJ2 D 1 1\n".utf8)))
        XCTAssertNil(JavaWire.state(Array("GTVJ1 X 1 1\n".utf8)))
        XCTAssertNil(JavaWire.state(Array("GTVJ1 D x 1\n".utf8)))
        XCTAssertNil(JavaWire.state(Array("GTVJ1 D 1\n".utf8)))
    }
}
