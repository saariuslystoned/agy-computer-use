import Foundation

public protocol POSIXSyscallProviding: Sendable {
    var lastErrno: Int32 { get }
    func setErrno(_ value: Int32)

    func accept(_ socket: Int32, _ address: UnsafeMutablePointer<sockaddr>?, _ addressLen: UnsafeMutablePointer<socklen_t>?) -> Int32
    func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int
    func write(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int
    func listen(_ socket: Int32, _ backlog: Int32) -> Int32
    func bind(_ socket: Int32, _ address: UnsafePointer<sockaddr>?, _ addressLen: socklen_t) -> Int32
    func socket(_ domain: Int32, _ type: Int32, _ protocol: Int32) -> Int32
    func open(_ path: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32
    func fcntl(_ fd: Int32, _ cmd: Int32, _ arg: Int32) -> Int32
    func getsockopt(_ socket: Int32, _ level: Int32, _ optionName: Int32, _ optionValue: UnsafeMutableRawPointer?, _ optionLen: UnsafeMutablePointer<socklen_t>?) -> Int32
    func lstat(_ path: UnsafePointer<CChar>, _ buf: UnsafeMutablePointer<stat>?) -> Int32
    func fstat(_ fd: Int32, _ buf: UnsafeMutablePointer<stat>?) -> Int32
    func flock(_ fd: Int32, _ operation: Int32) -> Int32
    func unlink(_ path: UnsafePointer<CChar>) -> Int32
    func rmdir(_ path: UnsafePointer<CChar>) -> Int32
    func mkdir(_ path: UnsafePointer<CChar>, _ mode: mode_t) -> Int32
    func close(_ fd: Int32) -> Int32
    func getuid() -> uid_t
    func setsockopt(_ socket: Int32, _ level: Int32, _ optionName: Int32, _ optionValue: UnsafeRawPointer?, _ optionLen: socklen_t) -> Int32
    func connect(_ socket: Int32, _ address: UnsafePointer<sockaddr>?, _ addressLen: socklen_t) -> Int32
    func poll(_ fds: UnsafeMutablePointer<pollfd>?, _ nfds: nfds_t, _ timeout: Int32) -> Int32
    func getpeereid(_ socket: Int32, _ uid: UnsafeMutablePointer<uid_t>?, _ gid: UnsafeMutablePointer<gid_t>?) -> Int32
}

extension POSIXSyscallProviding {
    public func open(_ path: String, _ oflag: Int32, _ mode: mode_t = 0) -> Int32 {
        path.withCString { open($0, oflag, mode) }
    }
    public func lstat(_ path: String, _ buf: UnsafeMutablePointer<stat>?) -> Int32 {
        path.withCString { lstat($0, buf) }
    }
    public func unlink(_ path: String) -> Int32 {
        path.withCString { unlink($0) }
    }
    public func rmdir(_ path: String) -> Int32 {
        path.withCString { rmdir($0) }
    }
    public func mkdir(_ path: String, _ mode: mode_t) -> Int32 {
        path.withCString { mkdir($0, mode) }
    }
}

@_silgen_name("flock")
private func sys_flock(_ fd: Int32, _ operation: Int32) -> Int32

public final class DarwinPOSIXSyscalls: POSIXSyscallProviding, @unchecked Sendable {
    public static let shared = DarwinPOSIXSyscalls()
    public init() {}

    public var lastErrno: Int32 { errno }
    public func setErrno(_ value: Int32) { errno = value }

    public func accept(_ socket: Int32, _ address: UnsafeMutablePointer<sockaddr>?, _ addressLen: UnsafeMutablePointer<socklen_t>?) -> Int32 {
        Darwin.accept(socket, address, addressLen)
    }
    public func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        Darwin.read(fd, buf, count)
    }
    public func write(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int {
        Darwin.write(fd, buf, count)
    }
    public func listen(_ socket: Int32, _ backlog: Int32) -> Int32 {
        Darwin.listen(socket, backlog)
    }
    public func bind(_ socket: Int32, _ address: UnsafePointer<sockaddr>?, _ addressLen: socklen_t) -> Int32 {
        Darwin.bind(socket, address, addressLen)
    }
    public func socket(_ domain: Int32, _ type: Int32, _ protocol: Int32) -> Int32 {
        Darwin.socket(domain, type, `protocol`)
    }
    public func open(_ path: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32 {
        Darwin.open(path, oflag, mode)
    }
    public func fcntl(_ fd: Int32, _ cmd: Int32, _ arg: Int32) -> Int32 {
        Darwin.fcntl(fd, cmd, arg)
    }
    public func getsockopt(_ socket: Int32, _ level: Int32, _ optionName: Int32, _ optionValue: UnsafeMutableRawPointer?, _ optionLen: UnsafeMutablePointer<socklen_t>?) -> Int32 {
        Darwin.getsockopt(socket, level, optionName, optionValue, optionLen)
    }
    public func lstat(_ path: UnsafePointer<CChar>, _ buf: UnsafeMutablePointer<stat>?) -> Int32 {
        Darwin.lstat(path, buf)
    }
    public func fstat(_ fd: Int32, _ buf: UnsafeMutablePointer<stat>?) -> Int32 {
        Darwin.fstat(fd, buf)
    }
    public func flock(_ fd: Int32, _ operation: Int32) -> Int32 {
        sys_flock(fd, operation)
    }
    public func unlink(_ path: UnsafePointer<CChar>) -> Int32 {
        Darwin.unlink(path)
    }
    public func rmdir(_ path: UnsafePointer<CChar>) -> Int32 {
        Darwin.rmdir(path)
    }
    public func mkdir(_ path: UnsafePointer<CChar>, _ mode: mode_t) -> Int32 {
        Darwin.mkdir(path, mode)
    }
    public func close(_ fd: Int32) -> Int32 {
        Darwin.close(fd)
    }
    public func getuid() -> uid_t {
        Darwin.getuid()
    }
    public func setsockopt(_ socket: Int32, _ level: Int32, _ optionName: Int32, _ optionValue: UnsafeRawPointer?, _ optionLen: socklen_t) -> Int32 {
        Darwin.setsockopt(socket, level, optionName, optionValue, optionLen)
    }
    public func connect(_ socket: Int32, _ address: UnsafePointer<sockaddr>?, _ addressLen: socklen_t) -> Int32 {
        Darwin.connect(socket, address, addressLen)
    }
    public func poll(_ fds: UnsafeMutablePointer<pollfd>?, _ nfds: nfds_t, _ timeout: Int32) -> Int32 {
        Darwin.poll(fds, nfds, timeout)
    }
    public func getpeereid(_ socket: Int32, _ uid: UnsafeMutablePointer<uid_t>?, _ gid: UnsafeMutablePointer<gid_t>?) -> Int32 {
        Darwin.getpeereid(socket, uid, gid)
    }
}
