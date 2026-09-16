import AppKit
import ApplicationServices

final class Sentinel: NSObject, NSApplicationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 650, y: 200, width: 460, height: 220),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let field = NSTextField(string: "")
    var keys = 0
    var samples = 0
    var focusedSamples = 0
    var frontSamples = 0
    var eventMonitor: Any?
    let path = CommandLine.arguments[1]
    func applicationDidFinishLaunching(_ note: Notification) {
        window.title = "Issue 12 — Input Sentinel"
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 220))
        let label = NSTextField(wrappingLabelWithString: "Physical keyboard test: type test words below while the separate AX Lab changes in the background. No typed content is recorded in proof.")
        label.frame = NSRect(x: 25, y: 110, width: 410, height: 85)
        field.frame = NSRect(x: 25, y: 55, width: 410, height: 30)
        field.setAccessibilityIdentifier("issue12-sentinel-input")
        view.addSubview(label); view.addSubview(field); window.contentView = view
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(field)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.keys += 1
            return event
        }
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.sample() }
    }
    func sample() {
        samples += 1
        let focused = window.firstResponder === field.currentEditor() && field.currentEditor() != nil
        if focused { focusedSamples += 1 }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        if front { frontSamples += 1 }
        let d: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "window_id": window.windowNumber, "key_events": keys, "samples": samples,
            "focused_samples": focusedSamples, "front_samples": frontSamples,
            "field_is_first_responder": focused, "frontmost": front]
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Sentinel(); app.delegate = delegate; app.run()
