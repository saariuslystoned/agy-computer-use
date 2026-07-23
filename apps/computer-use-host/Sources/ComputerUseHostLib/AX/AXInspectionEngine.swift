import Foundation
import ApplicationServices
import AppKit

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
    public let role: String
    public let subrole: String?
    public let title: String?
    public let value: String?
    public let enabled: Bool?
    public let focused: Bool?
    public let bounds: AXRect
    public let children: [AXNodeDTO]?

    public init(id: String, role: String, subrole: String? = nil, title: String? = nil, value: String? = nil, enabled: Bool? = nil, focused: Bool? = nil, bounds: AXRect, children: [AXNodeDTO]? = nil) {
        self.id = id
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
    public let topologyVersion: String
    public let nodeCount: Int
    public let maxDepthReached: Int
    public let truncated: Bool
    public let tree: AXNodeDTO

    enum CodingKeys: String, CodingKey {
        case targetApp = "target_app"
        case topologyVersion = "topology_version"
        case nodeCount = "node_count"
        case maxDepthReached = "max_depth_reached"
        case truncated
        case tree
    }

    public init(targetApp: AXTargetAppDTO, topologyVersion: String, nodeCount: Int, maxDepthReached: Int, truncated: Bool, tree: AXNodeDTO) {
        self.targetApp = targetApp
        self.topologyVersion = topologyVersion
        self.nodeCount = nodeCount
        self.maxDepthReached = maxDepthReached
        self.truncated = truncated
        self.tree = tree
    }
}

public protocol AXInspectionEngine: Sendable {
    var isAvailable: Bool { get }
    func isAccessibilityTrusted() -> Bool
    func inspectTree(maxDepth: Int, appId: String?, topologyVersion: String) throws -> AXTreeResultDTO
}

public extension AXInspectionEngine {
    func inspectTree(maxDepth: Int = 10, appId: String? = nil) throws -> AXTreeResultDTO {
        try inspectTree(maxDepth: maxDepth, appId: appId, topologyVersion: "")
    }
}

public struct DisabledAXInspector: AXInspectionEngine {
    public init() {}

    public var isAvailable: Bool { false }

    public func isAccessibilityTrusted() -> Bool {
        return false
    }

    public func inspectTree(maxDepth: Int = 10, appId: String? = nil, topologyVersion: String = "") throws -> AXTreeResultDTO {
        throw ComputerUseError.targetUnreachable(reason: "AX tree inspection is unavailable in this build phase")
    }
}

public struct DefaultAXInspector: AXInspectionEngine {
    public init() {}

    public var isAvailable: Bool {
        return AXIsProcessTrusted()
    }

    public func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    public func inspectTree(maxDepth requestedMaxDepth: Int = 10, appId: String? = nil, topologyVersion: String = "") throws -> AXTreeResultDTO {
        guard isAccessibilityTrusted() else {
            throw ComputerUseError.permissionDenied(permission: "accessibility")
        }

        let runningApps = NSWorkspace.shared.runningApplications
        var targetApp: NSRunningApplication? = nil

        if let query = appId?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            let matches = runningApps.filter { app in
                app.bundleIdentifier == query ||
                app.localizedName == query ||
                String(app.processIdentifier) == query
            }
            if matches.isEmpty {
                throw ComputerUseError.targetUnreachable(reason: "No running application matches identifier '\(query)'")
            }
            if matches.count > 1 {
                throw ComputerUseError.targetUnreachable(reason: "Ambiguous application identifier '\(query)' matches \(matches.count) running processes")
            }
            targetApp = matches.first
        } else {
            targetApp = NSWorkspace.shared.menuBarOwningApplication ?? NSWorkspace.shared.frontmostApplication
        }

        guard let app = targetApp, !app.isTerminated else {
            throw ComputerUseError.targetUnreachable(reason: "Target application is unavailable or terminated")
        }

        let pid = app.processIdentifier
        let appDTO = AXTargetAppDTO(pid: Int(pid), bundleId: app.bundleIdentifier, name: app.localizedName)
        let axApp = AXUIElementCreateApplication(pid)

        AXUIElementSetMessagingTimeout(axApp, 5.0)

        let maxDepth = min(max(1, requestedMaxDepth), BoundedAXTraverser.defaultMaxDepth)
        let maxNodes = BoundedAXTraverser.defaultMaxNodes

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
            didTimeout: &didTimeout
        ), !didTimeout else {
            if didTimeout {
                throw ComputerUseError.targetUnreachable(reason: "AX tree inspection timed out after 5.0 seconds")
            }
            throw ComputerUseError.targetUnreachable(reason: "Failed to extract root AX element for application '\(app.localizedName ?? "\(pid)")'")
        }

        return AXTreeResultDTO(
            targetApp: appDTO,
            topologyVersion: topologyVersion,
            nodeCount: nodeCount,
            maxDepthReached: maxDepthReached,
            truncated: isTruncated,
            tree: rootNode
        )
    }

    package static func boundsRect(position: CGPoint, size: CGSize) -> AXRect {
        AXRect(
            x: Double(position.x),
            y: Double(position.y),
            width: max(0.0, Double(size.width)),
            height: max(0.0, Double(size.height))
        )
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
        didTimeout: inout Bool
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
                        didTimeout: &didTimeout
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

        return AXNodeDTO(
            id: elementId,
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
