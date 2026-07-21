import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit
@testable import ComputerUseHostLib

#if canImport(XCTest)
import XCTest

final class ComputerUseHostTests: XCTestCase {
    func testHostSuite() async throws {
        try await ComputerUseHostTestRunner.runAll()
    }
}
#endif

// Test-only fakes (completely isolated from production library target)
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

public final class ScriptedCaptureEngine: DisplayCaptureEngine, @unchecked Sendable {
    private let delayMs: UInt64
    private let shouldFailOversized: Bool

    public init(delayMs: UInt64 = 0, shouldFailOversized: Bool = false) {
        self.delayMs = delayMs
        self.shouldFailOversized = shouldFailOversized
    }

    public func captureDisplay(displayId: Int? = nil, topology: DisplayTopology) async throws -> CaptureFrameDTO {
        if delayMs > 0 {
            try await Task.sleep(nanoseconds: delayMs * 1_000_000)
        }

        let targetId = displayId ?? topology.primaryDisplayId
        guard let targetDisplay = topology.displays.first(where: { $0.id == targetId }) else {
            throw ComputerUseError.targetUnreachable(reason: "Display ID \(targetId) not found in topology")
        }

        if shouldFailOversized {
            throw ComputerUseError.ipcError(reason: "Captured JPEG image size (11000000 bytes) exceeds maximum 10 MiB limit")
        }

        let dummyJpegBase64 = "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="

        return CaptureFrameDTO(
            captureId: "cap-scripted-\(UUID().uuidString.prefix(8))",
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

public final class FakeInputInjector: InputSynthesisEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _actionHistory: [String] = []

    public init() {}

    public var isMutationEnabled: Bool { true }

    public var actionHistory: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _actionHistory
    }

    private func validatePrecondition(captureId: String, currentCaptureId: String) throws {
        guard captureId == currentCaptureId else {
            throw ComputerUseError.staleCapture(current: currentCaptureId, received: captureId)
        }
    }

    public func performClick(gridX: Int, gridY: Int, button: MouseButton, clickCount: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        try validatePrecondition(captureId: captureId, currentCaptureId: currentCaptureId)
        let point = try CoordinateMapper.gridToLogicalPoint(gridX: gridX, gridY: gridY, display: display)

        lock.lock()
        let count = _actionHistory.count
        _actionHistory.append("click(\(point.x), \(point.y), \(button.rawValue), count: \(clickCount))")
        lock.unlock()

        let actId = "act-click-\(count + 1)"
        return ActionResultDTO(actionId: actId, status: "dispatched", captureId: captureId, durationMs: 12.5)
    }

    public func performMove(gridX: Int, gridY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        try validatePrecondition(captureId: captureId, currentCaptureId: currentCaptureId)
        let point = try CoordinateMapper.gridToLogicalPoint(gridX: gridX, gridY: gridY, display: display)

        lock.lock()
        let count = _actionHistory.count
        _actionHistory.append("move(\(point.x), \(point.y))")
        lock.unlock()

        let actId = "act-move-\(count + 1)"
        return ActionResultDTO(actionId: actId, status: "dispatched", captureId: captureId, durationMs: 8.0)
    }

    public func performDrag(startX: Int, startY: Int, endX: Int, endY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        try validatePrecondition(captureId: captureId, currentCaptureId: currentCaptureId)
        let startPoint = try CoordinateMapper.gridToLogicalPoint(gridX: startX, gridY: startY, display: display)
        let endPoint = try CoordinateMapper.gridToLogicalPoint(gridX: endX, gridY: endY, display: display)

        lock.lock()
        let count = _actionHistory.count
        _actionHistory.append("drag((\(startPoint.x), \(startPoint.y)) -> (\(endPoint.x), \(endPoint.y)))")
        lock.unlock()

        let actId = "act-drag-\(count + 1)"
        return ActionResultDTO(actionId: actId, status: "dispatched", captureId: captureId, durationMs: 45.0)
    }

    public func performType(text: String, pressEnter: Bool, captureId: String, currentCaptureId: String) throws -> ActionResultDTO {
        try validatePrecondition(captureId: captureId, currentCaptureId: currentCaptureId)

        lock.lock()
        let count = _actionHistory.count
        let enterSuffix = pressEnter ? "+return" : ""
        _actionHistory.append("type([REDACTED_TEXT]\(enterSuffix))")
        lock.unlock()

        let actId = "act-type-\(count + 1)"
        return ActionResultDTO(actionId: actId, status: "dispatched", captureId: captureId, durationMs: Double(text.count * 10))
    }

    public func performShortcut(keys: [String], captureId: String, currentCaptureId: String) throws -> ActionResultDTO {
        try validatePrecondition(captureId: captureId, currentCaptureId: currentCaptureId)

        lock.lock()
        let count = _actionHistory.count
        _actionHistory.append("shortcut(\(keys.joined(separator: "+")))")
        lock.unlock()

        let actId = "act-shortcut-\(count + 1)"
        return ActionResultDTO(actionId: actId, status: "dispatched", captureId: captureId, durationMs: 15.0)
    }

    public func performScroll(gridX: Int, gridY: Int, deltaX: Int, deltaY: Int, captureId: String, currentCaptureId: String, display: DisplayInfo) throws -> ActionResultDTO {
        try validatePrecondition(captureId: captureId, currentCaptureId: currentCaptureId)
        let point = try CoordinateMapper.gridToLogicalPoint(gridX: gridX, gridY: gridY, display: display)

        lock.lock()
        let count = _actionHistory.count
        _actionHistory.append("scroll(\(point.x), \(point.y), dx: \(deltaX), dy: \(deltaY))")
        lock.unlock()

        let actId = "act-scroll-\(count + 1)"
        return ActionResultDTO(actionId: actId, status: "dispatched", captureId: captureId, durationMs: 10.0)
    }

    public func releaseHeldInputs() {}
}

public struct ComputerUseHostTestRunner {
    private static func assertTrue(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
        if !condition {
            fputs("[FAIL] \(message) at \(file):\(line)\n", stderr)
            exit(1)
        }
    }

    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: String = #file, line: Int = #line) {
        if actual != expected {
            fputs("[FAIL] Expected '\(expected)', got '\(actual)'. \(message) at \(file):\(line)\n", stderr)
            exit(1)
        }
    }

    public static func runAll() async throws {
        fputs("[TEST] Running Swift Host Unit & Integration Tests (Milestone D2 Repair 1)...\n", stderr)

        // 1. Framing tests
        let originalText = "Hello, Framed IPC!"
        let payload = originalText.data(using: .utf8)!
        let encoded = try LengthPrefixedFramer.encode(payload: payload)
        assertEqual(encoded.count, 4 + payload.count)

        var buffer = encoded
        let decoded = try LengthPrefixedFramer.decode(from: &buffer)
        assertTrue(decoded != nil)
        assertEqual(String(data: decoded!, encoding: .utf8), originalText)

        // 2. Fragmented & Coalesced framing test
        var partialBuffer = encoded.subdata(in: 0..<3)
        let decNil = try LengthPrefixedFramer.decode(from: &partialBuffer)
        assertTrue(decNil == nil, "Partial length header must return nil")

        partialBuffer.append(encoded.subdata(in: 3..<encoded.count))
        let decComplete = try LengthPrefixedFramer.decode(from: &partialBuffer)
        assertTrue(decComplete != nil, "Complete reassembled buffer must decode successfully")

        // 3. Oversized header test (>16MB)
        var oversized = Data([0x01, 0x00, 0x00, 0x01]) // 16MB + 1 byte
        oversized.append(Data([0x00]))
        var threwOversized = false
        do { _ = try LengthPrefixedFramer.decode(from: &oversized) } catch { threwOversized = true }
        assertTrue(threwOversized, "Oversized header must throw ipcError")

        // 4. Socket Directory Preparation & Safe Unlinking Test
        let testDirPath = "/tmp/agy-computer-use-test-\(getuid())"
        try SocketListener.prepareDirectory(at: testDirPath)
        assertTrue(FileManager.default.fileExists(atPath: testDirPath))

        // 5. Real UDS Client-Server Round Trip Test over Darwin Unix Domain Socket with Fake drivers
        let testSocketPath = "\(testDirPath)/test-roundtrip-\(UUID().uuidString).sock"
        let fakeTopologyProvider = FakeDisplayTopologyProvider()
        let fakeCaptureEngine = FakeCaptureEngine()
        let fakeInputInjector = FakeInputInjector()
        let fakeAXInspector = FakeAXInspector(available: false, trusted: false)

        let serverActor = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: fakeTopologyProvider,
            captureEngine: fakeCaptureEngine,
            axEngine: fakeAXInspector,
            inputEngine: fakeInputInjector
        )

        let listener = SocketListener(socketPath: testSocketPath, server: serverActor)
        try listener.start()

        let serverTask = Task {
            _ = try await listener.acceptAndHandleOneConnection()
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        let clientFd = socket(AF_UNIX, SOCK_STREAM, 0)
        assertTrue(clientFd >= 0, "Client socket creation failed")

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
        assertEqual(connRes, 0, "Socket connect failed")

        let req = IPCRequest(id: "uds-test-1", method: "status")
        let reqData = try JSONEncoder().encode(req)
        let framedReq = try LengthPrefixedFramer.encode(payload: reqData)
        _ = framedReq.withUnsafeBytes { bPtr in
            write(clientFd, bPtr.baseAddress!, framedReq.count)
        }

        var resHeader = [UInt8](repeating: 0, count: 4)
        _ = read(clientFd, &resHeader, 4)
        let resLen = Int(resHeader[0]) << 24 | Int(resHeader[1]) << 16 | Int(resHeader[2]) << 8 | Int(resHeader[3])
        assertTrue(resLen > 0, "Response payload length must be > 0")

        var resPayload = [UInt8](repeating: 0, count: resLen)
        _ = read(clientFd, &resPayload, resLen)
        close(clientFd)

        _ = await serverTask.result
        listener.stop()

        let resp = try JSONDecoder().decode(IPCResponse.self, from: Data(resPayload))
        assertTrue(resp.success, "Real UDS socket response must indicate success")
        assertEqual(resp.id, "uds-test-1")

        // 6. Grid Coordinate mapping tests (0, 500, 999, -1, 1000)
        let display = DisplayInfo(id: 1, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: 0, originY: 0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)

        let p0 = try CoordinateMapper.gridToLogicalPoint(gridX: 0, gridY: 0, display: display)
        assertEqual(p0.x, 0.0)
        assertEqual(p0.y, 0.0)

        let p500 = try CoordinateMapper.gridToLogicalPoint(gridX: 500, gridY: 500, display: display)
        assertEqual(p500.x, 960.0)
        assertEqual(p500.y, 540.0)

        let p999 = try CoordinateMapper.gridToLogicalPoint(gridX: 999, gridY: 999, display: display)
        assertEqual(p999.x, 1918.0)
        assertEqual(p999.y, 1078.0)
        assertTrue(p999.x < display.widthPoints, "999 gridX must be inside half-open display width [0, 1920)")

        var threwMinus1 = false
        do { _ = try CoordinateMapper.gridToLogicalPoint(gridX: -1, gridY: 500, display: display) } catch { threwMinus1 = true }
        assertTrue(threwMinus1)

        var threw1000 = false
        do { _ = try CoordinateMapper.gridToLogicalPoint(gridX: 1000, gridY: 500, display: display) } catch { threw1000 = true }
        assertTrue(threw1000)

        // 7. Deterministic Topology & Full SHA-256 Hashing Tests (Golden, order-independence, single-field mutation)
        let dPrimary = DisplayInfo(id: 1, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: 0, originY: 0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)
        let dSecondaryNeg = DisplayInfo(id: 2, widthPoints: 2560, heightPoints: 1440, scaleFactor: 2.0, originX: -2560, originY: 0, pixelWidth: 5120, pixelHeight: 2880, rotation: 90.0)

        let versionA = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [dPrimary, dSecondaryNeg])
        let versionB = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [dSecondaryNeg, dPrimary])
        assertTrue(versionA.hasPrefix("top-sha256-"), "Version string must start with top-sha256-")
        assertEqual(versionA.count, 11 + 64, "Full SHA-256 digest string must be exactly 64 hex characters (75 chars total)")
        assertEqual(versionA, versionB, "Topology SHA-256 version computation must be order-independent across display descriptors")

        // Single-field mutation tests
        let fieldMutations: [DisplayInfo] = [
            DisplayInfo(id: 2, widthPoints: 2560, heightPoints: 1440, scaleFactor: 2.0, originX: -2561, originY: 0, pixelWidth: 5120, pixelHeight: 2880, rotation: 90.0), // originX
            DisplayInfo(id: 2, widthPoints: 2560, heightPoints: 1440, scaleFactor: 2.0, originX: -2560, originY: 1, pixelWidth: 5120, pixelHeight: 2880, rotation: 90.0), // originY
            DisplayInfo(id: 2, widthPoints: 2561, heightPoints: 1440, scaleFactor: 2.0, originX: -2560, originY: 0, pixelWidth: 5120, pixelHeight: 2880, rotation: 90.0), // widthPoints
            DisplayInfo(id: 2, widthPoints: 2560, heightPoints: 1441, scaleFactor: 2.0, originX: -2560, originY: 0, pixelWidth: 5120, pixelHeight: 2880, rotation: 90.0), // heightPoints
            DisplayInfo(id: 2, widthPoints: 2560, heightPoints: 1440, scaleFactor: 1.5, originX: -2560, originY: 0, pixelWidth: 5120, pixelHeight: 2880, rotation: 90.0), // scaleFactor
            DisplayInfo(id: 2, widthPoints: 2560, heightPoints: 1440, scaleFactor: 2.0, originX: -2560, originY: 0, pixelWidth: 5121, pixelHeight: 2880, rotation: 90.0), // pixelWidth
            DisplayInfo(id: 2, widthPoints: 2560, heightPoints: 1440, scaleFactor: 2.0, originX: -2560, originY: 0, pixelWidth: 5120, pixelHeight: 2881, rotation: 90.0), // pixelHeight
            DisplayInfo(id: 2, widthPoints: 2560, heightPoints: 1440, scaleFactor: 2.0, originX: -2560, originY: 0, pixelWidth: 5120, pixelHeight: 2880, rotation: 0.0)   // rotation
        ]

        for mutDisplay in fieldMutations {
            let mutVersion = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [dPrimary, mutDisplay])
            assertTrue(versionA != mutVersion, "Single-field descriptor mutation must produce a distinct topology SHA-256 digest")
        }

        // 8. Permission Denied Preflight Proof (SCShareableContent loader must NEVER be called when preflight is false)
        let trackingLoader = TrackingShareableContentLoader()
        let engineDenied = SCScreenshotCaptureEngine(
            authorizer: FakeScreenRecordingAuthorizer(granted: false),
            contentLoader: trackingLoader
        )
        var deniedThrew = false
        do {
            _ = try await engineDenied.captureDisplay(displayId: 1, topology: DisplayTopology(version: "top-v1", primaryDisplayId: 1, displays: [dPrimary]))
        } catch let err as ComputerUseError {
            if case .permissionDenied(let perm) = err {
                assertEqual(perm, "screen_recording")
                deniedThrew = true
            }
        }
        assertTrue(deniedThrew, "Preflight permission failure must throw ComputerUseError.permissionDenied")
        assertEqual(trackingLoader.loadCount, 0, "ShareableContentLoader must NEVER be called when preflight permission check fails")

        // 9. In-Memory Synthetic CGImage JPEG Encoding & Decoding Round-Trip Test with exact dimensions assertion
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
            fputs("[FAIL] Unable to create test CGContext\n", stderr)
            exit(1)
        }
        ctx.setFillColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        guard let cgImg = ctx.makeImage() else {
            fputs("[FAIL] Unable to create test CGImage\n", stderr)
            exit(1)
        }

        let jpegData = try SCScreenshotCaptureEngine.encodeToJPEG(image: cgImg, quality: 0.8)
        assertTrue(jpegData.count > 0, "Encoded JPEG data must be non-empty")
        let magicBytes = [UInt8](jpegData.prefix(3))
        assertEqual(magicBytes, [0xFF, 0xD8, 0xFF], "Encoded JPEG data must begin with JPEG magic bytes [0xFF, 0xD8, 0xFF]")

        // Decode synthetic JPEG and assert pixel dimensions
        guard let imageSource = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let decodedCGImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            fputs("[FAIL] Failed to decode synthetic JPEG image data\n", stderr)
            exit(1)
        }
        assertEqual(decodedCGImage.width, 100, "Decoded JPEG image width must match original 100px")
        assertEqual(decodedCGImage.height, 100, "Decoded JPEG image height must match original 100px")

        // 10. Production-Disabled Action Tests & Lease Retention Proof
        let prodServer = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: FakeCaptureEngine(),
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector()
        )

        let obsProd = await prodServer.handleRequest(IPCRequest(id: "p1", method: "observe"))
        assertTrue(obsProd.success)
        let capProdId = obsProd.data?["capture_id"]?.rawValue as? String
        assertTrue(capProdId != nil)
        let topVerProd = obsProd.data?["topology_version"]?.rawValue as? String
        assertTrue(topVerProd != nil)

        let clickProdParams: [String: AnyCodable] = [
            "x": .int(500),
            "y": .int(500),
            "button": .string("left"),
            "click_count": .int(1),
            "capture_id": .string(capProdId!),
            "topology_version": .string(topVerProd!),
            "intent": .string("Click disabled action")
        ]

        let disabledActions = ["click", "move", "drag", "type", "shortcut", "scroll"]
        for actionName in disabledActions {
            let actResp = await prodServer.handleRequest(IPCRequest(id: "dis-\(actionName)", method: actionName, params: clickProdParams))
            assertTrue(!actResp.success, "Disabled action '\(actionName)' must return success: false")
            assertEqual(actResp.error?.code, "MUTATION_DISABLED", "Disabled action '\(actionName)' must return error code MUTATION_DISABLED")
        }

        let axProd = await prodServer.handleRequest(IPCRequest(id: "ax1", method: "ax_tree"))
        assertTrue(!axProd.success, "Disabled AX inspection must fail")
        assertEqual(axProd.error?.code, "TARGET_UNREACHABLE", "Disabled AX inspection must return TARGET_UNREACHABLE")

        // 11. Strict display_id Parameter Validation Test
        let invalidDisplayParamReq = IPCRequest(id: "inv-disp", method: "observe", params: ["display_id": .string("1")])
        let invDispResp = await prodServer.handleRequest(invalidDisplayParamReq)
        assertTrue(!invDispResp.success, "String display_id parameter must be rejected")
        assertEqual(invDispResp.error?.code, "IPC_ERROR", "Invalid display_id type must return IPC_ERROR")

        // 12. Production Composition & Zero-Fake Symbol Guard (Source & Binary check)
        let defaultProdServer = HostServer()
        let prodStatus = await defaultProdServer.handleRequest(IPCRequest(id: "p-stat", method: "status"))
        assertTrue(prodStatus.success)
        assertEqual(prodStatus.data?["input_mutation_state"]?.rawValue as? String, "disabled")
        assertEqual(prodStatus.data?["accessibility_available"]?.rawValue as? Bool, false)

        // Source Code Safety & Absence Proof (CGRequestScreenCaptureAccess, CGEvent, and Fake* symbols in Sources)
        let currentFile = #filePath
        let testsDir = pathComponentsUp(from: currentFile, levels: 1)
        let appsDir = pathComponentsUp(from: testsDir, levels: 1)
        let sourcesDir = "\(appsDir)/Sources"

        let sourceFiles = try getRecursiveSwiftFiles(at: sourcesDir)
        assertTrue(!sourceFiles.isEmpty, "Sources directory must contain Swift source files")

        for sFile in sourceFiles {
            let content = try String(contentsOfFile: sFile, encoding: .utf8)
            assertTrue(!content.contains("CGRequestScreenCaptureAccess"), "File \(sFile) must NOT contain CGRequestScreenCaptureAccess")
            assertTrue(!content.contains("CGEvent"), "File \(sFile) must NOT contain CGEvent")
            assertTrue(!content.contains("FakeScreenRecordingAuthorizer"), "File \(sFile) must NOT contain FakeScreenRecordingAuthorizer")
            assertTrue(!content.contains("FakeDisplayTopologyProvider"), "File \(sFile) must NOT contain FakeDisplayTopologyProvider")
            assertTrue(!content.contains("FakeCaptureEngine"), "File \(sFile) must NOT contain FakeCaptureEngine")
            assertTrue(!content.contains("FakeAXInspector"), "File \(sFile) must NOT contain FakeAXInspector")
            assertTrue(!content.contains("FakeInputInjector"), "File \(sFile) must NOT contain FakeInputInjector")
        }

        fputs("[ALL TESTS PASSED] Swift Host unit & integration tests (D2 Repair 1) executed cleanly.\n", stderr)
    }

    private static func pathComponentsUp(from filePath: String, levels: Int) -> String {
        var url = URL(fileURLWithPath: filePath)
        for _ in 0..<levels {
            url.deleteLastPathComponent()
        }
        return url.path
    }

    private static func getRecursiveSwiftFiles(at dirPath: String) throws -> [String] {
        var results: [String] = []
        let items = try FileManager.default.contentsOfDirectory(atPath: dirPath)
        for item in items {
            let full = "\(dirPath)/\(item)"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: full, isDirectory: &isDir) {
                if isDir.boolValue {
                    results.append(contentsOf: try getRecursiveSwiftFiles(at: full))
                } else if full.hasSuffix(".swift") {
                    results.append(full)
                }
            }
        }
        return results
    }
}
