import Foundation

public actor HostServer {
    private var isConnected: Bool = false
    private let authorizer: ScreenRecordingAuthorizing
    private let topologyProvider: DisplayTopologyProviding
    private let captureEngine: DisplayCaptureEngine
    private let axEngine: AXInspectionEngine
    private let inputEngine: InputSynthesisEngine
    private let observationTimeoutSec: Double

    private var latestCapture: CaptureFrameDTO?
    private var activeTopology: DisplayTopology?
    private var latestIssuedGeneration: UInt64 = 0

    public init(
        authorizer: ScreenRecordingAuthorizing = CGScreenRecordingAuthorizer(),
        topologyProvider: DisplayTopologyProviding = SystemDisplayTopologyProvider(),
        captureEngine: DisplayCaptureEngine? = nil,
        axEngine: AXInspectionEngine = DisabledAXInspector(),
        inputEngine: InputSynthesisEngine = DisabledInputInjector(),
        observationTimeoutSec: Double = 5.0
    ) {
        self.authorizer = authorizer
        self.topologyProvider = topologyProvider
        self.captureEngine = captureEngine ?? SCScreenshotCaptureEngine(authorizer: authorizer)
        self.axEngine = axEngine
        self.inputEngine = inputEngine
        self.observationTimeoutSec = observationTimeoutSec
    }

    public func handleRequest(_ request: IPCRequest) async -> IPCResponse {
        do {
            switch request.method {
            case "status":
                self.isConnected = true
                let currentTopology = try topologyProvider.getTopology()
                self.activeTopology = currentTopology
                let isGranted = authorizer.isScreenCaptureAccessGranted

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
                        "tcc_permission_state": .string(isGranted ? "granted" : "denied"),
                        "accessibility_available": .bool(axEngine.isAvailable),
                        "accessibility_trusted": .bool(axEngine.isAvailable && axEngine.isAccessibilityTrusted()),
                        "input_mutation_state": .string(inputEngine.isMutationEnabled ? "enabled" : "disabled"),
                        "topology_version": .string(currentTopology.version),
                        "primary_display_id": .int(currentTopology.primaryDisplayId),
                        "display_count": .int(currentTopology.displays.count),
                        "topology": .dictionary(topologyDict)
                    ]
                )

            case "observe":
                let initialTopology = try topologyProvider.getTopology()
                self.activeTopology = initialTopology

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

                // Increment generation counter and immediately invalidate old lease before await
                latestIssuedGeneration += 1
                let generation = latestIssuedGeneration
                self.latestCapture = nil

                // Nonisolated actor-safe deadline execution
                let frame = try await HostServer.executeObservationWithDeadline(
                    captureEngine: captureEngine,
                    targetDisplayId: targetDisplayId,
                    initialTopology: initialTopology,
                    timeoutSec: self.observationTimeoutSec
                )

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
                    throw ComputerUseError.targetUnreachable(reason: "AX tree inspection is unavailable in this build phase")
                }
                let maxDepth = request.params?["max_depth"]?.rawValue as? Int ?? 10
                let appId = request.params?["app_id"]?.rawValue as? String ?? "Finder"
                let tree = try axEngine.inspectTree(maxDepth: maxDepth, appId: appId)
                let encoder = JSONEncoder()
                let treeData = try encoder.encode(tree)
                let treeDict = try JSONDecoder().decode([String: AnyCodable].self, from: treeData)
                return IPCResponse(id: request.id, success: true, data: treeDict)

            case "click", "move", "drag", "type", "shortcut", "scroll":
                guard inputEngine.isMutationEnabled else {
                    throw ComputerUseError.mutationDisabled
                }
                throw ComputerUseError.mutationDisabled

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
        timeoutSec: Double
    ) async throws -> CaptureFrameDTO {
        let timeoutNano = UInt64(timeoutSec * 1_000_000_000)
        return try await withThrowingTaskGroup(of: CaptureFrameDTO.self) { group in
            group.addTask {
                try await captureEngine.captureDisplay(displayId: targetDisplayId, topology: initialTopology)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNano)
                throw ComputerUseError.timeout(operation: "observe", seconds: timeoutSec)
            }
            guard let firstResult = try await group.next() else {
                throw ComputerUseError.ipcError(reason: "Observation task group produced no result")
            }
            group.cancelAll()
            return firstResult
        }
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
