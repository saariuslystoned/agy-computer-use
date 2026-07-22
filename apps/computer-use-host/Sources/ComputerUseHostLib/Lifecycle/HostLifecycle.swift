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

public protocol HostSignalSource: AnyObject, Sendable {
    func resume()
    func cancel()
}

public protocol HostSignalSourceFactory: Sendable {
    func makeSignalSource(signal: Int32, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) -> any HostSignalSource
}

private final class DispatchSignalSourceAdapter: HostSignalSource, @unchecked Sendable {
    private let source: any DispatchSourceSignal

    init(source: any DispatchSourceSignal) {
        self.source = source
    }

    func resume() {
        source.resume()
    }

    func cancel() {
        source.cancel()
    }
}

public struct DefaultDispatchSignalSourceFactory: HostSignalSourceFactory {
    public init() {}
    public func makeSignalSource(signal sig: Int32, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) -> any HostSignalSource {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
        source.setEventHandler(handler: handler)
        let adapter = DispatchSignalSourceAdapter(source: source)
        adapter.resume()
        return adapter
    }
}

public final class HostLifecycle: @unchecked Sendable {
    private let listener: HostListener
    private let signalFactory: HostSignalSourceFactory
    private let lock = NSLock()
    private var state: LifecycleState = .unstarted
    private var sigIntSource: (any HostSignalSource)?
    private var sigTermSource: (any HostSignalSource)?
    private var startHook: (() -> Void)?

    public init(listener: HostListener, signalFactory: HostSignalSourceFactory = DefaultDispatchSignalSourceFactory(), startHook: (() -> Void)? = nil) {
        self.listener = listener
        self.signalFactory = signalFactory
        self.startHook = startHook
    }

    public var currentState: LifecycleState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func setupSignalHandlers() {
        let queue = DispatchQueue(label: "com.saariuslystoned.agy-computer-use.lifecycle")

        let intSource = signalFactory.makeSignalSource(signal: SIGINT, queue: queue) { [weak self] in
            self?.stop()
        }
        self.sigIntSource = intSource

        let termSource = signalFactory.makeSignalSource(signal: SIGTERM, queue: queue) { [weak self] in
            self?.stop()
        }
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
