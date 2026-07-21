import Foundation

public actor HostServer {
    private var isConnected: Bool = false
    private let captureEngine: DisplayCaptureEngine
    private let axEngine: AXInspectionEngine
    private let inputEngine: InputSynthesisEngine
    private var latestCapture: CaptureFrameDTO?
    private var activeTopology: DisplayTopology

    public init(
        captureEngine: DisplayCaptureEngine = FakeCaptureEngine(),
        axEngine: AXInspectionEngine = FakeAXInspector(),
        inputEngine: InputSynthesisEngine = FakeInputInjector()
    ) {
        self.captureEngine = captureEngine
        self.axEngine = axEngine
        self.inputEngine = inputEngine
        self.activeTopology = DisplayTopology(
            version: "top-v1",
            primaryDisplayId: 1,
            displays: [
                DisplayInfo(id: 1, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: 0, originY: 0)
            ]
        )
    }

    public func handleRequest(_ request: IPCRequest) async -> IPCResponse {
        do {
            switch request.method {
            case "handshake":
                self.isConnected = true
                return IPCResponse(
                    id: request.id,
                    success: true,
                    data: [
                        "protocol_version": .string("1.0"),
                        "host_version": .string("0.1.0"),
                        "topology_version": .string(activeTopology.version)
                    ]
                )

            case "status":
                return IPCResponse(
                    id: request.id,
                    success: true,
                    data: [
                        "connected": .bool(isConnected),
                        "topology_version": .string(activeTopology.version),
                        "primary_display_id": .int(activeTopology.primaryDisplayId),
                        "display_count": .int(activeTopology.displays.count),
                        "tcc_permission_state": .string("fake_granted"),
                        "accessibility_trusted": .bool(axEngine.isAccessibilityTrusted())
                    ]
                )

            case "observe":
                let displayId = request.params?["display_id"]?.rawValue as? Int ?? activeTopology.primaryDisplayId
                let frame = try captureEngine.captureDisplay(displayId: displayId, topology: activeTopology)
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
                let maxDepth = request.params?["max_depth"]?.rawValue as? Int ?? 10
                let appId = request.params?["app_id"]?.rawValue as? String ?? "Finder"
                let tree = try axEngine.inspectTree(maxDepth: maxDepth, appId: appId)
                let encoder = JSONEncoder()
                let treeData = try encoder.encode(tree)
                let treeDict = try JSONDecoder().decode([String: AnyCodable].self, from: treeData)
                return IPCResponse(id: request.id, success: true, data: treeDict)

            case "click":
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
                let postObs = try createPostActionObservation(displayId: display.id)

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
                let (capId, activeCapId, display) = try consumeAndValidateCaptureLease(params: request.params)
                let x = request.params?["x"]?.rawValue as? Int ?? 0
                let y = request.params?["y"]?.rawValue as? Int ?? 0

                let result = try inputEngine.performMove(
                    gridX: x, gridY: y, captureId: capId, currentCaptureId: activeCapId, display: display
                )
                let postObs = try createPostActionObservation(displayId: display.id)

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
                let (capId, activeCapId, display) = try consumeAndValidateCaptureLease(params: request.params)
                let sx = request.params?["start_x"]?.rawValue as? Int ?? 0
                let sy = request.params?["start_y"]?.rawValue as? Int ?? 0
                let ex = request.params?["end_x"]?.rawValue as? Int ?? 0
                let ey = request.params?["end_y"]?.rawValue as? Int ?? 0

                let result = try inputEngine.performDrag(
                    startX: sx, startY: sy, endX: ex, endY: ey,
                    captureId: capId, currentCaptureId: activeCapId, display: display
                )
                let postObs = try createPostActionObservation(displayId: display.id)

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
                let (capId, activeCapId, display) = try consumeAndValidateCaptureLease(params: request.params)
                let rawText = request.params?["text"]?.rawValue as? String ?? ""
                let pressEnter = request.params?["press_enter"]?.rawValue as? Bool ?? false

                let result = try inputEngine.performType(
                    text: rawText, pressEnter: pressEnter, captureId: capId, currentCaptureId: activeCapId
                )
                let postObs = try createPostActionObservation(displayId: display.id)

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
                let (capId, activeCapId, display) = try consumeAndValidateCaptureLease(params: request.params)
                let keysRaw = request.params?["keys"]?.rawValue as? [Any] ?? []
                let keys = keysRaw.compactMap { $0 as? String }

                let result = try inputEngine.performShortcut(
                    keys: keys, captureId: capId, currentCaptureId: activeCapId
                )
                let postObs = try createPostActionObservation(displayId: display.id)

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
                let postObs = try createPostActionObservation(displayId: display.id)

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

        guard let topVer = params["topology_version"]?.rawValue as? String, topVer == activeTopology.version else {
            throw ComputerUseError.staleTopology(current: activeTopology.version, received: params["topology_version"]?.rawValue as? String ?? "")
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

        guard let display = activeTopology.displays.first(where: { $0.id == activeCap.displayId }) else {
            throw ComputerUseError.targetUnreachable(reason: "Display ID \(activeCap.displayId) not found in topology")
        }

        return (capId, activeCapId, display)
    }

    private func createPostActionObservation(displayId: Int) throws -> [String: AnyCodable] {
        let frame = try captureEngine.captureDisplay(displayId: displayId, topology: activeTopology)
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
