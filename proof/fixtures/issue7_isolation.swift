import Foundation
import AppKit
import ApplicationServices
let host = Int64(CommandLine.arguments[1])!
let target = pid_t(CommandLine.arguments[2])!
let sentinel = pid_t(CommandLine.arguments[3])!
let seconds = Double(CommandLine.arguments[4])!
let output = URL(fileURLWithPath: CommandLine.arguments[5])
final class Counts { var hostPosts = 0; var coverage = true }
let counts = Counts()
let types: [CGEventType] = [.mouseMoved,.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged,.keyDown,.keyUp,.flagsChanged,.scrollWheel]
let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _,type,event,_ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { counts.coverage=false }
    if event.getIntegerValueField(.eventSourceUnixProcessID)==host { counts.hostPosts += 1 }
    return Unmanaged.passUnretained(event)
}, userInfo: nil)
var tapCount: UInt32=0
var complete=false
if let tap, let source=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,tap,0) {
    CFRunLoopAddSource(CFRunLoopGetCurrent(),source,.defaultMode)
    if CGGetEventTapList(0,nil,&tapCount) == .success, tapCount>0 {
        var infos=[CGEventTapInformation](repeating:CGEventTapInformation(),count:Int(tapCount))
        if CGGetEventTapList(tapCount,&infos,&tapCount) == .success {
            complete=infos.prefix(Int(tapCount)).contains { $0.tappingProcess==getpid() && $0.enabled && ($0.eventsOfInterest & mask)==mask }
        }
    }
}
let app=AXUIElementCreateApplication(sentinel)
AXUIElementSetMessagingTimeout(app,0.1)
let started=Date()
let initialMoves=CGEventSource.counterForEventType(.hidSystemState,eventType:.mouseMoved)
let initialKeys=CGEventSource.counterForEventType(.hidSystemState,eventType:.keyDown)
var samples=0, targetFront=0, sentinelFront=0, focusErrors=0, focusChanges=0, pointerChanges=0
var initialFocus: CFTypeRef?
var previous=CGEvent(source:nil)?.location
while Date().timeIntervalSince(started)<seconds {
    samples+=1
    let front=NSWorkspace.shared.frontmostApplication?.processIdentifier
    if front==target {targetFront+=1}; if front==sentinel {sentinelFront+=1}
    var focus: CFTypeRef?
    if AXUIElementCopyAttributeValue(app,kAXFocusedUIElementAttribute as CFString,&focus) != .success || focus==nil {focusErrors+=1}
    else if let initialFocus {if !CFEqual(initialFocus,focus!) {focusChanges+=1}} else {initialFocus=focus}
    let point=CGEvent(source:nil)?.location
    if point != previous {pointerChanges+=1}; previous=point
    RunLoop.current.run(until:Date().addingTimeInterval(0.05))
}
if let tap {complete = complete && CGEvent.tapIsEnabled(tap:tap); CFMachPortInvalidate(tap)}
let result:[String:Any]=["host_pid":host,"samples":samples,"elapsed_s":Date().timeIntervalSince(started),
    "target_front_samples":targetFront,"sentinel_front_samples":sentinelFront,"focus_read_errors":focusErrors,
    "focus_changes":focusChanges,"pointer_position_changes":pointerChanges,"host_event_posts":counts.hostPosts,
    "event_tap_coverage":complete && counts.coverage,
    "hid_mouse_move_delta":CGEventSource.counterForEventType(.hidSystemState,eventType:.mouseMoved)-initialMoves,
    "hid_key_down_delta":CGEventSource.counterForEventType(.hidSystemState,eventType:.keyDown)-initialKeys]
try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output)
