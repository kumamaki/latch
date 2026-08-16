/// Wraps host ops so `queryBoot` cannot read ready before the DEBUG
/// socket is listening, or after it failed.
@MainActor
final class LatchBootGatedOps: LatchOpsProviding {
    private let inner: any LatchOpsProviding

    init(inner: any LatchOpsProviding) {
        self.inner = inner
    }

    func queryBoot() async -> String {
        Latch.resolvedBoot(host: await inner.queryBoot())
    }

    func queryWindows() async -> [LatchWindowStatus] {
        await inner.queryWindows()
    }

    func showWindow(_ name: String) async throws {
        try await inner.showWindow(name)
    }

    func hideWindow(_ name: String) async throws {
        try await inner.hideWindow(name)
    }

    func axDump(window: String?, labeled: Bool) async throws -> LatchAXNode {
        try await inner.axDump(window: window, labeled: labeled)
    }

    func axFind(id: String) async throws -> LatchAXNode {
        try await inner.axFind(id: id)
    }

    func axPress(id: String, action: String?) async throws {
        try await inner.axPress(id: id, action: action)
    }

    func axSet(id: String, value: String) async throws {
        try await inner.axSet(id: id, value: value)
    }

    func screenshot(window: String) async throws -> String {
        try await inner.screenshot(window: window)
    }
}
