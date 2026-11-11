import Foundation

@testable import LatchE2E

/// The executables `swift build` leaves next to the test bundle.
enum Fixture {
    static func binary(_ name: String) throws -> URL {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            repo.appendingPathComponent(".build/out/Products/Debug/\(name)"),
            repo.appendingPathComponent(".build/debug/\(name)"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(name),
        ]
        guard
            let candidate = candidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path)
            })
        else {
            throw LatchE2EError.invalidConfig(
                reason:
                    "\(name) binary not built (\(candidates.map(\.path).joined(separator: ", ")))."
            )
        }
        return candidate
    }
}
