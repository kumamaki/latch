import Foundation
import Testing

@testable import LatchE2E

/// Dogfood: drive the example Notes app through the LatchE2E harness.
/// Same surface scripts/e2e-notes.sh covers — onboarding, compose,
/// save — but through the typed runner with a journey per run.
@Suite("Notes dogfood", .serialized)
struct NotesE2ETests {
    @Test("compose, save, window dance, screenshot")
    func composeAndSave() async throws {
        let notes = try await NotesBuild.binary()

        let journey = try Journey(scenario: "notes-compose")
        let app = LatchApp(
            config: LatchApp.Config(executableURL: notes, slug: "notes"),
            journey: journey
        )
        try await app.run { app in
            try await app.expect("editor.title").toAppear(timeout: 30)

            try await journey.step("dark mode") {
                try await app.set("prefs.appearance.dark", value: "true")
                try await app.expect("prefs.appearance.dark").value("true")
            }

            try await journey.step("compose") {
                try await app.press("editor.new")
                try await app.expect("composer.title").toAppear()
                try await app.expect("composer.save").enabled(false)
            }

            try await journey.step("disabled save refuses") {
                await #expect(throws: LatchE2EError.self) {
                    try await app.press("composer.save")
                }
            }

            try await journey.step("save") {
                try await app.set("composer.title", value: "Hello")
                try await app.expect("composer.save").enabled()
                try await app.press("composer.save")
                try await app.expect("composer.save").toBeAbsent()
                try await app.expect("editor.title").value("Hello")
            }

            try await journey.step("window show hide") {
                try await app.hide("main")
                try await app.waitWindow("main", visible: false)
                try await app.show("main")
                try await app.waitWindow("main")
            }

            try await journey.step("screenshot") {
                let shot = try await app.screenshot(window: "main")
                #expect(FileManager.default.fileExists(atPath: shot.path))
            }
        }

        let artifacts = await journey.directory
        #expect(
            FileManager.default.fileExists(
                atPath: artifacts.appendingPathComponent("trace.jsonl").path))
        #expect(
            FileManager.default.fileExists(
                atPath: artifacts.appendingPathComponent("junit.xml").path))
        #expect(
            !FileManager.default.fileExists(
                atPath: artifacts.appendingPathComponent("failure.json").path))
        let diffs = try FileManager.default.contentsOfDirectory(
            at: artifacts.appendingPathComponent("diffs"), includingPropertiesForKeys: nil)
        #expect(diffs.contains { $0.lastPathComponent.contains("axPress-editor.new") })
    }

    @Test("through walks to the final state and reports misses")
    func throughTracksTransitions() async throws {
        let notes = try await NotesBuild.binary()

        let journey = try Journey(scenario: "notes-through")
        let app = LatchApp(
            config: LatchApp.Config(executableURL: notes, slug: "notes"),
            journey: journey
        )
        try await app.run { app in
            try await app.expect("editor.title").toAppear(timeout: 30)
            try await journey.step("sheet") {
                try await app.press("editor.new")
                try await app.expect("composer.title").toAppear()
            }
            try await journey.step("walk the title") {
                try await app.set("composer.title", value: "Draft")
                try await app.expect("composer.title").through(["Draft"])
            }
            try await journey.step("missed transition fails with observed") {
                await #expect(throws: LatchE2EError.self) {
                    try await app.expect("composer.title").through(
                        ["Draft", "Hello"], timeout: 1, stallWindow: nil)
                }
            }
        }
    }
}

/// Builds the example app before a run; swift build is incremental, so
/// a warm cache makes this cheap.
private enum NotesBuild {
    static func binary() async throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/LatchE2ETests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let notes = root.appendingPathComponent("examples/Notes")

        _ = try await swift(["build", "--package-path", notes.path, "--product", "Notes"])
        let binPath = try await swift(
            ["build", "--package-path", notes.path, "--show-bin-path"])
        let binary = URL(fileURLWithPath: binPath.trimmingCharacters(in: .whitespacesAndNewlines))
            .appendingPathComponent("Notes")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw LatchE2EError.appLaunch(
                reason:
                    "Notes binary missing at \(binary.path); run swift build --package-path examples/Notes --product Notes"
            )
        }
        return binary
    }

    private static func swift(_ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { handler in
                if handler.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: LatchE2EError.appLaunch(
                            reason:
                                "swift \(arguments.joined(separator: " ")) exited with \(handler.terminationStatus)"
                        ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: LatchE2EError.appLaunch(reason: "\(error)"))
            }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
