import Foundation
import Testing

@testable import Latch

@Suite(.serialized)
struct LatchCLITests {

    @Test("missing slug fails loud")
    func missingSlugFails() throws {
        let result = try runCLI(
            arguments: ["ping"],
            environment: ["LATCH_APP": nil],
            directory: FileManager.default.temporaryDirectory
        )
        #expect(result.status == 1)
        #expect(result.stderr.contains(".latch.json"))
        #expect(result.stderr.contains("--app"))
    }

    @Test("invalid latch json fails before a parent file")
    func invalidSlugFileFailsLoud() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"app":"parent"}"#.utf8).write(
            to: root.appendingPathComponent(".latch.json"))
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: child.appendingPathComponent(".latch.json"))

        let result = try runCLI(
            arguments: ["ping"],
            environment: ["LATCH_APP": nil],
            directory: child
        )
        #expect(result.status == 1)
        #expect(result.stderr.contains("not valid JSON"))
        #expect(!result.stderr.contains("parent-dev"))
    }

    @Test("missing app key in latch json fails loud")
    func missingAppKeyFailsLoud() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"slug":"notes"}"#.utf8).write(
            to: directory.appendingPathComponent(".latch.json"))

        let result = try runCLI(
            arguments: ["ping"],
            environment: ["LATCH_APP": nil],
            directory: directory
        )
        #expect(result.status == 1)
        #expect(result.stderr.contains("missing a non-empty app string"))
    }

    @Test("doctor with a bad slug names the missing token and socket")
    func doctorBadSlug() throws {
        let app = uniqueApp()
        let result = try runCLI(arguments: ["--app", app, "doctor"])
        #expect(result.status == 1)
        #expect(result.stdout.contains("slug: \(app)"))
        #expect(result.stdout.contains("slug_from: --app"))
        #expect(result.stdout.contains("token_exists: false"))
        #expect(result.stdout.contains("socket_listening: false"))
        #expect(result.stdout.contains("next: token missing"))
        #expect(result.stdout.contains("\(app)-dev/latch.token"))
        #expect(result.stdout.contains("\(app)-dev/latch.sock"))
    }

    @Test("ping health, doctor, ids, and wait value use the slug file")
    func dailyLoopAgainstLiveSocket() async throws {
        let app = uniqueApp()
        let directory = try makeTempDirectory()
        let (server, ops, dataDirectory) = try await startServer(app: app)
        defer {
            Task { await server.stop() }
            try? FileManager.default.removeItem(at: dataDirectory)
            try? FileManager.default.removeItem(at: directory)
        }
        try Data("{\"app\":\"\(app)\"}".utf8).write(
            to: directory.appendingPathComponent(".latch.json"))

        try withExtendedLifetime(ops) {
            let ping = try runCLI(
                arguments: ["ping"],
                environment: ["LATCH_APP": nil],
                directory: directory
            )
            #expect(ping.status == 0)
            let pingJSON = try #require(parseJSON(ping.stdout))
            #expect(pingJSON["status"] as? String == "ok")
            #expect(pingJSON["boot"] as? String == "ready")
            #expect(pingJSON["windows"] as? Int == 1)
            #expect(pingJSON["catalog"] as? Int == 3)

            let doctor = try runCLI(
                arguments: ["doctor"],
                environment: ["LATCH_APP": nil],
                directory: directory
            )
            #expect(doctor.status == 0)
            #expect(doctor.stdout.contains("slug: \(app)"))
            #expect(doctor.stdout.contains("slug_from: .latch.json"))
            #expect(doctor.stdout.contains("boot: ready"))
            #expect(doctor.stdout.contains("windows: 1"))
            #expect(doctor.stdout.contains("catalog: 3"))
            #expect(doctor.stdout.contains("next: ok"))

            let ids = try runCLI(
                arguments: ["ids"],
                environment: ["LATCH_APP": nil],
                directory: directory
            )
            #expect(ids.status == 0)
            #expect(ids.stdout.contains("| Id | Surface |"))
            #expect(ids.stdout.contains("`window.main`"))
            #expect(ids.stdout.contains("`editor.title`"))
            #expect(ids.stdout.contains("`prefs.appearance.dark`"))

            let before = try runCLI(
                arguments: [
                    "wait", "ax", "prefs.appearance.dark", "--value", "true", "--timeout", "1",
                ],
                environment: ["LATCH_APP": nil],
                directory: directory
            )
            #expect(before.status == 1)
            #expect(before.stderr.contains("timeout"))

            let set = try runCLI(
                arguments: ["ax", "set", "prefs.appearance.dark", "true"],
                environment: ["LATCH_APP": nil],
                directory: directory
            )
            #expect(set.status == 0)

            let wait = try runCLI(
                arguments: ["wait", "ax", "prefs.appearance.dark", "--value", "true"],
                environment: ["LATCH_APP": nil],
                directory: directory
            )
            #expect(wait.status == 0)
            #expect(wait.stdout.contains("ready: ax prefs.appearance.dark value=true"))
        }
    }

    @Test("flag app wins over latch json")
    func flagWinsOverSlugFile() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"app":"from-file"}"#.utf8).write(
            to: directory.appendingPathComponent(".latch.json"))
        let result = try runCLI(
            arguments: ["--app", "from-flag", "doctor"],
            environment: ["LATCH_APP": "from-env"],
            directory: directory
        )
        #expect(result.status == 1)
        #expect(result.stdout.contains("slug: from-flag"))
        #expect(result.stdout.contains("slug_from: --app"))
    }

    @Test("LATCH_APP wins over latch json")
    func envWinsOverSlugFile() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"app":"from-file"}"#.utf8).write(
            to: directory.appendingPathComponent(".latch.json"))
        let result = try runCLI(
            arguments: ["doctor"],
            environment: ["LATCH_APP": "from-env"],
            directory: directory
        )
        #expect(result.status == 1)
        #expect(result.stdout.contains("slug: from-env"))
        #expect(result.stdout.contains("slug_from: LATCH_APP"))
    }

    private func uniqueApp() -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return "latch-cli-\(suffix)"
    }

    private func startServer(app: String) async throws -> (
        LatchServer, FakeLatchOps, URL
    ) {
        let dataDirectory = try LatchPaths.directory(app: app)
        try FileManager.default.createDirectory(
            at: dataDirectory, withIntermediateDirectories: true)
        let tokenURL = try LatchPaths.tokenFile(app: app)
        let token = try LatchToken.loadOrGenerate(at: tokenURL)
        let socketURL = try LatchPaths.socket(app: app)
        let ops = FakeLatchOps()
        let server = LatchServer(
            ops: ops,
            token: token,
            socketPath: socketURL
        )
        try await server.start()
        return (server, ops, dataDirectory)
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func parseJSON(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        else { return nil }
        return dict
    }

    private func runCLI(
        arguments: [String],
        environment: [String: String?] = [:],
        directory: URL? = nil
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.cliPath] + arguments
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            if let value {
                env[key] = value
            } else {
                env.removeValue(forKey: key)
            }
        }
        process.environment = env
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                ?? "",
            String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                ?? ""
        )
    }

    private static let cliPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("cli/latch.sh")
        .path
}
