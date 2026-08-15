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

    /// Bind the DEBUG socket. Release is a no-op. Does not affect the catalog.
    public static func start(
        app: String,
        ops: (any LatchOpsProviding)? = nil
    ) {
        #if DEBUG
            let resolved = ops ?? LatchDefaultOps(appName: app)
            retainedOps = resolved
            Task {
                do {
                    // The token is written before the server ensures the
                    // directory, so a first run must create it here.
                    try UnixSocketServer().ensureDirectory(
                        at: LatchPaths.directory(app: app))
                    let tokenURL = try LatchPaths.tokenFile(app: app)
                    let token = try LatchToken.loadOrGenerate(at: tokenURL)
                    let socketPath = try LatchPaths.socket(app: app)
                    let server = LatchServer(
                        ops: resolved, token: token, socketPath: socketPath)
                    try await server.start()
                    self.server = server
                } catch {
                    assertionFailure("Latch failed to start: \(error)")
                }
            }
        #endif
    }

    /// Stop the socket. Safe to call when Latch never started.
    public static func stop() {
        #if DEBUG
            Task {
                await server?.stop()
                server = nil
                retainedOps = nil
            }
        #endif
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
