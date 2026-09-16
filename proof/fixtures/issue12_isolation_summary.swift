import Foundation
import AppKit
import ApplicationServices
let target = pid_t(CommandLine.arguments[1])!
let sentinel = pid_t(CommandLine.arguments[2])!
let seconds = Double(CommandLine.arguments[3])!
let output = URL(fileURLWithPath: CommandLine.arguments[4])
let app = AXUIElementCreateApplication(sentinel)
let started = Date()
let firstKeys = CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown)
let firstMoves = CGEventSource.counterForEventType(.hidSystemState, eventType: .mouseMoved)
let startPoint = CGEvent(source: nil)?.location ?? .zero
var previousPoint = startPoint
var pointerChanges = 0
var samples = 0
var targetFront = 0
var sentinelFront = 0
var focusErrors = 0
var focusChanges = 0
var initialFocus: CFTypeRef?
while Date().timeIntervalSince(started) < seconds {
    samples += 1
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    if front == target { targetFront += 1 }
    if front == sentinel { sentinelFront += 1 }
    var focused: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
    if result != .success || focused == nil { focusErrors += 1 }
    else if let baseline = initialFocus {
        if !CFEqual(baseline, focused!) { focusChanges += 1 }
    } else { initialFocus = focused }
    let point = CGEvent(source: nil)?.location ?? .zero
    if point != previousPoint { pointerChanges += 1 }
    previousPoint = point
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
let d: [String: Any] = ["samples": samples, "elapsed_s": Date().timeIntervalSince(started),
    "target_front_samples": targetFront, "sentinel_front_samples": sentinelFront,
    "focus_read_errors": focusErrors, "focus_changes": focusChanges,
    "pointer_position_changes": pointerChanges,
    "hid_key_down_delta": CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown) - firstKeys,
    "hid_mouse_move_delta": CGEventSource.counterForEventType(.hidSystemState, eventType: .mouseMoved) - firstMoves]
try JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]).write(to: output)
