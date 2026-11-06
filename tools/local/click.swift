import Cocoa
// click x y [count]: click chuột trái tại điểm màn hình (toạ độ điểm, gốc trên-trái).
let a = CommandLine.arguments
guard a.count >= 3, let x = Double(a[1]), let y = Double(a[2]) else { exit(2) }
let n = a.count > 3 ? Int(a[3]) ?? 1 : 1
let p = CGPoint(x: x, y: y)
let src = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(80000)
for i in 1...n {
    let d = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)!
    d.setIntegerValueField(.mouseEventClickState, value: Int64(i))
    d.post(tap: .cghidEventTap); usleep(30000)
    let u = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)!
    u.setIntegerValueField(.mouseEventClickState, value: Int64(i))
    u.post(tap: .cghidEventTap); usleep(60000)
}
