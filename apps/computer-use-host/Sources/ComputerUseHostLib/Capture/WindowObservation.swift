import Foundation

public struct WindowCaptureRequest: Sendable {
    public let windowID: UInt32
    public let pid: Int32
    public let bounds: AXRect
    public let display: DisplayInfo
    public let topologyVersion: String
    public init(windowID: UInt32, pid: Int32, bounds: AXRect, display: DisplayInfo, topologyVersion: String) {
        self.windowID = windowID; self.pid = pid; self.bounds = bounds
        self.display = display; self.topologyVersion = topologyVersion
    }
}
public protocol WindowCaptureEngine: Sendable {
    func captureWindow(_ request: WindowCaptureRequest) async throws -> CaptureFrameDTO
}

// Uses the existing physical-capacity and deadline authority; a window frame is
// never promoted to the global-HID display-capture lease.
package struct WindowCaptureAdapter: DisplayCaptureEngine {
    let engine: any WindowCaptureEngine
    let request: WindowCaptureRequest
    package func captureDisplay(displayId: Int?, topology: DisplayTopology) async throws -> CaptureFrameDTO {
        try await engine.captureWindow(request)
    }
}

public struct WindowObservationDTO: Codable, Sendable {
    public let window: AXWindowDescriptor
    public let state: AXTreeResultDTO
    public let image: CaptureFrameDTO
    public let timing: WindowObservationTiming
    public let consistency: String
    public let imageRedaction: String
    public let axRedaction: String
    public let screenPointsPerPixelX: Double
    public let screenPointsPerPixelY: Double
    public let displayNormalizedScaleX: Double
    public let displayNormalizedScaleY: Double
    public let displayNormalizedOffsetX: Double
    public let displayNormalizedOffsetY: Double
    enum CodingKeys: String, CodingKey {
        case window, state, image, timing, consistency
        case imageRedaction = "image_redaction", axRedaction = "ax_redaction"
        case screenPointsPerPixelX = "screen_points_per_pixel_x", screenPointsPerPixelY = "screen_points_per_pixel_y"
        case displayNormalizedScaleX = "display_normalized_scale_x", displayNormalizedScaleY = "display_normalized_scale_y"
        case displayNormalizedOffsetX = "display_normalized_offset_x", displayNormalizedOffsetY = "display_normalized_offset_y"
    }
}
public struct WindowObservationTiming: Codable, Sendable {
    public let axBeforeMs: Int
    public let imageStartedMs: Int
    public let imageCompletedMs: Int
    public let axAfterMs: Int
    public let atomic: Bool
    enum CodingKeys: String, CodingKey {
        case axBeforeMs = "ax_before_ms", imageStartedMs = "image_started_ms"
        case imageCompletedMs = "image_completed_ms", axAfterMs = "ax_after_ms", atomic
    }
}

public protocol AXWindowInspectionEngine: AXScopedInspectionEngine {
    func discoverTargets(appID: String?, sessionID: String, topology: DisplayTopology) throws -> AXTargetDiscovery
    func inspectWindow(appID: String, windowRef: String?, sessionID: String,
        maxDepth: Int, topology: DisplayTopology) throws -> (AXWindowDescriptor, AXTreeResultDTO, WindowCaptureRequest)
    func finishWindowObservation(windowRef: String, sessionID: String, before: AXTreeResultDTO,
        bounds: AXRect, maxDepth: Int, topology: DisplayTopology) throws -> AXTreeResultDTO
    func invalidateWindowObservation(windowRef: String, sessionID: String)
}
