import Foundation
@preconcurrency import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import AppKit

public struct CaptureFrameDTO: Codable, Equatable, Sendable {
    public let captureId: String
    public let timestamp: Int64
    public let topologyVersion: String
    public let displayId: Int
    public let widthPoints: Double
    public let heightPoints: Double
    public let scaleFactor: Double
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let imageFormat: String
    public let imageDataBase64: String

    enum CodingKeys: String, CodingKey {
        case captureId = "capture_id"
        case timestamp
        case topologyVersion = "topology_version"
        case displayId = "display_id"
        case widthPoints = "width_points"
        case heightPoints = "height_points"
        case scaleFactor = "scale_factor"
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
        case imageFormat = "image_format"
        case imageDataBase64 = "image_data_base64"
    }

    public init(
        captureId: String,
        timestamp: Int64,
        topologyVersion: String,
        displayId: Int,
        widthPoints: Double,
        heightPoints: Double,
        scaleFactor: Double,
        pixelWidth: Int,
        pixelHeight: Int,
        imageFormat: String,
        imageDataBase64: String
    ) {
        self.captureId = captureId
        self.timestamp = timestamp
        self.topologyVersion = topologyVersion
        self.displayId = displayId
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.scaleFactor = scaleFactor
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.imageFormat = imageFormat
        self.imageDataBase64 = imageDataBase64
    }
}

public protocol DisplayCaptureEngine: Sendable {
    func captureDisplay(displayId: Int?, topology: DisplayTopology) async throws -> CaptureFrameDTO
}

public actor SCScreenshotCaptureEngine: DisplayCaptureEngine {
    public typealias ImageCapturer = @Sendable (SCContentFilter, SCStreamConfiguration) async throws -> CGImage

    private let authorizer: ScreenRecordingAuthorizing
    private let imageCapturer: ImageCapturer
    public private(set) var frameworkInvocationCount: Int = 0

    public init(
        authorizer: ScreenRecordingAuthorizing = CGScreenRecordingAuthorizer(),
        imageCapturer: ImageCapturer? = nil
    ) {
        self.authorizer = authorizer
        self.imageCapturer = imageCapturer ?? { filter, config in
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }

    public func captureDisplay(displayId: Int? = nil, topology: DisplayTopology) async throws -> CaptureFrameDTO {
        // 1. Permission Preflight Check BEFORE touching ScreenCaptureKit
        guard authorizer.isScreenCaptureAccessGranted else {
            throw ComputerUseError.permissionDenied(permission: "screen_recording")
        }

        let targetDisplayId = displayId ?? topology.primaryDisplayId
        guard let targetDisplay = topology.displays.first(where: { $0.id == targetDisplayId }) else {
            throw ComputerUseError.targetUnreachable(reason: "Display ID \(targetDisplayId) not found in topology")
        }

        // 2. Pre-check 64-megapixel budget BEFORE framework allocation
        guard targetDisplay.pixelWidth > 0, targetDisplay.pixelHeight > 0 else {
            throw ComputerUseError.targetUnreachable(reason: "Display ID \(targetDisplayId) pixel dimensions (\(targetDisplay.pixelWidth)x\(targetDisplay.pixelHeight)) must be positive")
        }
        let (totalPixels, overflow) = targetDisplay.pixelWidth.multipliedReportingOverflow(by: targetDisplay.pixelHeight)
        guard !overflow, totalPixels <= 64_000_000 else {
            throw ComputerUseError.targetUnreachable(reason: "Display ID \(targetDisplayId) pixel dimensions (\(targetDisplay.pixelWidth)x\(targetDisplay.pixelHeight)) exceed 64-megapixel safety limit")
        }

        // 3. Increment framework invocation counter to track real framework calls
        frameworkInvocationCount += 1

        // 4. Perform SCShareableContent discovery and filter creation entirely inside actor scope
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scDisplay = content.displays.first(where: { Int($0.displayID) == targetDisplayId }) else {
            throw ComputerUseError.targetUnreachable(reason: "Display ID \(targetDisplayId) not found in SCShareableContent")
        }

        let currentPid = ProcessInfo.processInfo.processIdentifier
        let excludingApps = content.applications.filter { $0.processID == currentPid }
        let contentFilter = SCContentFilter(display: scDisplay, excludingApplications: excludingApps, exceptingWindows: [])

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = targetDisplay.pixelWidth
        streamConfig.height = targetDisplay.pixelHeight
        streamConfig.showsCursor = false

        // 5. Capture image via injected imageCapturer
        let cgImage = try await imageCapturer(contentFilter, streamConfig)

        // 6. Validate and encode image via pure validator
        let (_, base64Str) = try SCScreenshotCaptureEngine.validateAndEncode(image: cgImage, targetDisplay: targetDisplay, quality: 0.8)

        let capId = "cap-\(UUID().uuidString)"
        return CaptureFrameDTO(
            captureId: capId,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            topologyVersion: topology.version,
            displayId: targetDisplay.id,
            widthPoints: targetDisplay.widthPoints,
            heightPoints: targetDisplay.heightPoints,
            scaleFactor: targetDisplay.scaleFactor,
            pixelWidth: targetDisplay.pixelWidth,
            pixelHeight: targetDisplay.pixelHeight,
            imageFormat: "jpeg",
            imageDataBase64: base64Str
        )
    }

    public static func validateAndEncode(image: CGImage, targetDisplay: DisplayInfo, quality: Double = 0.8) throws -> (data: Data, base64: String) {
        let pixelWidth = targetDisplay.pixelWidth
        let pixelHeight = targetDisplay.pixelHeight

        guard pixelWidth > 0, pixelHeight > 0 else {
            throw ComputerUseError.targetUnreachable(reason: "Display ID \(targetDisplay.id) has non-positive pixel dimensions")
        }

        let (totalPixels, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !overflow, totalPixels > 0, totalPixels <= 64_000_000 else {
            throw ComputerUseError.targetUnreachable(reason: "Display ID \(targetDisplay.id) pixel dimensions exceed safety limits")
        }

        guard image.width == pixelWidth, image.height == pixelHeight else {
            throw ComputerUseError.targetUnreachable(reason: "Captured CGImage dimensions (\(image.width)x\(image.height)) mismatch requested topology (\(pixelWidth)x\(pixelHeight))")
        }

        let jpegData = try encodeToJPEG(image: image, quality: quality)
        guard !jpegData.isEmpty else {
            throw ComputerUseError.ipcError(reason: "Encoded JPEG data is empty")
        }

        let maxRawBytes = 10 * 1024 * 1024 // Exact 10 MiB limit
        guard jpegData.count <= maxRawBytes else {
            throw ComputerUseError.ipcError(reason: "Captured JPEG image size (\(jpegData.count) bytes) exceeds maximum 10 MiB limit")
        }

        return (jpegData, jpegData.base64EncodedString())
    }

    public static func encodeToJPEG(image: CGImage, quality: Double = 0.8) throws -> Data {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ComputerUseError.ipcError(reason: "Failed to create ImageIO JPEG destination")
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ComputerUseError.ipcError(reason: "Failed to finalize JPEG encoding")
        }

        return mutableData as Data
    }
}
