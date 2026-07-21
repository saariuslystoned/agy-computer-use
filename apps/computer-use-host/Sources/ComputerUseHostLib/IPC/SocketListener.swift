import Foundation

public class SocketListener {
    public let socketPath: String
    private let server: HostServer
    private var listeningSocket: Int32 = -1
    private var isRunning = false
    private var boundInode: ino_t = 0
    private var boundDev: dev_t = 0

    public init(socketPath: String? = nil, server: HostServer) {
        let uid = getuid()
        let defaultPath = "/tmp/agy-computer-use-\(uid)/agy-computer-use.sock"
        self.socketPath = socketPath ?? defaultPath
        self.server = server
    }

    public static func resolvePerUserSocketDirectory() -> String {
        let uid = getuid()
        return "/tmp/agy-computer-use-\(uid)"
    }

    public static func prepareDirectory(at path: String) throws {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        if !fileManager.fileExists(atPath: path, isDirectory: &isDir) {
            try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        var statBuf = stat()
        guard lstat(path, &statBuf) == 0 else {
            throw ComputerUseError.ipcError(reason: "lstat failed on directory \(path)")
        }

        guard (statBuf.st_mode & S_IFMT) == S_IFDIR else {
            throw ComputerUseError.ipcError(reason: "Runtime directory \(path) is a symlink or not a directory")
        }

        guard (statBuf.st_mode & S_IFLNK) == 0 else {
            throw ComputerUseError.ipcError(reason: "Runtime directory \(path) must not be a symbolic link")
        }

        guard statBuf.st_uid == getuid() else {
            throw ComputerUseError.ipcError(reason: "Runtime directory \(path) is not owned by current user (UID \(getuid()))")
        }

        let currentPermissions = statBuf.st_mode & 0o777
        guard currentPermissions == 0o700 else {
            throw ComputerUseError.ipcError(reason: "Runtime directory \(path) permissions are \(String(format: "%o", currentPermissions)), expected 0700")
        }
    }

    public func start() throws {
        let dirPath = (socketPath as NSString).deletingLastPathComponent
        try SocketListener.prepareDirectory(at: dirPath)

        let fm = FileManager.default
        if fm.fileExists(atPath: socketPath) {
            var statBuf = stat()
            guard lstat(socketPath, &statBuf) == 0 else {
                throw ComputerUseError.ipcError(reason: "Failed to stat existing socket path \(socketPath)")
            }

            guard (statBuf.st_mode & S_IFMT) == S_IFSOCK else {
                throw ComputerUseError.ipcError(reason: "Existing path \(socketPath) is not a socket file")
            }

            guard statBuf.st_uid == getuid() else {
                throw ComputerUseError.ipcError(reason: "Existing socket \(socketPath) owned by another user")
            }

            // Distinguish live listener from stale socket file by attempting test connection
            let testFd = socket(AF_UNIX, SOCK_STREAM, 0)
            if testFd >= 0 {
                var testAddr = sockaddr_un()
                let pathBytes = socketPath.utf8CString
                let addrLen = MemoryLayout<sa_family_t>.size + pathBytes.count
                testAddr.sun_len = UInt8(addrLen)
                testAddr.sun_family = sa_family_t(AF_UNIX)
                withUnsafeMutableBytes(of: &testAddr.sun_path) { ptr in
                    ptr.initializeMemory(as: CChar.self, repeating: 0)
                    _ = pathBytes.withUnsafeBufferPointer { bPtr in
                        memcpy(ptr.baseAddress!, bPtr.baseAddress!, bPtr.count)
                    }
                }

                let connRes = withUnsafePointer(to: &testAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        connect(testFd, saPtr, socklen_t(addrLen))
                    }
                }
                close(testFd)

                if connRes == 0 {
                    throw ComputerUseError.ipcError(reason: "Active listener process already bound to socket path \(socketPath)")
                }
            }

            // Socket is stale and non-responsive; safely remove it
            try fm.removeItem(atPath: socketPath)
        }

        listeningSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listeningSocket >= 0 else {
            throw ComputerUseError.ipcError(reason: "Failed to create socket file descriptor")
        }

        var addr = sockaddr_un()
        let pathBytes = socketPath.utf8CString
        let addrLen = MemoryLayout<sa_family_t>.size + pathBytes.count
        guard addrLen <= MemoryLayout<sockaddr_un>.size else {
            throw ComputerUseError.ipcError(reason: "Socket path '\(socketPath)' exceeds Darwin max length")
        }

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
                bind(listeningSocket, saPtr, socklen_t(addrLen))
            }
        }

        guard bindRes == 0 else {
            close(listeningSocket)
            listeningSocket = -1
            throw ComputerUseError.ipcError(reason: "Failed to bind Unix domain socket to \(socketPath)")
        }

        guard listen(listeningSocket, 5) == 0 else {
            close(listeningSocket)
            listeningSocket = -1
            throw ComputerUseError.ipcError(reason: "Failed to listen on Unix domain socket")
        }

        var statBuf = stat()
        if lstat(socketPath, &statBuf) == 0 {
            self.boundInode = statBuf.st_ino
            self.boundDev = statBuf.st_dev
        }

        isRunning = true
    }

    public func acceptAndHandleOneConnection() async throws -> Bool {
        guard isRunning && listeningSocket >= 0 else { return false }

        var clientAddr = sockaddr_un()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                accept(listeningSocket, saPtr, &clientAddrLen)
            }
        }

        guard clientFd >= 0 else {
            if !isRunning { return false }
            throw ComputerUseError.ipcError(reason: "Socket accept failed")
        }

        defer {
            close(clientFd)
        }

        // Validate peer credentials on Darwin via getpeereid
        var peuid: uid_t = 0
        var pegid: gid_t = 0
        guard getpeereid(clientFd, &peuid, &pegid) == 0 else {
            throw ComputerUseError.ipcError(reason: "getpeereid failed on client socket")
        }

        guard peuid == getuid() else {
            throw ComputerUseError.permissionDenied(permission: "Peer UID \(peuid) does not match host UID \(getuid())")
        }

        // Read length-prefixed request header with EINTR retry handling
        var headerBuf = [UInt8](repeating: 0, count: 4)
        var headerRead = 0
        while headerRead < 4 {
            let n = headerBuf.withUnsafeMutableBufferPointer { bPtr in
                read(clientFd, bPtr.baseAddress! + headerRead, 4 - headerRead)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw ComputerUseError.ipcError(reason: "Socket header read error: \(String(cString: strerror(errno)))")
            }
            if n == 0 { break }
            headerRead += n
        }

        guard headerRead == 4 else {
            return false // Socket closed without complete frame
        }

        let payloadLen = Int(headerBuf[0]) << 24 | Int(headerBuf[1]) << 16 | Int(headerBuf[2]) << 8 | Int(headerBuf[3])
        guard payloadLen > 0 && payloadLen <= 16 * 1024 * 1024 else {
            throw ComputerUseError.ipcError(reason: "Invalid payload length \(payloadLen)")
        }

        // Read payload bytes with EINTR retry handling
        var payloadBuf = [UInt8](repeating: 0, count: payloadLen)
        var totalRead = 0
        while totalRead < payloadLen {
            let bytesRead = payloadBuf.withUnsafeMutableBufferPointer { bPtr in
                read(clientFd, bPtr.baseAddress! + totalRead, payloadLen - totalRead)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw ComputerUseError.ipcError(reason: "Socket payload read error: \(String(cString: strerror(errno)))")
            }
            if bytesRead == 0 { break }
            totalRead += bytesRead
        }

        guard totalRead == payloadLen else {
            throw ComputerUseError.ipcError(reason: "Incomplete read of request payload")
        }

        let requestData = Data(payloadBuf)
        let request = try JSONDecoder().decode(IPCRequest.self, from: requestData)

        // Dispatch request to HostServer actor
        let response = await server.handleRequest(request)
        let responseData = try JSONEncoder().encode(response)

        let encodedResponse = try LengthPrefixedFramer.encode(payload: responseData)

        // Robust write loop handling partial writes and EINTR
        try writeAll(fd: clientFd, data: encodedResponse)

        return true
    }

    private func writeAll(fd: Int32, data: Data) throws {
        var written = 0
        let total = data.count
        try data.withUnsafeBytes { rawPtr in
            guard let basePtr = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            while written < total {
                let res = write(fd, basePtr + written, total - written)
                if res < 0 {
                    if errno == EINTR { continue }
                    throw ComputerUseError.ipcError(reason: "Socket write error: \(String(cString: strerror(errno)))")
                }
                if res == 0 {
                    throw ComputerUseError.ipcError(reason: "Socket closed prematurely during write")
                }
                written += res
            }
        }
    }

    public func stop() {
        isRunning = false
        if listeningSocket >= 0 {
            close(listeningSocket)
            listeningSocket = -1
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: socketPath) {
            var statBuf = stat()
            if lstat(socketPath, &statBuf) == 0,
               (statBuf.st_mode & S_IFMT) == S_IFSOCK,
               statBuf.st_uid == getuid(),
               statBuf.st_ino == boundInode,
               statBuf.st_dev == boundDev {
                try? fm.removeItem(atPath: socketPath)
            }
        }
    }
}
