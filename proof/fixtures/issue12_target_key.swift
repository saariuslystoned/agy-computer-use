// Inject one non-text key only into the explicitly disposable fixture process.
// This is a proof stimulus, never an AX production fallback.
import AppKit
import ApplicationServices
import Foundation
let pid = pid_t(CommandLine.arguments[1])!
guard let target = NSRunningApplication(processIdentifier: pid),
      target.bundleIdentifier == "com.saariuslystoned.issue12-ax-lab", !target.isActive else {
    fatalError("Expected the disposable background fixture")
}
let before = CGEvent(source: nil)!.location
for down in [true, false] {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: down)!
    event.postToPid(pid)
}
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
let after = CGEvent(source: nil)!.location
print("{\"target_pid\":\(pid),\"pointer_unchanged\":\(before == after)}")
