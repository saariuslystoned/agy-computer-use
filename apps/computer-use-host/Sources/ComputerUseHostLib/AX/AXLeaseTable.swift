import Foundation

// Logical controller ownership, not an authentication boundary. The owner-only
// socket remains the security boundary. All access is under the inspector gate.
package struct AXLeaseTarget: Equatable {
    let pid: Int32
    let windowID: UInt32?
    package init(pid: Int32, windowID: UInt32?) { self.pid = pid; self.windowID = windowID }
    func overlaps(_ other: Self) -> Bool {
        pid == other.pid && (windowID == nil || other.windowID == nil || windowID == other.windowID)
    }
}

package struct AXLeaseTable<Value> {
    private struct Entry {
        let sessionID: String
        let target: AXLeaseTarget
        let deadline: ContinuousClock.Instant
        let value: Value
    }
    private var entries: [String: Entry] = [:]
    let capacity: Int
    package init(capacity: Int) { self.capacity = capacity }
    package var count: Int { entries.count }

    package mutating func prune(now: ContinuousClock.Instant) {
        entries = entries.filter { now < $0.value.deadline }
    }
    package mutating func insert(id: String, sessionID: String, target: AXLeaseTarget,
                                 deadline: ContinuousClock.Instant, value: Value,
                                 now: ContinuousClock.Instant) throws {
        prune(now: now)
        remove(sessionID: sessionID, target: target)
        guard entries.count < capacity, now < deadline else {
            throw ComputerUseError.targetUnreachable(reason: "AX lease capacity exhausted or observation expired")
        }
        entries[id] = Entry(sessionID: sessionID, target: target, deadline: deadline, value: value)
    }
    package mutating func value(id: String, sessionID: String, now: ContinuousClock.Instant) -> Value? {
        prune(now: now)
        guard let entry = entries[id], entry.sessionID == sessionID else { return nil }
        return entry.value
    }
    package mutating func remove(sessionID: String, target: AXLeaseTarget? = nil) {
        entries = entries.filter { $0.value.sessionID != sessionID || (target != nil && $0.value.target != target!) }
    }
    package mutating func consume(target: AXLeaseTarget) {
        // First writer under the operation gate wins. Every competing lease for
        // that exact target becomes stale before dispatch, even on uncertainty.
        entries = entries.filter { !$0.value.target.overlaps(target) }
    }
}

public protocol AXScopedInspectionEngine: AXInspectionEngine {
    func inspectTree(maxDepth: Int, appId: String, topologyVersion: String, sessionID: String) throws -> AXTreeResultDTO
    func closeSession(_ sessionID: String)
}

public protocol AXScopedActionEngine: AXActionObservationEngine {
    func performScopedSemanticAction(snapshotId: String, appInstanceRef: String, elementRef: String,
        action: String, value: String?, topologyVersion: String, sessionID: String,
        options: AXObservationOptions?) throws -> AXSemanticActionResultDTO
}
