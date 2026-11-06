import Cocoa
import ApplicationServices
print("postEvent:", CGPreflightPostEventAccess())
print("listenEvent:", CGPreflightListenEventAccess())
print("axTrusted:", AXIsProcessTrusted())
print("screenCapture:", CGPreflightScreenCaptureAccess())
print("pid:", getpid(), "ppid:", getppid())
