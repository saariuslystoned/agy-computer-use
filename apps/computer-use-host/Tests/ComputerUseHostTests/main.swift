import Foundation
import ComputerUseHostLib

fileprivate func assertTrue(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
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
runTest("LengthPrefixedFraming") {
    let originalText = "Hello, Computer Use IPC!"
    let payload = originalText.data(using: .utf8)!

    let encoded = try LengthPrefixedFramer.encode(payload: payload)
    assertEqual(encoded.count, 4 + payload.count, "Encoded count should equal header + payload")

    var buffer = encoded
    let decoded = try LengthPrefixedFramer.decode(from: &buffer)
    assertTrue(decoded != nil, "Decoded payload should not be nil")
    assertEqual(String(data: decoded!, encoding: .utf8), originalText, "Decoded string should match original")
    assertEqual(buffer.count, 0, "Buffer should be empty after decode")
}

// 2. Coordinate Mapper Test
runTest("CoordinateMapperGridToLogicalPoint") {
    let display = DisplayInfo(id: 1, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: 0, originY: 0)

    let topLeft = try CoordinateMapper.gridToLogicalPoint(gridX: 0, gridY: 0, display: display)
    assertEqual(topLeft.x, 0.0)
    assertEqual(topLeft.y, 0.0)

    let bottomRight = try CoordinateMapper.gridToLogicalPoint(gridX: 999, gridY: 999, display: display)
    assertEqual(bottomRight.x, 1920.0)
    assertEqual(bottomRight.y, 1080.0)
}

// 3. Multi-Monitor Negative Origin Test
runTest("CoordinateMapperNegativeOriginMultiMonitor") {
    let secondaryDisplay = DisplayInfo(id: 2, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: -1920, originY: 0)

    let point = try CoordinateMapper.gridToLogicalPoint(gridX: 0, gridY: 0, display: secondaryDisplay)
    assertEqual(point.x, -1920.0)
    assertEqual(point.y, 0.0)
}

// 4. Out Of Bounds Rejection Test
runTest("CoordinateMapperOutOfBoundsRejection") {
    let display = DisplayInfo(id: 1, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: 0, originY: 0)

    var threwError = false
    do {
        _ = try CoordinateMapper.gridToLogicalPoint(gridX: -1, gridY: 500, display: display)
    } catch {
        threwError = true
    }
    assertTrue(threwError, "-1 gridX should throw outOfBounds")
}

// 5. AX Tree Secure Text Redaction Test
runTest("AXTreeRedactionAndLimits") {
    let fakeAX = FakeAXInspector()
    let tree = try fakeAX.inspectTree(maxDepth: 5, appId: "TestApp")

    assertEqual(tree.role, "AXApplication")
    assertEqual(tree.children?.count, 1)

    let windowNode = tree.children?[0]
    let passNode = windowNode?.children?.first(where: { $0.subrole == "AXSecureTextField" })

    assertTrue(passNode != nil, "Password node should exist")
    assertEqual(passNode?.value, "[REDACTED]", "Password value should be redacted")
}

// 6. Host Server Observe & Click Workflow Test
runTest("HostServerObserveAndClickWorkflow") {
    let server = HostServer()

    let statusResp = server.handleRequest(IPCRequest(id: "1", method: "status"))
    assertTrue(statusResp.success, "Status request should succeed")

    let observeResp = server.handleRequest(IPCRequest(id: "2", method: "observe"))
    assertTrue(observeResp.success, "Observe request should succeed")
    let capId = observeResp.data?["capture_id"]?.rawValue as? String
    assertTrue(capId != nil, "Capture ID should be present")

    let clickParams: [String: AnyCodable] = [
        "x": .int(500),
        "y": .int(500),
        "button": .string("left"),
        "click_count": .int(1),
        "capture_id": .string(capId!)
    ]
    let clickResp = server.handleRequest(IPCRequest(id: "3", method: "click", params: clickParams))
    assertTrue(clickResp.success, "Click request with valid capture_id should succeed")
    assertEqual(clickResp.data?["status"]?.rawValue as? String, "verified")

    let staleClickParams: [String: AnyCodable] = [
        "x": .int(500),
        "y": .int(500),
        "capture_id": .string("stale-cap-9999")
    ]
    let staleResp = server.handleRequest(IPCRequest(id: "4", method: "click", params: staleClickParams))
    assertTrue(!staleResp.success, "Click request with stale capture_id should fail")
    assertEqual(staleResp.error?.code, "STALE_CAPTURE")
}

fputs("\n[ALL TESTS PASSED] 6 Swift unit tests executed cleanly.\n", stderr)
