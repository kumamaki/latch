import Foundation
import Testing

@testable import LatchE2E

@Suite(.serialized)
struct DragJourneyTests {
    @Test("drag moves a token and a short drag stays a click")
    func dragJourney() async throws {
        let journey = try Journey(scenario: "drag-bins")
        let app = LatchApp(
            config: LatchApp.Config(
                executableURL: try Self.fixtureBinary(),
                slug: "drag-fixture"
            ),
            journey: journey
        )
        try await app.run { app in
            try await app.poll("gesture frame", timeout: 15) { app in
                guard let raw = try await app.node("gesture.frame")?.value else { return false }
                return parseFrame(raw) != nil
            }
            let raw = try #require(await app.node("gesture.frame")?.value)
            let frame = try #require(parseFrame(raw))
            let startX = frame.x + 12
            let startY = frame.y + frame.height / 2

            try await app.dragPoint(
                window: "main", x: startX, y: startY, toX: startX + 4, toY: startY)
            #expect(try await app.node("gesture.well")?.value == "0")

            try await app.dragPoint(
                window: "main", x: startX, y: startY, toX: startX + 40, toY: startY)
            try await app.poll("gesture distance", timeout: 5) { app in
                let raw = try await app.node("gesture.well")?.value ?? "0"
                return (Int(raw) ?? 0) >= 10
            }

            let started = Date()
            try await app.dragSession(from: "bin.source", to: "bin.dest")
            #expect(Date().timeIntervalSince(started) < 5)
            try await app.poll("token moved", timeout: 5) { app in
                let dest = try await app.node("bin.dest")?.value
                let row = try await app.node("bin.source.row")?.value
                let source = try await app.node("bin.source")?.value
                return dest == "token" && row == "idle" && source == ""
            }
        }
    }

    private static func fixtureBinary() throws -> URL {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            repo.appendingPathComponent(".build/out/Products/Debug/DragFixture"),
            repo.appendingPathComponent(".build/debug/DragFixture"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(
                "DragFixture"),
        ]
        guard
            let candidate = candidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path)
            })
        else {
            throw LatchE2EError.invalidConfig(
                reason:
                    "DragFixture binary not built (\(candidates.map(\.path).joined(separator: ", ")))."
            )
        }
        return candidate
    }
}

private func parseFrame(_ raw: String) -> (x: Double, y: Double, width: Double, height: Double)? {
    let parts = raw.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return nil }
    return (parts[0], parts[1], parts[2], parts[3])
}
