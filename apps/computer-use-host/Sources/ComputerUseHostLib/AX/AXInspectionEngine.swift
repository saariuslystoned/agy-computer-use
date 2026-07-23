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

        let maxDepth = min(max(1, requestedMaxDepth), BoundedAXTraverser.defaultMaxDepth)
        let maxNodes = BoundedAXTraverser.defaultMaxNodes

        var nodeCount = 0
        var maxDepthReached = 0
        var isTruncated = false
        var visited = Set<AXUIElement>()

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
            deadline: deadline
        ) else {
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

    private static func buildNode(
        axElement: AXUIElement,
        currentDepth: Int,
        maxDepth: Int,
        nodeCount: inout Int,
        maxNodes: Int,
        maxDepthReached: inout Int,
        isTruncated: inout Bool,
        visited: inout Set<AXUIElement>,
        deadline: ContinuousClock.Instant
    ) -> AXNodeDTO? {
        if ContinuousClock().now >= deadline {
            isTruncated = true
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
        if AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue) == .success,
           let r = roleValue as? String {
            roleStr = r
        }

        // Subrole
        var subroleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subroleValue) == .success,
           let sr = subroleValue as? String {
            subroleStr = sr
        }

        // Title
        var titleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &titleValue) == .success,
           let t = titleValue as? String {
            titleStr = t
        }

        // Value
        var valValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &valValue) == .success {
            if let v = valValue as? String {
                valueStr = v
            } else if let v = valValue {
                valueStr = String(describing: v)
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

        // Position & Size -> Bounds
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        var pt = CGPoint.zero
        var sz = CGSize.zero

        if AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &posValue) == .success,
           let posVal = posValue {
            var rawPt = CGPoint.zero
            if AXValueGetValue(posVal as! AXValue, .cgPoint, &rawPt) {
                pt = rawPt
            }
        }

        if AXUIElementCopyAttributeValue(axElement, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let sizeVal = sizeValue {
            var rawSz = CGSize.zero
            if AXValueGetValue(sizeVal as! AXValue, .cgSize, &rawSz) {
                sz = rawSz
            }
        }
        boundsRect = AXRect(x: Double(pt.x), y: Double(pt.y), width: Double(sz.width), height: Double(sz.height))

        // Redaction & Truncation of Strings
        let isSecure = (subroleStr == "AXSecureTextField" || subroleStr == (kAXSecureTextFieldSubrole as String))
        if isSecure {
            valueStr = BoundedAXTraverser.redactedPlaceholder
        } else if let v = valueStr {
            if v.count > BoundedAXTraverser.maxStringLength {
                valueStr = String(v.prefix(BoundedAXTraverser.maxStringLength)) + "..."
                isTruncated = true
            }
        }

        if let t = titleStr, t.count > BoundedAXTraverser.maxStringLength {
            titleStr = String(t.prefix(BoundedAXTraverser.maxStringLength)) + "..."
            isTruncated = true
        }

        // Children
        var childrenNodes: [AXNodeDTO] = []
        if currentDepth < maxDepth {
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(axElement, kAXChildrenAttribute as CFString, &childrenValue) == .success,
               let childrenArr = childrenValue as? [AXUIElement] {
                for childAX in childrenArr {
                    if nodeCount >= maxNodes || ContinuousClock().now >= deadline {
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
                        deadline: deadline
                    ) {
                        childrenNodes.append(childDTO)
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

        let elementHash = abs(axElement.hashValue)
        let elementId = "ax-\(roleStr)-\(elementHash)"

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
            return String(text.prefix(maxStringLength)) + "..."
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
