import Cocoa
let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
    if CommandLine.arguments.count > 1, String(pid) != CommandLine.arguments[1] { continue }
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(w[kCGWindowNumber as String] ?? 0, pid, w[kCGWindowOwnerName as String] ?? "", "'\(w[kCGWindowName as String] ?? "")'", b["X"] ?? 0, b["Y"] ?? 0, b["Width"] ?? 0, b["Height"] ?? 0, "layer", w[kCGWindowLayer as String] ?? 0)
}
