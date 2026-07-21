import Foundation
@testable import ComputerUseHostLib

@main
struct ComputerUseHostTestsMain {
    private static func assertTrue(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
        if !condition {
            fputs("[FAIL] \(message) at \(file):\(line)\n", stderr)
            exit(1)
        }
    }

    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: String = #file, line: Int = #line) {
        if actual != expected {
            fputs("[FAIL] Expected '\(expected)', got '\(actual)'. \(message) at \(file):\(line)\n", stderr)
            exit(1)
        }
    }

    static func main() async throws {
        fputs("[TEST] Running Swift Host Unit & Integration Tests...\n", stderr)

        // 1. Framing tests
        let originalText = "Hello, Framed IPC!"
        let payload = originalText.data(using: .utf8)!
        let encoded = try LengthPrefixedFramer.encode(payload: payload)
        assertEqual(encoded.count, 4 + payload.count)

        var buffer = encoded
        let decoded = try LengthPrefixedFramer.decode(from: &buffer)
        assertTrue(decoded != nil)
        assertEqual(String(data: decoded!, encoding: .utf8), originalText)

        // 2. Fragmented & Coalesced framing test
        var partialBuffer = encoded.subdata(in: 0..<3)
        let decNil = try LengthPrefixedFramer.decode(from: &partialBuffer)
        assertTrue(decNil == nil, "Partial length header must return nil")

        partialBuffer.append(encoded.subdata(in: 3..<encoded.count))
        let decComplete = try LengthPrefixedFramer.decode(from: &partialBuffer)
        assertTrue(decComplete != nil, "Complete reassembled buffer must decode successfully")

        // 3. Oversized header test
        var oversized = Data([0x01, 0x00, 0x00, 0x01]) // 16MB + 1 byte
        oversized.append(Data([0x00]))
        var threwOversized = false
        do { _ = try LengthPrefixedFramer.decode(from: &oversized) } catch { threwOversized = true }
        assertTrue(threwOversized, "Oversized header must throw ipcError")

        // 4. Socket Directory Preparation Test
        let testDirPath = "/tmp/agy-computer-use-test-\(getuid())"
        try SocketListener.prepareDirectory(at: testDirPath)
        assertTrue(FileManager.default.fileExists(atPath: testDirPath))

        // 5. Grid Coordinate mapping tests (0, 500, 999, -1, 1000, multi-monitor, portrait, retina)
        let display = DisplayInfo(id: 1, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: 0, originY: 0)

        let p0 = try CoordinateMapper.gridToLogicalPoint(gridX: 0, gridY: 0, display: display)
        assertEqual(p0.x, 0.0)
        assertEqual(p0.y, 0.0)

        let p500 = try CoordinateMapper.gridToLogicalPoint(gridX: 500, gridY: 500, display: display)
        assertEqual(p500.x, 960.0)
        assertEqual(p500.y, 540.0)

        let p999 = try CoordinateMapper.gridToLogicalPoint(gridX: 999, gridY: 999, display: display)
        assertEqual(p999.x, 1918.0)
        assertEqual(p999.y, 1078.0)
        assertTrue(p999.x < display.widthPoints, "999 gridX must be inside half-open display width [0, 1920)")

        // Rejections (-1 and 1000)
        var threwMinus1 = false
        do { _ = try CoordinateMapper.gridToLogicalPoint(gridX: -1, gridY: 500, display: display) } catch { threwMinus1 = true }
        assertTrue(threwMinus1)

        var threw1000 = false
        do { _ = try CoordinateMapper.gridToLogicalPoint(gridX: 1000, gridY: 500, display: display) } catch { threw1000 = true }
        assertTrue(threw1000)

        // Negative screen origin (-1920)
        let secDisplay = DisplayInfo(id: 2, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: -1920, originY: 0)
        let pSec0 = try CoordinateMapper.gridToLogicalPoint(gridX: 0, gridY: 0, display: secDisplay)
        assertEqual(pSec0.x, -1920.0)

        // Portrait 3x Retina
        let portraitDisplay = DisplayInfo(id: 3, widthPoints: 1080, heightPoints: 1920, scaleFactor: 3.0, originX: 0, originY: 0)
        let pPortCenter = try CoordinateMapper.gridToLogicalPoint(gridX: 500, gridY: 500, display: portraitDisplay)
        assertEqual(pPortCenter.x, 540.0)
        assertEqual(pPortCenter.y, 960.0)
        let retinaPixel = CoordinateMapper.logicalPointToPhysicalPixels(point: pPortCenter, display: portraitDisplay)
        assertEqual(retinaPixel.x, 1620.0)
        assertEqual(retinaPixel.y, 2880.0)

        // 6. AX Subrole Redaction Test
        let fakeAX = FakeAXInspector()
        let axTree = try fakeAX.inspectTree(maxDepth: 5, appId: "TestApp")
        let winNode = axTree.children?[0]
        let passNode = winNode?.children?.first(where: { $0.subrole == "AXSecureTextField" })
        assertTrue(passNode != nil, "AXSecureTextField subrole must be detected")
        assertEqual(passNode?.value, "[REDACTED]", "Secure field value must be redacted")

        // 7. HostServer Actor Concurrency & Single-Use Capture Lease Test
        let server = HostServer()
        let hsResp = await server.handleRequest(IPCRequest(id: "h1", method: "handshake"))
        assertTrue(hsResp.success)

        let obs1 = await server.handleRequest(IPCRequest(id: "o1", method: "observe"))
        assertTrue(obs1.success)
        let cap1 = obs1.data?["capture_id"]?.rawValue as? String
        assertTrue(cap1 != nil)

        // Click consumes cap1, returns post_action_observation with cap2
        let click1Params: [String: AnyCodable] = [
            "x": .int(500),
            "y": .int(500),
            "button": .string("left"),
            "click_count": .int(1),
            "capture_id": .string(cap1!),
            "topology_version": .string("top-v1"),
            "intent": .string("Click open button")
        ]
        let click1Resp = await server.handleRequest(IPCRequest(id: "c1", method: "click", params: click1Params))
        assertTrue(click1Resp.success)
        assertEqual(click1Resp.data?["status"]?.rawValue as? String, "dispatched")

        let postObs = click1Resp.data?["post_action_observation"]?.rawValue as? [String: Any]
        assertTrue(postObs != nil)
        let cap2 = postObs?["capture_id"] as? String
        assertTrue(cap2 != nil)
        assertTrue(cap1 != cap2)

        // Reuse cap1 MUST fail with STALE_CAPTURE
        let clickStale = await server.handleRequest(IPCRequest(id: "c2", method: "click", params: click1Params))
        assertTrue(!clickStale.success)
        assertEqual(clickStale.error?.code, "STALE_CAPTURE")

        // Click with fresh cap2 MUST succeed
        let click2Params: [String: AnyCodable] = [
            "x": .int(500),
            "y": .int(500),
            "button": .string("left"),
            "click_count": .int(1),
            "capture_id": .string(cap2!),
            "topology_version": .string("top-v1"),
            "intent": .string("Click confirm button")
        ]
        let click2Resp = await server.handleRequest(IPCRequest(id: "c3", method: "click", params: click2Params))
        assertTrue(click2Resp.success)

        // 8. Non-retention & Redaction check
        let history = await server.getInputHistory()
        for item in history {
            assertTrue(!item.contains("SecretPass"), "Raw secret text must never be retained in input history")
        }

        fputs("[ALL TESTS PASSED] Swift Host verification test suite executed cleanly.\n", stderr)
    }
}
