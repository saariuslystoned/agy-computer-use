import Foundation
import CoreGraphics
import ApplicationServices

public final class CGEventInputSynthesisEngine: InputSynthesisEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var heldModifiers: Set<CGKeyCode> = []
    private var heldMouseButton: MouseButton? = nil
    private var heldBaseKey: CGKeyCode? = nil

    public init() {}

    public var isMutationEnabled: Bool {
        return AXIsProcessTrusted()
    }

    public func releaseHeldInputs() {
        lock.lock()
        let currentButton = heldMouseButton
        let currentModifiers = heldModifiers
        let currentBaseKey = heldBaseKey
        heldMouseButton = nil
        heldModifiers.removeAll()
        heldBaseKey = nil
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

        if let baseKey = currentBaseKey {
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: baseKey, keyDown: false)
            keyUp?.post(tap: .cghidEventTap)
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
            lock.lock()
            heldBaseKey = returnKeyCode
            lock.unlock()

            guard let enterDown = CGEvent(keyboardEventSource: nil, virtualKey: returnKeyCode, keyDown: true) else {
                throw ComputerUseError.ipcError(reason: "Failed to create enter down CGEvent")
            }
            enterDown.post(tap: .cghidEventTap)

            guard let enterUp = CGEvent(keyboardEventSource: nil, virtualKey: returnKeyCode, keyDown: false) else {
                throw ComputerUseError.ipcError(reason: "Failed to create enter up CGEvent")
            }
            enterUp.post(tap: .cghidEventTap)

            lock.lock()
            heldBaseKey = nil
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
        var baseKeyCodes: [CGKeyCode] = []

        for keyStr in keys {
            let k = keyStr.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            switch k {
            case "cmd", "command":
                if !modKeyCodes.contains(0x37) { modKeyCodes.append(0x37) }
            case "shift":
                if !modKeyCodes.contains(0x38) { modKeyCodes.append(0x38) }
            case "alt", "option":
                if !modKeyCodes.contains(0x3A) { modKeyCodes.append(0x3A) }
            case "ctrl", "control":
                if !modKeyCodes.contains(0x3B) { modKeyCodes.append(0x3B) }
            case "tab":
                baseKeyCodes.append(0x30)
            case "enter", "return":
                baseKeyCodes.append(0x24)
            case "escape", "esc":
                baseKeyCodes.append(0x35)
            case "left":
                baseKeyCodes.append(0x7B)
            case "right":
                baseKeyCodes.append(0x7C)
            case "down":
                baseKeyCodes.append(0x7D)
            case "up":
                baseKeyCodes.append(0x7E)
            case "home":
                baseKeyCodes.append(0x73)
            case "end":
                baseKeyCodes.append(0x77)
            case "pageup":
                baseKeyCodes.append(0x74)
            case "pagedown":
                baseKeyCodes.append(0x79)
            default:
                throw ComputerUseError.ipcError(reason: "Unsupported shortcut key '\(keyStr)'")
            }
        }

        guard baseKeyCodes.count == 1 else {
            throw ComputerUseError.ipcError(reason: "Shortcut must contain exactly one supported base navigation key, got \(baseKeyCodes.count)")
        }

        let baseKeyCode = baseKeyCodes[0]

        for modCode in modKeyCodes {
            lock.lock()
            heldModifiers.insert(modCode)
            lock.unlock()
            guard let modDown = CGEvent(keyboardEventSource: nil, virtualKey: modCode, keyDown: true) else {
                throw ComputerUseError.ipcError(reason: "Failed to create modifier down CGEvent")
            }
            modDown.post(tap: .cghidEventTap)
        }

        lock.lock()
        heldBaseKey = baseKeyCode
        lock.unlock()

        guard let baseDown = CGEvent(keyboardEventSource: nil, virtualKey: baseKeyCode, keyDown: true) else {
            throw ComputerUseError.ipcError(reason: "Failed to create base key down CGEvent")
        }
        baseDown.post(tap: .cghidEventTap)

        guard let baseUp = CGEvent(keyboardEventSource: nil, virtualKey: baseKeyCode, keyDown: false) else {
            throw ComputerUseError.ipcError(reason: "Failed to create base key up CGEvent")
        }
        baseUp.post(tap: .cghidEventTap)

        lock.lock()
        heldBaseKey = nil
        lock.unlock()

        for modCode in modKeyCodes.reversed() {
            guard let modUp = CGEvent(keyboardEventSource: nil, virtualKey: modCode, keyDown: false) else {
                throw ComputerUseError.ipcError(reason: "Failed to create modifier up CGEvent")
            }
            modUp.post(tap: .cghidEventTap)
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

        guard let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cgPoint, mouseButton: .left) else {
            throw ComputerUseError.ipcError(reason: "Failed to create mouse move CGEvent")
        }
        moveEvent.post(tap: .cghidEventTap)

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

    public func performDrag(startX: Int, startY: Int, endX: Int, endY: Int, button: MouseButton = .left, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        defer { releaseHeldInputs() }

        guard isMutationEnabled else {
            throw ComputerUseError.mutationDisabled
        }

        guard captureId == currentCaptureId && !captureId.isEmpty else {
            throw ComputerUseError.staleCapture(current: currentCaptureId, received: captureId)
        }

        let startPoint = try CoordinateMapper.gridToLogicalPoint(gridX: startX, gridY: startY, display: display)
        let endPoint = try CoordinateMapper.gridToLogicalPoint(gridX: endX, gridY: endY, display: display)

        let cgStart = CGPoint(x: startPoint.x, y: startPoint.y)
        let cgEnd = CGPoint(x: endPoint.x, y: endPoint.y)
        let cgButton = btnToCGButton(button)

        let downType: CGEventType
        let dragType: CGEventType
        let upType: CGEventType

        switch button {
        case .left:
            downType = .leftMouseDown
            dragType = .leftMouseDragged
            upType = .leftMouseUp
        case .right:
            downType = .rightMouseDown
            dragType = .rightMouseDragged
            upType = .rightMouseUp
        case .middle:
            downType = .otherMouseDown
            dragType = .otherMouseDragged
            upType = .otherMouseUp
        }

        let startClock = ContinuousClock().now

        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cgStart, mouseButton: cgButton) {
            moveEvent.post(tap: .cghidEventTap)
        }

        lock.lock()
        heldMouseButton = button
        lock.unlock()

        guard let downEvent = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: cgStart, mouseButton: cgButton) else {
            throw ComputerUseError.ipcError(reason: "Failed to create mouse down CGEvent for drag")
        }
        downEvent.post(tap: .cghidEventTap)

        let steps = 5
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let currentX = cgStart.x + (cgEnd.x - cgStart.x) * t
            let currentY = cgStart.y + (cgEnd.y - cgStart.y) * t
            let stepPoint = CGPoint(x: currentX, y: currentY)

            if let dragEvent = CGEvent(mouseEventSource: nil, mouseType: dragType, mouseCursorPosition: stepPoint, mouseButton: cgButton) {
                dragEvent.post(tap: .cghidEventTap)
            }
        }

        guard let upEvent = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: cgEnd, mouseButton: cgButton) else {
            throw ComputerUseError.ipcError(reason: "Failed to create mouse up CGEvent for drag")
        }
        upEvent.post(tap: .cghidEventTap)

        lock.lock()
        heldMouseButton = nil
        lock.unlock()

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

    public func performScroll(gridX: Int, gridY: Int, deltaX: Int, deltaY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        defer { releaseHeldInputs() }

        guard isMutationEnabled else {
            throw ComputerUseError.mutationDisabled
        }

        guard captureId == currentCaptureId && !captureId.isEmpty else {
            throw ComputerUseError.staleCapture(current: currentCaptureId, received: captureId)
        }

        guard deltaX != 0 || deltaY != 0 else {
            throw ComputerUseError.ipcError(reason: "At least one scroll delta (deltaX or deltaY) must be non-zero")
        }

        let logicalPoint = try CoordinateMapper.gridToLogicalPoint(gridX: gridX, gridY: gridY, display: display)
        let cgPoint = CGPoint(x: logicalPoint.x, y: logicalPoint.y)

        let startClock = ContinuousClock().now

        guard let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cgPoint, mouseButton: .left) else {
            throw ComputerUseError.ipcError(reason: "Failed to create mouse move CGEvent for scroll anchor")
        }
        moveEvent.post(tap: .cghidEventTap)

        guard let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(-deltaY), wheel2: Int32(-deltaX), wheel3: 0) else {
            throw ComputerUseError.ipcError(reason: "Failed to create scroll wheel CGEvent")
        }
        scrollEvent.post(tap: .cghidEventTap)

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
}
