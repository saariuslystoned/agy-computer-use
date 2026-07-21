import Foundation
import CoreGraphics
import ComputerUseHostLib

private final class AtomicCounter: @unchecked Sendable {
    private var val: Int = 0
    private let lock = NSLock()
    func increment() { lock.lock(); val += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return val }
}

private final class ErrorBox: @unchecked Sendable {
    private var err: Error? = nil
    private let lock = NSLock()
    func set(_ error: Error) { lock.lock(); err = error; lock.unlock() }
    var value: Error? { lock.lock(); defer { lock.unlock() }; return err }
}

public final class TestManualClock: HostClock, @unchecked Sendable {
    private let lock = NSLock()
    private var currentInstant: ContinuousClock.Instant

    public init(initial: ContinuousClock.Instant = ContinuousClock().now) {
        self.currentInstant = initial
    }

    public var now: ContinuousClock.Instant {
        lock.lock(); defer { lock.unlock() }
        return currentInstant
    }

    public func advance(by duration: Duration) {
        lock.lock(); defer { lock.unlock() }
        currentInstant = currentInstant + duration
    }
}

public actor ManualSleeper: Sleeper {
    private struct PendingSleep {
        let continuation: CheckedContinuation<Void, Error>
    }

    private var pending: [PendingSleep] = []
    private var armedWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var totalArmedCount: Int = 0
    private var bufferedAdvances: Int = 0

    public init() {}

    public func sleep(nanoseconds: UInt64) async throws {
        try Task.checkCancellation()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Task {
                    await self.registerOrResume(continuation: continuation)
                }
            }
        } onCancel: {
            Task {
                await self.cancelAll()
            }
        }
    }

    private func registerOrResume(continuation: CheckedContinuation<Void, Error>) async {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        if bufferedAdvances > 0 {
            bufferedAdvances -= 1
            totalArmedCount += 1
            notifyArmedWaiters()
            continuation.resume()
            return
        }
        pending.append(PendingSleep(continuation: continuation))
        totalArmedCount += 1
        notifyArmedWaiters()
    }

    public func waitUntilArmed(count: Int) async {
        if totalArmedCount >= count {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            armedWaiters[count, default: []].append(continuation)
        }
    }

    private func notifyArmedWaiters() {
        let currentCount = totalArmedCount
        for (targetCount, waiters) in armedWaiters where currentCount >= targetCount {
            armedWaiters.removeValue(forKey: targetCount)
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    public func advance() {
        if pending.isEmpty {
            bufferedAdvances += 1
            return
        }
        let toResume = pending
        pending.removeAll()

        for item in toResume {
            item.continuation.resume()
        }
    }

    public func cancelAll() {
        let toCancel = pending
        pending.removeAll()

        for item in toCancel {
            item.continuation.resume(throwing: CancellationError())
        }
    }
}

public final class ScriptedPOSIXSyscalls: POSIXSyscallProviding, @unchecked Sendable {
    private let underlying = DarwinPOSIXSyscalls.shared
    private let lock = NSLock()
    private var customErrno: Int32 = 0

    public var acceptHook: ((Int32, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?) -> Int32?)?
    public var readHook: ((Int32, UnsafeMutableRawPointer?, Int) -> Int?)?
    public var writeHook: ((Int32, UnsafeRawPointer?, Int) -> Int?)?
    public var listenHook: ((Int32, Int32) -> Int32?)?

    public var acceptCallCount: Int = 0
    public var readCallCount: Int = 0
    public var writeCallCount: Int = 0

    public init() {}

    public var lastErrno: Int32 {
        lock.lock(); defer { lock.unlock() }
        return customErrno != 0 ? customErrno : underlying.lastErrno
    }

    public func setErrno(_ value: Int32) {
        lock.lock(); defer { lock.unlock() }
        customErrno = value
        underlying.setErrno(value)
    }

    public func clearErrno() {
        lock.lock(); defer { lock.unlock() }
        customErrno = 0
        underlying.setErrno(0)
    }

    public func accept(_ socket: Int32, _ address: UnsafeMutablePointer<sockaddr>?, _ addressLen: UnsafeMutablePointer<socklen_t>?) -> Int32 {
        clearErrno()
        lock.lock()
        acceptCallCount += 1
        let hook = acceptHook
        lock.unlock()
        if let res = hook?(socket, address, addressLen) { return res }
        return underlying.accept(socket, address, addressLen)
    }

    public func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        clearErrno()
        lock.lock()
        readCallCount += 1
        let hook = readHook
        lock.unlock()
        if let res = hook?(fd, buf, count) { return res }
        return underlying.read(fd, buf, count)
    }

    public func write(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int {
        clearErrno()
        lock.lock()
        writeCallCount += 1
        let hook = writeHook
        lock.unlock()
        if let res = hook?(fd, buf, count) { return res }
        return underlying.write(fd, buf, count)
    }

    public func listen(_ socket: Int32, _ backlog: Int32) -> Int32 {
        clearErrno()
        if let res = listenHook?(socket, backlog) { return res }
        return underlying.listen(socket, backlog)
    }

    public func bind(_ socket: Int32, _ address: UnsafePointer<sockaddr>?, _ addressLen: socklen_t) -> Int32 { underlying.bind(socket, address, addressLen) }
    public func socket(_ domain: Int32, _ type: Int32, _ protocol: Int32) -> Int32 { underlying.socket(domain, type, `protocol`) }
    public func open(_ path: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32 { underlying.open(path, oflag, mode) }
    public func fcntl(_ fd: Int32, _ cmd: Int32, _ arg: Int32) -> Int32 { underlying.fcntl(fd, cmd, arg) }
    public func getsockopt(_ socket: Int32, _ level: Int32, _ optionName: Int32, _ optionValue: UnsafeMutableRawPointer?, _ optionLen: UnsafeMutablePointer<socklen_t>?) -> Int32 { underlying.getsockopt(socket, level, optionName, optionValue, optionLen) }
    public func lstat(_ path: UnsafePointer<CChar>, _ buf: UnsafeMutablePointer<stat>?) -> Int32 { underlying.lstat(path, buf) }
    public func fstat(_ fd: Int32, _ buf: UnsafeMutablePointer<stat>?) -> Int32 { underlying.fstat(fd, buf) }
    public func flock(_ fd: Int32, _ operation: Int32) -> Int32 { underlying.flock(fd, operation) }
    public func unlink(_ path: UnsafePointer<CChar>) -> Int32 { underlying.unlink(path) }
    public func rmdir(_ path: UnsafePointer<CChar>) -> Int32 { underlying.rmdir(path) }
    public func mkdir(_ path: UnsafePointer<CChar>, _ mode: mode_t) -> Int32 { underlying.mkdir(path, mode) }
    public func close(_ fd: Int32) -> Int32 { underlying.close(fd) }
    public func getuid() -> uid_t { underlying.getuid() }
    public func setsockopt(_ socket: Int32, _ level: Int32, _ optionName: Int32, _ optionValue: UnsafeRawPointer?, _ optionLen: socklen_t) -> Int32 { underlying.setsockopt(socket, level, optionName, optionValue, optionLen) }
    public func connect(_ socket: Int32, _ address: UnsafePointer<sockaddr>?, _ addressLen: socklen_t) -> Int32 { underlying.connect(socket, address, addressLen) }
    public func poll(_ fds: UnsafeMutablePointer<pollfd>?, _ nfds: nfds_t, _ timeout: Int32) -> Int32 { underlying.poll(fds, nfds, timeout) }
    public func getpeereid(_ socket: Int32, _ uid: UnsafeMutablePointer<uid_t>?, _ gid: UnsafeMutablePointer<gid_t>?) -> Int32 { underlying.getpeereid(socket, uid, gid) }
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

public final class CustomDescriptorProvider: DisplayDescriptorProviding, @unchecked Sendable {
    private let bounds: CGRect
    private let rotation: Double
    private let pixelWidth: Int
    private let pixelHeight: Int
    private let scale: Double

    public init(bounds: CGRect, rotation: Double, pixelWidth: Int, pixelHeight: Int, scale: Double) {
        self.bounds = bounds
        self.rotation = rotation
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
    }

    public func getDisplayDescriptor(id: Int) throws -> (bounds: CGRect, rotation: Double, pixelWidth: Int, pixelHeight: Int, scale: Double) {
        return (bounds, rotation, pixelWidth, pixelHeight, scale)
    }
}

public enum ControlledCaptureEngineError: Error, Equatable {
    case invalidIndex(Int)
}

public actor ControlledCaptureEngine: DisplayCaptureEngine {
    private var continuations: [Int: CheckedContinuation<CaptureFrameDTO, Error>] = [:]
    private var registrationWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var exitWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    private(set) public var invocationCount: Int = 0
    private(set) public var physicalExitCount: Int = 0

    public var pendingCount: Int {
        return continuations.count
    }

    public init() {}

    public func captureDisplay(displayId: Int?, topology: DisplayTopology) async throws -> CaptureFrameDTO {
        let index = invocationCount
        invocationCount += 1

        defer {
            physicalExitCount += 1
            notifyExitWaiters()
        }

        return try await withCheckedThrowingContinuation { continuation in
            continuations[index] = continuation
            notifyRegistrationWaiters()
        }
    }

    public func waitUntilRegistered(count: Int) async {
        if invocationCount >= count { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            registrationWaiters[count, default: []].append(continuation)
        }
    }

    private func notifyRegistrationWaiters() {
        let currentCount = invocationCount
        for (targetCount, waiters) in registrationWaiters where currentCount >= targetCount {
            registrationWaiters.removeValue(forKey: targetCount)
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    public func waitUntilExited(count: Int) async {
        if physicalExitCount >= count { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exitWaiters[count, default: []].append(continuation)
        }
    }

    private func notifyExitWaiters() {
        let currentCount = physicalExitCount
        for (targetCount, waiters) in exitWaiters where currentCount >= targetCount {
            exitWaiters.removeValue(forKey: targetCount)
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    @discardableResult
    public func complete(index: Int, with result: Result<CaptureFrameDTO, Error>) throws -> Bool {
        guard let continuation = continuations.removeValue(forKey: index) else {
            throw ControlledCaptureEngineError.invalidIndex(index)
        }
        continuation.resume(with: result)
        return true
    }
}

public final class FakeCaptureEngine: DisplayCaptureEngine, @unchecked Sendable {
    private let counter = AtomicCounter()
    private let delayMs: Double
    private let customTopologyVersion: String?
    private let largePayloadBytes: Int

    public init(delayMs: Double = 0.0, customTopologyVersion: String? = nil, largePayloadBytes: Int = 0) {
        self.delayMs = delayMs
        self.customTopologyVersion = customTopologyVersion
        self.largePayloadBytes = largePayloadBytes
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
        let finalB64 = largePayloadBytes > 0 ? b64 + String(repeating: "A", count: max(0, largePayloadBytes - b64.count)) : b64

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
            imageDataBase64: finalB64
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

private func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a != b {
        fputs("[FAIL] Assertion failed: '\(a)' != '\(b)'. \(msg) at \(file):\(line)\n", stderr)
        exit(1)
    }
}

private func assertTrue(_ cond: Bool, _ msg: String = "", file: String = #file, line: Int = #line) {
    if !cond {
        fputs("[FAIL] Assertion failed. \(msg) at \(file):\(line)\n", stderr)
        exit(1)
    }
}

private func connectToSocket(at socketPath: String) throws -> Int32 {
    let clientFd = socket(AF_UNIX, SOCK_STREAM, 0)
    assertTrue(clientFd >= 0)

    var nosigpipe: Int32 = 1
    _ = setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

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
    assertEqual(connRes, 0)
    return clientFd
}

private func sendIPCRequest(_ req: IPCRequest, to fd: Int32) throws {
    let reqData = try JSONEncoder().encode(req)
    let framed = try LengthPrefixedFramer.encode(payload: reqData)
    _ = framed.withUnsafeBytes { ptr in write(fd, ptr.baseAddress!, framed.count) }
}

private func readIPCResponse(from fd: Int32) throws -> IPCResponse {
    var headerBuf = [UInt8](repeating: 0, count: 4)
    let r1 = read(fd, &headerBuf, 4)
    guard r1 == 4 else {
        throw ComputerUseError.ipcError(reason: "Failed to read 4-byte header from client socket")
    }
    let respLen = Int(headerBuf[0]) << 24 | Int(headerBuf[1]) << 16 | Int(headerBuf[2]) << 8 | Int(headerBuf[3])

    var respBuf = [UInt8](repeating: 0, count: respLen)
    let r2 = read(fd, &respBuf, respLen)
    guard r2 == respLen else {
        throw ComputerUseError.ipcError(reason: "Failed to read \(respLen) payload bytes from client socket")
    }

    return try JSONDecoder().decode(IPCResponse.self, from: Data(respBuf))
}

@main
public struct ComputerUseHostTestRunner {
    public static func run01_LengthPrefixedFraming() async throws {
        let payload = Data("{\"id\":\"test-1\",\"method\":\"status\"}".utf8)
        let framed = try LengthPrefixedFramer.encode(payload: payload)
        assertEqual(framed.count, 4 + payload.count)
        var mutFramed = framed
        let decoded = try LengthPrefixedFramer.decode(from: &mutFramed)
        assertEqual(decoded, payload)
    }

    public static func run02_OversizedFramingHeaderRejection() async throws {
        var badHeader = Data([0x01, 0x00, 0x00, 0x01])
        badHeader.append(Data(repeating: 0, count: 10))
        var threwOversized = false
        do { _ = try LengthPrefixedFramer.decode(from: &badHeader) } catch { threwOversized = true }
        assertTrue(threwOversized)
    }

    public static func run03_DirectoryPreparation() async throws {
        let testDir = "/tmp/test-host-runner-prep-\(UUID().uuidString)"
        try SocketListener.prepareDirectory(at: testDir)
        var statBuf = stat()
        assertEqual(lstat(testDir, &statBuf), 0)
        assertEqual(statBuf.st_mode & 0o777, 0o700)
        _ = rmdir(testDir)
    }

    public static func run04_UDSClientServerRoundTrip() async throws {
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
        let clientFd = try connectToSocket(at: listener.socketPath)

        try sendIPCRequest(IPCRequest(id: "client-req-1", method: "status"), to: clientFd)
        _ = try await acceptTask.value

        let respObj = try readIPCResponse(from: clientFd)
        assertEqual(respObj.id, "client-req-1")
        assertTrue(respObj.success)

        close(clientFd)
        listener.stop()
    }

    public static func run05_PostTimeoutUDSRecovery() async throws {
        let sockPath5 = "/tmp/agy-test-c5-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath5)
        let timeoutEngine5 = TrulyNoncooperativeCaptureEngine(delayMs: 300.0)
        let server5 = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: timeoutEngine5,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector(),
            observationTimeoutSec: 0.05
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
    }

    public static func run06_SlowDripHeaderTimeout() async throws {
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

        let start6 = ContinuousClock().now
        for i in 0..<3 {
            let byte = Data([UInt8(i)])
            _ = byte.withUnsafeBytes { ptr in write(clientFd6, ptr.baseAddress!, 1) }
            try await Task.sleep(nanoseconds: 800_000_000)
        }

        _ = try await acceptTask6.value
        let elapsed6 = ContinuousClock().now - start6
        let elapsedSec6 = Double(elapsed6.components.seconds) + Double(elapsed6.components.attoseconds) / 1e18

        assertTrue(elapsedSec6 >= 1.8 && elapsedSec6 <= 3.5, "Header read phase deadline enforced in \(elapsedSec6)s")

        let resp6 = try readIPCResponse(from: clientFd6)
        assertTrue(!resp6.success)
        assertEqual(resp6.error?.code, "TIMEOUT")

        close(clientFd6)
        listener6.stop()
    }

    public static func run07_SlowDripBodyTimeout() async throws {
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

        let header7 = Data([0x00, 0x00, 0x00, 0x40])
        _ = header7.withUnsafeBytes { ptr in write(clientFd7, ptr.baseAddress!, 4) }

        let start7 = ContinuousClock().now
        for i in 0..<4 {
            let byte = Data([UInt8(i)])
            _ = byte.withUnsafeBytes { ptr in write(clientFd7, ptr.baseAddress!, 1) }
            try await Task.sleep(nanoseconds: 900_000_000)
        }

        _ = try await acceptTask7.value
        let elapsed7 = ContinuousClock().now - start7
        let elapsedSec7 = Double(elapsed7.components.seconds) + Double(elapsed7.components.attoseconds) / 1e18

        assertTrue(elapsedSec7 >= 2.8 && elapsedSec7 <= 4.5, "Body read phase deadline enforced in \(elapsedSec7)s")

        let resp7 = try readIPCResponse(from: clientFd7)
        assertTrue(!resp7.success)
        assertEqual(resp7.error?.code, "TIMEOUT")

        close(clientFd7)
        listener7.stop()
    }

    public static func run08_BlockedResponseWriteTimeout() async throws {
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
        listener8.socketWriter = { _, _, _ in
            errno = EAGAIN
            return -1
        }
        try listener8.start()

        let acceptTask8 = Task { try await listener8.acceptAndHandleOneConnection() }
        let clientFd8 = try connectToSocket(at: listener8.socketPath)

        var smallBuf8: Int32 = 1024
        _ = setsockopt(clientFd8, SOL_SOCKET, SO_RCVBUF, &smallBuf8, socklen_t(MemoryLayout<Int32>.size))

        try sendIPCRequest(IPCRequest(id: "block-req-8", method: "observe"), to: clientFd8)

        let start8 = ContinuousClock().now
        let handled8 = try await acceptTask8.value
        let elapsed8 = ContinuousClock().now - start8
        let elapsedSec8 = Double(elapsed8.components.seconds) + Double(elapsed8.components.attoseconds) / 1e18

        assertTrue(handled8)
        assertTrue(elapsedSec8 >= 1.8 && elapsedSec8 <= 5.5, "Blocked write phase deadline enforced in \(elapsedSec8)s")

        var buf8 = [UInt8](repeating: 0, count: 16)
        let r8 = read(clientFd8, &buf8, 16)
        assertTrue(r8 <= 0, "Client read must return EOF/error due to socket close on write timeout, proving no second error response write")

        close(clientFd8)
        listener8.stop()
    }

    public static func run09_PeerCloseAndPartialIO() async throws {
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

        let acceptTask9a = Task { try await listener9.acceptAndHandleOneConnection() }
        let clientFd9a = try connectToSocket(at: listener9.socketPath)
        let pBytes = Data([0x00, 0x00])
        _ = pBytes.withUnsafeBytes { ptr in write(clientFd9a, ptr.baseAddress!, 2) }
        close(clientFd9a)

        let handled9a = try await acceptTask9a.value
        assertTrue(handled9a, "Listener handles abrupt peer close during header read safely")

        let acceptTask9b = Task { try await listener9.acceptAndHandleOneConnection() }
        let clientFd9b = try connectToSocket(at: listener9.socketPath)
        var msg9b = Data([0x00, 0x00, 0x00, 0x20])
        msg9b.append(Data("partial".utf8))
        _ = msg9b.withUnsafeBytes { ptr in write(clientFd9b, ptr.baseAddress!, msg9b.count) }
        close(clientFd9b)

        let handled9b = try await acceptTask9b.value
        assertTrue(handled9b, "Listener handles abrupt peer close during body read safely")

        listener9.stop()
    }

    public static func run10_EINTRRetryPath() async throws {
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
    }

    public static func run11_TimeoutResponseFollowedByNextClient() async throws {
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
    }

    public static func run12_LiveSocketCollisionProbe() async throws {
        let sockPath12 = "/tmp/agy-test-c12-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath12)

        let rawFd12 = socket(AF_UNIX, SOCK_STREAM, 0)
        assertTrue(rawFd12 >= 0)
        var addr12 = sockaddr_un()
        let pathBytes12 = sockPath12.utf8CString
        addr12.sun_len = UInt8(MemoryLayout<sa_family_t>.size + pathBytes12.count)
        addr12.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr12.sun_path) { ptr in
            ptr.initializeMemory(as: CChar.self, repeating: 0)
            _ = pathBytes12.withUnsafeBufferPointer { bPtr in memcpy(ptr.baseAddress!, bPtr.baseAddress!, bPtr.count) }
        }
        let sockLen12 = socklen_t(addr12.sun_len)
        _ = withUnsafePointer(to: &addr12) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(rawFd12, saPtr, sockLen12)
            }
        }
        _ = listen(rawFd12, 5)

        let listener12 = SocketListener(
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
            try listener12.start()
        } catch let err as ComputerUseError {
            if case .ipcError(let reason) = err {
                assertTrue(reason.contains("live listener") || reason.contains("active socket"))
                threwCollision12 = true
            }
        }
        assertTrue(threwCollision12, "Starting listener on active socket path without host.lock must fail live probe")

        close(rawFd12)
        _ = unlink(sockPath12)
    }

    public static func run13_VerifiedStaleSocketRecovery() async throws {
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
    }

    public static func run14_ForeignSymlinkNonSocketRefusal() async throws {
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
    }

    public static func run15_StopNeverUnlinksReplacementInode() async throws {
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

        listener15.stop()

        var statBuf15 = stat()
        assertEqual(lstat(sockPath15, &statBuf15), 0)
        assertTrue((statBuf15.st_mode & S_IFMT) == S_IFSOCK)
        _ = unlink(sockPath15)
    }

    public static func run16_IEEE754BitPatternTopologyGoldenVectorAndMutations() async throws {
        let primaryDisp = DisplayInfo(
            id: 1,
            widthPoints: 1920.0,
            heightPoints: 1080.0,
            scaleFactor: 2.0,
            originX: 0.0,
            originY: 0.0,
            pixelWidth: 3840,
            pixelHeight: 2160,
            rotation: 0.0
        )
        let expectedDigestHex = "7275400fc06a64d3e67dad36ddfff2a9390c8adee90c0ceabb46715c2f403fe3"
        let expectedGoldenVersion = "top-sha256-\(expectedDigestHex)"
        let goldVer = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [primaryDisp])

        assertEqual(goldVer, expectedGoldenVersion)
        assertTrue(goldVer.hasPrefix("top-sha256-"))
        assertEqual(goldVer.count, 75)
        let hexDigest = String(goldVer.dropFirst(11))
        assertEqual(hexDigest, expectedDigestHex)

        let mutId = DisplayInfo(id: 2, widthPoints: 1920.0, heightPoints: 1080.0, scaleFactor: 2.0, originX: 0.0, originY: 0.0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)
        assertTrue(SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutId]) != goldVer)

        let mutW = DisplayInfo(id: 1, widthPoints: 2560.0, heightPoints: 1080.0, scaleFactor: 2.0, originX: 0.0, originY: 0.0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)
        assertTrue(SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutW]) != goldVer)

        let mutH = DisplayInfo(id: 1, widthPoints: 1920.0, heightPoints: 1440.0, scaleFactor: 2.0, originX: 0.0, originY: 0.0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)
        assertTrue(SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutH]) != goldVer)

        let mutScale = DisplayInfo(id: 1, widthPoints: 1920.0, heightPoints: 1080.0, scaleFactor: 1.0, originX: 0.0, originY: 0.0, pixelWidth: 1920, pixelHeight: 1080, rotation: 0.0)
        assertTrue(SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutScale]) != goldVer)

        let mutOx = DisplayInfo(id: 1, widthPoints: 1920.0, heightPoints: 1080.0, scaleFactor: 2.0, originX: 100.0, originY: 0.0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)
        assertTrue(SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutOx]) != goldVer)

        let mutOy = DisplayInfo(id: 1, widthPoints: 1920.0, heightPoints: 1080.0, scaleFactor: 2.0, originX: 0.0, originY: 50.0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)
        assertTrue(SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutOy]) != goldVer)

        let mutPw = DisplayInfo(id: 1, widthPoints: 1920.0, heightPoints: 1080.0, scaleFactor: 2.0, originX: 0.0, originY: 0.0, pixelWidth: 1920, pixelHeight: 2160, rotation: 0.0)
        assertTrue(SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutPw]) != goldVer)

        let mutPh = DisplayInfo(id: 1, widthPoints: 1920.0, heightPoints: 1080.0, scaleFactor: 2.0, originX: 0.0, originY: 0.0, pixelWidth: 3840, pixelHeight: 1080, rotation: 0.0)
        assertTrue(SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutPh]) != goldVer)

        let mutRot = DisplayInfo(id: 1, widthPoints: 1920.0, heightPoints: 1080.0, scaleFactor: 2.0, originX: 0.0, originY: 0.0, pixelWidth: 3840, pixelHeight: 2160, rotation: 90.0)
        assertTrue(SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutRot]) != goldVer)

        assertTrue(SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 2, displays: [primaryDisp]) != goldVer)

        let mutSignedZero = DisplayInfo(id: 1, widthPoints: 1920.0, heightPoints: 1080.0, scaleFactor: 2.0, originX: -0.0, originY: -0.0, pixelWidth: 3840, pixelHeight: 2160, rotation: -0.0)
        let signedZeroVer = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutSignedZero])
        assertEqual(signedZeroVer, goldVer)

        let invalidDescriptors: [(CGRect, Double, Int, Int, Double)] = [
            (CGRect(x: Double.nan, y: 0, width: 1920, height: 1080), 0.0, 3840, 2160, 2.0),
            (CGRect(x: 0, y: Double.infinity, width: 1920, height: 1080), 0.0, 3840, 2160, 2.0),
            (CGRect(x: 0, y: 0, width: Double.nan, height: 1080), 0.0, 3840, 2160, 2.0),
            (CGRect(x: 0, y: 0, width: 1920, height: Double.infinity), 0.0, 3840, 2160, 2.0),
            (CGRect(x: 0, y: 0, width: 1920, height: 1080), Double.nan, 3840, 2160, 2.0),
            (CGRect(x: 0, y: 0, width: 1920, height: 1080), 0.0, 3840, 2160, Double.infinity)
        ]

        for (bounds, rot, pw, ph, scale) in invalidDescriptors {
            let fakeDesc = CustomDescriptorProvider(bounds: bounds, rotation: rot, pixelWidth: pw, pixelHeight: ph, scale: scale)
            let provider = SystemDisplayTopologyProvider(
                enumerator: ScriptedDisplayListEnumerator(script: [{ (1, [1]) }, { (1, [1]) }, { (1, [1]) }]),
                descriptorProvider: fakeDesc
            )
            var threwError = false
            do {
                _ = try provider.getTopology()
            } catch let err as ComputerUseError {
                if case .targetUnreachable(let reason) = err {
                    assertTrue(reason.contains("non-finite") || reason.contains("invalid scale"))
                    threwError = true
                }
            } catch {}
            assertTrue(threwError, "Display topology provider must reject non-finite float fields")
        }
    }

    public static func run17_HotPlugSafeDisplayEnumerator() async throws {
        let passes: [() throws -> (primaryId: Int, displayIDs: [Int])] = [
            { (1, [1, 2]) },
            { (1, [1, 2]) },
            { (1, [1, 2]) }
        ]
        let enumProvider = SystemDisplayTopologyProvider(
            enumerator: ScriptedDisplayListEnumerator(script: passes),
            descriptorProvider: FakeDescriptorProvider()
        )
        let top17 = try enumProvider.getTopology()
        assertEqual(top17.displays.count, 2)

        let retryPasses: [() throws -> (primaryId: Int, displayIDs: [Int])] = [
            { (1, [1]) },
            { (1, [1, 2]) },
            { (1, [1, 2]) },
            { (1, [1, 2]) },
            { (1, [1, 2]) }
        ]
        let retryProvider = SystemDisplayTopologyProvider(
            enumerator: ScriptedDisplayListEnumerator(script: retryPasses),
            descriptorProvider: FakeDescriptorProvider()
        )
        let topRetry = try retryProvider.getTopology()
        assertEqual(topRetry.displays.count, 2)
    }

    public static func run18_PermissionPreflightDeniedZeroLoaderCalls() async throws {
        let auth18 = FakeScreenRecordingAuthorizer(granted: false)
        let engine18 = SCScreenshotCaptureEngine(authorizer: auth18)
        let top18 = try FakeDisplayTopologyProvider().getTopology()

        var threwDenied = false
        do {
            _ = try await engine18.captureDisplay(displayId: 1, topology: top18)
        } catch let err as ComputerUseError {
            if case .permissionDenied(let perm) = err {
                assertEqual(perm, "screen_recording")
                threwDenied = true
            }
        }
        assertTrue(threwDenied)
        assertEqual(await engine18.frameworkInvocationCount, 0)

        let engine18_granted = SCScreenshotCaptureEngine(
            authorizer: FakeScreenRecordingAuthorizer(granted: true)
        )
        let invalidTop = DisplayTopology(
            version: "v1.0",
            primaryDisplayId: 1,
            displays: [
                DisplayInfo(
                    id: 1,
                    widthPoints: 8001,
                    heightPoints: 8000,
                    scaleFactor: 1.0,
                    originX: 0,
                    originY: 0,
                    pixelWidth: 8001,
                    pixelHeight: 8000,
                    rotation: 0.0
                )
            ]
        )
        var threwInvalidDimensions = false
        do {
            _ = try await engine18_granted.captureDisplay(displayId: 1, topology: invalidTop)
        } catch {
            threwInvalidDimensions = true
        }
        assertTrue(threwInvalidDimensions)
        assertEqual(await engine18_granted.frameworkInvocationCount, 0, "captureDisplay must fail before Framework allocation on >64MP pixel dimensions")
    }

    public static func run19_PureJPEGValidatorExactAndNear10MiBBoundaries() async throws {
        let sof0Data = Data([
            0xFF, 0xD8,
            0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x64, 0x00, 0x64, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
            0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00,
            0xFF, 0xD9
        ])
        let dims19 = SCScreenshotCaptureEngine.parseJPEGDimensions(data: sof0Data)
        assertTrue(dims19 != nil)
        assertEqual(dims19?.width, 100)
        assertEqual(dims19?.height, 100)
        try SCScreenshotCaptureEngine.validateJPEGData(data: sof0Data)

        let subLimitData = Data(repeating: 0x41, count: 10_485_759)
        var threwSubLimit = false
        do { try SCScreenshotCaptureEngine.validateJPEGData(data: subLimitData) } catch { threwSubLimit = true }
        assertTrue(threwSubLimit, "Must reject invalid magic bytes for 1-byte below limit payload")

        let exactLimitData = Data(repeating: 0x41, count: 10_485_760)
        var threwExactLimit = false
        do { try SCScreenshotCaptureEngine.validateJPEGData(data: exactLimitData) } catch { threwExactLimit = true }
        assertTrue(threwExactLimit, "Must reject invalid magic bytes for exact 10 MiB limit payload")

        let overLimitData = Data(repeating: 0x41, count: 10_485_761)
        var threwOverLimit = false
        do { try SCScreenshotCaptureEngine.validateJPEGData(data: overLimitData) } catch { threwOverLimit = true }
        assertTrue(threwOverLimit, "Must reject payloads strictly exceeding 10 MiB limit")

        // Preflight pixel dimensions validation
        try validatePixelDimensions(width: 8000, height: 8000)
        var threwPixelZero = false
        do { try validatePixelDimensions(width: 0, height: 100) } catch { threwPixelZero = true }
        assertTrue(threwPixelZero)

        var threwPixelNeg = false
        do { try validatePixelDimensions(width: -1, height: -1) } catch { threwPixelNeg = true }
        assertTrue(threwPixelNeg)

        var threwPixelOverflow = false
        do { try validatePixelDimensions(width: Int.max, height: Int.max) } catch { threwPixelOverflow = true }
        assertTrue(threwPixelOverflow)

        var threwPixelOver64MP = false
        do { try validatePixelDimensions(width: 8001, height: 8000) } catch { threwPixelOver64MP = true }
        assertTrue(threwPixelOver64MP)
    }

    public static func run20_SOF0AndSOF2MarkerValidation() async throws {
        let sof0Data = Data([
            0xFF, 0xD8,
            0xFF, 0xC0, 0x00, 0x11, 0x08, 0x02, 0x00, 0x03, 0x20, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
            0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00,
            0xFF, 0xD9
        ])
        let dimsSOF0 = SCScreenshotCaptureEngine.parseJPEGDimensions(data: sof0Data)
        assertTrue(dimsSOF0 != nil)
        assertEqual(dimsSOF0?.width, 800)
        assertEqual(dimsSOF0?.height, 512)

        let sof2Data = Data([
            0xFF, 0xD8,
            0xFF, 0xC2, 0x00, 0x11, 0x08, 0x01, 0x00, 0x02, 0x00, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
            0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00,
            0xFF, 0xD9
        ])
        let dimsSOF2 = SCScreenshotCaptureEngine.parseJPEGDimensions(data: sof2Data)
        assertTrue(dimsSOF2 != nil)
        assertEqual(dimsSOF2?.width, 512)
        assertEqual(dimsSOF2?.height, 256)

        // Test COM (0xFE) segment before SOF
        let comData = Data([
            0xFF, 0xD8,
            0xFF, 0xFE, 0x00, 0x07, 0x48, 0x65, 0x6C, 0x6C, 0x6F,
            0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0x00, 0x02, 0x00, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
            0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00,
            0xFF, 0xD9
        ])
        let dimsCOM = SCScreenshotCaptureEngine.parseJPEGDimensions(data: comData)
        assertTrue(dimsCOM != nil, "COM (0xFE) segment before SOF must be parsed successfully")
        assertEqual(dimsCOM?.width, 512)
        assertEqual(dimsCOM?.height, 256)

        // Test Multi-scan Progressive JPEG with inter-scan DHT/DQT markers
        let multiScanData = Data([
            0xFF, 0xD8,
            0xFF, 0xC2, 0x00, 0x11, 0x08, 0x01, 0x00, 0x02, 0x00, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
            0xFF, 0xDB, 0x00, 0x05, 0x00, 0x01, 0x02,
            0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00,
            0xFF, 0xC4, 0x00, 0x05, 0x00, 0x00, 0x00,
            0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00,
            0xFF, 0xD9
        ])
        let dimsMulti = SCScreenshotCaptureEngine.parseJPEGDimensions(data: multiScanData)
        assertTrue(dimsMulti != nil, "Multi-scan progressive JPEG must be parsed successfully")
        assertEqual(dimsMulti?.width, 512)
        assertEqual(dimsMulti?.height, 256)

        // Negative: Nested SOI inside stream
        let nestedSOIData = Data([
            0xFF, 0xD8,
            0xFF, 0xD8,
            0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0x00, 0x02, 0x00, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
            0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00,
            0xFF, 0xD9
        ])
        assertTrue(SCScreenshotCaptureEngine.parseJPEGDimensions(data: nestedSOIData) == nil, "Must reject nested SOI")

        // Negative: Zero-component SOS (Ns == 0)
        let zeroCompSOSData = Data([
            0xFF, 0xD8,
            0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0x00, 0x02, 0x00, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
            0xFF, 0xDA, 0x00, 0x06, 0x00, 0x00, 0x3F, 0x00,
            0xFF, 0xD9
        ])
        assertTrue(SCScreenshotCaptureEngine.parseJPEGDimensions(data: zeroCompSOSData) == nil, "Must reject zero-component SOS")
    }

    public static func run21_JPEGInvalidMagicTruncatedSegmentAndMismatchRejection() async throws {
        let sof0Data = Data([
            0xFF, 0xD8,
            0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x64, 0x00, 0x64, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
            0xFF, 0xDA, 0x00, 0x08, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11,
            0xFF, 0xD9
        ])
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
    }

    public static func run22_NoncooperativeLateCompletionGenerationFence() async throws {
        let controlledEngine = ControlledCaptureEngine()
        let sleeper = ManualSleeper()
        let fenceServer = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: controlledEngine,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector(),
            observationTimeoutSec: 5.0,
            sleeper: sleeper
        )

        let reqATask = Task { await fenceServer.handleRequest(IPCRequest(id: "fence-A", method: "observe")) }
        await controlledEngine.waitUntilRegistered(count: 1)
        await sleeper.waitUntilArmed(count: 1)
        await sleeper.advance()

        let respA = await reqATask.value
        assertTrue(!respA.success)
        assertEqual(respA.error?.code, "TIMEOUT")

        let reqBTask = Task { await fenceServer.handleRequest(IPCRequest(id: "fence-B", method: "observe")) }
        await controlledEngine.waitUntilRegistered(count: 2)
        let frameB = try FakeCaptureEngine().generateDTO(topology: FakeDisplayTopologyProvider().getTopology())
        try await controlledEngine.complete(index: 1, with: .success(frameB))

        let respB = await reqBTask.value
        assertTrue(respB.success)
        assertEqual(await fenceServer.latestCaptureSnapshot?.captureId, frameB.captureId)
        assertEqual(await fenceServer.latestIssuedGenerationSnapshot, 2)

        let frameA = try FakeCaptureEngine().generateDTO(topology: FakeDisplayTopologyProvider().getTopology())
        try await controlledEngine.complete(index: 0, with: .success(frameA))
        await controlledEngine.waitUntilExited(count: 2)

        assertEqual(await fenceServer.latestCaptureSnapshot?.captureId, frameB.captureId)
        assertEqual(await fenceServer.latestIssuedGenerationSnapshot, 2)
    }

    public static func run23_StaleOperationGenerationFence() async throws {
        let controlledEngine = ControlledCaptureEngine()
        let server = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: controlledEngine,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector(),
            observationTimeoutSec: 10.0
        )

        let task1 = Task { await server.handleRequest(IPCRequest(id: "stale-1", method: "observe")) }
        await controlledEngine.waitUntilRegistered(count: 1)

        let task2 = Task { await server.handleRequest(IPCRequest(id: "stale-2", method: "observe")) }
        await controlledEngine.waitUntilRegistered(count: 2)

        let frame2 = try FakeCaptureEngine().generateDTO(topology: FakeDisplayTopologyProvider().getTopology())
        try await controlledEngine.complete(index: 1, with: .success(frame2))
        let resp2 = await task2.value
        assertTrue(resp2.success)

        let frame1 = try FakeCaptureEngine().generateDTO(topology: FakeDisplayTopologyProvider().getTopology())
        try await controlledEngine.complete(index: 0, with: .success(frame1))
        let resp1 = await task1.value
        assertTrue(!resp1.success)
        assertEqual(resp1.error?.code, "STALE_OPERATION")

        assertEqual(await server.latestCaptureSnapshot?.captureId, frame2.captureId)
        assertEqual(await server.latestIssuedGenerationSnapshot, 2)
    }

    public static func run24_RequesterCancellation() async throws {
        let budget = CaptureBudget(maxConcurrent: 1)
        let controlledEngine = ControlledCaptureEngine()
        let server = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: controlledEngine,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector(),
            observationTimeoutSec: 5.0,
            budget: budget
        )

        let reqTask = Task {
            await server.handleRequest(IPCRequest(id: "req-cancel", method: "observe"))
        }
        await controlledEngine.waitUntilRegistered(count: 1)

        reqTask.cancel()

        let resp = await reqTask.value
        assertTrue(!resp.success)
        assertEqual(resp.error?.code, "CANCELLED")

        assertEqual(budget.count, 1, "Budget must remain occupied by active physical capture after cancellation")

        let frame = try FakeCaptureEngine().generateDTO(topology: FakeDisplayTopologyProvider().getTopology())
        try await controlledEngine.complete(index: 0, with: .success(frame))
        await controlledEngine.waitUntilExited(count: 1)
        for _ in 0..<100 {
            if budget.count == 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        assertEqual(budget.count, 0, "Budget must be released on physical capture exit")
        assertEqual(await server.latestCaptureSnapshot, nil, "Cancelled request must never promote capture frame")
    }

    public static func run25_TimedOutOrphanCapacity() async throws {
        let budget = CaptureBudget(maxConcurrent: 1)
        let controlledEngine = ControlledCaptureEngine()
        let sleeper = ManualSleeper()
        let server = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: controlledEngine,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector(),
            observationTimeoutSec: 5.0,
            budget: budget,
            sleeper: sleeper
        )

        let taskA = Task { await server.handleRequest(IPCRequest(id: "orphan-A", method: "observe")) }
        await controlledEngine.waitUntilRegistered(count: 1)
        await sleeper.waitUntilArmed(count: 1)
        await sleeper.advance()

        let respA = await taskA.value
        assertTrue(!respA.success)
        assertEqual(respA.error?.code, "TIMEOUT")
        assertEqual(budget.count, 1, "Budget must remain occupied while orphan task A runs")

        let invocationsBeforeB = await controlledEngine.invocationCount
        let genBeforeB = await server.latestIssuedGenerationSnapshot

        let respB = await server.handleRequest(IPCRequest(id: "orphan-B", method: "observe"))
        assertTrue(!respB.success)
        assertEqual(respB.error?.code, "CAPTURE_BUSY")
        assertEqual(await controlledEngine.invocationCount, invocationsBeforeB, "Busy request B must cause zero capture engine invocations")
        assertEqual(await server.latestIssuedGenerationSnapshot, genBeforeB, "Busy request B must cause zero generation changes")

        let frameA = try FakeCaptureEngine().generateDTO(topology: FakeDisplayTopologyProvider().getTopology())
        try await controlledEngine.complete(index: 0, with: .success(frameA))
        await controlledEngine.waitUntilExited(count: 1)
        for _ in 0..<100 {
            if budget.count == 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        assertEqual(budget.count, 0, "Budget must be released after orphan task A exits")

        let taskC = Task { await server.handleRequest(IPCRequest(id: "orphan-C", method: "observe")) }
        await controlledEngine.waitUntilRegistered(count: 2)
        let frameC = try FakeCaptureEngine().generateDTO(topology: FakeDisplayTopologyProvider().getTopology())
        try await controlledEngine.complete(index: 1, with: .success(frameC))

        let respC = await taskC.value
        assertTrue(respC.success)
        assertEqual(await server.latestCaptureSnapshot?.captureId, frameC.captureId)
    }

    public static func run26_TopologyChangeDuringCaptureDiscarded() async throws {
        let fakeEngine = FakeCaptureEngine(customTopologyVersion: "top-sha256-old-version-stale-token")
        let server = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: fakeEngine,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector()
        )

        let resp = await server.handleRequest(IPCRequest(id: "top-change-req", method: "observe"))
        assertTrue(!resp.success)
        assertEqual(resp.error?.code, "STALE_TOPOLOGY")
    }

    public static func run27_DisabledActionsAndAXTreeRejection() async throws {
        let server = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: FakeCaptureEngine(),
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector()
        )

        let axResp = await server.handleRequest(IPCRequest(id: "ax-req", method: "ax_tree"))
        assertTrue(!axResp.success)
        assertEqual(axResp.error?.code, "TARGET_UNREACHABLE")

        let clickResp = await server.handleRequest(IPCRequest(id: "click-req", method: "click"))
        assertTrue(!clickResp.success)
        assertEqual(clickResp.error?.code, "MUTATION_DISABLED")
    }

    public static func run28_DisplayIdParameterValidation() async throws {
        let server = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: FakeCaptureEngine(),
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector()
        )

        let reqBadType = IPCRequest(id: "bad-id-1", method: "observe", params: ["display_id": .string("1")])
        let respBadType = await server.handleRequest(reqBadType)
        assertTrue(!respBadType.success)
        assertEqual(respBadType.error?.code, "IPC_ERROR")

        let reqNotFound = IPCRequest(id: "bad-id-2", method: "observe", params: ["display_id": .int(9999)])
        let respNotFound = await server.handleRequest(reqNotFound)
        assertTrue(!respNotFound.success)
        assertEqual(respNotFound.error?.code, "TARGET_UNREACHABLE")
    }

    public static func run29_CancellationErrorMappedToCancelledCode() async throws {
        struct CancellingCaptureEngine: DisplayCaptureEngine {
            func captureDisplay(displayId: Int?, topology: DisplayTopology) async throws -> CaptureFrameDTO {
                throw CancellationError()
            }
        }

        let server = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: CancellingCaptureEngine(),
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector()
        )

        let resp = await server.handleRequest(IPCRequest(id: "cancel-req", method: "observe"))
        assertTrue(!resp.success)
        assertEqual(resp.error?.code, "CANCELLED")
    }

    public static func run30_PartialStartRollback() async throws {
        let parentDir30 = "/tmp/agy-test-c30-\(UUID().uuidString)"
        let sockPath30 = "\(parentDir30)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath30)

        _ = mkdir(sockPath30, 0o700)

        let lockPath30 = "\(parentDir30)/host.lock"
        let listener30 = SocketListener(
            socketPath: sockPath30,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )

        var threwRollback30 = false
        do {
            try listener30.start()
        } catch let err as ComputerUseError {
            if case .ipcError = err {
                threwRollback30 = true
            }
        }
        assertTrue(threwRollback30, "Listener start must fail when bind fails")

        _ = rmdir(sockPath30)

        var statLock30 = stat()
        assertTrue(lstat(lockPath30, &statLock30) == 0, "host.lock file must persist on disk after partial-start rollback")
        let testLockFd30 = open(lockPath30, O_RDWR | O_CLOEXEC)
        assertTrue(testLockFd30 >= 0, "host.lock must be readable/writable after rollback")
        assertEqual(flock(testLockFd30, LOCK_EX | LOCK_NB), 0, "Persistent host.lock inode must be unlocked after rollback")
        close(testLockFd30)

        try listener30.start()
        let clientFd30 = try connectToSocket(at: listener30.socketPath)
        close(clientFd30)
        listener30.stop()
    }

    public static func run31_AcceptEINTRRetry() async throws {
        let parentDir = "/tmp/agy-test-c31-\(UUID().uuidString)"
        let sockPath = "\(parentDir)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath)

        let scriptedSyscalls = ScriptedPOSIXSyscalls()
        var acceptAttempts = 0
        scriptedSyscalls.acceptHook = { fd, saPtr, lenPtr in
            acceptAttempts += 1
            if acceptAttempts == 1 {
                scriptedSyscalls.setErrno(EINTR)
                return -1
            }
            return nil
        }

        let listener = SocketListener(
            socketPath: sockPath,
            server: HostServer(authorizer: FakeScreenRecordingAuthorizer(), topologyProvider: FakeDisplayTopologyProvider(), captureEngine: FakeCaptureEngine(), axEngine: DisabledAXInspector(), inputEngine: DisabledInputInjector()),
            syscalls: scriptedSyscalls
        )
        try listener.start()
        defer { listener.stop() }

        let clientFd = try connectToSocket(at: sockPath)
        defer { close(clientFd) }

        let handled = try await listener.acceptAndHandleOneConnection()
        assertTrue(handled)
        assertEqual(scriptedSyscalls.acceptCallCount, 2, "accept must be called exactly 2 times (1 EINTR retry + 1 success)")
    }

    public static func run32_ReadHeaderBodyEINTRRetry() async throws {
        let parentDir = "/tmp/agy-test-c32-\(UUID().uuidString)"
        let sockPath = "\(parentDir)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath)

        let scriptedSyscalls = ScriptedPOSIXSyscalls()
        var headerReadAttempts = 0
        var bodyReadAttempts = 0

        scriptedSyscalls.readHook = { fd, buf, count in
            if count == 4 {
                headerReadAttempts += 1
                if headerReadAttempts == 1 {
                    scriptedSyscalls.setErrno(EINTR)
                    return -1
                }
            } else if count > 4 {
                bodyReadAttempts += 1
                if bodyReadAttempts == 1 {
                    scriptedSyscalls.setErrno(EINTR)
                    return -1
                }
            }
            return nil
        }

        let listener = SocketListener(
            socketPath: sockPath,
            server: HostServer(authorizer: FakeScreenRecordingAuthorizer(), topologyProvider: FakeDisplayTopologyProvider(), captureEngine: FakeCaptureEngine(), axEngine: DisabledAXInspector(), inputEngine: DisabledInputInjector()),
            syscalls: scriptedSyscalls
        )
        try listener.start()
        defer { listener.stop() }

        let clientFd = try connectToSocket(at: sockPath)
        defer { close(clientFd) }

        try sendIPCRequest(IPCRequest(id: "test-eintr", method: "observe"), to: clientFd)
        let handled = try await listener.acceptAndHandleOneConnection()
        assertTrue(handled)

        assertEqual(headerReadAttempts, 2, "Header read must retry exactly once after single EINTR")
        assertEqual(bodyReadAttempts, 2, "Body read must retry exactly once after single EINTR")
    }

    public static func run33_WriteResponseEAGAINDeadlineAndSingleAttempt() async throws {
        let parentDir = "/tmp/agy-test-c33-\(UUID().uuidString)"
        let sockPath = "\(parentDir)/host.sock"
        let manualClock = TestManualClock()
        let scriptedSyscalls = ScriptedPOSIXSyscalls()
        var writeCallSequence = 0

        scriptedSyscalls.writeHook = { fd, buf, count in
            writeCallSequence += 1
            if writeCallSequence == 1 {
                return 2
            }
            manualClock.advance(by: .seconds(1))
            scriptedSyscalls.setErrno(EAGAIN)
            return -1
        }

        let listener = SocketListener(
            socketPath: sockPath,
            server: HostServer(authorizer: FakeScreenRecordingAuthorizer(), topologyProvider: FakeDisplayTopologyProvider(), captureEngine: FakeCaptureEngine(), axEngine: DisabledAXInspector(), inputEngine: DisabledInputInjector()),
            perFrameTimeoutSec: 0.1,
            syscalls: scriptedSyscalls,
            clock: manualClock
        )
        try listener.start()
        defer { listener.stop() }

        let clientFd = try connectToSocket(at: sockPath)
        defer { close(clientFd) }

        try sendIPCRequest(IPCRequest(id: "test-write-eagain", method: "observe"), to: clientFd)
        let handled = try await listener.acceptAndHandleOneConnection()
        assertTrue(handled)

        assertTrue(writeCallSequence > 1, "Write must retry on EAGAIN until deadline")
        assertEqual(scriptedSyscalls.writeCallCount, writeCallSequence, "No secondary response write must be initiated in catch block")
    }

    public static func run34_PositiveByteAdvancesClockPastDeadlineReturnsTimeout() async throws {
        let parentDir = "/tmp/agy-test-c34-\(UUID().uuidString)"
        let sockPath = "\(parentDir)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath)

        let manualClock = TestManualClock()
        let scriptedSyscalls = ScriptedPOSIXSyscalls()

        scriptedSyscalls.readHook = { fd, buf, count in
            manualClock.advance(by: .seconds(5))
            return 2
        }

        let listener = SocketListener(
            socketPath: sockPath,
            server: HostServer(authorizer: FakeScreenRecordingAuthorizer(), topologyProvider: FakeDisplayTopologyProvider(), captureEngine: FakeCaptureEngine(), axEngine: DisabledAXInspector(), inputEngine: DisabledInputInjector()),
            syscalls: scriptedSyscalls,
            clock: manualClock
        )
        try listener.start()
        defer { listener.stop() }

        let clientFd = try connectToSocket(at: sockPath)
        defer { close(clientFd) }

        let handled = try await listener.acceptAndHandleOneConnection()
        assertTrue(handled)
        let resp = try readIPCResponse(from: clientFd)
        assertTrue(!resp.success)
        assertEqual(resp.error?.code, "TIMEOUT")
    }

    public static func run35_InjectedListenFailurePostBindRollback() async throws {
        let parentDir = "/tmp/agy-test-c35-\(UUID().uuidString)"
        let sockPath = "\(parentDir)/host.sock"
        let lockPath = "\(parentDir)/host.lock"
        try SocketListener.prepareDirectory(at: sockPath)

        let scriptedSyscalls = ScriptedPOSIXSyscalls()
        var listenAttempt = 0
        scriptedSyscalls.listenHook = { fd, backlog in
            listenAttempt += 1
            if listenAttempt == 1 {
                scriptedSyscalls.setErrno(EOPNOTSUPP)
                return -1
            }
            return nil
        }

        let listener = SocketListener(
            socketPath: sockPath,
            server: HostServer(authorizer: FakeScreenRecordingAuthorizer(), topologyProvider: FakeDisplayTopologyProvider(), captureEngine: FakeCaptureEngine(), axEngine: DisabledAXInspector(), inputEngine: DisabledInputInjector()),
            syscalls: scriptedSyscalls
        )

        var threwListenError = false
        do {
            try listener.start()
        } catch let err as ComputerUseError {
            if case .ipcError = err { threwListenError = true }
        }
        assertTrue(threwListenError, "start() must fail when listen returns non-zero")
        assertEqual(listenAttempt, 1, "Initial start attempt must execute listen exactly once")

        var statBuf = stat()
        assertTrue(lstat(sockPath, &statBuf) != 0, "Bound socket file must be unlinked on listen rollback")

        assertTrue(lstat(lockPath, &statBuf) == 0, "host.lock must persist on disk after listen failure")
        let initialLockInode = statBuf.st_ino

        try listener.start()
        defer { listener.stop() }

        assertEqual(listenAttempt, 2, "Second start attempt must execute listen a second time successfully")
        assertTrue(lstat(lockPath, &statBuf) == 0)
        assertEqual(statBuf.st_ino, initialLockInode, "host.lock inode must remain unchanged")

        let clientFd = try connectToSocket(at: listener.socketPath)
        close(clientFd)
    }

    private static func runWithWatchdog(name: String, timeoutSec: Double = 10.0, _ block: @Sendable @escaping () async throws -> Void) async throws {
        let sem = DispatchSemaphore(value: 0)
        let errorBox = ErrorBox()
        let task = Task {
            do {
                try await block()
            } catch {
                errorBox.set(error)
            }
            sem.signal()
        }

        let watchdogThread = Thread {
            let timeoutResult = sem.wait(timeout: .now() + .seconds(Int(timeoutSec)))
            if timeoutResult == .timedOut {
                fputs("[FAIL] Hard watchdog timeout for test: \(name)\n", stderr)
                task.cancel()
                _exit(1)
            }
        }
        watchdogThread.start()
        _ = await task.value
        if let err = errorBox.value { throw err }
    }

    public static func main() async throws {
        signal(SIGPIPE, SIG_IGN)
        fputs("[ComputerUseHostTestRunner] Starting Native Test Runner Authority...\n", stderr)
        try await runWithWatchdog(name: "test01_LengthPrefixedFraming") { try await run01_LengthPrefixedFraming() }
        try await runWithWatchdog(name: "test02_OversizedFramingHeaderRejection") { try await run02_OversizedFramingHeaderRejection() }
        try await runWithWatchdog(name: "test03_DirectoryPreparation") { try await run03_DirectoryPreparation() }
        try await runWithWatchdog(name: "test04_UDSClientServerRoundTrip") { try await run04_UDSClientServerRoundTrip() }
        try await runWithWatchdog(name: "test05_PostTimeoutUDSRecovery") { try await run05_PostTimeoutUDSRecovery() }
        try await runWithWatchdog(name: "test06_SlowDripHeaderTimeout") { try await run06_SlowDripHeaderTimeout() }
        try await runWithWatchdog(name: "test07_SlowDripBodyTimeout") { try await run07_SlowDripBodyTimeout() }
        try await runWithWatchdog(name: "test08_BlockedResponseWriteTimeout") { try await run08_BlockedResponseWriteTimeout() }
        try await runWithWatchdog(name: "test09_PeerCloseAndPartialIO") { try await run09_PeerCloseAndPartialIO() }
        try await runWithWatchdog(name: "test10_EINTRRetryPath") { try await run10_EINTRRetryPath() }
        try await runWithWatchdog(name: "test11_TimeoutResponseFollowedByNextClient") { try await run11_TimeoutResponseFollowedByNextClient() }
        try await runWithWatchdog(name: "test12_LiveSocketCollisionProbe") { try await run12_LiveSocketCollisionProbe() }
        try await runWithWatchdog(name: "test13_VerifiedStaleSocketRecovery") { try await run13_VerifiedStaleSocketRecovery() }
        try await runWithWatchdog(name: "test14_ForeignSymlinkNonSocketRefusal") { try await run14_ForeignSymlinkNonSocketRefusal() }
        try await runWithWatchdog(name: "test15_StopNeverUnlinksReplacementInode") { try await run15_StopNeverUnlinksReplacementInode() }
        try await runWithWatchdog(name: "test16_IEEE754BitPatternTopologyGoldenVectorAndMutations") { try await run16_IEEE754BitPatternTopologyGoldenVectorAndMutations() }
        try await runWithWatchdog(name: "test17_HotPlugSafeDisplayEnumerator") { try await run17_HotPlugSafeDisplayEnumerator() }
        try await runWithWatchdog(name: "test18_PermissionPreflightDeniedZeroLoaderCalls") { try await run18_PermissionPreflightDeniedZeroLoaderCalls() }
        try await runWithWatchdog(name: "test19_PureJPEGValidatorExactAndNear10MiBBoundaries") { try await run19_PureJPEGValidatorExactAndNear10MiBBoundaries() }
        try await runWithWatchdog(name: "test20_SOF0AndSOF2MarkerValidation") { try await run20_SOF0AndSOF2MarkerValidation() }
        try await runWithWatchdog(name: "test21_JPEGInvalidMagicTruncatedSegmentAndMismatchRejection") { try await run21_JPEGInvalidMagicTruncatedSegmentAndMismatchRejection() }
        try await runWithWatchdog(name: "test22_NoncooperativeLateCompletionGenerationFence") { try await run22_NoncooperativeLateCompletionGenerationFence() }
        try await runWithWatchdog(name: "test23_StaleOperationGenerationFence") { try await run23_StaleOperationGenerationFence() }
        try await runWithWatchdog(name: "test24_RequesterCancellation") { try await run24_RequesterCancellation() }
        try await runWithWatchdog(name: "test25_TimedOutOrphanCapacity") { try await run25_TimedOutOrphanCapacity() }
        try await runWithWatchdog(name: "test26_TopologyChangeDuringCaptureDiscarded") { try await run26_TopologyChangeDuringCaptureDiscarded() }
        try await runWithWatchdog(name: "test27_DisabledActionsAndAXTreeRejection") { try await run27_DisabledActionsAndAXTreeRejection() }
        try await runWithWatchdog(name: "test28_DisplayIdParameterValidation") { try await run28_DisplayIdParameterValidation() }
        try await runWithWatchdog(name: "test29_CancellationErrorMappedToCancelledCode") { try await run29_CancellationErrorMappedToCancelledCode() }
        try await runWithWatchdog(name: "test30_PartialStartRollback") { try await run30_PartialStartRollback() }
        try await runWithWatchdog(name: "test31_AcceptEINTRRetry") { try await run31_AcceptEINTRRetry() }
        try await runWithWatchdog(name: "test32_ReadHeaderBodyEINTRRetry") { try await run32_ReadHeaderBodyEINTRRetry() }
        try await runWithWatchdog(name: "test33_WriteResponseEAGAINDeadlineAndSingleAttempt") { try await run33_WriteResponseEAGAINDeadlineAndSingleAttempt() }
        try await runWithWatchdog(name: "test34_PositiveByteAdvancesClockPastDeadlineReturnsTimeout") { try await run34_PositiveByteAdvancesClockPastDeadlineReturnsTimeout() }
        try await runWithWatchdog(name: "test35_InjectedListenFailurePostBindRollback") { try await run35_InjectedListenFailurePostBindRollback() }
        fputs("[ComputerUseHostTestRunner] Executed 35 native test cases successfully. ALL PASSED.\n", stderr)
    }
}
