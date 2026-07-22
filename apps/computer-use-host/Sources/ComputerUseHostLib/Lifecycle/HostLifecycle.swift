import Foundation
import CagyPOSIX

public final class HostLifecycle: @unchecked Sendable {
    private let listener: SocketListener
    private let lock = NSLock()
    private var isStopped = false
    private var sigIntSource: (any DispatchSourceSignal)?
    private var sigTermSource: (any DispatchSourceSignal)?

    public init(listener: SocketListener) {
        self.listener = listener
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
        setupSignalHandlers()
        do {
            try listener.start()
        } catch {
            stop()
            throw error
        }
    }

    public func runAcceptLoop() async throws {
        while !self.isStoppedState {
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
        guard !isStopped else {
            lock.unlock()
            return
        }
        isStopped = true
        lock.unlock()

        sigIntSource?.cancel()
        sigTermSource?.cancel()
        sigIntSource = nil
        sigTermSource = nil
        listener.stop()
    }

    public var isStoppedState: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }
}
