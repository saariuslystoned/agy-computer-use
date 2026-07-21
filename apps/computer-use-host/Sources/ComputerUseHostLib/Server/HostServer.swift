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
    private var currentOperationSequence: UInt64 = 0
    private var latestCompletedSequence: UInt64 = 0

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
            case "handshake":
                self.isConnected = true
                let topVer = (try? topologyProvider.getTopology().version) ?? "top-v1"
                return IPCResponse(
                    id: request.id,
                    success: true,
                    data: [
                        "protocol_version": .string("1.0"),
                        "host_version": .string("0.1.0"),
                        "topology_version": .string(topVer)
                    ]
                )

            case "status":
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
                        "accessibility_trusted": .bool(axEngine.isAccessibilityTrusted()),
                        "input_mutation_state": .string(inputEngine.isMutationEnabled ? "enabled" : "disabled"),
                        "topology_version": .string(currentTopology.version),
                        "primary_display_id": .int(currentTopology.primaryDisplayId),
                        "display_count": .int(currentTopology.displays.count),
                        "topology": .dictionary(topologyDict)
                    ]
                )

            case "observe":
                let currentTopology = try topologyProvider.getTopology()
                self.activeTopology = currentTopology
                let displayId = request.params?["display_id"]?.rawValue as? Int ?? currentTopology.primaryDisplayId

                currentOperationSequence += 1
                let opSeq = currentOperationSequence

                let frame = try await captureEngine.captureDisplay(displayId: displayId, topology: currentTopology)

                if Task.isCancelled {
                    throw ComputerUseError.cancelled(reason: "Observation operation cancelled during execution")
                }

                guard opSeq >= self.latestCompletedSequence else {
                    throw ComputerUseError.ipcError(reason: "Stale out-of-order capture completion discarded")
                }

                self.latestCompletedSequence = opSeq
                self.latestCapture = frame

                let dataDict: [String: AnyCodable] = [
                    "capture_id": .string(frame.captureId),
                    "timestamp": .int(Int(frame.timestamp)),
                    "topology_version": .string(frame.topologyVersion),
                    "display_id": .int(frame.displayId),
                    "width_points": .double(frame.widthPoints),
                    "height_points": .double(frame.heightPoints),
                    "scale_factor": .double(frame.scaleFactor),
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

        let currentTopVer = (try? topologyProvider.getTopology().version) ?? "top-v1"
        guard let topVer = params["topology_version"]?.rawValue as? String, topVer == currentTopVer else {
            throw ComputerUseError.staleTopology(current: currentTopVer, received: params["topology_version"]?.rawValue as? String ?? "")
        }

        guard let intent = params["intent"]?.rawValue as? String, !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ComputerUseError.ipcError(reason: "Missing non-empty action intent description")
        }

        guard let activeCap = self.latestCapture else {
            throw ComputerUseError.staleCapture(current: "none", received: capId)
        }

        guard activeCap.captureId == capId else {
            throw ComputerUseError.staleCapture(current: activeCap.captureId, received: capId)
        }

        let activeCapId = activeCap.captureId

        // Atomically consume capture lease BEFORE dispatching input
        self.latestCapture = nil

        let topology = try topologyProvider.getTopology()
        guard let display = topology.displays.first(where: { $0.id == activeCap.displayId }) else {
            throw ComputerUseError.targetUnreachable(reason: "Display ID \(activeCap.displayId) not found in topology")
        }

        return (capId, activeCapId, display)
    }

    private func createPostActionObservation(displayId: Int) async throws -> [String: AnyCodable] {
        let topology = try topologyProvider.getTopology()
        let frame = try await captureEngine.captureDisplay(displayId: displayId, topology: topology)
        self.latestCapture = frame

        return [
            "capture_id": .string(frame.captureId),
            "timestamp": .int(Int(frame.timestamp)),
            "topology_version": .string(frame.topologyVersion),
            "display_id": .int(frame.displayId),
            "image_format": .string(frame.imageFormat),
            "image_data_base64": .string(frame.imageDataBase64)
        ]
    }

    public func getInputHistory() -> [String] {
        if let fakeInjector = inputEngine as? FakeInputInjector {
            return fakeInjector.actionHistory
        }
        return []
    }
}
