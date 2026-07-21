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
        logStderr("[ComputerUseHost] Foundation starting up (v0.1)...")
        logStderr("[ComputerUseHost] Initializing HostServer Actor with Deterministic Test Seams...")

        let server = HostServer()
        let statusReq = IPCRequest(id: "init-status", method: "status")
        let response = await server.handleRequest(statusReq)

        logStderr("[ComputerUseHost] Status check completed. Success: \(response.success)")
        if let data = response.data {
            logStderr("[ComputerUseHost] Data: \(data.mapValues { $0.rawValue })")
        }

        let listener = SocketListener(server: server)
        logStderr("[ComputerUseHost] Socket path resolved: \(listener.socketPath)")
        try await listener.start()
        logStderr("[ComputerUseHost] Socket listener started successfully.")
        listener.stop()
    }
}
