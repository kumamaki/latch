import Foundation

/// Process-wide Latch host.
///
/// Two uses, one catalog:
/// - In-process: `snapshot` / `find` / `press` / `set` — always available.
/// - Outside agent: `start(app:)` binds a DEBUG-only unix socket.
@MainActor
public enum Latch {
    private static var server: LatchServer?
    private static var retainedOps: (any LatchOpsProviding)?
    private static var lifecycleTask: Task<Void, Never>?
    static var socketPhase: LatchSocketPhase = .idle
    static var failLoudOnStartFailure = true

    /// Bind the DEBUG socket. Release is a no-op. Does not affect the catalog.
    ///
    /// Idempotent while starting or listening. Boot stays `starting` until
    /// the socket is up; a failed bind reports `failed`.
    public static func start(
        app: String,
        ops: (any LatchOpsProviding)? = nil
    ) {
        #if DEBUG
            switch socketPhase {
            case .starting, .listening:
                return
            case .idle, .failed:
                break
            }
            socketPhase = .starting
            let resolved = ops ?? LatchDefaultOps(appName: app)
            let gated = LatchBootGatedOps(inner: resolved)
            retainedOps = gated
            let previous = lifecycleTask
            lifecycleTask = Task {
                await previous?.value
                do {
                    // The token is written before the server ensures the
                    // directory, so a first run must create it here.
                    try UnixSocketServer().ensureDirectory(
                        at: LatchPaths.directory(app: app))
                    let tokenURL = try LatchPaths.tokenFile(app: app)
                    let token = try LatchToken.loadOrGenerate(at: tokenURL)
                    let socketPath = try LatchPaths.socket(app: app)
                    let server = LatchServer(
                        ops: gated, token: token, socketPath: socketPath)
                    try await server.start()
                    self.server = server
                    self.socketPhase = .listening
                } catch {
                    self.socketPhase = .failed
                    if failLoudOnStartFailure {
                        assertionFailure("Latch failed to start: \(error)")
                    }
                }
            }
        #endif
    }

    /// Stop the socket. Safe to call when Latch never started.
    public static func stop() {
        #if DEBUG
            socketPhase = .idle
            let server = self.server
            self.server = nil
            retainedOps = nil
            let previous = lifecycleTask
            lifecycleTask = Task {
                await previous?.value
                await server?.stop()
            }
        #endif
    }

    static func resolvedBoot(host: String) -> String {
        socketPhase.resolvedBoot(host: host)
    }

    static func waitForLifecycle() async {
        await lifecycleTask?.value
    }

    /// Live catalog. Same nodes an outside agent would see in labeled dump.
    public static func snapshot(window: String? = nil) -> [LatchCatalog.Node] {
        LatchCatalog.snapshot(window: window)
    }

    public static func find(id: String) throws -> LatchCatalog.Node {
        try LatchCatalog.find(id: id)
    }

    public static func press(id: String, action: String? = nil) throws {
        try LatchCatalog.press(id: id, action: action)
    }

    public static func set(id: String, value: String) throws {
        try LatchCatalog.set(id: id, value: value)
    }
}
