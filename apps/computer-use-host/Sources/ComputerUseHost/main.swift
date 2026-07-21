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

        let listener = SocketListener(server: server)
        logStderr("[ComputerUseHost] Socket path: \(listener.socketPath)")

        try listener.start()
        logStderr("[ComputerUseHost] Socket listener bound and listening. Entering event loop...")

        // Process incoming IPC connection loop
        while true {
            do {
                _ = try await listener.acceptAndHandleOneConnection()
            } catch {
                logStderr("[ComputerUseHost] IPC connection error: \(error.localizedDescription)")
            }
        }
    }
}
