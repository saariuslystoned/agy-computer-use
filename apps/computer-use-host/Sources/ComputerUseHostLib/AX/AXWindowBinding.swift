import Foundation
import AppKit
@preconcurrency import ApplicationServices

public struct AXWindowDescriptor: Codable, Equatable, Sendable {
    public let windowRef: String
    public let targetApp: AXTargetAppDTO
    public let title: String
    public let bounds: AXRect
    public let display: DisplayInfo
    public let expiresAtMs: Int
    enum CodingKeys: String, CodingKey {
        case windowRef = "window_ref", targetApp = "target_app", title, bounds, display
        case expiresAtMs = "expires_at_ms"
    }
}
public struct AXTargetDiscovery: Codable, Sendable {
    public let apps: [AXTargetAppDTO]
    public let windows: [AXWindowDescriptor]
    public let truncated: Bool
    public let topologyVersion: String
    enum CodingKeys: String, CodingKey {
        case apps, windows, truncated
        case topologyVersion = "topology_version"
    }
}

package struct AXWindowBinding: @unchecked Sendable {
    let ref: String
    let sessionID: String
    let app: AXTargetAppDTO
    let birth: TimeInterval
    let windowID: UInt32
    let element: AXUIElement
    let peers: [AXUIElement]
    let deadline: ContinuousClock.Instant
    let expiresAtMs: Int

    func validate() throws -> AXRect {
        guard let process = NSRunningApplication(processIdentifier: Int32(app.pid)), !process.isTerminated,
              process.bundleIdentifier == app.bundleId,
              DefaultAXInspector.matchesProcessBirth(expectedLaunchTime: birth,
                  currentLaunchTime: process.launchDate?.timeIntervalSince1970), ContinuousClock().now < deadline else {
            throw ComputerUseError.staleOperation(reason: "Window reference expired or process instance changed; rediscover the target")
        }
        let current = try AXWindowBindingStore.windows(pid: Int32(app.pid))
        guard current.count == peers.count,
              current.allSatisfy({ item in peers.contains { CFEqual(item, $0) } }),
              current.contains(where: { CFEqual($0, element) }) else {
            throw ComputerUseError.staleOperation(reason: "Window set changed, was replaced, or a dialog opened; rediscover the explicit app")
        }
        let bounds = try AXWindowBindingStore.bounds(element)
        let matching = AXWindowBindingStore.cgWindows(pid: Int32(app.pid)).filter { $0.id == windowID }
        guard matching.count == 1, matching[0].bounds == bounds else {
            throw ComputerUseError.staleOperation(reason: "Exact window identity or geometry changed during observation")
        }
        return bounds
    }
    func descriptor(topology: DisplayTopology) throws -> AXWindowDescriptor {
        let bounds = try validate()
        return AXWindowDescriptor(windowRef: ref, targetApp: app,
            title: String(AXWindowBindingStore.title(element).prefix(256)), bounds: bounds,
            display: try WindowGeometry.display(for: bounds, topology: topology), expiresAtMs: expiresAtMs)
    }
}

package enum WindowGeometry {
    package static func display(for bounds: AXRect, topology: DisplayTopology) throws -> DisplayInfo {
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.x.isFinite, bounds.y.isFinite,
              bounds.width > 0, bounds.height > 0 else {
            throw ComputerUseError.targetUnreachable(reason: "Window has invalid or empty geometry")
        }
        let x = bounds.x + bounds.width / 2, y = bounds.y + bounds.height / 2
        let centered = topology.displays.filter {
            x >= $0.originX && x < $0.originX + $0.widthPoints && y >= $0.originY && y < $0.originY + $0.heightPoints
        }
        guard centered.count == 1, let display = centered.first else {
            throw ComputerUseError.targetUnreachable(reason: "Window center has no unambiguous active display")
        }
        return display
    }
    // Pixel coordinates have a top-left origin and map to global display points.
    // A visual transform never grants global-input authority.
    package static func pixelToScreen(x: Double, y: Double, bounds: AXRect, pixelWidth: Int, pixelHeight: Int) throws -> Point2D {
        guard pixelWidth > 0, pixelHeight > 0, x.isFinite, y.isFinite,
              x >= 0, y >= 0, x < Double(pixelWidth), y < Double(pixelHeight) else {
            throw ComputerUseError.targetUnreachable(reason: "Window pixel coordinate is outside the captured image")
        }
        return Point2D(x: bounds.x + x * bounds.width / Double(pixelWidth),
                       y: bounds.y + y * bounds.height / Double(pixelHeight))
    }
}

package struct AXWindowBindingStore {
    private var bindings: [String: AXWindowBinding] = [:]
    mutating func prune() { bindings = bindings.filter { ContinuousClock().now < $0.value.deadline } }
    mutating func close(sessionID: String) { bindings = bindings.filter { $0.value.sessionID != sessionID } }
    mutating func lookup(ref: String, sessionID: String) -> AXWindowBinding? {
        prune()
        guard let binding = bindings[ref], binding.sessionID == sessionID else { return nil }
        return binding
    }
    mutating func resolve(ref: String, sessionID: String) throws -> AXWindowBinding {
        guard let binding = lookup(ref: ref, sessionID: sessionID) else {
            throw ComputerUseError.staleOperation(reason: "Unknown, expired or foreign-session window reference")
        }
        _ = try binding.validate()
        return binding
    }
    static func resolveApp(_ selector: String) throws -> NSRunningApplication {
        let matches: [NSRunningApplication]
        if let pid = Int32(selector), pid > 0 {
            matches = NSRunningApplication(processIdentifier: pid).map { [$0] } ?? []
        } else {
            let byBundle = NSRunningApplication.runningApplications(withBundleIdentifier: selector)
            matches = byBundle.isEmpty ? apps().filter { $0.localizedName == selector } : byBundle
        }
        guard matches.count == 1, let app = matches.first, !app.isTerminated else {
            throw ComputerUseError.targetUnreachable(reason: "Application selector is absent or ambiguous; use a discovered PID")
        }
        return app
    }
    static func apps() -> [NSRunningApplication] {
        // Window-server enumeration supplements NSWorkspace's cached inventory.
        let windowPIDs = cgWindows(pid: nil).map { $0.pid }
        let workspacePIDs = NSWorkspace.shared.runningApplications.map { $0.processIdentifier }
        return Set(windowPIDs + workspacePIDs).sorted().compactMap { NSRunningApplication(processIdentifier: $0) }
            .filter { !$0.isTerminated }
    }
    mutating func discover(appID: String?, sessionID: String, topology: DisplayTopology) throws -> AXTargetDiscovery {
        prune()
        guard let appID else {
            let all = Self.apps()
            return AXTargetDiscovery(apps: all.prefix(128).map {
                AXTargetAppDTO(pid: Int($0.processIdentifier), bundleId: $0.bundleIdentifier,
                    name: $0.localizedName.map { String($0.prefix(256)) })
            }, windows: [], truncated: all.count > 128, topologyVersion: topology.version)
        }
        let app = try Self.resolveApp(appID)
        guard let birth = app.launchDate?.timeIntervalSince1970, birth > 0 else {
            throw ComputerUseError.staleOperation(reason: "Process birth identity unavailable")
        }
        let windows = try Self.windows(pid: app.processIdentifier)
        guard windows.count <= 16 else {
            throw ComputerUseError.targetUnreachable(reason: "App exceeds bounded 16-window discovery; no partial selection issued")
        }
        let candidates = Self.cgWindows(pid: app.processIdentifier)
        // Do not evict another session's live references to make room.
        let retainedBindings = bindings.filter { $0.value.sessionID != sessionID || $0.value.app.pid != Int(app.processIdentifier) }
        guard retainedBindings.count + windows.count <= 64 else {
            throw ComputerUseError.targetUnreachable(reason: "Window reference capacity exhausted; close a session or wait for expiry")
        }
        let appDTO = AXTargetAppDTO(pid: Int(app.processIdentifier), bundleId: app.bundleIdentifier, name: app.localizedName)
        var created: [AXWindowBinding] = []
        let deadline = ContinuousClock().now + .seconds(5)
        for window in windows {
            guard ContinuousClock().now < deadline else { throw ComputerUseError.timeout(operation: "window discovery", seconds: 5) }
            let bounds = try Self.bounds(window)
            let title = Self.title(window)
            let matches = candidates.filter { $0.bounds == bounds && ($0.title == nil || $0.title == title) }
            let sameAXBounds = try windows.filter { try Self.bounds($0) == bounds && Self.title($0) == title }
            guard matches.count == 1, sameAXBounds.count == 1, let cg = matches.first else {
                throw ComputerUseError.targetUnreachable(reason: "AX/window-server binding is ambiguous or unavailable; no window was guessed")
            }
            let item = AXWindowBinding(ref: "ax-window-\(UUID().uuidString.lowercased())", sessionID: sessionID,
                app: appDTO, birth: birth, windowID: cg.id, element: window, peers: windows,
                deadline: ContinuousClock().now + .seconds(300), expiresAtMs: Int(Date().timeIntervalSince1970 * 1000) + 300_000)
            created.append(item)
        }
        let descriptors = try created.map { try $0.descriptor(topology: topology) }
        bindings = retainedBindings
        for binding in created { bindings[binding.ref] = binding }
        return AXTargetDiscovery(apps: [appDTO], windows: descriptors, truncated: false, topologyVersion: topology.version)
    }
    static func windows(pid: Int32) throws -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement] else {
            throw ComputerUseError.targetUnreachable(reason: "App window hierarchy unavailable")
        }
        if !windows.isEmpty { return windows }
        var recovered: [AXUIElement] = []
        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(app, attribute as CFString, &value)
            guard status == .success || status == .noValue || status == .attributeUnsupported else {
                throw ComputerUseError.targetUnreachable(reason: "Application window references unavailable")
            }
            if let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let element = value as! AXUIElement
                if !recovered.contains(where: { CFEqual($0, element) }) { recovered.append(element) }
            }
        }
        // A scalar main/focused reference is sufficient only when it accounts
        // for every public window-server candidate. Never hide ambiguity.
        guard recovered.count == cgWindows(pid: pid).count else {
            throw ComputerUseError.targetUnreachable(reason: "Window enumeration incomplete; exact selection would be ambiguous")
        }
        return recovered
    }
    static func title(_ element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }
    static func bounds(_ element: AXUIElement) throws -> AXRect {
        AXUIElementSetMessagingTimeout(element, 0.2)
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            throw ComputerUseError.targetUnreachable(reason: "Window geometry is unavailable")
        }
        let p = position as! AXValue, s = size as! AXValue
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetType(p) == .cgPoint, AXValueGetType(s) == .cgSize,
              AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &dimensions) else {
            throw ComputerUseError.targetUnreachable(reason: "Window geometry type mismatch")
        }
        return AXRect(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
    }
    struct CGWindowRecord { let id: UInt32; let pid: Int32; let bounds: AXRect; let title: String? }
    static func cgWindows(pid: Int32?) -> [CGWindowRecord] {
        let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard (row[kCGWindowLayer as String] as? Int) == 0,
                  let owner = row[kCGWindowOwnerPID as String] as? Int32, pid == nil || owner == pid,
                  let id = row[kCGWindowNumber as String] as? UInt32,
                  let raw = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: raw as CFDictionary), rect.width > 0, rect.height > 0 else { return nil }
            return CGWindowRecord(id: id, pid: owner,
                bounds: AXRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
                title: row[kCGWindowName as String] as? String)
        }
    }
}
