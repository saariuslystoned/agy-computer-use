import Foundation
import ComputerUseHostLib

fileprivate func logStderr(_ message: String) {
    if let data = "\(message)\n".data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

logStderr("[ComputerUseHost] Foundation starting up (v0.1)...")
logStderr("[ComputerUseHost] Initializing HostServer with Fake/Deterministic Test Backends...")

let server = HostServer()
let statusReq = IPCRequest(id: "init-status", method: "status")
let response = server.handleRequest(statusReq)

logStderr("[ComputerUseHost] Status check completed. Success: \(response.success)")
if let data = response.data {
    logStderr("[ComputerUseHost] Data: \(data.mapValues { $0.rawValue })")
}

logStderr("[ComputerUseHost] Ready for local IPC socket connections.")
