import Foundation
import Testing

@testable import Latch

@Suite(.serialized)
@MainActor
struct LatchBootTests {
    init() async {
        await Latch.resetForTesting()
    }

    @Test("boot is starting until listen, then the host state")
    func bootFollowsSocketPhase() {
        Latch.socketPhase = .idle
        #expect(Latch.resolvedBoot(host: "ready") == "starting")
        Latch.socketPhase = .starting
        #expect(Latch.resolvedBoot(host: "ready") == "starting")
        Latch.socketPhase = .listening
        #expect(Latch.resolvedBoot(host: "ready") == "ready")
        #expect(Latch.resolvedBoot(host: "booting") == "booting")
        Latch.socketPhase = .failed
        #expect(Latch.resolvedBoot(host: "ready") == "failed")
    }

    @Test("gated queryBoot hides host ready until listen")
    func gatedQueryBoot() async {
        let ops = LatchBootGatedOps(inner: FakeLatchOps())
        Latch.socketPhase = .starting
        #expect(await ops.queryBoot() == "starting")
        Latch.socketPhase = .listening
        #expect(await ops.queryBoot() == "ready")
        Latch.socketPhase = .failed
        #expect(await ops.queryBoot() == "failed")
    }

    @Test("start listens then stays listening on a second call")
    func startIsIdempotent() async throws {
        let app = uniqueApp()
        defer { cleanup(app: app) }
        Latch.start(app: app, ops: FakeLatchOps())
        #expect(Latch.socketPhase == .starting || Latch.socketPhase == .listening)
        await Latch.waitForLifecycle()
        #expect(Latch.socketPhase == .listening)
        #expect(Latch.resolvedBoot(host: "ready") == "ready")
        let socket = try LatchPaths.socket(app: app)
        #expect(FileManager.default.fileExists(atPath: socket.path))

        Latch.start(app: app, ops: FakeLatchOps())
        #expect(Latch.socketPhase == .listening)
        await Latch.waitForLifecycle()
        #expect(Latch.socketPhase == .listening)
        #expect(FileManager.default.fileExists(atPath: socket.path))
    }

    @Test("failed bind reports failed and does not look ready")
    func failedStartReportsFailed() async throws {
        // sun_path is 104 bytes on Darwin. A long slug makes bind fail
        // before listen, so boot cannot report the host ready state.
        let app = String(repeating: "x", count: 200)
        Latch.failLoudOnStartFailure = false
        defer {
            Latch.failLoudOnStartFailure = true
            cleanup(app: app)
        }
        Latch.start(app: app, ops: FakeLatchOps())
        await Latch.waitForLifecycle()
        #expect(Latch.socketPhase == .failed)
        #expect(Latch.resolvedBoot(host: "ready") == "failed")
        let ops = LatchBootGatedOps(inner: FakeLatchOps())
        #expect(await ops.queryBoot() == "failed")
    }

    private func uniqueApp() -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return "latch-boot-\(suffix)"
    }

    private func cleanup(app: String) {
        Latch.stop()
        if let directory = try? LatchPaths.directory(app: app) {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

extension Latch {
    static func resetForTesting() async {
        stop()
        await waitForLifecycle()
        socketPhase = .idle
        failLoudOnStartFailure = true
    }
}
