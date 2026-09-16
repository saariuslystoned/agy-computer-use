import Foundation

public struct AXObservationOptions: Codable, Equatable, Sendable {
    public let condition: String
    public let timeoutMs: Int

    enum CodingKeys: String, CodingKey {
        case condition
        case timeoutMs = "timeout_ms"
    }

    public init(condition: String, timeoutMs: Int) throws {
        guard ["snapshot", "semantic_change"].contains(condition),
              (100...2_000).contains(timeoutMs) else {
            throw ComputerUseError.ipcError(reason: "observe requires condition snapshot or semantic_change and timeout_ms between 100 and 2000")
        }
        self.condition = condition
        self.timeoutMs = timeoutMs
    }
}

public struct AXChangeSummary: Codable, Equatable, Sendable {
    public let added: Int
    public let removed: Int
    public let changed: Int
    public let nodeIds: [String]
    public let truncated: Bool

    enum CodingKeys: String, CodingKey {
        case added, removed, changed, truncated
        case nodeIds = "node_ids"
    }

    package var hasChanges: Bool { added + removed + changed > 0 }

    // These traversal IDs describe differences only; they never authorize actions.
    package static func compare(_ before: AXTreeResultDTO, _ after: AXTreeResultDTO) -> Self {
        func flatten(_ node: AXNodeDTO, into nodes: inout [String: AXNodeDTO]) {
            nodes[node.id] = AXNodeDTO(
                id: node.id, supportedActions: node.supportedActions,
                role: node.role, subrole: node.subrole, identifier: node.identifier,
                description: node.description, title: node.title, value: node.value,
                enabled: node.enabled, focused: node.focused, bounds: node.bounds
            )
            for child in node.children ?? [] { flatten(child, into: &nodes) }
        }
        var old: [String: AXNodeDTO] = [:]
        var new: [String: AXNodeDTO] = [:]
        flatten(before.tree, into: &old)
        flatten(after.tree, into: &new)
        let added = Set(new.keys).subtracting(old.keys)
        let removed = Set(old.keys).subtracting(new.keys)
        let changed = Set(old.keys).intersection(new.keys).filter { old[$0] != new[$0] }
        let ids = added.union(removed).union(changed).sorted()
        return Self(added: added.count, removed: removed.count, changed: changed.count,
                    nodeIds: Array(ids.prefix(16)),
                    truncated: ids.count > 16 || before.truncated || after.truncated)
    }
}

public struct AXActionObservation: Codable, Equatable, Sendable {
    public let status: String
    public let condition: String
    public let attempts: Int
    public let elapsedMs: Double
    public let state: AXTreeResultDTO?
    public let changes: AXChangeSummary?
    public let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case status, condition, attempts, state, changes
        case elapsedMs = "elapsed_ms"
        case errorCode = "error_code"
    }
}

public protocol AXActionObservationEngine: AXSemanticActionEngine {
    func performSemanticActionAndObserve(
        snapshotId: String, appInstanceRef: String, elementRef: String,
        action: String, value: String?, topologyVersion: String,
        options: AXObservationOptions
    ) throws -> AXSemanticActionResultDTO
}

// Production orchestration; injected clocks/readers also exercise deterministic
// timeout, delayed-change, failure and no-repeat behavior without TCC authority.
package enum AXActionObservationRunner {
    package static func run(
        baseline: AXTreeResultDTO,
        options: AXObservationOptions,
        dispatch: () throws -> AXSemanticActionResultDTO,
        inspect: (ContinuousClock.Instant) throws -> AXTreeResultDTO,
        invalidate: () -> Void,
        now: () -> ContinuousClock.Instant = { ContinuousClock().now },
        wait: (Int) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1_000) }
    ) throws -> AXSemanticActionResultDTO {
        // Never retry or inspect automatically after an action-side error.
        var receipt = try dispatch()
        let start = now()
        let deadline = start + .milliseconds(options.timeoutMs)
        var attempts = 0
        var lastState: AXTreeResultDTO?
        var lastChanges: AXChangeSummary?
        func observation(_ status: String, error: String? = nil) -> AXActionObservation {
            let duration = start.duration(to: now()).components
            return AXActionObservation(
                status: status, condition: options.condition, attempts: attempts,
                elapsedMs: max(0, Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15),
                state: lastState, changes: lastChanges, errorCode: error
            )
        }
        while now() < deadline {
            attempts += 1
            do {
                let state = try inspect(deadline)
                guard state.targetApp.pid == baseline.targetApp.pid,
                      state.targetApp.bundleId == baseline.targetApp.bundleId,
                      state.topologyVersion == baseline.topologyVersion,
                      state.axSnapshotId != baseline.axSnapshotId,
                      state.appInstanceRef != baseline.appInstanceRef else {
                    throw ComputerUseError.staleOperation(reason: "Compound observation target or freshness changed")
                }
                guard now() < deadline else {
                    invalidate()
                    lastState = nil
                    lastChanges = nil
                    receipt.observation = observation("timed_out", error: "TIMEOUT")
                    return receipt
                }
                lastState = state
                lastChanges = AXChangeSummary.compare(baseline, state)
                if lastChanges!.hasChanges || options.condition == "snapshot" {
                    receipt.observation = observation(lastChanges!.hasChanges ? "changed" : "unchanged")
                    return receipt
                }
            } catch {
                invalidate()
                lastState = nil
                lastChanges = nil
                let code = (error as? ComputerUseError)?.errorCode ?? "TARGET_UNREACHABLE"
                receipt.observation = observation(code == "TIMEOUT" ? "timed_out" : "failed", error: code)
                return receipt
            }
            // Poll only reads, never the mutation. Avoid issuing a lease that the
            // caller could mistake for fresh at a later timeout boundary.
            invalidate()
            lastState = nil
            lastChanges = nil
            let remaining = now().duration(to: deadline).components
            let remainingMs = Int(remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000)
            if remainingMs <= 0 { break }
            wait(min(100, remainingMs))
        }
        receipt.observation = observation("timed_out", error: "TIMEOUT")
        return receipt
    }
}
