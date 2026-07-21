import Foundation

public final class SocketListener: @unchecked Sendable {
    public let socketPath: String
    private let server: HostServer
    private var serverFd: Int32 = -1
    private var isRunning: Bool = false
    private let lock = NSLock()
    private let perFrameTimeoutSec: Double

    public init(socketPath: String = "/tmp/agy-computer-use/host.sock", server: HostServer, perFrameTimeoutSec: Double = 5.0) {
        self.socketPath = socketPath
        self.server = server
        self.perFrameTimeoutSec = perFrameTimeoutSec
    }

    public static func prepareDirectory(at path: String) throws {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: path) {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDir) {
                if !isDir.boolValue {
                    try fileManager.removeItem(atPath: path)
                    try createOwnerOnlyDir(at: path)
                } else {
                    try setOwnerOnlyPermissions(at: path)
                }
            }
        } else {
            try createOwnerOnlyDir(at: path)
        }
    }

    private static func createOwnerOnlyDir(at path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        try setOwnerOnlyPermissions(at: path)
    }

    private static func setOwnerOnlyPermissions(at path: String) throws {
        let res = chmod(path, S_IRWXU) // 0700: Owner rwx only
        guard res == 0 else {
            throw ComputerUseError.ipcError(reason: "Failed to set 0700 permissions on directory: \(path)")
        }

        var statBuf = stat()
        guard lstat(path, &statBuf) == 0 else {
            throw ComputerUseError.ipcError(reason: "Failed to lstat directory: \(path)")
        }

        guard (statBuf.st_mode & S_IFMT) == S_IFDIR else {
            throw ComputerUseError.ipcError(reason: "Path is not a directory: \(path)")
        }

        guard (statBuf.st_mode & 0o777) == 0o700 else {
            throw ComputerUseError.ipcError(reason: "Insecure directory permissions (\(String(format: "%o", statBuf.st_mode & 0o777))) for path: \(path)")
        }
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }

        let parentDir = (socketPath as NSString).deletingLastPathComponent
        try SocketListener.prepareDirectory(at: parentDir)

        if FileManager.default.fileExists(atPath: socketPath) {
            _ = unlink(socketPath)
        }

        serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            throw ComputerUseError.ipcError(reason: "Failed to create UNIX domain socket descriptor")
        }

        var on: Int32 = 1
        _ = setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(serverFd)
            serverFd = -1
            throw ComputerUseError.ipcError(reason: "Socket path exceeds sun_path maximum size (\(socketPath))")
        }

        let addrLen = MemoryLayout<sa_family_t>.size + pathBytes.count
        addr.sun_len = UInt8(addrLen)
        addr.sun_family = sa_family_t(AF_UNIX)

        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            ptr.initializeMemory(as: CChar.self, repeating: 0)
            _ = pathBytes.withUnsafeBufferPointer { bPtr in
                memcpy(ptr.baseAddress!, bPtr.baseAddress!, bPtr.count)
            }
        }

        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(serverFd, saPtr, socklen_t(addrLen))
            }
        }

        guard bindRes == 0 else {
            let err = errno
            close(serverFd)
            serverFd = -1
            throw ComputerUseError.ipcError(reason: "Failed to bind socket at \(socketPath): errno \(err)")
        }

        let listenRes = listen(serverFd, 5)
        guard listenRes == 0 else {
            let err = errno
            close(serverFd)
            serverFd = -1
            throw ComputerUseError.ipcError(reason: "Failed to listen on socket at \(socketPath): errno \(err)")
        }

        isRunning = true
    }

    private func getSocketState() -> (fd: Int32, active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (serverFd, isRunning)
    }

    public func acceptAndHandleOneConnection() async throws -> Bool {
        let (fd, active) = getSocketState()

        guard active, fd >= 0 else { return false }

        var clientAddr = sockaddr_un()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                accept(fd, saPtr, &clientAddrLen)
            }
        }

        if clientFd < 0 {
            if errno == EINTR { return true }
            return false
        }

        defer {
            close(clientFd)
        }

        var nosigpipe: Int32 = 1
        let optRes = setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        guard optRes == 0 else {
            return true
        }

        // Monotonic deadline calculations using ContinuousClock
        let clock = ContinuousClock()
        let headerDeadline = clock.now + .seconds(2)
        let bodyDeadline = clock.now + .seconds(3)
        let writeDeadline = clock.now + .seconds(2)

        do {
            var headerBuffer = Data()
            try readExactly(count: 4, from: clientFd, into: &headerBuffer, clock: clock, deadline: headerDeadline, operation: "socket_read_header")

            let payloadLength = Int(headerBuffer[0]) << 24 | Int(headerBuffer[1]) << 16 | Int(headerBuffer[2]) << 8 | Int(headerBuffer[3])
            guard payloadLength > 0, payloadLength <= LengthPrefixedFramer.maxPayloadSize else {
                let errResp = IPCResponse(
                    id: "unknown",
                    success: false,
                    error: IPCErrorPayload(code: "IPC_ERROR", message: "Oversized or zero payload header length: \(payloadLength)")
                )
                try writeResponse(errResp, to: clientFd, clock: clock, deadline: writeDeadline)
                return true
            }

            var payloadBuffer = Data()
            try readExactly(count: payloadLength, from: clientFd, into: &payloadBuffer, clock: clock, deadline: bodyDeadline, operation: "socket_read_body")

            let request = try JSONDecoder().decode(IPCRequest.self, from: payloadBuffer)
            let response = await server.handleRequest(request)

            try writeResponse(response, to: clientFd, clock: clock, deadline: writeDeadline)
        } catch let err as ComputerUseError {
            let errResp = IPCResponse(
                id: "err-\(UUID().uuidString)",
                success: false,
                error: IPCErrorPayload(code: err.errorCode, message: err.errorMessage)
            )
            _ = try? writeResponse(errResp, to: clientFd, clock: clock, deadline: writeDeadline)
        } catch {
            let errResp = IPCResponse(
                id: "err-\(UUID().uuidString)",
                success: false,
                error: IPCErrorPayload(code: "IPC_ERROR", message: error.localizedDescription)
            )
            _ = try? writeResponse(errResp, to: clientFd, clock: clock, deadline: writeDeadline)
        }

        return true
    }

    private func readExactly(count: Int, from fd: Int32, into data: inout Data, clock: ContinuousClock, deadline: ContinuousClock.Instant, operation: String) throws {
        var tempBuf = [UInt8](repeating: 0, count: count)
        var totalRead = 0

        while totalRead < count {
            let now = clock.now
            guard now < deadline else {
                throw ComputerUseError.timeout(operation: operation, seconds: perFrameTimeoutSec)
            }

            let duration = deadline - now
            let remainingSec = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            guard remainingSec > 0 else {
                throw ComputerUseError.timeout(operation: operation, seconds: perFrameTimeoutSec)
            }

            var tv = timeval(tv_sec: Int(remainingSec), tv_usec: __darwin_suseconds_t((remainingSec - floor(remainingSec)) * 1_000_000))
            let optRes = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            guard optRes == 0 else {
                throw ComputerUseError.ipcError(reason: "Failed to set SO_RCVTIMEO socket option")
            }

            let bytesRead = read(fd, &tempBuf[totalRead], count - totalRead)
            if bytesRead > 0 {
                totalRead += bytesRead
            } else if bytesRead == 0 {
                throw ComputerUseError.ipcError(reason: "Socket closed prematurely by peer during read")
            } else {
                let err = errno
                if err == EINTR { continue }
                if err == EAGAIN || err == EWOULDBLOCK {
                    throw ComputerUseError.timeout(operation: operation, seconds: perFrameTimeoutSec)
                }
                throw ComputerUseError.ipcError(reason: "Socket read failed with errno \(err)")
            }
        }

        data.append(tempBuf, count: totalRead)
    }

    private func writeResponse(_ response: IPCResponse, to fd: Int32, clock: ContinuousClock, deadline: ContinuousClock.Instant) throws {
        let respData = try JSONEncoder().encode(response)
        let framedResp = try LengthPrefixedFramer.encode(payload: respData)

        try writeAll(data: framedResp, to: fd, clock: clock, deadline: deadline)
    }

    private func writeAll(data: Data, to fd: Int32, clock: ContinuousClock, deadline: ContinuousClock.Instant) throws {
        var totalWritten = 0
        let totalCount = data.count

        try data.withUnsafeBytes { rawBuf in
            guard let basePtr = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

            while totalWritten < totalCount {
                let now = clock.now
                guard now < deadline else {
                    throw ComputerUseError.timeout(operation: "socket_write_response", seconds: perFrameTimeoutSec)
                }

                let duration = deadline - now
                let remainingSec = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                guard remainingSec > 0 else {
                    throw ComputerUseError.timeout(operation: "socket_write_response", seconds: perFrameTimeoutSec)
                }

                var tv = timeval(tv_sec: Int(remainingSec), tv_usec: __darwin_suseconds_t((remainingSec - floor(remainingSec)) * 1_000_000))
                let optRes = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                guard optRes == 0 else {
                    throw ComputerUseError.ipcError(reason: "Failed to set SO_SNDTIMEO socket option")
                }

                let bytesWritten = write(fd, basePtr.advanced(by: totalWritten), totalCount - totalWritten)
                if bytesWritten > 0 {
                    totalWritten += bytesWritten
                } else if bytesWritten < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    if err == EAGAIN || err == EWOULDBLOCK {
                        throw ComputerUseError.timeout(operation: "socket_write_response", seconds: perFrameTimeoutSec)
                    }
                    throw ComputerUseError.ipcError(reason: "Socket write failed with errno \(err)")
                }
            }
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning else { return }
        isRunning = false

        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }

        if FileManager.default.fileExists(atPath: socketPath) {
            _ = unlink(socketPath)
        }
    }
}
