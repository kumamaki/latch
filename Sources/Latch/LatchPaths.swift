import Foundation

/// Filesystem location for the DEBUG Latch socket + token file.
@MainActor
public enum LatchPaths {
    /// Isolated Debug / E2E: point the socket at a temp data dir.
    public static var dataDirectoryOverride: URL?

    public static func directory(app: String) throws -> URL {
        if let override = dataDirectoryOverride {
            return override
        }
        if let override = ProcessInfo.processInfo.environment["LATCH_DATA_DIR"],
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        guard let home = FileManager.default.homeDirectoryForCurrentUser as URL? else {
            throw LatchError.homeDirectoryUnavailable
        }
        return
            home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("\(app)-dev", isDirectory: true)
    }

    public static func socket(app: String) throws -> URL {
        try directory(app: app).appendingPathComponent("latch.sock")
    }

    public static func tokenFile(app: String) throws -> URL {
        try directory(app: app).appendingPathComponent("latch.token")
    }

    public static func screenshotDirectory(app: String) throws -> URL {
        guard let home = FileManager.default.homeDirectoryForCurrentUser as URL? else {
            throw LatchError.homeDirectoryUnavailable
        }
        return
            home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("\(app)-dev", isDirectory: true)
            .appendingPathComponent("latch", isDirectory: true)
    }
}
