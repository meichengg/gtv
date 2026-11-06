import Cocoa
// activate <pid>: đưa ứng dụng lên trước.
guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]),
      let app = NSRunningApplication(processIdentifier: pid) else { exit(1) }
app.activate(options: [.activateAllWindows])
