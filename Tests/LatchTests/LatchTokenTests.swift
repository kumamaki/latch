import Foundation
import Testing

@testable import Latch

@Suite
struct LatchTokenTests {
    @Test("matches is constant-time equality")
    func matches() {
        let token = LatchToken(value: "deadbeef")
        #expect(token.matches("deadbeef"))
        #expect(!token.matches("deadbeee"))
        #expect(!token.matches("deadbee"))
        #expect(!token.matches(""))
    }

    @Test("loadOrGenerate persists a 64-char hex token at 0600")
    func persists() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("latch.token")

        let first = try LatchToken.loadOrGenerate(at: url)
        #expect(first.value.count == 64)
        #expect(first.value.allSatisfy { $0.isHexDigit })

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.uint16Value == 0o600)

        let second = try LatchToken.loadOrGenerate(at: url)
        #expect(second == first)
    }
}
