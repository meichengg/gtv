import Cocoa
print(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
