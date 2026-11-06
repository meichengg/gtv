import Cocoa
import ApplicationServices
// axdump <pid> [maxdepth] [filter]: cây AX của cửa sổ chính (vai trò, tên, mô tả, vị trí).
let a = CommandLine.arguments
let pid = Int32(a[1])!; let maxDepth = a.count > 2 ? Int(a[2])! : 8; let filter = a.count > 3 ? a[3].lowercased() : ""
let app = AXUIElementCreateApplication(pid)
func get(_ e: AXUIElement, _ n: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ n: String) -> String { (get(e, n) as? String) ?? "" }
func pos(_ e: AXUIElement) -> String {
    guard let p = get(e, kAXPositionAttribute), let s = get(e, kAXSizeAttribute) else { return "" }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return "@\(Int(pt.x)),\(Int(pt.y)) \(Int(sz.width))x\(Int(sz.height))"
}
func walk(_ e: AXUIElement, _ d: Int) {
    let line = "\(String(repeating: " ", count: d))\(str(e, kAXRoleAttribute)) '\(str(e, kAXTitleAttribute))' '\(str(e, kAXDescriptionAttribute))' \(pos(e))"
    if filter.isEmpty || line.lowercased().contains(filter) { print(line) }
    guard d < maxDepth, let kids = get(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
    for k in kids { walk(k, d + 1) }
}
if a.count > 4 && a[4] == "menu" { if let mb = get(app, kAXMenuBarAttribute) { walk(mb as! AXUIElement, 0) } }
else if let w = get(app, kAXFocusedWindowAttribute) { walk(w as! AXUIElement, 0) }
