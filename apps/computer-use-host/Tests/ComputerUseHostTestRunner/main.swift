import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import ComputerUseHostLib
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

private final class AtomicCounter: @unchecked Sendable {
    private var val: Int = 0
    private let lock = NSLock()
    func increment() { lock.lock(); val += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return val }
}

private final class ErrorBox: @unchecked Sendable {
    private var err: Error? = nil
    private let lock = NSLock()
    func set(_ error: Error) { lock.lock(); err = error; lock.unlock() }
    var value: Error? { lock.lock(); defer { lock.unlock() }; return err }
}

public final class TestManualClock: HostClock, @unchecked Sendable {
    private let lock = NSLock()
    private var currentInstant: ContinuousClock.Instant

    public init(initial: ContinuousClock.Instant = ContinuousClock().now) {
        self.currentInstant = initial
    }

    public var now: ContinuousClock.Instant {
        lock.lock(); defer { lock.unlock() }
        return currentInstant
    }

    public func advance(by duration: Duration) {
        lock.lock(); defer { lock.unlock() }
        currentInstant = currentInstant + duration
    }
}

public struct SleeperSnapshot: Equatable, Sendable {
    public let targetState: ManualSleeper.WaiterState?
    public let pendingIDs: [UInt64]
    public let bufferedAdvances: Int

    public init(targetState: ManualSleeper.WaiterState?, pendingIDs: [UInt64], bufferedAdvances: Int) {
        self.targetState = targetState
        self.pendingIDs = pendingIDs
        self.bufferedAdvances = bufferedAdvances
    }
}

public struct SleeperInvariantError: Error, Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable {
        case markRegistering
        case publication
        case finish
    }

    public let stage: Stage
    public let message: String

    public init(stage: Stage, message: String = "Sleeper invariant error") {
        self.stage = stage
        self.message = message
    }
}

public final class ManualSleeper: Sleeper, @unchecked Sendable {
    public enum WaiterState: Equatable, @unchecked Sendable {
        case reserved
        case registering
        case suspended(CheckedContinuation<Void, Error>)
        case waking
        case cancelledBeforePublish
        case cancelledAfterWake
        case corruptedTestState

        public static func == (lhs: WaiterState, rhs: WaiterState) -> Bool {
            switch (lhs, rhs) {
            case (.reserved, .reserved),
                 (.registering, .registering),
                 (.waking, .waking),
                 (.cancelledBeforePublish, .cancelledBeforePublish),
                 (.cancelledAfterWake, .cancelledAfterWake),
                 (.corruptedTestState, .corruptedTestState):
                return true
            case (.suspended, .suspended):
                return true
            default:
                return false
            }
        }
    }

    public struct Hooks: Sendable {
        public let afterReserveBeforeRegistering: (@Sendable (ManualSleeper, UInt64) -> Void)?
        public let preRegistration: (@Sendable (ManualSleeper, UInt64) -> Void)?
        public let afterSuspendedPublication: (@Sendable (ManualSleeper, UInt64) -> Void)?
        public let observerRegistered: (@Sendable (Int) -> Void)?
        public let wakeSelected: (@Sendable (ManualSleeper, UInt64) -> Void)?
        public let postResumeBeforeFinish: (@Sendable (ManualSleeper, UInt64) -> Void)?

        public init(
            afterReserveBeforeRegistering: (@Sendable (ManualSleeper, UInt64) -> Void)? = nil,
            preRegistration: (@Sendable (ManualSleeper, UInt64) -> Void)? = nil,
            afterSuspendedPublication: (@Sendable (ManualSleeper, UInt64) -> Void)? = nil,
            observerRegistered: (@Sendable (Int) -> Void)? = nil,
            wakeSelected: (@Sendable (ManualSleeper, UInt64) -> Void)? = nil,
            postResumeBeforeFinish: (@Sendable (ManualSleeper, UInt64) -> Void)? = nil
        ) {
            self.afterReserveBeforeRegistering = afterReserveBeforeRegistering
            self.preRegistration = preRegistration
            self.afterSuspendedPublication = afterSuspendedPublication
            self.observerRegistered = observerRegistered
            self.wakeSelected = wakeSelected
            self.postResumeBeforeFinish = postResumeBeforeFinish
        }
    }

    private let lock = NSLock()
    private var nextWaiterID: UInt64 = 0
    private var waiterStates: [UInt64: WaiterState] = [:]
    private var pendingOrder: [UInt64] = []
    private var issuedWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var suspendedWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var bufferedAdvances: Int = 0
    private var totalSuspendedRecorded: Int = 0

    private(set) public var issuedCount: Int = 0
    private(set) public var succeededCount: Int = 0
    private(set) public var cancelledCount: Int = 0
    private(set) public var invariantCount: Int = 0

    public let hooks: Hooks

    public init(hooks: Hooks = Hooks()) {
        self.hooks = hooks
    }

    public func getState(id: UInt64) -> WaiterState? {
        lock.lock()
        defer { lock.unlock() }
        return waiterStates[id]
    }

    public func snapshot(for id: UInt64) -> SleeperSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return SleeperSnapshot(
            targetState: waiterStates[id],
            pendingIDs: pendingOrder,
            bufferedAdvances: bufferedAdvances
        )
    }

    public func corruptStateForTest(id: UInt64, newState: WaiterState?) {
        lock.lock()
        defer { lock.unlock() }
        if let newState = newState {
            waiterStates[id] = newState
        } else {
            waiterStates.removeValue(forKey: id)
            pendingOrder.removeAll { $0 == id }
        }
    }

    private func reserveIDLocked() -> (UInt64, [CheckedContinuation<Void, Never>]) {
        lock.lock()
        defer { lock.unlock() }
        nextWaiterID += 1
        issuedCount += 1
        let id = nextWaiterID
        waiterStates[id] = .reserved
        let issuedToResume = collectIssuedWaitersLocked()
        return (id, issuedToResume)
    }

    private func markRegisteringLocked(id: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let state = waiterStates[id] else {
            invariantCount += 1
            throw SleeperInvariantError(stage: .markRegistering, message: "Missing state on markRegistering")
        }
        switch state {
        case .reserved:
            waiterStates[id] = .registering
        case .cancelledBeforePublish:
            break
        default:
            waiterStates.removeValue(forKey: id)
            pendingOrder.removeAll { $0 == id }
            invariantCount += 1
            throw SleeperInvariantError(stage: .markRegistering, message: "Invalid state \(state) on markRegistering")
        }
    }

    private enum PublicationAction {
        case failCancellation
        case wakeImmediately
        case suspended
        case invariantError(SleeperInvariantError)
    }

    private func installPublicationLocked(id: UInt64, continuation: CheckedContinuation<Void, Error>) -> (PublicationAction, [CheckedContinuation<Void, Never>], [CheckedContinuation<Void, Never>]) {
        lock.lock()
        defer { lock.unlock() }

        guard let state = waiterStates[id] else {
            invariantCount += 1
            return (.invariantError(SleeperInvariantError(stage: .publication, message: "Missing state on publication")), [], [])
        }

        switch state {
        case .cancelledBeforePublish:
            waiterStates.removeValue(forKey: id)
            cancelledCount += 1
            return (.failCancellation, [], [])
        case .registering, .reserved:
            if bufferedAdvances > 0 {
                bufferedAdvances -= 1
                waiterStates[id] = .waking
                let issued = collectIssuedWaitersLocked()
                return (.wakeImmediately, issued, [])
            }
            waiterStates[id] = .suspended(continuation)
            pendingOrder.append(id)
            totalSuspendedRecorded += 1
            let issued = collectIssuedWaitersLocked()
            let suspendedObs = collectSuspendedWaitersLocked()
            return (.suspended, issued, suspendedObs)
        default:
            waiterStates.removeValue(forKey: id)
            pendingOrder.removeAll { $0 == id }
            invariantCount += 1
            return (.invariantError(SleeperInvariantError(stage: .publication, message: "Invalid state \(state) on publication")), [], [])
        }
    }

    private enum WakeResult {
        case cancelled
        case succeeded
        case invariantError(SleeperInvariantError)
    }

    private func finishWakeLocked(id: UInt64) -> WakeResult {
        lock.lock()
        defer { lock.unlock() }
        guard let state = waiterStates.removeValue(forKey: id) else {
            invariantCount += 1
            return .invariantError(SleeperInvariantError(stage: .finish, message: "Missing state on finishWake"))
        }
        switch state {
        case .waking:
            succeededCount += 1
            return .succeeded
        case .cancelledAfterWake:
            cancelledCount += 1
            return .cancelled
        default:
            pendingOrder.removeAll { $0 == id }
            invariantCount += 1
            return .invariantError(SleeperInvariantError(stage: .finish, message: "Invalid state \(state) on finishWake"))
        }
    }

    public func sleep(nanoseconds: UInt64) async throws {
        let (id, issuedToResume) = reserveIDLocked()
        for iObs in issuedToResume { iObs.resume() }

        return try await withTaskCancellationHandler {
            hooks.afterReserveBeforeRegistering?(self, id)

            try markRegisteringLocked(id: id)

            hooks.preRegistration?(self, id)

            var wasImmediateWake = false

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let (action, issuedToResume, suspendedToResume) = installPublicationLocked(id: id, continuation: continuation)
                for iObs in issuedToResume { iObs.resume() }
                for sObs in suspendedToResume { sObs.resume() }

                switch action {
                case .failCancellation:
                    continuation.resume(throwing: CancellationError())
                case .wakeImmediately:
                    wasImmediateWake = true
                    continuation.resume()
                case .suspended:
                    hooks.afterSuspendedPublication?(self, id)
                case .invariantError(let err):
                    continuation.resume(throwing: err)
                }
            }

            if wasImmediateWake {
                hooks.wakeSelected?(self, id)
            } else {
                hooks.postResumeBeforeFinish?(self, id)
            }

            let res = finishWakeLocked(id: id)
            switch res {
            case .cancelled:
                throw CancellationError()
            case .invariantError(let err):
                throw err
            case .succeeded:
                break
            }
        } onCancel: {
            self.cancel(id: id)
        }
    }

    public func cancel(id: UInt64) {
        lock.lock()
        guard let state = waiterStates[id] else {
            lock.unlock()
            return
        }
        switch state {
        case .reserved, .registering:
            waiterStates[id] = .cancelledBeforePublish
            lock.unlock()
        case .suspended(let cont):
            waiterStates.removeValue(forKey: id)
            pendingOrder.removeAll { $0 == id }
            cancelledCount += 1
            lock.unlock()
            cont.resume(throwing: CancellationError())
        case .waking:
            waiterStates[id] = .cancelledAfterWake
            lock.unlock()
        case .cancelledBeforePublish, .cancelledAfterWake, .corruptedTestState:
            lock.unlock()
        }
    }

    private enum AdvanceAction {
        case buffered, wake(CheckedContinuation<Void, Error>, UInt64), none
    }

    public func advance() {
        let action: AdvanceAction = {
            lock.lock()
            defer { lock.unlock() }
            if pendingOrder.isEmpty {
                bufferedAdvances += 1
                return .buffered
            }
            let id = pendingOrder.removeFirst()
            guard let state = waiterStates[id] else {
                return .none
            }
            if case .suspended(let cont) = state {
                waiterStates[id] = .waking
                return .wake(cont, id)
            }
            return .none
        }()

        if case .wake(let cont, let id) = action {
            hooks.wakeSelected?(self, id)
            cont.resume()
        }
    }

    public func advanceAll() {
        let wakes: [(CheckedContinuation<Void, Error>, UInt64)] = {
            lock.lock()
            defer { lock.unlock() }
            var items: [(CheckedContinuation<Void, Error>, UInt64)] = []
            for id in pendingOrder {
                if let state = waiterStates[id], case .suspended(let cont) = state {
                    waiterStates[id] = .waking
                    items.append((cont, id))
                }
            }
            pendingOrder.removeAll()
            return items
        }()

        for (cont, id) in wakes {
            hooks.wakeSelected?(self, id)
            cont.resume()
        }
    }

    public func cancelAll() {
        lock.lock()
        var suspendedToCancel: [CheckedContinuation<Void, Error>] = []
        for (id, state) in waiterStates {
            switch state {
            case .reserved, .registering:
                waiterStates[id] = .cancelledBeforePublish
            case .suspended(let cont):
                suspendedToCancel.append(cont)
                cancelledCount += 1
            case .waking:
                waiterStates[id] = .cancelledAfterWake
            case .cancelledBeforePublish, .cancelledAfterWake, .corruptedTestState:
                break
            }
        }
        let keysToRemove = waiterStates.compactMap { (k, v) -> UInt64? in
            if case .suspended = v { return k }
            return nil
        }
        for k in keysToRemove { waiterStates.removeValue(forKey: k) }
        pendingOrder.removeAll()

        let issuedToResume = issuedWaiters.values.flatMap { $0 }
        issuedWaiters.removeAll()
        let suspendedObs = suspendedWaiters.values.flatMap { $0 }
        suspendedWaiters.removeAll()
        bufferedAdvances = 0
        lock.unlock()

        for cont in suspendedToCancel { cont.resume(throwing: CancellationError()) }
        for iObs in issuedToResume { iObs.resume() }
        for sObs in suspendedObs { sObs.resume() }
    }

    public func waitUntilIssued(count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if issuedCount >= count {
                lock.unlock()
                continuation.resume()
            } else {
                issuedWaiters[count, default: []].append(continuation)
                lock.unlock()
            }
        }
    }

    public func waitUntilSuspended(count: Int) async {
        let (alreadySuspended, registeredHook): (Bool, ((Int) -> Void)?) = {
            lock.lock()
            defer { lock.unlock() }
            if totalSuspendedRecorded >= count {
                return (true, nil)
            } else {
                return (false, hooks.observerRegistered)
            }
        }()

        if alreadySuspended {
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if totalSuspendedRecorded >= count {
                lock.unlock()
                continuation.resume()
            } else {
                suspendedWaiters[count, default: []].append(continuation)
                lock.unlock()
                if let obsHook = registeredHook {
                    obsHook(count)
                }
            }
        }
    }

    public func assertCounters(issued: Int, succeeded: Int, cancelled: Int, line: Int = #line) {
        lock.lock()
        let i = issuedCount
        let s = succeededCount
        let c = cancelledCount
        let inv = invariantCount
        lock.unlock()

        assertEqual(i, issued, "Exact issued counter mismatch at line \(line)")
        assertEqual(s, succeeded, "Exact succeeded counter mismatch at line \(line)")
        assertEqual(c, cancelled, "Exact cancelled counter mismatch at line \(line)")
        assertEqual(inv, 0, "Invariant count must be zero at line \(line)")
    }

    public func assertZeroState(line: Int = #line) {
        lock.lock()
        let stateCount = waiterStates.count
        let pendingCount = pendingOrder.count
        let issuedObsCount = issuedWaiters.values.reduce(0) { $0 + $1.count }
        let suspendedObsCount = suspendedWaiters.values.reduce(0) { $0 + $1.count }
        let advances = bufferedAdvances
        lock.unlock()

        assertEqual(stateCount, 0, "waiterStates must be empty at line \(line)")
        assertEqual(pendingCount, 0, "pendingOrder must be empty at line \(line)")
        assertEqual(issuedObsCount, 0, "issuedWaiters must be empty at line \(line)")
        assertEqual(suspendedObsCount, 0, "suspendedWaiters must be empty at line \(line)")
        assertEqual(advances, 0, "bufferedAdvances must be 0 at line \(line)")
    }

    public func assertNoUnresolvedContinuations() {
        lock.lock()
        let statesCount = waiterStates.count
        let issuedObs = issuedWaiters.values.reduce(0) { $0 + $1.count }
        let suspendedObs = suspendedWaiters.values.reduce(0) { $0 + $1.count }
        let pending = pendingOrder.count
        let advances = bufferedAdvances
        let issued = issuedCount
        let succeeded = succeededCount
        let cancelled = cancelledCount
        let inv = invariantCount
        lock.unlock()

        assertTrue(statesCount == 0 && issuedObs == 0 && suspendedObs == 0 && pending == 0 && advances == 0,
            "No active states (\(statesCount)), issued observers (\(issuedObs)), suspended observers (\(suspendedObs)), pending (\(pending)), or advances (\(advances)) must remain in ManualSleeper")
        assertEqual(issued, succeeded + cancelled,
            "Exact monotonic terminal counters reconciliation: issued (\(issued)) == succeeded (\(succeeded)) + cancelled (\(cancelled))")
        assertEqual(inv, 0, "Invariant count must be zero")
    }

    private func collectIssuedWaitersLocked() -> [CheckedContinuation<Void, Never>] {
        let currentCount = issuedCount
        var toResume: [CheckedContinuation<Void, Never>] = []
        for (targetCount, waiters) in issuedWaiters where currentCount >= targetCount {
            issuedWaiters.removeValue(forKey: targetCount)
            toResume.append(contentsOf: waiters)
        }
        return toResume
    }

    private func collectSuspendedWaitersLocked() -> [CheckedContinuation<Void, Never>] {
        let currentCount = totalSuspendedRecorded
        var toResume: [CheckedContinuation<Void, Never>] = []
        for (targetCount, waiters) in suspendedWaiters where currentCount >= targetCount {
            suspendedWaiters.removeValue(forKey: targetCount)
            toResume.append(contentsOf: waiters)
        }
        return toResume
    }
}

public final class ScriptedPOSIXSyscalls: POSIXSyscallProviding, @unchecked Sendable {
    private let underlying = DarwinPOSIXSyscalls.shared
    private let lock = NSLock()
    private var customErrno: Int32 = 0

    public var acceptHook: ((Int32, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?) -> Int32?)?
    public var readHook: ((Int32, UnsafeMutableRawPointer?, Int) -> Int?)?
    public var writeHook: ((Int32, UnsafeRawPointer?, Int) -> Int?)?
    public var listenHook: ((Int32, Int32) -> Int32?)?
    public var bindHook: ((Int32, UnsafePointer<sockaddr>?, socklen_t) -> Int32?)?
    public var fstatatHook: ((Int32, UnsafePointer<CChar>, UnsafeMutablePointer<stat>?, Int32) -> Int32?)?
    public var lstatHook: ((UnsafePointer<CChar>, UnsafeMutablePointer<stat>?) -> Int32?)?

    public var acceptCallCount: Int = 0
    public var readCallCount: Int = 0
    public var writeCallCount: Int = 0
    public var unlinkatCallCount: Int = 0
    public var closeCallCount: Int = 0
    public var unlinkedFiles: [String] = []
    public var openedDescriptors: [Int32] = []
    public var closedDescriptors: [Int32] = []
    public var openCounts: [Int32: Int] = [:]
    public var closeCounts: [Int32: Int] = [:]

    private var nextGeneration: UInt64 = 0
    private var activeGenerations: [UInt64: Int32] = [:]
    private var closedGenerations: Set<UInt64> = []

    public init() {}

    private func trackOpen(fd: Int32) {
        guard fd >= 0 else { return }
        lock.lock()
        nextGeneration += 1
        let gen = nextGeneration
        activeGenerations[gen] = fd
        openedDescriptors.append(fd)
        openCounts[fd, default: 0] += 1
        lock.unlock()
    }

    private func trackCloseSuccess(fd: Int32) {
        lock.lock()
        closeCallCount += 1
        closedDescriptors.append(fd)
        closeCounts[fd, default: 0] += 1
        if let (gen, _) = activeGenerations.first(where: { $1 == fd }) {
            activeGenerations.removeValue(forKey: gen)
            closedGenerations.insert(gen)
        }
        lock.unlock()
    }

    public var areAllDescriptorsClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return activeGenerations.isEmpty
    }

    public var activeGenerationCount: Int {
        lock.lock(); defer { lock.unlock() }
        return activeGenerations.count
    }

    public var lastErrno: Int32 {
        lock.lock(); defer { lock.unlock() }
        return customErrno != 0 ? customErrno : underlying.lastErrno
    }

    public func setErrno(_ value: Int32) {
        lock.lock(); defer { lock.unlock() }
        customErrno = value
        underlying.setErrno(value)
    }

    public func clearErrno() {
        lock.lock(); defer { lock.unlock() }
        customErrno = 0
        underlying.setErrno(0)
    }

    public func accept(_ socket: Int32, _ address: UnsafeMutablePointer<sockaddr>?, _ addressLen: UnsafeMutablePointer<socklen_t>?) -> Int32 {
        clearErrno()
        lock.lock()
        acceptCallCount += 1
        let hook = acceptHook
        lock.unlock()
        if let res = hook?(socket, address, addressLen) { return res }
        let fd = underlying.accept(socket, address, addressLen)
        if fd >= 0 {
            trackOpen(fd: fd)
        }
        return fd
    }

    public func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        clearErrno()
        lock.lock()
        readCallCount += 1
        let hook = readHook
        lock.unlock()
        if let res = hook?(fd, buf, count) { return res }
        return underlying.read(fd, buf, count)
    }

    public func write(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int {
        clearErrno()
        lock.lock()
        writeCallCount += 1
        let hook = writeHook
        lock.unlock()
        if let res = hook?(fd, buf, count) { return res }
        return underlying.write(fd, buf, count)
    }

    public func listen(_ socket: Int32, _ backlog: Int32) -> Int32 {
        clearErrno()
        if let res = listenHook?(socket, backlog) { return res }
        return underlying.listen(socket, backlog)
    }

    public func bind(_ socket: Int32, _ address: UnsafePointer<sockaddr>?, _ addressLen: socklen_t) -> Int32 {
        clearErrno()
        if let res = bindHook?(socket, address, addressLen) { return res }
        return underlying.bind(socket, address, addressLen)
    }

    public func socket(_ domain: Int32, _ type: Int32, _ protocol: Int32) -> Int32 {
        clearErrno()
        let fd = underlying.socket(domain, type, `protocol`)
        if fd >= 0 {
            trackOpen(fd: fd)
        }
        return fd
    }

    public func open(_ path: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32 {
        clearErrno()
        let fd = underlying.open(path, oflag, mode)
        if fd >= 0 {
            trackOpen(fd: fd)
        }
        return fd
    }

    public func openat(_ dirFd: Int32, _ path: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32 {
        clearErrno()
        let fd = underlying.openat(dirFd, path, oflag, mode)
        if fd >= 0 {
            trackOpen(fd: fd)
        }
        return fd
    }

    public func fcntl(_ fd: Int32, _ cmd: Int32, _ arg: Int32) -> Int32 { clearErrno(); return underlying.fcntl(fd, cmd, arg) }
    public func getsockopt(_ socket: Int32, _ level: Int32, _ optionName: Int32, _ optionValue: UnsafeMutableRawPointer?, _ optionLen: UnsafeMutablePointer<socklen_t>?) -> Int32 { clearErrno(); return underlying.getsockopt(socket, level, optionName, optionValue, optionLen) }
    public func lstat(_ path: UnsafePointer<CChar>, _ buf: UnsafeMutablePointer<stat>?) -> Int32 {
        clearErrno()
        if let res = lstatHook?(path, buf) { return res }
        return underlying.lstat(path, buf)
    }

    public func fstat(_ fd: Int32, _ buf: UnsafeMutablePointer<stat>?) -> Int32 { clearErrno(); return underlying.fstat(fd, buf) }
    public func fstatat(_ dirFd: Int32, _ path: UnsafePointer<CChar>, _ buf: UnsafeMutablePointer<stat>?, _ flag: Int32) -> Int32 {
        clearErrno()
        if let res = fstatatHook?(dirFd, path, buf, flag) { return res }
        return underlying.fstatat(dirFd, path, buf, flag)
    }

    public func fileFlock(_ fd: Int32, _ operation: Int32) -> Int32 { clearErrno(); return underlying.fileFlock(fd, operation) }
    public func unlink(_ path: UnsafePointer<CChar>) -> Int32 { clearErrno(); return underlying.unlink(path) }
    public func unlinkat(_ dirFd: Int32, _ path: UnsafePointer<CChar>, _ flag: Int32) -> Int32 {
        clearErrno()
        lock.lock()
        unlinkatCallCount += 1
        unlinkedFiles.append(String(cString: path))
        lock.unlock()
        return underlying.unlinkat(dirFd, path, flag)
    }
    public func rmdir(_ path: UnsafePointer<CChar>) -> Int32 { clearErrno(); return underlying.rmdir(path) }
    public func mkdir(_ path: UnsafePointer<CChar>, _ mode: mode_t) -> Int32 { clearErrno(); return underlying.mkdir(path, mode) }
    public func close(_ fd: Int32) -> Int32 {
        clearErrno()
        let ret = underlying.close(fd)
        if ret == 0 {
            trackCloseSuccess(fd: fd)
        }
        return ret
    }
    public func getuid() -> uid_t { underlying.getuid() }
    public func setsockopt(_ socket: Int32, _ level: Int32, _ optionName: Int32, _ optionValue: UnsafeRawPointer?, _ optionLen: socklen_t) -> Int32 { clearErrno(); return underlying.setsockopt(socket, level, optionName, optionValue, optionLen) }
    public func connect(_ socket: Int32, _ address: UnsafePointer<sockaddr>?, _ addressLen: socklen_t) -> Int32 { clearErrno(); return underlying.connect(socket, address, addressLen) }
    public func poll(_ fds: UnsafeMutablePointer<pollfd>?, _ nfds: nfds_t, _ timeout: Int32) -> Int32 { clearErrno(); return underlying.poll(fds, nfds, timeout) }
    public func getpeereid(_ socket: Int32, _ uid: UnsafeMutablePointer<uid_t>?, _ gid: UnsafeMutablePointer<gid_t>?) -> Int32 { clearErrno(); return underlying.getpeereid(socket, uid, gid) }
}

public final class FakeScreenRecordingAuthorizer: ScreenRecordingAuthorizing, @unchecked Sendable {
    public let granted: Bool
    public init(granted: Bool = true) { self.granted = granted }
    public var isScreenCaptureAccessGranted: Bool { return granted }
}

public final class FakeDisplayTopologyProvider: DisplayTopologyProviding, @unchecked Sendable {
    private let topology: DisplayTopology
    public init(topology: DisplayTopology? = nil) {
        let primary = DisplayInfo(id: 1, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: 0, originY: 0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)
        let token = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [primary])
        self.topology = topology ?? DisplayTopology(version: token, primaryDisplayId: 1, displays: [primary])
    }
    public func getTopology() throws -> DisplayTopology { return topology }
}

public final class ScriptedDisplayListEnumerator: DisplayListEnumerating, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [() throws -> (primaryId: Int, displayIDs: [Int])]

    public init(script: [() throws -> (primaryId: Int, displayIDs: [Int])]) {
        self.script = script
    }

    public func getActiveDisplays() throws -> (primaryId: Int, displayIDs: [Int]) {
        lock.lock()
        defer { lock.unlock() }
        guard !script.isEmpty else {
            throw ComputerUseError.targetUnreachable(reason: "Exhausted scripted display list passes")
        }
        return try script.removeFirst()()
    }
}

public final class FakeDescriptorProvider: DisplayDescriptorProviding, @unchecked Sendable {
    public init() {}
    public func getDisplayDescriptor(id: Int) throws -> (bounds: CGRect, rotation: Double, pixelWidth: Int, pixelHeight: Int, scale: Double) {
        return (CGRect(x: 0, y: 0, width: 1920, height: 1080), 0.0, 3840, 2160, 2.0)
    }
}

public final class CustomDescriptorProvider: DisplayDescriptorProviding, @unchecked Sendable {
    private let bounds: CGRect
    private let rotation: Double
    private let pixelWidth: Int
    private let pixelHeight: Int
    private let scale: Double

    public init(bounds: CGRect, rotation: Double, pixelWidth: Int, pixelHeight: Int, scale: Double) {
        self.bounds = bounds
        self.rotation = rotation
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
    }

    public func getDisplayDescriptor(id: Int) throws -> (bounds: CGRect, rotation: Double, pixelWidth: Int, pixelHeight: Int, scale: Double) {
        return (bounds, rotation, pixelWidth, pixelHeight, scale)
    }
}

public enum ControlledCaptureEngineError: Error, Equatable {
    case invalidIndex(Int)
}

public actor ControlledCaptureEngine: DisplayCaptureEngine {
    private var continuations: [Int: CheckedContinuation<CaptureFrameDTO, Error>] = [:]
    private var registrationWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var exitWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    private(set) public var invocationCount: Int = 0
    private(set) public var physicalExitCount: Int = 0

    public var pendingCount: Int {
        return continuations.count
    }

    public init() {}

    public func captureDisplay(displayId: Int?, topology: DisplayTopology) async throws -> CaptureFrameDTO {
        let index = invocationCount
        invocationCount += 1

        defer {
            physicalExitCount += 1
            notifyExitWaiters()
        }

        return try await withCheckedThrowingContinuation { continuation in
            continuations[index] = continuation
            notifyRegistrationWaiters()
        }
    }

    public func waitUntilRegistered(count: Int) async {
        if invocationCount >= count { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            registrationWaiters[count, default: []].append(continuation)
        }
    }

    private func notifyRegistrationWaiters() {
        let currentCount = invocationCount
        for (targetCount, waiters) in registrationWaiters where currentCount >= targetCount {
            registrationWaiters.removeValue(forKey: targetCount)
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    public func waitUntilExited(count: Int) async {
        if physicalExitCount >= count { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exitWaiters[count, default: []].append(continuation)
        }
    }

    private func notifyExitWaiters() {
        let currentCount = physicalExitCount
        for (targetCount, waiters) in exitWaiters where currentCount >= targetCount {
            exitWaiters.removeValue(forKey: targetCount)
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    @discardableResult
    public func complete(index: Int, with result: Result<CaptureFrameDTO, Error>) throws -> Bool {
        guard let continuation = continuations.removeValue(forKey: index) else {
            throw ControlledCaptureEngineError.invalidIndex(index)
        }
        continuation.resume(with: result)
        return true
    }
}

public final class FakeCaptureEngine: DisplayCaptureEngine, @unchecked Sendable {
    private let counter = AtomicCounter()
    private let delayMs: Double
    private let customTopologyVersion: String?
    private let largePayloadBytes: Int

    public init(delayMs: Double = 0.0, customTopologyVersion: String? = nil, largePayloadBytes: Int = 0) {
        self.delayMs = delayMs
        self.customTopologyVersion = customTopologyVersion
        self.largePayloadBytes = largePayloadBytes
    }

    public var invocationCount: Int { counter.value }

    public func captureDisplay(displayId: Int?, topology: DisplayTopology) async throws -> CaptureFrameDTO {
        counter.increment()
        if delayMs > 0 {
            try await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
        }
        return try generateDTO(topology: topology)
    }

    public func generateDTO(topology: DisplayTopology) throws -> CaptureFrameDTO {
        let display = topology.displays.first!
        let width = display.pixelWidth
        let height = display.pixelHeight

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ComputerUseError.ipcError(reason: "Failed to create fake test CGContext")
        }

        ctx.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImg = ctx.makeImage() else {
            throw ComputerUseError.ipcError(reason: "Failed to create fake CGImage")
        }

        let targetDisp = DisplayInfo(
            id: display.id,
            widthPoints: display.widthPoints,
            heightPoints: display.heightPoints,
            scaleFactor: display.scaleFactor,
            originX: display.originX,
            originY: display.originY,
            pixelWidth: width,
            pixelHeight: height,
            rotation: display.rotation
        )

        let (_, b64) = try SCScreenshotCaptureEngine.validateAndEncode(image: cgImg, targetDisplay: targetDisp, quality: 0.8)
        let versionToUse = customTopologyVersion ?? topology.version
        let finalB64 = largePayloadBytes > 0 ? b64 + String(repeating: "A", count: max(0, largePayloadBytes - b64.count)) : b64

        return CaptureFrameDTO(
            captureId: "cap-test-\(UUID().uuidString)",
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            topologyVersion: versionToUse,
            displayId: display.id,
            widthPoints: display.widthPoints,
            heightPoints: display.heightPoints,
            scaleFactor: display.scaleFactor,
            pixelWidth: width,
            pixelHeight: height,
            imageFormat: "jpeg",
            imageDataBase64: finalB64
        )
    }
}

public final class TrulyNoncooperativeCaptureEngine: DisplayCaptureEngine, @unchecked Sendable {
    private let delayMs: Double

    public init(delayMs: Double = 400.0) {
        self.delayMs = delayMs
    }

    public func captureDisplay(displayId: Int?, topology: DisplayTopology) async throws -> CaptureFrameDTO {
        let deadline = ContinuousClock().now + .milliseconds(delayMs)
        while ContinuousClock().now < deadline {
            let spinEnd = ContinuousClock().now + .milliseconds(1)
            while ContinuousClock().now < spinEnd {}
        }
        return try FakeCaptureEngine().generateDTO(topology: topology)
    }
}

private func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a != b {
        fputs("[FAIL] Assertion failed: '\(a)' != '\(b)'. \(msg) at \(file):\(line)\n", stderr)
        exit(1)
    }
}

private func assertTrue(_ cond: Bool, _ msg: String = "", file: String = #file, line: Int = #line) {
    if !cond {
        fputs("[FAIL] Assertion failed. \(msg) at \(file):\(line)\n", stderr)
        exit(1)
    }
}

private func fail(_ msg: String = "", file: String = #file, line: Int = #line) -> Never {
    fputs("[FAIL] \(msg) at \(file):\(line)\n", stderr)
    exit(1)
}

private func connectToSocket(at socketPath: String) throws -> Int32 {
    let clientFd = socket(AF_UNIX, SOCK_STREAM, 0)
    assertTrue(clientFd >= 0)

    var nosigpipe: Int32 = 1
    _ = setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_un()
    let pathBytes = socketPath.utf8CString
    addr.sun_len = UInt8(MemoryLayout<sa_family_t>.size + pathBytes.count)
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
        ptr.initializeMemory(as: CChar.self, repeating: 0)
        _ = pathBytes.withUnsafeBufferPointer { bPtr in memcpy(ptr.baseAddress!, bPtr.baseAddress!, bPtr.count) }
    }

    let sockLen = socklen_t(addr.sun_len)
    let connRes = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
            connect(clientFd, saPtr, sockLen)
        }
    }
    assertEqual(connRes, 0)
    return clientFd
}

private func sendIPCRequest(_ req: IPCRequest, to fd: Int32) throws {
    let reqData = try JSONEncoder().encode(req)
    let framed = try LengthPrefixedFramer.encode(payload: reqData)
    _ = framed.withUnsafeBytes { ptr in write(fd, ptr.baseAddress!, framed.count) }
}

private func readIPCResponse(from fd: Int32) throws -> IPCResponse {
    var headerBuf = [UInt8](repeating: 0, count: 4)
    let r1 = read(fd, &headerBuf, 4)
    guard r1 == 4 else {
        throw ComputerUseError.ipcError(reason: "Failed to read 4-byte header from client socket")
    }
    let respLen = Int(headerBuf[0]) << 24 | Int(headerBuf[1]) << 16 | Int(headerBuf[2]) << 8 | Int(headerBuf[3])

    var respBuf = [UInt8](repeating: 0, count: respLen)
    let r2 = read(fd, &respBuf, respLen)
    guard r2 == respLen else {
        throw ComputerUseError.ipcError(reason: "Failed to read \(respLen) payload bytes from client socket")
    }

    return try JSONDecoder().decode(IPCResponse.self, from: Data(respBuf))
}

@main
public struct ComputerUseHostTestRunner {
    public static func run01_LengthPrefixedFraming() async throws {
        let payload = Data("{\"id\":\"test-1\",\"method\":\"status\"}".utf8)
        let framed = try LengthPrefixedFramer.encode(payload: payload)
        assertEqual(framed.count, 4 + payload.count)
        var mutFramed = framed
        let decoded = try LengthPrefixedFramer.decode(from: &mutFramed)
        assertEqual(decoded, payload)
    }

    public static func run02_OversizedFramingHeaderRejection() async throws {
        var badHeader = Data([0x01, 0x00, 0x00, 0x01])
        badHeader.append(Data(repeating: 0, count: 10))
        var threwOversized = false
        do { _ = try LengthPrefixedFramer.decode(from: &badHeader) } catch { threwOversized = true }
        assertTrue(threwOversized)
    }

    public static func run03_DirectoryPreparation() async throws {
        let testDir = "/tmp/test-host-runner-prep-\(UUID().uuidString)"
        try SocketListener.prepareDirectory(at: testDir)
        var statBuf = stat()
        assertEqual(lstat(testDir, &statBuf), 0)
        assertEqual(statBuf.st_mode & 0o777, 0o700)
        _ = rmdir(testDir)
    }

    public static func run04_UDSClientServerRoundTrip() async throws {
        let sockPath = "/tmp/agy-test-c4-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath)
        let fakeEngine = FakeCaptureEngine()
        let server = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: fakeEngine,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector()
        )
        let listener = SocketListener(socketPath: sockPath, server: server)
        try listener.start()

        let acceptTask = Task { try await listener.acceptAndHandleOneConnection() }
        let clientFd = try connectToSocket(at: listener.socketPath)

        try sendIPCRequest(IPCRequest(id: "client-req-1", method: "status"), to: clientFd)
        _ = try await acceptTask.value

        let respObj = try readIPCResponse(from: clientFd)
        assertEqual(respObj.id, "client-req-1")
        assertTrue(respObj.success)

        close(clientFd)
        listener.stop()
    }

    public static func run05_PostTimeoutUDSRecovery() async throws {
        let sockPath5 = "/tmp/agy-test-c5-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath5)
        let timeoutEngine5 = TrulyNoncooperativeCaptureEngine(delayMs: 300.0)
        let server5 = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: timeoutEngine5,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector(),
            observationTimeoutSec: 0.05
        )
        let listener5 = SocketListener(socketPath: sockPath5, server: server5)
        try listener5.start()

        let acceptTask5a = Task { try await listener5.acceptAndHandleOneConnection() }
        let clientFd5a = try connectToSocket(at: listener5.socketPath)
        try sendIPCRequest(IPCRequest(id: "timeout-req-1", method: "observe"), to: clientFd5a)

        _ = try await acceptTask5a.value
        let resp5a = try readIPCResponse(from: clientFd5a)
        assertEqual(resp5a.id, "timeout-req-1")
        assertTrue(!resp5a.success)
        assertEqual(resp5a.error?.code, "TIMEOUT")
        close(clientFd5a)

        let acceptTask5b = Task { try await listener5.acceptAndHandleOneConnection() }
        let clientFd5b = try connectToSocket(at: listener5.socketPath)
        try sendIPCRequest(IPCRequest(id: "recovery-req-2", method: "status"), to: clientFd5b)

        _ = try await acceptTask5b.value
        let resp5b = try readIPCResponse(from: clientFd5b)
        assertEqual(resp5b.id, "recovery-req-2")
        assertTrue(resp5b.success)
        close(clientFd5b)

        listener5.stop()
    }

    public static func run06_SlowDripHeaderTimeout() async throws {
        let sockPath6 = "/tmp/agy-test-c6-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath6)
        let listener6 = SocketListener(
            socketPath: sockPath6,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )
        try listener6.start()

        let acceptTask6 = Task { try await listener6.acceptAndHandleOneConnection() }
        let clientFd6 = try connectToSocket(at: listener6.socketPath)

        let start6 = ContinuousClock().now
        for i in 0..<3 {
            let byte = Data([UInt8(i)])
            _ = byte.withUnsafeBytes { ptr in write(clientFd6, ptr.baseAddress!, 1) }
            try await Task.sleep(nanoseconds: 800_000_000)
        }

        _ = try await acceptTask6.value
        let elapsed6 = ContinuousClock().now - start6
        let elapsedSec6 = Double(elapsed6.components.seconds) + Double(elapsed6.components.attoseconds) / 1e18

        assertTrue(elapsedSec6 >= 1.8 && elapsedSec6 <= 3.5, "Header read phase deadline enforced in \(elapsedSec6)s")

        let resp6 = try readIPCResponse(from: clientFd6)
        assertTrue(!resp6.success)
        assertEqual(resp6.error?.code, "TIMEOUT")

        close(clientFd6)
        listener6.stop()
    }

    public static func run07_SlowDripBodyTimeout() async throws {
        let sockPath7 = "/tmp/agy-test-c7-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath7)
        let listener7 = SocketListener(
            socketPath: sockPath7,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )
        try listener7.start()

        let acceptTask7 = Task { try await listener7.acceptAndHandleOneConnection() }
        let clientFd7 = try connectToSocket(at: listener7.socketPath)

        let header7 = Data([0x00, 0x00, 0x00, 0x40])
        _ = header7.withUnsafeBytes { ptr in write(clientFd7, ptr.baseAddress!, 4) }

        let start7 = ContinuousClock().now
        for i in 0..<4 {
            let byte = Data([UInt8(i)])
            _ = byte.withUnsafeBytes { ptr in write(clientFd7, ptr.baseAddress!, 1) }
            try await Task.sleep(nanoseconds: 900_000_000)
        }

        _ = try await acceptTask7.value
        let elapsed7 = ContinuousClock().now - start7
        let elapsedSec7 = Double(elapsed7.components.seconds) + Double(elapsed7.components.attoseconds) / 1e18

        assertTrue(elapsedSec7 >= 2.8 && elapsedSec7 <= 4.5, "Body read phase deadline enforced in \(elapsedSec7)s")

        let resp7 = try readIPCResponse(from: clientFd7)
        assertTrue(!resp7.success)
        assertEqual(resp7.error?.code, "TIMEOUT")

        close(clientFd7)
        listener7.stop()
    }

    public static func run08_BlockedResponseWriteTimeout() async throws {
        let sockPath8 = "/tmp/agy-test-c8-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath8)
        let listener8 = SocketListener(
            socketPath: sockPath8,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(granted: true),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )
        listener8.socketWriter = { _, _, _ in
            errno = EAGAIN
            return -1
        }
        try listener8.start()

        let acceptTask8 = Task { try await listener8.acceptAndHandleOneConnection() }
        let clientFd8 = try connectToSocket(at: listener8.socketPath)

        var smallBuf8: Int32 = 1024
        _ = setsockopt(clientFd8, SOL_SOCKET, SO_RCVBUF, &smallBuf8, socklen_t(MemoryLayout<Int32>.size))

        try sendIPCRequest(IPCRequest(id: "block-req-8", method: "observe"), to: clientFd8)

        let start8 = ContinuousClock().now
        let handled8 = try await acceptTask8.value
        let elapsed8 = ContinuousClock().now - start8
        let elapsedSec8 = Double(elapsed8.components.seconds) + Double(elapsed8.components.attoseconds) / 1e18

        assertTrue(handled8)
        assertTrue(elapsedSec8 >= 1.8 && elapsedSec8 <= 5.5, "Blocked write phase deadline enforced in \(elapsedSec8)s")

        var buf8 = [UInt8](repeating: 0, count: 16)
        let r8 = read(clientFd8, &buf8, 16)
        assertTrue(r8 <= 0, "Client read must return EOF/error due to socket close on write timeout, proving no second error response write")

        close(clientFd8)
        listener8.stop()
    }

    public static func run09_PeerCloseAndPartialIO() async throws {
        let sockPath9 = "/tmp/agy-test-c9-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath9)
        let listener9 = SocketListener(
            socketPath: sockPath9,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )
        try listener9.start()

        let acceptTask9a = Task { try await listener9.acceptAndHandleOneConnection() }
        let clientFd9a = try connectToSocket(at: listener9.socketPath)
        let pBytes = Data([0x00, 0x00])
        _ = pBytes.withUnsafeBytes { ptr in write(clientFd9a, ptr.baseAddress!, 2) }
        close(clientFd9a)

        let handled9a = try await acceptTask9a.value
        assertTrue(handled9a, "Listener handles abrupt peer close during header read safely")

        let acceptTask9b = Task { try await listener9.acceptAndHandleOneConnection() }
        let clientFd9b = try connectToSocket(at: listener9.socketPath)
        var msg9b = Data([0x00, 0x00, 0x00, 0x20])
        msg9b.append(Data("partial".utf8))
        _ = msg9b.withUnsafeBytes { ptr in write(clientFd9b, ptr.baseAddress!, msg9b.count) }
        close(clientFd9b)

        let handled9b = try await acceptTask9b.value
        assertTrue(handled9b, "Listener handles abrupt peer close during body read safely")

        listener9.stop()
    }

    public static func run10_EINTRRetryPath() async throws {
        signal(SIGUSR1, { _ in })

        let sockPath10 = "/tmp/agy-test-c10-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath10)
        let listener10 = SocketListener(
            socketPath: sockPath10,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(granted: true),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )
        try listener10.start()

        let acceptTask10 = Task { try await listener10.acceptAndHandleOneConnection() }
        let clientFd10 = try connectToSocket(at: listener10.socketPath)

        kill(getpid(), SIGUSR1)
        try sendIPCRequest(IPCRequest(id: "eintr-req-10", method: "status"), to: clientFd10)

        kill(getpid(), SIGUSR1)
        let handled10 = try await acceptTask10.value
        assertTrue(handled10)

        let resp10 = try readIPCResponse(from: clientFd10)
        assertEqual(resp10.id, "eintr-req-10")
        assertTrue(resp10.success)

        close(clientFd10)
        listener10.stop()
        signal(SIGUSR1, SIG_DFL)
    }

    public static func run11_TimeoutResponseFollowedByNextClient() async throws {
        let sockPath11 = "/tmp/agy-test-c11-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath11)
        let listener11 = SocketListener(
            socketPath: sockPath11,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(granted: true),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )
        try listener11.start()

        let acceptTask11a = Task { try await listener11.acceptAndHandleOneConnection() }
        let clientFd11a = try connectToSocket(at: listener11.socketPath)
        let partialHeader11 = Data([0x00, 0x00])
        _ = partialHeader11.withUnsafeBytes { ptr in write(clientFd11a, ptr.baseAddress!, 2) }

        _ = try await acceptTask11a.value
        let resp11a = try readIPCResponse(from: clientFd11a)
        assertTrue(!resp11a.success)
        assertEqual(resp11a.error?.code, "TIMEOUT")
        close(clientFd11a)

        let acceptTask11b = Task { try await listener11.acceptAndHandleOneConnection() }
        let clientFd11b = try connectToSocket(at: listener11.socketPath)
        try sendIPCRequest(IPCRequest(id: "seq-req-11", method: "status"), to: clientFd11b)

        _ = try await acceptTask11b.value
        let resp11b = try readIPCResponse(from: clientFd11b)
        assertEqual(resp11b.id, "seq-req-11")
        assertTrue(resp11b.success)
        close(clientFd11b)

        listener11.stop()
    }

    public static func run12_LiveSocketCollisionProbe() async throws {
        let sockPath12 = "/tmp/agy-test-c12-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath12)

        let rawFd12 = socket(AF_UNIX, SOCK_STREAM, 0)
        assertTrue(rawFd12 >= 0)
        var addr12 = sockaddr_un()
        let pathBytes12 = sockPath12.utf8CString
        addr12.sun_len = UInt8(MemoryLayout<sa_family_t>.size + pathBytes12.count)
        addr12.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr12.sun_path) { ptr in
            ptr.initializeMemory(as: CChar.self, repeating: 0)
            _ = pathBytes12.withUnsafeBufferPointer { bPtr in memcpy(ptr.baseAddress!, bPtr.baseAddress!, bPtr.count) }
        }
        let sockLen12 = socklen_t(addr12.sun_len)
        _ = withUnsafePointer(to: &addr12) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(rawFd12, saPtr, sockLen12)
            }
        }
        _ = listen(rawFd12, 5)

        let listener12 = SocketListener(
            socketPath: sockPath12,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )

        var threwCollision12 = false
        do {
            try listener12.start()
        } catch let err as ComputerUseError {
            if case .ipcError(let reason) = err {
                assertTrue(reason.contains("live listener") || reason.contains("active socket"))
                threwCollision12 = true
            }
        }
        assertTrue(threwCollision12, "Starting listener on active socket path without host.lock must fail live probe")

        close(rawFd12)
        _ = unlink(sockPath12)
    }

    public static func run13_VerifiedStaleSocketRecovery() async throws {
        let sockPath13 = "/tmp/agy-test-c13-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath13)

        let dummyFd13 = socket(AF_UNIX, SOCK_STREAM, 0)
        assertTrue(dummyFd13 >= 0)
        var addr13 = sockaddr_un()
        let pathBytes13 = sockPath13.utf8CString
        addr13.sun_len = UInt8(MemoryLayout<sa_family_t>.size + pathBytes13.count)
        addr13.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr13.sun_path) { ptr in
            ptr.initializeMemory(as: CChar.self, repeating: 0)
            _ = pathBytes13.withUnsafeBufferPointer { bPtr in memcpy(ptr.baseAddress!, bPtr.baseAddress!, bPtr.count) }
        }
        let sockLen13 = socklen_t(addr13.sun_len)
        let bindRes13 = withUnsafePointer(to: &addr13) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(dummyFd13, saPtr, sockLen13)
            }
        }
        assertEqual(bindRes13, 0)
        close(dummyFd13)

        var statBuf13 = stat()
        assertEqual(lstat(sockPath13, &statBuf13), 0)
        assertTrue((statBuf13.st_mode & S_IFMT) == S_IFSOCK)

        let listener13 = SocketListener(
            socketPath: sockPath13,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(granted: true),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )
        try listener13.start()

        let acceptTask13 = Task { try await listener13.acceptAndHandleOneConnection() }
        let clientFd13 = try connectToSocket(at: listener13.socketPath)
        try sendIPCRequest(IPCRequest(id: "stale-rec-13", method: "status"), to: clientFd13)

        _ = try await acceptTask13.value
        let resp13 = try readIPCResponse(from: clientFd13)
        assertEqual(resp13.id, "stale-rec-13")
        assertTrue(resp13.success)

        close(clientFd13)
        listener13.stop()
    }

    public static func run14_ForeignSymlinkNonSocketRefusal() async throws {
        let sockPath14Reg = "/tmp/agy-test-c14r-\(UUID().uuidString)/reg.sock"
        try SocketListener.prepareDirectory(at: sockPath14Reg)

        let regFd14 = open(sockPath14Reg, O_CREAT | O_WRONLY, 0o600)
        assertTrue(regFd14 >= 0)
        close(regFd14)

        let listener14a = SocketListener(
            socketPath: sockPath14Reg,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )

        var threwReg14 = false
        do {
            try listener14a.start()
        } catch let err as ComputerUseError {
            if case .ipcError(let reason) = err {
                assertTrue(reason.contains("non-socket file"))
                threwReg14 = true
            }
        }
        assertTrue(threwReg14, "Listener must refuse to unlink pre-existing regular file")
        _ = unlink(sockPath14Reg)

        let sockPath14Lnk = "/tmp/agy-test-c14l-\(UUID().uuidString)/lnk.sock"
        try SocketListener.prepareDirectory(at: sockPath14Lnk)
        let targetPath14 = "/tmp/agy-test-c14l-\(UUID().uuidString)/target"
        _ = symlink(targetPath14, sockPath14Lnk)

        let listener14b = SocketListener(
            socketPath: sockPath14Lnk,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )

        var threwLnk14 = false
        do {
            try listener14b.start()
        } catch let err as ComputerUseError {
            if case .ipcError(let reason) = err {
                assertTrue(reason.contains("non-socket file"))
                threwLnk14 = true
            }
        }
        assertTrue(threwLnk14, "Listener must refuse to unlink pre-existing symlink")
        _ = unlink(sockPath14Lnk)
    }

    public static func run15_StopNeverUnlinksReplacementInode() async throws {
        let sockPath15 = "/tmp/agy-test-c15-\(UUID().uuidString)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath15)
        let listener15 = SocketListener(
            socketPath: sockPath15,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )
        try listener15.start()

        _ = unlink(listener15.socketPath)

        let replacementFd15 = socket(AF_UNIX, SOCK_STREAM, 0)
        assertTrue(replacementFd15 >= 0)
        var addr15 = sockaddr_un()
        let pathBytes15 = listener15.socketPath.utf8CString
        addr15.sun_len = UInt8(MemoryLayout<sa_family_t>.size + pathBytes15.count)
        addr15.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr15.sun_path) { ptr in
            ptr.initializeMemory(as: CChar.self, repeating: 0)
            _ = pathBytes15.withUnsafeBufferPointer { bPtr in memcpy(ptr.baseAddress!, bPtr.baseAddress!, bPtr.count) }
        }
        let sockLen15 = socklen_t(addr15.sun_len)
        _ = withUnsafePointer(to: &addr15) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(replacementFd15, saPtr, sockLen15)
            }
        }
        close(replacementFd15)

        listener15.stop()

        var statBuf15 = stat()
        assertEqual(lstat(sockPath15, &statBuf15), 0)
        assertTrue((statBuf15.st_mode & S_IFMT) == S_IFSOCK)
        _ = unlink(sockPath15)
    }

    public static func run16_IEEE754BitPatternTopologyGoldenVectorAndMutations() async throws {
        let primaryDisp = DisplayInfo(
            id: 1,
            widthPoints: 1920.0,
            heightPoints: 1080.0,
            scaleFactor: 2.0,
            originX: 0.0,
            originY: 0.0,
            pixelWidth: 3840,
            pixelHeight: 2160,
            rotation: 0.0
        )
        let expectedDigestHex = "7275400fc06a64d3e67dad36ddfff2a9390c8adee90c0ceabb46715c2f403fe3"
        let expectedGoldenVersion = "top-sha256-\(expectedDigestHex)"
        let goldVer = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [primaryDisp])

        assertEqual(goldVer, expectedGoldenVersion)
        assertTrue(goldVer.hasPrefix("top-sha256-"))
        assertEqual(goldVer.count, 75)
        let hexDigest = String(goldVer.dropFirst(11))
        assertEqual(hexDigest, expectedDigestHex)

        let mutId = DisplayInfo(id: 2, widthPoints: 1920.0, heightPoints: 1080.0, scaleFactor: 2.0, originX: 0.0, originY: 0.0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)
        assertTrue(SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutId]) != goldVer)

        let mutW = DisplayInfo(id: 1, widthPoints: 2560.0, heightPoints: 1080.0, scaleFactor: 2.0, originX: 0.0, originY: 0.0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)
        assertTrue(SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutW]) != goldVer)

        let mutH = DisplayInfo(id: 1, widthPoints: 1920.0, heightPoints: 1440.0, scaleFactor: 2.0, originX: 0.0, originY: 0.0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)
        assertTrue(SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutH]) != goldVer)

        let mutScale = DisplayInfo(id: 1, widthPoints: 1920.0, heightPoints: 1080.0, scaleFactor: 1.0, originX: 0.0, originY: 0.0, pixelWidth: 1920, pixelHeight: 1080, rotation: 0.0)
        assertTrue(SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutScale]) != goldVer)

        let mutOx = DisplayInfo(id: 1, widthPoints: 1920.0, heightPoints: 1080.0, scaleFactor: 2.0, originX: 100.0, originY: 0.0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)
        assertTrue(SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutOx]) != goldVer)

        let mutOy = DisplayInfo(id: 1, widthPoints: 1920.0, heightPoints: 1080.0, scaleFactor: 2.0, originX: 0.0, originY: 50.0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)
        assertTrue(SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutOy]) != goldVer)

        let mutPw = DisplayInfo(id: 1, widthPoints: 1920.0, heightPoints: 1080.0, scaleFactor: 2.0, originX: 0.0, originY: 0.0, pixelWidth: 1920, pixelHeight: 2160, rotation: 0.0)
        assertTrue(SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutPw]) != goldVer)

        let mutPh = DisplayInfo(id: 1, widthPoints: 1920.0, heightPoints: 1080.0, scaleFactor: 2.0, originX: 0.0, originY: 0.0, pixelWidth: 3840, pixelHeight: 1080, rotation: 0.0)
        assertTrue(SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutPh]) != goldVer)

        let mutRot = DisplayInfo(id: 1, widthPoints: 1920.0, heightPoints: 1080.0, scaleFactor: 2.0, originX: 0.0, originY: 0.0, pixelWidth: 3840, pixelHeight: 2160, rotation: 90.0)
        assertTrue(SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutRot]) != goldVer)

        assertTrue(SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 2, displays: [primaryDisp]) != goldVer)

        let mutSignedZero = DisplayInfo(id: 1, widthPoints: 1920.0, heightPoints: 1080.0, scaleFactor: 2.0, originX: -0.0, originY: -0.0, pixelWidth: 3840, pixelHeight: 2160, rotation: -0.0)
        let signedZeroVer = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: 1, displays: [mutSignedZero])
        assertEqual(signedZeroVer, goldVer)

        let invalidDescriptors: [(CGRect, Double, Int, Int, Double)] = [
            (CGRect(x: Double.nan, y: 0, width: 1920, height: 1080), 0.0, 3840, 2160, 2.0),
            (CGRect(x: 0, y: Double.infinity, width: 1920, height: 1080), 0.0, 3840, 2160, 2.0),
            (CGRect(x: 0, y: 0, width: Double.nan, height: 1080), 0.0, 3840, 2160, 2.0),
            (CGRect(x: 0, y: 0, width: 1920, height: Double.infinity), 0.0, 3840, 2160, 2.0),
            (CGRect(x: 0, y: 0, width: 1920, height: 1080), Double.nan, 3840, 2160, 2.0),
            (CGRect(x: 0, y: 0, width: 1920, height: 1080), 0.0, 3840, 2160, Double.infinity)
        ]

        for (bounds, rot, pw, ph, scale) in invalidDescriptors {
            let fakeDesc = CustomDescriptorProvider(bounds: bounds, rotation: rot, pixelWidth: pw, pixelHeight: ph, scale: scale)
            let provider = SystemDisplayTopologyProvider(
                enumerator: ScriptedDisplayListEnumerator(script: [{ (1, [1]) }, { (1, [1]) }, { (1, [1]) }]),
                descriptorProvider: fakeDesc
            )
            var threwError = false
            do {
                _ = try provider.getTopology()
            } catch let err as ComputerUseError {
                if case .targetUnreachable(let reason) = err {
                    assertTrue(reason.contains("non-finite") || reason.contains("invalid scale"))
                    threwError = true
                }
            } catch {}
            assertTrue(threwError, "Display topology provider must reject non-finite float fields")
        }
    }

    public static func run17_HotPlugSafeDisplayEnumerator() async throws {
        let passes: [() throws -> (primaryId: Int, displayIDs: [Int])] = [
            { (1, [1, 2]) },
            { (1, [1, 2]) },
            { (1, [1, 2]) }
        ]
        let enumProvider = SystemDisplayTopologyProvider(
            enumerator: ScriptedDisplayListEnumerator(script: passes),
            descriptorProvider: FakeDescriptorProvider()
        )
        let top17 = try enumProvider.getTopology()
        assertEqual(top17.displays.count, 2)

        let retryPasses: [() throws -> (primaryId: Int, displayIDs: [Int])] = [
            { (1, [1]) },
            { (1, [1, 2]) },
            { (1, [1, 2]) },
            { (1, [1, 2]) },
            { (1, [1, 2]) }
        ]
        let retryProvider = SystemDisplayTopologyProvider(
            enumerator: ScriptedDisplayListEnumerator(script: retryPasses),
            descriptorProvider: FakeDescriptorProvider()
        )
        let topRetry = try retryProvider.getTopology()
        assertEqual(topRetry.displays.count, 2)
    }

    public static func run18_PermissionPreflightDeniedZeroLoaderCalls() async throws {
        let auth18 = FakeScreenRecordingAuthorizer(granted: false)
        let engine18 = SCScreenshotCaptureEngine(authorizer: auth18)
        let top18 = try FakeDisplayTopologyProvider().getTopology()

        var threwDenied = false
        do {
            _ = try await engine18.captureDisplay(displayId: 1, topology: top18)
        } catch let err as ComputerUseError {
            if case .permissionDenied(let perm) = err {
                assertEqual(perm, "screen_recording")
                threwDenied = true
            }
        }
        assertTrue(threwDenied)
        assertEqual(await engine18.frameworkInvocationCount, 0)

        let engine18_granted = SCScreenshotCaptureEngine(
            authorizer: FakeScreenRecordingAuthorizer(granted: true)
        )

        let invalidDimensions: [(Int, Int)] = [
            (0, 100),
            (-1, -1),
            (Int.max, Int.max),
            (5213, 12277) // Exact 64,000,001 (64M+1)
        ]

        for (pw, ph) in invalidDimensions {
            let invalidTop = DisplayTopology(
                version: "v1.0",
                primaryDisplayId: 1,
                displays: [
                    DisplayInfo(
                        id: 1,
                        widthPoints: Double(pw),
                        heightPoints: Double(ph),
                        scaleFactor: 1.0,
                        originX: 0,
                        originY: 0,
                        pixelWidth: pw,
                        pixelHeight: ph,
                        rotation: 0.0
                    )
                ]
            )
            var threwInvalid = false
            do {
                _ = try await engine18_granted.captureDisplay(displayId: 1, topology: invalidTop)
            } catch {
                threwInvalid = true
            }
            assertTrue(threwInvalid, "captureDisplay must fail on invalid pixel dimensions (\(pw)x\(ph))")
            assertEqual(await engine18_granted.contentLoaderInvocationCount, 0, "Content loader must not be called on invalid dimensions (\(pw)x\(ph))")
            assertEqual(await engine18_granted.frameworkInvocationCount, 0, "Framework allocation must not be called on invalid dimensions (\(pw)x\(ph))")
            assertEqual(await engine18_granted.encoderInvocationCount, 0, "JPEG encoder must not be called on invalid dimensions (\(pw)x\(ph))")
        }

        // Test exact 64M limit (8000 x 8000 = 64,000,000) with lightweight fake injected dependencies
        let fakeCGImage = CGImage(
            width: 8000,
            height: 8000,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: 8000,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: Data(repeating: 0, count: 64_000_000) as CFData)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!

        let engine64M = SCScreenshotCaptureEngine(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            contentLoader: {
                // Return dummy SCShareableContent
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            },
            imageCapturer: { filter, config in
                return fakeCGImage
            },
            jpegEncoder: { image, quality in
                return Data([
                    0xFF, 0xD8,
                    0xFF, 0xC0, 0x00, 0x11, 0x08, 0x1F, 0x40, 0x1F, 0x40, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
                    0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00,
                    0x00,
                    0xFF, 0xD9
                ])
            }
        )

        let valid64MTop = DisplayTopology(
            version: "v1.0",
            primaryDisplayId: 1,
            displays: [
                DisplayInfo(
                    id: 1,
                    widthPoints: 8000,
                    heightPoints: 8000,
                    scaleFactor: 1.0,
                    originX: 0,
                    originY: 0,
                    pixelWidth: 8000,
                    pixelHeight: 8000,
                    rotation: 0.0
                )
            ]
        )

        let frame64M = try await engine64M.captureDisplay(displayId: 1, topology: valid64MTop)
        assertEqual(frame64M.pixelWidth, 8000)
        assertEqual(frame64M.pixelHeight, 8000)
        assertEqual(await engine64M.contentLoaderInvocationCount, 1, "Content loader must be invoked exactly once for 64M boundary")
        assertEqual(await engine64M.frameworkInvocationCount, 1, "Framework capturer must be invoked exactly once for 64M boundary")
        assertEqual(await engine64M.encoderInvocationCount, 1, "JPEG encoder must be invoked exactly once for 64M boundary")
    }

    public static func run19_PureJPEGValidatorExactAndNear10MiBBoundaries() async throws {
        let sof0Data = Data([
            0xFF, 0xD8,
            0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x64, 0x00, 0x64, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
            0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00,
            0xFF, 0xD9
        ])
        let dims19 = SCScreenshotCaptureEngine.parseJPEGDimensions(data: sof0Data)
        assertTrue(dims19 != nil)
        assertEqual(dims19?.width, 100)
        assertEqual(dims19?.height, 100)
        try SCScreenshotCaptureEngine.validateJPEGData(data: sof0Data)

        let subLimitData = Data(repeating: 0x41, count: 10_485_759)
        var threwSubLimit = false
        do { try SCScreenshotCaptureEngine.validateJPEGData(data: subLimitData) } catch { threwSubLimit = true }
        assertTrue(threwSubLimit, "Must reject invalid magic bytes for 1-byte below limit payload")

        let exactLimitData = Data(repeating: 0x41, count: 10_485_760)
        var threwExactLimit = false
        do { try SCScreenshotCaptureEngine.validateJPEGData(data: exactLimitData) } catch { threwExactLimit = true }
        assertTrue(threwExactLimit, "Must reject invalid magic bytes for exact 10 MiB limit payload")

        let overLimitData = Data(repeating: 0x41, count: 10_485_761)
        var threwOverLimit = false
        do { try SCScreenshotCaptureEngine.validateJPEGData(data: overLimitData) } catch { threwOverLimit = true }
        assertTrue(threwOverLimit, "Must reject payloads strictly exceeding 10 MiB limit")

        // Preflight pixel dimensions validation
        try validatePixelDimensions(width: 8000, height: 8000)
        var threwPixelZero = false
        do { try validatePixelDimensions(width: 0, height: 100) } catch { threwPixelZero = true }
        assertTrue(threwPixelZero)

        var threwPixelNeg = false
        do { try validatePixelDimensions(width: -1, height: -1) } catch { threwPixelNeg = true }
        assertTrue(threwPixelNeg)

        var threwPixelOverflow = false
        do { try validatePixelDimensions(width: Int.max, height: Int.max) } catch { threwPixelOverflow = true }
        assertTrue(threwPixelOverflow)

        var threwPixelOver64MP = false
        do { try validatePixelDimensions(width: 8001, height: 8000) } catch { threwPixelOver64MP = true }
        assertTrue(threwPixelOver64MP)
    }

    public static func run20_SOF0AndSOF2MarkerValidation() async throws {
        let repoRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent() // ComputerUseHostTestRunner
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // apps/computer-use-host
            .deletingLastPathComponent() // apps
            .deletingLastPathComponent() // repo root
        let goldenURL = repoRoot.appendingPathComponent("docs/fixtures/golden_progressive.jpg")
        assertTrue(FileManager.default.fileExists(atPath: goldenURL.path), "docs/fixtures/golden_progressive.jpg must exist")

        let goldenData = try Data(contentsOf: goldenURL)
        assertTrue(goldenData.count > 0, "golden_progressive.jpg must be non-empty")

        // ImageIO decode verification
        let imageSource = CGImageSourceCreateWithData(goldenData as CFData, nil)
        assertTrue(imageSource != nil, "golden_progressive.jpg must create CGImageSource")
        let cgImage = imageSource.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        assertTrue(cgImage != nil, "golden_progressive.jpg must decode to CGImage via ImageIO")
        assertEqual(cgImage?.width, 10, "golden_progressive.jpg width must be 10")
        assertEqual(cgImage?.height, 10, "golden_progressive.jpg height must be 10")

        // 16-Row Canonical Mutation Table Validation with SHA-256 Parity
        let tableURL = repoRoot.appendingPathComponent("docs/fixtures/canonical_jpeg_mutations.json")
        assertTrue(FileManager.default.fileExists(atPath: tableURL.path), "docs/fixtures/canonical_jpeg_mutations.json must exist")
        let tableData = try Data(contentsOf: tableURL)

        struct MutationRow: Decodable {
            let id: Int
            let name: String
            let expectedResult: String
            let expectedWidth: Int?
            let expectedHeight: Int?
            let sha256: String
        }

        let table = try JSONDecoder().decode([MutationRow].self, from: tableData)
        assertEqual(table.count, 16, "Canonical JPEG mutation table must contain exactly 16 rows")

        for row in table {
            var mutData = Data()
            switch row.id {
            case 1:
                mutData = goldenData
            case 2:
                mutData = goldenData
                mutData[4] = 0x00; mutData[5] = 0x01
            case 3:
                mutData = goldenData
                guard let sofIdx = mutData.range(of: Data([0xFF, 0xC2]))?.lowerBound else {
                    fatalError("SOF marker not found for row \(row.id)")
                }
                mutData[sofIdx + 13] = mutData[sofIdx + 10]
            case 4:
                mutData = goldenData
                guard let sosIdx = mutData.range(of: Data([0xFF, 0xDA]))?.lowerBound else {
                    fatalError("SOS marker not found for row \(row.id)")
                }
                mutData[sosIdx + 7] = mutData[sosIdx + 5]
            case 5:
                mutData = goldenData
                guard let sosIdx = mutData.range(of: Data([0xFF, 0xDA]))?.lowerBound else {
                    fatalError("SOS marker not found for row \(row.id)")
                }
                mutData[sosIdx + 5] = 0x99
            case 6:
                mutData = goldenData
                guard let sosIdx = mutData.range(of: Data([0xFF, 0xDA]))?.lowerBound else {
                    fatalError("SOS marker not found for row \(row.id)")
                }
                mutData[sosIdx + 4] = 0
            case 7:
                mutData = goldenData
                guard let sosIdx = mutData.range(of: Data([0xFF, 0xDA]))?.lowerBound else {
                    fatalError("SOS marker not found for row \(row.id)")
                }
                mutData[sosIdx + 4] = 5
            case 8:
                mutData = Data([0xFF, 0xD8, 0xFF, 0xD8]) + goldenData.dropFirst(2)
            case 9:
                guard let sofIdx = goldenData.range(of: Data([0xFF, 0xC2]))?.lowerBound else {
                    fatalError("SOF marker not found for row \(row.id)")
                }
                let segLen = Int(goldenData[sofIdx + 2]) << 8 | Int(goldenData[sofIdx + 3])
                let sofChunk = goldenData[sofIdx..<(sofIdx + 2 + segLen)]
                mutData.append(goldenData[0..<(sofIdx + 2 + segLen)])
                mutData.append(sofChunk)
                mutData.append(goldenData[(sofIdx + 2 + segLen)...])
            case 10:
                mutData = goldenData
                guard let sosIdx = mutData.range(of: Data([0xFF, 0xDA]))?.lowerBound else {
                    fatalError("SOS marker not found for row \(row.id)")
                }
                var found = false
                for i in (sosIdx + 10)..<(mutData.count - 1) {
                    if mutData[i] == 0xFF && mutData[i + 1] != 0x00 && !(mutData[i + 1] >= 0xD0 && mutData[i + 1] <= 0xD7) && mutData[i + 1] != 0xD9 {
                        mutData[i + 1] = 0x02
                        found = true
                        break
                    }
                }
                assertTrue(found, "Inter-scan marker must be found for row \(row.id)")
            case 11:
                mutData = Data(goldenData.prefix(goldenData.count - 10))
            case 12:
                mutData = Data(goldenData.prefix(goldenData.count - 2))
            case 13:
                mutData = goldenData
                guard let sofIdx = mutData.range(of: Data([0xFF, 0xC2]))?.lowerBound else {
                    fatalError("SOF marker not found for row \(row.id)")
                }
                mutData[sofIdx + 5] = 0x1F; mutData[sofIdx + 6] = 0x40
                mutData[sofIdx + 7] = 0x1F; mutData[sofIdx + 8] = 0x40
            case 14:
                mutData = goldenData
                guard let sofIdx = mutData.range(of: Data([0xFF, 0xC2]))?.lowerBound else {
                    fatalError("SOF marker not found for row \(row.id)")
                }
                mutData[sofIdx + 5] = 0x14; mutData[sofIdx + 6] = 0x5D // height = 5213
                mutData[sofIdx + 7] = 0x2F; mutData[sofIdx + 8] = 0xF5 // width = 12277
            case 15:
                mutData = goldenData + Data([0x00, 0x00])
            case 16:
                mutData = goldenData + Data([0xAA])
            default:
                fatalError("Unexpected row ID \(row.id)")
            }

            let computedHash = SHA256.hash(data: mutData).compactMap { String(format: "%02x", $0) }.joined()
            assertEqual(computedHash, row.sha256, "SHA-256 mismatch for row \(row.id) (\(row.name))")

            let dims = SCScreenshotCaptureEngine.parseJPEGDimensions(data: mutData)
            if row.expectedResult == "accept" {
                assertTrue(dims != nil, "Row \(row.id) (\(row.name)) must be accepted")
                assertEqual(dims?.width, row.expectedWidth)
                assertEqual(dims?.height, row.expectedHeight)
            } else {
                assertTrue(dims == nil, "Row \(row.id) (\(row.name)) must be rejected")
            }
        }
    }

    public static func run21_JPEGInvalidMagicTruncatedSegmentAndMismatchRejection() async throws {
        let sof0Data = Data([
            0xFF, 0xD8,
            0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x64, 0x00, 0x64, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
            0xFF, 0xDA, 0x00, 0x08, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11,
            0xFF, 0xD9
        ])
        let invalidMagicData = Data([0x00, 0x00, 0xFF, 0xD8])
        assertTrue(SCScreenshotCaptureEngine.parseJPEGDimensions(data: invalidMagicData) == nil)
        var threwBadMagic = false
        do { try SCScreenshotCaptureEngine.validateJPEGData(data: invalidMagicData) } catch { threwBadMagic = true }
        assertTrue(threwBadMagic, "Must reject invalid magic bytes")

        let truncatedData = sof0Data.prefix(8)
        assertTrue(SCScreenshotCaptureEngine.parseJPEGDimensions(data: Data(truncatedData)) == nil)
        var threwTruncated = false
        do { try SCScreenshotCaptureEngine.validateJPEGData(data: Data(truncatedData)) } catch { threwTruncated = true }
        assertTrue(threwTruncated, "Must reject truncated JPEG segment")
    }

    public static func run22_NoncooperativeLateCompletionGenerationFence() async throws {
        let controlledEngine = ControlledCaptureEngine()
        let sleeper = ManualSleeper()
        let manualClock = TestManualClock()
        let fenceServer = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: controlledEngine,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector(),
            observationTimeoutSec: 5.0,
            sleeper: sleeper,
            clock: manualClock
        )

        let reqATask = Task { await fenceServer.handleRequest(IPCRequest(id: "fence-A", method: "observe")) }
        await controlledEngine.waitUntilRegistered(count: 1)
        await sleeper.waitUntilIssued(count: 1)
        manualClock.advance(by: .seconds(5))
        sleeper.advance()

        let respA = await reqATask.value
        assertTrue(!respA.success)
        assertEqual(respA.error?.code, "TIMEOUT")

        let reqBTask = Task { await fenceServer.handleRequest(IPCRequest(id: "fence-B", method: "observe")) }
        await controlledEngine.waitUntilRegistered(count: 2)
        let frameB = try FakeCaptureEngine().generateDTO(topology: FakeDisplayTopologyProvider().getTopology())
        try await controlledEngine.complete(index: 1, with: .success(frameB))

        let respB = await reqBTask.value
        assertTrue(respB.success)
        assertEqual(await fenceServer.latestCaptureSnapshot?.captureId, frameB.captureId)
        assertEqual(await fenceServer.latestIssuedGenerationSnapshot, 2)

        let frameA = try FakeCaptureEngine().generateDTO(topology: FakeDisplayTopologyProvider().getTopology())
        try await controlledEngine.complete(index: 0, with: .success(frameA))
        await controlledEngine.waitUntilExited(count: 2)

        assertEqual(await fenceServer.latestCaptureSnapshot?.captureId, frameB.captureId)
        assertEqual(await fenceServer.latestIssuedGenerationSnapshot, 2)
    }

    public static func run23_StaleOperationGenerationFence() async throws {
        let controlledEngine = ControlledCaptureEngine()
        let server = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: controlledEngine,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector(),
            observationTimeoutSec: 10.0
        )

        let task1 = Task { await server.handleRequest(IPCRequest(id: "stale-1", method: "observe")) }
        await controlledEngine.waitUntilRegistered(count: 1)

        let task2 = Task { await server.handleRequest(IPCRequest(id: "stale-2", method: "observe")) }
        await controlledEngine.waitUntilRegistered(count: 2)

        let frame2 = try FakeCaptureEngine().generateDTO(topology: FakeDisplayTopologyProvider().getTopology())
        try await controlledEngine.complete(index: 1, with: .success(frame2))
        let resp2 = await task2.value
        assertTrue(resp2.success)

        let frame1 = try FakeCaptureEngine().generateDTO(topology: FakeDisplayTopologyProvider().getTopology())
        try await controlledEngine.complete(index: 0, with: .success(frame1))
        let resp1 = await task1.value
        assertTrue(!resp1.success)
        assertEqual(resp1.error?.code, "STALE_OPERATION")

        assertEqual(await server.latestCaptureSnapshot?.captureId, frame2.captureId)
        assertEqual(await server.latestIssuedGenerationSnapshot, 2)
    }

    public static func run24_RequesterCancellation() async throws {
        let budget = CaptureBudget(maxConcurrent: 1)
        let controlledEngine = ControlledCaptureEngine()
        let server = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: controlledEngine,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector(),
            observationTimeoutSec: 5.0,
            budget: budget
        )

        let reqTask = Task {
            await server.handleRequest(IPCRequest(id: "req-cancel", method: "observe"))
        }
        await controlledEngine.waitUntilRegistered(count: 1)

        reqTask.cancel()

        let resp = await reqTask.value
        assertTrue(!resp.success)
        assertEqual(resp.error?.code, "CANCELLED")

        assertEqual(budget.count, 1, "Budget must remain occupied by active physical capture after cancellation")

        let frame = try FakeCaptureEngine().generateDTO(topology: FakeDisplayTopologyProvider().getTopology())
        try await controlledEngine.complete(index: 0, with: .success(frame))
        await controlledEngine.waitUntilExited(count: 1)
        for _ in 0..<100 {
            if budget.count == 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        assertEqual(budget.count, 0, "Budget must be released on physical capture exit")
        assertEqual(await server.latestCaptureSnapshot, nil, "Cancelled request must never promote capture frame")
    }

    public static func run25_TimedOutOrphanCapacity() async throws {
        let budget = CaptureBudget(maxConcurrent: 1)
        let controlledEngine = ControlledCaptureEngine()
        let sleeper = ManualSleeper()
        let manualClock = TestManualClock()
        let server = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: controlledEngine,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector(),
            observationTimeoutSec: 5.0,
            budget: budget,
            sleeper: sleeper,
            clock: manualClock
        )

        let taskA = Task { await server.handleRequest(IPCRequest(id: "orphan-A", method: "observe")) }
        await controlledEngine.waitUntilRegistered(count: 1)
        await sleeper.waitUntilIssued(count: 1)
        manualClock.advance(by: .seconds(5))
        sleeper.advance()

        let respA = await taskA.value
        assertTrue(!respA.success)
        assertEqual(respA.error?.code, "TIMEOUT")
        assertEqual(budget.count, 1, "Budget must remain occupied while orphan task A runs")

        let invocationsBeforeB = await controlledEngine.invocationCount
        let genBeforeB = await server.latestIssuedGenerationSnapshot

        let respB = await server.handleRequest(IPCRequest(id: "orphan-B", method: "observe"))
        assertTrue(!respB.success)
        assertEqual(respB.error?.code, "CAPTURE_BUSY")
        assertEqual(await controlledEngine.invocationCount, invocationsBeforeB, "Busy request B must cause zero capture engine invocations")
        assertEqual(await server.latestIssuedGenerationSnapshot, genBeforeB, "Busy request B must cause zero generation changes")

        let frameA = try FakeCaptureEngine().generateDTO(topology: FakeDisplayTopologyProvider().getTopology())
        try await controlledEngine.complete(index: 0, with: .success(frameA))
        await controlledEngine.waitUntilExited(count: 1)
        for _ in 0..<100 {
            if budget.count == 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        assertEqual(budget.count, 0, "Budget must be released after orphan task A exits")

        let taskC = Task { await server.handleRequest(IPCRequest(id: "orphan-C", method: "observe")) }
        await controlledEngine.waitUntilRegistered(count: 2)
        let frameC = try FakeCaptureEngine().generateDTO(topology: FakeDisplayTopologyProvider().getTopology())
        try await controlledEngine.complete(index: 1, with: .success(frameC))

        let respC = await taskC.value
        assertTrue(respC.success)
        assertEqual(await server.latestCaptureSnapshot?.captureId, frameC.captureId)
    }

    public static func run26_TopologyChangeDuringCaptureDiscarded() async throws {
        let fakeEngine = FakeCaptureEngine(customTopologyVersion: "top-sha256-old-version-stale-token")
        let server = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: fakeEngine,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector()
        )

        let resp = await server.handleRequest(IPCRequest(id: "top-change-req", method: "observe"))
        assertTrue(!resp.success)
        assertEqual(resp.error?.code, "STALE_TOPOLOGY")
    }

    public static func run27_DisabledActionsAndAXTreeRejection() async throws {
        let server = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: FakeCaptureEngine(),
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector()
        )

        let axResp = await server.handleRequest(IPCRequest(id: "ax-req", method: "ax_tree"))
        assertTrue(!axResp.success)
        assertEqual(axResp.error?.code, "TARGET_UNREACHABLE")

        let clickResp = await server.handleRequest(IPCRequest(id: "click-req", method: "click"))
        assertTrue(!clickResp.success)
        assertEqual(clickResp.error?.code, "MUTATION_DISABLED")
    }

    public static func run28_DisplayIdParameterValidation() async throws {
        let server = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: FakeCaptureEngine(),
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector()
        )

        let reqBadType = IPCRequest(id: "bad-id-1", method: "observe", params: ["display_id": .string("1")])
        let respBadType = await server.handleRequest(reqBadType)
        assertTrue(!respBadType.success)
        assertEqual(respBadType.error?.code, "IPC_ERROR")

        let reqNotFound = IPCRequest(id: "bad-id-2", method: "observe", params: ["display_id": .int(9999)])
        let respNotFound = await server.handleRequest(reqNotFound)
        assertTrue(!respNotFound.success)
        assertEqual(respNotFound.error?.code, "TARGET_UNREACHABLE")
    }

    public static func run29_CancellationErrorMappedToCancelledCode() async throws {
        struct CancellingCaptureEngine: DisplayCaptureEngine {
            func captureDisplay(displayId: Int?, topology: DisplayTopology) async throws -> CaptureFrameDTO {
                throw CancellationError()
            }
        }

        let server = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: CancellingCaptureEngine(),
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector()
        )

        let resp = await server.handleRequest(IPCRequest(id: "cancel-req", method: "observe"))
        assertTrue(!resp.success)
        assertEqual(resp.error?.code, "CANCELLED")
    }

    public static func run30_PartialStartRollback() async throws {
        let parentDir30 = "/tmp/agy-test-c30-\(UUID().uuidString)"
        let sockPath30 = "\(parentDir30)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath30)

        _ = mkdir(sockPath30, 0o700)

        let lockPath30 = "\(parentDir30)/host.lock"
        let listener30 = SocketListener(
            socketPath: sockPath30,
            server: HostServer(
                authorizer: FakeScreenRecordingAuthorizer(),
                topologyProvider: FakeDisplayTopologyProvider(),
                captureEngine: FakeCaptureEngine(),
                axEngine: DisabledAXInspector(),
                inputEngine: DisabledInputInjector()
            )
        )

        var threwRollback30 = false
        do {
            try listener30.start()
        } catch let err as ComputerUseError {
            if case .ipcError = err {
                threwRollback30 = true
            }
        }
        assertTrue(threwRollback30, "Listener start must fail when bind fails")

        _ = rmdir(sockPath30)

        var statLock30 = stat()
        assertTrue(lstat(lockPath30, &statLock30) == 0, "host.lock file must persist on disk after partial-start rollback")
        let testLockFd30 = open(lockPath30, O_RDWR | O_CLOEXEC)
        assertTrue(testLockFd30 >= 0, "host.lock must be readable/writable after rollback")
        assertEqual(flock(testLockFd30, LOCK_EX | LOCK_NB), 0, "Persistent host.lock inode must be unlocked after rollback")
        close(testLockFd30)

        try listener30.start()
        let clientFd30 = try connectToSocket(at: listener30.socketPath)
        close(clientFd30)
        listener30.stop()
    }

    public static func run31_AcceptEINTRRetry() async throws {
        let parentDir = "/tmp/agy-test-c31-\(UUID().uuidString)"
        let sockPath = "\(parentDir)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath)

        let scriptedSyscalls = ScriptedPOSIXSyscalls()
        var acceptAttempts = 0
        scriptedSyscalls.acceptHook = { fd, saPtr, lenPtr in
            acceptAttempts += 1
            if acceptAttempts == 1 {
                scriptedSyscalls.setErrno(EINTR)
                return -1
            }
            return nil
        }

        let listener = SocketListener(
            socketPath: sockPath,
            server: HostServer(authorizer: FakeScreenRecordingAuthorizer(), topologyProvider: FakeDisplayTopologyProvider(), captureEngine: FakeCaptureEngine(), axEngine: DisabledAXInspector(), inputEngine: DisabledInputInjector()),
            syscalls: scriptedSyscalls
        )
        try listener.start()
        defer { listener.stop() }

        let clientFd = try connectToSocket(at: sockPath)
        defer { close(clientFd) }

        let handled = try await listener.acceptAndHandleOneConnection()
        assertTrue(handled)
        assertEqual(scriptedSyscalls.acceptCallCount, 2, "accept must be called exactly 2 times (1 EINTR retry + 1 success)")
    }

    public static func run32_ReadHeaderBodyEINTRRetry() async throws {
        let parentDir = "/tmp/agy-test-c32-\(UUID().uuidString)"
        let sockPath = "\(parentDir)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath)

        let scriptedSyscalls = ScriptedPOSIXSyscalls()
        var headerReadAttempts = 0
        var bodyReadAttempts = 0

        scriptedSyscalls.readHook = { fd, buf, count in
            if count == 4 {
                headerReadAttempts += 1
                if headerReadAttempts == 1 {
                    scriptedSyscalls.setErrno(EINTR)
                    return -1
                }
            } else if count > 4 {
                bodyReadAttempts += 1
                if bodyReadAttempts == 1 {
                    scriptedSyscalls.setErrno(EINTR)
                    return -1
                }
            }
            return nil
        }

        let listener = SocketListener(
            socketPath: sockPath,
            server: HostServer(authorizer: FakeScreenRecordingAuthorizer(), topologyProvider: FakeDisplayTopologyProvider(), captureEngine: FakeCaptureEngine(), axEngine: DisabledAXInspector(), inputEngine: DisabledInputInjector()),
            syscalls: scriptedSyscalls
        )
        try listener.start()
        defer { listener.stop() }

        let clientFd = try connectToSocket(at: sockPath)
        defer { close(clientFd) }

        try sendIPCRequest(IPCRequest(id: "test-eintr", method: "observe"), to: clientFd)
        let handled = try await listener.acceptAndHandleOneConnection()
        assertTrue(handled)

        assertEqual(headerReadAttempts, 2, "Header read must retry exactly once after single EINTR")
        assertEqual(bodyReadAttempts, 2, "Body read must retry exactly once after single EINTR")
    }

    public static func run33_WriteResponseEAGAINDeadlineAndSingleAttempt() async throws {
        let parentDir = "/tmp/agy-test-c33-\(UUID().uuidString)"
        let sockPath = "\(parentDir)/host.sock"
        let manualClock = TestManualClock()
        let scriptedSyscalls = ScriptedPOSIXSyscalls()
        var writeCallSequence = 0

        scriptedSyscalls.writeHook = { fd, buf, count in
            writeCallSequence += 1
            if writeCallSequence == 1 {
                return 2
            }
            manualClock.advance(by: .seconds(1))
            scriptedSyscalls.setErrno(EAGAIN)
            return -1
        }

        let listener = SocketListener(
            socketPath: sockPath,
            server: HostServer(authorizer: FakeScreenRecordingAuthorizer(), topologyProvider: FakeDisplayTopologyProvider(), captureEngine: FakeCaptureEngine(), axEngine: DisabledAXInspector(), inputEngine: DisabledInputInjector()),
            perFrameTimeoutSec: 0.1,
            syscalls: scriptedSyscalls,
            clock: manualClock
        )
        try listener.start()
        defer { listener.stop() }

        let clientFd = try connectToSocket(at: sockPath)
        defer { close(clientFd) }

        try sendIPCRequest(IPCRequest(id: "test-write-eagain", method: "observe"), to: clientFd)
        let handled = try await listener.acceptAndHandleOneConnection()
        assertTrue(handled)

        assertTrue(writeCallSequence > 1, "Write must retry on EAGAIN until deadline")
        assertEqual(listener.responseAttemptCount, 1, "Only one response write attempt must be initiated (0 catch-path second attempts)")
    }

    public static func run34_PositiveByteAdvancesClockPastDeadlineReturnsTimeout() async throws {
        let parentDir = "/tmp/agy-test-c34-\(UUID().uuidString)"
        let sockPath = "\(parentDir)/host.sock"
        try SocketListener.prepareDirectory(at: sockPath)

        let manualClock = TestManualClock()
        let scriptedSyscalls = ScriptedPOSIXSyscalls()

        scriptedSyscalls.readHook = { fd, buf, count in
            manualClock.advance(by: .seconds(5))
            return 2
        }

        let listener = SocketListener(
            socketPath: sockPath,
            server: HostServer(authorizer: FakeScreenRecordingAuthorizer(), topologyProvider: FakeDisplayTopologyProvider(), captureEngine: FakeCaptureEngine(), axEngine: DisabledAXInspector(), inputEngine: DisabledInputInjector()),
            perFrameTimeoutSec: 1.0,
            syscalls: scriptedSyscalls,
            clock: manualClock
        )
        try listener.start()
        defer { listener.stop() }

        let clientFd = try connectToSocket(at: sockPath)
        defer { close(clientFd) }

        var headerData = Data()
        headerData.append(contentsOf: [0x00, 0x00, 0x00, 0x10])
        headerData.withUnsafeBytes { ptr in
            _ = write(clientFd, ptr.baseAddress!, ptr.count)
        }

        let handled = try await listener.acceptAndHandleOneConnection()
        assertTrue(handled)

        let resp34 = try readIPCResponse(from: clientFd)
        assertTrue(!resp34.success, "Response must indicate failure when deadline expires on body read")
        assertEqual(resp34.error?.code, "TIMEOUT", "Error code must be TIMEOUT")
    }

    public static func run35_InjectedListenFailurePostBindRollback() async throws {
        let parentDir = "/tmp/agy-test-c35-\(UUID().uuidString)"
        let sockPath = "\(parentDir)/host.sock"
        let scriptedSyscalls = ScriptedPOSIXSyscalls()

        scriptedSyscalls.listenHook = { sock, backlog in
            scriptedSyscalls.setErrno(EADDRINUSE)
            return -1
        }

        let listener = SocketListener(
            socketPath: sockPath,
            server: HostServer(authorizer: FakeScreenRecordingAuthorizer(), topologyProvider: FakeDisplayTopologyProvider(), captureEngine: FakeCaptureEngine(), axEngine: DisabledAXInspector(), inputEngine: DisabledInputInjector()),
            perFrameTimeoutSec: 1.0,
            syscalls: scriptedSyscalls
        )

        var threw = false
        do {
            try listener.start()
        } catch {
            threw = true
        }
        assertTrue(threw, "SocketListener.start must throw when listen returns error")

        var origLockStat = stat()
        let lockPath = "\(parentDir)/host.lock"
        assertEqual(scriptedSyscalls.lstat(lockPath, &origLockStat), 0, "Persistent host.lock inode must remain after listen failure rollback")
        let origLockInode = origLockStat.st_ino

        var sockStat = stat()
        assertTrue(scriptedSyscalls.lstat(sockPath, &sockStat) != 0, "Failed socket file must be removed after listen failure rollback")
        assertTrue(!scriptedSyscalls.openedDescriptors.isEmpty, "Opened descriptors list must be non-empty")
        assertTrue(scriptedSyscalls.areAllDescriptorsClosed, "All opened descriptors must be closed as a multiset (openCount == closeCount)")
        assertTrue(scriptedSyscalls.unlinkatCallCount > 0, "Descriptor-relative unlinkat must be called on rollback")
        assertTrue(scriptedSyscalls.unlinkedFiles.contains("host.sock"), "Descriptor-relative unlinkat must unlink host.sock token")

        scriptedSyscalls.listenHook = nil
        var secondStartThrew = false
        do {
            try listener.start()
        } catch {
            secondStartThrew = true
        }
        assertTrue(!secondStartThrew, "Subsequent SocketListener.start must succeed after rollback")

        var postRestartLockStat = stat()
        assertEqual(scriptedSyscalls.lstat(lockPath, &postRestartLockStat), 0, "Persistent host.lock inode must exist after restart")
        assertEqual(postRestartLockStat.st_ino, origLockInode, "Persistent host.lock inode must remain unchanged after listen failure rollback & restart")

        listener.stop()
        assertTrue(scriptedSyscalls.lstat(sockPath, &sockStat) != 0, "Socket file must be unlinked on listener stop")
        assertTrue(scriptedSyscalls.areAllDescriptorsClosed, "All descriptors must be closed as a multiset after listener stop")

        // Pre-bind parent swap test
        let preBindDir = "/tmp/agy-prebind-\(UUID().uuidString)"
        let preBindSockPath = "\(preBindDir)/host.sock"
        var fstatatCallCount = 0
        let preBindSyscalls = ScriptedPOSIXSyscalls()
        preBindSyscalls.fstatatHook = { dirFd, path, buf, flag in
            fstatatCallCount += 1
            if fstatatCallCount == 1, let buf = buf {
                // Return mismatched inode for parentDir revalidation pre-bind
                buf.pointee.st_dev = 9999
                buf.pointee.st_ino = 9999
                buf.pointee.st_mode = S_IFDIR | 0o700
                buf.pointee.st_uid = getuid()
                return 0
            }
            return nil
        }
        let preBindListener = SocketListener(
            socketPath: preBindSockPath,
            server: HostServer(authorizer: FakeScreenRecordingAuthorizer(), topologyProvider: FakeDisplayTopologyProvider(), captureEngine: FakeCaptureEngine(), axEngine: DisabledAXInspector(), inputEngine: DisabledInputInjector()),
            perFrameTimeoutSec: 1.0,
            syscalls: preBindSyscalls
        )
        var preBindThrew = false
        do { try preBindListener.start() } catch { preBindThrew = true }
        assertTrue(preBindThrew, "SocketListener.start must throw on pre-bind parent swap revalidation failure")
        assertTrue(preBindSyscalls.areAllDescriptorsClosed, "All descriptors must be closed after pre-bind swap failure")

        preBindSyscalls.fstatatHook = nil
        var validStartThrew = false
        do { try preBindListener.start() } catch { validStartThrew = true }
        assertTrue(!validStartThrew, "Valid start must succeed after pre-bind swap failure")
        preBindListener.stop()
        assertTrue(preBindSyscalls.areAllDescriptorsClosed, "All descriptors must be closed after stop")

        // Refusal of FIFO or non-socket file at socket path (and inode survival)
        let fifoDir = "/tmp/agy-fifo-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: fifoDir, withIntermediateDirectories: true, attributes: [FileAttributeKey.posixPermissions: 0o700])
        let fifoPath = "\(fifoDir)/host.sock"
        mkfifo(fifoPath, 0o600)
        var preFifoStat = stat()
        assertEqual(lstat(fifoPath, &preFifoStat), 0)
        let origFifoInode = preFifoStat.st_ino

        let fifoListener = SocketListener(
            socketPath: fifoPath,
            server: HostServer(authorizer: FakeScreenRecordingAuthorizer(), topologyProvider: FakeDisplayTopologyProvider(), captureEngine: FakeCaptureEngine(), axEngine: DisabledAXInspector(), inputEngine: DisabledInputInjector()),
            perFrameTimeoutSec: 1.0,
            syscalls: scriptedSyscalls
        )
        var fifoThrew = false
        do { try fifoListener.start() } catch { fifoThrew = true }
        assertTrue(fifoThrew, "SocketListener.start must refuse FIFO file at socket path")

        var postFifoStat = stat()
        assertEqual(lstat(fifoPath, &postFifoStat), 0, "Original FIFO file must survive start failure")
        assertEqual(postFifoStat.st_ino, origFifoInode, "Original FIFO inode must remain unchanged")
        assertTrue((postFifoStat.st_mode & S_IFMT) == S_IFIFO, "Original FIFO type must remain S_IFIFO")
        assertTrue(scriptedSyscalls.areAllDescriptorsClosed, "All descriptors must be closed after FIFO refusal")

        unlink(fifoPath)
        var fifoStartThrew = false
        do { try fifoListener.start() } catch { fifoStartThrew = true }
        assertTrue(!fifoStartThrew, "Valid start must succeed after FIFO removal")
        fifoListener.stop()
        rmdir(fifoDir)

        // Foreign replacement file survival on stop()
        let foreignDir = "/tmp/agy-foreign-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: foreignDir, withIntermediateDirectories: true, attributes: [FileAttributeKey.posixPermissions: 0o700])
        let foreignSockPath = "\(foreignDir)/host.sock"
        let foreignListener = SocketListener(
            socketPath: foreignSockPath,
            server: HostServer(authorizer: FakeScreenRecordingAuthorizer(), topologyProvider: FakeDisplayTopologyProvider(), captureEngine: FakeCaptureEngine(), axEngine: DisabledAXInspector(), inputEngine: DisabledInputInjector()),
            perFrameTimeoutSec: 1.0,
            syscalls: scriptedSyscalls
        )
        try foreignListener.start()

        unlink(foreignSockPath)
        let foreignFd = open(foreignSockPath, O_CREAT | O_WRONLY, 0o600)
        assertTrue(foreignFd >= 0)
        close(foreignFd)
        var foreignStat = stat()
        assertEqual(lstat(foreignSockPath, &foreignStat), 0)

        foreignListener.stop()
        var postStopStat = stat()
        assertEqual(lstat(foreignSockPath, &postStopStat), 0, "Foreign replacement file must survive listener.stop()")
        assertEqual(postStopStat.st_ino, foreignStat.st_ino, "Foreign replacement file inode must remain untouched")
        unlink(foreignSockPath)
        rmdir(foreignDir)

        // Descriptor bookkeeping fd-reuse / failed-close discriminator test
        let discSyscalls = ScriptedPOSIXSyscalls()
        let fd1 = discSyscalls.open("/dev/null", O_RDONLY, 0)
        assertTrue(fd1 >= 0)
        assertEqual(discSyscalls.activeGenerationCount, 1)
        assertTrue(!discSyscalls.areAllDescriptorsClosed)
        let closeRes = discSyscalls.close(fd1)
        assertEqual(closeRes, 0)
        assertEqual(discSyscalls.activeGenerationCount, 0)
        assertTrue(discSyscalls.areAllDescriptorsClosed)
    }

    public struct FourSurfaces {
        public let manifest: [String]
        public let xctestFuncs: [String]
        public let allTests: [String]
        public let runnerCalls: [String]
    }

    public enum FourSurfaceValidationError: Error {
        case duplicateInSurface(String)
        case emptySurface
        case mismatch(String)
    }

    public static func validateFourSurfaces(_ surfaces: FourSurfaces) throws {
        guard surfaces.manifest.count == Set(surfaces.manifest).count else {
            throw FourSurfaceValidationError.duplicateInSurface("manifest")
        }
        guard surfaces.xctestFuncs.count == Set(surfaces.xctestFuncs).count else {
            throw FourSurfaceValidationError.duplicateInSurface("xctestFuncs")
        }
        guard surfaces.allTests.count == Set(surfaces.allTests).count else {
            throw FourSurfaceValidationError.duplicateInSurface("allTests")
        }
        guard surfaces.runnerCalls.count == Set(surfaces.runnerCalls).count else {
            throw FourSurfaceValidationError.duplicateInSurface("runnerCalls")
        }

        let s1 = Set(surfaces.manifest)
        let s2 = Set(surfaces.xctestFuncs)
        let s3 = Set(surfaces.allTests)
        let s4 = Set(surfaces.runnerCalls)

        guard !s1.isEmpty else {
            throw FourSurfaceValidationError.emptySurface
        }

        guard s1 == s2 else {
            throw FourSurfaceValidationError.mismatch("manifest vs xctestFuncs")
        }
        guard s1 == s3 else {
            throw FourSurfaceValidationError.mismatch("manifest vs allTests")
        }
        guard s1 == s4 else {
            throw FourSurfaceValidationError.mismatch("manifest vs runnerCalls")
        }
    }

    public static func loadFourSurfaces() throws -> FourSurfaces {
        let manifestPaths = ["docs/native_test_manifest.txt", "../../docs/native_test_manifest.txt"]
        var manifestContent: String? = nil
        for p in manifestPaths {
            if let c = try? String(contentsOfFile: p, encoding: .utf8) {
                manifestContent = c
                break
            }
        }
        guard let mContent = manifestContent else {
            throw FourSurfaceValidationError.emptySurface
        }
        let manifestLines = mContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let manifestList = manifestLines.compactMap { $0.components(separatedBy: "/").last }

        let testsPaths = ["Tests/ComputerUseHostTests/ComputerUseHostTests.swift", "../../apps/computer-use-host/Tests/ComputerUseHostTests/ComputerUseHostTests.swift", "apps/computer-use-host/Tests/ComputerUseHostTests/ComputerUseHostTests.swift"]
        var testsContent: String? = nil
        for p in testsPaths {
            if let c = try? String(contentsOfFile: p, encoding: .utf8) {
                testsContent = c
                break
            }
        }
        guard let tContent = testsContent else {
            throw FourSurfaceValidationError.emptySurface
        }
        let xctestFuncLines = tContent.components(separatedBy: "\n")
            .filter { $0.contains("func test") && $0.contains("() throws {") }
            .compactMap { line -> String? in
                guard let range = line.range(of: "test[0-9]{2}_[A-Za-z0-9_]+", options: .regularExpression) else { return nil }
                return String(line[range])
            }

        let allTestsMatches = tContent.components(separatedBy: "\n")
            .filter { $0.contains("(\"test") }
            .compactMap { line -> String? in
                guard let firstQuote = line.range(of: "\"test")?.lowerBound,
                      let secondQuote = line[line.index(after: firstQuote)...].range(of: "\"")?.lowerBound else { return nil }
                return String(line[line.index(after: firstQuote)..<secondQuote])
            }

        let runnerPaths = ["Tests/ComputerUseHostTestRunner/main.swift", "../../apps/computer-use-host/Tests/ComputerUseHostTestRunner/main.swift", "apps/computer-use-host/Tests/ComputerUseHostTestRunner/main.swift"]
        var runnerContent: String? = nil
        for p in runnerPaths {
            if let c = try? String(contentsOfFile: p, encoding: .utf8) {
                runnerContent = c
                break
            }
        }
        guard let rContent = runnerContent else {
            throw FourSurfaceValidationError.emptySurface
        }
        let runnerCalls = rContent.components(separatedBy: "\n")
            .filter { $0.contains("runWithWatchdog(name: \"test") }
            .compactMap { line -> String? in
                guard let range = line.range(of: "test[0-9]{2}_[A-Za-z0-9_]+", options: .regularExpression) else { return nil }
                return String(line[range])
            }

        return FourSurfaces(
            manifest: manifestList,
            xctestFuncs: xctestFuncLines,
            allTests: allTestsMatches,
            runnerCalls: runnerCalls
        )
    }

    public static func run36_FourSurfaceAuthorityBijection() async throws {
        let surfaces = try loadFourSurfaces()
        try validateFourSurfaces(surfaces)

        let baseList = surfaces.manifest
        if baseList.isEmpty { fail("Base surface must not be empty") }
        let firstItem = baseList[0]
        let extraItem = "test99_InjectedExtraTest"
        let renamedItem = "test01_RenamedMismatch"

        func assertThrows(_ block: () throws -> Void, _ msg: String) {
            var threw = false
            do {
                try block()
            } catch {
                threw = true
            }
            if !threw {
                fail(msg)
            }
        }

        // Surface 1 (manifest) mutations: missing, extra, duplicate, renamed
        assertThrows({ try validateFourSurfaces(FourSurfaces(manifest: Array(baseList.dropFirst()), xctestFuncs: surfaces.xctestFuncs, allTests: surfaces.allTests, runnerCalls: surfaces.runnerCalls)) }, "Surface 1 missing item must throw")
        assertThrows({ try validateFourSurfaces(FourSurfaces(manifest: baseList + [extraItem], xctestFuncs: surfaces.xctestFuncs, allTests: surfaces.allTests, runnerCalls: surfaces.runnerCalls)) }, "Surface 1 extra item must throw")
        assertThrows({ try validateFourSurfaces(FourSurfaces(manifest: baseList + [firstItem], xctestFuncs: surfaces.xctestFuncs, allTests: surfaces.allTests, runnerCalls: surfaces.runnerCalls)) }, "Surface 1 duplicate item must throw")
        assertThrows({ try validateFourSurfaces(FourSurfaces(manifest: [renamedItem] + Array(baseList.dropFirst()), xctestFuncs: surfaces.xctestFuncs, allTests: surfaces.allTests, runnerCalls: surfaces.runnerCalls)) }, "Surface 1 renamed item must throw")

        // Surface 2 (XCTest functions) mutations: missing, extra, duplicate, renamed
        assertThrows({ try validateFourSurfaces(FourSurfaces(manifest: surfaces.manifest, xctestFuncs: Array(baseList.dropFirst()), allTests: surfaces.allTests, runnerCalls: surfaces.runnerCalls)) }, "Surface 2 missing item must throw")
        assertThrows({ try validateFourSurfaces(FourSurfaces(manifest: surfaces.manifest, xctestFuncs: baseList + [extraItem], allTests: surfaces.allTests, runnerCalls: surfaces.runnerCalls)) }, "Surface 2 extra item must throw")
        assertThrows({ try validateFourSurfaces(FourSurfaces(manifest: surfaces.manifest, xctestFuncs: baseList + [firstItem], allTests: surfaces.allTests, runnerCalls: surfaces.runnerCalls)) }, "Surface 2 duplicate item must throw")
        assertThrows({ try validateFourSurfaces(FourSurfaces(manifest: surfaces.manifest, xctestFuncs: [renamedItem] + Array(baseList.dropFirst()), allTests: surfaces.allTests, runnerCalls: surfaces.runnerCalls)) }, "Surface 2 renamed item must throw")

        // Surface 3 (__allTests) mutations: missing, extra, duplicate, renamed
        assertThrows({ try validateFourSurfaces(FourSurfaces(manifest: surfaces.manifest, xctestFuncs: surfaces.xctestFuncs, allTests: Array(baseList.dropFirst()), runnerCalls: surfaces.runnerCalls)) }, "Surface 3 missing item must throw")
        assertThrows({ try validateFourSurfaces(FourSurfaces(manifest: surfaces.manifest, xctestFuncs: surfaces.xctestFuncs, allTests: baseList + [extraItem], runnerCalls: surfaces.runnerCalls)) }, "Surface 3 extra item must throw")
        assertThrows({ try validateFourSurfaces(FourSurfaces(manifest: surfaces.manifest, xctestFuncs: surfaces.xctestFuncs, allTests: baseList + [firstItem], runnerCalls: surfaces.runnerCalls)) }, "Surface 3 duplicate item must throw")
        assertThrows({ try validateFourSurfaces(FourSurfaces(manifest: surfaces.manifest, xctestFuncs: surfaces.xctestFuncs, allTests: [renamedItem] + Array(baseList.dropFirst()), runnerCalls: surfaces.runnerCalls)) }, "Surface 3 renamed item must throw")

        // Surface 4 (runner calls) mutations: missing, extra, duplicate, renamed
        assertThrows({ try validateFourSurfaces(FourSurfaces(manifest: surfaces.manifest, xctestFuncs: surfaces.xctestFuncs, allTests: surfaces.allTests, runnerCalls: Array(baseList.dropFirst()))) }, "Surface 4 missing item must throw")
        assertThrows({ try validateFourSurfaces(FourSurfaces(manifest: surfaces.manifest, xctestFuncs: surfaces.xctestFuncs, allTests: surfaces.allTests, runnerCalls: baseList + [extraItem])) }, "Surface 4 extra item must throw")
        assertThrows({ try validateFourSurfaces(FourSurfaces(manifest: surfaces.manifest, xctestFuncs: surfaces.xctestFuncs, allTests: surfaces.allTests, runnerCalls: baseList + [firstItem])) }, "Surface 4 duplicate item must throw")
        assertThrows({ try validateFourSurfaces(FourSurfaces(manifest: surfaces.manifest, xctestFuncs: surfaces.xctestFuncs, allTests: surfaces.allTests, runnerCalls: [renamedItem] + Array(baseList.dropFirst()))) }, "Surface 4 renamed item must throw")
    }

    private static func runWithWatchdog(name: String, timeoutSec: Double = 10.0, _ block: @Sendable @escaping () async throws -> Void) async throws {
        let sem = DispatchSemaphore(value: 0)
        let errorBox = ErrorBox()
        let task = Task {
            do {
                try await block()
            } catch {
                errorBox.set(error)
            }
            sem.signal()
        }

        let watchdogThread = Thread {
            let timeoutResult = sem.wait(timeout: .now() + .seconds(Int(timeoutSec)))
            if timeoutResult == .timedOut {
                fputs("[FAIL] Hard watchdog timeout for test: \(name)\n", stderr)
                task.cancel()
                _exit(1)
            }
        }
        watchdogThread.start()
        _ = await task.value
        if let err = errorBox.value { throw err }
    }

    public static func main() async throws {
        signal(SIGPIPE, SIG_IGN)
        fputs("[ComputerUseHostTestRunner] Starting Native Test Runner Authority...\n", stderr)
        try await runWithWatchdog(name: "test01_LengthPrefixedFraming") { try await run01_LengthPrefixedFraming() }
        try await runWithWatchdog(name: "test02_OversizedFramingHeaderRejection") { try await run02_OversizedFramingHeaderRejection() }
        try await runWithWatchdog(name: "test03_DirectoryPreparation") { try await run03_DirectoryPreparation() }
        try await runWithWatchdog(name: "test04_UDSClientServerRoundTrip") { try await run04_UDSClientServerRoundTrip() }
        try await runWithWatchdog(name: "test05_PostTimeoutUDSRecovery") { try await run05_PostTimeoutUDSRecovery() }
        try await runWithWatchdog(name: "test06_SlowDripHeaderTimeout") { try await run06_SlowDripHeaderTimeout() }
        try await runWithWatchdog(name: "test07_SlowDripBodyTimeout") { try await run07_SlowDripBodyTimeout() }
        try await runWithWatchdog(name: "test08_BlockedResponseWriteTimeout") { try await run08_BlockedResponseWriteTimeout() }
        try await runWithWatchdog(name: "test09_PeerCloseAndPartialIO") { try await run09_PeerCloseAndPartialIO() }
        try await runWithWatchdog(name: "test10_EINTRRetryPath") { try await run10_EINTRRetryPath() }
        try await runWithWatchdog(name: "test11_TimeoutResponseFollowedByNextClient") { try await run11_TimeoutResponseFollowedByNextClient() }
        try await runWithWatchdog(name: "test12_LiveSocketCollisionProbe") { try await run12_LiveSocketCollisionProbe() }
        try await runWithWatchdog(name: "test13_VerifiedStaleSocketRecovery") { try await run13_VerifiedStaleSocketRecovery() }
        try await runWithWatchdog(name: "test14_ForeignSymlinkNonSocketRefusal") { try await run14_ForeignSymlinkNonSocketRefusal() }
        try await runWithWatchdog(name: "test15_StopNeverUnlinksReplacementInode") { try await run15_StopNeverUnlinksReplacementInode() }
        try await runWithWatchdog(name: "test16_IEEE754BitPatternTopologyGoldenVectorAndMutations") { try await run16_IEEE754BitPatternTopologyGoldenVectorAndMutations() }
        try await runWithWatchdog(name: "test17_HotPlugSafeDisplayEnumerator") { try await run17_HotPlugSafeDisplayEnumerator() }
        try await runWithWatchdog(name: "test18_PermissionPreflightDeniedZeroLoaderCalls") { try await run18_PermissionPreflightDeniedZeroLoaderCalls() }
        try await runWithWatchdog(name: "test19_PureJPEGValidatorExactAndNear10MiBBoundaries") { try await run19_PureJPEGValidatorExactAndNear10MiBBoundaries() }
        try await runWithWatchdog(name: "test20_SOF0AndSOF2MarkerValidation") { try await run20_SOF0AndSOF2MarkerValidation() }
        try await runWithWatchdog(name: "test21_JPEGInvalidMagicTruncatedSegmentAndMismatchRejection") { try await run21_JPEGInvalidMagicTruncatedSegmentAndMismatchRejection() }
        try await runWithWatchdog(name: "test22_NoncooperativeLateCompletionGenerationFence") { try await run22_NoncooperativeLateCompletionGenerationFence() }
        try await runWithWatchdog(name: "test23_StaleOperationGenerationFence") { try await run23_StaleOperationGenerationFence() }
        try await runWithWatchdog(name: "test24_RequesterCancellation") { try await run24_RequesterCancellation() }
        try await runWithWatchdog(name: "test25_TimedOutOrphanCapacity") { try await run25_TimedOutOrphanCapacity() }
        try await runWithWatchdog(name: "test26_TopologyChangeDuringCaptureDiscarded") { try await run26_TopologyChangeDuringCaptureDiscarded() }
        try await runWithWatchdog(name: "test27_DisabledActionsAndAXTreeRejection") { try await run27_DisabledActionsAndAXTreeRejection() }
        try await runWithWatchdog(name: "test28_DisplayIdParameterValidation") { try await run28_DisplayIdParameterValidation() }
        try await runWithWatchdog(name: "test29_CancellationErrorMappedToCancelledCode") { try await run29_CancellationErrorMappedToCancelledCode() }
        try await runWithWatchdog(name: "test30_PartialStartRollback") { try await run30_PartialStartRollback() }
        try await runWithWatchdog(name: "test31_AcceptEINTRRetry") { try await run31_AcceptEINTRRetry() }
        try await runWithWatchdog(name: "test32_ReadHeaderBodyEINTRRetry") { try await run32_ReadHeaderBodyEINTRRetry() }
        try await runWithWatchdog(name: "test33_WriteResponseEAGAINDeadlineAndSingleAttempt") { try await run33_WriteResponseEAGAINDeadlineAndSingleAttempt() }
        try await runWithWatchdog(name: "test34_PositiveByteAdvancesClockPastDeadlineReturnsTimeout") { try await run34_PositiveByteAdvancesClockPastDeadlineReturnsTimeout() }
        try await runWithWatchdog(name: "test35_InjectedListenFailurePostBindRollback") { try await run35_InjectedListenFailurePostBindRollback() }
        try await runWithWatchdog(name: "test36_FourSurfaceAuthorityBijection") { try await run36_FourSurfaceAuthorityBijection() }
        try await runWithWatchdog(name: "test37_ManualSleeperSevenDeterministicScenarios") { try await run37_ManualSleeperSevenDeterministicScenarios() }
        fputs("[ComputerUseHostTestRunner] Executed 37 native test cases successfully. ALL PASSED.\n", stderr)
    }

    public static func run37_ManualSleeperSevenDeterministicScenarios() async throws {
        final class TestGate: @unchecked Sendable {
            private let cond = NSCondition()
            private var arrivedCount: Int = 0
            private var released: Bool = false
            private var waiterCount: Int = 0

            func signalArrived(timeoutSec: Double = 5.0) {
                cond.lock()
                arrivedCount += 1
                waiterCount += 1
                cond.broadcast()
                let deadline = Date().addingTimeInterval(timeoutSec)
                while !released {
                    if !cond.wait(until: deadline) {
                        waiterCount -= 1
                        cond.unlock()
                        fatalError("TestGate timeout waiting for release")
                    }
                }
                waiterCount -= 1
                cond.unlock()
            }

            func waitUntilArrived(targetCount: Int = 1, timeoutSec: Double = 5.0) {
                cond.lock()
                let deadline = Date().addingTimeInterval(timeoutSec)
                while arrivedCount < targetCount {
                    if !cond.wait(until: deadline) {
                        cond.unlock()
                        fatalError("TestGate timeout waiting for arrival (arrived: \(arrivedCount), target: \(targetCount))")
                    }
                }
                cond.unlock()
            }

            func release() {
                cond.lock()
                released = true
                cond.broadcast()
                cond.unlock()
            }

            func assertClosed(line: Int = #line) {
                cond.lock()
                let rel = released
                let wc = waiterCount
                cond.unlock()
                assertTrue(rel, "TestGate must be released at line \(line)")
                assertEqual(wc, 0, "TestGate must have 0 live waiters at line \(line)")
            }
        }

        // 1. Discriminator 1: Registering + cancelAll -> (1, 0, 1)
        let gate1 = TestGate()
        let sleeper1 = ManualSleeper(hooks: ManualSleeper.Hooks(
            preRegistration: { sleeper, id in
                assertEqual(sleeper.getState(id: id), .registering)
                gate1.signalArrived()
            }
        ))
        let t1 = Task { try await sleeper1.sleep(nanoseconds: 100_000_000) }
        gate1.waitUntilArrived()
        sleeper1.cancelAll()
        assertEqual(sleeper1.getState(id: 1), .cancelledBeforePublish)
        gate1.release()
        var threw1 = false
        do { try await t1.value } catch is CancellationError { threw1 = true } catch {}
        assertTrue(threw1, "Discriminator 1: Paused at registration gate must throw CancellationError on cancelAll")
        sleeper1.assertCounters(issued: 1, succeeded: 0, cancelled: 1)
        sleeper1.assertNoUnresolvedContinuations()
        gate1.assertClosed()

        // 2. Discriminator 2: Buffered cancellation -> (2, 1, 1)
        let gate2 = TestGate()
        let sleeper2 = ManualSleeper(hooks: ManualSleeper.Hooks(
            preRegistration: { _, id in
                if id == 1 { gate2.signalArrived() }
            }
        ))
        let tA2 = Task { try await sleeper2.sleep(nanoseconds: 100_000_000) }
        gate2.waitUntilArrived()
        sleeper2.advance() // Creates 1 real buffer
        tA2.cancel()        // Cancels tA2 -> state becomes cancelledBeforePublish
        assertEqual(sleeper2.getState(id: 1), .cancelledBeforePublish)
        gate2.release()
        var threwA2 = false
        do { try await tA2.value } catch is CancellationError { threwA2 = true } catch {}
        assertTrue(threwA2, "Discriminator 2: Cancelled waiter must throw CancellationError without consuming buffer")

        let tB2 = Task { try await sleeper2.sleep(nanoseconds: 100_000_000) }
        try await tB2.value // tB2 consumes the buffered advance successfully
        sleeper2.assertCounters(issued: 2, succeeded: 1, cancelled: 1)
        sleeper2.assertNoUnresolvedContinuations()
        gate2.assertClosed()

        // 3. Discriminator 3: Cancel after wake selection with postResumeBeforeFinish gate -> (1, 0, 1)
        let postResumeGate3 = TestGate()
        let sleeper3 = ManualSleeper(hooks: ManualSleeper.Hooks(
            postResumeBeforeFinish: { _, _ in postResumeGate3.signalArrived() }
        ))
        let t3 = Task { try await sleeper3.sleep(nanoseconds: 100_000_000) }
        await sleeper3.waitUntilSuspended(count: 1)
        if case .suspended = sleeper3.getState(id: 1) {} else { assertTrue(false, "Discriminator 3: State 1 must be .suspended") }
        sleeper3.advance() // Selects t3 for wake -> state becomes waking, resumes continuation, pauses at postResumeBeforeFinish
        postResumeGate3.waitUntilArrived()
        t3.cancel()        // Cancels t3 -> state becomes cancelledAfterWake
        assertEqual(sleeper3.getState(id: 1), .cancelledAfterWake)
        postResumeGate3.release()
        var threw3 = false
        do { try await t3.value } catch is CancellationError { threw3 = true } catch {}
        assertTrue(threw3, "Discriminator 3: Cancellation after wake selection must throw CancellationError")
        sleeper3.assertCounters(issued: 1, succeeded: 0, cancelled: 1)
        sleeper3.assertNoUnresolvedContinuations()
        postResumeGate3.assertClosed()

        // 4. Discriminator 4: Mixed cancelAll (one registering, one suspended) -> (2, 0, 2)
        let gate4 = TestGate()
        let sleeper4 = ManualSleeper(hooks: ManualSleeper.Hooks(
            preRegistration: { _, id in
                if id == 1 { gate4.signalArrived() }
            }
        ))
        let tA4 = Task { try await sleeper4.sleep(nanoseconds: 100_000_000) }
        gate4.waitUntilArrived() // tA4 is at registering
        let tB4 = Task { try await sleeper4.sleep(nanoseconds: 100_000_000) }
        await sleeper4.waitUntilSuspended(count: 1) // tB4 is suspended
        assertEqual(sleeper4.getState(id: 1), .registering)
        if case .suspended = sleeper4.getState(id: 2) {} else { assertTrue(false, "Discriminator 4: State 2 must be .suspended") }
        sleeper4.cancelAll()
        assertEqual(sleeper4.getState(id: 1), .cancelledBeforePublish)
        gate4.release()
        var threwA4 = false, threwB4 = false
        do { try await tA4.value } catch is CancellationError { threwA4 = true } catch {}
        do { try await tB4.value } catch is CancellationError { threwB4 = true } catch {}
        assertTrue(threwA4 && threwB4, "Discriminator 4: Both registering and suspended waiters must throw CancellationError on cancelAll")
        sleeper4.assertCounters(issued: 2, succeeded: 0, cancelled: 2)
        sleeper4.assertNoUnresolvedContinuations()
        gate4.assertClosed()

        // 5. Discriminator 5: Honest observer registration gate proof & two-waiter isolation -> (2, 1, 1)
        let obsGate5 = TestGate()
        let regGate5 = TestGate()
        let sleeper5 = ManualSleeper(hooks: ManualSleeper.Hooks(
            preRegistration: { _, id in
                if id == 1 { regGate5.signalArrived() }
            },
            observerRegistered: { count in
                if count == 1 { obsGate5.signalArrived() }
            }
        ))
        let w1 = Task { try await sleeper5.sleep(nanoseconds: 100_000_000) }
        regGate5.waitUntilArrived() // w1 is paused at preRegistration

        let obsTask = Task { await sleeper5.waitUntilSuspended(count: 1) }
        obsGate5.waitUntilArrived() // Proves waitUntilSuspended registered while w1 was paused!
        obsGate5.release()

        regGate5.release() // w1 completes registration and suspends
        await obsTask.value // obsTask resolves now that count == 1

        let w2 = Task { try await sleeper5.sleep(nanoseconds: 100_000_000) }
        await sleeper5.waitUntilSuspended(count: 2)
        if case .suspended = sleeper5.getState(id: 1) {} else { assertTrue(false, "Discriminator 5: State 1 must be .suspended") }
        if case .suspended = sleeper5.getState(id: 2) {} else { assertTrue(false, "Discriminator 5: State 2 must be .suspended") }
        w1.cancel()
        var threwW1 = false
        do { try await w1.value } catch is CancellationError { threwW1 = true } catch {}
        assertTrue(threwW1, "Discriminator 5: Cancelled waiter 1 must throw CancellationError")

        sleeper5.advance()
        try await w2.value
        sleeper5.assertCounters(issued: 2, succeeded: 1, cancelled: 1)
        sleeper5.assertNoUnresolvedContinuations()
        obsGate5.assertClosed()
        regGate5.assertClosed()

        // 6. Discriminator 6 (R1-C2A): Exact publication-boundary state snapshot -> (1, 1, 0)
        let pubGate6 = TestGate()
        let sleeper6 = ManualSleeper(hooks: ManualSleeper.Hooks(
            afterSuspendedPublication: { _, _ in pubGate6.signalArrived() }
        ))
        let t6 = Task { try await sleeper6.sleep(nanoseconds: 100_000_000) }
        pubGate6.waitUntilArrived()
        let snapPre = sleeper6.snapshot(for: 1)
        if case .suspended = snapPre.targetState {} else { assertTrue(false, "R1-C2A: Target state must be .suspended") }
        assertEqual(snapPre.pendingIDs, [1], "R1-C2A: Pending IDs snapshot must be [1]")
        assertEqual(snapPre.bufferedAdvances, 0, "R1-C2A: Buffered advances snapshot must be 0")

        sleeper6.advance() // Resumes published waiter, state becomes .waking
        let snapPost = sleeper6.snapshot(for: 1)
        assertEqual(snapPost.targetState, .waking, "R1-C2A: Target state after advance must be .waking")
        assertEqual(snapPost.pendingIDs, [], "R1-C2A: Pending IDs after advance must be []")
        assertEqual(snapPost.bufferedAdvances, 0, "R1-C2A: Buffered advances after advance must be 0")

        pubGate6.release()
        try await t6.value
        sleeper6.assertCounters(issued: 1, succeeded: 1, cancelled: 0)
        sleeper6.assertNoUnresolvedContinuations()
        pubGate6.assertClosed()

        // 7. Discriminator 7: Direct lost-wake boundary (advance before publication) -> (1, 1, 0)
        let gate7 = TestGate()
        let sleeper7 = ManualSleeper(hooks: ManualSleeper.Hooks(
            preRegistration: { _, _ in gate7.signalArrived() }
        ))
        let t7 = Task { try await sleeper7.sleep(nanoseconds: 100_000_000) }
        gate7.waitUntilArrived()
        sleeper7.advance() // Advance before publication callback
        gate7.release()
        try await t7.value // Must consume buffer and succeed without ever suspending
        sleeper7.assertCounters(issued: 1, succeeded: 1, cancelled: 0)
        sleeper7.assertNoUnresolvedContinuations()
        gate7.assertClosed()

        // 8. Discriminator 8 (R1-C3A): Cancellation while paused at earliest afterReserveBeforeRegistering boundary -> (1, 0, 1)
        let gateReserveCancel = TestGate()
        let sleeperReserveCancel = ManualSleeper(hooks: ManualSleeper.Hooks(
            afterReserveBeforeRegistering: { sleeper, id in
                assertEqual(sleeper.getState(id: id), .reserved)
                gateReserveCancel.signalArrived()
            }
        ))
        let tRes = Task { try await sleeperReserveCancel.sleep(nanoseconds: 100_000_000) }
        gateReserveCancel.waitUntilArrived()
        tRes.cancel() // Cancellation handler executes while paused inside afterReserveBeforeRegistering
        assertEqual(sleeperReserveCancel.getState(id: 1), .cancelledBeforePublish)
        gateReserveCancel.release()
        var threwRes = false
        do { try await tRes.value } catch is CancellationError { threwRes = true } catch {}
        assertTrue(threwRes, "Discriminator 8: Cancellation at afterReserveBeforeRegistering boundary must throw CancellationError")
        sleeperReserveCancel.assertCounters(issued: 1, succeeded: 0, cancelled: 1)
        sleeperReserveCancel.assertNoUnresolvedContinuations()
        gateReserveCancel.assertClosed()

        // 9. Negative Invariant 1: Missing state before markRegistering throws SleeperInvariantError
        let gateNeg1 = TestGate()
        let sleeperNeg1 = ManualSleeper(hooks: ManualSleeper.Hooks(
            afterReserveBeforeRegistering: { sleeper, id in
                sleeper.corruptStateForTest(id: id, newState: nil)
                gateNeg1.signalArrived()
            }
        ))
        let tNeg1 = Task { try await sleeperNeg1.sleep(nanoseconds: 100_000_000) }
        gateNeg1.waitUntilArrived()
        gateNeg1.release()
        var stageNeg1: SleeperInvariantError.Stage?
        do { try await tNeg1.value } catch let err as SleeperInvariantError { stageNeg1 = err.stage } catch {}
        assertEqual(stageNeg1, .markRegistering, "Negative Invariant 1: Error stage must be .markRegistering")
        assertEqual(sleeperNeg1.issuedCount, 1)
        assertEqual(sleeperNeg1.succeededCount, 0)
        assertEqual(sleeperNeg1.cancelledCount, 0)
        assertEqual(sleeperNeg1.invariantCount, 1)
        sleeperNeg1.assertZeroState()
        gateNeg1.assertClosed()

        // 10. Negative Invariant 2: Invalid existing state before markRegistering throws SleeperInvariantError
        let gateNeg2 = TestGate()
        let sleeperNeg2 = ManualSleeper(hooks: ManualSleeper.Hooks(
            afterReserveBeforeRegistering: { sleeper, id in
                sleeper.corruptStateForTest(id: id, newState: .corruptedTestState)
                gateNeg2.signalArrived()
            }
        ))
        let tNeg2 = Task { try await sleeperNeg2.sleep(nanoseconds: 100_000_000) }
        gateNeg2.waitUntilArrived()
        gateNeg2.release()
        var stageNeg2: SleeperInvariantError.Stage?
        do { try await tNeg2.value } catch let err as SleeperInvariantError { stageNeg2 = err.stage } catch {}
        assertEqual(stageNeg2, .markRegistering, "Negative Invariant 2: Error stage must be .markRegistering")
        assertEqual(sleeperNeg2.issuedCount, 1)
        assertEqual(sleeperNeg2.succeededCount, 0)
        assertEqual(sleeperNeg2.cancelledCount, 0)
        assertEqual(sleeperNeg2.invariantCount, 1)
        sleeperNeg2.assertZeroState()
        gateNeg2.assertClosed()

        // 11. Negative Invariant 3: Missing state before publication throws SleeperInvariantError
        let gateNeg3 = TestGate()
        let sleeperNeg3 = ManualSleeper(hooks: ManualSleeper.Hooks(
            preRegistration: { sleeper, id in
                sleeper.corruptStateForTest(id: id, newState: nil)
                gateNeg3.signalArrived()
            }
        ))
        let tNeg3 = Task { try await sleeperNeg3.sleep(nanoseconds: 100_000_000) }
        gateNeg3.waitUntilArrived()
        gateNeg3.release()
        var stageNeg3: SleeperInvariantError.Stage?
        do { try await tNeg3.value } catch let err as SleeperInvariantError { stageNeg3 = err.stage } catch {}
        assertEqual(stageNeg3, .publication, "Negative Invariant 3: Error stage must be .publication")
        assertEqual(sleeperNeg3.issuedCount, 1)
        assertEqual(sleeperNeg3.succeededCount, 0)
        assertEqual(sleeperNeg3.cancelledCount, 0)
        assertEqual(sleeperNeg3.invariantCount, 1)
        sleeperNeg3.assertZeroState()
        gateNeg3.assertClosed()

        // 12. Negative Invariant 4: Invalid existing state before publication throws SleeperInvariantError
        let gateNeg4 = TestGate()
        let sleeperNeg4 = ManualSleeper(hooks: ManualSleeper.Hooks(
            preRegistration: { sleeper, id in
                sleeper.corruptStateForTest(id: id, newState: .corruptedTestState)
                gateNeg4.signalArrived()
            }
        ))
        let tNeg4 = Task { try await sleeperNeg4.sleep(nanoseconds: 100_000_000) }
        gateNeg4.waitUntilArrived()
        gateNeg4.release()
        var stageNeg4: SleeperInvariantError.Stage?
        do { try await tNeg4.value } catch let err as SleeperInvariantError { stageNeg4 = err.stage } catch {}
        assertEqual(stageNeg4, .publication, "Negative Invariant 4: Error stage must be .publication")
        assertEqual(sleeperNeg4.issuedCount, 1)
        assertEqual(sleeperNeg4.succeededCount, 0)
        assertEqual(sleeperNeg4.cancelledCount, 0)
        assertEqual(sleeperNeg4.invariantCount, 1)
        sleeperNeg4.assertZeroState()
        gateNeg4.assertClosed()

        // 13. Negative Invariant 5: Missing state on finish path throws SleeperInvariantError
        let postResumeGateNeg5 = TestGate()
        let sleeperNeg5 = ManualSleeper(hooks: ManualSleeper.Hooks(
            postResumeBeforeFinish: { sleeper, id in
                sleeper.corruptStateForTest(id: id, newState: nil)
                postResumeGateNeg5.signalArrived()
            }
        ))
        let tNeg5 = Task { try await sleeperNeg5.sleep(nanoseconds: 100_000_000) }
        await sleeperNeg5.waitUntilSuspended(count: 1)
        sleeperNeg5.advance() // State becomes .waking, continuation resumes, hits postResumeBeforeFinish
        postResumeGateNeg5.waitUntilArrived()
        postResumeGateNeg5.release()
        var stageNeg5: SleeperInvariantError.Stage?
        do { try await tNeg5.value } catch let err as SleeperInvariantError { stageNeg5 = err.stage } catch {}
        assertEqual(stageNeg5, .finish, "Negative Invariant 5: Error stage must be .finish")
        assertEqual(sleeperNeg5.issuedCount, 1)
        assertEqual(sleeperNeg5.succeededCount, 0)
        assertEqual(sleeperNeg5.cancelledCount, 0)
        assertEqual(sleeperNeg5.invariantCount, 1)
        sleeperNeg5.assertZeroState()
        postResumeGateNeg5.assertClosed()

        // 14. HostServer deadline authority: early wake -> re-arm -> single timeout response
        let controlledEngine = ControlledCaptureEngine()
        let sleeper14 = ManualSleeper()
        let manualClock = TestManualClock()
        let server14 = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: controlledEngine,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector(),
            observationTimeoutSec: 1.0,
            sleeper: sleeper14,
            clock: manualClock
        )

        let reqTask1 = Task { await server14.handleRequest(IPCRequest(id: "timeout-1", method: "observe")) }
        await controlledEngine.waitUntilRegistered(count: 1)
        await sleeper14.waitUntilIssued(count: 1)

        manualClock.advance(by: .milliseconds(500))
        sleeper14.advance()
        await sleeper14.waitUntilIssued(count: 2)

        manualClock.advance(by: .seconds(2))
        sleeper14.advance()

        let resp1 = await reqTask1.value
        assertTrue(!resp1.success, "HostServer deadline: First request must timeout")
        assertEqual(resp1.error?.code, "TIMEOUT")

        try await controlledEngine.complete(index: 0, with: .failure(ComputerUseError.timeout(operation: "observe", seconds: 1.0)))
        await controlledEngine.waitUntilExited(count: 1)
        assertEqual(await controlledEngine.pendingCount, 0, "HostServer deadline: Pending capture count must be zero")

        let frame2 = try FakeCaptureEngine().generateDTO(topology: FakeDisplayTopologyProvider().getTopology())
        let reqTask2 = Task { await server14.handleRequest(IPCRequest(id: "timeout-2", method: "observe")) }
        await controlledEngine.waitUntilRegistered(count: 2)
        try await controlledEngine.complete(index: 1, with: .success(frame2))
        let resp2 = await reqTask2.value
        assertTrue(resp2.success, "HostServer deadline: Second request must complete independently")
        assertEqual(await controlledEngine.pendingCount, 0, "HostServer deadline: Pending capture count zero")
        sleeper14.assertNoUnresolvedContinuations()

        // 15. Non-cancellation sleeper error propagation through HostServer production logic & capture exit
        struct CustomSleeperError: Error, Equatable {}
        struct ThrowingSleeper: Sleeper {
            func sleep(nanoseconds: UInt64) async throws {
                throw CustomSleeperError()
            }
        }
        let controlledEngine15 = ControlledCaptureEngine()
        let throwingServer = HostServer(
            authorizer: FakeScreenRecordingAuthorizer(granted: true),
            topologyProvider: FakeDisplayTopologyProvider(),
            captureEngine: controlledEngine15,
            axEngine: DisabledAXInspector(),
            inputEngine: DisabledInputInjector(),
            observationTimeoutSec: 1.0,
            sleeper: ThrowingSleeper()
        )
        let reqTask15 = Task { await throwingServer.handleRequest(IPCRequest(id: "err-1", method: "observe")) }
        await controlledEngine15.waitUntilRegistered(count: 1)
        let resp15 = await reqTask15.value
        assertTrue(!resp15.success, "Scenario 15: Injected sleeper error must cause request failure")
        assertEqual(resp15.error?.code, "HOST_ERROR", "Scenario 15: Error code must be HOST_ERROR")
        try await controlledEngine15.complete(index: 0, with: .failure(CustomSleeperError()))
        await controlledEngine15.waitUntilExited(count: 1)
        assertEqual(await controlledEngine15.pendingCount, 0, "Scenario 15: Pending capture count must be zero")
    }
}
