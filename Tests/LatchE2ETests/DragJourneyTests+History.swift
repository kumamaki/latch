import Foundation
import Testing

@testable import LatchE2E

// An extension, not a suite of its own: both journeys launch DragFixture on
// the same socket slug, so they must run one after the other.
extension DragJourneyTests {
    @Test("history keeps a state that lasts 10 ms, through keeps up with a slow one")
    func historyJourney() async throws {
        let app = LatchApp(
            config: LatchApp.Config(
                executableURL: try DragJourneyTests.fixtureBinary(),
                slug: "drag-fixture"
            ),
            journey: try Journey(scenario: "value-history")
        )
        try await app.run { app in
            try await app.expect("flip.state").toAppear(timeout: 15)

            try await app.press("flip.fast")
            try await app.expect("flip.state").toHaveRecorded(["a", "b", "c"])

            try await app.press("flip.slow")
            try await app.expect("flip.state").through(["a", "b", "c"], timeout: 5)

            let recorded = try await app.history("flip.state")
            #expect(recorded.map(\.value) == ["a", "b", "c", "a", "b", "c"])
            #expect(
                recorded.map(\.milliseconds) == recorded.map(\.milliseconds).sorted())

            await #expect(throws: LatchE2EError.self) {
                try await app.history("gesture.well")
            }
        }
    }
}
