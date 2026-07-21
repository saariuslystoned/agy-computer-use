import Foundation

public enum MouseButton: String, Codable {
    case left
    case right
    case middle
}

public struct ActionResultDTO: Codable, Equatable {
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

public protocol InputSynthesisEngine {
    func performClick(gridX: Int, gridY: Int, button: MouseButton, clickCount: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO
    func performMove(gridX: Int, gridY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO
    func performDrag(startX: Int, startY: Int, endX: Int, endY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO
    func performType(text: String, pressEnter: Bool, captureId: String, currentCaptureId: String) throws -> ActionResultDTO
    func performShortcut(keys: [String], captureId: String, currentCaptureId: String) throws -> ActionResultDTO
    func performScroll(gridX: Int, gridY: Int, deltaX: Int, deltaY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO
    func releaseHeldInputs()
}

public class FakeInputInjector: InputSynthesisEngine {
    public private(set) var actionHistory: [String] = []
    public private(set) var isInputHeld: Bool = false

    public init() {}

    private func validatePrecondition(captureId: String, currentCaptureId: String) throws {
        guard captureId == currentCaptureId else {
            throw ComputerUseError.staleCapture(current: currentCaptureId, received: captureId)
        }
    }

    public func performClick(gridX: Int, gridY: Int, button: MouseButton, clickCount: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        try validatePrecondition(captureId: captureId, currentCaptureId: currentCaptureId)
        let point = try CoordinateMapper.gridToLogicalPoint(gridX: gridX, gridY: gridY, display: display)

        isInputHeld = true
        defer { releaseHeldInputs() }

        let actId = "act-click-\(actionHistory.count + 1)"
        actionHistory.append("click(\(point.x), \(point.y), \(button.rawValue), count: \(clickCount))")

        return ActionResultDTO(actionId: actId, status: "dispatched", captureId: captureId, durationMs: 12.5)
    }

    public func performMove(gridX: Int, gridY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        try validatePrecondition(captureId: captureId, currentCaptureId: currentCaptureId)
        let point = try CoordinateMapper.gridToLogicalPoint(gridX: gridX, gridY: gridY, display: display)

        let actId = "act-move-\(actionHistory.count + 1)"
        actionHistory.append("move(\(point.x), \(point.y))")

        return ActionResultDTO(actionId: actId, status: "dispatched", captureId: captureId, durationMs: 8.0)
    }

    public func performDrag(startX: Int, startY: Int, endX: Int, endY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        try validatePrecondition(captureId: captureId, currentCaptureId: currentCaptureId)
        let startPoint = try CoordinateMapper.gridToLogicalPoint(gridX: startX, gridY: startY, display: display)
        let endPoint = try CoordinateMapper.gridToLogicalPoint(gridX: endX, gridY: endY, display: display)

        isInputHeld = true
        defer { releaseHeldInputs() }

        let actId = "act-drag-\(actionHistory.count + 1)"
        actionHistory.append("drag((\(startPoint.x), \(startPoint.y)) -> (\(endPoint.x), \(endPoint.y)))")

        return ActionResultDTO(actionId: actId, status: "dispatched", captureId: captureId, durationMs: 45.0)
    }

    public func performType(text: String, pressEnter: Bool, captureId: String, currentCaptureId: String) throws -> ActionResultDTO {
        try validatePrecondition(captureId: captureId, currentCaptureId: currentCaptureId)

        let actId = "act-type-\(actionHistory.count + 1)"
        let enterSuffix = pressEnter ? "+return" : ""
        actionHistory.append("type([REDACTED_TEXT]\(enterSuffix))")

        return ActionResultDTO(actionId: actId, status: "dispatched", captureId: captureId, durationMs: Double(text.count * 10))
    }

    public func performShortcut(keys: [String], captureId: String, currentCaptureId: String) throws -> ActionResultDTO {
        try validatePrecondition(captureId: captureId, currentCaptureId: currentCaptureId)

        isInputHeld = true
        defer { releaseHeldInputs() }

        let actId = "act-shortcut-\(actionHistory.count + 1)"
        actionHistory.append("shortcut(\(keys.joined(separator: "+")))")

        return ActionResultDTO(actionId: actId, status: "dispatched", captureId: captureId, durationMs: 15.0)
    }

    public func performScroll(gridX: Int, gridY: Int, deltaX: Int, deltaY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        try validatePrecondition(captureId: captureId, currentCaptureId: currentCaptureId)
        let point = try CoordinateMapper.gridToLogicalPoint(gridX: gridX, gridY: gridY, display: display)

        let actId = "act-scroll-\(actionHistory.count + 1)"
        actionHistory.append("scroll(\(point.x), \(point.y), dx: \(deltaX), dy: \(deltaY))")

        return ActionResultDTO(actionId: actId, status: "dispatched", captureId: captureId, durationMs: 10.0)
    }

    public func releaseHeldInputs() {
        isInputHeld = false
    }
}
