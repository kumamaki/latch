import AppKit
import Testing

@testable import Latch

struct LatchKeysTests {
    @Test(
        "a name resolves to one key code, and a bad name or modifier fails loud",
        arguments: [
            ("k", UInt16(40)), ("0", 29), ("return", 36), ("escape", 53), ("left", 123),
        ])
    func resolves(name: String, keyCode: UInt16) throws {
        #expect(try LatchKey.stroke(named: name).keyCode == keyCode)
    }

    @Test("unknown key and modifier names are refused")
    func refusesUnknown() throws {
        #expect(throws: LatchError.self) { try LatchKey.stroke(named: "K") }
        #expect(throws: LatchError.self) { try LatchKey.stroke(named: "f13") }
        #expect(throws: LatchError.self) { try LatchKey.flags(["cmd"]) }
        #expect(try LatchKey.flags(["command", "shift"]) == [.command, .shift])
    }
}
