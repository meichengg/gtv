import Cocoa
import ApplicationServices
// axval <pid>: giá trị (AXValue) và vai trò của phần tử đang focus trong ứng dụng.
let pid = Int32(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)
var f: CFTypeRef?
guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &f) == .success, let el = f else { print("NOFOCUS"); exit(1) }
let e = el as! AXUIElement
func attr(_ n: String) -> String {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success, let v else { return "" }
    return "\(v)"
}
if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "role" { print(attr(kAXRoleAttribute), attr(kAXDescriptionAttribute)); exit(0) }
var v: CFTypeRef?
if AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &v) == .success, let s = v as? String {
    FileHandle.standardOutput.write(s.data(using: .utf8)!)
} else { print("NOVALUE role=\(attr(kAXRoleAttribute))"); exit(1) }
