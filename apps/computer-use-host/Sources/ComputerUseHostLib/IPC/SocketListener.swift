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

        // Fail-closed lstat validation
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

    public func start() async throws {
        let dirPath = (socketPath as NSString).deletingLastPathComponent
        try SocketListener.prepareDirectory(at: dirPath)

        // Remove existing stale socket file if it exists and is owned by user and not a symlink
        let fm = FileManager.default
        if fm.fileExists(atPath: socketPath) {
            var statBuf = stat()
            if lstat(socketPath, &statBuf) == 0, (statBuf.st_mode & S_IFMT) != S_IFLNK, statBuf.st_uid == getuid() {
                try fm.removeItem(atPath: socketPath)
            }
        }

        listeningSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listeningSocket >= 0 else {
            throw ComputerUseError.ipcError(reason: "Failed to create socket")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw ComputerUseError.ipcError(reason: "Socket path too long")
        }

        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            ptr.initializeMemory(as: CChar.self, repeating: 0)
            _ = pathBytes.withUnsafeBufferPointer { bPtr in
                memcpy(ptr.baseAddress!, bPtr.baseAddress!, bPtr.count)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(listeningSocket, saPtr, addrLen)
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

    public func stop() {
        isRunning = false
        if listeningSocket >= 0 {
            close(listeningSocket)
            listeningSocket = -1
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: socketPath) {
            try? fm.removeItem(atPath: socketPath)
        }
    }
}
