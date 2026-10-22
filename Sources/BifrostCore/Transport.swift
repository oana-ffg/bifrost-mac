import Foundation
import Darwin

public enum Runtime {
    public static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bifrost/run") }
    public static var socketPath: String { directory.appendingPathComponent("bridge.sock").path }
    public static func checkPrivateDirectory(_ url: URL, create: Bool) throws {
        var metadata = stat()
        if lstat(url.path, &metadata) < 0 {
            guard errno == ENOENT, create else { throw BridgeError("runtime_unavailable", "Runtime directory is missing; start /Applications/Bifrost.app.") }
            guard mkdir(url.path, 0o700) == 0 else { throw systemError("create runtime directory") }
            guard lstat(url.path, &metadata) == 0 else { throw systemError("inspect runtime directory") }
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else {
            throw BridgeError("unsafe_runtime", "\(url.path) must be an owned directory with mode 0700, without a symlink.")
        }
    }
}

public func systemError(_ operation: String) -> BridgeError { BridgeError("transport_error", "\(operation): \(String(cString: strerror(errno)))") }

private func address(_ path: String) throws -> sockaddr_un {
    var value = sockaddr_un()
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path), path.utf8.allSatisfy({ $0 < 128 }) else {
        throw BridgeError("socket_path", "The Unix socket path must be ASCII and at most 103 bytes.")
    }
    value.sun_family = sa_family_t(AF_UNIX)
    value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &value.sun_path) { $0.copyBytes(from: bytes) }
    return value
}

public final class Connection {
    public let fd: Int32
    public let peerPID: Int32
    private let writeLock = NSLock()
    public init(fd: Int32) throws {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { Darwin.close(fd); throw BridgeError("peer_denied", "Only the same OS user may connect.") }
        var pid: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, 0, LOCAL_PEERPID, &pid, &length) == 0 else { Darwin.close(fd); throw systemError("inspect peer PID") }
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else { Darwin.close(fd); throw systemError("configure socket") }
        self.fd = fd; self.peerPID = pid
    }
    deinit { Darwin.close(fd) }
    public static func connect(path: String = Runtime.socketPath) throws -> Connection {
        try Runtime.checkPrivateDirectory(URL(fileURLWithPath: path).deletingLastPathComponent(), create: false)
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFSOCK, metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else {
            throw BridgeError("app_unavailable", "The private Bifrost socket is missing or unsafe. Run bifrost start, then bifrost doctor.")
        }
        var target = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw systemError("create socket") }
        let result = withUnsafePointer(to: &target) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else {
            let denied = errno == EPERM || errno == EACCES
            let error = denied ? BridgeError("sandbox_blocked", "The agent sandbox blocked Bifrost's local socket. Use the configured Bifrost MCP tools or request host access for this CLI command.") : systemError("connect; start Bifrost.app if it is not running")
            Darwin.close(fd); throw error
        }
        return try Connection(fd: fd)
    }
    private func wait(_ events: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw BridgeError("deadline_exceeded", "Bifrost request timed out. Check the app and required permissions.") }
            var item = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&item, 1, Int32(min(remaining * 1000, 1000)))
            if result < 0 { if errno == EINTR { continue }; throw systemError("poll") }
            if result > 0 { return }
        }
    }
    private func readBytes(_ count: Int, deadline: TimeInterval) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                try wait(Int16(POLLIN), deadline: deadline)
                let received = recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, MSG_DONTWAIT)
                if received == 0 { throw BridgeError("disconnected", "The bridge closed the connection.") }
                if received < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw systemError("read") }
                offset += received
            }
        }
        return data
    }
    public func receive(timeout: TimeInterval = 30) throws -> [String: Any] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let header = try readBytes(4, deadline: deadline)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= Wire.maximumFrame else { throw BridgeError("frame_limit", "Frame length is outside the supported range.") }
        let data = try readBytes(count, deadline: deadline)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BridgeError("invalid_request", "Expected a JSON object.") }
        return object
    }
    public func send(_ value: [String: Any], timeout: TimeInterval = 30) throws {
        let payload = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard !payload.isEmpty, payload.count <= Wire.maximumFrame else { throw BridgeError("frame_limit", "Response exceeds 8 MiB. Narrow the query.") }
        var size = UInt32(payload.count).bigEndian
        var data = withUnsafeBytes(of: &size) { Data($0) }; data.append(payload)
        writeLock.lock(); defer { writeLock.unlock() }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                try wait(Int16(POLLOUT), deadline: deadline)
                let sent = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset, MSG_DONTWAIT)
                if sent < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw systemError("write") }
                guard sent > 0 else { throw BridgeError("disconnected", "Socket write returned zero.") }
                offset += sent
            }
        }
    }
}

public final class Listener {
    public let fd: Int32
    private let lockFD: Int32
    private let path: String
    private let socketInode: ino_t
    public init(path: String = Runtime.socketPath) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try Runtime.checkPrivateDirectory(directory.deletingLastPathComponent(), create: true)
        try Runtime.checkPrivateDirectory(directory, create: true)
        let lockPath = directory.appendingPathComponent("bridge.lock").path
        let lockHandle = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockHandle >= 0 else { throw systemError("open instance lock") }
        var lockInfo = stat()
        guard fstat(lockHandle, &lockInfo) == 0, lockInfo.st_uid == getuid(), lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_mode & 0o077 == 0, flock(lockHandle, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockHandle); throw BridgeError("already_running", "Bifrost is already running, or its instance lock is unsafe.")
        }
        let newFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard newFD >= 0 else { Darwin.close(lockHandle); throw systemError("create listener") }
        var ownedInode: ino_t = 0
        do {
            var metadata = stat()
            if lstat(path, &metadata) == 0 {
                guard metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFSOCK else { throw BridgeError("unsafe_runtime", "Refusing to replace a non-socket or foreign socket.") }
                guard unlink(path) == 0 else { throw systemError("remove stale socket") }
            } else if errno != ENOENT { throw systemError("inspect socket") }
            var target = try address(path)
            let result = withUnsafePointer(to: &target) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(newFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result == 0, lstat(path, &metadata) == 0 else { throw systemError("bind") }
            ownedInode = metadata.st_ino
            guard chmod(path, 0o600) == 0, listen(newFD, 16) == 0 else { throw systemError("listen") }
            guard fcntl(newFD, F_SETFD, FD_CLOEXEC) == 0 else { throw systemError("configure listener") }
        } catch {
            Darwin.close(newFD)
            if ownedInode != 0 { var current = stat(); if lstat(path, &current) == 0, current.st_ino == ownedInode, current.st_mode & S_IFMT == S_IFSOCK { unlink(path) } }
            Darwin.close(lockHandle)
            throw error
        }
        self.path = path; self.fd = newFD; self.lockFD = lockHandle; self.socketInode = ownedInode
    }
    deinit {
        Darwin.close(fd)
        var current = stat()
        if lstat(path, &current) == 0, current.st_ino == socketInode, current.st_mode & S_IFMT == S_IFSOCK { unlink(path) }
        Darwin.close(lockFD)
    }
    public func accept() throws -> Connection {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                let failure = errno
                if failure == EBADF || failure == EINVAL { throw systemError("listener is closed") }
                NSLog("Bifrost accept failed (%d); retrying", failure)
                if failure == EMFILE || failure == ENFILE || failure == ENOBUFS || failure == ENOMEM { Thread.sleep(forTimeInterval: 0.25) }
                continue
            }
            guard fcntl(client, F_SETFD, FD_CLOEXEC) == 0 else {
                NSLog("Bifrost client setup failed (%d); dropping connection", errno); Darwin.close(client); continue
            }
            do { return try Connection(fd: client) }
            catch { NSLog("Bifrost dropped disconnected or invalid peer: %@", error.localizedDescription) }
        }
    }
}

public enum BridgeClient {
    public static func call(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 30) throws -> Any {
        let connection = try Connection.connect()
        try connection.send(["version": Wire.version, "method": method, "params": params], timeout: timeout)
        return try Wire.result(connection.receive(timeout: timeout))
    }
}
