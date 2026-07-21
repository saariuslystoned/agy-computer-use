import Foundation
import ApplicationServices

public struct AXRect: Codable, Equatable {
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

public struct AXNodeDTO: Codable, Equatable {
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

public protocol AXInspectionEngine {
    func inspectTree(maxDepth: Int, appId: String?) throws -> AXNodeDTO
    func isAccessibilityTrusted() -> Bool
}

public class BoundedAXTraverser {
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

        // Official macOS AX classifier: detect kAXSubroleAttribute == kAXSecureTextFieldSubrole ("AXSecureTextField")
        // Title matching is NOT used as a classifier per Apple AX guidelines.
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

public class FakeAXInspector: AXInspectionEngine {
    public init() {}

    public func isAccessibilityTrusted() -> Bool {
        // macOS AXIsProcessTrustedWithOptions async trust check API reference
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    public func inspectTree(maxDepth: Int = 10, appId: String? = nil) throws -> AXNodeDTO {
        var nodeCount = 0
        var visited = Set<String>()

        let rawRoot = AXNodeDTO(
            id: "app-root",
            role: "AXApplication",
            title: appId ?? "Finder",
            bounds: AXRect(x: 0, y: 0, width: 1920, height: 1080),
            children: [
                AXNodeDTO(
                    id: "win-1",
                    role: "AXWindow",
                    title: "Main Window",
                    bounds: AXRect(x: 100, y: 100, width: 800, height: 600),
                    children: [
                        AXNodeDTO(
                            id: "btn-open",
                            role: "AXButton",
                            title: "Open Document",
                            bounds: AXRect(x: 150, y: 500, width: 120, height: 30)
                        ),
                        AXNodeDTO(
                            id: "input-pass",
                            role: "AXTextField",
                            subrole: "AXSecureTextField",
                            title: "Secure Field",
                            value: "SecretPass123!",
                            bounds: AXRect(x: 300, y: 500, width: 200, height: 30)
                        )
                    ]
                )
            ]
        )

        guard let cleanTree = BoundedAXTraverser.sanitizeNode(rawRoot, currentDepth: 1, maxDepth: maxDepth, nodeCount: &nodeCount, maxNodes: BoundedAXTraverser.defaultMaxNodes, visited: &visited) else {
            throw ComputerUseError.targetUnreachable(reason: "AX Tree traversal failed or exceeded bounds")
        }

        return cleanTree
    }
}
