import Foundation
import CoreGraphics

/// Environment admission and target verification are mandatory dependencies.
/// Only the native process can mint permits; IPC booleans never authorize input.
package protocol ExclusiveEnvironmentProviding: Sendable {
    func admission(controller: String, hostInstance: String) throws -> ExclusiveEnvironmentAdmission
}
package struct ExclusiveEnvironmentAdmission: Equatable, Sendable {
    let identity: String
    let expiresAtMs: Int
    package init(identity: String, expiresAtMs: Int) { self.identity = identity; self.expiresAtMs = expiresAtMs }
}
package protocol ExclusiveFocusChecking: Sendable {
    func validate(point: CGPoint?, keyboard: Bool) throws
}
package protocol ExclusiveFocusProviding: Sendable {
    func bind(appID: String) throws -> any ExclusiveFocusChecking
}

public final class ExclusiveInputPermit: @unchecked Sendable {
    fileprivate let authorityID: UUID
    fileprivate let leaseID: String
    fileprivate let controller: String
    fileprivate let action: String
    fileprivate let captureID: String
    fileprivate var claimed = false
    fileprivate init(authorityID: UUID, leaseID: String, controller: String, action: String, captureID: String) {
        self.authorityID = authorityID; self.leaseID = leaseID; self.controller = controller
        self.action = action; self.captureID = captureID
    }
}

public final class ExclusiveInputAuthority: @unchecked Sendable {
    public let hostInstance = UUID().uuidString.lowercased()
    private let identity = UUID()
    private let lock = NSRecursiveLock()
    private let environment: any ExclusiveEnvironmentProviding
    private let focus: any ExclusiveFocusProviding
    private let now: @Sendable () -> Int
    private let monotonic: @Sendable () -> TimeInterval
    private struct Lease {
        let id: String
        let controller: String
        let admission: ExclusiveEnvironmentAdmission
        let deadline: TimeInterval
        let expiresAtMs: Int
        let target: any ExclusiveFocusChecking
    }
    private var lease: Lease?

    public convenience init() {
        self.init(environment: SystemExclusiveEnvironment(), focus: SystemExclusiveFocusProvider())
    }
    package init(environment: any ExclusiveEnvironmentProviding, focus: any ExclusiveFocusProviding,
                 now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
                 monotonic: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.environment = environment; self.focus = focus; self.now = now; self.monotonic = monotonic
    }
    public var isAdmitted: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let lease else { return false }
        do { try validate(lease); return true } catch { self.lease = nil; return false }
    }
    package func acquire(controller: String, appID: String, durationMs: Int) throws -> [String: AnyCodable] {
        lock.lock(); defer { lock.unlock() }
        guard !controller.isEmpty, !appID.isEmpty, (1_000...60_000).contains(durationMs) else {
            throw ComputerUseError.ipcError(reason: "Exclusive admission requires controller, explicit app and 1000...60000 ms duration")
        }
        if let existing = lease {
            do { try validate(existing) } catch { lease = nil }
            if lease != nil { throw ComputerUseError.exclusiveControlBusy }
        }
        let admission = try environment.admission(controller: controller, hostInstance: hostInstance)
        guard admission.expiresAtMs > now(), admission.expiresAtMs - now() <= 300_000 else {
            throw ComputerUseError.exclusiveControlExpired
        }
        let target = try focus.bind(appID: appID)
        try target.validate(point: nil, keyboard: false)
        let ttl = min(durationMs, admission.expiresAtMs - now())
        guard ttl > 0 else { throw ComputerUseError.exclusiveControlExpired }
        let created = Lease(id: "exclusive-\(UUID().uuidString.lowercased())", controller: controller,
            admission: admission, deadline: monotonic() + Double(ttl) / 1000,
            expiresAtMs: now() + ttl, target: target)
        lease = created
        return ["lease_id": .string(created.id), "expires_at_ms": .int(created.expiresAtMs),
                "strategy": .string("exclusive_global_hid"), "may_affect_pointer_or_focus": .bool(true)]
    }
    package func revoke(controller: String) {
        lock.lock(); defer { lock.unlock() }
        if lease?.controller == controller { lease = nil }
    }
    package func requireOwner(controller: String?, leaseID: String?, action: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let lease, controller == lease.controller, leaseID == lease.id else {
            throw ComputerUseError.operatorExclusiveRequired(action: action)
        }
        do { try validate(lease) } catch { self.lease = nil; throw error }
    }
    package func permit(controller: String?, leaseID: String?, action: String, captureID: String) throws -> ExclusiveInputPermit {
        lock.lock(); defer { lock.unlock() }
        try requireOwner(controller: controller, leaseID: leaseID, action: action)
        return ExclusiveInputPermit(authorityID: identity, leaseID: leaseID!, controller: controller!, action: action, captureID: captureID)
    }
    package func claim(_ permit: ExclusiveInputPermit?, action: String, captureID: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let permit, permit.authorityID == identity, !permit.claimed,
              permit.action == action, permit.captureID == captureID else {
            throw ComputerUseError.operatorExclusiveRequired(action: action)
        }
        permit.claimed = true
        try requireOwner(controller: permit.controller, leaseID: permit.leaseID, action: action)
    }
    package func validatePost(_ permit: ExclusiveInputPermit, point: CGPoint?, keyboard: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard !Task.isCancelled else { throw ComputerUseError.cancelled(reason: "Global input cancelled before next event") }
        guard permit.authorityID == identity, permit.claimed else { throw ComputerUseError.inputGuardUnavailable }
        try requireOwner(controller: permit.controller, leaseID: permit.leaseID, action: permit.action)
        guard let lease else { throw ComputerUseError.exclusiveControlRevoked }
        do {
            try lease.target.validate(point: point, keyboard: keyboard)
            try validateAdmission(lease) // target checks can block; expiry/revocation must still precede the post
        }
        catch { self.lease = nil; throw error }
    }
    private func validate(_ lease: Lease) throws {
        try validateAdmission(lease)
        try lease.target.validate(point: nil, keyboard: false)
        try validateAdmission(lease)
    }
    private func validateAdmission(_ lease: Lease) throws {
        guard now() < lease.expiresAtMs, monotonic() < lease.deadline else { throw ComputerUseError.exclusiveControlExpired }
        let current: ExclusiveEnvironmentAdmission
        do { current = try environment.admission(controller: lease.controller, hostInstance: hostInstance) }
        catch { throw ComputerUseError.exclusiveControlRevoked }
        guard current == lease.admission else { throw ComputerUseError.exclusiveControlRevoked }
    }
}
