import Foundation

public actor HostServer {
    private var isConnected: Bool = false
    private let authorizer: ScreenRecordingAuthorizing
    private let topologyProvider: DisplayTopologyProviding
    private let captureEngine: DisplayCaptureEngine
    private let axEngine: AXInspectionEngine
    private let inputEngine: InputSynthesisEngine

    private var latestCapture: CaptureFrameDTO?
    private var activeTopology: DisplayTopology?
    private var latestIssuedGeneration: UInt64 = 0

    public init(
        authorizer: ScreenRecordingAuthorizing = CGScreenRecordingAuthorizer(),
        topologyProvider: DisplayTopologyProviding = SystemDisplayTopologyProvider(),
        captureEngine: DisplayCaptureEngine? = nil,
        axEngine: AXInspectionEngine = DisabledAXInspector(),
        inputEngine: InputSynthesisEngine = DisabledInputInjector()
    ) {
        self.authorizer = authorizer
        self.topologyProvider = topologyProvider
        self.captureEngine = captureEngine ?? SCScreenshotCaptureEngine(authorizer: authorizer)
        self.axEngine = axEngine
        self.inputEngine = inputEngine
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

                // Strict display_id validation: only absent value selects primary; present non-integer fails immediately
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

                guard let targetDisplay = initialTopology.displays.first(where: { $0.id == targetDisplayId }) else {
                    throw ComputerUseError.targetUnreachable(reason: "Display ID \(targetDisplayId) not found in initial topology")
                }

                // Increment generation counter and immediately invalidate existing capture lease
                latestIssuedGeneration += 1
                let generation = latestIssuedGeneration
                self.latestCapture = nil

                let frame = try await captureEngine.captureDisplay(displayId: targetDisplayId, topology: initialTopology)

                if Task.isCancelled {
                    throw ComputerUseError.cancelled(reason: "Observation operation cancelled during execution")
                }

                // Re-read current topology once after capture completes
                let currentTopology = try topologyProvider.getTopology()

                // Generation promotion guard: require issued generation to match latest generation
                guard generation == self.latestIssuedGeneration else {
                    throw ComputerUseError.staleOperation(reason: "Newer observation generation issued while generation \(generation) was in flight")
                }

                // Triple topology & DTO dimension validation
                guard initialTopology.version == frame.topologyVersion && frame.topologyVersion == currentTopology.version else {
                    throw ComputerUseError.staleTopology(current: currentTopology.version, received: frame.topologyVersion)
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

            case "click":
                guard inputEngine.isMutationEnabled else {
                    throw ComputerUseError.mutationDisabled
                }
                let (capId, activeCapId, display) = try consumeAndValidateCaptureLease(params: request.params)
                let x = request.params?["x"]?.rawValue as? Int ?? 0
                let y = request.params?["y"]?.rawValue as? Int ?? 0
                let buttonStr = request.params?["button"]?.rawValue as? String ?? "left"
                let clickCount = request.params?["click_count"]?.rawValue as? Int ?? 1
                let button = MouseButton(rawValue: buttonStr) ?? .left

                let result = try inputEngine.performClick(
                    gridX: x, gridY: y, button: button, clickCount: clickCount,
                    captureId: capId, currentCaptureId: activeCapId, display: display
                )
                let postObs = try await createPostActionObservation(displayId: display.id)

                return IPCResponse(
                    id: request.id,
                    success: true,
                    data: [
                        "action_id": .string(result.actionId),
                        "status": .string("dispatched"),
                        "capture_id": .string(capId),
                        "duration_ms": .double(result.durationMs),
                        "post_action_observation": .dictionary(postObs)
                    ]
                )

            case "move":
                guard inputEngine.isMutationEnabled else {
                    throw ComputerUseError.mutationDisabled
                }
                let (capId, activeCapId, display) = try consumeAndValidateCaptureLease(params: request.params)
                let x = request.params?["x"]?.rawValue as? Int ?? 0
                let y = request.params?["y"]?.rawValue as? Int ?? 0

                let result = try inputEngine.performMove(
                    gridX: x, gridY: y, captureId: capId, currentCaptureId: activeCapId, display: display
                )
                let postObs = try await createPostActionObservation(displayId: display.id)

                return IPCResponse(
                    id: request.id,
                    success: true,
                    data: [
                        "action_id": .string(result.actionId),
                        "status": .string("dispatched"),
                        "capture_id": .string(capId),
                        "duration_ms": .double(result.durationMs),
                        "post_action_observation": .dictionary(postObs)
                    ]
                )

            case "drag":
                guard inputEngine.isMutationEnabled else {
                    throw ComputerUseError.mutationDisabled
                }
                let (capId, activeCapId, display) = try consumeAndValidateCaptureLease(params: request.params)
                let sx = request.params?["start_x"]?.rawValue as? Int ?? 0
                let sy = request.params?["start_y"]?.rawValue as? Int ?? 0
                let ex = request.params?["end_x"]?.rawValue as? Int ?? 0
                let ey = request.params?["end_y"]?.rawValue as? Int ?? 0

                let result = try inputEngine.performDrag(
                    startX: sx, startY: sy, endX: ex, endY: ey,
                    captureId: capId, currentCaptureId: activeCapId, display: display
                )
                let postObs = try await createPostActionObservation(displayId: display.id)

                return IPCResponse(
                    id: request.id,
                    success: true,
                    data: [
                        "action_id": .string(result.actionId),
                        "status": .string("dispatched"),
                        "capture_id": .string(capId),
                        "duration_ms": .double(result.durationMs),
                        "post_action_observation": .dictionary(postObs)
                    ]
                )

            case "type":
                guard inputEngine.isMutationEnabled else {
                    throw ComputerUseError.mutationDisabled
                }
                let (capId, activeCapId, display) = try consumeAndValidateCaptureLease(params: request.params)
                let rawText = request.params?["text"]?.rawValue as? String ?? ""
                let pressEnter = request.params?["press_enter"]?.rawValue as? Bool ?? false

                let result = try inputEngine.performType(
                    text: rawText, pressEnter: pressEnter, captureId: capId, currentCaptureId: activeCapId
                )
                let postObs = try await createPostActionObservation(displayId: display.id)

                return IPCResponse(
                    id: request.id,
                    success: true,
                    data: [
                        "action_id": .string(result.actionId),
                        "status": .string("dispatched"),
                        "capture_id": .string(capId),
                        "duration_ms": .double(result.durationMs),
                        "post_action_observation": .dictionary(postObs)
                    ]
                )

            case "shortcut":
                guard inputEngine.isMutationEnabled else {
                    throw ComputerUseError.mutationDisabled
                }
                let (capId, activeCapId, display) = try consumeAndValidateCaptureLease(params: request.params)
                let keysRaw = request.params?["keys"]?.rawValue as? [Any] ?? []
                let keys = keysRaw.compactMap { $0 as? String }

                let result = try inputEngine.performShortcut(
                    keys: keys, captureId: capId, currentCaptureId: activeCapId
                )
                let postObs = try await createPostActionObservation(displayId: display.id)

                return IPCResponse(
                    id: request.id,
                    success: true,
                    data: [
                        "action_id": .string(result.actionId),
                        "status": .string("dispatched"),
                        "capture_id": .string(capId),
                        "duration_ms": .double(result.durationMs),
                        "post_action_observation": .dictionary(postObs)
                    ]
                )

            case "scroll":
                guard inputEngine.isMutationEnabled else {
                    throw ComputerUseError.mutationDisabled
                }
                let (capId, activeCapId, display) = try consumeAndValidateCaptureLease(params: request.params)
                let x = request.params?["x"]?.rawValue as? Int ?? 0
                let y = request.params?["y"]?.rawValue as? Int ?? 0
                var dx = request.params?["delta_x"]?.rawValue as? Int ?? 0
                var dy = request.params?["delta_y"]?.rawValue as? Int ?? 0
                let direction = request.params?["direction"]?.rawValue as? String

                if dx == 0 && dy == 0, let dir = direction {
                    switch dir {
                    case "up": dy = -100
                    case "down": dy = 100
                    case "left": dx = -100
                    case "right": dx = 100
                    default: break
                    }
                }

                let result = try inputEngine.performScroll(
                    gridX: x, gridY: y, deltaX: dx, deltaY: dy,
                    captureId: capId, currentCaptureId: activeCapId, display: display
                )
                let postObs = try await createPostActionObservation(displayId: display.id)

                return IPCResponse(
                    id: request.id,
                    success: true,
                    data: [
                        "action_id": .string(result.actionId),
                        "status": .string("dispatched"),
                        "capture_id": .string(capId),
                        "duration_ms": .double(result.durationMs),
                        "post_action_observation": .dictionary(postObs)
                    ]
                )

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
        } catch {
            return IPCResponse(
                id: request.id,
                success: false,
                error: IPCErrorPayload(code: "HOST_ERROR", message: error.localizedDescription)
            )
        }
    }

    private func consumeAndValidateCaptureLease(params: [String: AnyCodable]?) throws -> (String, String, DisplayInfo) {
        guard let params = params else {
            throw ComputerUseError.ipcError(reason: "Missing parameters")
        }

        guard let capId = params["capture_id"]?.rawValue as? String, !capId.isEmpty else {
            throw ComputerUseError.ipcError(reason: "Missing or empty capture_id parameter")
        }

        let currentTopology = try topologyProvider.getTopology()
        guard let reqTopVer = params["topology_version"]?.rawValue as? String else {
            throw ComputerUseError.ipcError(reason: "Missing topology_version parameter")
        }

        guard let activeCap = self.latestCapture else {
            throw ComputerUseError.staleCapture(current: "none", received: capId)
        }

        // Strict topology requirement: request topology == active capture topology == current topology
        guard reqTopVer == activeCap.topologyVersion && activeCap.topologyVersion == currentTopology.version else {
            throw ComputerUseError.staleTopology(current: currentTopology.version, received: reqTopVer)
        }

        guard let intent = params["intent"]?.rawValue as? String, !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ComputerUseError.ipcError(reason: "Missing non-empty action intent description")
        }

        guard activeCap.captureId == capId else {
            throw ComputerUseError.staleCapture(current: activeCap.captureId, received: capId)
        }

        guard let display = currentTopology.displays.first(where: { $0.id == activeCap.displayId }) else {
            throw ComputerUseError.targetUnreachable(reason: "Display ID \(activeCap.displayId) not found in topology")
        }

        let activeCapId = activeCap.captureId

        // Atomically consume capture lease ONLY AFTER all validations pass
        self.latestCapture = nil

        return (capId, activeCapId, display)
    }

    private func createPostActionObservation(displayId: Int) async throws -> [String: AnyCodable] {
        let initialTopology = try topologyProvider.getTopology()
        latestIssuedGeneration += 1
        let generation = latestIssuedGeneration
        self.latestCapture = nil

        let frame = try await captureEngine.captureDisplay(displayId: displayId, topology: initialTopology)
        let currentTopology = try topologyProvider.getTopology()

        guard generation == self.latestIssuedGeneration else {
            throw ComputerUseError.staleOperation(reason: "Newer operation generation issued during post-action observation")
        }

        guard initialTopology.version == frame.topologyVersion && frame.topologyVersion == currentTopology.version else {
            throw ComputerUseError.staleTopology(current: currentTopology.version, received: frame.topologyVersion)
        }

        self.latestCapture = frame

        return [
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
            "image_data_base64": .string(frame.imageDataBase64)
        ]
    }
}
