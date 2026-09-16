import Foundation
import ApplicationServices

// AppKit can return success plus an empty AXChildren/AXWindows array while its
// explicit AXMainWindow/AXFocusedWindow still exposes the live window. These
// attributes belong to the selected app, never the system's frontmost app.
package enum AXApplicationChildren {
    package static func read<Element>(role: String,
        children: () -> (AXError, [Element]?), windows: () -> (AXError, [Element]?),
        mainWindow: () -> (AXError, Element?), focusedWindow: () -> (AXError, Element?),
        equal: (Element, Element) -> Bool
    ) throws -> (elements: [Element], incomplete: Bool) {
        func check(_ error: AXError) throws {
            if error == .cannotComplete { throw ComputerUseError.timeout(operation: "AX children read", seconds: 0.1) }
            if ![AXError.success, .noValue, .attributeUnsupported, .notImplemented].contains(error) {
                throw ComputerUseError.staleOperation(reason: "AX hierarchy read failed")
            }
        }
        let (status, original) = children()
        try check(status)
        if let original, !original.isEmpty { return (original, false) }
        guard role == "AXApplication" else { return ([], false) }
        let (windowStatus, allWindows) = windows()
        try check(windowStatus)
        if let allWindows, !allWindows.isEmpty { return (allWindows, true) }
        var result: [Element] = []
        for (status, element) in [mainWindow(), focusedWindow()] {
            try check(status)
            if let element, !result.contains(where: { equal($0, element) }) { result.append(element) }
        }
        // Other windows/menu items may be absent; do not claim a complete tree.
        return (result, true)
    }
}
