import Foundation
import ApplicationServices

public typealias BudgetCountObserver = @Sendable (Int) -> Void

public final class CaptureBudget: @unchecked Sendable {
    public let maxConcurrent: Int
    private var activeCount: Int = 0
    private let lock = NSLock()
    private let countObserver: BudgetCountObserver?

    public init(maxConcurrent: Int = 2, countObserver: BudgetCountObserver? = nil) {
        self.maxConcurrent = maxConcurrent
        self.countObserver = countObserver
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeCount
    }

    public func acquire() -> Bool {
        var newCount: Int? = nil
        lock.lock()
        if activeCount < maxConcurrent {
            activeCount += 1
            newCount = activeCount
        }
        lock.unlock()

        if let count = newCount {
            countObserver?(count)
            return true
        }
        return false
    }

    public func release() {
        var newCount: Int? = nil
        lock.lock()
        if activeCount > 0 {
            activeCount -= 1
            newCount = activeCount
        }
        lock.unlock()

        if let count = newCount {
            countObserver?(count)
        }
    }
}

public enum ArbiterResolutionOutcome: String, Equatable, Sendable {
    case success
    case timeout
    case cancelled
    case failure
}

public typealias ArbiterResolutionObserver = @Sendable (ArbiterResolutionOutcome) -> Void

private final class OneShotArbiter<T: Sendable>: @unchecked Sendable {
    private enum State {
        case pending(CheckedContinuation<T, Error>?, captureTask: Task<Void, Never>?, timerTask: Task<Void, Never>?)
        case resolved(Result<T, Error>)
    }

    private let lock = NSLock()
    private var state: State = .pending(nil, captureTask: nil, timerTask: nil)
    private let resolutionObserver: ArbiterResolutionObserver?

    init(resolutionObserver: ArbiterResolutionObserver? = nil) {
        self.resolutionObserver = resolutionObserver
    }

    func installContinuation(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        switch state {
        case .pending(_, let cTask, let tTask):
            state = .pending(continuation, captureTask: cTask, timerTask: tTask)
            lock.unlock()
        case .resolved(let result):
            lock.unlock()
            continuation.resume(with: result)
        }
    }

    func installCaptureTask(_ task: Task<Void, Never>) {
        lock.lock()
        switch state {
        case .pending(let cont, _, let tTask):
            state = .pending(cont, captureTask: task, timerTask: tTask)
            lock.unlock()
        case .resolved:
            lock.unlock()
            task.cancel()
        }
    }

    func installTimerTask(_ task: Task<Void, Never>) {
        lock.lock()
        switch state {
        case .pending(let cont, let cTask, _):
            state = .pending(cont, captureTask: cTask, timerTask: task)
            lock.unlock()
        case .resolved:
            lock.unlock()
            task.cancel()
        }
    }

    func resolve(with result: Result<T, Error>) {
        var contToResume: CheckedContinuation<T, Error>? = nil
        var captureToCancel: Task<Void, Never>? = nil
        var timerToCancel: Task<Void, Never>? = nil
        var winningOutcome: ArbiterResolutionOutcome? = nil

        lock.lock()
        switch state {
        case .pending(let cont, let cTask, let tTask):
            contToResume = cont
            state = .resolved(result)

            switch result {
            case .success:
                timerToCancel = tTask
                winningOutcome = .success
            case .failure(let err as ComputerUseError):
                if case .timeout = err {
                    captureToCancel = cTask
                    winningOutcome = .timeout
                } else if case .cancelled = err {
                    captureToCancel = cTask
                    timerToCancel = tTask
                    winningOutcome = .cancelled
                } else {
                    timerToCancel = tTask
                    winningOutcome = .failure
                }
            case .failure(is CancellationError):
                captureToCancel = cTask
                timerToCancel = tTask
                winningOutcome = .cancelled
            case .failure:
                timerToCancel = tTask
                captureToCancel = cTask
                winningOutcome = .failure
            }
            lock.unlock()
        case .resolved:
            lock.unlock()
            return
        }

        if let outcome = winningOutcome {
            resolutionObserver?(outcome)
        }

        captureToCancel?.cancel()
        timerToCancel?.cancel()

        if let cont = contToResume {
            cont.resume(with: result)
        }
    }
}

public protocol Sleeper: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}

public struct DefaultSleeper: Sleeper {
    public init() {}
    public func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

public protocol HostClock: Sendable {
    var now: ContinuousClock.Instant { get }
}

public struct DefaultHostClock: HostClock {
    public init() {}
    public var now: ContinuousClock.Instant {
        ContinuousClock().now
    }
}

public actor HostServer {
    private var isConnected: Bool = false
    private let authorizer: ScreenRecordingAuthorizing
    private let topologyProvider: DisplayTopologyProviding
    private let captureEngine: DisplayCaptureEngine
    private let axEngine: AXInspectionEngine
    private let axActionEngine: AXSemanticActionEngine
    private let inputEngine: InputSynthesisEngine
    private let observationTimeoutSec: Double
    private let budget: CaptureBudget
    private let sleeper: Sleeper
    private let clock: HostClock
    private let resolutionObserver: ArbiterResolutionObserver?

    private var latestCapture: CaptureFrameDTO?
    private var activeTopology: DisplayTopology?
    private var latestIssuedGeneration: UInt64 = 0

    public var latestCaptureSnapshot: CaptureFrameDTO? {
        return self.latestCapture
    }

    public var latestIssuedGenerationSnapshot: UInt64 {
        return self.latestIssuedGeneration
    }

    public init(
        authorizer: ScreenRecordingAuthorizing = CGScreenRecordingAuthorizer(),
        topologyProvider: DisplayTopologyProviding = SystemDisplayTopologyProvider(),
        captureEngine: DisplayCaptureEngine? = nil,
        axEngine: AXInspectionEngine = DisabledAXInspector(),
        axActionEngine: AXSemanticActionEngine = DisabledAXSemanticActionEngine(),
        inputEngine: InputSynthesisEngine = CGEventInputSynthesisEngine(),
        observationTimeoutSec: Double = 5.0,
        budget: CaptureBudget = CaptureBudget(maxConcurrent: 2),
        sleeper: Sleeper = DefaultSleeper(),
        clock: HostClock = DefaultHostClock(),
        resolutionObserver: ArbiterResolutionObserver? = nil
    ) {
        self.authorizer = authorizer
        self.topologyProvider = topologyProvider
        self.captureEngine = captureEngine ?? SCScreenshotCaptureEngine(authorizer: authorizer)
        self.axEngine = axEngine
        self.axActionEngine = axActionEngine
        self.inputEngine = inputEngine
        self.observationTimeoutSec = observationTimeoutSec
        self.budget = budget
        self.sleeper = sleeper
        self.clock = clock
        self.resolutionObserver = resolutionObserver
    }

    public func handleRequest(_ request: IPCRequest) async -> IPCResponse {
        do {
            switch request.method {
            case "status":
                self.isConnected = true
                let currentTopology = try topologyProvider.getTopology()
                self.activeTopology = currentTopology
                let isGranted = authorizer.isScreenCaptureAccessGranted
                let osAxTrusted = inputEngine.isMutationEnabled
                let operatorSafeAXAvailable =
                    axEngine.isAvailable &&
                    axActionEngine.isOperatorSafeActionAvailable &&
                    axActionEngine.supportedOperatorSafeActions == ["press"]
                let supportedActionStrategies: [AnyCodable] =
                    (operatorSafeAXAvailable ? [.string("ax_semantic")] : []) +
                    (osAxTrusted ? [.string("exclusive_global_hid")] : [])

                let topologyDict: [String: AnyCodable] = [
                    "version": .string(currentTopology.version),
                    "primary_display_id": .int(currentTopology.primaryDisplayId),
                    "displays": .array(currentTopology.displays.map { display in
                        .dictionary([
                            "id": .int(display.id),
                            "width_points": .double(display.widthPoints),
                            "height_points": .double(display.heightPoints),
                            "scale_factor": .double(display.scaleFactor),
                            "origin_x": .double(display.originX),
                            "origin_y": .double(display.originY),
                            "pixel_width": .int(display.pixelWidth),
                            "pixel_height": .int(display.pixelHeight),
                            "rotation": .double(display.rotation)
                        ])
                    })
                ]

                return IPCResponse(
                    id: request.id,
                    success: true,
                    data: [
                        "connected": .bool(isConnected),
                        "pid": .int(Int(ProcessInfo.processInfo.processIdentifier)),
                        "tcc_permission_state": .string(isGranted ? "granted" : "denied"),
                        "accessibility_available": .bool(axEngine.isAvailable),
                        "accessibility_trusted": .bool(osAxTrusted),
                        "ax_tree_inspection_available": .bool(axEngine.isAvailable),
                        "operator_safe_ax_available": .bool(operatorSafeAXAvailable),
                        "operator_safe_ax_actions": operatorSafeAXAvailable
                            ? .array([.string("press")])
                            : .array([]),
                        "supported_action_strategies": .array(supportedActionStrategies),
                        "global_hid_may_affect_pointer_or_focus": .bool(true),
                        "input_mutation_state": .string(osAxTrusted ? "enabled" : "disabled"),
                        "topology_version": .string(currentTopology.version),
                        "primary_display_id": .int(currentTopology.primaryDisplayId),
                        "display_count": .int(currentTopology.displays.count),
                        "topology": .dictionary(topologyDict)
                    ]
                )

            case "observe":
                if Task.isCancelled {
                    return IPCResponse(
                        id: request.id,
                        success: false,
                        error: IPCErrorPayload(code: "CANCELLED", message: "Task was cancelled before processing")
                    )
                }

                guard authorizer.isScreenCaptureAccessGranted else {
                    throw ComputerUseError.permissionDenied(permission: "screen_recording")
                }

                let initialTopology = try topologyProvider.getTopology()

                let targetDisplayId: Int
                if let rawDisplayParam = request.params?["display_id"] {
                    switch rawDisplayParam {
                    case .int(let dId):
                        targetDisplayId = dId
                    default:
                        throw ComputerUseError.ipcError(reason: "display_id parameter must be an integer")
                    }
                } else {
                    targetDisplayId = initialTopology.primaryDisplayId
                }

                guard initialTopology.displays.contains(where: { $0.id == targetDisplayId }) else {
                    throw ComputerUseError.targetUnreachable(reason: "Display ID \(targetDisplayId) not found in initial topology")
                }

                // Acquire physical capture capacity BEFORE incrementing generation or clearing lease
                guard budget.acquire() else {
                    throw ComputerUseError.captureBusy(reason: "Physical capture capacity limit (\(budget.maxConcurrent)) reached; fast failing observe request")
                }

                self.activeTopology = initialTopology
                latestIssuedGeneration += 1
                let generation = latestIssuedGeneration
                self.latestCapture = nil

                // Nonisolated actor-safe deadline execution with budget release on physical exit
                let frame: CaptureFrameDTO
                do {
                    frame = try await HostServer.executeObservationWithDeadline(
                        captureEngine: captureEngine,
                        targetDisplayId: targetDisplayId,
                        initialTopology: initialTopology,
                        timeoutSec: self.observationTimeoutSec,
                        budget: budget,
                        sleeper: self.sleeper,
                        clock: self.clock,
                        resolutionObserver: self.resolutionObserver
                    )
                } catch {
                    throw error
                }

                if Task.isCancelled {
                    throw ComputerUseError.cancelled(reason: "Observation request cancelled")
                }

                // Promote frame using unified validator
                _ = try validateAndPromoteFrame(
                    frame: frame,
                    initialTopology: initialTopology,
                    generation: generation,
                    targetDisplayId: targetDisplayId
                )

                let dataDict: [String: AnyCodable] = [
                    "capture_id": .string(frame.captureId),
                    "timestamp": .int(Int(frame.timestamp)),
                    "topology_version": .string(frame.topologyVersion),
                    "display_id": .int(frame.displayId),
                    "width_points": .double(frame.widthPoints),
                    "height_points": .double(frame.heightPoints),
                    "scale_factor": .double(frame.scaleFactor),
                    "pixel_width": .int(frame.pixelWidth),
                    "pixel_height": .int(frame.pixelHeight),
                    "image_format": .string(frame.imageFormat),
                    "image_data_base64": .string(frame.imageDataBase64),
                    "image_byte_length": .int(frame.imageByteLength),
                    "image_sha256": .string(frame.imageSha256),
                    "normalized_bounds": .dictionary([
                        "min_x": .int(0),
                        "min_y": .int(0),
                        "max_x": .int(999),
                        "max_y": .int(999)
                    ])
                ]
                return IPCResponse(id: request.id, success: true, data: dataDict)

            case "ax_tree":
                guard axEngine.isAvailable else {
                    throw ComputerUseError.targetUnreachable(reason: "AX tree inspection is unavailable or untrusted in this build phase")
                }
                if let maxDepthRaw = request.params?["max_depth"]?.rawValue as? Int {
                    guard maxDepthRaw >= 1 && maxDepthRaw <= 10 else {
                        throw ComputerUseError.ipcError(reason: "max_depth parameter must be an integer between 1 and 10")
                    }
                }
                let maxDepth = request.params?["max_depth"]?.rawValue as? Int ?? 10
                guard let rawAppId = request.params?["app_id"]?.rawValue as? String else {
                    throw ComputerUseError.ipcError(reason: "app_id parameter is required and must be nonblank")
                }
                let appId = rawAppId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !appId.isEmpty else {
                    throw ComputerUseError.ipcError(reason: "app_id parameter is required and must be nonblank")
                }
                let currentTop = try topologyProvider.getTopology()
                let treeResult = try axEngine.inspectTree(maxDepth: maxDepth, appId: appId, topologyVersion: currentTop.version)
                let encoder = JSONEncoder()
                let treeData = try encoder.encode(treeResult)
                let treeDict = try JSONDecoder().decode([String: AnyCodable].self, from: treeData)
                return IPCResponse(id: request.id, success: true, data: treeDict)

            case "ax_action":
                guard let intent = request.params?["intent"]?.rawValue as? String,
                      !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ComputerUseError.ipcError(reason: "intent parameter is required and must be nonblank")
                }
                guard let action = request.params?["action"]?.rawValue as? String,
                      !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ComputerUseError.ipcError(reason: "action parameter is required and must be nonblank")
                }
                guard action == "press" else {
                    throw ComputerUseError.noninterferingActionUnsupported(action: action)
                }
                guard let snapshotId = request.params?["ax_snapshot_id"]?.rawValue as? String,
                      !snapshotId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ComputerUseError.ipcError(reason: "ax_snapshot_id parameter is required and must be nonblank")
                }
                guard let appInstanceRef = request.params?["app_instance_ref"]?.rawValue as? String,
                      !appInstanceRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ComputerUseError.ipcError(reason: "app_instance_ref parameter is required and must be nonblank")
                }
                guard let elementRef = request.params?["element_ref"]?.rawValue as? String,
                      !elementRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ComputerUseError.ipcError(reason: "element_ref parameter is required and must be nonblank")
                }
                guard let requestedTopologyVersion = request.params?["topology_version"]?.rawValue as? String,
                      !requestedTopologyVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ComputerUseError.ipcError(reason: "topology_version parameter is required and must be nonblank")
                }

                let currentTopology = try topologyProvider.getTopology()
                guard requestedTopologyVersion == currentTopology.version else {
                    throw ComputerUseError.staleTopology(
                        current: currentTopology.version,
                        received: requestedTopologyVersion
                    )
                }
                guard axActionEngine.isOperatorSafeActionAvailable else {
                    throw ComputerUseError.noninterferingActionUnsupported(action: action)
                }
                guard axActionEngine.supportedOperatorSafeActions == ["press"] else {
                    throw ComputerUseError.noninterferingActionUnsupported(action: action)
                }

                let result = try axActionEngine.performSemanticAction(
                    snapshotId: snapshotId,
                    appInstanceRef: appInstanceRef,
                    elementRef: elementRef,
                    action: action,
                    topologyVersion: requestedTopologyVersion
                )
                guard !result.actionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      result.status == "dispatched",
                      result.strategy == "ax_semantic",
                      result.action == action,
                      result.axSnapshotId == snapshotId,
                      result.appInstanceRef == appInstanceRef,
                      result.elementRef == elementRef,
                      result.topologyVersion == requestedTopologyVersion,
                      result.requiresReinspection,
                      result.globalHIDPosts == 0,
                      result.durationMs.isFinite,
                      result.durationMs >= 0 else {
                    throw ComputerUseError.axOutcomeUnknown(
                        reason: "AX semantic action engine returned an invalid or unsafe dispatch receipt"
                    )
                }
                let encoder = JSONEncoder()
                let resultData = try encoder.encode(result)
                let resultDict = try JSONDecoder().decode([String: AnyCodable].self, from: resultData)
                return IPCResponse(id: request.id, success: true, data: resultDict)

            case "click":
                guard inputEngine.isMutationEnabled else {
                    throw ComputerUseError.mutationDisabled
                }
                guard let intentStr = request.params?["intent"]?.rawValue as? String,
                      !intentStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ComputerUseError.ipcError(reason: "intent parameter is required and must be nonblank")
                }
                guard let reqTopVer = request.params?["topology_version"]?.rawValue as? String, !reqTopVer.isEmpty else {
                    throw ComputerUseError.ipcError(reason: "topology_version parameter is required")
                }
                let currentTop = try topologyProvider.getTopology()
                guard reqTopVer == currentTop.version else {
                    throw ComputerUseError.staleTopology(current: currentTop.version, received: reqTopVer)
                }
                guard let reqCapId = request.params?["capture_id"]?.rawValue as? String, !reqCapId.isEmpty else {
                    throw ComputerUseError.ipcError(reason: "capture_id parameter is required")
                }
                guard let activeCap = self.latestCapture,
                      activeCap.captureId == reqCapId,
                      activeCap.topologyVersion == reqTopVer else {
                    throw ComputerUseError.staleCapture(current: self.latestCapture?.captureId ?? "", received: reqCapId)
                }
                guard let x = request.params?["x"]?.rawValue as? Int,
                      let y = request.params?["y"]?.rawValue as? Int else {
                    throw ComputerUseError.ipcError(reason: "x and y integer parameters are required")
                }
                try CoordinateMapper.validateGridCoordinates(x: x, y: y)

                let buttonStr = request.params?["button"]?.rawValue as? String ?? "left"
                guard let button = MouseButton(rawValue: buttonStr) else {
                    throw ComputerUseError.ipcError(reason: "Invalid mouse button '\(buttonStr)'")
                }
                let clickCount = request.params?["click_count"]?.rawValue as? Int ?? 1
                guard clickCount >= 1 && clickCount <= 3 else {
                    throw ComputerUseError.ipcError(reason: "click_count must be between 1 and 3")
                }

                guard let display = currentTop.displays.first(where: { $0.id == activeCap.displayId }) else {
                    throw ComputerUseError.targetUnreachable(reason: "Display ID \(activeCap.displayId) not found in active topology")
                }

                // ATOMIC LEASE CONSUMPTION
                self.latestCapture = nil

                do {
                    let result = try inputEngine.performClick(gridX: x, gridY: y, button: button, clickCount: clickCount, captureId: reqCapId, currentCaptureId: reqCapId, display: display)
                    return IPCResponse(id: request.id, success: true, data: [
                        "action_id": .string(result.actionId),
                        "status": .string(result.status),
                        "capture_id": .string(result.captureId),
                        "duration_ms": .double(result.durationMs)
                    ])
                } catch {
                    inputEngine.releaseHeldInputs()
                    throw error
                }

            case "move":
                guard inputEngine.isMutationEnabled else {
                    throw ComputerUseError.mutationDisabled
                }
                guard let intentStr = request.params?["intent"]?.rawValue as? String,
                      !intentStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ComputerUseError.ipcError(reason: "intent parameter is required and must be nonblank")
                }
                guard let reqTopVer = request.params?["topology_version"]?.rawValue as? String, !reqTopVer.isEmpty else {
                    throw ComputerUseError.ipcError(reason: "topology_version parameter is required")
                }
                let currentTop = try topologyProvider.getTopology()
                guard reqTopVer == currentTop.version else {
                    throw ComputerUseError.staleTopology(current: currentTop.version, received: reqTopVer)
                }
                guard let reqCapId = request.params?["capture_id"]?.rawValue as? String, !reqCapId.isEmpty else {
                    throw ComputerUseError.ipcError(reason: "capture_id parameter is required")
                }
                guard let activeCap = self.latestCapture,
                      activeCap.captureId == reqCapId,
                      activeCap.topologyVersion == reqTopVer else {
                    throw ComputerUseError.staleCapture(current: self.latestCapture?.captureId ?? "", received: reqCapId)
                }
                guard let x = request.params?["x"]?.rawValue as? Int,
                      let y = request.params?["y"]?.rawValue as? Int else {
                    throw ComputerUseError.ipcError(reason: "x and y integer parameters are required")
                }
                try CoordinateMapper.validateGridCoordinates(x: x, y: y)

                guard let display = currentTop.displays.first(where: { $0.id == activeCap.displayId }) else {
                    throw ComputerUseError.targetUnreachable(reason: "Display ID \(activeCap.displayId) not found in active topology")
                }

                // ATOMIC LEASE CONSUMPTION
                self.latestCapture = nil

                do {
                    let result = try inputEngine.performMove(gridX: x, gridY: y, captureId: reqCapId, currentCaptureId: reqCapId, display: display)
                    return IPCResponse(id: request.id, success: true, data: [
                        "action_id": .string(result.actionId),
                        "status": .string(result.status),
                        "capture_id": .string(result.captureId),
                        "duration_ms": .double(result.durationMs)
                    ])
                } catch {
                    inputEngine.releaseHeldInputs()
                    throw error
                }

            case "scroll":
                guard inputEngine.isMutationEnabled else {
                    throw ComputerUseError.mutationDisabled
                }
                guard let intentStr = request.params?["intent"]?.rawValue as? String,
                      !intentStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ComputerUseError.ipcError(reason: "intent parameter is required and must be nonblank")
                }
                guard let reqTopVer = request.params?["topology_version"]?.rawValue as? String, !reqTopVer.isEmpty else {
                    throw ComputerUseError.ipcError(reason: "topology_version parameter is required")
                }
                let currentTop = try topologyProvider.getTopology()
                guard reqTopVer == currentTop.version else {
                    throw ComputerUseError.staleTopology(current: currentTop.version, received: reqTopVer)
                }
                guard let reqCapId = request.params?["capture_id"]?.rawValue as? String, !reqCapId.isEmpty else {
                    throw ComputerUseError.ipcError(reason: "capture_id parameter is required")
                }
                guard let activeCap = self.latestCapture,
                      activeCap.captureId == reqCapId,
                      activeCap.topologyVersion == reqTopVer else {
                    throw ComputerUseError.staleCapture(current: self.latestCapture?.captureId ?? "", received: reqCapId)
                }
                guard let x = request.params?["x"]?.rawValue as? Int,
                      let y = request.params?["y"]?.rawValue as? Int else {
                    throw ComputerUseError.ipcError(reason: "x and y integer parameters are required")
                }
                try CoordinateMapper.validateGridCoordinates(x: x, y: y)

                let deltaX = request.params?["delta_x"]?.rawValue as? Int ?? 0
                let deltaY = request.params?["delta_y"]?.rawValue as? Int ?? 0
                guard deltaX >= -1000 && deltaX <= 1000 else {
                    throw ComputerUseError.ipcError(reason: "delta_x must be between -1000 and 1000")
                }
                guard deltaY >= -1000 && deltaY <= 1000 else {
                    throw ComputerUseError.ipcError(reason: "delta_y must be between -1000 and 1000")
                }
                guard deltaX != 0 || deltaY != 0 else {
                    throw ComputerUseError.ipcError(reason: "At least one scroll delta (delta_x or delta_y) must be non-zero")
                }

                guard let display = currentTop.displays.first(where: { $0.id == activeCap.displayId }) else {
                    throw ComputerUseError.targetUnreachable(reason: "Display ID \(activeCap.displayId) not found in active topology")
                }

                // ATOMIC LEASE CONSUMPTION
                self.latestCapture = nil

                do {
                    let result = try inputEngine.performScroll(gridX: x, gridY: y, deltaX: deltaX, deltaY: deltaY, captureId: reqCapId, currentCaptureId: reqCapId, display: display)
                    return IPCResponse(id: request.id, success: true, data: [
                        "action_id": .string(result.actionId),
                        "status": .string(result.status),
                        "capture_id": .string(result.captureId),
                        "duration_ms": .double(result.durationMs)
                    ])
                } catch {
                    inputEngine.releaseHeldInputs()
                    throw error
                }

            case "drag":
                guard inputEngine.isMutationEnabled else {
                    throw ComputerUseError.mutationDisabled
                }
                guard let intentStr = request.params?["intent"]?.rawValue as? String,
                      !intentStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ComputerUseError.ipcError(reason: "intent parameter is required and must be nonblank")
                }
                guard let reqTopVer = request.params?["topology_version"]?.rawValue as? String, !reqTopVer.isEmpty else {
                    throw ComputerUseError.ipcError(reason: "topology_version parameter is required")
                }
                let currentTop = try topologyProvider.getTopology()
                guard reqTopVer == currentTop.version else {
                    throw ComputerUseError.staleTopology(current: currentTop.version, received: reqTopVer)
                }
                guard let reqCapId = request.params?["capture_id"]?.rawValue as? String, !reqCapId.isEmpty else {
                    throw ComputerUseError.ipcError(reason: "capture_id parameter is required")
                }
                guard let activeCap = self.latestCapture,
                      activeCap.captureId == reqCapId,
                      activeCap.topologyVersion == reqTopVer else {
                    throw ComputerUseError.staleCapture(current: self.latestCapture?.captureId ?? "", received: reqCapId)
                }
                guard let startX = request.params?["start_x"]?.rawValue as? Int,
                      let startY = request.params?["start_y"]?.rawValue as? Int,
                      let endX = request.params?["end_x"]?.rawValue as? Int,
                      let endY = request.params?["end_y"]?.rawValue as? Int else {
                    throw ComputerUseError.ipcError(reason: "start_x, start_y, end_x, end_y integer parameters are required")
                }
                try CoordinateMapper.validateGridCoordinates(x: startX, y: startY)
                try CoordinateMapper.validateGridCoordinates(x: endX, y: endY)

                let buttonStr = request.params?["button"]?.rawValue as? String ?? "left"
                guard buttonStr == "left" else {
                    throw ComputerUseError.ipcError(reason: "Drag button must be 'left' in this minimum-safe slice")
                }
                let button = MouseButton.left

                guard let display = currentTop.displays.first(where: { $0.id == activeCap.displayId }) else {
                    throw ComputerUseError.targetUnreachable(reason: "Display ID \(activeCap.displayId) not found in active topology")
                }

                // ATOMIC LEASE CONSUMPTION
                self.latestCapture = nil

                do {
                    let result = try inputEngine.performDrag(startX: startX, startY: startY, endX: endX, endY: endY, button: button, captureId: reqCapId, currentCaptureId: reqCapId, display: display)
                    return IPCResponse(id: request.id, success: true, data: [
                        "action_id": .string(result.actionId),
                        "status": .string(result.status),
                        "capture_id": .string(result.captureId),
                        "duration_ms": .double(result.durationMs)
                    ])
                } catch {
                    inputEngine.releaseHeldInputs()
                    throw error
                }

            case "type":
                guard inputEngine.isMutationEnabled else {
                    throw ComputerUseError.mutationDisabled
                }
                guard let intentStr = request.params?["intent"]?.rawValue as? String,
                      !intentStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ComputerUseError.ipcError(reason: "intent parameter is required and must be nonblank")
                }
                guard let reqTopVer = request.params?["topology_version"]?.rawValue as? String, !reqTopVer.isEmpty else {
                    throw ComputerUseError.ipcError(reason: "topology_version parameter is required")
                }
                let currentTop = try topologyProvider.getTopology()
                guard reqTopVer == currentTop.version else {
                    throw ComputerUseError.staleTopology(current: currentTop.version, received: reqTopVer)
                }
                guard let reqCapId = request.params?["capture_id"]?.rawValue as? String, !reqCapId.isEmpty else {
                    throw ComputerUseError.ipcError(reason: "capture_id parameter is required")
                }
                guard let activeCap = self.latestCapture,
                      activeCap.captureId == reqCapId,
                      activeCap.topologyVersion == reqTopVer else {
                    throw ComputerUseError.staleCapture(current: self.latestCapture?.captureId ?? "", received: reqCapId)
                }
                guard let textPayload = request.params?["text"]?.rawValue as? String, !textPayload.isEmpty else {
                    throw ComputerUseError.ipcError(reason: "text parameter is required and must be non-empty")
                }
                let pressEnter = request.params?["press_enter"]?.rawValue as? Bool ?? false

                // ATOMIC LEASE CONSUMPTION
                self.latestCapture = nil

                do {
                    let result = try inputEngine.performType(text: textPayload, pressEnter: pressEnter, captureId: reqCapId, currentCaptureId: reqCapId)
                    return IPCResponse(id: request.id, success: true, data: [
                        "action_id": .string(result.actionId),
                        "status": .string(result.status),
                        "capture_id": .string(result.captureId),
                        "duration_ms": .double(result.durationMs)
                    ])
                } catch {
                    inputEngine.releaseHeldInputs()
                    throw error
                }

            case "shortcut":
                guard inputEngine.isMutationEnabled else {
                    throw ComputerUseError.mutationDisabled
                }
                guard let intentStr = request.params?["intent"]?.rawValue as? String,
                      !intentStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ComputerUseError.ipcError(reason: "intent parameter is required and must be nonblank")
                }
                guard let reqTopVer = request.params?["topology_version"]?.rawValue as? String, !reqTopVer.isEmpty else {
                    throw ComputerUseError.ipcError(reason: "topology_version parameter is required")
                }
                let currentTop = try topologyProvider.getTopology()
                guard reqTopVer == currentTop.version else {
                    throw ComputerUseError.staleTopology(current: currentTop.version, received: reqTopVer)
                }
                guard let reqCapId = request.params?["capture_id"]?.rawValue as? String, !reqCapId.isEmpty else {
                    throw ComputerUseError.ipcError(reason: "capture_id parameter is required")
                }
                guard let activeCap = self.latestCapture,
                      activeCap.captureId == reqCapId,
                      activeCap.topologyVersion == reqTopVer else {
                    throw ComputerUseError.staleCapture(current: self.latestCapture?.captureId ?? "", received: reqCapId)
                }
                guard let keysAny = request.params?["keys"]?.rawValue as? [Any] else {
                    throw ComputerUseError.ipcError(reason: "keys array parameter is required")
                }
                let keys = keysAny.compactMap { $0 as? String }
                guard keys.count == keysAny.count && !keys.isEmpty else {
                    throw ComputerUseError.ipcError(reason: "keys must be an array of non-empty strings")
                }

                // ATOMIC LEASE CONSUMPTION
                self.latestCapture = nil

                do {
                    let result = try inputEngine.performShortcut(keys: keys, captureId: reqCapId, currentCaptureId: reqCapId)
                    return IPCResponse(id: request.id, success: true, data: [
                        "action_id": .string(result.actionId),
                        "status": .string(result.status),
                        "capture_id": .string(result.captureId),
                        "duration_ms": .double(result.durationMs)
                    ])
                } catch {
                    inputEngine.releaseHeldInputs()
                    throw error
                }

            default:
                return IPCResponse(
                    id: request.id,
                    success: false,
                    error: IPCErrorPayload(code: "UNKNOWN_METHOD", message: "Method '\(request.method)' not implemented")
                )
            }
        } catch let err as ComputerUseError {
            return IPCResponse(
                id: request.id,
                success: false,
                error: IPCErrorPayload(code: err.errorCode, message: err.errorMessage)
            )
        } catch is CancellationError {
            return IPCResponse(
                id: request.id,
                success: false,
                error: IPCErrorPayload(code: "CANCELLED", message: "Task was cancelled")
            )
        } catch {
            return IPCResponse(
                id: request.id,
                success: false,
                error: IPCErrorPayload(code: "HOST_ERROR", message: error.localizedDescription)
            )
        }
    }

    nonisolated public static func executeObservationWithDeadline(
        captureEngine: DisplayCaptureEngine,
        targetDisplayId: Int,
        initialTopology: DisplayTopology,
        timeoutSec: Double,
        budget: CaptureBudget,
        sleeper: Sleeper = DefaultSleeper(),
        clock: HostClock = DefaultHostClock(),
        resolutionObserver: ArbiterResolutionObserver? = nil
    ) async throws -> CaptureFrameDTO {
        guard timeoutSec.isFinite && timeoutSec > 0 && timeoutSec < 100_000_000 else {
            budget.release()
            throw ComputerUseError.ipcError(reason: "Invalid observation timeout value: \(timeoutSec)")
        }

        let startInstant = clock.now
        let absoluteDeadline = startInstant + .seconds(timeoutSec)
        let arbiter = OneShotArbiter<CaptureFrameDTO>(resolutionObserver: resolutionObserver)

        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    arbiter.installContinuation(continuation)

                    let captureTask = Task.detached {
                        defer { budget.release() }
                        do {
                            let frame = try await captureEngine.captureDisplay(displayId: targetDisplayId, topology: initialTopology)
                            if clock.now >= absoluteDeadline {
                                arbiter.resolve(with: .failure(ComputerUseError.timeout(operation: "observe", seconds: timeoutSec)))
                            } else {
                                arbiter.resolve(with: .success(frame))
                            }
                        } catch {
                            if clock.now >= absoluteDeadline {
                                arbiter.resolve(with: .failure(ComputerUseError.timeout(operation: "observe", seconds: timeoutSec)))
                            } else {
                                arbiter.resolve(with: .failure(error))
                            }
                        }
                    }
                    arbiter.installCaptureTask(captureTask)

                    let timerTask = Task.detached {
                        do {
                            while true {
                                let now = clock.now
                                if now >= absoluteDeadline {
                                    break
                                }
                                let duration = absoluteDeadline - now
                                let (seconds, attoseconds) = duration.components
                                let nanoFromSeconds = seconds >= 0 ? UInt64(seconds) * 1_000_000_000 : 0
                                let nanoFromAttoseconds = attoseconds > 0 ? UInt64((attoseconds + 999_999_999) / 1_000_000_000) : 0
                                let totalNano = max(1, nanoFromSeconds + nanoFromAttoseconds)
                                try await sleeper.sleep(nanoseconds: totalNano)
                            }
                            arbiter.resolve(with: .failure(ComputerUseError.timeout(operation: "observe", seconds: timeoutSec)))
                        } catch is CancellationError {
                            // Normal cancellation on capture completion or request cancellation
                        } catch {
                            arbiter.resolve(with: .failure(error))
                        }
                    }
                    arbiter.installTimerTask(timerTask)
                }
            },
            onCancel: {
                arbiter.resolve(with: .failure(ComputerUseError.cancelled(reason: "Observation request explicitly cancelled")))
            }
        )
    }

    private func validateAndPromoteFrame(
        frame: CaptureFrameDTO,
        initialTopology: DisplayTopology,
        generation: UInt64,
        targetDisplayId: Int
    ) throws -> DisplayTopology {
        let currentTopology = try topologyProvider.getTopology()

        // 1. Generation fence: require issued generation to match current generation
        guard generation == self.latestIssuedGeneration else {
            throw ComputerUseError.staleOperation(reason: "Newer observation generation \(self.latestIssuedGeneration) issued while generation \(generation) was in flight")
        }

        // 2. Topology version equality across initial, frame, and current topology
        guard initialTopology.version == frame.topologyVersion && frame.topologyVersion == currentTopology.version else {
            throw ComputerUseError.staleTopology(current: currentTopology.version, received: frame.topologyVersion)
        }

        // 3. Display ID & geometry equality
        guard let targetDisplay = currentTopology.displays.first(where: { $0.id == targetDisplayId }) else {
            throw ComputerUseError.targetUnreachable(reason: "Display ID \(targetDisplayId) missing from current topology")
        }

        guard frame.displayId == targetDisplayId &&
              frame.widthPoints == targetDisplay.widthPoints &&
              frame.heightPoints == targetDisplay.heightPoints &&
              frame.scaleFactor == targetDisplay.scaleFactor &&
              frame.pixelWidth == targetDisplay.pixelWidth &&
              frame.pixelHeight == targetDisplay.pixelHeight else {
            throw ComputerUseError.staleTopology(current: currentTopology.version, received: frame.topologyVersion)
        }

        self.activeTopology = currentTopology
        self.latestCapture = frame
        return currentTopology
    }
}
