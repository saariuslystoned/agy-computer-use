import Foundation
import AppKit
@preconcurrency import ApplicationServices
import Carbon

package struct SystemExclusiveFocusProvider: ExclusiveFocusProviding {
    package func bind(appID: String) throws -> any ExclusiveFocusChecking {
        let app = try AXWindowBindingStore.resolveApp(appID)
        guard app.isActive else { throw ComputerUseError.inputFocusChanged }
        let monitor = try ExclusiveInputMonitor(pid: app.processIdentifier)
        let topology = try SystemDisplayTopologyProvider().getTopology()
        var windows = AXWindowBindingStore()
        let discovered = try windows.discover(appID: appID, sessionID: "exclusive", topology: topology)
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.1)
        let focusedWindow = try SystemExclusiveFocus.element(axApp, kAXFocusedWindowAttribute)
        var matches: [AXWindowBinding] = []
        for descriptor in discovered.windows {
            let binding = try windows.resolve(ref: descriptor.windowRef, sessionID: "exclusive")
            if CFEqual(binding.element, focusedWindow) { matches.append(binding) }
        }
        guard matches.count == 1, let binding = matches.first else { throw ComputerUseError.inputFocusChanged }
        let focused = try SystemExclusiveFocus.element(axApp, kAXFocusedUIElementAttribute)
        let result = SystemExclusiveFocus(binding: binding, focused: focused,
            bounds: try binding.validate(), topology: topology.version, monitor: monitor)
        try result.validate(point: nil, keyboard: true)
        return result
    }
}

package final class SystemExclusiveFocus: ExclusiveFocusChecking, @unchecked Sendable {
    private let binding: AXWindowBinding
    private let focused: AXUIElement
    private let bounds: AXRect
    private let topology: String
    private let monitor: ExclusiveInputMonitor
    package init(binding: AXWindowBinding, focused: AXUIElement, bounds: AXRect,
                 topology: String, monitor: ExclusiveInputMonitor) {
        self.binding = binding; self.focused = focused; self.bounds = bounds
        self.topology = topology; self.monitor = monitor
    }
    package static func element(_ parent: AXUIElement, _ attribute: String) throws -> AXUIElement {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { throw ComputerUseError.inputFocusChanged }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    package func validate(point: CGPoint?, keyboard: Bool) throws {
        try monitor.validate()
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { throw ComputerUseError.inputGuardUnavailable }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == Int32(binding.app.pid),
              try binding.validate() == bounds,
              try SystemDisplayTopologyProvider().getTopology().version == topology else { throw ComputerUseError.inputFocusChanged }
        let app = AXUIElementCreateApplication(Int32(binding.app.pid))
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard CFEqual(try Self.element(app, kAXFocusedWindowAttribute), binding.element) else { throw ComputerUseError.inputFocusChanged }
        if keyboard {
            let current = try Self.element(app, kAXFocusedUIElementAttribute)
            guard CFEqual(current, focused) else { throw ComputerUseError.inputFocusChanged }
            AXUIElementSetMessagingTimeout(current, 0.1)
            var role: CFTypeRef?, subrole: CFTypeRef?, enabled: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role) == .success,
                  role is String else { throw ComputerUseError.inputGuardUnavailable }
            let subStatus = AXUIElementCopyAttributeValue(current, kAXSubroleAttribute as CFString, &subrole)
            guard subStatus == .success || subStatus == .attributeUnsupported || subStatus == .noValue else { throw ComputerUseError.inputGuardUnavailable }
            guard role as? String != "AXSecureTextField", subrole as? String != "AXSecureTextField" else { throw ComputerUseError.secureAXValueUnsupported }
            guard AXUIElementCopyAttributeValue(current, kAXEnabledAttribute as CFString, &enabled) == .success,
                  enabled as? Bool == true else { throw ComputerUseError.inputFocusChanged }
            // Secure semantics may be carried by an ancestor of a focused editor.
            var ancestor = current
            var seen: [AXUIElement] = []
            var reachedWindow = false
            for _ in 0..<32 {
                if CFEqual(ancestor, binding.element) { reachedWindow = true; break }
                guard !seen.contains(where: { CFEqual($0, ancestor) }) else { throw ComputerUseError.inputGuardUnavailable }
                seen.append(ancestor)
                AXUIElementSetMessagingTimeout(ancestor, 0.1)
                var ancestorRole: CFTypeRef?, ancestorSubrole: CFTypeRef?
                guard AXUIElementCopyAttributeValue(ancestor, kAXRoleAttribute as CFString, &ancestorRole) == .success,
                      ancestorRole is String else { throw ComputerUseError.inputGuardUnavailable }
                let status = AXUIElementCopyAttributeValue(ancestor, kAXSubroleAttribute as CFString, &ancestorSubrole)
                guard status == .success || status == .attributeUnsupported || status == .noValue else { throw ComputerUseError.inputGuardUnavailable }
                guard ancestorRole as? String != "AXSecureTextField", ancestorSubrole as? String != "AXSecureTextField" else { throw ComputerUseError.secureAXValueUnsupported }
                ancestor = try Self.element(ancestor, kAXParentAttribute)
            }
            guard reachedWindow else { throw ComputerUseError.inputGuardUnavailable }
            var pid: pid_t = 0
            guard AXUIElementGetPid(current, &pid) == .success, pid == Int32(binding.app.pid),
                  CFEqual(try Self.element(current, kAXWindowAttribute), binding.element) else { throw ComputerUseError.inputFocusChanged }
        }
        if let point {
            guard point.x >= bounds.x, point.y >= bounds.y, point.x < bounds.x + bounds.width,
                  point.y < bounds.y + bounds.height else { throw ComputerUseError.inputFocusChanged }
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.1)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
                  let hit else { throw ComputerUseError.inputGuardUnavailable }
            var pid: pid_t = 0
            guard AXUIElementGetPid(hit, &pid) == .success, pid == Int32(binding.app.pid),
                  CFEqual(try Self.element(hit, kAXWindowAttribute), binding.element) else { throw ComputerUseError.inputFocusChanged }
        }
        try monitor.validate()
    }
}
