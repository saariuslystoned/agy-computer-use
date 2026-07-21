import Foundation
import ScreenCaptureKit
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

public protocol ShareableContentLoader: Sendable {
    func loadShareableContent() async throws -> (displays: [SCDisplay], applications: [SCRunningApplication])
}

public struct SystemShareableContentLoader: ShareableContentLoader {
    public init() {}

    public func loadShareableContent() async throws -> (displays: [SCDisplay], applications: [SCRunningApplication]) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return (content.displays, content.applications)
    }
}

public actor SCScreenshotCaptureEngine: DisplayCaptureEngine {
    private let authorizer: ScreenRecordingAuthorizing
    private let contentLoader: ShareableContentLoader

    public init(
        authorizer: ScreenRecordingAuthorizing = CGScreenRecordingAuthorizer(),
        contentLoader: ShareableContentLoader = SystemShareableContentLoader()
    ) {
        self.authorizer = authorizer
        self.contentLoader = contentLoader
    }

    public func captureDisplay(displayId: Int? = nil, topology: DisplayTopology) async throws -> CaptureFrameDTO {
        // 1. Preflight TCC permission check BEFORE calling SCShareableContent
        guard authorizer.isScreenCaptureAccessGranted else {
            throw ComputerUseError.permissionDenied(permission: "screen_recording")
        }

        let targetDisplayId = displayId ?? topology.primaryDisplayId
        guard let targetDisplay = topology.displays.first(where: { $0.id == targetDisplayId }) else {
            throw ComputerUseError.targetUnreachable(reason: "Display ID \(targetDisplayId) not found in topology")
        }

        // 2. Bound & overflow check target dimensions
        let pixelWidth = targetDisplay.pixelWidth
        let pixelHeight = targetDisplay.pixelHeight
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw ComputerUseError.targetUnreachable(reason: "Display ID \(targetDisplayId) has invalid pixel dimensions")
        }
        let (totalPixels, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !overflow, totalPixels > 0, totalPixels <= 64_000_000 else { // 8K resolution boundary check
            throw ComputerUseError.targetUnreachable(reason: "Display ID \(targetDisplayId) pixel dimensions (\(pixelWidth)x\(pixelHeight)) exceed safety limits")
        }

        // 3. Load shareable content
        let (scDisplays, scApps) = try await contentLoader.loadShareableContent()
        guard let scDisplay = scDisplays.first(where: { Int($0.displayID) == targetDisplayId }) else {
            throw ComputerUseError.targetUnreachable(reason: "Display ID \(targetDisplayId) not found in SCShareableContent")
        }

        let currentPid = ProcessInfo.processInfo.processIdentifier
        let excludingApps = scApps.filter { $0.processID == currentPid }
        let contentFilter = SCContentFilter(display: scDisplay, excludingApplications: excludingApps, exceptingWindows: [])

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = pixelWidth
        streamConfig.height = pixelHeight
        streamConfig.showsCursor = false

        // 4. Capture CGImage via SCScreenshotManager
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: contentFilter, configuration: streamConfig)

        // 5. Verify returned CGImage dimensions match requested topology
        guard cgImage.width == pixelWidth, cgImage.height == pixelHeight else {
            throw ComputerUseError.targetUnreachable(reason: "Captured image dimensions (\(cgImage.width)x\(cgImage.height)) mismatch requested topology (\(pixelWidth)x\(pixelHeight))")
        }

        // 6. In-process JPEG encoding & exact 10 MiB limit check
        let jpegData = try SCScreenshotCaptureEngine.encodeToJPEG(image: cgImage, quality: 0.8)
        guard !jpegData.isEmpty else {
            throw ComputerUseError.ipcError(reason: "Encoded JPEG image data is empty")
        }

        let maxByteLimit = 10 * 1024 * 1024 // 10 MiB limit before base64 encoding
        guard jpegData.count <= maxByteLimit else {
            throw ComputerUseError.ipcError(reason: "Captured JPEG image size (\(jpegData.count) bytes) exceeds maximum 10 MiB limit")
        }

        let capId = "cap-\(UUID().uuidString)"
        return CaptureFrameDTO(
            captureId: capId,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            topologyVersion: topology.version,
            displayId: targetDisplay.id,
            widthPoints: targetDisplay.widthPoints,
            heightPoints: targetDisplay.heightPoints,
            scaleFactor: targetDisplay.scaleFactor,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            imageFormat: "jpeg",
            imageDataBase64: jpegData.base64EncodedString()
        )
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
