import Foundation

public enum MouseButton: String, Codable, Sendable {
    case left
    case right
    case middle
}

public struct ActionResultDTO: Codable, Equatable, Sendable {
    public let actionId: String
    public let status: String // "dispatched" or "indeterminate"
    public let captureId: String
    public let durationMs: Double

    public init(actionId: String, status: String, captureId: String, durationMs: Double) {
        self.actionId = actionId
        self.status = status
        self.captureId = captureId
        self.durationMs = durationMs
    }
}

public protocol InputSynthesisEngine: Sendable {
    var isMutationEnabled: Bool { get }

    func performClick(gridX: Int, gridY: Int, button: MouseButton, clickCount: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO
    func performMove(gridX: Int, gridY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO
    func performDrag(startX: Int, startY: Int, endX: Int, endY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO
    func performType(text: String, pressEnter: Bool, captureId: String, currentCaptureId: String) throws -> ActionResultDTO
    func performShortcut(keys: [String], captureId: String, currentCaptureId: String) throws -> ActionResultDTO
    func performScroll(gridX: Int, gridY: Int, deltaX: Int, deltaY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO
    func releaseHeldInputs()
}

public struct DisabledInputInjector: InputSynthesisEngine {
    public init() {}

    public var isMutationEnabled: Bool { false }

    public func performClick(gridX: Int, gridY: Int, button: MouseButton, clickCount: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        throw ComputerUseError.mutationDisabled
    }

    public func performMove(gridX: Int, gridY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        throw ComputerUseError.mutationDisabled
    }

    public func performDrag(startX: Int, startY: Int, endX: Int, endY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        throw ComputerUseError.mutationDisabled
    }

    public func performType(text: String, pressEnter: Bool, captureId: String, currentCaptureId: String) throws -> ActionResultDTO {
        throw ComputerUseError.mutationDisabled
    }

    public func performShortcut(keys: [String], captureId: String, currentCaptureId: String) throws -> ActionResultDTO {
        throw ComputerUseError.mutationDisabled
    }

    public func performScroll(gridX: Int, gridY: Int, deltaX: Int, deltaY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        throw ComputerUseError.mutationDisabled
    }

    public func releaseHeldInputs() {}
}

public final class FakeInputInjector: InputSynthesisEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _actionHistory: [String] = []
    private var _isInputHeld: Bool = false

    public init() {}

    public var isMutationEnabled: Bool { true }

    public var actionHistory: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _actionHistory
    }

    public var isInputHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isInputHeld
    }

    private func validatePrecondition(captureId: String, currentCaptureId: String) throws {
        guard captureId == currentCaptureId else {
            throw ComputerUseError.staleCapture(current: currentCaptureId, received: captureId)
        }
    }

    public func performClick(gridX: Int, gridY: Int, button: MouseButton, clickCount: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        try validatePrecondition(captureId: captureId, currentCaptureId: currentCaptureId)
        let point = try CoordinateMapper.gridToLogicalPoint(gridX: gridX, gridY: gridY, display: display)

        lock.lock()
        _isInputHeld = true
        let count = _actionHistory.count
        _actionHistory.append("click(\(point.x), \(point.y), \(button.rawValue), count: \(clickCount))")
        _isInputHeld = false
        lock.unlock()

        let actId = "act-click-\(count + 1)"
        return ActionResultDTO(actionId: actId, status: "dispatched", captureId: captureId, durationMs: 12.5)
    }

    public func performMove(gridX: Int, gridY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        try validatePrecondition(captureId: captureId, currentCaptureId: currentCaptureId)
        let point = try CoordinateMapper.gridToLogicalPoint(gridX: gridX, gridY: gridY, display: display)

        lock.lock()
        let count = _actionHistory.count
        _actionHistory.append("move(\(point.x), \(point.y))")
        lock.unlock()

        let actId = "act-move-\(count + 1)"
        return ActionResultDTO(actionId: actId, status: "dispatched", captureId: captureId, durationMs: 8.0)
    }

    public func performDrag(startX: Int, startY: Int, endX: Int, endY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        try validatePrecondition(captureId: captureId, currentCaptureId: currentCaptureId)
        let startPoint = try CoordinateMapper.gridToLogicalPoint(gridX: startX, gridY: startY, display: display)
        let endPoint = try CoordinateMapper.gridToLogicalPoint(gridX: endX, gridY: endY, display: display)

        lock.lock()
        _isInputHeld = true
        let count = _actionHistory.count
        _actionHistory.append("drag((\(startPoint.x), \(startPoint.y)) -> (\(endPoint.x), \(endPoint.y)))")
        _isInputHeld = false
        lock.unlock()

        let actId = "act-drag-\(count + 1)"
        return ActionResultDTO(actionId: actId, status: "dispatched", captureId: captureId, durationMs: 45.0)
    }

    public func performType(text: String, pressEnter: Bool, captureId: String, currentCaptureId: String) throws -> ActionResultDTO {
        try validatePrecondition(captureId: captureId, currentCaptureId: currentCaptureId)

        lock.lock()
        let count = _actionHistory.count
        let enterSuffix = pressEnter ? "+return" : ""
        _actionHistory.append("type([REDACTED_TEXT]\(enterSuffix))")
        lock.unlock()

        let actId = "act-type-\(count + 1)"
        return ActionResultDTO(actionId: actId, status: "dispatched", captureId: captureId, durationMs: Double(text.count * 10))
    }

    public func performShortcut(keys: [String], captureId: String, currentCaptureId: String) throws -> ActionResultDTO {
        try validatePrecondition(captureId: captureId, currentCaptureId: currentCaptureId)

        lock.lock()
        _isInputHeld = true
        let count = _actionHistory.count
        _actionHistory.append("shortcut(\(keys.joined(separator: "+")))")
        _isInputHeld = false
        lock.unlock()

        let actId = "act-shortcut-\(count + 1)"
        return ActionResultDTO(actionId: actId, status: "dispatched", captureId: captureId, durationMs: 15.0)
    }

    public func performScroll(gridX: Int, gridY: Int, deltaX: Int, deltaY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        try validatePrecondition(captureId: captureId, currentCaptureId: currentCaptureId)
        let point = try CoordinateMapper.gridToLogicalPoint(gridX: gridX, gridY: gridY, display: display)

        lock.lock()
        let count = _actionHistory.count
        _actionHistory.append("scroll(\(point.x), \(point.y), dx: \(deltaX), dy: \(deltaY))")
        lock.unlock()

        let actId = "act-scroll-\(count + 1)"
        return ActionResultDTO(actionId: actId, status: "dispatched", captureId: captureId, durationMs: 10.0)
    }

    public func releaseHeldInputs() {
        lock.lock()
        _isInputHeld = false
        lock.unlock()
    }
}
