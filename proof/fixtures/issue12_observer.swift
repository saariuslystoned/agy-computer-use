import Foundation
import AppKit
import ApplicationServices
let output = URL(fileURLWithPath: CommandLine.arguments[1])
FileManager.default.createFile(atPath: output.path, contents: nil)
let file = try FileHandle(forWritingTo: output)
let system = AXUIElementCreateSystemWide()
for _ in 0..<3600 {
    var focused: CFTypeRef?
    let focusResult = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
    let point = CGEvent(source: nil)?.location ?? .zero
    let sample: [String: Any] = ["at_ms": Int(Date().timeIntervalSince1970 * 1000),
        "x": point.x, "y": point.y,
        "frontmost_pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
        "focused_hash": focused.map { String(CFHash($0)) } ?? "unavailable",
        "focus_status": focusResult.rawValue,
        "mouse_moves": CGEventSource.counterForEventType(.combinedSessionState, eventType: .mouseMoved),
        "key_downs": CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)]
    let data = try JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys])
    try file.write(contentsOf: data + Data([10]))
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
try file.close()
