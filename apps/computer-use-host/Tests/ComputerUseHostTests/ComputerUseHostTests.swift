import Foundation
#if canImport(XCTest)
import XCTest
#endif
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import ScreenCaptureKit
@testable import ComputerUseHostLib

public struct FakeDisplayListEnumerator: DisplayListEnumerating {
    public let primaryId: Int
    public let displayIDs: [Int]
    public let shouldThrow: Bool

    public init(primaryId: Int = 1, displayIDs: [Int] = [1], shouldThrow: Bool = false) {
        self.primaryId = primaryId
        self.displayIDs = displayIDs
        self.shouldThrow = shouldThrow
    }

    public func getActiveDisplays() throws -> (primaryId: Int, displayIDs: [Int]) {
        if shouldThrow {
            throw ComputerUseError.targetUnreachable(reason: "Exhausted retries or enumerated list failed")
        }
        return (primaryId, displayIDs)
    }
}

public struct FakeScreenRecordingAuthorizer: ScreenRecordingAuthorizing {
    public let granted: Bool

    public init(granted: Bool = true) {
        self.granted = granted
    }

    public var isScreenCaptureAccessGranted: Bool {
        return granted
    }
}

public struct FakeDisplayTopologyProvider: DisplayTopologyProviding {
    public let topology: DisplayTopology

    public init(topology: DisplayTopology? = nil) {
        if let t = topology {
            self.topology = t
        } else {
            let defaultDisplays = [
                DisplayInfo(id: 1, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: 0, originY: 0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)
            ]
            let ver = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: defaultDisplays)
            self.topology = DisplayTopology(version: ver, primaryDisplayId: 1, displays: defaultDisplays)
        }
    }

    public func getTopology() throws -> DisplayTopology {
        return topology
    }
}

public final class FakeCaptureEngine: DisplayCaptureEngine, @unchecked Sendable {
    private var captureCounter = 1
    private let lock = NSLock()
    private let delayMs: UInt64

    public init(delayMs: UInt64 = 0) {
        self.delayMs = delayMs
    }

    private func nextCounter() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let count = captureCounter
        captureCounter += 1
        return count
    }

    public func captureDisplay(displayId: Int? = nil, topology: DisplayTopology) async throws -> CaptureFrameDTO {
        if delayMs > 0 {
            try await Task.sleep(nanoseconds: delayMs * 1_000_000)
        }
        let count = nextCounter()
        let targetDisplayId = displayId ?? topology.primaryDisplayId
        guard let targetDisplay = topology.displays.first(where: { $0.id == targetDisplayId }) else {
            throw ComputerUseError.targetUnreachable(reason: "Display ID \(targetDisplayId) not found in topology")
        }

        let dummyJpegBase64 = "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="

        return CaptureFrameDTO(
            captureId: "cap-\(String(format: "%04d", count))",
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            topologyVersion: topology.version,
            displayId: targetDisplay.id,
            widthPoints: targetDisplay.widthPoints,
            heightPoints: targetDisplay.heightPoints,
            scaleFactor: targetDisplay.scaleFactor,
            pixelWidth: targetDisplay.pixelWidth,
            pixelHeight: targetDisplay.pixelHeight,
            imageFormat: "jpeg",
            imageDataBase64: dummyJpegBase64
        )
    }
}

public struct TrackingShareableContentLoader: ShareableContentLoader {
    private let _loadCount: AtomicCounter = AtomicCounter()

    public init() {}

    public var loadCount: Int {
        return _loadCount.value
    }

    public func loadShareableContent() async throws -> (displays: [SCDisplay], applications: [SCRunningApplication]) {
        _loadCount.increment()
        return ([], [])
    }
}

public final class AtomicCounter: @unchecked Sendable {
    private var _val: Int = 0
    private let lock = NSLock()

    public init() {}

    public var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _val
    }

    public func increment() {
        lock.lock()
        _val += 1
        lock.unlock()
    }
}

public struct FakeAXInspector: AXInspectionEngine {
    public let available: Bool
    public let trusted: Bool

    public init(available: Bool = false, trusted: Bool = false) {
        self.available = available
        self.trusted = trusted
    }

    public var isAvailable: Bool { available }

    public func isAccessibilityTrusted() -> Bool {
        return trusted
    }

    public func inspectTree(maxDepth: Int = 10, appId: String? = nil) throws -> AXNodeDTO {
        guard available else {
            throw ComputerUseError.targetUnreachable(reason: "AX tree inspection is unavailable in this build phase")
        }
        return AXNodeDTO(
            id: "app-root",
            role: "AXApplication",
            title: appId ?? "Finder",
            bounds: AXRect(x: 0, y: 0, width: 1920, height: 1080)
        )
    }
}

#if canImport(XCTest)
final class ComputerUseHostTests: XCTestCase {

    func testLengthPrefixedFraming() throws {
        let originalText = "Hello, Framed IPC!"
        let payload = originalText.data(using: .utf8)!
        let encoded = try LengthPrefixedFramer.encode(payload: payload)
        XCTAssertEqual(encoded.count, 4 + payload.count)

        var buffer = encoded
        let decoded = try LengthPrefixedFramer.decode(from: &buffer)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(String(data: decoded!, encoding: .utf8), originalText)

        // Fragmented framing test
        var partialBuffer = encoded.subdata(in: 0..<3)
        let decNil = try LengthPrefixedFramer.decode(from: &partialBuffer)
        XCTAssertNil(decNil, "Partial length header must return nil")

        partialBuffer.append(encoded.subdata(in: 3..<encoded.count))
        let decComplete = try LengthPrefixedFramer.decode(from: &partialBuffer)
        XCTAssertNotNil(decComplete, "Complete reassembled buffer must decode successfully")
    }

    func testOversizedFramingHeaderRejection() throws {
        var oversized = Data([0x01, 0x00, 0x00, 0x01]) // 16MB + 1 byte
        oversized.append(Data([0x00]))
        XCTAssertThrowsError(try LengthPrefixedFramer.decode(from: &oversized))
    }

    func testDirectoryPreparation() throws {
        let testDirPath = "/tmp/agy-computer-use-test-\(getuid())"
        try SocketListener.prepareDirectory(at: testDirPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: testDirPath))
    }

    func testUDSClientServerRoundTrip() async throws {
        let testDirPath = "/tmp/agy-computer-use-test-\(getuid())"
        try SocketListener.prepareDirectory(at: testDirPath)
        let testSocketPath = "\(testDirPath)/test-roundtrip-\(UUID().uuidString).sock"

        let fakeTopologyProvider = FakeDisplayTopologyProvider()
        let fakeCaptureEngine = FakeCaptureEngine()
        let fakeInputInjector = DisabledInputInjector()
        let fakeAXInspector = FakeAXInspector(available: false, trusted: false)

        let serverActor = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: fakeTopologyProvider,
            captureEngine: fakeCaptureEngine,
            axEngine: fakeAXInspector,
            inputEngine: fakeInputInjector
        )

        let listener = SocketListener(socketPath: testSocketPath, server: serverActor, perFrameTimeoutSec: 5.0)
        try listener.start()

        let serverTask = Task {
            _ = try await listener.acceptAndHandleOneConnection()
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        let clientFd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(clientFd, 0, "Client socket creation failed")

        var addr = sockaddr_un()
        let pathBytes = testSocketPath.utf8CString
        let addrLen = MemoryLayout<sa_family_t>.size + pathBytes.count
        addr.sun_len = UInt8(addrLen)
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            ptr.initializeMemory(as: CChar.self, repeating: 0)
            _ = pathBytes.withUnsafeBufferPointer { bPtr in
                memcpy(ptr.baseAddress!, bPtr.baseAddress!, bPtr.count)
            }
        }

        let connRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                connect(clientFd, saPtr, socklen_t(addrLen))
            }
        }
        XCTAssertEqual(connRes, 0, "Socket connect failed")

        let req = IPCRequest(id: "uds-test-1", method: "status")
        let reqData = try JSONEncoder().encode(req)
        let framedReq = try LengthPrefixedFramer.encode(payload: reqData)
        _ = framedReq.withUnsafeBytes { bPtr in
            write(clientFd, bPtr.baseAddress!, framedReq.count)
        }

        var resHeader = [UInt8](repeating: 0, count: 4)
        _ = read(clientFd, &resHeader, 4)
        let resLen = Int(resHeader[0]) << 24 | Int(resHeader[1]) << 16 | Int(resHeader[2]) << 8 | Int(resHeader[3])
        XCTAssertGreaterThan(resLen, 0, "Response payload length must be > 0")

        var resPayload = [UInt8](repeating: 0, count: resLen)
        _ = read(clientFd, &resPayload, resLen)
        close(clientFd)

        _ = await serverTask.result
        listener.stop()

        let resp = try JSONDecoder().decode(IPCResponse.self, from: Data(resPayload))
        XCTAssertTrue(resp.success, "Real UDS socket response must indicate success")
        XCTAssertEqual(resp.id, "uds-test-1")
    }

    func testIEEE754BitPatternTopologyHashing() throws {
        let dPrimary = DisplayInfo(id: 1, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: 0, originY: 0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)
        let dSecondaryNeg = DisplayInfo(id: 2, widthPoints: 2560, heightPoints: 1440, scaleFactor: 2.0, originX: -2560, originY: 0, pixelWidth: 5120, pixelHeight: 2880, rotation: 90.0)

        let versionA = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [dPrimary, dSecondaryNeg])
        let versionB = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [dSecondaryNeg, dPrimary])

        XCTAssertTrue(versionA.hasPrefix("top-sha256-"), "Version string must start with top-sha256-")
        XCTAssertEqual(versionA.count, 75, "Full SHA-256 token must be 75 characters long")
        XCTAssertEqual(versionA, versionB, "Topology SHA-256 computation must be order-independent")

        // Micro-mutation test: 0.0 vs 0.00001
        let dMutated = DisplayInfo(id: 2, widthPoints: 2560, heightPoints: 1440, scaleFactor: 2.0, originX: -2560.00001, originY: 0, pixelWidth: 5120, pixelHeight: 2880, rotation: 90.0)
        let versionMutated = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [dPrimary, dMutated])
        XCTAssertNotEqual(versionA, versionMutated, "Micro-mutation of 0.00001 must produce a distinct IEEE-754 bitPattern hash")
    }

    func testHotPlugSafeDisplayEnumerator() throws {
        // Test duplicate display ID rejection
        let dupEnumerator = FakeDisplayListEnumerator(primaryId: 1, displayIDs: [1, 1])
        let dupProvider = SystemDisplayTopologyProvider(enumerator: dupEnumerator)
        XCTAssertThrowsError(try dupProvider.getTopology())

        // Test zero display ID rejection
        let zeroEnumerator = FakeDisplayListEnumerator(primaryId: 1, displayIDs: [0])
        let zeroProvider = SystemDisplayTopologyProvider(enumerator: zeroEnumerator)
        XCTAssertThrowsError(try zeroProvider.getTopology())

        // Test missing primary display ID rejection
        let missingPrimaryEnumerator = FakeDisplayListEnumerator(primaryId: 2, displayIDs: [1])
        let missingPrimaryProvider = SystemDisplayTopologyProvider(enumerator: missingPrimaryEnumerator)
        XCTAssertThrowsError(try missingPrimaryProvider.getTopology())
    }

    func testPermissionPreflightDeniedZeroLoaderCalls() async throws {
        let trackingLoader = TrackingShareableContentLoader()
        let engineDenied = SCScreenshotCaptureEngine(
            authorizer: FakeScreenRecordingAuthorizer(granted: false),
            contentLoader: trackingLoader
        )
        let dPrimary = DisplayInfo(id: 1, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: 0, originY: 0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)

        do {
            _ = try await engineDenied.captureDisplay(displayId: 1, topology: DisplayTopology(version: "top-sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", primaryDisplayId: 1, displays: [dPrimary]))
            XCTFail("Permission denied must throw")
        } catch let err as ComputerUseError {
            if case .permissionDenied(let perm) = err {
                XCTAssertEqual(perm, "screen_recording")
            } else {
                XCTFail("Unexpected error: \(err)")
            }
        }
        XCTAssertEqual(trackingLoader.loadCount, 0, "ShareableContentLoader must NEVER be called when preflight permission check fails")
    }

    func testPureJPEGValidatorAndDimensionCheck() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: 100,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 400,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Unable to create test CGContext")
            return
        }
        ctx.setFillColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        guard let cgImg = ctx.makeImage() else {
            XCTFail("Unable to create test CGImage")
            return
        }

        let targetDisplay = DisplayInfo(id: 1, widthPoints: 50, heightPoints: 50, scaleFactor: 2.0, originX: 0, originY: 0, pixelWidth: 100, pixelHeight: 100, rotation: 0.0)

        let (jpegData, _) = try SCScreenshotCaptureEngine.validateAndEncode(image: cgImg, targetDisplay: targetDisplay, quality: 0.8)
        XCTAssertFalse(jpegData.isEmpty)
        let magicBytes = [UInt8](jpegData.prefix(3))
        XCTAssertEqual(magicBytes, [0xFF, 0xD8, 0xFF], "JPEG magic bytes must match")

        // Dimension mismatch rejection
        let mismatchedDisplay = DisplayInfo(id: 1, widthPoints: 100, heightPoints: 100, scaleFactor: 2.0, originX: 0, originY: 0, pixelWidth: 200, pixelHeight: 200, rotation: 0.0)
        XCTAssertThrowsError(try SCScreenshotCaptureEngine.validateAndEncode(image: cgImg, targetDisplay: mismatchedDisplay, quality: 0.8))
    }

    func testDisabledActionsAndAXTreeRejection() async throws {
        let prodServer = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: FakeCaptureEngine(),
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector()
        )

        let disabledActions = ["click", "move", "drag", "type", "shortcut", "scroll"]
        for actionName in disabledActions {
            let actResp = await prodServer.handleRequest(IPCRequest(id: "dis-\(actionName)", method: actionName))
            XCTAssertFalse(actResp.success)
            XCTAssertEqual(actResp.error?.code, "MUTATION_DISABLED")
        }

        let axResp = await prodServer.handleRequest(IPCRequest(id: "ax1", method: "ax_tree"))
        XCTAssertFalse(axResp.success)
        XCTAssertEqual(axResp.error?.code, "TARGET_UNREACHABLE")
    }

    func testDisplayIdParameterValidation() async throws {
        let prodServer = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: FakeCaptureEngine(),
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector()
        )

        let invalidReq = IPCRequest(id: "inv-1", method: "observe", params: ["display_id": .string("1")])
        let resp = await prodServer.handleRequest(invalidReq)
        XCTAssertFalse(resp.success)
        XCTAssertEqual(resp.error?.code, "IPC_ERROR")
    }
}
#endif
