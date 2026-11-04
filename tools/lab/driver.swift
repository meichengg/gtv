// Gõ phím giả (như bàn phím thật, qua HID) vào ứng dụng đang ở trước. Chỉ dùng trong IME Lab (máy ảo CI).
//   driver <bundleID mong đợi> <ms giữa 2 phím> <chuỗi>
// Phím đặc biệt: {BS} {RET} {TAB} {ESC} {LEFT} {RIGHT} {UP} {DOWN} {CA} {CE} {CU} {CX} {CQ}=Ctrl+\ {CMDN}
// Lệnh: {WAIT<ms>}  {IS:vi} {IS:en} {IS:abc} (chọn input source)  {MS:<ms>} (đổi khoảng cách giữa 2 phím)
// Dừng ngay (mã 3) nếu ứng dụng phía trước không phải <bundleID> ("-" = không kiểm tra).
import Carbon
import Cocoa

let args = CommandLine.arguments
guard args.count >= 4 else { print("usage: driver <bundleID|-> <ms> <keys>"); exit(2) }
let expected = args[1]
var delay = useconds_t((Int(args[2]) ?? 50) * 1000)

let keys: [Character: (CGKeyCode, Bool)] = {
    var m: [Character: (CGKeyCode, Bool)] = [:]
    let plain: [(String, CGKeyCode)] = [
        ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
        ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19),
        ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28),
        ("0", 29), ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37), ("j", 38),
        ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44), ("n", 45), ("m", 46), (".", 47),
        (" ", 49), ("`", 50),
    ]
    for (s, k) in plain { m[Character(s)] = (k, false) }
    for (s, k) in plain where s.first!.isLetter { m[Character(s.uppercased())] = (k, true) }
    let shifted: [(String, CGKeyCode)] = [
        ("!", 18), ("@", 19), ("#", 20), ("$", 21), ("%", 23), ("^", 22), ("&", 26), ("*", 28), ("(", 25),
        (")", 29), ("_", 27), ("+", 24), ("{", 33), ("}", 30), ("|", 42), (":", 41), ("\"", 39), ("<", 43),
        (">", 47), ("?", 44), ("~", 50),
    ]
    for (s, k) in shifted { m[Character(s)] = (k, true) }
    return m
}()

let special: [String: (CGKeyCode, CGEventFlags, String?)] = [
    "BS": (51, [], "\u{7f}"), "RET": (36, [], "\r"), "TAB": (48, [], "\t"), "ESC": (53, [], "\u{1b}"),
    "LEFT": (123, [], nil), "RIGHT": (124, [], nil), "DOWN": (125, [], nil), "UP": (126, [], nil),
    "CA": (0, .maskControl, "\u{01}"), "CE": (14, .maskControl, "\u{05}"), "CU": (32, .maskControl, "\u{15}"),
    "CX": (7, .maskControl, "\u{18}"), "CQ": (42, .maskControl, "\u{1c}"), "CMDN": (45, .maskCommand, "n"),
]

// Biến môi trường để dò cách phím giả đi qua bộ gõ: DRIVER_SOURCE=hid|combined|private,
// DRIVER_TAP=hid|session|annotated, DRIVER_UNICODE=1|0, DRIVER_KBTYPE=<số>
let env = ProcessInfo.processInfo.environment
let source = CGEventSource(stateID: ["combined": .combinedSessionState, "private": .privateState][env["DRIVER_SOURCE"] ?? ""]
                                    ?? .hidSystemState)
let tapLocation: CGEventTapLocation = ["session": .cgSessionEventTap, "annotated": .cgAnnotatedSessionEventTap][env["DRIVER_TAP"] ?? ""]
    ?? .cghidEventTap
let setUnicode = env["DRIVER_UNICODE"] != "0"
let keyboardType = env["DRIVER_KBTYPE"].flatMap { Int64($0) }

func front() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "" }

func check() {
    if expected != "-" && front() != expected {
        FileHandle.standardError.write("ABORT: phía trước là \(front()), không phải \(expected)\n".data(using: .utf8)!)
        exit(3)
    }
}

func post(_ code: CGKeyCode, _ flags: CGEventFlags, _ text: String?) {
    check()
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
        e.flags = flags
        if let keyboardType { e.setIntegerValueField(.keyboardEventKeyboardType, value: keyboardType) }
        if setUnicode, let text {
            let u = Array(text.utf16)
            e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
        }
        e.post(tap: tapLocation)
        if down { usleep(6000) }
    }
}

func selectInputSource(_ id: String) {
    let full = ["vi": "com.gtv.inputmethod.GTV.vi", "en": "com.gtv.inputmethod.GTV.en",
                "abc": "com.apple.keylayout.ABC"][id] ?? id
    let list = TISCreateInputSourceList([kTISPropertyInputSourceID as String: full] as CFDictionary, true)?
        .takeRetainedValue() as? [TISInputSource] ?? []
    guard let s = list.first else {
        let all = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] ?? []
        var info = ""
        for src in all {
            guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { continue }
            let sid = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
            guard sid.contains("gtv") else { continue }
            let en = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsEnabled).map {
                Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue() == kCFBooleanTrue } ?? false
            info += " \(sid)(enabled=\(en))"
        }
        FileHandle.standardError.write("không thấy input source \(full); GTV đã cài:\(info)\n".data(using: .utf8)!)
        exit(4)
    }
    TISSelectInputSource(s)
    usleep(250_000)
}

if ProcessInfo.processInfo.environment["DRIVER_VERBOSE"] != nil {
    FileHandle.standardError.write("AX trusted=\(AXIsProcessTrusted()) postEvent=\(CGPreflightPostEventAccess())\n".data(using: .utf8)!)
}

var s = Substring(args[3])
while let c = s.first {
    if c == "{", let end = s.firstIndex(of: "}") {
        let name = String(s[s.index(after: s.startIndex)..<end])
        s = s[s.index(after: end)...]
        if name.hasPrefix("WAIT") { usleep(useconds_t(Int(name.dropFirst(4)) ?? 0) * 1000); continue }
        if name.hasPrefix("MS:") { delay = useconds_t((Int(name.dropFirst(3)) ?? 50) * 1000); continue }
        if name.hasPrefix("IS:") { selectInputSource(String(name.dropFirst(3))); continue }
        guard let (k, f, t) = special[name] else { print("phím lạ: \(name)"); exit(2) }
        post(k, f, t)
    } else {
        s = s.dropFirst()
        guard let (k, shift) = keys[c] else { print("không có phím cho '\(c)'"); exit(2) }
        post(k, shift ? .maskShift : [], String(c))
    }
    usleep(delay)
}
