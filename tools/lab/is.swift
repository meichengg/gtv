// is get | is select <id> | is enable <id> | is list   — đọc / chọn / liệt kê input source (IME Lab).
import Carbon

func prop(_ s: TISInputSource, _ k: CFString) -> AnyObject? {
    guard let p = TISGetInputSourceProperty(s, k) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue()
}

let a = CommandLine.arguments
switch a.count >= 2 ? a[1] : "get" {
case "enable" where a.count >= 3:
    let list = TISCreateInputSourceList([kTISPropertyInputSourceID as String: a[2]] as CFDictionary, true)?
        .takeRetainedValue() as? [TISInputSource] ?? []
    guard let s = list.first else { print("not found: \(a[2])"); exit(1) }
    print("enable \(a[2]): \(TISEnableInputSource(s))")
case "select" where a.count >= 3:
    // Tìm trong mọi input source đã cài: trên máy ảo CI, bộ gõ cha có thể chưa bật dù chế độ đã bật.
    let list = TISCreateInputSourceList([kTISPropertyInputSourceID as String: a[2]] as CFDictionary, true)?
        .takeRetainedValue() as? [TISInputSource] ?? []
    guard let s = list.first else { print("not found: \(a[2])"); exit(1) }
    let status = TISSelectInputSource(s)
    if status != noErr { print("select error \(status)") }
    usleep(200_000)
    fallthrough
case "get":
    print(prop(TISCopyCurrentKeyboardInputSource().takeRetainedValue(), kTISPropertyInputSourceID) as? String ?? "-")
case "list":
    let all = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] ?? []
    for s in all {
        let id = prop(s, kTISPropertyInputSourceID) as? String ?? "-"
        let enabled = (prop(s, kTISPropertyInputSourceIsEnabled) as? NSNumber)?.boolValue ?? false
        let selectable = (prop(s, kTISPropertyInputSourceIsSelectCapable) as? NSNumber)?.boolValue ?? false
        if id.contains("gtv") || enabled { print("\(id) enabled=\(enabled) selectable=\(selectable)") }
    }
default:
    print("usage: is get | is select <id> | is list")
}
