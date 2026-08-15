import Darwin
import Foundation

/// Failure modes the shared `UnixSocketServer` scaffolding can produce.
public enum UnixSocketError: Error, Sendable, CustomStringConvertible {
    case socketPathTooLong(path: String, limit: Int)
    case directoryCreate(path: String, underlying: String)
    case socketCreate(errno: Int32)
    case socketBind(path: String, errno: Int32)
    case socketListen(errno: Int32)

    public var description: String {
        switch self {
        case .socketPathTooLong(let path, let limit):
            return "Socket path \(path) exceeds sun_path limit (\(limit) bytes)."
        case .directoryCreate(let path, let underlying):
            return "Failed to create \(path): \(underlying)."
        case .socketCreate(let errno):
            return "socket(2) failed with errno \(errno)."
        case .socketBind(let path, let errno):
            return "bind(2) on \(path) failed with errno \(errno)."
        case .socketListen(let errno):
            return "listen(2) failed with errno \(errno)."
        }
    }
}

/// Shared AF_UNIX `SOCK_STREAM` listen-socket scaffolding.
public struct UnixSocketServer: Sendable {
    public init() {}

    /// Idempotent: creates the dir at `0700` if missing, and tightens an
    /// existing dir's perms to `0700` if it's currently looser.
    public func ensureDirectory(at url: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw UnixSocketError.directoryCreate(
                    path: url.path,
                    underlying: "Path exists and is not a directory."
                )
            }
            try tightenToOwnerOnly(at: url)
            return
        }
        do {
            try manager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw UnixSocketError.directoryCreate(
                path: url.path,
                underlying: error.localizedDescription
            )
        }
    }

    private func tightenToOwnerOnly(at url: URL) throws {
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: url.path)
        let currentPerms = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        if (currentPerms & 0o077) == 0 {
            return
        }
        let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uintValue
        guard ownerID == UInt(getuid()) else {
            return
        }
        do {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw UnixSocketError.directoryCreate(
                path: url.path,
                underlying: "Failed to tighten to 0700: \(error.localizedDescription)"
            )
        }
    }

    /// Returns a non-blocking, listening AF_UNIX SOCK_STREAM fd bound to
    /// `path`. Unlinks any stale socket file from a previous run before binding.
    public func createListenSocket(at path: String) throws -> Int32 {
        let pathBytes = Array(path.utf8)
        let pathLimit = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard pathBytes.count < pathLimit else {
            throw UnixSocketError.socketPathTooLong(path: path, limit: pathLimit)
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.socketCreate(errno: errno) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        _ = Darwin.unlink(path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePointer in
            tuplePointer.withMemoryRebound(to: CChar.self, capacity: pathLimit) { charPointer in
                for index in 0..<pathBytes.count {
                    charPointer[index] = CChar(bitPattern: pathBytes[index])
                }
                charPointer[pathBytes.count] = 0
            }
        }

        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { addrPointer -> Int32 in
            addrPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, addrSize)
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw UnixSocketError.socketBind(path: path, errno: err)
        }

        _ = Darwin.chmod(path, 0o600)

        guard Darwin.listen(fd, 16) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw UnixSocketError.socketListen(errno: err)
        }
        return fd
    }

    public func runAcceptLoop(
        fd: Int32,
        queue: DispatchQueue,
        socketPath: String,
        onAccept: @escaping @Sendable (Int32) -> Void,
        onFatalAcceptError: @escaping @Sendable (Int32) -> Void
    ) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            while true {
                let clientFD = Darwin.accept(fd, nil, nil)
                if clientFD < 0 {
                    let err = errno
                    if err == EAGAIN || err == EWOULDBLOCK { return }
                    if err == EBADF || err == EINVAL { return }
                    onFatalAcceptError(err)
                    return
                }
                let clientFlags = fcntl(clientFD, F_GETFL, 0)
                if clientFlags >= 0 {
                    _ = fcntl(clientFD, F_SETFL, clientFlags & ~O_NONBLOCK)
                }
                onAccept(clientFD)
            }
        }
        source.setCancelHandler {
            Darwin.close(fd)
            _ = Darwin.unlink(socketPath)
        }
        source.resume()
        return source
    }
}
