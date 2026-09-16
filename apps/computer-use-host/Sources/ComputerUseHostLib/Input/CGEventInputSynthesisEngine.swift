import Foundation
import CoreGraphics
import ApplicationServices

package protocol GlobalEventPosting: Sendable {
    func post(_ event: CGEvent)
}
private struct SystemGlobalEventPoster: GlobalEventPosting {
    func post(_ event: CGEvent) { event.post(tap: .cghidEventTap) }
}

package struct GlobalInputFailure: Error, Sendable {
    package let underlying: ComputerUseError
    package let posts: Int
    package let cleanupPosts: Int
    package var code: String { posts == 0 ? underlying.errorCode : "OUTCOME_UNKNOWN" }
    package var message: String { posts == 0 ? underlying.errorMessage : "Global input may have partially dispatched; observe before adjudicating a new action. Never retry this mutation." }
    package var details: [String: String] {
        ["strategy": posts == 0 ? "rejected" : "exclusive_global_hid", "global_hid_posts": String(posts),
         "cleanup_posts": String(cleanupPosts), "cause": underlying.errorCode]
    }
}

public final class CGEventInputSynthesisEngine: InputSynthesisEngine, @unchecked Sendable {
    public let exclusiveAuthority: ExclusiveInputAuthority
    private let lock = NSRecursiveLock()
    private let poster: any GlobalEventPosting
    private let trusted: @Sendable () -> Bool
    private var held: [String: CGEvent] = [:]
    public convenience init() {
        self.init(authority: ExclusiveInputAuthority(), poster: SystemGlobalEventPoster(), trusted: { AXIsProcessTrusted() })
    }
    package init(authority: ExclusiveInputAuthority, poster: any GlobalEventPosting, trusted: @escaping @Sendable () -> Bool) {
        exclusiveAuthority = authority; self.poster = poster; self.trusted = trusted
    }
    public var isMutationEnabled: Bool { trusted() }

    package static func durationMilliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1_000_000_000_000_000
    }
    package static func utf16Chunks(for text: String, maxCodeUnits: Int = 20) -> [[UniChar]] {
        precondition(maxCodeUnits >= 2)
        let units = Array(text.utf16)
        var chunks: [[UniChar]] = [], offset = 0
        while offset < units.count {
            var end = min(offset + maxCodeUnits, units.count)
            if end < units.count && (0xD800...0xDBFF).contains(units[end - 1]) && (0xDC00...0xDFFF).contains(units[end]) { end -= 1 }
            chunks.append(Array(units[offset..<end])); offset = end
        }
        return chunks
    }
    private struct Step {
        let event: CGEvent
        let point: CGPoint?
        let keyboard: Bool
        let hold: String?
        let release: CGEvent?
        let clear: String?
        init(_ event: CGEvent, point: CGPoint? = nil, keyboard: Bool = false,
             hold: String? = nil, release: CGEvent? = nil, clear: String? = nil) {
            self.event = event; self.point = point; self.keyboard = keyboard
            self.hold = hold; self.release = release; self.clear = clear
        }
    }
    private func event(_ value: CGEvent?) throws -> CGEvent {
        guard let value else { throw ComputerUseError.inputGuardUnavailable }; return value
    }
    private func point(_ x: Int, _ y: Int, _ display: DisplayInfo) throws -> CGPoint {
        let p = try CoordinateMapper.gridToLogicalPoint(gridX: x, gridY: y, display: display)
        return CGPoint(x: p.x, y: p.y)
    }
    private func mouse(_ type: CGEventType, _ point: CGPoint, _ button: CGMouseButton = .left) throws -> CGEvent {
        try event(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button))
    }
    private func key(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags = []) throws -> CGEvent {
        let e = try event(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)); e.flags = flags; return e
    }
    @discardableResult private func cleanup() -> Int {
        var count = 0
        for (_, up) in held.sorted(by: { $0.key < $1.key }) {
            // Release only our actually posted downs. Never replay a down or move
            // the cursor back after takeover. Releases are the sole gate exception.
            if up.type == .leftMouseUp || up.type == .rightMouseUp || up.type == .otherMouseUp {
                if let current = CGEvent(source: nil)?.location { up.location = current }
            }
            poster.post(up); count += 1
        }
        held.removeAll(); return count
    }
    public func releaseHeldInputs() { lock.lock(); defer { lock.unlock() }; cleanup() }

    private func dispatch(action: String, captureID: String, currentCaptureID: String,
                          permit: ExclusiveInputPermit?, plan: () throws -> [Step]) throws -> ActionResultDTO {
        lock.lock(); defer { lock.unlock() }
        let start = ContinuousClock().now
        var posts = 0
        do {
            try exclusiveAuthority.claim(permit, action: action, captureID: captureID)
            guard isMutationEnabled else { throw ComputerUseError.mutationDisabled }
            guard !captureID.isEmpty, captureID == currentCaptureID else {
                throw ComputerUseError.staleCapture(current: currentCaptureID, received: captureID)
            }
            let steps = try plan() // allocate every event/release before the first post
            guard let permit, !steps.isEmpty else { throw ComputerUseError.inputGuardUnavailable }
            // Preflight the entire path (including drag endpoint) before mutation.
            for step in steps { try exclusiveAuthority.validatePost(permit, point: step.point, keyboard: step.keyboard) }
            for step in steps {
                try exclusiveAuthority.validatePost(permit, point: step.point, keyboard: step.keyboard)
                poster.post(step.event); posts += 1
                if let hold = step.hold, let up = step.release { held[hold] = up }
                if let clear = step.clear { held.removeValue(forKey: clear) }
            }
            return ActionResultDTO(actionId: "act-\(UUID().uuidString.lowercased())", status: "dispatched",
                captureId: captureID, durationMs: Self.durationMilliseconds(ContinuousClock().now - start), globalHIDPosts: posts)
        } catch {
            let releases = cleanup()
            let cause = (error as? ComputerUseError) ?? .inputGuardUnavailable
            throw GlobalInputFailure(underlying: cause, posts: posts + releases, cleanupPosts: releases)
        }
    }
    public func performClick(gridX: Int, gridY: Int, button: MouseButton, clickCount: Int,
        captureId: String, currentCaptureId: String, display: DisplayInfo, permit: ExclusiveInputPermit? = nil) throws -> ActionResultDTO {
        try dispatch(action: "click", captureID: captureId, currentCaptureID: currentCaptureId, permit: permit) {
            guard (1...3).contains(clickCount) else { throw ComputerUseError.ipcError(reason: "Invalid click count") }
            let p = try point(gridX, gridY, display)
            let b: CGMouseButton = button == .left ? .left : button == .right ? .right : .center
            let down: CGEventType = button == .left ? .leftMouseDown : button == .right ? .rightMouseDown : .otherMouseDown
            let up: CGEventType = button == .left ? .leftMouseUp : button == .right ? .rightMouseUp : .otherMouseUp
            var result = [Step(try mouse(.mouseMoved, p), point: p)]
            for count in 1...clickCount {
                let d = try mouse(down, p, b), u = try mouse(up, p, b)
                d.setIntegerValueField(.mouseEventClickState, value: Int64(count)); u.setIntegerValueField(.mouseEventClickState, value: Int64(count))
                result += [Step(d, point: p, hold: "mouse", release: u), Step(u, point: p, clear: "mouse")]
            }
            return result
        }
    }
    public func performMove(gridX: Int, gridY: Int, captureId: String, currentCaptureId: String,
        display: DisplayInfo, permit: ExclusiveInputPermit? = nil) throws -> ActionResultDTO {
        try dispatch(action: "move", captureID: captureId, currentCaptureID: currentCaptureId, permit: permit) {
            let p = try point(gridX, gridY, display); return [Step(try mouse(.mouseMoved, p), point: p)]
        }
    }
    public func performDrag(startX: Int, startY: Int, endX: Int, endY: Int, button: MouseButton = .left,
        captureId: String, currentCaptureId: String, display: DisplayInfo, permit: ExclusiveInputPermit? = nil) throws -> ActionResultDTO {
        try dispatch(action: "drag", captureID: captureId, currentCaptureID: currentCaptureId, permit: permit) {
            guard button == .left else { throw ComputerUseError.ipcError(reason: "Only left drag is supported") }
            let a = try point(startX, startY, display), b = try point(endX, endY, display)
            let up = try mouse(.leftMouseUp, b)
            var result = [Step(try mouse(.mouseMoved, a), point: a),
                          Step(try mouse(.leftMouseDown, a), point: a, hold: "mouse", release: up)]
            for i in 1...5 {
                let t = Double(i) / 5, p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                result.append(Step(try mouse(.leftMouseDragged, p), point: p))
            }
            result.append(Step(up, point: b, clear: "mouse")); return result
        }
    }
    public func performScroll(gridX: Int, gridY: Int, deltaX: Int, deltaY: Int, captureId: String,
        currentCaptureId: String, display: DisplayInfo, permit: ExclusiveInputPermit? = nil) throws -> ActionResultDTO {
        try dispatch(action: "scroll", captureID: captureId, currentCaptureID: currentCaptureId, permit: permit) {
            guard (-1000...1000).contains(deltaX), (-1000...1000).contains(deltaY), deltaX != 0 || deltaY != 0 else {
                throw ComputerUseError.ipcError(reason: "Scroll deltas must be bounded and nonzero")
            }
            let p = try point(gridX, gridY, display)
            let wheel = try event(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: Int32(-deltaY), wheel2: Int32(-deltaX), wheel3: 0))
            wheel.location = p // allocation precedes the anchor move; bind the event explicitly
            return [Step(try mouse(.mouseMoved, p), point: p), Step(wheel, point: p)]
        }
    }
    public func performType(text: String, pressEnter: Bool, captureId: String, currentCaptureId: String,
        permit: ExclusiveInputPermit? = nil) throws -> ActionResultDTO {
        try dispatch(action: "type", captureID: captureId, currentCaptureID: currentCaptureId, permit: permit) {
            guard !text.isEmpty, text.count <= 1000 else { throw ComputerUseError.ipcError(reason: "Text must contain 1...1000 characters") }
            var result: [Step] = []
            for chunk in Self.utf16Chunks(for: text) {
                let d = try key(0, true), u = try key(0, false)
                d.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                u.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                result += [Step(d, keyboard: true, hold: "key", release: u), Step(u, keyboard: true, clear: "key")]
            }
            if pressEnter {
                let d = try key(0x24, true), u = try key(0x24, false)
                result += [Step(d, keyboard: true, hold: "key", release: u), Step(u, keyboard: true, clear: "key")]
            }
            return result
        }
    }
    public func performShortcut(keys: [String], captureId: String, currentCaptureId: String,
        permit: ExclusiveInputPermit? = nil) throws -> ActionResultDTO {
        try dispatch(action: "shortcut", captureID: captureId, currentCaptureID: currentCaptureId, permit: permit) {
            guard !keys.isEmpty, keys.count <= 5 else { throw ComputerUseError.ipcError(reason: "Shortcut requires 1...5 keys") }
            let modifiers: [String: (CGKeyCode, CGEventFlags)] = ["cmd": (0x37, .maskCommand), "command": (0x37, .maskCommand),
                "shift": (0x38, .maskShift), "alt": (0x3A, .maskAlternate), "option": (0x3A, .maskAlternate),
                "ctrl": (0x3B, .maskControl), "control": (0x3B, .maskControl)]
            let bases: [String: CGKeyCode] = ["tab": 0x30, "enter": 0x24, "return": 0x24, "escape": 0x35, "esc": 0x35,
                "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E, "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79]
            var mods: [(CGKeyCode, CGEventFlags)] = [], base: [CGKeyCode] = []
            for raw in keys {
                let k = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if let m = modifiers[k] { if !mods.contains(where: { $0.0 == m.0 }) { mods.append(m) } }
                else if let b = bases[k] { base.append(b) }
                else { throw ComputerUseError.ipcError(reason: "Unsupported shortcut key") }
            }
            guard base.count == 1 else { throw ComputerUseError.ipcError(reason: "Shortcut requires exactly one navigation key") }
            var flags: CGEventFlags = [], result: [Step] = []
            for (code, flag) in mods {
                flags.insert(flag)
                result.append(Step(try key(code, true, flags), keyboard: true, hold: "mod-\(code)", release: try key(code, false)))
            }
            let u = try key(base[0], false, flags)
            result += [Step(try key(base[0], true, flags), keyboard: true, hold: "key", release: u), Step(u, keyboard: true, clear: "key")]
            for (code, flag) in mods.reversed() {
                flags.remove(flag); result.append(Step(try key(code, false, flags), keyboard: true, clear: "mod-\(code)"))
            }
            return result
        }
    }
}
