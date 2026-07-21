import Foundation

public actor HostServer {
    public let topology: DisplayTopology
    public let captureEngine: DisplayCaptureEngine
    public let axEngine: AXInspectionEngine
    public let inputEngine: InputSynthesisEngine

    private var latestCapture: CaptureFrameDTO?
    private var inputHistory: [String] = []

    public init(
        topology: DisplayTopology? = nil,
        captureEngine: DisplayCaptureEngine? = nil,
        axEngine: AXInspectionEngine? = nil,
        inputEngine: InputSynthesisEngine? = nil
    ) {
        let defaultDisplay = DisplayInfo(id: 1, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: 0, originY: 0)
        self.topology = topology ?? DisplayTopology(version: "top-v1", primaryDisplayId: 1, displays: [defaultDisplay])
        self.captureEngine = captureEngine ?? FakeCaptureEngine()
        self.axEngine = axEngine ?? FakeAXInspector()
        self.inputEngine = inputEngine ?? FakeInputInjector()
    }

    public func getInputHistory() -> [String] {
        return inputHistory
    }

    private func createPostActionObservation(displayId: Int) throws -> (CaptureFrameDTO, [String: AnyCodable]) {
        let frame = try captureEngine.captureDisplay(displayId: displayId, topology: topology)
        self.latestCapture = frame
        let obsData: [String: AnyCodable] = [
            "capture_id": .string(frame.captureId),
            "timestamp": .int(Int(frame.timestamp)),
            "topology_version": .string(frame.topologyVersion),
            "display_id": .int(frame.displayId),
            "width_points": .double(frame.widthPoints),
            "height_points": .double(frame.heightPoints),
            "scale_factor": .double(frame.scaleFactor),
            "image_format": .string(frame.imageFormat),
            "image_data_base64": .string(frame.imageDataBase64)
        ]
        return (frame, obsData)
    }

    private func validatePreconditions(params: [String: AnyCodable]?) throws -> (String, String, String) {
        guard let capId = params?["capture_id"]?.rawValue as? String, !capId.isEmpty else {
            throw ComputerUseError.ipcError(reason: "Missing required 'capture_id' precondition")
        }
        guard let topVer = params?["topology_version"]?.rawValue as? String, topVer == topology.version else {
            let receivedVer = (params?["topology_version"]?.rawValue as? String) ?? "none"
            throw ComputerUseError.staleTopology(current: topology.version, received: receivedVer)
        }
        guard let intent = params?["intent"]?.rawValue as? String, !intent.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ComputerUseError.ipcError(reason: "Missing required non-empty 'intent' description for mutation")
        }
        guard let currentCap = latestCapture, currentCap.captureId == capId else {
            let currentCapId = latestCapture?.captureId ?? "none"
            throw ComputerUseError.staleCapture(current: currentCapId, received: capId)
        }
        return (capId, topVer, intent)
    }

    public func handleRequest(_ request: IPCRequest) -> IPCResponse {
        do {
            switch request.method {
            case "handshake":
                let handshakeData: [String: AnyCodable] = [
                    "protocol_version": .string("1.0"),
                    "host_version": .string("0.1.0"),
                    "topology_version": .string(topology.version)
                ]
                return IPCResponse(id: request.id, success: true, data: handshakeData)

            case "status":
                let statusData: [String: AnyCodable] = [
                    "connected": .bool(true),
                    "topology_version": .string(topology.version),
                    "primary_display_id": .int(topology.primaryDisplayId),
                    "display_count": .int(topology.displays.count),
                    "tcc_permission_state": .string("fake_granted"),
                    "accessibility_trusted": .bool(axEngine.isAccessibilityTrusted())
                ]
                return IPCResponse(id: request.id, success: true, data: statusData)

            case "observe":
                let displayId = request.params?["display_id"]?.rawValue as? Int
                let (_, observeData) = try createPostActionObservation(displayId: displayId ?? topology.primaryDisplayId)
                return IPCResponse(id: request.id, success: true, data: observeData)

            case "ax_tree":
                let maxDepth = (request.params?["max_depth"]?.rawValue as? Int) ?? 10
                let appId = request.params?["app_id"]?.rawValue as? String
                let treeNode = try axEngine.inspectTree(maxDepth: maxDepth, appId: appId)

                let encoder = JSONEncoder()
                let data = try encoder.encode(treeNode)
                let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let anyDict = dict.mapValues { AnyCodable($0) }

                return IPCResponse(id: request.id, success: true, data: anyDict)

            case "click":
                guard let x = request.params?["x"]?.rawValue as? Int,
                      let y = request.params?["y"]?.rawValue as? Int else {
                    throw ComputerUseError.ipcError(reason: "Missing required click parameters (x, y)")
                }
                let (capId, _, intent) = try validatePreconditions(params: request.params)

                let btnRaw = (request.params?["button"]?.rawValue as? String) ?? "left"
                let btn = MouseButton(rawValue: btnRaw) ?? .left
                let clickCount = (request.params?["click_count"]?.rawValue as? Int) ?? 1

                let targetDisplay = topology.displays.first(where: { $0.id == (latestCapture?.displayId ?? topology.primaryDisplayId) }) ?? topology.displays[0]
                let result = try inputEngine.performClick(gridX: x, gridY: y, button: btn, clickCount: clickCount, captureId: capId, currentCaptureId: capId, display: targetDisplay)

                inputHistory.append("[CLICK] intent=\(intent) (x:\(x), y:\(y))")

                let (_, postObs) = try createPostActionObservation(displayId: targetDisplay.id)

                let resultData: [String: AnyCodable] = [
                    "action_id": .string(result.actionId),
                    "status": .string("dispatched"),
                    "capture_id": .string(result.captureId),
                    "duration_ms": .double(result.durationMs),
                    "post_action_observation": .dictionary(postObs)
                ]
                return IPCResponse(id: request.id, success: true, data: resultData)

            case "move":
                guard let x = request.params?["x"]?.rawValue as? Int,
                      let y = request.params?["y"]?.rawValue as? Int else {
                    throw ComputerUseError.ipcError(reason: "Missing required move parameters (x, y)")
                }
                let (capId, _, intent) = try validatePreconditions(params: request.params)

                let targetDisplay = topology.displays.first(where: { $0.id == (latestCapture?.displayId ?? topology.primaryDisplayId) }) ?? topology.displays[0]
                let result = try inputEngine.performMove(gridX: x, gridY: y, captureId: capId, currentCaptureId: capId, display: targetDisplay)

                inputHistory.append("[MOVE] intent=\(intent) (x:\(x), y:\(y))")

                let (_, postObs) = try createPostActionObservation(displayId: targetDisplay.id)

                let resultData: [String: AnyCodable] = [
                    "action_id": .string(result.actionId),
                    "status": .string("dispatched"),
                    "capture_id": .string(result.captureId),
                    "duration_ms": .double(result.durationMs),
                    "post_action_observation": .dictionary(postObs)
                ]
                return IPCResponse(id: request.id, success: true, data: resultData)

            case "drag":
                guard let startX = request.params?["start_x"]?.rawValue as? Int,
                      let startY = request.params?["start_y"]?.rawValue as? Int,
                      let endX = request.params?["end_x"]?.rawValue as? Int,
                      let endY = request.params?["end_y"]?.rawValue as? Int else {
                    throw ComputerUseError.ipcError(reason: "Missing required drag parameters")
                }
                let (capId, _, intent) = try validatePreconditions(params: request.params)

                let targetDisplay = topology.displays.first(where: { $0.id == (latestCapture?.displayId ?? topology.primaryDisplayId) }) ?? topology.displays[0]
                let result = try inputEngine.performDrag(startX: startX, startY: startY, endX: endX, endY: endY, captureId: capId, currentCaptureId: capId, display: targetDisplay)

                inputHistory.append("[DRAG] intent=\(intent) (\(startX),\(startY))->(\(endX),\(endY))")

                let (_, postObs) = try createPostActionObservation(displayId: targetDisplay.id)

                let resultData: [String: AnyCodable] = [
                    "action_id": .string(result.actionId),
                    "status": .string("dispatched"),
                    "capture_id": .string(result.captureId),
                    "duration_ms": .double(result.durationMs),
                    "post_action_observation": .dictionary(postObs)
                ]
                return IPCResponse(id: request.id, success: true, data: resultData)

            case "type":
                guard let text = request.params?["text"]?.rawValue as? String else {
                    throw ComputerUseError.ipcError(reason: "Missing required type parameters (text)")
                }
                let (capId, _, intent) = try validatePreconditions(params: request.params)

                let result = try inputEngine.performType(text: text, captureId: capId, currentCaptureId: capId)

                // Privacy: sanitize raw typed text from history logs
                inputHistory.append("[TYPE] intent=\(intent) text_length=\(text.count) [REDACTED_TEXT]")

                let targetDisplayId = latestCapture?.displayId ?? topology.primaryDisplayId
                let (_, postObs) = try createPostActionObservation(displayId: targetDisplayId)

                let resultData: [String: AnyCodable] = [
                    "action_id": .string(result.actionId),
                    "status": .string("dispatched"),
                    "capture_id": .string(result.captureId),
                    "duration_ms": .double(result.durationMs),
                    "post_action_observation": .dictionary(postObs)
                ]
                return IPCResponse(id: request.id, success: true, data: resultData)

            case "shortcut":
                guard let keysAny = request.params?["keys"]?.rawValue as? [Any] else {
                    throw ComputerUseError.ipcError(reason: "Missing required shortcut parameters (keys)")
                }
                let (capId, _, intent) = try validatePreconditions(params: request.params)
                let keys = keysAny.compactMap { $0 as? String }

                let result = try inputEngine.performShortcut(keys: keys, captureId: capId, currentCaptureId: capId)

                inputHistory.append("[SHORTCUT] intent=\(intent) keys=\(keys.joined(separator: "+"))")

                let targetDisplayId = latestCapture?.displayId ?? topology.primaryDisplayId
                let (_, postObs) = try createPostActionObservation(displayId: targetDisplayId)

                let resultData: [String: AnyCodable] = [
                    "action_id": .string(result.actionId),
                    "status": .string("dispatched"),
                    "capture_id": .string(result.captureId),
                    "duration_ms": .double(result.durationMs),
                    "post_action_observation": .dictionary(postObs)
                ]
                return IPCResponse(id: request.id, success: true, data: resultData)

            case "scroll":
                guard let x = request.params?["x"]?.rawValue as? Int,
                      let y = request.params?["y"]?.rawValue as? Int,
                      let deltaX = request.params?["delta_x"]?.rawValue as? Int,
                      let deltaY = request.params?["delta_y"]?.rawValue as? Int else {
                    throw ComputerUseError.ipcError(reason: "Missing required scroll parameters")
                }
                let (capId, _, intent) = try validatePreconditions(params: request.params)

                let targetDisplay = topology.displays.first(where: { $0.id == (latestCapture?.displayId ?? topology.primaryDisplayId) }) ?? topology.displays[0]
                let result = try inputEngine.performScroll(gridX: x, gridY: y, deltaX: deltaX, deltaY: deltaY, captureId: capId, currentCaptureId: capId, display: targetDisplay)

                inputHistory.append("[SCROLL] intent=\(intent) (x:\(x), y:\(y)) dx:\(deltaX) dy:\(deltaY)")

                let (_, postObs) = try createPostActionObservation(displayId: targetDisplay.id)

                let resultData: [String: AnyCodable] = [
                    "action_id": .string(result.actionId),
                    "status": .string("dispatched"),
                    "capture_id": .string(result.captureId),
                    "duration_ms": .double(result.durationMs),
                    "post_action_observation": .dictionary(postObs)
                ]
                return IPCResponse(id: request.id, success: true, data: resultData)

            default:
                throw ComputerUseError.ipcError(reason: "Unknown method '\(request.method)'")
            }
        } catch let err as ComputerUseError {
            let errorPayload = IPCErrorPayload(code: err.errorCode, message: err.errorMessage)
            return IPCResponse(id: request.id, success: false, error: errorPayload)
        } catch {
            let errorPayload = IPCErrorPayload(code: "UNKNOWN_ERROR", message: error.localizedDescription)
            return IPCResponse(id: request.id, success: false, error: errorPayload)
        }
    }
}
