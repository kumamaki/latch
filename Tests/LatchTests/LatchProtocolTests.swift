import Foundation
import Testing

@testable import Latch

@Suite
struct LatchProtocolTests {
    private let decoder = JSONDecoder()

    @Test("decodes ping with no args")
    func ping() throws {
        let json = Data(#"{"token":"abc","command":"ping"}"#.utf8)
        let request = try decoder.decode(LatchRequest.self, from: json)
        #expect(request.token == "abc")
        guard case .ping = request.command else {
            Issue.record("expected .ping, got \(request.command)")
            return
        }
    }

    @Test("decodes screenshot")
    func screenshot() throws {
        let json = Data(
            #"""
            {"token":"abc","command":"screenshot","args":{"window":"main"}}
            """#.utf8)
        let request = try decoder.decode(LatchRequest.self, from: json)
        guard case .screenshot(let window) = request.command else {
            Issue.record("expected .screenshot, got \(request.command)")
            return
        }
        #expect(window == "main")
    }

    @Test("decodes axPress with named action")
    func axPressNamed() throws {
        let json = Data(
            #"""
            {"token":"abc","command":"axPress","args":{"id":"row.1","action":"start"}}
            """#.utf8)
        let request = try decoder.decode(LatchRequest.self, from: json)
        guard case .axPress(let id, let action) = request.command else {
            Issue.record("expected .axPress, got \(request.command)")
            return
        }
        #expect(id == "row.1")
        #expect(action == "start")
    }

    @Test("decodes axDump labeled")
    func axDumpLabeled() throws {
        let json = Data(
            #"""
            {"token":"abc","command":"axDump","args":{"window":"main","labeled":true}}
            """#.utf8)
        let request = try decoder.decode(LatchRequest.self, from: json)
        guard case .axDump(let window, let labeled) = request.command else {
            Issue.record("expected .axDump, got \(request.command)")
            return
        }
        #expect(window == "main")
        #expect(labeled)
    }

    @Test("decodes axSet")
    func axSet() throws {
        let json = Data(
            #"""
            {"token":"abc","command":"axSet","args":{"id":"editor.title","value":"Hello"}}
            """#.utf8)
        let request = try decoder.decode(LatchRequest.self, from: json)
        guard case .axSet(let id, let value) = request.command else {
            Issue.record("expected .axSet, got \(request.command)")
            return
        }
        #expect(id == "editor.title")
        #expect(value == "Hello")
    }

    @Test("unknown command is LatchError.unknownCommand")
    func unknownCommand() {
        let json = Data(#"{"token":"abc","command":"explode"}"#.utf8)
        do {
            _ = try decoder.decode(LatchRequest.self, from: json)
            Issue.record("expected decode to throw")
        } catch let error as LatchError {
            guard case .unknownCommand(let name) = error else {
                Issue.record("expected unknownCommand, got \(error)")
                return
            }
            #expect(name == "explode")
        } catch {
            Issue.record("expected LatchError, got \(error)")
        }
    }

    @Test("success envelope encodes ok:true")
    func successEnvelope() throws {
        let data = try JSONEncoder().encode(
            LatchResponse.success(.pong(boot: "ready", windows: 1, catalog: 3))
        )
        let object = try JSONSerialization.jsonObject(with: data)
        let dict = try #require(object as? [String: Any])
        #expect(dict["ok"] as? Bool == true)
        let payload = try #require(dict["data"] as? [String: Any])
        #expect(payload["status"] as? String == "ok")
        #expect(payload["boot"] as? String == "ready")
        #expect(payload["windows"] as? Int == 1)
        #expect(payload["catalog"] as? Int == 3)
    }

    @Test("catalogCount skips the application root")
    func catalogCountSkipsApplicationRoot() {
        let leaf = LatchAXNode(
            id: "editor.save",
            role: "button",
            title: "Save",
            value: nil,
            enabled: true,
            actions: ["press"],
            frame: .zero,
            children: []
        )
        let window = LatchAXNode(
            id: "window.main",
            role: "window",
            title: "Notes",
            value: nil,
            enabled: true,
            actions: [],
            frame: .zero,
            children: [leaf]
        )
        let root = LatchAXNode(
            id: nil,
            role: "application",
            title: "Notes",
            value: nil,
            enabled: true,
            actions: [],
            frame: .zero,
            children: [window]
        )
        #expect(root.catalogCount == 2)
        #expect(window.catalogCount == 2)
    }
}
