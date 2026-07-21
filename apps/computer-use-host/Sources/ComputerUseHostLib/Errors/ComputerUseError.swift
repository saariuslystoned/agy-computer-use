import Foundation

public enum ComputerUseError: Error, Equatable, Codable {
    case staleTopology(current: String, received: String)
    case staleCapture(current: String, received: String)
    case outOfBounds(x: Int, y: Int, limitX: Int, limitY: Int)
    case velocityExceeded(requestedSpeed: Double, maxSpeed: Double)
    case targetUnreachable(reason: String)
    case permissionDenied(permission: String)
    case timeout(operation: String, seconds: Double)
    case cancelled(reason: String)
    case ipcError(reason: String)

    public var errorCode: String {
        switch self {
        case .staleTopology: return "STALE_TOPOLOGY"
        case .staleCapture: return "STALE_CAPTURE"
        case .outOfBounds: return "OUT_OF_BOUNDS"
        case .velocityExceeded: return "VELOCITY_EXCEEDED"
        case .targetUnreachable: return "TARGET_UNREACHABLE"
        case .permissionDenied: return "PERMISSION_DENIED"
        case .timeout: return "TIMEOUT"
        case .cancelled: return "CANCELLED"
        case .ipcError: return "IPC_ERROR"
        }
    }

    public var errorMessage: String {
        switch self {
        case .staleTopology(let current, let received):
            return "Display topology version mismatch. Current: \(current), received: \(received)."
        case .staleCapture(let current, let received):
            return "Capture precondition failed. Current capture: \(current), received: \(received)."
        case .outOfBounds(let x, let y, let limitX, let limitY):
            return "Coordinates (\(x), \(y)) exceed valid bounds [0...\(limitX), 0...\(limitY)]."
        case .velocityExceeded(let speed, let maxSpeed):
            return "Mouse movement velocity \(speed) exceeds safety threshold \(maxSpeed)."
        case .targetUnreachable(let reason):
            return "Target element or coordinate unreachable: \(reason)."
        case .permissionDenied(let permission):
            return "Required macOS TCC permission missing: \(permission)."
        case .timeout(let op, let sec):
            return "Operation '\(op)' timed out after \(sec) seconds."
        case .cancelled(let reason):
            return "Operation cancelled: \(reason)."
        case .ipcError(let reason):
            return "IPC protocol error: \(reason)."
        }
    }
}
