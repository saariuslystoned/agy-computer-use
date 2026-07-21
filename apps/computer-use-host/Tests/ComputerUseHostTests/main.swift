import Foundation
import ComputerUseHostLib

fileprivate func assertTrue(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
    if !condition {
        fputs("[FAIL] \(message) at \(file):\(line)\n", stderr)
        exit(1)
    }
}

fileprivate func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: String = #file, line: Int = #line) {
    if actual != expected {
        fputs("[FAIL] Expected '\(expected)', got '\(actual)'. \(message) at \(file):\(line)\n", stderr)
        exit(1)
    }
}

fileprivate func runTest(_ name: String, _ block: () throws -> Void) {
    fputs("[TEST] Running \(name)...\n", stderr)
    do {
        try block()
        fputs("[PASS] \(name)\n", stderr)
    } catch {
        fputs("[FAIL] \(name) threw error: \(error)\n", stderr)
        exit(1)
    }
}

// 1. Length Prefixed Framing Test
runTest("LengthPrefixedFramingAndBufferLimits") {
    let originalText = "Hello, Computer Use IPC!"
    let payload = originalText.data(using: .utf8)!

    let encoded = try LengthPrefixedFramer.encode(payload: payload)
    assertEqual(encoded.count, 4 + payload.count, "Encoded count should equal header + payload")

    var buffer = encoded
    let decoded = try LengthPrefixedFramer.decode(from: &buffer)
    assertTrue(decoded != nil, "Decoded payload should not be nil")
    assertEqual(String(data: decoded!, encoding: .utf8), originalText, "Decoded string should match original")
    assertEqual(buffer.count, 0, "Buffer should be empty after decode")

    // Oversized Header Rejection Test
    var oversizedHeader = Data([0xFF, 0xFF, 0xFF, 0xFF]) // 4GB payload header
    oversizedHeader.append(Data([0x01, 0x02, 0x03]))
    var threwErr = false
    do {
        _ = try LengthPrefixedFramer.decode(from: &oversizedHeader)
    } catch {
        threwErr = true
    }
    assertTrue(threwErr, "Oversized header must throw ipcError")
}

// 2. Exact Grid 0...999 Mapping Test (floor(x / 1000 * width))
runTest("GridCoordinates0To999FloorMapping") {
    let landscapeDisplay = DisplayInfo(id: 1, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: 0, originY: 0)

    // x = 0 -> 0.0
    let topLeft = try CoordinateMapper.gridToLogicalPoint(gridX: 0, gridY: 0, display: landscapeDisplay)
    assertEqual(topLeft.x, 0.0)
    assertEqual(topLeft.y, 0.0)

    // x = 500 -> floor(500 / 1000 * 1920) = 960.0
    let center = try CoordinateMapper.gridToLogicalPoint(gridX: 500, gridY: 500, display: landscapeDisplay)
    assertEqual(center.x, 960.0)
    assertEqual(center.y, 540.0)

    // x = 999 -> floor(999 / 1000 * 1920) = 1918.0 (STRICTLY < 1920.0, inside half-open display bounds!)
    let bottomRight = try CoordinateMapper.gridToLogicalPoint(gridX: 999, gridY: 999, display: landscapeDisplay)
    assertEqual(bottomRight.x, 1918.0)
    assertEqual(bottomRight.y, 1078.0)
    assertTrue(bottomRight.x < landscapeDisplay.widthPoints, "999 gridX must remain inside half-open display width [0, 1920)")
    assertTrue(bottomRight.y < landscapeDisplay.heightPoints, "999 gridY must remain inside half-open display height [0, 1080)")

    // Invert mapping test
    let invMin = CoordinateMapper.logicalPointToGrid(pointX: 0.0, pointY: 0.0, display: landscapeDisplay)
    assertEqual(invMin.x, 0.0)
    assertEqual(invMin.y, 0.0)

    let invMax = CoordinateMapper.logicalPointToGrid(pointX: 1918.0, pointY: 1079.0, display: landscapeDisplay)
    assertEqual(invMax.x, 999.0)
    assertEqual(invMax.y, 999.0)
}

// 3. Multi-Monitor, Negative Origins, Portrait, and Retina Scaling Test
runTest("CoordinateMapperMultiMonitorPortraitRetina") {
    // Secondary Display with negative origin x = -1920
    let secondaryDisplay = DisplayInfo(id: 2, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: -1920, originY: 0)

    let pointSec0 = try CoordinateMapper.gridToLogicalPoint(gridX: 0, gridY: 0, display: secondaryDisplay)
    assertEqual(pointSec0.x, -1920.0)
    assertEqual(pointSec0.y, 0.0)

    let pointSec999 = try CoordinateMapper.gridToLogicalPoint(gridX: 999, gridY: 999, display: secondaryDisplay)
    assertEqual(pointSec999.x, -1920.0 + 1918.0) // -2.0
    assertEqual(pointSec999.y, 1078.0)

    // Portrait Display (1080 x 1920)
    let portraitDisplay = DisplayInfo(id: 3, widthPoints: 1080, heightPoints: 1920, scaleFactor: 3.0, originX: 0, originY: 0)
    let portCenter = try CoordinateMapper.gridToLogicalPoint(gridX: 500, gridY: 500, display: portraitDisplay)
    assertEqual(portCenter.x, 540.0) // floor(500/1000 * 1080)
    assertEqual(portCenter.y, 960.0) // floor(500/1000 * 1920)

    let retinaPixel = CoordinateMapper.logicalPointToPhysicalPixels(point: portCenter, display: portraitDisplay)
    assertEqual(retinaPixel.x, 1620.0) // 540 * 3.0
    assertEqual(retinaPixel.y, 2880.0) // 960 * 3.0
}

// 4. Boundary Rejection Test (-1 and 1000)
runTest("GridCoordinateBoundaryRejection") {
    let display = DisplayInfo(id: 1, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: 0, originY: 0)

    var errMinus1 = false
    do { _ = try CoordinateMapper.gridToLogicalPoint(gridX: -1, gridY: 500, display: display) } catch { errMinus1 = true }
    assertTrue(errMinus1, "-1 grid coordinate must be rejected")

    var err1000 = false
    do { _ = try CoordinateMapper.gridToLogicalPoint(gridX: 1000, gridY: 500, display: display) } catch { err1000 = true }
    assertTrue(err1000, "1000 grid coordinate must be rejected")
}

// 5. AX Subrole Redaction Test
runTest("AXTreeSubroleRedaction") {
    let fakeAX = FakeAXInspector()
    let tree = try fakeAX.inspectTree(maxDepth: 5, appId: "TestApp")

    let windowNode = tree.children?[0]
    let passNode = windowNode?.children?.first(where: { $0.subrole == "AXSecureTextField" })

    assertTrue(passNode != nil, "AXSecureTextField node should be detected by subrole")
    assertEqual(passNode?.value, "[REDACTED]", "Secure field value must be redacted")
}

// 6. Post-Action Observation and Sequential Freshness Test
runTest("HostServerPostActionObservationWorkflow") {
    let server = HostServer()

    // 1. Initial Handshake
    let handshakeResp = server.handleRequest(IPCRequest(id: "h1", method: "handshake"))
    assertTrue(handshakeResp.success, "Handshake request should succeed")

    // 2. Initial Observe (returns cap-0001)
    let obs1Resp = server.handleRequest(IPCRequest(id: "1", method: "observe"))
    assertTrue(obs1Resp.success, "Observe should succeed")
    let cap1 = obs1Resp.data?["capture_id"]?.rawValue as? String
    assertEqual(cap1, "cap-0001")

    // 3. Click action referencing cap-0001
    let click1Params: [String: AnyCodable] = [
        "x": .int(500),
        "y": .int(500),
        "button": .string("left"),
        "click_count": .int(1),
        "capture_id": .string(cap1!)
    ]
    let click1Resp = server.handleRequest(IPCRequest(id: "2", method: "click", params: click1Params))
    assertTrue(click1Resp.success, "Click action should succeed")

    // Check that post_action_observation is immediately returned!
    let postObsDict = click1Resp.data?["post_action_observation"]?.rawValue as? [String: Any]
    assertTrue(postObsDict != nil, "post_action_observation must be included in action result")
    let cap2 = postObsDict?["capture_id"] as? String
    assertEqual(cap2, "cap-0002", "Action execution must update capture state to cap-0002")

    // 4. Immediate second click using cap-0001 MUST FAIL with STALE_CAPTURE
    let staleResp = server.handleRequest(IPCRequest(id: "3", method: "click", params: click1Params))
    assertTrue(!staleResp.success, "Subsequent action with cap-0001 must fail after cap-0002 was issued")
    assertEqual(staleResp.error?.code, "STALE_CAPTURE")

    // 5. Click using new post-action cap-0002 MUST SUCCEED!
    let click2Params: [String: AnyCodable] = [
        "x": .int(500),
        "y": .int(500),
        "button": .string("left"),
        "click_count": .int(1),
        "capture_id": .string(cap2!)
    ]
    let click2Resp = server.handleRequest(IPCRequest(id: "4", method: "click", params: click2Params))
    assertTrue(click2Resp.success, "Click action with fresh cap-0002 must succeed")
}

fputs("\n[ALL TESTS PASSED] 6 Swift unit tests executed cleanly.\n", stderr)
