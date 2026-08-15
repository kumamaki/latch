import Foundation

/// Filesystem location for the DEBUG Latch socket + token file.
public enum LatchPaths {
    public static func directory(app: String) throws -> URL {
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
