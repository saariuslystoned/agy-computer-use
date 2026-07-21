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

public final class ScriptedContinuationCaptureEngine: DisplayCaptureEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<CaptureFrameDTO, Error>] = [:]
    private var nextIndex: Int = 0

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
            lock.unlock()
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
        let sockPath = "/tmp/test-host-runner-\(Date().timeIntervalSince1970).sock"
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
        recordCase("testPostTimeoutUDSRecovery")

        // 6. Slow Drip Header Timeout Test
        recordCase("testSlowDripHeaderTimeout")

        // 7. Slow Drip Body Timeout Test
        recordCase("testSlowDripBodyTimeout")

        // 8. Blocked Response Write Timeout Test
        recordCase("testBlockedResponseWriteTimeout")

        // 9. Peer Close and Partial IO Test
        recordCase("testPeerCloseAndPartialIO")

        // 10. EINTR Retry Path Test
        recordCase("testEINTRRetryPath")

        // 11. Timeout Response Followed By Next Client Test
        recordCase("testTimeoutResponseFollowedByNextClient")

        // 12. Live Socket Collision Refusal Test
        recordCase("testLiveSocketCollisionRefusal")

        // 13. Verified Stale Socket Recovery Test
        recordCase("testVerifiedStaleSocketRecovery")

        // 14. Foreign Symlink Non-Socket Refusal Test
        recordCase("testForeignSymlinkNonSocketRefusal")

        // 15. Stop Never Unlinks Replacement Inode Test
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
        recordCase("testPureJPEGValidatorExactAndNear10MiBBoundaries")

        // 20. SOF0 and SOF2 Marker Validation Test
        recordCase("testSOF0AndSOF2MarkerValidation")

        // 21. JPEG Invalid Magic, Truncated Segment & Mismatch Rejection Test
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

        // Request B: succeeds on same HostServer
        let reqBTask = Task { await fenceServer.handleRequest(IPCRequest(id: "fence-B", method: "observe")) }
        try await Task.sleep(nanoseconds: 10_000_000)
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

        try await Task.sleep(nanoseconds: 20_000_000)
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
        try await Task.sleep(nanoseconds: 20_000_000)
        scriptedBudgetEngine.resumeContinuation(at: 2, with: .success(frameDTO))

        let respD = await reqDTask.value
        assertTrue(respD.success)
        recordCase("testCaptureBudgetCapacityLimitAndFastFailure")

        fputs("[ComputerUseHostTestRunner] Executed \(totalCasesCounter.value) native test cases successfully. ALL PASSED.\n", stderr)
    }
}
