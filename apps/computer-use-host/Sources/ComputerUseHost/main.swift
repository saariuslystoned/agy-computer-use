import Foundation
import ComputerUseHostLib

fileprivate func logStderr(_ message: String) {
    if let data = "\(message)\n".data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

@main
struct ComputerUseHostMain {
    static func main() async throws {
        logStderr("[ComputerUseHost] Starting native Unix domain socket server (v0.1-d2)...")

        let authorizer = CGScreenRecordingAuthorizer()
        let topologyProvider = SystemDisplayTopologyProvider()
        let captureEngine = SCScreenshotCaptureEngine(authorizer: authorizer)
        let inputEngine = DisabledInputInjector()
        let axEngine = DisabledAXInspector()

        let server = HostServer(
            authorizer: authorizer,
            topologyProvider: topologyProvider,
            captureEngine: captureEngine,
            axEngine: axEngine,
            inputEngine: inputEngine
        )

        let socketPathOverride = ProcessInfo.processInfo.environment["COMPUTER_USE_SOCKET_PATH"]
        let listener: SocketListener
        if let customPath = socketPathOverride, !customPath.isEmpty {
            listener = SocketListener(socketPath: customPath, server: server)
        } else {
            listener = SocketListener(server: server)
        }
        logStderr("[ComputerUseHost] Socket path: \(listener.socketPath)")

        let lifecycle = HostLifecycle(listener: listener)
        try lifecycle.start()
        logStderr("[ComputerUseHost] Socket listener bound and listening. Entering event loop...")

        defer {
            lifecycle.stop()
            logStderr("[ComputerUseHost] Host server stopped cleanly.")
        }

        try await lifecycle.runAcceptLoop()
    }
}
