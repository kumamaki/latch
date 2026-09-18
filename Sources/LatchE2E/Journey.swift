import Foundation

/// One run's evidence directory — the trace is the product:
///
///     .latch-trace/<scenario>-<timestamp>/
///         trace.jsonl   one event per command, step, expectation, failure
///         diffs/        catalog added/removed/changed per mutating action
///         shots/        screenshots, copied next to the evidence
///         junit.xml     CI reporting
///         failure.json  got/want + last diff + catalog + shot on first failure
///         app.log       the app's own stdout + stderr
public actor Journey {
    public let directory: URL
    private let scenario: String
    private let traceHandle: FileHandle
    private var steps: [StepRecord] = []
    private var lastDiff: CatalogDiff?
    private var lastCatalogIds: [String] = []
    private var failureRecorded = false
    private var diffCounter = 0
    private var shotCounter = 0

    private struct StepRecord {
        let label: String
        let seconds: Double
        let failed: Bool
        let message: String?
    }

    /// - Parameters:
    ///   - scenario: names the directory; non-alphanumerics become `-`.
    ///   - root: trace root. Defaults to `.latch-trace/` in the cwd.
    public init(scenario: String, root: URL? = nil) throws {
        self.scenario = scenario
        let slug = String(
            scenario.map { character in
                character.isLetter || character.isNumber ? character : "-"
            })
        let base =
            root
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".latch-trace", isDirectory: true)
        directory = base.appendingPathComponent(
            "\(slug)-\(Self.stamp(Date()))", isDirectory: true)

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let trace = directory.appendingPathComponent("trace.jsonl")
        guard FileManager.default.createFile(atPath: trace.path, contents: nil) else {
            throw LatchE2EError.trace(reason: "cannot create \(trace.path)")
        }
        guard let handle = FileHandle(forWritingAtPath: trace.path) else {
            throw LatchE2EError.trace(reason: "cannot open \(trace.path)")
        }
        traceHandle = handle

        let appLog = directory.appendingPathComponent("app.log")
        guard FileManager.default.createFile(atPath: appLog.path, contents: nil) else {
            throw LatchE2EError.trace(reason: "cannot create \(appLog.path)")
        }
    }

    nonisolated public var appLogURL: URL {
        directory.appendingPathComponent("app.log")
    }

    /// Named scenario step with timing and failure capture. The DSL
    /// marker that keeps a trace readable.
    public func step(_ label: String, _ body: @Sendable () async throws -> Void) async throws {
        let started = Date()
        do {
            try await body()
            steps.append(
                StepRecord(
                    label: label, seconds: Date().timeIntervalSince(started),
                    failed: false, message: nil))
            try append([
                "event": .string("step"),
                "label": .string(label),
                "phase": .string("end"),
                "seconds": .number(Date().timeIntervalSince(started)),
            ])
        } catch {
            let message = String(describing: error)
            steps.append(
                StepRecord(
                    label: label, seconds: Date().timeIntervalSince(started),
                    failed: true, message: message))
            try? append([
                // Diagnostic write during error unwinding; the primary
                // failure below must win.
                "event": .string("step"),
                "label": .string(label),
                "phase": .string("failed"),
                "error": .string(message),
            ])
            throw error
        }
    }

    /// Close the run: write junit.xml. run(_:) calls this for you.
    public func finish() throws {
        var cases = ""
        for step in steps {
            var item = "<testcase name=\"\(Self.escape(step.label))\""
            item += " classname=\"\(Self.escape(scenario))\""
            item += " time=\"\(String(format: "%.3f", step.seconds))\""
            if step.failed {
                item +=
                    "><failure message=\"\(Self.escape(step.message ?? "failed"))\"/></testcase>"
            } else {
                item += "/>"
            }
            cases += item
        }
        var failures = 0
        for step in steps where step.failed {
            failures += 1
        }
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuite name="\(Self.escape(scenario))" tests="\(steps.count)" failures="\(failures)">
            \(cases)
            </testsuite>
            """
        try xml.write(
            to: directory.appendingPathComponent("junit.xml"),
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - Harness recording (internal; LatchApp calls these)

    func recordCommand(
        _ command: String, ok: Bool, seconds: TimeInterval, error: String?
    ) throws {
        var event: [String: JSONValue] = [
            "event": .string("command"),
            "command": .string(command),
            "ok": .bool(ok),
            "seconds": .number(seconds),
        ]
        if let error {
            event["error"] = .string(error)
        }
        try append(event)
    }

    func recordDiff(_ diff: CatalogDiff, action: String, id: String, after: CatalogSnapshot) throws
    {
        lastDiff = diff
        lastCatalogIds = after.ids
        diffCounter += 1
        let fileID = id.replacingOccurrences(of: "/", with: "_")
        let destination =
            directory
            .appendingPathComponent("diffs", isDirectory: true)
            .appendingPathComponent(
                String(format: "%03d", diffCounter) + "-\(action)-\(fileID).json")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = JSONValue.object([
            "action": .string(action),
            "id": .string(id),
            "added": .array(diff.added.map(JSONValue.string)),
            "removed": .array(diff.removed.map(JSONValue.string)),
            "changed": .array(diff.changed.map(JSONValue.string)),
            "catalogIds": .array(after.ids.map(JSONValue.string)),
        ])
        try JSONEncoder().encode(payload).write(to: destination)
        try append([
            "event": .string("diff"),
            "action": .string(action),
            "id": .string(id),
            "summary": .string(diff.summary),
        ])
    }

    func recordExpectation(
        label: String, outcome: String, attempts: Int, detail: String?
    ) throws {
        var event: [String: JSONValue] = [
            "event": .string("expect"),
            "label": .string(label),
            "outcome": .string(outcome),
            "attempts": .number(Double(attempts)),
        ]
        if let detail {
            event["detail"] = .string(detail)
        }
        try append(event)
    }

    func recordShot(_ url: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        shotCounter += 1
        let destination =
            directory
            .appendingPathComponent("shots", isDirectory: true)
            .appendingPathComponent(
                String(format: "%03d", shotCounter) + "-\(url.lastPathComponent)")
        // Read + write, not copyfile: the kernel screenshot lands in
        // ~/Library/Logs/<app>-dev/latch/, where copyfile can be
        // refused even when stat and read are fine.
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let png = try Data(contentsOf: url)
        try png.write(to: destination, options: .atomic)
        try append(["event": .string("shot"), "path": .string(destination.path)])
        return destination
    }

    func recordNote(_ note: String) throws {
        try append(["event": .string("note"), "note": .string(note)])
    }

    func recordFailure(_ error: Error, shotPath: URL?) throws {
        guard !failureRecorded else { return }
        failureRecorded = true
        var payload: [String: JSONValue] = [
            "error": .string(String(describing: error)),
            "lastDiff": .string(lastDiff?.summary ?? "none"),
            "catalogIds": .array(lastCatalogIds.map(JSONValue.string)),
            "appLog": .string(appLogURL.path),
        ]
        if let shotPath {
            payload["shot"] = .string(shotPath.path)
        }
        try JSONEncoder()
            .encode(JSONValue.object(payload))
            .write(to: directory.appendingPathComponent("failure.json"))
        try append([
            "event": .string("failure"),
            "error": .string(String(describing: error)),
        ])
    }

    // MARK: - Helpers

    private func append(_ event: [String: JSONValue]) throws {
        var event = event
        event["at"] = .string(Date.now.formatted(.iso8601))
        var line = try JSONEncoder().encode(JSONValue.object(event))
        line.append(0x0A)
        try traceHandle.write(contentsOf: line)
    }

    private static func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// ISO8601 with separators stripped: `20260919T023541Z`. Colons
    /// would make the directory unreadable from Finder.
    private static func stamp(_ date: Date) -> String {
        date.formatted(.iso8601)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
    }
}
