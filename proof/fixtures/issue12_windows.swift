import AppKit

final class ProofWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// Disposable proof app. The controller file is a fixture stimulus, not an input
// route in ComputerUseHost. It never operates another application's windows.
final class WindowsLab: NSObject, NSApplicationDelegate {
    var windows: [String: NSWindow] = [:]
    var fields: [String: NSTextField] = [:]
    var alert: NSAlert?
    var sequence = 0
    var completed: String = ""
    let statePath = CommandLine.arguments[1]
    let commandPath = CommandLine.arguments[2]
    func make(_ key: String, origin: NSPoint) {
        let window = ProofWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 350, height: 170)),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Issue 12 — Window " + key
        window.setAccessibilityIdentifier("issue12-window-" + key)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 170))
        let label = NSTextField(labelWithString: "Exact target " + key)
        label.frame = NSRect(x: 20, y: 110, width: 310, height: 30)
        let field = NSTextField(string: "before-" + key)
        field.frame = NSRect(x: 20, y: 55, width: 310, height: 30)
        field.setAccessibilityIdentifier("issue12-input-" + key)
        view.addSubview(label); view.addSubview(field); window.contentView = view
        windows[key] = window; fields[key] = field; window.orderFrontRegardless()
    }
    func applicationDidFinishLaunching(_ note: Notification) {
        make("A", origin: NSPoint(x: 100, y: 520))
        make("B", origin: NSPoint(x: 520, y: 520))
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
    }
    func tick() {
        if let bytes = try? Data(contentsOf: URL(fileURLWithPath: commandPath)),
           let command = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
           let id = command["id"] as? String, id != completed {
            let key = command["window"] as? String ?? "A"
            switch command["op"] as? String {
            case "move":
                if let x = command["x"] as? Double, let y = command["y"] as? Double {
                    windows[key]?.setFrameOrigin(NSPoint(x: x, y: y))
                }
            case "replace":
                let origin = windows[key]?.frame.origin ?? NSPoint(x: 520, y: 520)
                windows[key]?.close(); make(key, origin: origin)
            case "dialog": make("Dialog", origin: NSPoint(x: 350, y: 350))
            case "close-dialog": windows["Dialog"]?.close(); windows["Dialog"] = nil; fields["Dialog"] = nil
            case "sheet":
                let sheet = NSAlert(); sheet.messageText = "Issue 12 — Modal dialog"
                alert = sheet
                if let parent = windows["A"] { sheet.beginSheetModal(for: parent) { [weak self] _ in self?.alert = nil } }
            case "close-sheet":
                if let parent = windows["A"], let sheet = parent.attachedSheet {
                    parent.endSheet(sheet); sheet.orderOut(nil)
                }
            default: break
            }
            completed = id; sequence += 1
        }
        let all = windows.mapValues { window in ["window_id": window.windowNumber, "visible": window.isVisible] as [String: Any] }
        let state: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "sheet_window_id": windows["A"]?.attachedSheet?.windowNumber ?? 0, "windows": all, "values": fields.mapValues { $0.stringValue }, "sequence": sequence, "completed": completed]
        if let bytes = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? bytes.write(to: URL(fileURLWithPath: statePath), options: [.atomic])
        }
    }
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let delegate = WindowsLab(); app.delegate = delegate; app.run()
