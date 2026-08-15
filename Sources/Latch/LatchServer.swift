import Darwin
import Foundation
import os

/// DEBUG Latch socket. A file token instead of Keychain.
public actor LatchServer {
    private static let logger = Logger(subsystem: "latch", category: "LatchServer")

    /// Weak so the host can retain the server without a cycle.
    private weak var ops: (any LatchOpsProviding)?
    private var token: LatchToken
    private let socketPath: URL
    private let unixServer = UnixSocketServer()
    private var acceptSource: DispatchSourceRead?
    private var isRunning = false

    static let recvTimeoutSeconds: Int = 10
    static let maxConcurrentConnections: Int = 8
    private static let maxRequestBytes = 64 * 1024

    private nonisolated let connectionGate = DispatchSemaphore(
        value: maxConcurrentConnections
    )
    private nonisolated let acceptQueue = DispatchQueue(
        label: "latch.accept",
        qos: .utility
    )

    public init(
        ops: any LatchOpsProviding,
        token: LatchToken,
        socketPath: URL
    ) {
        self.ops = ops
        self.token = token
        self.socketPath = socketPath
    }

    public func start() throws {
        guard !isRunning else { return }

        do {
            try unixServer.ensureDirectory(at: socketPath.deletingLastPathComponent())
            let fd = try unixServer.createListenSocket(at: socketPath.path)

            acceptSource = unixServer.runAcceptLoop(
                fd: fd,
                queue: acceptQueue,
                socketPath: socketPath.path,
                onAccept: { [weak self] clientFD in
                    guard let self else {
                        Darwin.close(clientFD)
                        return
                    }
                    guard self.connectionGate.wait(timeout: .now()) == .success else {
                        Self.logger.warning("latch.accept outcome=rejected why=concurrent_cap")
                        Darwin.close(clientFD)
                        return
                    }
                    Self.applyRecvTimeout(fd: clientFD)
                    Task {
                        defer { self.connectionGate.signal() }
                        do {
                            try await self.handleConnection(clientFD: clientFD)
                        } catch {
                            Self.logger.warning("latch.connection outcome=failed why=\(error)")
                        }
                    }
                },
                onFatalAcceptError: { err in
                    Self.logger.warning("latch.accept outcome=failed errno=\(err)")
                }
            )
            isRunning = true
            Self.logger.info("latch.server outcome=started path=\(self.socketPath.path)")
        } catch let error as UnixSocketError {
            throw LatchError(error)
        }
    }

    public func stop() {
        guard isRunning else { return }
        acceptSource?.cancel()
        acceptSource = nil
        isRunning = false
    }

    private func handleConnection(clientFD: Int32) async throws {
        defer { Darwin.close(clientFD) }

        let raw = try Self.recvLine(fd: clientFD, limit: Self.maxRequestBytes)
        guard !raw.isEmpty else { return }

        let response = await dispatch(raw: raw)
        var encoded: Data
        do {
            encoded = try Self.encoder.encode(response)
        } catch {
            throw LatchError.encodeFailed(underlying: "\(error)")
        }
        encoded.append(0x0A)
        try Self.sendAll(fd: clientFD, data: encoded)
    }

    private func dispatch(raw: Data) async -> LatchResponse {
        let request: LatchRequest
        do {
            request = try Self.decoder.decode(LatchRequest.self, from: raw)
        } catch let error as LatchError {
            let code: LatchErrorCode =
                if case .unknownCommand = error { .unknownCommand } else { .protocol }
            return .failure(.init(code: code, message: error.description))
        } catch {
            return .failure(
                .init(code: .protocol, message: "Failed to decode request: \(error)")
            )
        }

        guard token.matches(request.token) else {
            return .failure(
                .init(code: .unauthenticated, message: "Token does not match.")
            )
        }

        do {
            return try await execute(command: request.command)
        } catch let error as LatchError {
            return .failure(.init(code: Self.code(for: error), message: error.description))
        } catch {
            return .failure(.init(code: .ipc, message: "\(error)"))
        }
    }

    private func execute(command: LatchCommand) async throws -> LatchResponse {
        guard let ops else {
            throw LatchError.opsUnavailable(reason: "Latch ops are gone.")
        }
        switch command {
        case .ping:
            return .success(.pong)
        case .queryBoot:
            return .success(.boot(state: await ops.queryBoot()))
        case .queryWindows:
            return .success(.windows(items: await ops.queryWindows()))
        case .windowShow(let name):
            try await ops.showWindow(name)
            return .success()
        case .windowHide(let name):
            try await ops.hideWindow(name)
            return .success()
        case .axDump(let window, let labeled):
            let root = try await ops.axDump(window: window, labeled: labeled)
            return .success(.axTree(root: root))
        case .axFind(let id):
            let node = try await ops.axFind(id: id)
            return .success(.axNode(node))
        case .axPress(let id, let action):
            try await ops.axPress(id: id, action: action)
            return .success()
        case .axSet(let id, let value):
            try await ops.axSet(id: id, value: value)
            return .success()
        case .screenshot(let window):
            let path = try await ops.screenshot(window: window)
            return .success(.screenshot(path: path))
        }
    }

    private static func code(for error: LatchError) -> LatchErrorCode {
        switch error {
        case .unauthenticated:
            return .unauthenticated
        case .unknownCommand:
            return .unknownCommand
        case .unknownWindow, .elementNotFound:
            return .notFound
        case .invalidValue:
            return .protocol
        case .windowNotVisible, .windowEmpty, .screenshotFailed, .actionUnavailable,
            .coreNotReady, .opsUnavailable:
            return .unavailable
        default:
            return .ipc
        }
    }

    private static let decoder = JSONDecoder()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    internal nonisolated static func applyRecvTimeout(fd: Int32) {
        var timeout = timeval(tv_sec: recvTimeoutSeconds, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) { pointer in
            Darwin.setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
    }

    internal nonisolated static func recvLine(fd: Int32, limit: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < limit {
            let chunk = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return Darwin.recv(fd, base, pointer.count, 0)
            }
            if chunk == 0 { break }
            if chunk < 0 {
                let err = errno
                if err == EINTR { continue }
                throw LatchError.recvFailed(errno: err)
            }
            data.append(buffer, count: chunk)
            if data.last == 0x0A { break }
        }
        return data
    }

    internal nonisolated static func sendAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard var base = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.send(fd, base, remaining, 0)
                if written < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    throw LatchError.sendFailed(errno: err)
                }
                if written == 0 {
                    throw LatchError.sendFailed(errno: 0)
                }
                base = base.advanced(by: written)
                remaining -= written
            }
        }
    }
}
