import Foundation

/// App-under-test lifecycle. Launches the binary with a fresh
/// LATCH_DATA_DIR, waits for the kernel socket to come up, and tears
/// everything down. Replaces the plist launch / cleanup glue that
/// lived in e2e setup scripts.
public actor LatchApp {
    public struct Config: Sendable {
        public var executableURL: URL
        public var slug: String
        public var arguments: [String]
        public var environment: [String: String]
        /// queryBoot state that means "ready to drive".
        public var bootState: String

        public init(
            executableURL: URL,
            slug: String,
            arguments: [String] = [],
            environment: [String: String] = [:],
            bootState: String = "ready"
        ) {
            self.executableURL = executableURL
            self.slug = slug
            self.arguments = arguments
            self.environment = environment
            self.bootState = bootState
        }
    }

    public let config: Config
    private let journey: Journey?
    private var process: Process?
    private var client: LatchSocketClient?
    private var dataDir: URL?

    public init(config: Config, journey: Journey? = nil) {
        self.config = config
        self.journey = journey
    }

    /// Launch + body + teardown in one call. On failure: screenshot,
    /// failure.json, junit.xml, teardown, rethrow — the journey always
    /// ends complete and the real error always propagates.
    public func run(_ body: @Sendable (LatchApp) async throws -> Void) async throws {
        do {
            try await launch()
            try await body(self)
        } catch {
            var shotPath: URL?
            do {
                shotPath = try await screenshot(window: "main")
            } catch {
                // The app may already be gone. The diagnostic below must
                // not mask the test failure we are unwinding with.
                try? await journey?.recordNote("failure screenshot unavailable: \(error)")
            }
            try? await journey?.recordFailure(error, shotPath: shotPath)
            try? await journey?.finish()
            await terminate()
            throw error
        }
        await terminate()
        try await journey?.finish()
    }

    // MARK: - Lifecycle

    public func launch() async throws {
        guard process == nil else {
            throw LatchE2EError.invalidConfig(reason: "launch() called twice")
        }
        // sun_path caps at 104 bytes and the macOS per-user temp root
        // already eats ~70, so keep the name short. The slug prefix is
        // for humans digging through /tmp; uniqueness comes from entropy.
        let slugPrefix = String(config.slug.prefix(8))
        let entropy = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-\(slugPrefix)-\(entropy)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        dataDir = dir

        let logURL = journey?.appLogURL ?? dir.appendingPathComponent("app.log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
            throw LatchE2EError.appLaunch(reason: "cannot create app log at \(logURL.path)")
        }
        guard let logHandle = FileHandle(forWritingAtPath: logURL.path) else {
            throw LatchE2EError.appLaunch(reason: "cannot open app log at \(logURL.path)")
        }

        let process = Process()
        process.executableURL = config.executableURL
        process.arguments = config.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LATCH_DATA_DIR"] = dir.path
        for (key, value) in config.environment {
            environment[key] = value
        }
        process.environment = environment
        // One shared file description for stdout + stderr, so both
        // streams append to app.log in write order.
        process.standardOutput = logHandle
        process.standardError = logHandle
        do {
            try process.run()
        } catch {
            throw LatchE2EError.appLaunch(reason: "\(config.executableURL.path): \(error)")
        }
        self.process = process

        let endpoint = LatchEndpoint.resolve(slug: config.slug, dataDir: dir)
        try await waitForSocket(endpoint: endpoint, process: process)
        client = LatchSocketClient(endpoint: endpoint)
        try await waitBoot(state: config.bootState, timeout: 30)
    }

    public func waitBoot(state: String, timeout: TimeInterval = 30) async throws {
        guard let process else {
            throw LatchE2EError.invalidConfig(reason: "waitBoot needs a launched app")
        }
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            if !process.isRunning {
                throw LatchE2EError.appLaunch(
                    reason: "exited with \(process.terminationStatus) during boot")
            }
            do {
                let data = try await send("queryBoot", record: false)
                let boot = data["state"]?.stringValue
                if boot == state { return }
                if boot == "failed" {
                    throw LatchE2EError.appLaunch(reason: "boot failed on the host side")
                }
            } catch let error as LatchE2EError {
                // Socket-level failures right after the files appear are
                // a boot race — keep polling. Server errors are real.
                if error.serverCode != nil { throw error }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw LatchE2EError.timeout(label: "boot state \(state)", detail: "")
    }

    public func waitWindow(
        _ name: String,
        visible: Bool = true,
        timeout: TimeInterval = 10
    ) async throws {
        try await pollUntil(
            label: "window \(name) \(visible ? "visible" : "hidden")",
            timeout: timeout,
            // Window visibility is not in the catalog dump; the stall
            // detector has no signal here.
            stallWindow: nil
        ) {
            guard
                let item = try await self.windows().first(where: { $0.name == name })
            else { return false }
            return item.exists && item.visible == visible
        }
    }

    public func terminate() async {
        guard let process else { return }
        client = nil
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        self.process = nil
        if let dataDir {
            // Ephemeral temp dir owned by this run; FileManager is the
            // right tool for it. Trashing /tmp scratch would be noise.
            try? FileManager.default.removeItem(at: dataDir)
            self.dataDir = nil
        }
    }

    private func waitForSocket(endpoint: LatchEndpoint, process: Process) async throws {
        let deadline = Date().addingTimeInterval(15)
        while true {
            let tokenThere = FileManager.default.fileExists(atPath: endpoint.tokenFile.path)
            let socketThere = FileManager.default.fileExists(atPath: endpoint.socket.path)
            if tokenThere && socketThere { return }
            if !process.isRunning {
                throw LatchE2EError.appLaunch(
                    reason: "exited with \(process.terminationStatus) before the socket came up")
            }
            if Date() >= deadline {
                throw LatchE2EError.timeout(
                    label: "socket at \(endpoint.socket.path)",
                    detail: "token or socket never appeared.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Kernel surface

    public func press(_ id: String, action: String? = nil) async throws {
        let args: [String: JSONValue] =
            action.map { ["id": .string(id), "action": .string($0)] }
            ?? ["id": .string(id)]
        try await withDiff(action: "axPress", id: id) {
            _ = try await self.send("axPress", args: args)
        }
    }

    public func set(_ id: String, value: String) async throws {
        try await withDiff(action: "axSet", id: id) {
            _ = try await self.send("axSet", args: ["id": .string(id), "value": .string(value)])
        }
    }

    public func show(_ window: String) async throws {
        _ = try await send("windowShow", args: ["window": .string(window)])
    }

    public func hide(_ window: String) async throws {
        _ = try await send("windowHide", args: ["window": .string(window)])
    }

    @discardableResult
    public func screenshot(window: String = "main") async throws -> URL {
        let data = try await send("screenshot", args: ["window": .string(window)])
        guard let path = data["path"]?.stringValue else {
            throw LatchE2EError.server(
                code: "protocol", message: "screenshot response without path")
        }
        let url = URL(fileURLWithPath: path)
        return try await journey?.recordShot(url) ?? url
    }

    /// Labeled dump flattened to id+value+enabled. The diff baseline
    /// and the stall detector's input.
    public func snapshot() async throws -> CatalogSnapshot {
        let data = try await send("axDump", args: ["labeled": .bool(true)], record: false)
        guard let root = data["root"] else {
            throw LatchE2EError.server(
                code: "protocol", message: "axDump response without root")
        }
        return CatalogSnapshot(dump: root)
    }

    /// axFind mapped to nil on a catalog miss, so expectations can poll
    /// instead of catching.
    public func node(_ id: String) async throws -> CatalogNode? {
        do {
            let data = try await send("axFind", args: ["id": .string(id)], record: false)
            guard let json = data["node"] else { return nil }
            return CatalogNode(json: json)
        } catch let error as LatchE2EError {
            if error.serverCode == "notFound" { return nil }
            throw error
        }
    }

    public struct WindowStatus: Sendable, Equatable {
        public let name: String
        public let visible: Bool
        public let exists: Bool
    }

    public func windows() async throws -> [WindowStatus] {
        let data = try await send("queryWindows", record: false)
        let items = data["items"]?.arrayValue ?? []
        return items.compactMap { item in
            guard let name = item["name"]?.stringValue else { return nil }
            return WindowStatus(
                name: name,
                visible: item["visible"]?.boolValue ?? false,
                exists: item["exists"]?.boolValue ?? false
            )
        }
    }

    public func expect(_ id: String) -> Expectation {
        Expectation(app: self, id: id)
    }

    /// Arbitrary predicate polling — the Den-proof escape hatch.
    /// Retries until the predicate holds or the timeout fires.
    public func poll(
        _ label: String,
        timeout: TimeInterval = 10,
        interval: TimeInterval = 0.2,
        stallWindow: TimeInterval? = 5,
        _ condition: @Sendable (LatchApp) async throws -> Bool
    ) async throws {
        try await pollUntil(
            label: label, timeout: timeout, interval: interval, stallWindow: stallWindow
        ) {
            try await condition(self)
        }
    }

    // MARK: - Internals

    private func withDiff(
        action: String,
        id: String,
        _ mutate: @Sendable () async throws -> Void
    ) async throws {
        let before = try await snapshot()
        try await mutate()
        let after = try await snapshot()
        try await journey?.recordDiff(
            after.diffed(from: before), action: action, id: id, after: after)
    }

    private func send(
        _ command: String,
        args: [String: JSONValue] = [:],
        record: Bool = true
    ) async throws -> JSONValue {
        guard let client else {
            throw LatchE2EError.invalidConfig(
                reason: "app not launched; call run(_:) or launch() first")
        }
        let started = Date()
        do {
            let data = try await client.send(command, args: args)
            if record {
                try await journey?.recordCommand(
                    command, ok: true, seconds: Date().timeIntervalSince(started), error: nil)
            }
            return data
        } catch {
            if record {
                try await journey?.recordCommand(
                    command, ok: false, seconds: Date().timeIntervalSince(started),
                    error: String(describing: error))
            }
            throw error
        }
    }

    func recordExpectation(
        label: String, outcome: String, attempts: Int, detail: String?
    ) async throws {
        try await journey?.recordExpectation(
            label: label, outcome: outcome, attempts: attempts, detail: detail)
    }

    func pollUntil(
        label: String,
        timeout: TimeInterval,
        interval: TimeInterval = 0.2,
        stallWindow: TimeInterval? = 5,
        _ condition: @Sendable () async throws -> Bool
    ) async throws {
        var attempts = 0
        var watcher = StallWatcher(window: stallWindow)
        let started = Date()
        while true {
            attempts += 1
            if try await condition() {
                try await journey?.recordExpectation(
                    label: label, outcome: "pass", attempts: attempts, detail: nil)
                return
            }
            let elapsed = Date().timeIntervalSince(started)
            if elapsed >= timeout {
                let movement =
                    watcher.lastSummary
                    .map { "Last catalog movement: \($0)." }
                    ?? "No catalog movement observed."
                try await journey?.recordExpectation(
                    label: label, outcome: "timeout", attempts: attempts, detail: movement)
                throw LatchE2EError.timeout(
                    label: label,
                    detail:
                        "polled \(attempts) times in \(String(format: "%.1f", elapsed))s. \(movement)"
                )
            }
            if let dumped = try? await snapshot(),
                let stalled = watcher.check(snapshot: dumped, at: Date())
            {
                // A failed dump only skips the stall check; the next
                // condition call surfaces the real error.
                try await journey?.recordExpectation(
                    label: label, outcome: "stalled", attempts: attempts,
                    detail: stalled.description)
                throw stalled
            }
            try await Task.sleep(for: .milliseconds(Int(interval * 1000)))
        }
    }
}
