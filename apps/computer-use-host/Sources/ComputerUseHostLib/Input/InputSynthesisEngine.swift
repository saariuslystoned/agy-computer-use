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
    public let strategy: String
    public let globalHIDPosts: Int

    enum CodingKeys: String, CodingKey {
        case actionId = "action_id"
        case status
        case captureId = "capture_id"
        case durationMs = "duration_ms"
        case strategy
        case globalHIDPosts = "global_hid_posts"
    }

    public init(actionId: String, status: String, captureId: String, durationMs: Double, strategy: String = "exclusive_global_hid", globalHIDPosts: Int = 1) {
        self.actionId = actionId
        self.status = status
        self.captureId = captureId
        self.durationMs = durationMs
        self.strategy = strategy
        self.globalHIDPosts = globalHIDPosts
    }
}

public protocol InputSynthesisEngine: Sendable {
    var isMutationEnabled: Bool { get }
    var exclusiveAuthority: ExclusiveInputAuthority { get }

    func performClick(gridX: Int, gridY: Int, button: MouseButton, clickCount: Int, captureId: String, currentCaptureId: String, display: DisplayInfo, permit: ExclusiveInputPermit?) throws -> ActionResultDTO
    func performMove(gridX: Int, gridY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo, permit: ExclusiveInputPermit?) throws -> ActionResultDTO
    func performDrag(startX: Int, startY: Int, endX: Int, endY: Int, button: MouseButton, captureId: String, currentCaptureId: String, display: DisplayInfo, permit: ExclusiveInputPermit?) throws -> ActionResultDTO
    func performType(text: String, pressEnter: Bool, captureId: String, currentCaptureId: String, permit: ExclusiveInputPermit?) throws -> ActionResultDTO
    func performShortcut(keys: [String], captureId: String, currentCaptureId: String, permit: ExclusiveInputPermit?) throws -> ActionResultDTO
    func performScroll(gridX: Int, gridY: Int, deltaX: Int, deltaY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo, permit: ExclusiveInputPermit?) throws -> ActionResultDTO
    func releaseHeldInputs()
}

public extension InputSynthesisEngine {
    func performDrag(startX: Int, startY: Int, endX: Int, endY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo, permit: ExclusiveInputPermit?) throws -> ActionResultDTO {
        try performDrag(startX: startX, startY: startY, endX: endX, endY: endY, button: .left, captureId: captureId, currentCaptureId: currentCaptureId, display: display, permit: permit)
    }
}

public struct DisabledInputInjector: InputSynthesisEngine {
    public let exclusiveAuthority = ExclusiveInputAuthority()
    public init() {}

    public var isMutationEnabled: Bool { false }

    public func performClick(gridX: Int, gridY: Int, button: MouseButton, clickCount: Int, captureId: String, currentCaptureId: String, display: DisplayInfo, permit: ExclusiveInputPermit?) throws -> ActionResultDTO {
        throw ComputerUseError.mutationDisabled
    }

    public func performMove(gridX: Int, gridY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo, permit: ExclusiveInputPermit?) throws -> ActionResultDTO {
        throw ComputerUseError.mutationDisabled
    }

    public func performDrag(startX: Int, startY: Int, endX: Int, endY: Int, button: MouseButton = .left, captureId: String, currentCaptureId: String, display: DisplayInfo, permit: ExclusiveInputPermit?) throws -> ActionResultDTO {
        throw ComputerUseError.mutationDisabled
    }

    public func performType(text: String, pressEnter: Bool, captureId: String, currentCaptureId: String, permit: ExclusiveInputPermit?) throws -> ActionResultDTO {
        throw ComputerUseError.mutationDisabled
    }

    public func performShortcut(keys: [String], captureId: String, currentCaptureId: String, permit: ExclusiveInputPermit?) throws -> ActionResultDTO {
        throw ComputerUseError.mutationDisabled
    }

    public func performScroll(gridX: Int, gridY: Int, deltaX: Int, deltaY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo, permit: ExclusiveInputPermit?) throws -> ActionResultDTO {
        throw ComputerUseError.mutationDisabled
    }

    public func releaseHeldInputs() {}
}
