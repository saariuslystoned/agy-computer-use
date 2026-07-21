import Foundation

public final class SocketListener: @unchecked Sendable {
    public static var defaultSocketPath: String {
        return "/private/tmp/agy-computer-use-\(getuid())/host.sock"
    }

    public let socketPath: String
    private let server: HostServer
    private var serverFd: Int32 = -1
    private var lockFd: Int32 = -1
    private var isRunning: Bool = false
    private var boundInode: ino_t = 0
    private let lock = NSLock()
    private let perFrameTimeoutSec: Double

    public init(socketPath: String? = nil, server: HostServer, perFrameTimeoutSec: Double = 5.0) {
        let path = socketPath ?? SocketListener.defaultSocketPath
        // Resolve /tmp symlink prefix to canonical /private/tmp if needed
        if path.hasPrefix("/tmp/") {
            self.socketPath = "/private" + path
        } else {
            self.socketPath = path
        }
        self.server = server
        self.perFrameTimeoutSec = perFrameTimeoutSec
    }

    public static func prepareDirectory(at path: String) throws {
        var canonicalPath = path
        if canonicalPath.hasPrefix("/tmp/") {
            canonicalPath = "/private" + canonicalPath
        }
        
        var isDir: ObjCBool = false
        let targetDir: String
        if FileManager.default.fileExists(atPath: canonicalPath, isDirectory: &isDir) {
            if isDir.boolValue {
                targetDir = canonicalPath
            } else {
                targetDir = (canonicalPath as NSString).deletingLastPathComponent
            }
        } else {
            if (canonicalPath as NSString).pathExtension.isEmpty {
                targetDir = canonicalPath
            } else {
                targetDir = (canonicalPath as NSString).deletingLastPathComponent
            }
        }

        if targetDir == "/private/tmp" || targetDir == "/tmp" {
            return
        }

        var statBuf = stat()
        if lstat(targetDir, &statBuf) == 0 {
            guard (statBuf.st_mode & S_IFMT) == S_IFDIR else {
                throw ComputerUseError.ipcError(reason: "Refusing to remove pre-existing non-directory file at runtime path: \(targetDir)")
            }
            guard statBuf.st_uid == getuid() else {
                throw ComputerUseError.ipcError(reason: "Directory owner UID \(statBuf.st_uid) does not match current user UID \(getuid())")
            }
            guard (statBuf.st_mode & 0o777) == 0o700 else {
                throw ComputerUseError.ipcError(reason: "Insecure directory permissions for path: \(targetDir)")
            }
        } else {
            let res = mkdir(targetDir, 0o700)
            guard res == 0 || errno == EEXIST else {
                throw ComputerUseError.ipcError(reason: "Failed to create 0700 runtime directory: \(targetDir)")
            }
        }
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }

        let parentDir = (socketPath as NSString).deletingLastPathComponent
        try SocketListener.prepareDirectory(at: socketPath)

        // Hold owner-only lifecycle lock file via flock LOCK_EX|LOCK_NB
        let lockPath = (parentDir as NSString).appendingPathComponent("host.lock")
        lockFd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFd >= 0 else {
            throw ComputerUseError.ipcError(reason: "Failed to open or create host.lock file at \(lockPath)")
        }

        let flockRes = flock(lockFd, LOCK_EX | LOCK_NB)
        guard flockRes == 0 else {
            close(lockFd)
            lockFd = -1
            throw ComputerUseError.ipcError(reason: "Refusing to start: another active host instance holds flock on \(lockPath)")
        }

        var statBuf = stat()
        if lstat(socketPath, &statBuf) == 0 {
            guard statBuf.st_uid == getuid() else {
                throw ComputerUseError.ipcError(reason: "Refusing to unlink socket owned by foreign UID \(statBuf.st_uid)")
            }
            guard (statBuf.st_mode & S_IFMT) == S_IFSOCK else {
                throw ComputerUseError.ipcError(reason: "Refusing to unlink non-socket file at \(socketPath)")
            }

            // Monotonic nonblocking connect & poll probe to refuse active listener
            let probeFd = socket(AF_UNIX, SOCK_STREAM, 0)
            if probeFd >= 0 {
                defer { close(probeFd) }
                let flags = fcntl(probeFd, F_GETFL, 0)
                _ = fcntl(probeFd, F_SETFL, flags | O_NONBLOCK)

                var probeAddr = sockaddr_un()
                let pathBytes = socketPath.utf8CString
                let addrLen = MemoryLayout<sa_family_t>.size + pathBytes.count
                probeAddr.sun_len = UInt8(addrLen)
                probeAddr.sun_family = sa_family_t(AF_UNIX)
                withUnsafeMutableBytes(of: &probeAddr.sun_path) { ptr in
                    ptr.initializeMemory(as: CChar.self, repeating: 0)
                    _ = pathBytes.withUnsafeBufferPointer { bPtr in memcpy(ptr.baseAddress!, bPtr.baseAddress!, bPtr.count) }
                }

                let connRes = withUnsafePointer(to: &probeAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        connect(probeFd, saPtr, socklen_t(addrLen))
                    }
                }

                if connRes == 0 {
                    throw ComputerUseError.ipcError(reason: "Refusing to unlink active socket with live listener at \(socketPath)")
                } else if errno == EINPROGRESS {
                    var pfd = pollfd(fd: probeFd, events: Int16(POLLOUT), revents: 0)
                    let pollRes = poll(&pfd, 1, 100) // 100ms deadline
                    if pollRes > 0 {
                        var err: Int32 = 0
                        var errLen = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(probeFd, SOL_SOCKET, SO_ERROR, &err, &errLen)
                        if err == 0 {
                            throw ComputerUseError.ipcError(reason: "Refusing to unlink active socket with live listener at \(socketPath)")
                        } else if err != ECONNREFUSED {
                            throw ComputerUseError.ipcError(reason: "Socket connect returned error \(err), failing closed")
                        }
                    } else {
                        throw ComputerUseError.ipcError(reason: "Socket connect probe timed out, failing closed")
                    }
                } else if errno != ECONNREFUSED {
                    throw ComputerUseError.ipcError(reason: "Socket probe failed with errno \(errno), failing closed")
                }
            }

            // Re-read stat right before unlinking
            var preUnlinkStat = stat()
            guard lstat(socketPath, &preUnlinkStat) == 0, preUnlinkStat.st_uid == getuid(), (preUnlinkStat.st_mode & S_IFMT) == S_IFSOCK else {
                throw ComputerUseError.ipcError(reason: "Socket state changed before unlink, failing closed")
            }
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

        var boundStat = stat()
        guard lstat(socketPath, &boundStat) == 0, boundStat.st_uid == getuid(), (boundStat.st_mode & S_IFMT) == S_IFSOCK else {
            close(serverFd)
            serverFd = -1
            throw ComputerUseError.ipcError(reason: "Bound socket state revalidation failed")
        }
        self.boundInode = boundStat.st_ino

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

        var peerUid: uid_t = 0
        var peerGid: gid_t = 0
        let peerRes = getpeereid(clientFd, &peerUid, &peerGid)
        guard peerRes == 0, peerUid == getuid() else {
            return true
        }

        var nosigpipe: Int32 = 1
        let optRes = setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        guard optRes == 0 else {
            return true
        }

        let clock = ContinuousClock()

        // 1. Header read phase: 2s deadline
        let headerDeadline = clock.now + .seconds(2)
        do {
            var headerBuffer = Data()
            try readExactly(count: 4, from: clientFd, into: &headerBuffer, clock: clock, deadline: headerDeadline, operation: "socket_read_header")

            let payloadLength = Int(headerBuffer[0]) << 24 | Int(headerBuffer[1]) << 16 | Int(headerBuffer[2]) << 8 | Int(headerBuffer[3])
            guard payloadLength > 0, payloadLength <= LengthPrefixedFramer.maxPayloadSize else {
                let writeDeadline = clock.now + .seconds(2)
                let errResp = IPCResponse(
                    id: "unknown",
                    success: false,
                    error: IPCErrorPayload(code: "IPC_ERROR", message: "Oversized or zero payload header length: \(payloadLength)")
                )
                try writeResponse(errResp, to: clientFd, clock: clock, deadline: writeDeadline)
                return true
            }

            // 2. Body read phase: 3s deadline starting at body phase start
            let bodyDeadline = clock.now + .seconds(3)
            var payloadBuffer = Data()
            try readExactly(count: payloadLength, from: clientFd, into: &payloadBuffer, clock: clock, deadline: bodyDeadline, operation: "socket_read_body")

            let request = try JSONDecoder().decode(IPCRequest.self, from: payloadBuffer)

            // 3. Execution phase: HostServer handles request with its own deadline
            let response = await server.handleRequest(request)

            // 4. Response write phase: 2s deadline starting at write phase start
            let writeDeadline = clock.now + .seconds(2)
            try writeResponse(response, to: clientFd, clock: clock, deadline: writeDeadline)
        } catch let err as ComputerUseError {
            let writeDeadline = clock.now + .seconds(2)
            let errResp = IPCResponse(
                id: "err-\(UUID().uuidString)",
                success: false,
                error: IPCErrorPayload(code: err.errorCode, message: err.errorMessage)
            )
            _ = try? writeResponse(errResp, to: clientFd, clock: clock, deadline: writeDeadline)
        } catch {
            let writeDeadline = clock.now + .seconds(2)
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

            let tvSec = Int(remainingSec)
            var tvUsec = __darwin_suseconds_t(ceil((remainingSec - floor(remainingSec)) * 1_000_000))
            if remainingSec > 0 && tvSec == 0 && tvUsec == 0 {
                tvUsec = 1
            }
            if tvUsec >= 1_000_000 {
                tvUsec = 999_999
            }
            var tv = timeval(tv_sec: tvSec, tv_usec: tvUsec)
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

                let tvSec = Int(remainingSec)
                var tvUsec = __darwin_suseconds_t(ceil((remainingSec - floor(remainingSec)) * 1_000_000))
                if remainingSec > 0 && tvSec == 0 && tvUsec == 0 {
                    tvUsec = 1
                }
                if tvUsec >= 1_000_000 {
                    tvUsec = 999_999
                }
                var tv = timeval(tv_sec: tvSec, tv_usec: tvUsec)
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

        var statBuf = stat()
        if lstat(socketPath, &statBuf) == 0 {
            if statBuf.st_ino == self.boundInode && statBuf.st_uid == getuid() && (statBuf.st_mode & S_IFMT) == S_IFSOCK {
                _ = unlink(socketPath)
            }
        }

        if lockFd >= 0 {
            _ = flock(lockFd, LOCK_UN)
            close(lockFd)
            lockFd = -1
        }
    }
}
