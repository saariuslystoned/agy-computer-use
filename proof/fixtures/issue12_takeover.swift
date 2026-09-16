// Disposable-fixture takeover proof only. Never target another application.
import AppKit
import Foundation
let pid = pid_t(CommandLine.arguments[1])!
guard let target = NSRunningApplication(processIdentifier: pid),
      target.bundleIdentifier == "com.saariuslystoned.issue12-ax-lab",
      let original = NSWorkspace.shared.frontmostApplication,
      original.processIdentifier != pid else { fatalError("Fixture must start in background") }
let start = Int(Date().timeIntervalSince1970 * 1000)
let activated = target.activate(options: [])
RunLoop.current.run(until: Date().addingTimeInterval(0.4))
let during = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
let restored = original.activate(options: [])
RunLoop.current.run(until: Date().addingTimeInterval(0.4))
let after = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
let result: [String: Any] = ["at_ms": start, "target_pid": pid,
    "before_pid": original.processIdentifier, "during_pid": during,
    "after_pid": after, "activate_returned": activated, "restore_returned": restored]
print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
guard activated, restored, during == pid, after == original.processIdentifier else { exit(1) }
