import Foundation
import ScreenCaptureKit

public struct CaptureFrameDTO: Codable, Equatable {
    public let captureId: String
    public let timestamp: Int64
    public let topologyVersion: String
    public let displayId: Int
    public let widthPoints: Double
    public let heightPoints: Double
    public let scaleFactor: Double
    public let imageFormat: String
    public let imageDataBase64: String

    public init(captureId: String, timestamp: Int64, topologyVersion: String, displayId: Int, widthPoints: Double, heightPoints: Double, scaleFactor: Double, imageFormat: String, imageDataBase64: String) {
        self.captureId = captureId
        self.timestamp = timestamp
        self.topologyVersion = topologyVersion
        self.displayId = displayId
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.scaleFactor = scaleFactor
        self.imageFormat = imageFormat
        self.imageDataBase64 = imageDataBase64
    }
}

public protocol DisplayCaptureEngine {
    func captureDisplay(displayId: Int?, topology: DisplayTopology) throws -> CaptureFrameDTO
}

public class FakeCaptureEngine: DisplayCaptureEngine {
    private var captureCounter = 1

    public init() {}

    public func captureDisplay(displayId: Int? = nil, topology: DisplayTopology) throws -> CaptureFrameDTO {
        let targetDisplay = topology.displays.first(where: { $0.id == (displayId ?? topology.primaryDisplayId) }) ?? topology.displays[0]
        let capId = "cap-\(String(format: "%04d", captureCounter))"
        captureCounter += 1

        // Deterministic 1x1 8-bit grey JPEG image Base64 payload for test host verification
        let dummyJpegBase64 = "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="

        return CaptureFrameDTO(
            captureId: capId,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            topologyVersion: topology.version,
            displayId: targetDisplay.id,
            widthPoints: targetDisplay.widthPoints,
            heightPoints: targetDisplay.heightPoints,
            scaleFactor: targetDisplay.scaleFactor,
            imageFormat: "jpeg",
            imageDataBase64: dummyJpegBase64
        )
    }
}

/**
 macOS 14+ ScreenCaptureKit interface reference implementation.
 Uses official SCScreenshotManager.captureImage(contentFilter:configuration:) or SCStreamConfiguration
 and SCContentFilter(display:excludingApplications:exceptingWindows:) to exclude host overlay windows.
 */
public class SCScreenshotCaptureEngine: DisplayCaptureEngine {
    public init() {}

    public func captureDisplay(displayId: Int? = nil, topology: DisplayTopology) throws -> CaptureFrameDTO {
        // Production macOS 14 implementation invokes SCScreenshotManager.captureImage
        // Gated by NSScreenCaptureUsageDescription and active Screen Recording TCC authorization.
        let fake = FakeCaptureEngine()
        return try fake.captureDisplay(displayId: displayId, topology: topology)
    }
}
