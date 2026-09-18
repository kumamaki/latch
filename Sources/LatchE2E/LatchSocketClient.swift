import Foundation

/// Where the kernel socket and token live. Client-side twin of
/// LatchPaths: explicit data dir first, then LATCH_DATA_DIR, then the
/// standard per-app directory.
public struct LatchEndpoint: Sendable {
    public let socket: URL
    public let tokenFile: URL

    public init(socket: URL, tokenFile: URL) {
        self.socket = socket
        self.tokenFile = tokenFile
    }

    public static func resolve(slug: String, dataDir: URL? = nil) -> LatchEndpoint {
        let directory: URL
        if let dataDir {
            directory = dataDir
        } else if let override = ProcessInfo.processInfo.environment["LATCH_DATA_DIR"],
            !override.isEmpty
        {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("\(slug)-dev", isDirectory: true)
        }
        return LatchEndpoint(
            socket: directory.appendingPathComponent("latch.sock"),
            tokenFile: directory.appendingPathComponent("latch.token")
        )
    }
}

/// Protocol client. One-shot newline-JSON round-trips like
/// cli/latch.sh; the server keeps no state between commands, so the
/// client does not either — it re-connects per command.
public actor LatchSocketClient {
    private let endpoint: LatchEndpoint
    private let timeout: TimeInterval
    private var cachedToken: String?

    private static let maxResponseBytes = 64 * 1024 * 1024

    public init(endpoint: LatchEndpoint, timeout: TimeInterval = 30) {
        self.endpoint = endpoint
        self.timeout = timeout
    }

    /// Send one kernel command and return the `data` payload on `ok`.
    /// Server failures throw `.server(code:message:)`.
    public func send(_ command: String, args: [String: JSONValue] = [:]) async throws -> JSONValue {
        let token = try self.token()
        var request: [String: JSONValue] = [
            "token": .string(token),
            "command": .string(command),
        ]
        if !args.isEmpty {
            request["args"] = .object(args)
        }
        let payload = try JSONEncoder().encode(JSONValue.object(request))

        let response = try Self.roundTrip(
            payload: payload,
            socketPath: endpoint.socket.path,
            timeoutSeconds: Int(timeout)
        )
        guard let envelope = try? JSONDecoder().decode(JSONValue.self, from: response) else {
            throw LatchE2EError.socket(
                reason:
                    "unparseable response: \(String(decoding: response.prefix(200), as: UTF8.self))"
            )
        }
        if envelope["ok"]?.boolValue == true {
            return envelope["data"] ?? .null
        }
        let error = envelope["error"]
        throw LatchE2EError.server(
            code: error?["code"]?.stringValue ?? "unknown",
            message: error?["message"]?.stringValue ?? "unknown error"
        )
    }

    /// The app writes the token once at boot; read it once per client.
    private func token() throws -> String {
        if let cachedToken {
            return cachedToken
        }
        guard FileManager.default.fileExists(atPath: endpoint.tokenFile.path) else {
            throw LatchE2EError.tokenMissing(path: endpoint.tokenFile.path)
        }
        let raw: String
        do {
            raw = try String(contentsOf: endpoint.tokenFile, encoding: .utf8)
        } catch {
            throw LatchE2EError.tokenMissing(path: endpoint.tokenFile.path)
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw LatchE2EError.tokenMissing(path: endpoint.tokenFile.path)
        }
        cachedToken = value
        return value
    }

    // MARK: - POSIX one-shot client

    private static func roundTrip(
        payload: Data,
        socketPath: String,
        timeoutSeconds: Int
    ) throws -> Data {
        let fd = try connect(path: socketPath)
        defer { Darwin.close(fd) }
        applyTimeout(fd: fd, seconds: timeoutSeconds)

        var out = payload
        out.append(0x0A)
        try sendAll(fd: fd, data: out)
        let response = try readAll(fd: fd)
        guard !response.isEmpty else {
            throw LatchE2EError.socket(reason: "connection closed without a response")
        }
        return response
    }

    private static func connect(path: String) throws -> Int32 {
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < 104 else {
            throw LatchE2EError.socket(reason: "socket path too long: \(path)")
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw LatchE2EError.socket(reason: "socket(2) failed, errno \(errno)")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            _ = pathBytes.copyBytes(to: destination.bindMemory(to: UInt8.self))
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw LatchE2EError.socket(reason: "connect to \(path) failed, errno \(code)")
        }
        return fd
    }

    private static func applyTimeout(fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        withUnsafePointer(to: &timeout) { pointer in
            _ = Darwin.setsockopt(
                fd, SOL_SOCKET, SO_RCVTIMEO, pointer,
                socklen_t(MemoryLayout<timeval>.size))
            _ = Darwin.setsockopt(
                fd, SOL_SOCKET, SO_SNDTIMEO, pointer,
                socklen_t(MemoryLayout<timeval>.size))
        }
    }

    private static func sendAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var base = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.send(fd, base, remaining, 0)
                if written < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw LatchE2EError.socket(reason: "send failed, errno \(code)")
                }
                base = base.advanced(by: written)
                remaining -= written
            }
        }
    }

    private static func readAll(fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let chunk = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return Darwin.recv(fd, base, pointer.count, 0)
            }
            if chunk == 0 { break }
            if chunk < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK {
                    throw LatchE2EError.socket(reason: "recv timed out")
                }
                throw LatchE2EError.socket(reason: "recv failed, errno \(code)")
            }
            data.append(buffer, count: chunk)
            if data.count > maxResponseBytes {
                throw LatchE2EError.socket(reason: "response exceeds \(maxResponseBytes) bytes")
            }
        }
        while let last = data.last, last == 0x0A || last == 0x0D || last == 0x20 || last == 0x09 {
            data.removeLast()
        }
        return data
    }
}
