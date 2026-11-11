import Foundation
import Testing

@testable import LatchE2E

struct TranscriptTests {
    @Test("a run's transcript lists steps, what each action changed, and refusals")
    func transcript() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-transcript-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let journey = try Journey(scenario: "transcript", root: root)

        try await journey.step("Open a menu") {
            try await journey.recordDiff(
                CatalogDiff(added: ["menu"], removed: [], changed: []),
                action: "mouseClick", id: "card", after: CatalogSnapshot(dump: .object([:])))
            try await journey.recordExpectation(
                label: "menu to appear", outcome: "pass", attempts: 1, detail: nil)
        }
        try await journey.step("Press a disabled row") {
            try await journey.recordCommand(
                "axPress", ok: false, seconds: 0, error: "Catalog entry row is disabled.")
        }
        try await journey.finish()

        let text = try String(
            contentsOf: await journey.directory.appendingPathComponent("transcript.txt"),
            encoding: .utf8)
        #expect(
            text == """
                Open a menu
                  mouseClick card  ->  added menu
                  expect menu to appear  pass

                Press a disabled row
                  axPress  refused: Catalog entry row is disabled.

                """)
    }
}
