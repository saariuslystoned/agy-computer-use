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

/// Pure pixel-preflight helper enforcing positivity and the 64-megapixel safety limit.
public func validatePixelDimensions(width: Int, height: Int) throws {
    guard width > 0, height > 0 else {
        throw ComputerUseError.targetUnreachable(
            reason: "Pixel dimensions (\(width)x\(height)) must be positive"
        )
    }
    let (totalPixels, overflow) = width.multipliedReportingOverflow(by: height)
    guard !overflow, totalPixels <= 64_000_000 else {
        throw ComputerUseError.targetUnreachable(
            reason: "Pixel dimensions (\(width)x\(height)) exceed 64-megapixel safety limit"
        )
    }
}

public protocol DisplayCaptureEngine: Sendable {
    func captureDisplay(displayId: Int?, topology: DisplayTopology) async throws -> CaptureFrameDTO
}

public actor SCScreenshotCaptureEngine: DisplayCaptureEngine {
    public typealias ContentLoader = @Sendable () async throws -> SCShareableContent
    public typealias ImageCapturer = @Sendable (SCContentFilter, SCStreamConfiguration) async throws -> CGImage
    public typealias JPEGEncoder = @Sendable (CGImage, Double) throws -> Data

    private let authorizer: ScreenRecordingAuthorizing
    private let contentLoader: ContentLoader
    private let imageCapturer: ImageCapturer
    private let jpegEncoder: JPEGEncoder

    public private(set) var contentLoaderInvocationCount: Int = 0
    public private(set) var frameworkInvocationCount: Int = 0
    public private(set) var encoderInvocationCount: Int = 0

    public init(
        authorizer: ScreenRecordingAuthorizing = CGScreenRecordingAuthorizer(),
        contentLoader: ContentLoader? = nil,
        imageCapturer: ImageCapturer? = nil,
        jpegEncoder: JPEGEncoder? = nil
    ) {
        self.authorizer = authorizer
        self.contentLoader = contentLoader ?? {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        self.imageCapturer = imageCapturer ?? { filter, config in
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
        self.jpegEncoder = jpegEncoder ?? { image, quality in
            try SCScreenshotCaptureEngine.encodeToJPEG(image: image, quality: quality)
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

        // 2. Pre-check 64-megapixel budget BEFORE framework allocation or content loading
        try validatePixelDimensions(width: targetDisplay.pixelWidth, height: targetDisplay.pixelHeight)

        // 3. Content loading boundary
        contentLoaderInvocationCount += 1
        let content = try await contentLoader()
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

        // 4. Capture image via injected imageCapturer
        frameworkInvocationCount += 1
        let cgImage = try await imageCapturer(contentFilter, streamConfig)

        // 5. Validate and encode image via pure validator + injected encoder
        encoderInvocationCount += 1
        let (_, base64Str) = try SCScreenshotCaptureEngine.validateAndEncode(image: cgImage, targetDisplay: targetDisplay, quality: 0.8, jpegEncoder: self.jpegEncoder)

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

    public static func parseJPEGDimensions(data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else {
            return nil
        }

        var offset = 2
        var foundSOF = false
        var foundSOS = false
        var dimensions: (width: Int, height: Int)? = nil
        var frameNumComponents = 0
        var sofComponentIds = Set<UInt8>()
        var eoiOffset = -1

        while offset < data.count - 1 {
            if data[offset] != 0xFF {
                if foundSOS {
                    offset += 1
                    continue
                } else {
                    return nil
                }
            }

            while offset < data.count - 1 && data[offset] == 0xFF && data[offset + 1] == 0xFF {
                offset += 1
            }
            if offset >= data.count - 1 { return nil }

            let marker = data[offset + 1]

            if foundSOS {
                if marker == 0x00 {
                    offset += 2
                    continue
                }
                if marker >= 0xD0 && marker <= 0xD7 {
                    offset += 2
                    continue
                }
                if marker == 0xD9 {
                    eoiOffset = offset
                    break
                }
                // Inter-scan marker in progressive JPEG: transition out of entropy scan to parse next segment
                foundSOS = false
            }

            if marker == 0xD8 {
                return nil
            }

            if marker == 0xD9 {
                return nil
            }

            if marker == 0xDA {
                if !foundSOF { return nil }
                if offset + 4 >= data.count { return nil }
                let segLen = (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
                let numScanComponents = Int(data[offset + 4])
                if numScanComponents < 1 || numScanComponents > frameNumComponents { return nil }
                if segLen != 6 + 2 * numScanComponents || offset + 2 + segLen > data.count { return nil }
                var sosSelectors = Set<UInt8>()
                for j in 0..<numScanComponents {
                    let selector = data[offset + 5 + 2 * j]
                    if !sofComponentIds.contains(selector) || sosSelectors.contains(selector) { return nil }
                    sosSelectors.insert(selector)
                }
                foundSOS = true
                offset += 2 + segLen
                continue
            }

            if marker == 0xC0 || marker == 0xC2 {
                if foundSOF { return nil }
                if offset + 9 >= data.count { return nil }
                let segLen = (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
                let precision = data[offset + 4]
                if precision != 8 { return nil }

                let height = (Int(data[offset + 5]) << 8) | Int(data[offset + 6])
                let width = (Int(data[offset + 7]) << 8) | Int(data[offset + 8])
                let numComponents = Int(data[offset + 9])

                if segLen != 8 + 3 * numComponents || offset + 2 + segLen > data.count { return nil }
                if width <= 0 || height <= 0 { return nil }
                let (totalPixels, overflow) = width.multipliedReportingOverflow(by: height)
                if overflow || totalPixels > 64_000_000 { return nil }
                if numComponents != 1 && numComponents != 3 && numComponents != 4 { return nil }

                for i in 0..<numComponents {
                    let compId = data[offset + 10 + 3 * i]
                    if sofComponentIds.contains(compId) { return nil }
                    sofComponentIds.insert(compId)
                }
                frameNumComponents = numComponents

                dimensions = (width, height)
                foundSOF = true
                offset += 2 + segLen
                continue
            }

            // Whitelist legal header/inter-scan segment markers: 0xC4 (DHT), 0xDB (DQT), 0xDD (DRI), 0xFE (COM), 0xE0..0xEF (APP0..APP15)
            let isWhitelisted = marker == 0xC4 || marker == 0xDB || marker == 0xDD || marker == 0xFE || (marker >= 0xE0 && marker <= 0xEF)
            guard isWhitelisted else { return nil }

            if marker == 0xDD {
                if offset + 3 >= data.count { return nil }
                let segLen = (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
                if segLen != 4 || offset + 2 + segLen > data.count { return nil }
                offset += 2 + segLen
                continue
            }

            if offset + 3 < data.count {
                let segLen = (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
                if segLen < 2 || offset + 2 + segLen > data.count { return nil }
                offset += 2 + segLen
            } else {
                return nil
            }
        }

        guard foundSOF, foundSOS, let dims = dimensions, eoiOffset != -1 else {
            return nil
        }

        for i in (eoiOffset + 2)..<data.count {
            if data[i] != 0 {
                return nil
            }
        }

        return dims
    }

    public static func validateJPEGData(
        data: Data,
        expectedWidth: Int? = nil,
        expectedHeight: Int? = nil,
        maxBytes: Int = 10 * 1024 * 1024
    ) throws {
        guard !data.isEmpty else {
            throw ComputerUseError.ipcError(reason: "Encoded JPEG data is empty")
        }

        guard data.count <= maxBytes else {
            throw ComputerUseError.ipcError(reason: "Captured JPEG image size (\(data.count) bytes) exceeds maximum 10 MiB limit")
        }

        guard data.count >= 4 && data[0] == 0xFF && data[1] == 0xD8 else {
            throw ComputerUseError.ipcError(reason: "Invalid JPEG magic header")
        }

        guard let dims = parseJPEGDimensions(data: data) else {
            throw ComputerUseError.ipcError(reason: "Invalid JPEG structure or marker truncation")
        }

        if let expW = expectedWidth, let expH = expectedHeight {
            guard dims.width == expW && dims.height == expH else {
                throw ComputerUseError.targetUnreachable(reason: "Captured JPEG dimensions (\(dims.width)x\(dims.height)) mismatch requested topology (\(expW)x\(expH))")
            }
        }
    }

    public static func validateAndEncode(
        image: CGImage,
        targetDisplay: DisplayInfo,
        quality: Double = 0.8,
        overrideDataSize: Int? = nil,
        jpegEncoder: JPEGEncoder? = nil
    ) throws -> (data: Data, base64: String) {
        let pixelWidth = targetDisplay.pixelWidth
        let pixelHeight = targetDisplay.pixelHeight

        try validatePixelDimensions(width: pixelWidth, height: pixelHeight)

        guard image.width == pixelWidth, image.height == pixelHeight else {
            throw ComputerUseError.targetUnreachable(reason: "Captured CGImage dimensions (\(image.width)x\(image.height)) mismatch requested topology (\(pixelWidth)x\(pixelHeight))")
        }

        let encoder = jpegEncoder ?? { img, q in try encodeToJPEG(image: img, quality: q) }
        let jpegData = try encoder(image, quality)
        let effectiveSize = overrideDataSize ?? jpegData.count
        guard effectiveSize <= 10 * 1024 * 1024 else {
            throw ComputerUseError.targetUnreachable(reason: "Captured JPEG image size (\(effectiveSize) bytes) exceeds maximum 10 MiB limit")
        }
        try validateJPEGData(data: jpegData, expectedWidth: pixelWidth, expectedHeight: pixelHeight, maxBytes: 10 * 1024 * 1024)

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
