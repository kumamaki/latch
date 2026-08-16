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
        let data = try #require(json["data"] as? [String: Any])
        #expect(data["status"] as? String == "ok")
        #expect(data["boot"] as? String == "ready")
        #expect(data["windows"] as? Int == 1)
        #expect(data["catalog"] as? Int == 3)
        let dumps = await ops.dumpCalls
        #expect(dumps.count == 1)
        #expect(dumps[0].window == nil)
        #expect(dumps[0].labeled)
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
    var dumpCalls: [(window: String?, labeled: Bool)] = []
    var bootState = "ready"
    var windowItems = [
        LatchWindowStatus(name: "main", visible: true, exists: true)
    ]
    var dumpRoot = LatchAXNode(
        id: nil,
        role: "application",
        title: "Notes",
        value: nil,
        enabled: true,
        actions: [],
        frame: .zero,
        children: [
            LatchAXNode(
                id: "window.main", role: "window", title: "Notes", value: nil,
                enabled: true, actions: [], frame: .zero,
                children: [
                    LatchAXNode(
                        id: "editor.title", role: "textfield", title: "Title",
                        value: "", enabled: true, actions: ["set"], frame: .zero,
                        children: []),
                    LatchAXNode(
                        id: "prefs.appearance.dark", role: "checkbox",
                        title: "Dark mode", value: "false", enabled: true,
                        actions: ["set"], frame: .zero, children: []),
                ]
            )
        ]
    )

    func setScreenshotPath(_ path: String) { screenshotPath = path }
    func setBootState(_ state: String) { bootState = state }
    func setWindowItems(_ items: [LatchWindowStatus]) { windowItems = items }
    func setDumpRoot(_ root: LatchAXNode) { dumpRoot = root }

    func queryBoot() async -> String { bootState }
    func queryWindows() async -> [LatchWindowStatus] { windowItems }
    func showWindow(_ name: String) async throws {}
    func hideWindow(_ name: String) async throws {}
    func axDump(window: String?, labeled: Bool) async throws -> LatchAXNode {
        dumpCalls.append((window, labeled))
        return dumpRoot
    }
    func axFind(id: String) async throws -> LatchAXNode {
        guard let node = dumpRoot.first(id: id) else {
            throw LatchError.elementNotFound(id: id)
        }
        return node
    }
    func axPress(id: String, action: String?) async throws {
        lastPressed = (id, action)
    }
    func axSet(id: String, value: String) async throws {
        guard dumpRoot.first(id: id) != nil else {
            throw LatchError.elementNotFound(id: id)
        }
        dumpRoot = dumpRoot.replacing(id: id, value: value)
    }
    func screenshot(window: String) async throws -> String {
        screenshotWindows.append(window)
        return screenshotPath
    }
}

extension LatchAXNode {
    func first(id: String) -> LatchAXNode? {
        if self.id == id { return self }
        for child in children {
            if let found = child.first(id: id) { return found }
        }
        return nil
    }

    func replacing(id: String, value: String) -> LatchAXNode {
        LatchAXNode(
            id: self.id,
            role: role,
            title: title,
            value: self.id == id ? value : self.value,
            enabled: enabled,
            actions: actions,
            frame: frame,
            children: children.map { $0.replacing(id: id, value: value) },
            window: window,
            kind: kind,
            choices: choices,
            description: description
        )
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
