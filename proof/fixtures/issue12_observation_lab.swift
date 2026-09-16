import AppKit

// Proof-only fault injection at the real AX application boundary.
// Ordinary mode retains the original disposable AppKit form behavior.
var hiddenUntil = Date.distantPast
let faultMode = CommandLine.arguments.dropFirst(2).first ?? "normal"
final class ObservationApplication: NSApplication {
    override func accessibilityChildren() -> [Any]? {
        if Date() < hiddenUntil { return [] }
        return windows.filter { $0.isVisible }
    }
}
final class ObservationField: NSTextField {
    override func setAccessibilityValue(_ value: Any?) {
        if let text = value as? String { stringValue = text }
        if faultMode == "transient" { hiddenUntil = Date().addingTimeInterval(0.25) }
        if faultMode == "missing" { hiddenUntil = Date().addingTimeInterval(3) }
        if faultMode == "exit-after-set" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { NSApp.terminate(nil) }
        }
    }
}

final class Lab: NSObject, NSApplicationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 440, height: 260),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let display = NSTextField(labelWithString: "0")
    let field = ObservationField(string: "before")
    var expression = ""
    let statePath = CommandLine.arguments[1]
    func applicationDidFinishLaunching(_ note: Notification) {
        window.title = "Issue 12 — Disposable AX Lab"
        window.setAccessibilityIdentifier("issue12-window")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 260))
        display.frame = NSRect(x: 25, y: 195, width: 390, height: 35)
        display.font = .monospacedDigitSystemFont(ofSize: 26, weight: .medium)
        display.setAccessibilityIdentifier("issue12-result")
        view.addSubview(display)
        for (i, title) in ["2", "+", "3", "=", "Clear"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(press(_:)))
            button.frame = NSRect(x: 25 + i * 78, y: 130, width: 70, height: 40)
            button.setAccessibilityIdentifier("issue12-" + title)
            view.addSubview(button)
        }
        let label = NSTextField(labelWithString: "Disposable test value")
        label.frame = NSRect(x: 25, y: 90, width: 380, height: 20)
        view.addSubview(label)
        field.frame = NSRect(x: 25, y: 45, width: 380, height: 30)
        field.setAccessibilityIdentifier("issue12-input")
        view.addSubview(field)
        window.contentView = view
        window.orderFrontRegardless()
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.writeState() }
        writeState()
    }
    @objc func press(_ sender: NSButton) {
        switch sender.title {
        case "Clear": expression = ""; display.stringValue = "0"
        case "=": display.stringValue = expression == "2+3" ? "5" : "invalid"
        default: expression += sender.title; display.stringValue = expression
        }
        writeState()
    }
    func writeState() {
        let dict: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "window_id": window.windowNumber, "display": display.stringValue,
            "field": field.stringValue, "expression": expression]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: statePath), options: [.atomic])
        }
    }
}
let app = ObservationApplication.shared
app.setActivationPolicy(.accessory)
let lab = Lab()
app.delegate = lab
app.run()
