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
    private var boundDev: dev_t = 0
    private var boundInode: ino_t = 0
    private let lock = NSLock()
    private let perFrameTimeoutSec: Double

    private let syscalls: POSIXSyscallProviding
    private let clock: HostClock

    public init(
        socketPath: String? = nil,
        server: HostServer,
        perFrameTimeoutSec: Double = 5.0,
        syscalls: POSIXSyscallProviding = DarwinPOSIXSyscalls.shared,
        clock: HostClock = DefaultHostClock()
    ) {
        let path = socketPath ?? SocketListener.defaultSocketPath
        if path.hasPrefix("/tmp/") {
            self.socketPath = "/private" + path
        } else {
            self.socketPath = path
        }
        self.server = server
        self.perFrameTimeoutSec = perFrameTimeoutSec
        self.syscalls = syscalls
        self.clock = clock
    }

    public static func prepareDirectory(at path: String, syscalls: POSIXSyscallProviding = DarwinPOSIXSyscalls.shared) throws {
        var canonicalPath = path
        if canonicalPath.hasPrefix("/tmp/") {
            canonicalPath = "/private" + canonicalPath
        }

        var isDir: ObjCBool = false
        let targetDir: String
        if FileManager.default.fileExists(atPath: canonicalPath, isDirectory: &isDir) {
            targetDir = isDir.boolValue ? canonicalPath : (canonicalPath as NSString).deletingLastPathComponent
        } else {
            targetDir = (canonicalPath as NSString).pathExtension.isEmpty ? canonicalPath : (canonicalPath as NSString).deletingLastPathComponent
        }

        if targetDir == "/private/tmp" || targetDir == "/tmp" {
            return
        }

        let res = syscalls.mkdir(targetDir, 0o700)
        if res == 0 || syscalls.lastErrno == EEXIST {
            let dirFd = syscalls.open(targetDir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0)
            guard dirFd >= 0 else {
                let err = syscalls.lastErrno
                if err == ELOOP {
                    throw ComputerUseError.ipcError(reason: "Refusing to follow symlink at runtime directory path: \(targetDir)")
                } else if err == ENOTDIR {
                    throw ComputerUseError.ipcError(reason: "Refusing to use pre-existing non-directory file at runtime path: \(targetDir)")
                }
                throw ComputerUseError.ipcError(reason: "Failed to open runtime directory descriptor for path: \(targetDir), errno: \(err)")
            }
            defer { _ = syscalls.close(dirFd) }

            var statBuf = stat()
            guard syscalls.fstat(dirFd, &statBuf) == 0 else {
                throw ComputerUseError.ipcError(reason: "Failed to fstat open descriptor for runtime directory: \(targetDir)")
            }
            guard (statBuf.st_mode & S_IFMT) == S_IFDIR else {
                throw ComputerUseError.ipcError(reason: "Refusing to use non-directory descriptor at runtime path: \(targetDir)")
            }
            guard statBuf.st_uid == syscalls.getuid() else {
                throw ComputerUseError.ipcError(reason: "Directory owner UID \(statBuf.st_uid) does not match current user UID \(syscalls.getuid())")
            }
            guard (statBuf.st_mode & 0o777) == 0o700 else {
                throw ComputerUseError.ipcError(reason: "Insecure directory permissions for path: \(targetDir) (mode 0o\(String(statBuf.st_mode & 0o777, radix: 8)), expected 0o700)")
            }
        } else {
            let err = syscalls.lastErrno
            throw ComputerUseError.ipcError(reason: "Failed to create 0700 runtime directory: \(targetDir), errno \(err)")
        }
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }

        var boundPathForRollback: String? = nil
        var boundDevForRollback: dev_t = 0
        var boundInodeForRollback: ino_t = 0

        do {
            let parentDir = (socketPath as NSString).deletingLastPathComponent
            try SocketListener.prepareDirectory(at: socketPath)

            let lockPath = (parentDir as NSString).appendingPathComponent("host.lock")
            lockFd = syscalls.open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lockFd >= 0 else {
                throw ComputerUseError.ipcError(reason: "Failed to open or create host.lock file at \(lockPath)")
            }

            let flockRes = syscalls.flock(lockFd, LOCK_EX | LOCK_NB)
            guard flockRes == 0 else {
                _ = syscalls.close(lockFd)
                lockFd = -1
                throw ComputerUseError.ipcError(reason: "Refusing to start: another active host instance holds flock on \(lockPath)")
            }

            var statBuf = stat()
            if syscalls.lstat(socketPath, &statBuf) == 0 {
                guard statBuf.st_uid == syscalls.getuid() else {
                    throw ComputerUseError.ipcError(reason: "Refusing to unlink socket owned by foreign UID \(statBuf.st_uid)")
                }
                guard (statBuf.st_mode & S_IFMT) == S_IFSOCK else {
                    throw ComputerUseError.ipcError(reason: "Refusing to unlink non-socket file at \(socketPath)")
                }

                let probeFd = syscalls.socket(AF_UNIX, SOCK_STREAM, 0)
                guard probeFd >= 0 else {
                    throw ComputerUseError.ipcError(reason: "Socket probe descriptor creation failed with errno \(syscalls.lastErrno), failing closed")
                }
                defer { _ = syscalls.close(probeFd) }

                let flags = syscalls.fcntl(probeFd, F_GETFL, 0)
                guard flags >= 0 else {
                    throw ComputerUseError.ipcError(reason: "Socket probe fcntl F_GETFL failed with errno \(syscalls.lastErrno), failing closed")
                }

                let setFlRes = syscalls.fcntl(probeFd, F_SETFL, flags | O_NONBLOCK)
                guard setFlRes >= 0 else {
                    throw ComputerUseError.ipcError(reason: "Socket probe fcntl F_SETFL failed with errno \(syscalls.lastErrno), failing closed")
                }

                var probeAddr = sockaddr_un()
                let pathBytes = socketPath.utf8CString
                guard pathBytes.count <= MemoryLayout.size(ofValue: probeAddr.sun_path) else {
                    throw ComputerUseError.ipcError(reason: "Socket path length exceeds sockaddr_un sun_path limit")
                }
                let addrLen = MemoryLayout<sa_family_t>.size + pathBytes.count
                probeAddr.sun_len = UInt8(addrLen)
                probeAddr.sun_family = sa_family_t(AF_UNIX)
                withUnsafeMutableBytes(of: &probeAddr.sun_path) { ptr in
                    ptr.initializeMemory(as: CChar.self, repeating: 0)
                    _ = pathBytes.withUnsafeBufferPointer { bPtr in memcpy(ptr.baseAddress!, bPtr.baseAddress!, bPtr.count) }
                }

                let connRes = withUnsafePointer(to: &probeAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        syscalls.connect(probeFd, saPtr, socklen_t(addrLen))
                    }
                }

                if connRes == 0 {
                    throw ComputerUseError.ipcError(reason: "Refusing to unlink active socket with live listener at \(socketPath)")
                } else if syscalls.lastErrno == EINPROGRESS {
                    var pfd = pollfd(fd: probeFd, events: Int16(POLLOUT), revents: 0)
                    let pollRes = syscalls.poll(&pfd, 1, 100)
                    if pollRes > 0 {
                        var err: Int32 = 0
                        var errLen = socklen_t(MemoryLayout<Int32>.size)
                        let optRes = syscalls.getsockopt(probeFd, SOL_SOCKET, SO_ERROR, &err, &errLen)
                        guard optRes == 0 else {
                            throw ComputerUseError.ipcError(reason: "Socket probe getsockopt SO_ERROR failed with errno \(syscalls.lastErrno), failing closed")
                        }
                        if err == 0 {
                            throw ComputerUseError.ipcError(reason: "Refusing to unlink active socket with live listener at \(socketPath)")
                        } else if err != ECONNREFUSED {
                            throw ComputerUseError.ipcError(reason: "Socket connect returned error \(err), failing closed")
                        }
                    } else if pollRes == 0 {
                        throw ComputerUseError.ipcError(reason: "Socket connect probe timed out, failing closed")
                    } else {
                        throw ComputerUseError.ipcError(reason: "Socket poll failed with errno \(syscalls.lastErrno), failing closed")
                    }
                } else if syscalls.lastErrno != ECONNREFUSED {
                    throw ComputerUseError.ipcError(reason: "Socket probe failed with errno \(syscalls.lastErrno), failing closed")
                }

                var preUnlinkStat = stat()
                guard syscalls.lstat(socketPath, &preUnlinkStat) == 0,
                      preUnlinkStat.st_dev == statBuf.st_dev,
                      preUnlinkStat.st_ino == statBuf.st_ino,
                      preUnlinkStat.st_uid == syscalls.getuid(),
                      (preUnlinkStat.st_mode & S_IFMT) == S_IFSOCK else {
                    throw ComputerUseError.ipcError(reason: "Socket state changed before unlink, failing closed")
                }
                _ = syscalls.unlink(socketPath)
            }

            serverFd = syscalls.socket(AF_UNIX, SOCK_STREAM, 0)
            guard serverFd >= 0 else {
                throw ComputerUseError.ipcError(reason: "Failed to create UNIX domain socket descriptor")
            }

            var on: Int32 = 1
            _ = syscalls.setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_un()
            let pathBytes = socketPath.utf8CString
            guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
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
                    syscalls.bind(serverFd, saPtr, socklen_t(addrLen))
                }
            }

            guard bindRes == 0 else {
                let err = syscalls.lastErrno
                throw ComputerUseError.ipcError(reason: "Failed to bind socket at \(socketPath): errno \(err)")
            }
            boundPathForRollback = socketPath

            var boundStat = stat()
            guard syscalls.lstat(socketPath, &boundStat) == 0, boundStat.st_uid == syscalls.getuid(), (boundStat.st_mode & S_IFMT) == S_IFSOCK else {
                throw ComputerUseError.ipcError(reason: "Bound socket state revalidation failed")
            }
            self.boundDev = boundStat.st_dev
            self.boundInode = boundStat.st_ino
            boundDevForRollback = boundStat.st_dev
            boundInodeForRollback = boundStat.st_ino

            let listenRes = syscalls.listen(serverFd, 5)
            guard listenRes == 0 else {
                let err = syscalls.lastErrno
                throw ComputerUseError.ipcError(reason: "Failed to listen on socket at \(socketPath): errno \(err)")
            }

            isRunning = true
        } catch {
            if serverFd >= 0 {
                _ = syscalls.close(serverFd)
                serverFd = -1
            }
            if let boundPath = boundPathForRollback, boundInodeForRollback > 0 {
                var statBuf = stat()
                if syscalls.lstat(boundPath, &statBuf) == 0,
                   statBuf.st_dev == boundDevForRollback,
                   statBuf.st_ino == boundInodeForRollback,
                   statBuf.st_uid == syscalls.getuid(),
                   (statBuf.st_mode & S_IFMT) == S_IFSOCK {
                    _ = syscalls.unlink(boundPath)
                }
            }
            if lockFd >= 0 {
                _ = syscalls.flock(lockFd, LOCK_UN)
                _ = syscalls.close(lockFd)
                lockFd = -1
            }
            self.boundDev = 0
            self.boundInode = 0
            self.isRunning = false
            throw error
        }
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

        var clientFd: Int32 = -1
        while true {
            clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    syscalls.accept(fd, saPtr, &clientAddrLen)
                }
            }
            if clientFd < 0 {
                if syscalls.lastErrno == EINTR {
                    continue
                }
                return false
            }
            break
        }

        defer {
            _ = syscalls.close(clientFd)
        }

        var peerUid: uid_t = 0
        var peerGid: gid_t = 0
        let peerRes = syscalls.getpeereid(clientFd, &peerUid, &peerGid)
        guard peerRes == 0, peerUid == syscalls.getuid() else {
            return true
        }

        var nosigpipe: Int32 = 1
        let optRes = syscalls.setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        guard optRes == 0 else {
            return true
        }

        let clock = self.clock
        var writeAttempted = false

        // 1. Header read phase: 2s deadline
        let headerDeadline = clock.now + .seconds(2)
        do {
            var headerBuffer = Data()
            try readExactly(count: 4, from: clientFd, into: &headerBuffer, clock: clock, deadline: headerDeadline, operation: "socket_read_header", phaseBudgetSec: 2.0)

            let payloadLength = Int(headerBuffer[0]) << 24 | Int(headerBuffer[1]) << 16 | Int(headerBuffer[2]) << 8 | Int(headerBuffer[3])
            guard payloadLength > 0, payloadLength <= LengthPrefixedFramer.maxPayloadSize else {
                writeAttempted = true
                let writeDeadline = clock.now + .seconds(self.perFrameTimeoutSec)
                let errResp = IPCResponse(
                    id: "unknown",
                    success: false,
                    error: IPCErrorPayload(code: "IPC_ERROR", message: "Oversized or zero payload header length: \(payloadLength)")
                )
                try await writeResponse(errResp, to: clientFd, clock: clock, deadline: writeDeadline, phaseBudgetSec: self.perFrameTimeoutSec)
                return true
            }

            // 2. Body read phase: 3s deadline starting at body phase start
            let bodyDeadline = clock.now + .seconds(3)
            var payloadBuffer = Data()
            try readExactly(count: payloadLength, from: clientFd, into: &payloadBuffer, clock: clock, deadline: bodyDeadline, operation: "socket_read_body", phaseBudgetSec: 3.0)

            let request = try JSONDecoder().decode(IPCRequest.self, from: payloadBuffer)

            // 3. Execution phase: HostServer handles request with its own deadline
            let response = await server.handleRequest(request)

            // 4. Response write phase: perFrameTimeoutSec deadline starting at write phase start
            writeAttempted = true
            let writeDeadline = clock.now + .seconds(self.perFrameTimeoutSec)
            try await writeResponse(response, to: clientFd, clock: clock, deadline: writeDeadline, phaseBudgetSec: self.perFrameTimeoutSec)
        } catch let err as ComputerUseError {
            if !writeAttempted {
                let writeDeadline = clock.now + .seconds(self.perFrameTimeoutSec)
                let errResp = IPCResponse(
                    id: "err-\(UUID().uuidString)",
                    success: false,
                    error: IPCErrorPayload(code: err.errorCode, message: err.errorMessage)
                )
                _ = try? await writeResponse(errResp, to: clientFd, clock: clock, deadline: writeDeadline, phaseBudgetSec: self.perFrameTimeoutSec)
            }
        } catch {
            if !writeAttempted {
                let writeDeadline = clock.now + .seconds(self.perFrameTimeoutSec)
                let errResp = IPCResponse(
                    id: "err-\(UUID().uuidString)",
                    success: false,
                    error: IPCErrorPayload(code: "IPC_ERROR", message: error.localizedDescription)
                )
                _ = try? await writeResponse(errResp, to: clientFd, clock: clock, deadline: writeDeadline, phaseBudgetSec: self.perFrameTimeoutSec)
            }
        }

        return true
    }

    private func readExactly(count: Int, from fd: Int32, into data: inout Data, clock: HostClock, deadline: ContinuousClock.Instant, operation: String, phaseBudgetSec: Double) throws {
        var tempBuf = [UInt8](repeating: 0, count: count)
        var totalRead = 0

        while totalRead < count {
            let now = clock.now
            guard now < deadline else {
                throw ComputerUseError.timeout(operation: operation, seconds: phaseBudgetSec)
            }

            let duration = deadline - now
            let remainingSec = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            guard remainingSec > 0 else {
                throw ComputerUseError.timeout(operation: operation, seconds: phaseBudgetSec)
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
            let optRes = syscalls.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            guard optRes == 0 else {
                throw ComputerUseError.ipcError(reason: "Failed to set SO_RCVTIMEO socket option")
            }

            let bytesRead = syscalls.read(fd, &tempBuf[totalRead], count - totalRead)
            if bytesRead > 0 {
                totalRead += bytesRead
                if clock.now >= deadline {
                    throw ComputerUseError.timeout(operation: operation, seconds: phaseBudgetSec)
                }
            } else if bytesRead == 0 {
                throw ComputerUseError.ipcError(reason: "Socket closed prematurely by peer during read")
            } else {
                let err = syscalls.lastErrno
                if err == EINTR { continue }
                if err == EAGAIN || err == EWOULDBLOCK {
                    throw ComputerUseError.timeout(operation: operation, seconds: phaseBudgetSec)
                }
                throw ComputerUseError.ipcError(reason: "Socket read failed with errno \(err)")
            }
        }

        data.append(tempBuf, count: totalRead)
    }

    private func writeResponse(_ response: IPCResponse, to fd: Int32, clock: HostClock, deadline: ContinuousClock.Instant, phaseBudgetSec: Double) async throws {
        let respData = try JSONEncoder().encode(response)
        let framedResp = try LengthPrefixedFramer.encode(payload: respData)

        try await writeAll(data: framedResp, to: fd, clock: clock, deadline: deadline, phaseBudgetSec: phaseBudgetSec)
    }

    public var socketWriter: (@Sendable (Int32, UnsafeRawPointer, Int) throws -> Int)? = nil

    private func writeAll(data: Data, to fd: Int32, clock: HostClock, deadline: ContinuousClock.Instant, phaseBudgetSec: Double) async throws {
        var totalWritten = 0
        let totalCount = data.count
        let bytesArray = [UInt8](data)

        while totalWritten < totalCount {
            let now = clock.now
            guard now < deadline else {
                throw ComputerUseError.timeout(operation: "socket_write_response", seconds: phaseBudgetSec)
            }

            let duration = deadline - now
            let remainingSec = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            guard remainingSec > 0 else {
                throw ComputerUseError.timeout(operation: "socket_write_response", seconds: phaseBudgetSec)
            }

            let tvSec = Int(remainingSec)
            var tvUsec = __darwin_suseconds_t(ceil((remainingSec - floor(remainingSec)) * 1_000_000))
            if remainingSec > 0 && tvSec == 0 && tvUsec == 0 {
                tvUsec = 1
            }
            if tvUsec >= 1_000_000 {
                tvUsec = 999_999
            }
            var nosigpipe: Int32 = 1
            let sigOptRes = syscalls.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
            guard sigOptRes == 0 else {
                throw ComputerUseError.ipcError(reason: "Failed to enforce SO_NOSIGPIPE option on client socket descriptor \(fd)")
            }

            var tv = timeval(tv_sec: tvSec, tv_usec: tvUsec)
            let optRes = syscalls.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            guard optRes == 0 else {
                throw ComputerUseError.ipcError(reason: "Failed to set SO_SNDTIMEO socket option")
            }

            let bytesWritten: Int
            if let customWriter = socketWriter {
                bytesWritten = try bytesArray.withUnsafeBytes { rawBuf in
                    guard let basePtr = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                    return try customWriter(fd, basePtr + totalWritten, totalCount - totalWritten)
                }
            } else {
                bytesWritten = bytesArray.withUnsafeBytes { rawBuf in
                    guard let basePtr = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                    return syscalls.write(fd, basePtr + totalWritten, totalCount - totalWritten)
                }
            }

            if bytesWritten > 0 {
                totalWritten += bytesWritten
                if clock.now >= deadline {
                    throw ComputerUseError.timeout(operation: "socket_write_response", seconds: phaseBudgetSec)
                }
            } else if bytesWritten == 0 {
                throw ComputerUseError.ipcError(reason: "Zero bytes written to socket")
            } else {
                let err = syscalls.lastErrno
                if err == EINTR { continue }
                if err == EAGAIN || err == EWOULDBLOCK {
                    let current = clock.now
                    if current < deadline {
                        try await Task.sleep(nanoseconds: 10_000_000)
                        continue
                    }
                    throw ComputerUseError.timeout(operation: "socket_write_response", seconds: phaseBudgetSec)
                }
                throw ComputerUseError.ipcError(reason: "Socket write failed with errno \(err)")
            }
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning else { return }
        isRunning = false

        if serverFd >= 0 {
            _ = syscalls.close(serverFd)
            serverFd = -1
        }

        var statBuf = stat()
        if syscalls.lstat(socketPath, &statBuf) == 0 {
            if statBuf.st_dev == self.boundDev && statBuf.st_ino == self.boundInode && statBuf.st_uid == syscalls.getuid() && (statBuf.st_mode & S_IFMT) == S_IFSOCK {
                _ = syscalls.unlink(socketPath)
            }
        }

        if lockFd >= 0 {
            _ = syscalls.flock(lockFd, LOCK_UN)
            _ = syscalls.close(lockFd)
            lockFd = -1
        }

        self.boundDev = 0
        self.boundInode = 0
    }
}
