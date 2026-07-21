import Foundation

public class SocketListener {
    public let socketPath: String
    private let server: HostServer
    private var listeningSocket: Int32 = -1
    private var isRunning = false

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

        guard statBuf.st_uid == getuid() else {
            throw ComputerUseError.ipcError(reason: "Runtime directory \(path) owner \(statBuf.st_uid) != current user \(getuid())")
        }

        guard (statBuf.st_mode & 0o077) == 0 else {
            throw ComputerUseError.ipcError(reason: "Runtime directory \(path) permissions permits group/other access")
        }
    }

    public func start() throws {
        let dirPath = (socketPath as NSString).deletingLastPathComponent
        try SocketListener.prepareDirectory(at: dirPath)

        let fm = FileManager.default
        if fm.fileExists(atPath: socketPath) {
            var statBuf = stat()
            if lstat(socketPath, &statBuf) == 0, (statBuf.st_mode & S_IFMT) != S_IFLNK, statBuf.st_uid == getuid() {
                try fm.removeItem(atPath: socketPath)
            } else {
                throw ComputerUseError.ipcError(reason: "Refusing to unlink unverified or unowned socket at \(socketPath)")
            }
        }

        listeningSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listeningSocket >= 0 else {
            throw ComputerUseError.ipcError(reason: "Failed to create socket")
        }

        var addr = sockaddr_un()
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw ComputerUseError.ipcError(reason: "Socket path too long")
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
                bind(listeningSocket, saPtr, socklen_t(addrLen))
            }
        }

        guard bindRes == 0 else {
            throw ComputerUseError.ipcError(reason: "Socket bind failed for \(socketPath)")
        }

        guard listen(listeningSocket, 5) == 0 else {
            throw ComputerUseError.ipcError(reason: "Socket listen failed")
        }

        chmod(socketPath, 0o600)
        isRunning = true
    }

    public func acceptAndHandleOneConnection() async throws -> Bool {
        guard isRunning, listeningSocket >= 0 else { return false }

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

        defer { close(clientFd) }

        // Darwin peer credential verification using getpeereid
        var peuid: uid_t = 0
        var pegid: gid_t = 0
        guard getpeereid(clientFd, &peuid, &pegid) == 0 else {
            throw ComputerUseError.ipcError(reason: "getpeereid failed for client connection")
        }

        guard peuid == getuid() else {
            throw ComputerUseError.ipcError(reason: "Peer UID \(peuid) does not match process owner UID \(getuid())")
        }

        // Read request length header (4-byte big endian)
        var lengthBuf = [UInt8](repeating: 0, count: 4)
        let readLen = read(clientFd, &lengthBuf, 4)
        guard readLen == 4 else {
            throw ComputerUseError.ipcError(reason: "Failed to read 4-byte framing header")
        }

        let payloadLen = Int(lengthBuf[0]) << 24 | Int(lengthBuf[1]) << 16 | Int(lengthBuf[2]) << 8 | Int(lengthBuf[3])
        guard payloadLen > 0 && payloadLen <= 16 * 1024 * 1024 else {
            throw ComputerUseError.ipcError(reason: "Invalid payload length \(payloadLen)")
        }

        var payloadBuf = [UInt8](repeating: 0, count: payloadLen)
        var totalRead = 0
        while totalRead < payloadLen {
            let bytesRead = payloadBuf.withUnsafeMutableBufferPointer { bPtr in
                read(clientFd, bPtr.baseAddress! + totalRead, payloadLen - totalRead)
            }
            if bytesRead <= 0 { break }
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
        _ = encodedResponse.withUnsafeBytes { bPtr in
            write(clientFd, bPtr.baseAddress!, encodedResponse.count)
        }

        return true
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
            if lstat(socketPath, &statBuf) == 0, (statBuf.st_mode & S_IFMT) != S_IFLNK, statBuf.st_uid == getuid() {
                try? fm.removeItem(atPath: socketPath)
            }
        }
    }
}
