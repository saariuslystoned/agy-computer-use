import Foundation
import CoreGraphics
import ComputerUseHostLib

private final class AtomicCounter: @unchecked Sendable {
    private var val: Int = 0
    private let lock = NSLock()
    func increment() { lock.lock(); val += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return val }
}

private let totalCasesCounter = AtomicCounter()
private func recordCase(_ name: String) {
    totalCasesCounter.increment()
    fputs("[TEST CASE \(totalCasesCounter.value)] \(name) - PASSED\n", stderr)
}

public final class FakeScreenRecordingAuthorizer: ScreenRecordingAuthorizing, @unchecked Sendable {
    public let granted: Bool
    public init(granted: Bool = true) { self.granted = granted }
    public var isScreenCaptureAccessGranted: Bool { return granted }
}

public final class FakeDisplayTopologyProvider: DisplayTopologyProviding, @unchecked Sendable {
    private let topology: DisplayTopology
    public init(topology: DisplayTopology? = nil) {
        let primary = DisplayInfo(id: 1, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: 0, originY: 0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)
        let token = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [primary])
        self.topology = topology ?? DisplayTopology(version: token, primaryDisplayId: 1, displays: [primary])
    }
    public func getTopology() throws -> DisplayTopology { return topology }
}

public final class ScriptedDisplayListEnumerator: DisplayListEnumerating, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [() throws -> (primaryId: Int, displayIDs: [Int])]

    public init(script: [() throws -> (primaryId: Int, displayIDs: [Int])]) {
        self.script = script
    }

    public func getActiveDisplays() throws -> (primaryId: Int, displayIDs: [Int]) {
        lock.lock()
        defer { lock.unlock() }
        guard !script.isEmpty else {
            throw ComputerUseError.targetUnreachable(reason: "Exhausted scripted display list passes")
        }
        return try script.removeFirst()()
    }
}

public final class FakeDescriptorProvider: DisplayDescriptorProviding, @unchecked Sendable {
    public init() {}
    public func getDisplayDescriptor(id: Int) throws -> (bounds: CGRect, rotation: Double, pixelWidth: Int, pixelHeight: Int, scale: Double) {
        return (CGRect(x: 0, y: 0, width: 1920, height: 1080), 0.0, 3840, 2160, 2.0)
    }
}

public final class ScriptedContinuationCaptureEngine: DisplayCaptureEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<CaptureFrameDTO, Error>] = [:]
    private var nextIndex: Int = 0
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    public var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextIndex
    }

    public func captureDisplay(displayId: Int?, topology: DisplayTopology) async throws -> CaptureFrameDTO {
        let index: Int = {
            lock.lock()
            defer { lock.unlock() }
            let idx = nextIndex
            nextIndex += 1
            return idx
        }()

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            continuations[index] = continuation
            let pendingWaiters = waiters.removeValue(forKey: index) ?? []
            lock.unlock()
            for waiter in pendingWaiters {
                waiter.resume()
            }
        }
    }

    public func waitForContinuation(at index: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if continuations[index] != nil {
                lock.unlock()
                continuation.resume()
            } else {
                waiters[index, default: []].append(continuation)
                lock.unlock()
            }
        }
    }

    public func resumeContinuation(at index: Int, with result: Result<CaptureFrameDTO, Error>) {
        lock.lock()
        let cont = continuations.removeValue(forKey: index)
        lock.unlock()
        cont?.resume(with: result)
    }
}

public final class FakeCaptureEngine: DisplayCaptureEngine, @unchecked Sendable {
    private let counter = AtomicCounter()
    private let delayMs: Double
    private let customTopologyVersion: String?

    public init(delayMs: Double = 0.0, customTopologyVersion: String? = nil) {
        self.delayMs = delayMs
        self.customTopologyVersion = customTopologyVersion
    }

    public var invocationCount: Int { counter.value }

    public func captureDisplay(displayId: Int?, topology: DisplayTopology) async throws -> CaptureFrameDTO {
        counter.increment()
        if delayMs > 0 {
            try await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
        }
        return try generateDTO(topology: topology)
    }

    public func generateDTO(topology: DisplayTopology) throws -> CaptureFrameDTO {
        let display = topology.displays.first!
        let width = display.pixelWidth
        let height = display.pixelHeight

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ComputerUseError.ipcError(reason: "Failed to create fake test CGContext")
        }

        ctx.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImg = ctx.makeImage() else {
            throw ComputerUseError.ipcError(reason: "Failed to create fake CGImage")
        }

        let targetDisp = DisplayInfo(
            id: display.id,
            widthPoints: display.widthPoints,
            heightPoints: display.heightPoints,
            scaleFactor: display.scaleFactor,
            originX: display.originX,
            originY: display.originY,
            pixelWidth: width,
            pixelHeight: height,
            rotation: display.rotation
        )

        let (_, b64) = try SCScreenshotCaptureEngine.validateAndEncode(image: cgImg, targetDisplay: targetDisp, quality: 0.8)
        let versionToUse = customTopologyVersion ?? topology.version

        return CaptureFrameDTO(
            captureId: "cap-test-\(UUID().uuidString)",
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            topologyVersion: versionToUse,
            displayId: display.id,
            widthPoints: display.widthPoints,
            heightPoints: display.heightPoints,
            scaleFactor: display.scaleFactor,
            pixelWidth: width,
            pixelHeight: height,
            imageFormat: "jpeg",
            imageDataBase64: b64
        )
    }
}

public final class TrulyNoncooperativeCaptureEngine: DisplayCaptureEngine, @unchecked Sendable {
    private let delayMs: Double

    public init(delayMs: Double = 400.0) {
        self.delayMs = delayMs
    }

    public func captureDisplay(displayId: Int?, topology: DisplayTopology) async throws -> CaptureFrameDTO {
        let deadline = ContinuousClock().now + .milliseconds(delayMs)
        while ContinuousClock().now < deadline {
            let spinEnd = ContinuousClock().now + .milliseconds(1)
            while ContinuousClock().now < spinEnd {}
        }
        return try FakeCaptureEngine().generateDTO(topology: topology)
    }
}

public final class CancellingCaptureEngine: DisplayCaptureEngine, @unchecked Sendable {
    public init() {}
    public func captureDisplay(displayId: Int?, topology: DisplayTopology) async throws -> CaptureFrameDTO {
        throw CancellationError()
    }
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ msg: String = "", file: String = #file, line: Int = #line) {
    if actual != expected {
        fputs("[FAIL] Expected '\(expected)', got '\(actual)'. \(msg) at \(file):\(line)\n", stderr)
        exit(1)
    }
}

private func assertTrue(_ condition: Bool, _ msg: String = "", file: String = #file, line: Int = #line) {
    if !condition {
        fputs("[FAIL] Assertion failed. \(msg) at \(file):\(line)\n", stderr)
        exit(1)
    }
}

private func connectToSocket(at socketPath: String) throws -> Int32 {
    let clientFd = socket(AF_UNIX, SOCK_STREAM, 0)
    assertTrue(clientFd >= 0, "Failed to create UNIX domain socket descriptor")

    var addr = sockaddr_un()
    let pathBytes = socketPath.utf8CString
    addr.sun_len = UInt8(MemoryLayout<sa_family_t>.size + pathBytes.count)
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
        ptr.initializeMemory(as: CChar.self, repeating: 0)
        _ = pathBytes.withUnsafeBufferPointer { bPtr in memcpy(ptr.baseAddress!, bPtr.baseAddress!, bPtr.count) }
    }

    let sockLen = socklen_t(addr.sun_len)
    let connRes = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
            connect(clientFd, saPtr, sockLen)
        }
    }
    assertEqual(connRes, 0, "Failed to connect to UDS socket at \(socketPath)")
    return clientFd
}

private func sendIPCRequest(_ req: IPCRequest, to clientFd: Int32) throws {
    let reqData = try JSONEncoder().encode(req)
    let framedReq = try LengthPrefixedFramer.encode(payload: reqData)
    _ = framedReq.withUnsafeBytes { ptr in
        write(clientFd, ptr.baseAddress!, framedReq.count)
    }
}

private func readIPCResponse(from clientFd: Int32) throws -> IPCResponse {
    var headerBuf = [UInt8](repeating: 0, count: 4)
    var hRead = 0
    while hRead < 4 {
        let r = read(clientFd, &headerBuf[hRead], 4 - hRead)
        if r > 0 {
            hRead += r
        } else if r == 0 {
            throw ComputerUseError.ipcError(reason: "EOF while reading response header")
        } else {
            if errno == EINTR { continue }
            throw ComputerUseError.ipcError(reason: "Socket read error errno \(errno)")
        }
    }

    let respLen = Int(headerBuf[0]) << 24 | Int(headerBuf[1]) << 16 | Int(headerBuf[2]) << 8 | Int(headerBuf[3])
    assertTrue(respLen > 0, "Invalid response payload length")

    var respBuf = [UInt8](repeating: 0, count: respLen)
    var totalRead = 0
    while totalRead < respLen {
        let r = read(clientFd, &respBuf[totalRead], respLen - totalRead)
        if r > 0 {
            totalRead += r
        } else if r == 0 {
            throw ComputerUseError.ipcError(reason: "EOF while reading response body")
        } else {
            if errno == EINTR { continue }
            throw ComputerUseError.ipcError(reason: "Socket read error errno \(errno)")
        }
    }

    return try JSONDecoder().decode(IPCResponse.self, from: Data(respBuf))
}

private func makeSyntheticJPEG(marker: UInt8, width: UInt16, height: UInt16, padToSize: Int = 0) -> Data {
    var data = Data()
    data.append(contentsOf: [0xFF, 0xD8])
    data.append(contentsOf: [0xFF, marker])
    data.append(contentsOf: [0x00, 0x0B])
    data.append(0x08)
    data.append(UInt8(height >> 8))
    data.append(UInt8(height & 0xFF))
    data.append(UInt8(width >> 8))
    data.append(UInt8(width & 0xFF))
    data.append(0x01)
    data.append(contentsOf: [0x01, 0x11, 0x00])

    data.append(contentsOf: [0xFF, 0xDA])
    data.append(contentsOf: [0x00, 0x08])
    data.append(0x01)
    data.append(contentsOf: [0x01, 0x00])
    data.append(contentsOf: [0x00, 0x3F, 0x00])

    if padToSize > data.count + 2 {
        let needed = padToSize - data.count - 2
        data.append(Data(repeating: 0x00, count: needed))
    } else {
        data.append(0x00)
    }

    data.append(contentsOf: [0xFF, 0xD9])
    return data
}

@main
struct ComputerUseHostTestRunner {
    static func main() async throws {
        fputs("[ComputerUseHostTestRunner] Starting Portable Native Execution Test Authority...\n", stderr)

        // 1. Length-Prefixed Framing Test
        let payload = Data("{\"id\":\"test-1\",\"method\":\"status\"}".utf8)
        let framed = try LengthPrefixedFramer.encode(payload: payload)
        assertEqual(framed.count, 4 + payload.count)
        var mutFramed = framed
        let decoded = try LengthPrefixedFramer.decode(from: &mutFramed)
        assertEqual(decoded, payload)
        recordCase("testLengthPrefixedFraming")

        // 2. Oversized Framing Header Rejection Test
        var badHeader = Data([0x01, 0x00, 0x00, 0x01]) // 16MB + 1
        badHeader.append(Data(repeating: 0, count: 10))
        var threwOversized = false
        do { _ = try LengthPrefixedFramer.decode(from: &badHeader) } catch { threwOversized = true }
        assertTrue(threwOversized)
        recordCase("testOversizedFramingHeaderRejection")

        // 3. Directory Preparation Test
        let testDir = "/tmp/agy-computer-use-test-\(UUID().uuidString)"
        try SocketListener.prepareDirectory(at: testDir)
        var statBuf = stat()
        assertEqual(lstat(testDir, &statBuf), 0)
        assertEqual(statBuf.st_mode & 0o777, 0o700)
        _ = rmdir(testDir)
        recordCase("testDirectoryPreparation")

        // 4. UDS Client Server Round Trip Test
        let sockPath = "/tmp/agy-test-c4-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath)
        let fakeEngine = FakeCaptureEngine()
        let server = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: fakeEngine,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector()
        )
        let listener = SocketListener(socketPath: sockPath, server: server)
        try listener.start()

        let acceptTask = Task { try await listener.acceptAndHandleOneConnection() }

        let clientFd = socket(AF_UNIX, SOCK_STREAM, 0)
        assertTrue(clientFd >= 0)

        var addr = sockaddr_un()
        let pathBytes = listener.socketPath.utf8CString
        addr.sun_len = UInt8(MemoryLayout<sa_family_t>.size + pathBytes.count)
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            ptr.initializeMemory(as: CChar.self, repeating: 0)
            _ = pathBytes.withUnsafeBufferPointer { bPtr in memcpy(ptr.baseAddress!, bPtr.baseAddress!, bPtr.count) }
        }

        let sockLen = socklen_t(addr.sun_len)
        let connRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                connect(clientFd, saPtr, sockLen)
            }
        }
        assertEqual(connRes, 0)

        let reqObj = IPCRequest(id: "client-req-1", method: "status")
        let reqData = try JSONEncoder().encode(reqObj)
        let framedReq = try LengthPrefixedFramer.encode(payload: reqData)

        _ = framedReq.withUnsafeBytes { ptr in write(clientFd, ptr.baseAddress!, framedReq.count) }

        _ = try await acceptTask.value

        var headerBuf = [UInt8](repeating: 0, count: 4)
        _ = read(clientFd, &headerBuf, 4)
        let respLen = Int(headerBuf[0]) << 24 | Int(headerBuf[1]) << 16 | Int(headerBuf[2]) << 8 | Int(headerBuf[3])

        var respBuf = [UInt8](repeating: 0, count: respLen)
        _ = read(clientFd, &respBuf, respLen)

        let respObj = try JSONDecoder().decode(IPCResponse.self, from: Data(respBuf))
        assertEqual(respObj.id, "client-req-1")
        assertTrue(respObj.success)

        close(clientFd)
        listener.stop()
        recordCase("testUDSClientServerRoundTrip")

        // 5. Post Timeout UDS Recovery Test
        let sockPath5 = "/tmp/agy-test-c5-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath5)
        let timeoutEngine5 = TrulyNoncooperativeCaptureEngine(delayMs: 300.0)
        let server5 = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: timeoutEngine5,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector(),
            observationTimeoutSec: 0.05 // 50ms timeout
        )
        let listener5 = SocketListener(socketPath: sockPath5, server: server5)
        try listener5.start()

        let acceptTask5a = Task { try await listener5.acceptAndHandleOneConnection() }
        let clientFd5a = try connectToSocket(at: listener5.socketPath)
        try sendIPCRequest(IPCRequest(id: "timeout-req-1", method: "observe"), to: clientFd5a)

        _ = try await acceptTask5a.value
        let resp5a = try readIPCResponse(from: clientFd5a)
        assertEqual(resp5a.id, "timeout-req-1")
        assertTrue(!resp5a.success)
        assertEqual(resp5a.error?.code, "TIMEOUT")
        close(clientFd5a)

        let acceptTask5b = Task { try await listener5.acceptAndHandleOneConnection() }
        let clientFd5b = try connectToSocket(at: listener5.socketPath)
        try sendIPCRequest(IPCRequest(id: "recovery-req-2", method: "status"), to: clientFd5b)

        _ = try await acceptTask5b.value
        let resp5b = try readIPCResponse(from: clientFd5b)
        assertEqual(resp5b.id, "recovery-req-2")
        assertTrue(resp5b.success)
        close(clientFd5b)

        listener5.stop()
        recordCase("testPostTimeoutUDSRecovery")

        // 6. Slow Drip Header Timeout Test
        let sockPath6 = "/tmp/agy-test-c6-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath6)
        let listener6 = SocketListener(
            socketPath: sockPath6,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )
        try listener6.start()

        let acceptTask6 = Task { try await listener6.acceptAndHandleOneConnection() }
        let clientFd6 = try connectToSocket(at: listener6.socketPath)

        let partialHeader6 = Data([0x00, 0x00])
        _ = partialHeader6.withUnsafeBytes { ptr in write(clientFd6, ptr.baseAddress!, 2) }

        let start6 = ContinuousClock().now
        _ = try await acceptTask6.value
        let elapsed6 = ContinuousClock().now - start6
        let elapsedSec6 = Double(elapsed6.components.seconds) + Double(elapsed6.components.attoseconds) / 1e18

        assertTrue(elapsedSec6 >= 1.8 && elapsedSec6 <= 3.5, "Header read phase deadline enforced in \(elapsedSec6)s")

        let resp6 = try readIPCResponse(from: clientFd6)
        assertTrue(!resp6.success)
        assertEqual(resp6.error?.code, "TIMEOUT")

        close(clientFd6)
        listener6.stop()
        recordCase("testSlowDripHeaderTimeout")

        // 7. Slow Drip Body Timeout Test
        let sockPath7 = "/tmp/agy-test-c7-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath7)
        let listener7 = SocketListener(
            socketPath: sockPath7,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )
        try listener7.start()

        let acceptTask7 = Task { try await listener7.acceptAndHandleOneConnection() }
        let clientFd7 = try connectToSocket(at: listener7.socketPath)

        let header7 = Data([0x00, 0x00, 0x00, 0x40]) // 64 bytes
        let bodyPartial7 = Data("hello".utf8)
        var msg7 = header7
        msg7.append(bodyPartial7)
        _ = msg7.withUnsafeBytes { ptr in write(clientFd7, ptr.baseAddress!, msg7.count) }

        let start7 = ContinuousClock().now
        _ = try await acceptTask7.value
        let elapsed7 = ContinuousClock().now - start7
        let elapsedSec7 = Double(elapsed7.components.seconds) + Double(elapsed7.components.attoseconds) / 1e18

        assertTrue(elapsedSec7 >= 2.8 && elapsedSec7 <= 4.5, "Body read phase deadline enforced in \(elapsedSec7)s")

        let resp7 = try readIPCResponse(from: clientFd7)
        assertTrue(!resp7.success)
        assertEqual(resp7.error?.code, "TIMEOUT")

        close(clientFd7)
        listener7.stop()
        recordCase("testSlowDripBodyTimeout")

        // 8. Blocked Response Write Timeout Test
        let sockPath8 = "/tmp/agy-test-c8-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath8)
        let listener8 = SocketListener(
            socketPath: sockPath8,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(granted: true),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )
        try listener8.start()

        let acceptTask8 = Task { try await listener8.acceptAndHandleOneConnection() }
        let clientFd8 = try connectToSocket(at: listener8.socketPath)

        var smallBuf: Int32 = 1024
        _ = setsockopt(clientFd8, SOL_SOCKET, SO_RCVBUF, &smallBuf, socklen_t(MemoryLayout<Int32>.size))

        try sendIPCRequest(IPCRequest(id: "block-req-8", method: "observe"), to: clientFd8)

        let start8 = ContinuousClock().now
        let handled8 = try await acceptTask8.value
        let elapsed8 = ContinuousClock().now - start8
        let elapsedSec8 = Double(elapsed8.components.seconds) + Double(elapsed8.components.attoseconds) / 1e18

        assertTrue(handled8)
        assertTrue(elapsedSec8 >= 1.8 && elapsedSec8 <= 5.5, "Blocked write phase deadline enforced in \(elapsedSec8)s")

        close(clientFd8)
        listener8.stop()
        recordCase("testBlockedResponseWriteTimeout")

        // 9. Peer Close and Partial IO Test
        let sockPath9 = "/tmp/agy-test-c9-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath9)
        let listener9 = SocketListener(
            socketPath: sockPath9,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )
        try listener9.start()

        // Scenario A: Client closes immediately after sending 2 header bytes
        let acceptTask9a = Task { try await listener9.acceptAndHandleOneConnection() }
        let clientFd9a = try connectToSocket(at: listener9.socketPath)
        let pBytes = Data([0x00, 0x00])
        _ = pBytes.withUnsafeBytes { ptr in write(clientFd9a, ptr.baseAddress!, 2) }
        close(clientFd9a)

        let handled9a = try await acceptTask9a.value
        assertTrue(handled9a, "Listener handles abrupt peer close during header read safely")

        // Scenario B: Client closes immediately after sending header + 5 body bytes
        let acceptTask9b = Task { try await listener9.acceptAndHandleOneConnection() }
        let clientFd9b = try connectToSocket(at: listener9.socketPath)
        var msg9b = Data([0x00, 0x00, 0x00, 0x20]) // 32 byte body
        msg9b.append(Data("partial".utf8))
        _ = msg9b.withUnsafeBytes { ptr in write(clientFd9b, ptr.baseAddress!, msg9b.count) }
        close(clientFd9b)

        let handled9b = try await acceptTask9b.value
        assertTrue(handled9b, "Listener handles abrupt peer close during body read safely")

        listener9.stop()
        recordCase("testPeerCloseAndPartialIO")

        // 10. EINTR Retry Path Test
        signal(SIGUSR1, { _ in })

        let sockPath10 = "/tmp/agy-test-c10-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath10)
        let listener10 = SocketListener(
            socketPath: sockPath10,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(granted: true),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )
        try listener10.start()

        let acceptTask10 = Task { try await listener10.acceptAndHandleOneConnection() }
        let clientFd10 = try connectToSocket(at: listener10.socketPath)

        kill(getpid(), SIGUSR1)
        try sendIPCRequest(IPCRequest(id: "eintr-req-10", method: "status"), to: clientFd10)

        kill(getpid(), SIGUSR1)
        let handled10 = try await acceptTask10.value
        assertTrue(handled10)

        let resp10 = try readIPCResponse(from: clientFd10)
        assertEqual(resp10.id, "eintr-req-10")
        assertTrue(resp10.success)

        close(clientFd10)
        listener10.stop()
        signal(SIGUSR1, SIG_DFL)
        recordCase("testEINTRRetryPath")

        // 11. Timeout Response Followed By Next Client Test
        let sockPath11 = "/tmp/agy-test-c11-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath11)
        let listener11 = SocketListener(
            socketPath: sockPath11,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(granted: true),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )
        try listener11.start()

        let acceptTask11a = Task { try await listener11.acceptAndHandleOneConnection() }
        let clientFd11a = try connectToSocket(at: listener11.socketPath)
        let partialHeader11 = Data([0x00, 0x00])
        _ = partialHeader11.withUnsafeBytes { ptr in write(clientFd11a, ptr.baseAddress!, 2) }

        _ = try await acceptTask11a.value
        let resp11a = try readIPCResponse(from: clientFd11a)
        assertTrue(!resp11a.success)
        assertEqual(resp11a.error?.code, "TIMEOUT")
        close(clientFd11a)

        let acceptTask11b = Task { try await listener11.acceptAndHandleOneConnection() }
        let clientFd11b = try connectToSocket(at: listener11.socketPath)
        try sendIPCRequest(IPCRequest(id: "seq-req-11", method: "status"), to: clientFd11b)

        _ = try await acceptTask11b.value
        let resp11b = try readIPCResponse(from: clientFd11b)
        assertEqual(resp11b.id, "seq-req-11")
        assertTrue(resp11b.success)
        close(clientFd11b)

        listener11.stop()
        recordCase("testTimeoutResponseFollowedByNextClient")

        // 12. Live Socket Collision Refusal Test
        let sockPath12 = "/tmp/agy-test-c12-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath12)
        let listener12a = SocketListener(
            socketPath: sockPath12,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )
        try listener12a.start()

        let listener12b = SocketListener(
            socketPath: sockPath12,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )

        var threwCollision12 = false
        do {
            try listener12b.start()
        } catch let err as ComputerUseError {
            if case .ipcError(let reason) = err {
                assertTrue(reason.contains("another active host") || reason.contains("active socket"))
                threwCollision12 = true
            }
        }
        assertTrue(threwCollision12, "Starting second listener on active socket path must throw ipcError collision refusal")

        listener12a.stop()
        recordCase("testLiveSocketCollisionRefusal")

        // 13. Verified Stale Socket Recovery Test
        let sockPath13 = "/tmp/agy-test-c13-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath13)

        let dummyFd13 = socket(AF_UNIX, SOCK_STREAM, 0)
        assertTrue(dummyFd13 >= 0)
        var addr13 = sockaddr_un()
        let pathBytes13 = sockPath13.utf8CString
        addr13.sun_len = UInt8(MemoryLayout<sa_family_t>.size + pathBytes13.count)
        addr13.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr13.sun_path) { ptr in
            ptr.initializeMemory(as: CChar.self, repeating: 0)
            _ = pathBytes13.withUnsafeBufferPointer { bPtr in memcpy(ptr.baseAddress!, bPtr.baseAddress!, bPtr.count) }
        }
        let sockLen13 = socklen_t(addr13.sun_len)
        let bindRes13 = withUnsafePointer(to: &addr13) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(dummyFd13, saPtr, sockLen13)
            }
        }
        assertEqual(bindRes13, 0)
        close(dummyFd13)

        var statBuf13 = stat()
        assertEqual(lstat(sockPath13, &statBuf13), 0)
        assertTrue((statBuf13.st_mode & S_IFMT) == S_IFSOCK)

        let listener13 = SocketListener(
            socketPath: sockPath13,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(granted: true),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )
        try listener13.start()

        let acceptTask13 = Task { try await listener13.acceptAndHandleOneConnection() }
        let clientFd13 = try connectToSocket(at: listener13.socketPath)
        try sendIPCRequest(IPCRequest(id: "stale-rec-13", method: "status"), to: clientFd13)

        _ = try await acceptTask13.value
        let resp13 = try readIPCResponse(from: clientFd13)
        assertEqual(resp13.id, "stale-rec-13")
        assertTrue(resp13.success)

        close(clientFd13)
        listener13.stop()
        recordCase("testVerifiedStaleSocketRecovery")

        // 14. Foreign Symlink Non-Socket Refusal Test
        let sockPath14Reg = "/tmp/agy-test-c14r-\(UUID().uuidString)/reg.sock"
        try SocketListener.prepareDirectory(at: sockPath14Reg)

        let regFd14 = open(sockPath14Reg, O_CREAT | O_WRONLY, 0o600)
        assertTrue(regFd14 >= 0)
        close(regFd14)

        let listener14a = SocketListener(
            socketPath: sockPath14Reg,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )

        var threwReg14 = false
        do {
            try listener14a.start()
        } catch let err as ComputerUseError {
            if case .ipcError(let reason) = err {
                assertTrue(reason.contains("non-socket file"))
                threwReg14 = true
            }
        }
        assertTrue(threwReg14, "Listener must refuse to unlink pre-existing regular file")
        _ = unlink(sockPath14Reg)

        let sockPath14Lnk = "/tmp/agy-test-c14l-\(UUID().uuidString)/lnk.sock"
        try SocketListener.prepareDirectory(at: sockPath14Lnk)
        let targetPath14 = "/tmp/agy-test-c14l-\(UUID().uuidString)/target"
        _ = symlink(targetPath14, sockPath14Lnk)

        let listener14b = SocketListener(
            socketPath: sockPath14Lnk,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )

        var threwLnk14 = false
        do {
            try listener14b.start()
        } catch let err as ComputerUseError {
            if case .ipcError(let reason) = err {
                assertTrue(reason.contains("non-socket file"))
                threwLnk14 = true
            }
        }
        assertTrue(threwLnk14, "Listener must refuse to unlink pre-existing symlink")
        _ = unlink(sockPath14Lnk)

        recordCase("testForeignSymlinkNonSocketRefusal")

        // 15. Stop Never Unlinks Replacement Inode Test
        let sockPath15 = "/tmp/agy-test-c15-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath15)
        let listener15 = SocketListener(
            socketPath: sockPath15,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )
        try listener15.start()

        _ = unlink(listener15.socketPath)

        let replacementFd15 = socket(AF_UNIX, SOCK_STREAM, 0)
        assertTrue(replacementFd15 >= 0)
        var addr15 = sockaddr_un()
        let pathBytes15 = listener15.socketPath.utf8CString
        addr15.sun_len = UInt8(MemoryLayout<sa_family_t>.size + pathBytes15.count)
        addr15.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr15.sun_path) { ptr in
            ptr.initializeMemory(as: CChar.self, repeating: 0)
            _ = pathBytes15.withUnsafeBufferPointer { bPtr in memcpy(ptr.baseAddress!, bPtr.baseAddress!, bPtr.count) }
        }
        let sockLen15 = socklen_t(addr15.sun_len)
        _ = withUnsafePointer(to: &addr15) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(replacementFd15, saPtr, sockLen15)
            }
        }
        close(replacementFd15)

        var replacementStat15 = stat()
        assertEqual(lstat(listener15.socketPath, &replacementStat15), 0)

        listener15.stop()

        var postStopStat15 = stat()
        assertEqual(lstat(listener15.socketPath, &postStopStat15), 0, "Replacement inode file must remain on disk after stop()")
        assertEqual(postStopStat15.st_ino, replacementStat15.st_ino, "Inode of replacement file must match")

        _ = unlink(listener15.socketPath)
        recordCase("testStopNeverUnlinksReplacementInode")

        // 16. IEEE-754 Bit Pattern Topology Golden Vector & Mutations Test
        let primaryDisp = DisplayInfo(id: 1, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: 0.0, originY: 0.0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)
        let goldVer = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [primaryDisp])
        assertTrue(goldVer.hasPrefix("top-sha256-"))
        assertEqual(goldVer.count, 75)

        let mutDisp1 = DisplayInfo(id: 1, widthPoints: 1920, heightPoints: 1080, scaleFactor: 1.0, originX: 0.0, originY: 0.0, pixelWidth: 1920, pixelHeight: 1080, rotation: 0.0)
        let mutVer1 = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutDisp1])
        assertTrue(mutVer1 != goldVer)

        let mutDisp2 = DisplayInfo(id: 1, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: -0.0, originY: 0.0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)
        let mutVer2 = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutDisp2])
        assertEqual(mutVer2, goldVer, "IEEE-754 bitPattern signed zero -0.0 vs 0.0 consistency")
        recordCase("testIEEE754BitPatternTopologyGoldenVectorAndMutations")

        // 17. Hot-Plug Safe Display Enumerator Test
        let validPass: () throws -> (primaryId: Int, displayIDs: [Int]) = { (1, [1]) }

        // Success path
        let successEnum = ScriptedDisplayListEnumerator(script: [validPass, validPass, validPass])
        let successProvider = SystemDisplayTopologyProvider(enumerator: successEnum, descriptorProvider: FakeDescriptorProvider())
        let top = try successProvider.getTopology()
        assertEqual(top.primaryDisplayId, 1)
        assertEqual(top.displays.count, 1)

        // Grow failure
        let growEnum = ScriptedDisplayListEnumerator(script: [{ (1, [1]) }, { (1, [1, 2]) }])
        let growProvider = SystemDisplayTopologyProvider(enumerator: growEnum, descriptorProvider: FakeDescriptorProvider())
        var threwGrow = false
        do { _ = try growProvider.getTopology() } catch { threwGrow = true }
        assertTrue(threwGrow, "Must reject display topology growth between passes")

        // Shrink failure
        let shrinkEnum = ScriptedDisplayListEnumerator(script: [{ (1, [1, 2]) }, { (1, [1]) }])
        let shrinkProvider = SystemDisplayTopologyProvider(enumerator: shrinkEnum, descriptorProvider: FakeDescriptorProvider())
        var threwShrink = false
        do { _ = try shrinkProvider.getTopology() } catch { threwShrink = true }
        assertTrue(threwShrink, "Must reject display topology shrinkage between passes")

        // Recount failure
        let errorEnum = ScriptedDisplayListEnumerator(script: [
            validPass,
            { throw ComputerUseError.targetUnreachable(reason: "Transient CG enumeration failure") }
        ])
        let errorProvider = SystemDisplayTopologyProvider(enumerator: errorEnum, descriptorProvider: FakeDescriptorProvider())
        var threwError = false
        do { _ = try errorProvider.getTopology() } catch { threwError = true }
        assertTrue(threwError, "Must propagate enumeration error on recount failure")

        // Duplicate ID failure
        let dupEnum = ScriptedDisplayListEnumerator(script: [{ (1, [1, 1]) }, { (1, [1, 1]) }])
        let dupProvider = SystemDisplayTopologyProvider(enumerator: dupEnum, descriptorProvider: FakeDescriptorProvider())
        var threwDup = false
        do { _ = try dupProvider.getTopology() } catch { threwDup = true }
        assertTrue(threwDup, "Must reject display list containing duplicate IDs")

        // Missing primary failure
        let missingPrimaryEnum = ScriptedDisplayListEnumerator(script: [{ (2, [1]) }, { (2, [1]) }])
        let missingPrimaryProvider = SystemDisplayTopologyProvider(enumerator: missingPrimaryEnum, descriptorProvider: FakeDescriptorProvider())
        var threwMissingPrimary = false
        do { _ = try missingPrimaryProvider.getTopology() } catch { threwMissingPrimary = true }
        assertTrue(threwMissingPrimary, "Must reject display list missing declared primary display ID")

        recordCase("testHotPlugSafeDisplayEnumerator")

        // 18. Permission Preflight Denied Zero Loader Calls Test
        let deniedAuth = FakeScreenRecordingAuthorizer(granted: false)
        let counterEngine = FakeCaptureEngine()
        let deniedServer = HostServer(
            authorizer: deniedAuth,
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: counterEngine,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector()
        )
        let deniedResp = await deniedServer.handleRequest(IPCRequest(id: "denied-1", method: "observe"))
        assertTrue(!deniedResp.success)
        assertEqual(deniedResp.error?.code, "PERMISSION_DENIED")
        assertEqual(counterEngine.invocationCount, 0, "Preflight check must prevent captureEngine invocation")
        recordCase("testPermissionPreflightDeniedZeroLoaderCalls")

        // 19. Pure JPEG Validator Exact & Near 10MiB Boundaries Test
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400, space: colorSpace, bitmapInfo: bitmapInfo
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

        // Exact near-10MiB boundaries validation
        let maxBytes = 10 * 1024 * 1024
        let exact10MiB = makeSyntheticJPEG(marker: 0xC0, width: 100, height: 100, padToSize: maxBytes)
        assertEqual(exact10MiB.count, maxBytes)
        try SCScreenshotCaptureEngine.validateJPEGData(data: exact10MiB, expectedWidth: 100, expectedHeight: 100, maxBytes: maxBytes)

        let oversized10MiB = makeSyntheticJPEG(marker: 0xC0, width: 100, height: 100, padToSize: maxBytes + 1)
        assertEqual(oversized10MiB.count, maxBytes + 1)
        var threwOversized10MiB = false
        do {
            try SCScreenshotCaptureEngine.validateJPEGData(data: oversized10MiB, expectedWidth: 100, expectedHeight: 100, maxBytes: maxBytes)
        } catch let err as ComputerUseError {
            if case .ipcError(let reason) = err {
                assertTrue(reason.contains("10 MiB limit"))
                threwOversized10MiB = true
            }
        }
        assertTrue(threwOversized10MiB, "Must reject JPEG exceeding exact 10 MiB boundary")

        recordCase("testPureJPEGValidatorExactAndNear10MiBBoundaries")

        // 20. SOF0 and SOF2 Marker Validation Test
        let sof0Data = makeSyntheticJPEG(marker: 0xC0, width: 320, height: 240)
        let dims0 = SCScreenshotCaptureEngine.parseJPEGDimensions(data: sof0Data)
        assertTrue(dims0 != nil)
        assertEqual(dims0?.width, 320)
        assertEqual(dims0?.height, 240)
        try SCScreenshotCaptureEngine.validateJPEGData(data: sof0Data, expectedWidth: 320, expectedHeight: 240)

        let sof2Data = makeSyntheticJPEG(marker: 0xC2, width: 640, height: 480)
        let dims2 = SCScreenshotCaptureEngine.parseJPEGDimensions(data: sof2Data)
        assertTrue(dims2 != nil)
        assertEqual(dims2?.width, 640)
        assertEqual(dims2?.height, 480)
        try SCScreenshotCaptureEngine.validateJPEGData(data: sof2Data, expectedWidth: 640, expectedHeight: 480)

        recordCase("testSOF0AndSOF2MarkerValidation")

        // 21. JPEG Invalid Magic, Truncated Segment & Mismatch Rejection Test
        let invalidMagicData = Data([0x00, 0x00, 0xFF, 0xD8])
        assertTrue(SCScreenshotCaptureEngine.parseJPEGDimensions(data: invalidMagicData) == nil)
        var threwBadMagic = false
        do { try SCScreenshotCaptureEngine.validateJPEGData(data: invalidMagicData) } catch { threwBadMagic = true }
        assertTrue(threwBadMagic, "Must reject invalid magic bytes")

        let truncatedData = sof0Data.prefix(8)
        assertTrue(SCScreenshotCaptureEngine.parseJPEGDimensions(data: Data(truncatedData)) == nil)
        var threwTruncated = false
        do { try SCScreenshotCaptureEngine.validateJPEGData(data: Data(truncatedData)) } catch { threwTruncated = true }
        assertTrue(threwTruncated, "Must reject truncated JPEG segment")

        var threwDimensionMismatch = false
        do { try SCScreenshotCaptureEngine.validateJPEGData(data: sof0Data, expectedWidth: 100, expectedHeight: 100) } catch { threwDimensionMismatch = true }
        assertTrue(threwDimensionMismatch, "Must reject JPEG dimension mismatch")

        recordCase("testJPEGInvalidMagicTruncatedSegmentAndMismatchRejection")

        // 22. Noncooperative Late Completion Generation Fence Test
        let scriptedEngine = ScriptedContinuationCaptureEngine()
        let fenceServer = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: scriptedEngine,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector(),
            observationTimeoutSec: 0.05 // 50ms timeout
        )

        // Request A: times out at 50ms
        let reqATask = Task { await fenceServer.handleRequest(IPCRequest(id: "fence-A", method: "observe")) }
        let respA = await reqATask.value
        assertTrue(!respA.success)
        assertEqual(respA.error?.code, "TIMEOUT")

        // Request B: succeeds on same HostServer deterministically
        let reqBTask = Task { await fenceServer.handleRequest(IPCRequest(id: "fence-B", method: "observe")) }
        await scriptedEngine.waitForContinuation(at: 1)
        let frameB = try! FakeCaptureEngine().generateDTO(topology: FakeDisplayTopologyProvider().getTopology())
        scriptedEngine.resumeContinuation(at: 1, with: .success(frameB))

        let respB = await reqBTask.value
        assertTrue(respB.success)
        assertEqual(await fenceServer.latestCaptureSnapshot?.captureId, frameB.captureId)
        assertEqual(await fenceServer.latestIssuedGenerationSnapshot, 2)

        // Now complete A (continuation index 0) late
        let frameA = try! FakeCaptureEngine().generateDTO(topology: FakeDisplayTopologyProvider().getTopology())
        scriptedEngine.resumeContinuation(at: 0, with: .success(frameA))

        // Assert that coordinator snapshot still proves B alone remains latest with generation 2 lease
        assertEqual(await fenceServer.latestCaptureSnapshot?.captureId, frameB.captureId)
        assertEqual(await fenceServer.latestIssuedGenerationSnapshot, 2)
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
        let realInvocationCount = await oversizedEngine.frameworkInvocationCount
        assertEqual(realInvocationCount, 0, "Invocation counter must prove zero framework calls on pre-check failure")
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
        let scriptedBudgetEngine = ScriptedContinuationCaptureEngine()
        let budgetServer = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: scriptedBudgetEngine,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector(),
            observationTimeoutSec: 1.0,
            budget: budget
        )

        // Occupy slot 1 (Request A)
        let reqBudgetATask = Task { await budgetServer.handleRequest(IPCRequest(id: "budget-A", method: "observe")) }
        // Occupy slot 2 (Request B)
        let reqBudgetBTask = Task { await budgetServer.handleRequest(IPCRequest(id: "budget-B", method: "observe")) }

        await scriptedBudgetEngine.waitForContinuation(at: 0)
        await scriptedBudgetEngine.waitForContinuation(at: 1)
        assertEqual(budget.count, 2)

        // Request C: while 2 slots are occupied, fails fast with CAPTURE_BUSY
        let startC = ContinuousClock().now
        let respC = await budgetServer.handleRequest(IPCRequest(id: "budget-C", method: "observe"))
        let elapsedC = ContinuousClock().now - startC
        let elapsedMsC = Double(elapsedC.components.seconds * 1000) + Double(elapsedC.components.attoseconds) / 1e15

        assertTrue(!respC.success)
        assertEqual(respC.error?.code, "CAPTURE_BUSY")
        assertTrue(elapsedMsC < 50.0, "Fast failure returned in \(elapsedMsC)ms")
        assertEqual(scriptedBudgetEngine.invocationCount, 2, "Engine invocation count must remain unchanged at 2 for rejected third request")

        // Release slots 1 and 2
        let frameDTO = try! FakeCaptureEngine().generateDTO(topology: FakeDisplayTopologyProvider().getTopology())
        scriptedBudgetEngine.resumeContinuation(at: 0, with: .success(frameDTO))
        scriptedBudgetEngine.resumeContinuation(at: 1, with: .success(frameDTO))

        _ = await reqBudgetATask.value
        _ = await reqBudgetBTask.value

        try await Task.sleep(nanoseconds: 50_000_000)
        assertEqual(budget.count, 0, "Capacity returns to 0 after physical capture tasks exit")

        // Request D: succeeds on same server
        let reqDTask = Task { await budgetServer.handleRequest(IPCRequest(id: "budget-D", method: "observe")) }
        await scriptedBudgetEngine.waitForContinuation(at: 2)
        scriptedBudgetEngine.resumeContinuation(at: 2, with: .success(frameDTO))

        let respD = await reqDTask.value
        assertTrue(respD.success)
        recordCase("testCaptureBudgetCapacityLimitAndFastFailure")

        fputs("[ComputerUseHostTestRunner] Executed \(totalCasesCounter.value) native test cases successfully. ALL PASSED.\n", stderr)
    }
}
