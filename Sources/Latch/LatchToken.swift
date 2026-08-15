import Foundation
import Security

/// Authentication token for the DEBUG Latch socket.
///
/// Stored as a `0600` sibling of the socket (`latch.token`), not in the
/// Keychain. Agents read the file; there is no pairing UI.
public struct LatchToken: Sendable, Equatable {
    public let value: String

    public init(value: String) {
        self.value = value
    }

    private static let byteLength = 32

    /// Returns the persisted token, or generates and writes a new one.
    public static func loadOrGenerate(at url: URL) throws -> Self {
        if let existing = try load(from: url) {
            return existing
        }
        let fresh = try generate()
        try store(fresh, at: url)
        return fresh
    }

    public static func load(from url: URL) throws -> Self? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return nil }
        do {
            let value = try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return Self(value: value)
        } catch {
            throw LatchError.tokenIO(underlying: error.localizedDescription)
        }
    }

    public static func store(_ token: Self, at url: URL) throws {
        do {
            try token.value.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw LatchError.tokenIO(underlying: error.localizedDescription)
        }
    }

    public func matches(_ candidate: String) -> Bool {
        let lhs = Array(value.utf8)
        let rhs = Array(candidate.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for index in 0..<lhs.count {
            diff |= lhs[index] ^ rhs[index]
        }
        return diff == 0
    }

    private static func generate() throws -> Self {
        var bytes = [UInt8](repeating: 0, count: byteLength)
        let status = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        guard status == errSecSuccess else {
            throw LatchError.tokenIO(underlying: "SecRandomCopyBytes failed: \(status)")
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return Self(value: hex)
    }
}
