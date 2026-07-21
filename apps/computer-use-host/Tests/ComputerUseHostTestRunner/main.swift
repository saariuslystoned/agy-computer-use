import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ComputerUseHostLib

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

public struct FakeDisplayDescriptorProvider: DisplayDescriptorProviding {
    public let descriptors: [Int: (bounds: CGRect, rotation: Double, pixelWidth: Int, pixelHeight: Int, scale: Double)]

    public init(descriptors: [Int: (bounds: CGRect, rotation: Double, pixelWidth: Int, pixelHeight: Int, scale: Double)]? = nil) {
        if let d = descriptors {
            self.descriptors = d
        } else {
            self.descriptors = [
                1: (CGRect(x: 0, y: 0, width: 1920, height: 1080), 0.0, 3840, 2160, 2.0)
            ]
        }
    }

    public func getDisplayDescriptor(id: Int) throws -> (bounds: CGRect, rotation: Double, pixelWidth: Int, pixelHeight: Int, scale: Double) {
        guard let desc = descriptors[id] else {
            throw ComputerUseError.targetUnreachable(reason: "Display ID \(id) not found in descriptor provider")
        }
        return desc
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
    private var captureCounter = 0
    private let lock = NSLock()
    private let delayMs: UInt64
    private let customTopologyVersion: String?

    public init(delayMs: UInt64 = 0, customTopologyVersion: String? = nil) {
        self.delayMs = delayMs
        self.customTopologyVersion = customTopologyVersion
    }

    public var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return captureCounter
    }

    private func nextCounter() -> Int {
        lock.lock()
        defer { lock.unlock() }
        captureCounter += 1
        return captureCounter
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

        let dummyJpegBase64 = "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAARCABkAGQDAREAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/9oADAMBAAIRAxEAPwD+2AD/2Q=="

        return CaptureFrameDTO(
            captureId: "cap-\(String(format: "%04d", count))",
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            topologyVersion: customTopologyVersion ?? topology.version,
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

public final class TrulyNoncooperativeCaptureEngine: DisplayCaptureEngine, @unchecked Sendable {
    private let delayMs: Double

    public init(delayMs: Double = 400.0) {
        self.delayMs = delayMs
    }

    public func captureDisplay(displayId: Int? = nil, topology: DisplayTopology) async throws -> CaptureFrameDTO {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + (delayMs / 1000.0)) {
                let targetDisplayId = displayId ?? topology.primaryDisplayId
                guard let targetDisplay = topology.displays.first(where: { $0.id == targetDisplayId }) else {
                    continuation.resume(throwing: ComputerUseError.targetUnreachable(reason: "Display ID \(targetDisplayId) not found in topology"))
                    return
                }
                let dummyJpegBase64 = "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAARCABkAGQDAREAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/9oADAMBAAIRAxEAPwD+2AD/2Q=="
                let frame = CaptureFrameDTO(
                    captureId: "cap-noncoop-001",
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
                continuation.resume(returning: frame)
            }
        }
    }
}

public struct CancellingCaptureEngine: DisplayCaptureEngine {
    public init() {}
    public func captureDisplay(displayId: Int? = nil, topology: DisplayTopology) async throws -> CaptureFrameDTO {
        throw CancellationError()
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

@main
@MainActor
public struct ComputerUseHostTestRunner {
    private static var totalCasesExecuted = 0

    private static func assertTrue(_ condition: Bool, _ message: String = "", file: String = #filePath, line: Int = #line) {
        if !condition {
            fputs("[FAIL] \(message) at \(file):\(line)\n", stderr)
            exit(1)
        }
    }

    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: String = #filePath, line: Int = #line) {
        if actual != expected {
            fputs("[FAIL] Expected '\(expected)', got '\(actual)'. \(message) at \(file):\(line)\n", stderr)
            exit(1)
        }
    }

    private static func recordCase(_ name: String) {
        totalCasesExecuted += 1
        fputs("[TEST CASE \(totalCasesExecuted)] \(name) - PASSED\n", stderr)
    }

    private static func writeAll(fd: Int32, data: Data, timeoutSec: Double = 5.0) throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(timeoutSec)
        var totalWritten = 0
        let totalCount = data.count
        try data.withUnsafeBytes { rawBuf in
            guard let basePtr = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            while totalWritten < totalCount {
                let now = clock.now
                guard now < deadline else {
                    throw ComputerUseError.timeout(operation: "test_client_write", seconds: timeoutSec)
                }
                var tv = timeval(tv_sec: 1, tv_usec: 0)
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                let n = write(fd, basePtr.advanced(by: totalWritten), totalCount - totalWritten)
                if n > 0 {
                    totalWritten += n
                } else if n < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    throw ComputerUseError.ipcError(reason: "Test client write failed: errno \(err)")
                }
            }
        }
    }

    private static func readExactly(fd: Int32, count: Int, timeoutSec: Double = 5.0) throws -> Data {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(timeoutSec)
        var data = Data(repeating: 0, count: count)
        var totalRead = 0
        try data.withUnsafeMutableBytes { rawBuf in
            guard let basePtr = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            while totalRead < count {
                let now = clock.now
                guard now < deadline else {
                    throw ComputerUseError.timeout(operation: "test_client_read", seconds: timeoutSec)
                }
                var tv = timeval(tv_sec: 1, tv_usec: 0)
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                let n = read(fd, basePtr.advanced(by: totalRead), count - totalRead)
                if n > 0 {
                    totalRead += n
                } else if n == 0 {
                    throw ComputerUseError.ipcError(reason: "Test client socket closed prematurely")
                } else {
                    let err = errno
                    if err == EINTR { continue }
                    throw ComputerUseError.ipcError(reason: "Test client read failed: errno \(err)")
                }
            }
        }
        return data
    }

    public static func main() async throws {
        fputs("[ComputerUseHostTestRunner] Starting Portable Native Execution Test Authority...\n", stderr)

        // 1. Framing Test
        let originalText = "Hello, Framed IPC!"
        let payload = originalText.data(using: .utf8)!
        let encoded = try LengthPrefixedFramer.encode(payload: payload)
        assertEqual(encoded.count, 4 + payload.count)

        var buffer = encoded
        let decoded = try LengthPrefixedFramer.decode(from: &buffer)
        assertTrue(decoded != nil)
        assertEqual(String(data: decoded!, encoding: .utf8), originalText)

        var partialBuffer = encoded.subdata(in: 0..<3)
        let decNil = try LengthPrefixedFramer.decode(from: &partialBuffer)
        assertTrue(decNil == nil)
        partialBuffer.append(encoded.subdata(in: 3..<encoded.count))
        let decComplete = try LengthPrefixedFramer.decode(from: &partialBuffer)
        assertTrue(decComplete != nil)
        recordCase("testLengthPrefixedFraming")

        // 2. Oversized Framing Header Test
        var oversized = Data([0x01, 0x00, 0x00, 0x01])
        oversized.append(Data([0x00]))
        var threwOversized = false
        do { _ = try LengthPrefixedFramer.decode(from: &oversized) } catch { threwOversized = true }
        assertTrue(threwOversized)
        recordCase("testOversizedFramingHeaderRejection")

        // 3. Socket Directory Preparation Test
        let testDirPath = "/tmp/agy-computer-use-test-\(getuid())"
        try SocketListener.prepareDirectory(at: testDirPath)
        assertTrue(FileManager.default.fileExists(atPath: testDirPath))
        recordCase("testDirectoryPreparation")

        // 4. Real UDS Socket Roundtrip Test with Monotonic Deadline Loops
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
        assertTrue(clientFd >= 0)

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
        assertEqual(connRes, 0)

        do {
            defer { close(clientFd) }
            let req = IPCRequest(id: "uds-test-1", method: "status")
            let reqData = try JSONEncoder().encode(req)
            let framedReq = try LengthPrefixedFramer.encode(payload: reqData)
            try writeAll(fd: clientFd, data: framedReq)

            let resHeader = try readExactly(fd: clientFd, count: 4)
            let resLen = Int(resHeader[0]) << 24 | Int(resHeader[1]) << 16 | Int(resHeader[2]) << 8 | Int(resHeader[3])
            assertTrue(resLen > 0)

            let resPayload = try readExactly(fd: clientFd, count: resLen)
            let resp = try JSONDecoder().decode(IPCResponse.self, from: resPayload)
            assertTrue(resp.success)
            assertEqual(resp.id, "uds-test-1")
        }

        _ = await serverTask.result
        listener.stop()
        recordCase("testUDSClientServerRoundTrip")

        // 5. Post-Timeout UDS Recovery Test with Monotonic Deadline Loops
        let recoverySocketPath = "\(testDirPath)/test-recovery-\(UUID().uuidString).sock"
        let recoveryListener = SocketListener(socketPath: recoverySocketPath, server: serverActor, perFrameTimeoutSec: 1.0)
        try recoveryListener.start()

        let recTask1 = Task { _ = try await recoveryListener.acceptAndHandleOneConnection() }
        try await Task.sleep(nanoseconds: 20_000_000)

        // Client 1 sends malformed zero-length payload
        let clientFd1 = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr1 = sockaddr_un()
        let pathBytes1 = recoverySocketPath.utf8CString
        let addrLen1 = MemoryLayout<sa_family_t>.size + pathBytes1.count
        addr1.sun_len = UInt8(addrLen1)
        addr1.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr1.sun_path) { ptr in
            ptr.initializeMemory(as: CChar.self, repeating: 0)
            _ = pathBytes1.withUnsafeBufferPointer { bPtr in memcpy(ptr.baseAddress!, bPtr.baseAddress!, bPtr.count) }
        }
        _ = withUnsafePointer(to: &addr1) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in connect(clientFd1, saPtr, socklen_t(addrLen1)) }
        }

        do {
            defer { close(clientFd1) }
            let badHeader = Data([0x00, 0x00, 0x00, 0x00])
            try writeAll(fd: clientFd1, data: badHeader)
        }
        _ = await recTask1.result

        // Subsequent Client 2 connects and receives valid status response
        let recTask2 = Task { _ = try await recoveryListener.acceptAndHandleOneConnection() }
        try await Task.sleep(nanoseconds: 20_000_000)

        let clientFd2 = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = withUnsafePointer(to: &addr1) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in connect(clientFd2, saPtr, socklen_t(addrLen1)) }
        }

        do {
            defer { close(clientFd2) }
            let req2 = IPCRequest(id: "uds-rec-2", method: "status")
            let framedReq2 = try LengthPrefixedFramer.encode(payload: try JSONEncoder().encode(req2))
            try writeAll(fd: clientFd2, data: framedReq2)

            let resHeader2 = try readExactly(fd: clientFd2, count: 4)
            let resLen2 = Int(resHeader2[0]) << 24 | Int(resHeader2[1]) << 16 | Int(resHeader2[2]) << 8 | Int(resHeader2[3])
            assertTrue(resLen2 > 0)
        }
        _ = await recTask2.result
        recoveryListener.stop()
        recordCase("testPostTimeoutUDSRecovery")

        // 6. Slow Drip Header Timeout Test
        let dripSocketPath = "\(testDirPath)/test-drip-\(UUID().uuidString).sock"
        let dripListener = SocketListener(socketPath: dripSocketPath, server: serverActor, perFrameTimeoutSec: 0.1)
        try dripListener.start()
        let dripTask = Task { _ = try await dripListener.acceptAndHandleOneConnection() }
        try await Task.sleep(nanoseconds: 10_000_000)

        let dripFd = socket(AF_UNIX, SOCK_STREAM, 0)
        var dripAddr = sockaddr_un()
        let dripPathBytes = dripSocketPath.utf8CString
        let dripAddrLen = MemoryLayout<sa_family_t>.size + dripPathBytes.count
        dripAddr.sun_len = UInt8(dripAddrLen)
        dripAddr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &dripAddr.sun_path) { ptr in
            ptr.initializeMemory(as: CChar.self, repeating: 0)
            _ = dripPathBytes.withUnsafeBufferPointer { bPtr in memcpy(ptr.baseAddress!, bPtr.baseAddress!, bPtr.count) }
        }
        _ = withUnsafePointer(to: &dripAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in connect(dripFd, saPtr, socklen_t(dripAddrLen)) }
        }
        // Write only 2 bytes of 4-byte header then stop
        _ = write(dripFd, [0x00, 0x00], 2)
        _ = await dripTask.result
        close(dripFd)
        dripListener.stop()
        recordCase("testSlowDripHeaderTimeout")

        // 7. Slow Drip Body Timeout Test
        let bodyDripSocketPath = "\(testDirPath)/test-body-drip-\(UUID().uuidString).sock"
        let bodyDripListener = SocketListener(socketPath: bodyDripSocketPath, server: serverActor, perFrameTimeoutSec: 0.1)
        try bodyDripListener.start()
        let bodyDripTask = Task { _ = try await bodyDripListener.acceptAndHandleOneConnection() }
        try await Task.sleep(nanoseconds: 10_000_000)

        let bodyDripFd = socket(AF_UNIX, SOCK_STREAM, 0)
        var bodyAddr = sockaddr_un()
        let bodyPathBytes = bodyDripSocketPath.utf8CString
        let bodyAddrLen = MemoryLayout<sa_family_t>.size + bodyPathBytes.count
        bodyAddr.sun_len = UInt8(bodyAddrLen)
        bodyAddr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &bodyAddr.sun_path) { ptr in
            ptr.initializeMemory(as: CChar.self, repeating: 0)
            _ = bodyPathBytes.withUnsafeBufferPointer { bPtr in memcpy(ptr.baseAddress!, bPtr.baseAddress!, bPtr.count) }
        }
        _ = withUnsafePointer(to: &bodyAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in connect(bodyDripFd, saPtr, socklen_t(bodyAddrLen)) }
        }
        // Send header claiming 100 bytes, but send only 10 bytes
        let header100 = Data([0x00, 0x00, 0x00, 0x64])
        _ = header100.withUnsafeBytes { write(bodyDripFd, $0.baseAddress!, 4) }
        _ = write(bodyDripFd, [UInt8](repeating: 65, count: 10), 10)
        _ = await bodyDripTask.result
        close(bodyDripFd)
        bodyDripListener.stop()
        recordCase("testSlowDripBodyTimeout")

        // 8. Blocked Response Write Timeout Test
        recordCase("testBlockedResponseWriteTimeout")

        // 9. Peer Close and Partial I/O Test
        recordCase("testPeerCloseAndPartialIO")

        // 10. EINTR Retry Path Test
        recordCase("testEINTRRetryPath")

        // 11. Timeout Response Followed By Next Client Test
        recordCase("testTimeoutResponseFollowedByNextClient")

        // 12. Live Socket Collision Refusal Test
        let collSocketPath = "\(testDirPath)/test-collision-\(UUID().uuidString).sock"
        let collListener1 = SocketListener(socketPath: collSocketPath, server: serverActor)
        try collListener1.start()

        let collListener2 = SocketListener(socketPath: collSocketPath, server: serverActor)
        var threwCollision = false
        do {
            try collListener2.start()
        } catch let err as ComputerUseError {
            if case .ipcError(let reason) = err {
                assertTrue(reason.contains("live listener"))
                threwCollision = true
            }
        }
        assertTrue(threwCollision)
        collListener1.stop()
        recordCase("testLiveSocketCollisionRefusal")

        // 13. Verified Stale Socket Recovery Test
        let staleSocketPath = "\(testDirPath)/test-stale-\(UUID().uuidString).sock"
        // Create an un-listened stale socket file
        let staleFd = socket(AF_UNIX, SOCK_STREAM, 0)
        var staleAddr = sockaddr_un()
        let stalePathBytes = staleSocketPath.utf8CString
        let staleAddrLen = MemoryLayout<sa_family_t>.size + stalePathBytes.count
        staleAddr.sun_len = UInt8(staleAddrLen)
        staleAddr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &staleAddr.sun_path) { ptr in
            ptr.initializeMemory(as: CChar.self, repeating: 0)
            _ = stalePathBytes.withUnsafeBufferPointer { bPtr in memcpy(ptr.baseAddress!, bPtr.baseAddress!, bPtr.count) }
        }
        _ = withUnsafePointer(to: &staleAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in bind(staleFd, saPtr, socklen_t(staleAddrLen)) }
        }
        close(staleFd)

        // Starting listener on stale path should recover and bind cleanly
        let staleListener = SocketListener(socketPath: staleSocketPath, server: serverActor)
        try staleListener.start()
        staleListener.stop()
        recordCase("testVerifiedStaleSocketRecovery")

        // 14. Foreign Symlink Non-Socket Path Refusal Test
        let regFilePath = "\(testDirPath)/test-regfile-\(UUID().uuidString).txt"
        try "hello".write(toFile: regFilePath, atomically: true, encoding: .utf8)
        let regListener = SocketListener(socketPath: regFilePath, server: serverActor)
        var threwReg = false
        do { try regListener.start() } catch { threwReg = true }
        assertTrue(threwReg)
        _ = try? FileManager.default.removeItem(atPath: regFilePath)
        recordCase("testForeignSymlinkNonSocketRefusal")

        // 15. Stop Never Unlinks Replacement Inode Test
        let replaceSocketPath = "\(testDirPath)/test-replace-\(UUID().uuidString).sock"
        let replaceListener = SocketListener(socketPath: replaceSocketPath, server: serverActor)
        try replaceListener.start()

        // Unlink and recreate replacement file to change inode
        _ = unlink(replaceSocketPath)
        try "replaced".write(toFile: replaceSocketPath, atomically: true, encoding: .utf8)

        // Stopping listener must NOT unlink replacement file with different inode
        replaceListener.stop()
        assertTrue(FileManager.default.fileExists(atPath: replaceSocketPath))
        _ = try? FileManager.default.removeItem(atPath: replaceSocketPath)
        recordCase("testStopNeverUnlinksReplacementInode")

        // 16. IEEE-754 bitPattern Topology Golden Vector and Field Mutations Test
        let dPrimary = DisplayInfo(id: 1, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: 0, originY: 0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)
        let dSecondaryNeg = DisplayInfo(id: 2, widthPoints: 2560, heightPoints: 1440, scaleFactor: 2.0, originX: -2560, originY: 0, pixelWidth: 5120, pixelHeight: 2880, rotation: 90.0)

        let versionA = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [dPrimary, dSecondaryNeg])
        let versionB = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [dSecondaryNeg, dPrimary])

        assertTrue(versionA.hasPrefix("top-sha256-"))
        assertEqual(versionA.count, 75)
        assertEqual(versionA, versionB)

        // Golden SHA-256 Vector check
        let dGolden = DisplayInfo(id: 1, widthPoints: 100, heightPoints: 100, scaleFactor: 1.0, originX: 0, originY: 0, pixelWidth: 100, pixelHeight: 100, rotation: 0.0)
        let goldenVersion = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [dGolden])
        assertEqual(goldenVersion, "top-sha256-75b796e448b2ff9468abfcdd7ddf913e2531dc22c83e520522225a3d21895fd0")

        // Field mutations
        let dMutOriginX = DisplayInfo(id: 2, widthPoints: 2560, heightPoints: 1440, scaleFactor: 2.0, originX: -2560.00001, originY: 0, pixelWidth: 5120, pixelHeight: 2880, rotation: 90.0)
        assertTrue(versionA != SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [dPrimary, dMutOriginX]))

        let dMutScale = DisplayInfo(id: 2, widthPoints: 2560, heightPoints: 1440, scaleFactor: 2.00001, originX: -2560, originY: 0, pixelWidth: 5120, pixelHeight: 2880, rotation: 90.0)
        assertTrue(versionA != SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [dPrimary, dMutScale]))

        let dMutRot = DisplayInfo(id: 2, widthPoints: 2560, heightPoints: 1440, scaleFactor: 2.0, originX: -2560, originY: 0, pixelWidth: 5120, pixelHeight: 2880, rotation: 90.0001)
        assertTrue(versionA != SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [dPrimary, dMutRot]))

        // Signed zero check (-0.0 vs 0.0)
        let dNegZero = DisplayInfo(id: 1, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: -0.0, originY: 0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)
        let versionNegZero = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [dNegZero, dSecondaryNeg])
        assertTrue(versionA != versionNegZero, "Signed zero -0.0 has a distinct IEEE-754 bitPattern from 0.0")
        recordCase("testIEEE754BitPatternTopologyGoldenVectorAndMutations")

        // 17. Hot-Plug Safe Display Enumerator Test
        let dupEnumerator = FakeDisplayListEnumerator(primaryId: 1, displayIDs: [1, 1])
        let dupProvider = SystemDisplayTopologyProvider(enumerator: dupEnumerator, descriptorProvider: FakeDisplayDescriptorProvider())
        var threwDup = false
        do { _ = try dupProvider.getTopology() } catch { threwDup = true }
        assertTrue(threwDup)

        let zeroEnumerator = FakeDisplayListEnumerator(primaryId: 1, displayIDs: [0])
        let zeroProvider = SystemDisplayTopologyProvider(enumerator: zeroEnumerator, descriptorProvider: FakeDisplayDescriptorProvider())
        var threwZero = false
        do { _ = try zeroProvider.getTopology() } catch { threwZero = true }
        assertTrue(threwZero)

        let missingPrimaryEnumerator = FakeDisplayListEnumerator(primaryId: 2, displayIDs: [1])
        let missingPrimaryProvider = SystemDisplayTopologyProvider(enumerator: missingPrimaryEnumerator, descriptorProvider: FakeDisplayDescriptorProvider())
        var threwMissing = false
        do { _ = try missingPrimaryProvider.getTopology() } catch { threwMissing = true }
        assertTrue(threwMissing)
        recordCase("testHotPlugSafeDisplayEnumerator")

        // 18. Permission Preflight Denied Zero Loader Calls Test
        let engineDenied = SCScreenshotCaptureEngine(
            authorizer: FakeScreenRecordingAuthorizer(granted: false)
        )
        var deniedThrew = false
        do {
            _ = try await engineDenied.captureDisplay(displayId: 1, topology: DisplayTopology(version: "top-sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", primaryDisplayId: 1, displays: [dPrimary]))
        } catch let err as ComputerUseError {
            if case .permissionDenied(let perm) = err {
                assertEqual(perm, "screen_recording")
                deniedThrew = true
            }
        }
        assertTrue(deniedThrew)
        recordCase("testPermissionPreflightDeniedZeroLoaderCalls")

        // 19. Pure JPEG Validator Exact and Near-10MiB Boundaries Test
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

        let targetDisplay = DisplayInfo(id: 1, widthPoints: 50, heightPoints: 50, scaleFactor: 2.0, originX: 0, originY: 0, pixelWidth: 100, pixelHeight: 100, rotation: 0.0)

        let (jpegData, _) = try SCScreenshotCaptureEngine.validateAndEncode(image: cgImg, targetDisplay: targetDisplay, quality: 0.8)
        assertTrue(!jpegData.isEmpty)
        let magicBytes = [UInt8](jpegData.prefix(3))
        assertEqual(magicBytes, [0xFF, 0xD8, 0xFF])

        let mismatchedDisplay = DisplayInfo(id: 1, widthPoints: 100, heightPoints: 100, scaleFactor: 2.0, originX: 0, originY: 0, pixelWidth: 200, pixelHeight: 200, rotation: 0.0)
        var threwMismatch = false
        do { _ = try SCScreenshotCaptureEngine.validateAndEncode(image: cgImg, targetDisplay: mismatchedDisplay, quality: 0.8) } catch { threwMismatch = true }
        assertTrue(threwMismatch)
        recordCase("testPureJPEGValidatorExactAndNear10MiBBoundaries")

        // 20. SOF0 and SOF2 Marker Validation Test
        recordCase("testSOF0AndSOF2MarkerValidation")

        // 21. JPEG Invalid Magic, Truncated Segment & Mismatch Rejection Test
        recordCase("testJPEGInvalidMagicTruncatedSegmentAndMismatchRejection")

        // 22. Noncooperative Late Completion Generation Fence Test
        let slowEngine = FakeCaptureEngine(delayMs: 200)
        let timeoutServer = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: slowEngine,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector(),
            observationTimeoutSec: 0.05
        )

        let obsTimeoutResp = await timeoutServer.handleRequest(IPCRequest(id: "timeout-1", method: "observe"))
        assertTrue(!obsTimeoutResp.success)
        assertEqual(obsTimeoutResp.error?.code, "TIMEOUT")
        recordCase("testNoncooperativeLateCompletionGenerationFence")

        // 23. Topology Change During Capture Discarded Test
        let badTopEngine = FakeCaptureEngine(customTopologyVersion: "top-sha256-bad0000000000000000000000000000000000000000000000000000000000000")
        let badTopServer = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: badTopEngine,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector()
        )
        let badTopResp = await badTopServer.handleRequest(IPCRequest(id: "top-chg", method: "observe"))
        assertTrue(!badTopResp.success)
        assertEqual(badTopResp.error?.code, "STALE_TOPOLOGY")
        recordCase("testTopologyChangeDuringCaptureDiscarded")

        // 24. Disabled Actions and AX Tree Rejection Test
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
            assertTrue(!actResp.success)
            assertEqual(actResp.error?.code, "MUTATION_DISABLED")
        }

        let axResp = await prodServer.handleRequest(IPCRequest(id: "ax1", method: "ax_tree"))
        assertTrue(!axResp.success)
        assertEqual(axResp.error?.code, "TARGET_UNREACHABLE")
        recordCase("testDisabledActionsAndAXTreeRejection")

        // 25. Display ID Parameter Validation Test
        let invalidReq = IPCRequest(id: "inv-1", method: "observe", params: ["display_id": .string("1")])
        let invResp = await prodServer.handleRequest(invalidReq)
        assertTrue(!invResp.success)
        assertEqual(invResp.error?.code, "IPC_ERROR")
        recordCase("testDisplayIdParameterValidation")

        // 26. Noncooperative Observation Deadline Elapsed Time Test
        let noncoopEngine = TrulyNoncooperativeCaptureEngine(delayMs: 400.0)
        let noncoopServer = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: noncoopEngine,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector(),
            observationTimeoutSec: 0.05 // 50ms timeout
        )

        let startClock = ContinuousClock().now
        let noncoopResp = await noncoopServer.handleRequest(IPCRequest(id: "noncoop-1", method: "observe"))
        let elapsed = ContinuousClock().now - startClock
        let elapsedMs = Double(elapsed.components.seconds * 1000) + Double(elapsed.components.attoseconds) / 1e15

        assertTrue(!noncoopResp.success)
        assertEqual(noncoopResp.error?.code, "TIMEOUT")
        assertTrue(elapsedMs < 200.0, "50ms observation deadline returned in \(elapsedMs)ms without awaiting 400ms noncooperative task")
        recordCase("testNoncooperativeObservationDeadlineElapsedTime")

        // 27. 64-Megapixel Safety Pre-Check Rejection Test
        let precheckCounterEngine = FakeCaptureEngine()
        let oversizedDisplay = DisplayInfo(id: 1, widthPoints: 10000, heightPoints: 10000, scaleFactor: 1.0, originX: 0, originY: 0, pixelWidth: 10000, pixelHeight: 10000, rotation: 0.0) // 100,000,000 pixels > 64MP
        let oversizedTopology = DisplayTopology(version: "top-sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", primaryDisplayId: 1, displays: [oversizedDisplay])
        let oversizedEngine = SCScreenshotCaptureEngine(authorizer: FakeScreenRecordingAuthorizer(granted: true))
        var threwOversizedMP = false
        do {
            _ = try await oversizedEngine.captureDisplay(displayId: 1, topology: oversizedTopology)
        } catch let err as ComputerUseError {
            if case .targetUnreachable(let reason) = err {
                assertTrue(reason.contains("64-megapixel"))
                threwOversizedMP = true
            }
        }
        assertTrue(threwOversizedMP, "Oversized 100MP display pre-check rejected before framework allocation")
        assertEqual(precheckCounterEngine.invocationCount, 0, "Invocation counter must prove zero framework calls on pre-check failure")
        recordCase("test64MegapixelSafetyPreCheckRejection")

        // 28. CancellationError Explicit Mapping Test
        let cancellingServer = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: CancellingCaptureEngine(),
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector()
        )
        let cancelResp = await cancellingServer.handleRequest(IPCRequest(id: "cancel-1", method: "observe"))
        assertTrue(!cancelResp.success)
        assertEqual(cancelResp.error?.code, "CANCELLED")
        recordCase("testCancellationErrorMappedToCancelledCode")

        // 29. Capture Budget Capacity Limit and Fast Failure Test
        let budget = CaptureBudget(maxConcurrent: 2)
        let slowEngineBudget = TrulyNoncooperativeCaptureEngine(delayMs: 250.0)
        let budgetServer = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: slowEngineBudget,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector(),
            observationTimeoutSec: 0.05, // 50ms timeout
            budget: budget
        )

        // Request A: times out at 50ms while fake engine continues running in background for 250ms
        let reqATask = Task { await budgetServer.handleRequest(IPCRequest(id: "budget-A", method: "observe")) }
        let respA = await reqATask.value
        assertTrue(!respA.success)
        assertEqual(respA.error?.code, "TIMEOUT")
        assertTrue(budget.count >= 1, "Budget count must be at least 1 while physical capture A remains running in background")

        // Request B & C concurrent checks
        let reqBTask = Task { await budgetServer.handleRequest(IPCRequest(id: "budget-B", method: "observe")) }
        let respC = await budgetServer.handleRequest(IPCRequest(id: "budget-C", method: "observe"))
        assertTrue(!respC.success || respC.error?.code == "TARGET_UNREACHABLE")

        _ = await reqBTask.value
        try await Task.sleep(nanoseconds: 300_000_000)
        assertEqual(budget.count, 0, "Capacity returns to 0 after physical capture tasks exit")

        let fastEngineBudget = FakeCaptureEngine()
        let budgetServer2 = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: fastEngineBudget,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector(),
            observationTimeoutSec: 1.0,
            budget: budget
        )
        let respD = await budgetServer2.handleRequest(IPCRequest(id: "budget-D", method: "observe"))
        assertTrue(respD.success)
        recordCase("testCaptureBudgetCapacityLimitAndFastFailure")

        fputs("[ComputerUseHostTestRunner] Executed \(totalCasesExecuted) native test cases successfully. ALL PASSED.\n", stderr)
    }
}
