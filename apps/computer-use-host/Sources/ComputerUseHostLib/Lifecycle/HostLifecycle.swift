import Foundation
import CagyPOSIX

public protocol HostListener: Sendable {
    func start() throws
    func acceptAndHandleOneConnection() async throws -> Bool
    func stop()
}

extension SocketListener: HostListener {}

public enum LifecycleState: Sendable, Equatable {
    case unstarted
    case starting
    case running
    case stopRequested
    case stopped
}

public final class HostLifecycle: @unchecked Sendable {
    private let listener: HostListener
    private let lock = NSLock()
    private var state: LifecycleState = .unstarted
    private var sigIntSource: (any DispatchSourceSignal)?
    private var sigTermSource: (any DispatchSourceSignal)?
    private var startHook: (() -> Void)?

    public init(listener: HostListener, startHook: (() -> Void)? = nil) {
        self.listener = listener
        self.startHook = startHook
    }

    public var currentState: LifecycleState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func setupSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let queue = DispatchQueue(label: "com.saariuslystoned.agy-computer-use.lifecycle")

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        intSource.setEventHandler { [weak self] in
            self?.stop()
        }
        intSource.resume()
        self.sigIntSource = intSource

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        termSource.setEventHandler { [weak self] in
            self?.stop()
        }
        termSource.resume()
        self.sigTermSource = termSource
    }

    public func start() throws {
        lock.lock()
        guard state == .unstarted else {
            lock.unlock()
            return
        }
        state = .starting
        lock.unlock()

        setupSignalHandlers()

        startHook?()

        do {
            try listener.start()
        } catch {
            stop()
            throw error
        }

        lock.lock()
        if state == .stopRequested || state == .stopped {
            state = .stopped
            lock.unlock()
            listener.stop()
            cancelSignalSources()
            return
        }
        state = .running
        lock.unlock()
    }

    public func runAcceptLoop() async throws {
        while true {
            if self.isStoppedState { break }

            let handled = try await listener.acceptAndHandleOneConnection()
            if !handled {
                if self.isStoppedState {
                    break
                } else {
                    throw ComputerUseError.ipcError(reason: "Unexpected false from acceptAndHandleOneConnection without requested termination")
                }
            }
        }
    }

    public func stop() {
        lock.lock()
        if state == .stopped {
            lock.unlock()
            return
        }
        if state == .starting {
            state = .stopRequested
            lock.unlock()
            return
        }
        state = .stopped
        lock.unlock()

        cancelSignalSources()
        listener.stop()
    }

    private func cancelSignalSources() {
        sigIntSource?.cancel()
        sigTermSource?.cancel()
        sigIntSource = nil
        sigTermSource = nil
    }

    public var isStoppedState: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .stopped || state == .stopRequested
    }
}
