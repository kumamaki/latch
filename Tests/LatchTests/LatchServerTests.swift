import Darwin
import Foundation
import Testing

@testable import Latch

@Suite(.serialized)
struct LatchServerTests {
    @Test("ping round-trip returns ok")
    func ping() async throws {
        let ops = FakeLatchOps()
        let (server, socketURL, token) = try await Self.makeServer(ops: ops)
        defer {
            Task { await server.stop() }
            try? FileManager.default.removeItem(at: socketURL)
        }

        let response = try Self.roundTrip(
            socketPath: socketURL.path,
            request: #"{"token":"\#(token)","command":"ping"}"#
        )
        let json = try #require(Self.parse(response))
        #expect(json["ok"] as? Bool == true)
    }

    @Test("wrong token is unauthenticated")
    func unauthenticated() async throws {
        let (server, socketURL, _) = try await Self.makeServer(ops: FakeLatchOps())
        defer {
            Task { await server.stop() }
            try? FileManager.default.removeItem(at: socketURL)
        }

        let response = try Self.roundTrip(
            socketPath: socketURL.path,
            request: #"{"token":"nope","command":"ping"}"#
        )
        let json = try #require(Self.parse(response))
        #expect(json["ok"] as? Bool == false)
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? String == "unauthenticated")
    }

    @Test("screenshot returns the path from ops")
    func screenshot() async throws {
        let ops = FakeLatchOps()
        await ops.setScreenshotPath("/tmp/main.png")
        let (server, socketURL, token) = try await Self.makeServer(ops: ops)
        defer {
            Task { await server.stop() }
            try? FileManager.default.removeItem(at: socketURL)
        }

        let response = try Self.roundTrip(
            socketPath: socketURL.path,
            request: #"{"token":"\#(token)","command":"screenshot","args":{"window":"main"}}"#
        )
        let json = try #require(Self.parse(response))
        #expect(json["ok"] as? Bool == true)
        let data = try #require(json["data"] as? [String: Any])
        #expect(data["path"] as? String == "/tmp/main.png")
        #expect(await ops.screenshotWindows == ["main"])
    }

    @Test("axPress forwards the named action")
    func axPressNamed() async throws {
        let ops = FakeLatchOps()
        let (server, socketURL, token) = try await Self.makeServer(ops: ops)
        defer {
            Task { await server.stop() }
            try? FileManager.default.removeItem(at: socketURL)
        }

        let response = try Self.roundTrip(
            socketPath: socketURL.path,
            request:
                #"{"token":"\#(token)","command":"axPress","args":{"id":"row.1","action":"start"}}"#
        )
        let json = try #require(Self.parse(response))
        #expect(json["ok"] as? Bool == true)
        let pressed = try #require(await ops.lastPressed)
        #expect(pressed.id == "row.1")
        #expect(pressed.action == "start")
    }

    private static func makeServer(
        ops: FakeLatchOps,
        token: String = "test-latch-token"
    ) async throws -> (server: LatchServer, socketURL: URL, token: String) {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let socketURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-\(suffix).sock")
        let server = LatchServer(
            ops: ops,
            token: LatchToken(value: token),
            socketPath: socketURL
        )
        try await server.start()
        return (server, socketURL, token)
    }

    private static func roundTrip(socketPath: String, request: String) throws -> Data {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXTestError.systemCall(name: "socket", errno: errno)
        }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLimit = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < pathLimit else {
            throw POSIXTestError.socketPathTooLong(path: socketPath)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePointer in
            tuplePointer.withMemoryRebound(to: CChar.self, capacity: pathLimit) { charPointer in
                for index in 0..<pathBytes.count {
                    charPointer[index] = CChar(bitPattern: pathBytes[index])
                }
                charPointer[pathBytes.count] = 0
            }
        }
        let connectResult = withUnsafePointer(to: &addr) { addrPointer -> Int32 in
            addrPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(
                    fd,
                    sockaddrPointer,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard connectResult == 0 else {
            throw POSIXTestError.systemCall(name: "connect", errno: errno)
        }

        var framed = Data(request.utf8)
        framed.append(0x0A)
        framed.withUnsafeBytes { buffer in
            guard var base = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.send(fd, base, remaining, 0)
                if written <= 0 { return }
                base = base.advanced(by: written)
                remaining -= written
            }
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let read = chunk.withUnsafeMutableBufferPointer { pointer -> Int in
                guard let base = pointer.baseAddress else { return 0 }
                return Darwin.recv(fd, base, pointer.count, 0)
            }
            if read <= 0 { break }
            response.append(chunk, count: read)
            if response.last == 0x0A { break }
        }
        return response
    }

    private static func parse(_ data: Data) -> [String: Any]? {
        var trimmed = data
        if trimmed.last == 0x0A { trimmed.removeLast() }
        guard
            let object = try? JSONSerialization.jsonObject(with: trimmed),
            let dict = object as? [String: Any]
        else { return nil }
        return dict
    }
}

actor FakeLatchOps: LatchOpsProviding {
    var screenshotPath = "/tmp/shot.png"
    var screenshotWindows: [String] = []
    var lastPressed: (id: String, action: String?)?

    func setScreenshotPath(_ path: String) { screenshotPath = path }

    func queryBoot() async -> String { "ready" }
    func queryWindows() async -> [LatchWindowStatus] { [] }
    func showWindow(_ name: String) async throws {}
    func hideWindow(_ name: String) async throws {}
    func axDump(window: String?, labeled: Bool) async throws -> LatchAXNode {
        LatchAXNode(
            id: nil, role: "application", title: "Notes", value: nil, enabled: true,
            actions: [], frame: .zero, children: [])
    }
    func axFind(id: String) async throws -> LatchAXNode {
        throw LatchError.elementNotFound(id: id)
    }
    func axPress(id: String, action: String?) async throws {
        lastPressed = (id, action)
    }
    func axSet(id: String, value: String) async throws {}
    func screenshot(window: String) async throws -> String {
        screenshotWindows.append(window)
        return screenshotPath
    }
}

private enum POSIXTestError: Error, CustomStringConvertible {
    case systemCall(name: String, errno: Int32)
    case socketPathTooLong(path: String)

    var description: String {
        switch self {
        case .systemCall(let name, let code):
            return "POSIX \(name) failed (errno=\(code))"
        case .socketPathTooLong(let path):
            return "Socket path too long for sockaddr_un: \(path)"
        }
    }
}
