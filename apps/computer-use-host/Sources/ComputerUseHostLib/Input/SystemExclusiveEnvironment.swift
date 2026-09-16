import Foundation
import CoreGraphics
import CagyPOSIX
import Darwin

/// Administrator-issued, short-lived admission. No request or environment flag
/// can substitute for this root-controlled record. This is an authorization
/// trust boundary, not automatic proof that a machine is a VM.
package struct SystemExclusiveEnvironment: ExclusiveEnvironmentProviding {
    package struct Record: Codable {
        let environment_id: String
        let environment_kind: String
        let host_instance_id: String
        let controller_id: String
        let uid: UInt32
        let gui_session_id: Int
        let expires_at_ms: Int
    }
    package static func validate(_ record: Record, controller: String, hostInstance: String,
                                 uid: UInt32, sessionID: Int, nowMs: Int) throws -> ExclusiveEnvironmentAdmission {
        guard !record.environment_id.isEmpty, record.environment_id.utf8.count <= 128,
              ["dedicated_worker", "isolated_vm"].contains(record.environment_kind),
              record.host_instance_id == hostInstance, record.controller_id == controller,
              record.uid == uid, record.gui_session_id == sessionID else {
            throw ComputerUseError.operatorExclusiveRequired(action: "admit")
        }
        guard record.expires_at_ms > nowMs, record.expires_at_ms - nowMs <= 300_000 else {
            throw ComputerUseError.exclusiveControlExpired
        }
        return ExclusiveEnvironmentAdmission(identity: record.environment_id, expiresAtMs: record.expires_at_ms)
    }
    package func admission(controller: String, hostInstance: String) throws -> ExclusiveEnvironmentAdmission {
        let fd = agy_open_exclusive_policy()
        guard fd >= 0 else { throw ComputerUseError.operatorExclusiveRequired(action: "admit") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0, info.st_size <= 4096 else { throw ComputerUseError.inputGuardUnavailable }
        var bytes = [UInt8](repeating: 0, count: 4097)
        let count = read(fd, &bytes, bytes.count)
        guard count == info.st_size,
              let record = try? JSONDecoder().decode(Record.self, from: Data(bytes.prefix(count))),
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true,
              let sessionID = session[kCGSessionConsoleSetKey as String] as? Int,
              let sessionUID = session[kCGSessionUserIDKey as String] as? UInt32,
              sessionUID == getuid() else { throw ComputerUseError.inputGuardUnavailable }
        return try Self.validate(record, controller: controller, hostInstance: hostInstance,
            uid: getuid(), sessionID: sessionID, nowMs: Int(Date().timeIntervalSince1970 * 1000))
    }
}
