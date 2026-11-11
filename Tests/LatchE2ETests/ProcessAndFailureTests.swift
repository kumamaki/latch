import Foundation
import Testing

@testable import LatchE2E

@Suite(.serialized)
struct ProcessAndFailureTests {
    private struct Boom: Error {}

    private func app(journey: Journey? = nil) throws -> LatchApp {
        LatchApp(
            config: LatchApp.Config(
                executableURL: try DragJourneyTests.fixtureBinary(), slug: "drag-fixture"),
            journey: journey)
    }

    @Test("a failed run writes the catalog values and the recent diffs")
    func failureReport() async throws {
        let journey = try Journey(scenario: "failure-report")
        let app = try app(journey: journey)

        await #expect(throws: Boom.self) {
            try await app.run { app in
                try await app.press("flip.fast")
                throw Boom()
            }
        }

        let data = try Data(
            contentsOf: await journey.directory.appendingPathComponent("failure.json"))
        let report = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(report["catalog"]?["flip.state"]?["value"]?.stringValue != nil)
        #expect(
            report["recentDiffs"]?.arrayValue?.first?.stringValue?.hasPrefix("axPress flip.fast")
                == true)
    }

    @Test("killNow ends the app and waitForTermination sees it")
    func killNow() async throws {
        let app = try app()
        try await app.launch()
        #expect(await app.isRunning)

        await app.killNow()

        #expect(await app.waitForTermination(timeout: 5))
        #expect(await !app.isRunning)
        await app.terminate()
    }
}
