import Foundation
import ApplicationServices
import AppKit
import CryptoKit

public struct AXRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct AXTargetAppDTO: Codable, Equatable, Sendable {
    public let pid: Int
    public let bundleId: String?
    public let name: String?

    enum CodingKeys: String, CodingKey {
        case pid
        case bundleId = "bundle_id"
        case name
    }

    public init(pid: Int, bundleId: String?, name: String?) {
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
    }
}

public struct AXNodeDTO: Codable, Equatable, Sendable {
    public let id: String
    public let elementRef: String?
    public let supportedActions: [String]?
    public let role: String
    public let subrole: String?
    public let title: String?
    public let value: String?
    public let enabled: Bool?
    public let focused: Bool?
    public let bounds: AXRect
    public let children: [AXNodeDTO]?

    enum CodingKeys: String, CodingKey {
        case id
        case elementRef = "element_ref"
        case supportedActions = "supported_actions"
        case role
        case subrole
        case title
        case value
        case enabled
        case focused
        case bounds
        case children
    }

    public init(id: String, elementRef: String? = nil, supportedActions: [String]? = nil, role: String, subrole: String? = nil, title: String? = nil, value: String? = nil, enabled: Bool? = nil, focused: Bool? = nil, bounds: AXRect, children: [AXNodeDTO]? = nil) {
        self.id = id
        self.elementRef = elementRef
        self.supportedActions = supportedActions
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.enabled = enabled
        self.focused = focused
        self.bounds = bounds
        self.children = children
    }
}

public struct AXTreeResultDTO: Codable, Equatable, Sendable {
    public let targetApp: AXTargetAppDTO
    public let axSnapshotId: String
    public let appInstanceRef: String
    public let expiresAtMs: Int
    public let topologyVersion: String
    public let nodeCount: Int
    public let maxDepthReached: Int
    public let truncated: Bool
    public let tree: AXNodeDTO

    enum CodingKeys: String, CodingKey {
        case targetApp = "target_app"
        case axSnapshotId = "ax_snapshot_id"
        case appInstanceRef = "app_instance_ref"
        case expiresAtMs = "expires_at_ms"
        case topologyVersion = "topology_version"
        case nodeCount = "node_count"
        case maxDepthReached = "max_depth_reached"
        case truncated
        case tree
    }

    public init(targetApp: AXTargetAppDTO, axSnapshotId: String, appInstanceRef: String, expiresAtMs: Int, topologyVersion: String, nodeCount: Int, maxDepthReached: Int, truncated: Bool, tree: AXNodeDTO) {
        self.targetApp = targetApp
        self.axSnapshotId = axSnapshotId
        self.appInstanceRef = appInstanceRef
        self.expiresAtMs = expiresAtMs
        self.topologyVersion = topologyVersion
        self.nodeCount = nodeCount
        self.maxDepthReached = maxDepthReached
        self.truncated = truncated
        self.tree = tree
    }
}

public struct AXSemanticActionResultDTO: Codable, Equatable, Sendable {
    public let actionId: String
    public let status: String
    public let strategy: String
    public let action: String
    public let axSnapshotId: String
    public let appInstanceRef: String
    public let elementRef: String
    public let topologyVersion: String
    public let requiresReinspection: Bool
    public let globalHIDPosts: Int
    public let durationMs: Double

    enum CodingKeys: String, CodingKey {
        case actionId = "action_id"
        case status
        case strategy
        case action
        case axSnapshotId = "ax_snapshot_id"
        case appInstanceRef = "app_instance_ref"
        case elementRef = "element_ref"
        case topologyVersion = "topology_version"
        case requiresReinspection = "requires_reinspection"
        case globalHIDPosts = "global_hid_posts"
        case durationMs = "duration_ms"
    }

    public init(
        actionId: String,
        status: String,
        strategy: String = "ax_semantic",
        action: String,
        axSnapshotId: String,
        appInstanceRef: String,
        elementRef: String,
        topologyVersion: String,
        requiresReinspection: Bool = true,
        globalHIDPosts: Int = 0,
        durationMs: Double
    ) {
        self.actionId = actionId
        self.status = status
        self.strategy = strategy
        self.action = action
        self.axSnapshotId = axSnapshotId
        self.appInstanceRef = appInstanceRef
        self.elementRef = elementRef
        self.topologyVersion = topologyVersion
        self.requiresReinspection = requiresReinspection
        self.globalHIDPosts = globalHIDPosts
        self.durationMs = durationMs
    }
}

public protocol AXInspectionEngine: Sendable {
    var isAvailable: Bool { get }
    func isAccessibilityTrusted() -> Bool
    func inspectTree(maxDepth: Int, appId: String, topologyVersion: String) throws -> AXTreeResultDTO
}

public protocol AXSemanticActionEngine: Sendable {
    var isOperatorSafeActionAvailable: Bool { get }
    var supportedOperatorSafeActions: [String] { get }
    func performSemanticAction(
        snapshotId: String,
        appInstanceRef: String,
        elementRef: String,
        action: String,
        topologyVersion: String
    ) throws -> AXSemanticActionResultDTO
}

public struct DisabledAXSemanticActionEngine: AXSemanticActionEngine {
    public init() {}

    public var isOperatorSafeActionAvailable: Bool { false }
    public var supportedOperatorSafeActions: [String] { [] }

    public func performSemanticAction(
        snapshotId: String,
        appInstanceRef: String,
        elementRef: String,
        action: String,
        topologyVersion: String
    ) throws -> AXSemanticActionResultDTO {
        throw ComputerUseError.noninterferingActionUnsupported(action: action)
    }
}

public struct DisabledAXInspector: AXInspectionEngine {
    public init() {}

    public var isAvailable: Bool { false }

    public func isAccessibilityTrusted() -> Bool {
        return false
    }

    public func inspectTree(maxDepth: Int, appId: String, topologyVersion: String) throws -> AXTreeResultDTO {
        throw ComputerUseError.targetUnreachable(reason: "AX tree inspection is unavailable in this build phase")
    }
}

package struct OperatorInputEpoch: Equatable, Sendable {
    package let counters: [UInt32]

    package init(counters: [UInt32]) {
        self.counters = counters
    }
}

package protocol OperatorInputEpochProviding: Sendable {
    func currentEpoch() -> OperatorInputEpoch
}

package final class AXSemanticOperationGate: @unchecked Sendable {
    private let lock = NSLock()

    package init() {}

    package func lockOperation() {
        lock.lock()
    }

    package func unlockOperation() {
        lock.unlock()
    }
}

package struct AXRetainedAuthorityValidation: Equatable, Sendable {
    package let windowIdentityMatches: Bool
    package let ancestryMatches: Bool
    package let elementFingerprintMatches: Bool
    package let windowFingerprintMatches: Bool
    package let operatorInputChanged: Bool

    package init(
        windowIdentityMatches: Bool,
        ancestryMatches: Bool,
        elementFingerprintMatches: Bool,
        windowFingerprintMatches: Bool,
        operatorInputChanged: Bool
    ) {
        self.windowIdentityMatches = windowIdentityMatches
        self.ancestryMatches = ancestryMatches
        self.elementFingerprintMatches = elementFingerprintMatches
        self.windowFingerprintMatches = windowFingerprintMatches
        self.operatorInputChanged = operatorInputChanged
    }
}

private struct SystemOperatorInputEpochProvider: OperatorInputEpochProviding {
    private static let observedEventTypes: [CGEventType] = [
        .leftMouseDown,
        .leftMouseUp,
        .rightMouseDown,
        .rightMouseUp,
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .keyDown,
        .keyUp,
        .flagsChanged,
        .scrollWheel,
        .otherMouseDown,
        .otherMouseUp,
        .otherMouseDragged
    ]

    func currentEpoch() -> OperatorInputEpoch {
        OperatorInputEpoch(counters: Self.observedEventTypes.map {
            CGEventSource.counterForEventType(.combinedSessionState, eventType: $0)
        })
    }
}

private struct RetainedAXElement {
    let element: AXUIElement
    let window: AXUIElement
    let elementFingerprint: String
    let windowFingerprint: String
    let ancestry: [AXUIElement]
}

private struct RetainedAXSnapshot {
    let snapshotId: String
    let appInstanceRef: String
    let pid: pid_t
    let bundleId: String?
    let launchTime: TimeInterval
    let topologyVersion: String
    let leaseDeadline: ContinuousClock.Instant
    let operatorInputEpoch: OperatorInputEpoch
    let elements: [String: RetainedAXElement]
}

public final class DefaultAXInspector: AXInspectionEngine, AXSemanticActionEngine, @unchecked Sendable {
    private static let actionLeaseLifetimeMs = 30_000

    private let operationGate = AXSemanticOperationGate()
    private let operatorInputEpochProvider: any OperatorInputEpochProviding
    private var activeSnapshot: RetainedAXSnapshot?

    public convenience init() {
        self.init(operatorInputEpochProvider: SystemOperatorInputEpochProvider())
    }

    package init(operatorInputEpochProvider: any OperatorInputEpochProviding) {
        self.operatorInputEpochProvider = operatorInputEpochProvider
    }

    public var isAvailable: Bool {
        return AXIsProcessTrusted()
    }

    public func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    public var isOperatorSafeActionAvailable: Bool {
        isAccessibilityTrusted()
    }

    public var supportedOperatorSafeActions: [String] {
        isOperatorSafeActionAvailable ? ["press"] : []
    }

    public func inspectTree(maxDepth requestedMaxDepth: Int, appId: String, topologyVersion: String) throws -> AXTreeResultDTO {
        operationGate.lockOperation()
        defer { operationGate.unlockOperation() }

        guard isAccessibilityTrusted() else {
            throw ComputerUseError.permissionDenied(permission: "accessibility")
        }

        activeSnapshot = nil

        let runningApps = NSWorkspace.shared.runningApplications
        var targetApp: NSRunningApplication? = nil

        let explicitAppSelector = appId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !explicitAppSelector.isEmpty else {
            throw ComputerUseError.ipcError(reason: "app_id parameter is required and must be nonblank")
        }
        guard !topologyVersion.isEmpty else {
            throw ComputerUseError.staleTopology(current: "", received: topologyVersion)
        }

        let matches = runningApps.filter { app in
            app.bundleIdentifier == explicitAppSelector ||
            app.localizedName == explicitAppSelector ||
            String(app.processIdentifier) == explicitAppSelector
        }
        if matches.isEmpty {
            throw ComputerUseError.targetUnreachable(reason: "No running application matches identifier '\(explicitAppSelector)'")
        }
        if matches.count > 1 {
            throw ComputerUseError.targetUnreachable(reason: "Ambiguous application identifier '\(explicitAppSelector)' matches \(matches.count) running processes")
        }
        targetApp = matches.first

        guard let app = targetApp, !app.isTerminated else {
            throw ComputerUseError.targetUnreachable(reason: "Target application is unavailable or terminated")
        }

        let pid = app.processIdentifier
        let appDTO = AXTargetAppDTO(pid: Int(pid), bundleId: app.bundleIdentifier, name: app.localizedName)
        let axApp = AXUIElementCreateApplication(pid)

        AXUIElementSetMessagingTimeout(axApp, 5.0)

        let maxDepth = min(max(1, requestedMaxDepth), BoundedAXTraverser.defaultMaxDepth)
        let maxNodes = BoundedAXTraverser.defaultMaxNodes
        guard let launchTime = app.launchDate?.timeIntervalSince1970,
              launchTime.isFinite,
              launchTime > 0 else {
            throw ComputerUseError.staleOperation(reason: "Target application process birth identity is unavailable")
        }
        let operatorInputEpochBefore = operatorInputEpochProvider.currentEpoch()
        let snapshotId = "ax-snap-\(UUID().uuidString.lowercased())"
        let appInstanceRef = "app-inst-\(UUID().uuidString.lowercased())"
        let expiresAtMs = Int(Date().timeIntervalSince1970 * 1_000) + Self.actionLeaseLifetimeMs
        let leaseDeadline = ContinuousClock().now + .milliseconds(Int64(Self.actionLeaseLifetimeMs))
        var retainedElements: [String: RetainedAXElement] = [:]

        var nodeCount = 0
        var maxDepthReached = 0
        var isTruncated = false
        var visited = Set<AXUIElement>()
        var didTimeout = false

        let deadline = ContinuousClock().now + .seconds(5)

        guard let rootNode = DefaultAXInspector.buildNode(
            axElement: axApp,
            currentDepth: 1,
            maxDepth: maxDepth,
            nodeCount: &nodeCount,
            maxNodes: maxNodes,
            maxDepthReached: &maxDepthReached,
            isTruncated: &isTruncated,
            visited: &visited,
            deadline: deadline,
            didTimeout: &didTimeout,
            retainedElements: &retainedElements
        ), !didTimeout else {
            if didTimeout {
                throw ComputerUseError.targetUnreachable(reason: "AX tree inspection timed out after 5.0 seconds")
            }
            throw ComputerUseError.targetUnreachable(reason: "Failed to extract root AX element for application '\(app.localizedName ?? "\(pid)")'")
        }

        let operatorInputEpochAfter = operatorInputEpochProvider.currentEpoch()
        guard !Self.operatorInputChanged(
            from: operatorInputEpochBefore,
            to: operatorInputEpochAfter
        ) else {
            throw ComputerUseError.userIntervened(
                reason: "Operator or system input changed during AX inspection; no action lease was issued"
            )
        }

        activeSnapshot = RetainedAXSnapshot(
            snapshotId: snapshotId,
            appInstanceRef: appInstanceRef,
            pid: pid,
            bundleId: app.bundleIdentifier,
            launchTime: launchTime,
            topologyVersion: topologyVersion,
            leaseDeadline: leaseDeadline,
            operatorInputEpoch: operatorInputEpochAfter,
            elements: retainedElements
        )

        return AXTreeResultDTO(
            targetApp: appDTO,
            axSnapshotId: snapshotId,
            appInstanceRef: appInstanceRef,
            expiresAtMs: expiresAtMs,
            topologyVersion: topologyVersion,
            nodeCount: nodeCount,
            maxDepthReached: maxDepthReached,
            truncated: isTruncated,
            tree: rootNode
        )
    }

    public func performSemanticAction(
        snapshotId: String,
        appInstanceRef: String,
        elementRef: String,
        action: String,
        topologyVersion: String
    ) throws -> AXSemanticActionResultDTO {
        operationGate.lockOperation()
        defer { operationGate.unlockOperation() }

        guard isAccessibilityTrusted() else {
            throw ComputerUseError.permissionDenied(permission: "accessibility")
        }

        let normalizedAction = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedAction == "press" else {
            throw ComputerUseError.noninterferingActionUnsupported(action: normalizedAction)
        }

        let retained: RetainedAXSnapshot
        let retainedElement: RetainedAXElement
        guard let current = activeSnapshot else {
            throw ComputerUseError.staleAXSnapshot(current: "", received: snapshotId)
        }
        guard current.snapshotId == snapshotId else {
            throw ComputerUseError.staleAXSnapshot(current: current.snapshotId, received: snapshotId)
        }
        guard current.appInstanceRef == appInstanceRef else {
            throw ComputerUseError.staleOperation(reason: "App instance reference does not match the retained AX snapshot")
        }
        guard current.topologyVersion == topologyVersion else {
            throw ComputerUseError.staleTopology(current: current.topologyVersion, received: topologyVersion)
        }
        guard Self.isActionLeaseUnexpired(
            now: ContinuousClock().now,
            deadline: current.leaseDeadline
        ) else {
            activeSnapshot = nil
            throw ComputerUseError.staleAXSnapshot(current: "", received: snapshotId)
        }
        guard let element = current.elements[elementRef] else {
            throw ComputerUseError.targetUnreachable(reason: "Unknown or non-actionable AX element reference")
        }

        retained = current
        retainedElement = element
        activeSnapshot = nil

        guard !Self.operatorInputChanged(
            from: retained.operatorInputEpoch,
            to: operatorInputEpochProvider.currentEpoch()
        ) else {
            throw ComputerUseError.userIntervened(
                reason: "Operator or system input changed after AX inspection; the one-shot lease was consumed"
            )
        }

        guard let runningApp = NSRunningApplication(processIdentifier: retained.pid),
              !runningApp.isTerminated else {
            throw ComputerUseError.staleOperation(reason: "Target application process is no longer running")
        }
        guard runningApp.bundleIdentifier == retained.bundleId else {
            throw ComputerUseError.staleOperation(reason: "Target application bundle identity changed")
        }
        guard Self.matchesProcessBirth(
            expectedLaunchTime: retained.launchTime,
            currentLaunchTime: runningApp.launchDate?.timeIntervalSince1970
        ) else {
            throw ComputerUseError.staleOperation(reason: "Target application process birth identity changed")
        }

        var elementPID: pid_t = 0
        guard AXUIElementGetPid(retainedElement.element, &elementPID) == .success,
              elementPID == retained.pid else {
            throw ComputerUseError.staleOperation(reason: "Retained AX element process identity changed")
        }

        var windowPID: pid_t = 0
        guard AXUIElementGetPid(retainedElement.window, &windowPID) == .success,
              windowPID == retained.pid else {
            throw ComputerUseError.staleOperation(reason: "Retained AX window process identity changed")
        }

        var enabledValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            retainedElement.element,
            kAXEnabledAttribute as CFString,
            &enabledValue
        ) == .success,
              let enabled = enabledValue as? Bool else {
            throw ComputerUseError.staleOperation(reason: "Retained AX element enabled state is unavailable")
        }
        guard enabled else {
            throw ComputerUseError.targetUnreachable(reason: "Retained AX element is disabled")
        }

        guard Self.safeActions(for: retainedElement.element).contains("press") else {
            throw ComputerUseError.noninterferingActionUnsupported(action: normalizedAction)
        }
        let currentWindow = Self.windowElement(for: retainedElement.element)
        let currentAncestry = Self.ancestryPath(
            from: retainedElement.element,
            to: retainedElement.window
        )
        try Self.validateRetainedAuthority(AXRetainedAuthorityValidation(
            windowIdentityMatches: currentWindow.map {
                CFEqual($0, retainedElement.window)
            } ?? false,
            ancestryMatches: currentAncestry.map {
                Self.ancestryMatches($0, retainedElement.ancestry)
            } ?? false,
            elementFingerprintMatches:
                Self.semanticFingerprint(for: retainedElement.element) == retainedElement.elementFingerprint,
            windowFingerprintMatches:
                Self.semanticFingerprint(for: retainedElement.window) == retainedElement.windowFingerprint,
            operatorInputChanged: Self.operatorInputChanged(
                from: retained.operatorInputEpoch,
                to: operatorInputEpochProvider.currentEpoch()
            )
        ))

        let startedAt = ContinuousClock().now
        let axResult = try Self.performAXActionCheckingOperatorInput(
            observedEpoch: retained.operatorInputEpoch,
            epochProvider: operatorInputEpochProvider
        ) {
            AXUIElementPerformAction(retainedElement.element, kAXPressAction as CFString)
        }
        let duration = ContinuousClock().now - startedAt
        let durationComponents = duration.components
        let durationMs =
            Double(durationComponents.seconds) * 1_000 +
            Double(durationComponents.attoseconds) / 1_000_000_000_000_000

        switch axResult {
        case .success:
            return AXSemanticActionResultDTO(
                actionId: "ax-act-\(UUID().uuidString.lowercased())",
                status: "dispatched",
                action: normalizedAction,
                axSnapshotId: snapshotId,
                appInstanceRef: appInstanceRef,
                elementRef: elementRef,
                topologyVersion: topologyVersion,
                durationMs: max(0, durationMs)
            )
        case .actionUnsupported:
            throw ComputerUseError.noninterferingActionUnsupported(action: normalizedAction)
        case .cannotComplete:
            throw ComputerUseError.axOutcomeUnknown(reason: "AXPress could not complete before the target state was re-inspected")
        case .invalidUIElement:
            throw ComputerUseError.staleOperation(reason: "Retained AX element is no longer valid")
        default:
            throw ComputerUseError.targetUnreachable(reason: "AXPress failed with AX error \(axResult.rawValue)")
        }
    }

    package static func boundsRect(position: CGPoint, size: CGSize) -> AXRect {
        AXRect(
            x: Double(position.x),
            y: Double(position.y),
            width: max(0.0, Double(size.width)),
            height: max(0.0, Double(size.height))
        )
    }

    package static func operatorInputChanged(
        from observed: OperatorInputEpoch,
        to current: OperatorInputEpoch
    ) -> Bool {
        observed != current
    }

    package static func validateRetainedAuthority(
        _ validation: AXRetainedAuthorityValidation
    ) throws {
        guard validation.windowIdentityMatches else {
            throw ComputerUseError.staleOperation(
                reason: "Retained AX element window identity changed"
            )
        }
        guard validation.ancestryMatches else {
            throw ComputerUseError.staleOperation(
                reason: "Retained AX element ancestry changed"
            )
        }
        guard validation.elementFingerprintMatches else {
            throw ComputerUseError.staleOperation(
                reason: "Retained AX element semantic identity changed"
            )
        }
        guard validation.windowFingerprintMatches else {
            throw ComputerUseError.staleOperation(
                reason: "Retained AX window semantic identity changed"
            )
        }
        guard !validation.operatorInputChanged else {
            throw ComputerUseError.userIntervened(
                reason: "Operator or system input changed while the AX action was being validated; the one-shot lease was consumed"
            )
        }
    }

    package static func performAXActionCheckingOperatorInput(
        observedEpoch: OperatorInputEpoch,
        epochProvider: any OperatorInputEpochProviding,
        perform: () -> AXError
    ) throws -> AXError {
        let result = perform()
        guard !operatorInputChanged(
            from: observedEpoch,
            to: epochProvider.currentEpoch()
        ) else {
            throw ComputerUseError.userIntervened(
                reason: "Operator or system input changed during AX dispatch; the action outcome is unknown and requires fresh computer_use_ax_tree inspection"
            )
        }
        return result
    }

    package static func semanticFingerprint(components: [String]) -> String {
        let canonical = components.map { component in
            "\(component.utf8.count):\(component)"
        }.joined()
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    package static func isActionLeaseUnexpired(
        now: ContinuousClock.Instant,
        deadline: ContinuousClock.Instant
    ) -> Bool {
        now < deadline
    }

    package static func matchesProcessBirth(
        expectedLaunchTime: TimeInterval,
        currentLaunchTime: TimeInterval?
    ) -> Bool {
        guard expectedLaunchTime.isFinite,
              let currentLaunchTime,
              currentLaunchTime.isFinite else {
            return false
        }
        return abs(expectedLaunchTime - currentLaunchTime) <= 0.001
    }

    private static func safeActions(for element: AXUIElement) -> [String] {
        var actionNames: CFArray?
        guard AXUIElementCopyActionNames(element, &actionNames) == .success,
              let names = actionNames as? [String],
              names.contains(kAXPressAction as String) else {
            return []
        }
        return ["press"]
    }

    private static func semanticFingerprint(for element: AXUIElement) -> String? {
        let attributes: [(String, CFString)] = [
            ("role", kAXRoleAttribute as CFString),
            ("subrole", kAXSubroleAttribute as CFString),
            ("identifier", kAXIdentifierAttribute as CFString),
            ("title", kAXTitleAttribute as CFString),
            ("description", kAXDescriptionAttribute as CFString),
            ("value", kAXValueAttribute as CFString),
            ("enabled", kAXEnabledAttribute as CFString),
            ("focused", kAXFocusedAttribute as CFString),
            ("position", kAXPositionAttribute as CFString),
            ("size", kAXSizeAttribute as CFString)
        ]

        var components: [String] = []
        components.reserveCapacity(attributes.count + 1)
        for (name, attribute) in attributes {
            guard let value = stableAttributeComponent(
                for: element,
                attribute: attribute
            ) else {
                return nil
            }
            components.append("\(name)=\(value)")
        }

        var actionNames: CFArray?
        guard AXUIElementCopyActionNames(element, &actionNames) == .success,
              let names = actionNames as? [String],
              names.count <= 64 else {
            return nil
        }
        let sortedNames = names.sorted()
        guard sortedNames.allSatisfy({ $0.utf8.count <= 256 }) else {
            return nil
        }
        components.append("actions=\(semanticFingerprint(components: sortedNames))")
        return semanticFingerprint(components: components)
    }

    private static func stableAttributeComponent(
        for element: AXUIElement,
        attribute: CFString
    ) -> String? {
        var rawValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &rawValue)
        if result == .noValue || result == .attributeUnsupported || result == .notImplemented {
            return "missing"
        }
        guard result == .success, let rawValue else {
            return nil
        }

        let typeId = CFGetTypeID(rawValue)
        if typeId == CFStringGetTypeID(), let value = rawValue as? String {
            guard value.utf8.count <= 4_096 else {
                return nil
            }
            return "string:\(semanticFingerprint(components: [value]))"
        }
        if typeId == CFBooleanGetTypeID() {
            return (rawValue as! CFBoolean) == kCFBooleanTrue ? "bool:true" : "bool:false"
        }
        if typeId == CFNumberGetTypeID(), let value = rawValue as? NSNumber {
            return "number:\(value.stringValue)"
        }
        if typeId == AXValueGetTypeID() {
            let axValue = (rawValue as CFTypeRef) as! AXValue
            switch AXValueGetType(axValue) {
            case .cgPoint:
                var point = CGPoint.zero
                guard AXValueGetValue(axValue, .cgPoint, &point) else {
                    return nil
                }
                return "point:\(Double(point.x).bitPattern):\(Double(point.y).bitPattern)"
            case .cgSize:
                var size = CGSize.zero
                guard AXValueGetValue(axValue, .cgSize, &size) else {
                    return nil
                }
                return "size:\(Double(size.width).bitPattern):\(Double(size.height).bitPattern)"
            default:
                return nil
            }
        }
        return nil
    }

    private static func windowElement(for element: AXUIElement) -> AXUIElement? {
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXWindowAttribute as CFString,
            &windowValue
        ) == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (windowValue as! AXUIElement)
    }

    private static func ancestryPath(
        from element: AXUIElement,
        to window: AXUIElement
    ) -> [AXUIElement]? {
        var path: [AXUIElement] = []
        var current = element
        var visited = Set<AXUIElement>()
        visited.insert(element)

        for _ in 0..<64 {
            if CFEqual(current, window) {
                return path
            }

            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                current,
                kAXParentAttribute as CFString,
                &parentValue
            ) == .success,
                  let parentValue,
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
                return nil
            }
            let parent = (parentValue as! AXUIElement)
            guard !visited.contains(parent) else {
                return nil
            }
            visited.insert(parent)
            path.append(parent)
            current = parent
        }
        return nil
    }

    private static func ancestryMatches(
        _ current: [AXUIElement],
        _ retained: [AXUIElement]
    ) -> Bool {
        guard current.count == retained.count else {
            return false
        }
        return zip(current, retained).allSatisfy { CFEqual($0.0, $0.1) }
    }

    private static func buildNode(
        axElement: AXUIElement,
        currentDepth: Int,
        maxDepth: Int,
        nodeCount: inout Int,
        maxNodes: Int,
        maxDepthReached: inout Int,
        isTruncated: inout Bool,
        visited: inout Set<AXUIElement>,
        deadline: ContinuousClock.Instant,
        didTimeout: inout Bool,
        retainedElements: inout [String: RetainedAXElement]
    ) -> AXNodeDTO? {
        if ContinuousClock().now >= deadline {
            didTimeout = true
            return nil
        }

        if nodeCount >= maxNodes {
            isTruncated = true
            return nil
        }

        if visited.contains(axElement) {
            isTruncated = true
            return nil
        }
        visited.insert(axElement)
        nodeCount += 1
        let currentNodeIndex = nodeCount
        maxDepthReached = max(maxDepthReached, currentDepth)

        var roleStr = "AXUnknown"
        var subroleStr: String? = nil
        var titleStr: String? = nil
        var valueStr: String? = nil
        var enabledVal: Bool? = nil
        var focusedVal: Bool? = nil
        var boundsRect = AXRect(x: 0, y: 0, width: 0, height: 0)

        // Role
        var roleValue: CFTypeRef?
        let roleRes = AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue)
        if roleRes == .cannotComplete {
            didTimeout = true
            return nil
        }
        if roleRes == .success, let r = roleValue as? String {
            roleStr = r
        }

        // Subrole
        var subroleValue: CFTypeRef?
        let subroleRes = AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subroleValue)
        if subroleRes == .cannotComplete {
            didTimeout = true
            return nil
        }
        if subroleRes == .success, let sr = subroleValue as? String {
            subroleStr = sr
        }

        // Title
        var titleValue: CFTypeRef?
        let titleRes = AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &titleValue)
        if titleRes == .cannotComplete {
            didTimeout = true
            return nil
        }
        if titleRes == .success, let t = titleValue as? String {
            titleStr = t
        }

        // Value - Expose only explicitly supported safe scalar text/value shapes (CFString, CFNumber, CFBoolean)
        var valValue: CFTypeRef?
        let valRes = AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &valValue)
        if valRes == .cannotComplete {
            didTimeout = true
            return nil
        }
        if valRes == .success, let v = valValue {
            if let str = v as? String {
                valueStr = str
            } else if let num = v as? NSNumber {
                valueStr = num.stringValue
            } else if CFGetTypeID(v) == CFBooleanGetTypeID() {
                let b = (v as! CFBoolean) == kCFBooleanTrue
                valueStr = b ? "true" : "false"
            }
        }

        // Enabled
        var enabledValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXEnabledAttribute as CFString, &enabledValue) == .success,
           let e = enabledValue as? Bool {
            enabledVal = e
        }

        // Focused
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXFocusedAttribute as CFString, &focusedValue) == .success,
           let f = focusedValue as? Bool {
            focusedVal = f
        }

        // Position & Size -> Bounds with safe CFGetTypeID and AXValueGetType validation
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        var pt = CGPoint.zero
        var sz = CGSize.zero

        if AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &posValue) == .success,
           let posVal = posValue,
           CFGetTypeID(posVal) == AXValueGetTypeID() {
            let axVal = (posVal as CFTypeRef) as! AXValue
            if AXValueGetType(axVal) == .cgPoint {
                var rawPt = CGPoint.zero
                if AXValueGetValue(axVal, .cgPoint, &rawPt) {
                    pt = rawPt
                }
            }
        }

        if AXUIElementCopyAttributeValue(axElement, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let sizeVal = sizeValue,
           CFGetTypeID(sizeVal) == AXValueGetTypeID() {
            let axVal = (sizeVal as CFTypeRef) as! AXValue
            if AXValueGetType(axVal) == .cgSize {
                var rawSz = CGSize.zero
                if AXValueGetValue(axVal, .cgSize, &rawSz) {
                    sz = rawSz
                }
            }
        }
        boundsRect = Self.boundsRect(position: pt, size: sz)

        // Redaction & Truncation of Strings (capped strictly at <= 256 chars including ellipsis)
        let isSecure = (subroleStr == "AXSecureTextField" || subroleStr == (kAXSecureTextFieldSubrole as String))
        if isSecure {
            valueStr = BoundedAXTraverser.redactedPlaceholder
        } else if let v = valueStr {
            if v.count > BoundedAXTraverser.maxStringLength {
                valueStr = String(v.prefix(BoundedAXTraverser.maxStringLength - 3)) + "..."
                isTruncated = true
            }
        }

        if let t = titleStr, t.count > BoundedAXTraverser.maxStringLength {
            titleStr = String(t.prefix(BoundedAXTraverser.maxStringLength - 3)) + "..."
            isTruncated = true
        }

        // Children
        var childrenNodes: [AXNodeDTO] = []
        if currentDepth < maxDepth {
            var childrenValue: CFTypeRef?
            let childRes = AXUIElementCopyAttributeValue(axElement, kAXChildrenAttribute as CFString, &childrenValue)
            if childRes == .cannotComplete {
                didTimeout = true
                return nil
            }
            if childRes == .success, let childrenArr = childrenValue as? [AXUIElement] {
                for childAX in childrenArr {
                    if nodeCount >= maxNodes || ContinuousClock().now >= deadline {
                        if ContinuousClock().now >= deadline {
                            didTimeout = true
                            return nil
                        }
                        isTruncated = true
                        break
                    }
                    if let childDTO = buildNode(
                        axElement: childAX,
                        currentDepth: currentDepth + 1,
                        maxDepth: maxDepth,
                        nodeCount: &nodeCount,
                        maxNodes: maxNodes,
                        maxDepthReached: &maxDepthReached,
                        isTruncated: &isTruncated,
                        visited: &visited,
                        deadline: deadline,
                        didTimeout: &didTimeout,
                        retainedElements: &retainedElements
                    ) {
                        childrenNodes.append(childDTO)
                    } else if didTimeout {
                        return nil
                    }
                }
            }
        } else {
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(axElement, kAXChildrenAttribute as CFString, &childrenValue) == .success,
               let childrenArr = childrenValue as? [AXUIElement], !childrenArr.isEmpty {
                isTruncated = true
            }
        }

        let elementId = "ax-\(roleStr)-\(currentNodeIndex)"
        var elementRef: String?
        var supportedActions: [String]?

        if !isSecure,
           enabledVal == true,
           let window = Self.windowElement(for: axElement),
           let elementFingerprint = Self.semanticFingerprint(for: axElement),
           let windowFingerprint = Self.semanticFingerprint(for: window),
           let ancestry = Self.ancestryPath(from: axElement, to: window) {
            let actions = Self.safeActions(for: axElement)
            if !actions.isEmpty {
                let ref = "ax-el-\(UUID().uuidString.lowercased())"
                retainedElements[ref] = RetainedAXElement(
                    element: axElement,
                    window: window,
                    elementFingerprint: elementFingerprint,
                    windowFingerprint: windowFingerprint,
                    ancestry: ancestry
                )
                elementRef = ref
                supportedActions = actions
            }
        }

        return AXNodeDTO(
            id: elementId,
            elementRef: elementRef,
            supportedActions: supportedActions,
            role: roleStr,
            subrole: subroleStr,
            title: titleStr,
            value: valueStr,
            enabled: enabledVal,
            focused: focusedVal,
            bounds: boundsRect,
            children: childrenNodes.isEmpty ? nil : childrenNodes
        )
    }
}

public enum BoundedAXTraverser {
    public static let defaultMaxDepth = 10
    public static let defaultMaxNodes = 500
    public static let maxStringLength = 256
    public static let redactedPlaceholder = "[REDACTED]"

    public static func sanitizeText(_ text: String?, isSecure: Bool) -> String? {
        guard let text = text else { return nil }
        if isSecure {
            return redactedPlaceholder
        }
        if text.count > maxStringLength {
            return String(text.prefix(maxStringLength - 3)) + "..."
        }
        return text
    }

    public static func sanitizeNode(_ node: AXNodeDTO, currentDepth: Int, maxDepth: Int, nodeCount: inout Int, maxNodes: Int, visited: inout Set<String>) -> AXNodeDTO? {
        if currentDepth > maxDepth || nodeCount >= maxNodes || visited.contains(node.id) {
            return nil
        }
        visited.insert(node.id)
        nodeCount += 1

        let isSecureRole = (node.subrole == "AXSecureTextField" || node.subrole == (kAXSecureTextFieldSubrole as String))
        let cleanValue = sanitizeText(node.value, isSecure: isSecureRole)
        let cleanTitle = sanitizeText(node.title, isSecure: false)

        var sanitizedChildren: [AXNodeDTO] = []
        if let children = node.children, currentDepth < maxDepth {
            for child in children {
                if let cleanChild = sanitizeNode(child, currentDepth: currentDepth + 1, maxDepth: maxDepth, nodeCount: &nodeCount, maxNodes: maxNodes, visited: &visited) {
                    sanitizedChildren.append(cleanChild)
                }
            }
        }

        return AXNodeDTO(
            id: node.id,
            elementRef: node.elementRef,
            supportedActions: node.supportedActions,
            role: node.role,
            subrole: node.subrole,
            title: cleanTitle,
            value: cleanValue,
            enabled: node.enabled,
            focused: node.focused,
            bounds: node.bounds,
            children: sanitizedChildren.isEmpty ? nil : sanitizedChildren
        )
    }
}
