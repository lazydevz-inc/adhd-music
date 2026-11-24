// Captures the on-screen windows of a process into PNG files (development screenshots).
// Usage: swift Scripts/snap.swift <pid> <output-prefix>
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[1]) else {
    print("usage: snap.swift <pid> <output-prefix>")
    exit(1)
}
let prefix = args[2]
let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
var index = 0
for window in list where (window[kCGWindowOwnerPID as String] as? Int32) == pid {
    guard let number = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Double],
          (bounds["Width"] ?? 0) > 60, (bounds["Height"] ?? 0) > 60 else { continue }
    let name = (window[kCGWindowName as String] as? String) ?? ""
    let out = "\(prefix)-\(index).png"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-o", "-l", String(number), out]
    try? task.run()
    task.waitUntilExit()
    print("\(out)\t\(number)\t\(name)\t\(Int(bounds["Width"] ?? 0))x\(Int(bounds["Height"] ?? 0))")
    index += 1
}
