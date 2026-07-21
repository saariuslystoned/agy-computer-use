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

public final class FakeCaptureEngine: DisplayCaptureEngine, @unchecked Sendable {
    private var captureCounter = 1
    private let lock = NSLock()

    public init() {}

    private func nextCounter() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let count = captureCounter
        captureCounter += 1
        return count
    }

    public func captureDisplay(displayId: Int? = nil, topology: DisplayTopology) async throws -> CaptureFrameDTO {
        let count = nextCounter()

        let targetDisplayId = displayId ?? topology.primaryDisplayId
        guard let targetDisplay = topology.displays.first(where: { $0.id == targetDisplayId }) else {
            throw ComputerUseError.targetUnreachable(reason: "Display ID \(targetDisplayId) not found in topology")
        }

        let capId = "cap-\(String(format: "%04d", count))"
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

public final class SCScreenshotCaptureEngine: DisplayCaptureEngine, @unchecked Sendable {
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
        // Preflight TCC permission check BEFORE calling SCShareableContent
        guard authorizer.isScreenCaptureAccessGranted else {
            throw ComputerUseError.permissionDenied(permission: "screen_recording")
        }

        let targetDisplayId = displayId ?? topology.primaryDisplayId
        guard let targetDisplay = topology.displays.first(where: { $0.id == targetDisplayId }) else {
            throw ComputerUseError.targetUnreachable(reason: "Display ID \(targetDisplayId) not found in topology")
        }

        let (scDisplays, scApps) = try await contentLoader.loadShareableContent()
        guard let scDisplay = scDisplays.first(where: { Int($0.displayID) == targetDisplayId }) else {
            throw ComputerUseError.targetUnreachable(reason: "Display ID \(targetDisplayId) not found in SCShareableContent")
        }

        let currentPid = ProcessInfo.processInfo.processIdentifier
        let excludingApps = scApps.filter { $0.processID == currentPid }
        let contentFilter = SCContentFilter(display: scDisplay, excludingApplications: excludingApps, exceptingWindows: [])

        let streamConfig = SCStreamConfiguration()
        let pixelWidth = targetDisplay.pixelWidth > 0 ? targetDisplay.pixelWidth : Int((targetDisplay.widthPoints * targetDisplay.scaleFactor).rounded())
        let pixelHeight = targetDisplay.pixelHeight > 0 ? targetDisplay.pixelHeight : Int((targetDisplay.heightPoints * targetDisplay.scaleFactor).rounded())

        streamConfig.width = pixelWidth
        streamConfig.height = pixelHeight
        streamConfig.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: contentFilter, configuration: streamConfig)

        let jpegData = try SCScreenshotCaptureEngine.encodeToJPEG(image: cgImage, quality: 0.8)

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
