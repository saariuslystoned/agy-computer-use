import Foundation
import CoreGraphics
import ApplicationServices

public final class CGEventInputSynthesisEngine: InputSynthesisEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var heldModifiers: Set<CGKeyCode> = []
    private var heldMouseButton: MouseButton? = nil

    public init() {}

    public var isMutationEnabled: Bool {
        return AXIsProcessTrusted()
    }

    public func releaseHeldInputs() {
        lock.lock()
        let currentButton = heldMouseButton
        let currentModifiers = heldModifiers
        heldMouseButton = nil
        heldModifiers.removeAll()
        lock.unlock()

        if let btn = currentButton {
            let eventType: CGEventType
            switch btn {
            case .left: eventType = .leftMouseUp
            case .right: eventType = .rightMouseUp
            case .middle: eventType = .otherMouseUp
            }
            if let event = CGEvent(source: nil) {
                let location = event.location
                let upEvent = CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: location, mouseButton: btnToCGButton(btn))
                upEvent?.post(tap: .cghidEventTap)
            }
        }

        for keyCode in currentModifiers {
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    private func btnToCGButton(_ btn: MouseButton) -> CGMouseButton {
        switch btn {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    public func performClick(gridX: Int, gridY: Int, button: MouseButton, clickCount: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        defer { releaseHeldInputs() }

        guard isMutationEnabled else {
            throw ComputerUseError.mutationDisabled
        }

        guard captureId == currentCaptureId && !captureId.isEmpty else {
            throw ComputerUseError.staleCapture(current: currentCaptureId, received: captureId)
        }

        let logicalPoint = try CoordinateMapper.gridToLogicalPoint(gridX: gridX, gridY: gridY, display: display)
        let cgPoint = CGPoint(x: logicalPoint.x, y: logicalPoint.y)

        let startClock = ContinuousClock().now

        let downType: CGEventType
        let upType: CGEventType
        let cgButton = btnToCGButton(button)

        switch button {
        case .left:
            downType = .leftMouseDown
            upType = .leftMouseUp
        case .right:
            downType = .rightMouseDown
            upType = .rightMouseUp
        case .middle:
            downType = .otherMouseDown
            upType = .otherMouseUp
        }

        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cgPoint, mouseButton: cgButton) {
            moveEvent.post(tap: .cghidEventTap)
        }

        let actualClickCount = max(1, min(3, clickCount))
        for i in 1...actualClickCount {
            lock.lock()
            heldMouseButton = button
            lock.unlock()

            guard let downEvent = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: cgPoint, mouseButton: cgButton) else {
                throw ComputerUseError.ipcError(reason: "Failed to create mouse down CGEvent")
            }
            downEvent.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            downEvent.post(tap: .cghidEventTap)

            guard let upEvent = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: cgPoint, mouseButton: cgButton) else {
                throw ComputerUseError.ipcError(reason: "Failed to create mouse up CGEvent")
            }
            upEvent.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            upEvent.post(tap: .cghidEventTap)

            lock.lock()
            heldMouseButton = nil
            lock.unlock()
        }

        let elapsed = ContinuousClock().now - startClock
        let (sec, attosec) = elapsed.components
        let durationMs = Double(sec) * 1000.0 + Double(attosec) / 1_000_000.0

        return ActionResultDTO(
            actionId: "act-\(UUID().uuidString.lowercased())",
            status: "dispatched",
            captureId: captureId,
            durationMs: durationMs
        )
    }

    public func performType(text: String, pressEnter: Bool, captureId: String, currentCaptureId: String) throws -> ActionResultDTO {
        defer { releaseHeldInputs() }

        guard isMutationEnabled else {
            throw ComputerUseError.mutationDisabled
        }

        guard captureId == currentCaptureId && !captureId.isEmpty else {
            throw ComputerUseError.staleCapture(current: currentCaptureId, received: captureId)
        }

        guard !text.isEmpty && text.count <= 1000 else {
            throw ComputerUseError.ipcError(reason: "Text payload must be between 1 and 1000 characters")
        }

        let startClock = ContinuousClock().now

        let utf16Array = Array(text.utf16)
        let chunkSize = 20
        var offset = 0
        while offset < utf16Array.count {
            let count = min(chunkSize, utf16Array.count - offset)
            let chunk = Array(utf16Array[offset..<(offset + count)])
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
                throw ComputerUseError.ipcError(reason: "Failed to create unicode CGEvent")
            }
            event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            event.post(tap: .cghidEventTap)
            offset += count
        }

        if pressEnter {
            let returnKeyCode: CGKeyCode = 0x24
            if let enterDown = CGEvent(keyboardEventSource: nil, virtualKey: returnKeyCode, keyDown: true) {
                enterDown.post(tap: .cghidEventTap)
            }
            if let enterUp = CGEvent(keyboardEventSource: nil, virtualKey: returnKeyCode, keyDown: false) {
                enterUp.post(tap: .cghidEventTap)
            }
        }

        let elapsed = ContinuousClock().now - startClock
        let (sec, attosec) = elapsed.components
        let durationMs = Double(sec) * 1000.0 + Double(attosec) / 1_000_000.0

        return ActionResultDTO(
            actionId: "act-\(UUID().uuidString.lowercased())",
            status: "dispatched",
            captureId: captureId,
            durationMs: durationMs
        )
    }

    public func performShortcut(keys: [String], captureId: String, currentCaptureId: String) throws -> ActionResultDTO {
        defer { releaseHeldInputs() }

        guard isMutationEnabled else {
            throw ComputerUseError.mutationDisabled
        }

        guard captureId == currentCaptureId && !captureId.isEmpty else {
            throw ComputerUseError.staleCapture(current: currentCaptureId, received: captureId)
        }

        guard !keys.isEmpty && keys.count <= 5 else {
            throw ComputerUseError.ipcError(reason: "Shortcut keys array must contain between 1 and 5 keys")
        }

        let startClock = ContinuousClock().now

        var modKeyCodes: [CGKeyCode] = []
        var baseKeyCode: CGKeyCode? = nil

        for keyStr in keys {
            let k = keyStr.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            switch k {
            case "cmd", "command":
                modKeyCodes.append(0x37)
            case "shift":
                modKeyCodes.append(0x38)
            case "alt", "option":
                modKeyCodes.append(0x3A)
            case "ctrl", "control":
                modKeyCodes.append(0x3B)
            case "tab":
                baseKeyCode = 0x30
            case "enter", "return":
                baseKeyCode = 0x24
            case "escape", "esc":
                baseKeyCode = 0x35
            case "left":
                baseKeyCode = 0x7B
            case "right":
                baseKeyCode = 0x7C
            case "down":
                baseKeyCode = 0x7D
            case "up":
                baseKeyCode = 0x7E
            case "home":
                baseKeyCode = 0x73
            case "end":
                baseKeyCode = 0x77
            case "pageup":
                baseKeyCode = 0x74
            case "pagedown":
                baseKeyCode = 0x79
            default:
                throw ComputerUseError.ipcError(reason: "Unsupported shortcut key '\(keyStr)'")
            }
        }

        for modCode in modKeyCodes {
            lock.lock()
            heldModifiers.insert(modCode)
            lock.unlock()
            if let modDown = CGEvent(keyboardEventSource: nil, virtualKey: modCode, keyDown: true) {
                modDown.post(tap: .cghidEventTap)
            }
        }

        if let bCode = baseKeyCode {
            if let baseDown = CGEvent(keyboardEventSource: nil, virtualKey: bCode, keyDown: true) {
                baseDown.post(tap: .cghidEventTap)
            }
            if let baseUp = CGEvent(keyboardEventSource: nil, virtualKey: bCode, keyDown: false) {
                baseUp.post(tap: .cghidEventTap)
            }
        }

        for modCode in modKeyCodes.reversed() {
            if let modUp = CGEvent(keyboardEventSource: nil, virtualKey: modCode, keyDown: false) {
                modUp.post(tap: .cghidEventTap)
            }
            lock.lock()
            heldModifiers.remove(modCode)
            lock.unlock()
        }

        let elapsed = ContinuousClock().now - startClock
        let (sec, attosec) = elapsed.components
        let durationMs = Double(sec) * 1000.0 + Double(attosec) / 1_000_000.0

        return ActionResultDTO(
            actionId: "act-\(UUID().uuidString.lowercased())",
            status: "dispatched",
            captureId: captureId,
            durationMs: durationMs
        )
    }

    public func performMove(gridX: Int, gridY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        throw ComputerUseError.mutationDisabled
    }

    public func performDrag(startX: Int, startY: Int, endX: Int, endY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        throw ComputerUseError.mutationDisabled
    }

    public func performScroll(gridX: Int, gridY: Int, deltaX: Int, deltaY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        throw ComputerUseError.mutationDisabled
    }
}
