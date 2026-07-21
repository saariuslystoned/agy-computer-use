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
