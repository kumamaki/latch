import Foundation

/// One expectation over one catalog id. Every check polls — Playwright
/// expect.poll semantics. No sleeps anywhere.
public struct Expectation: Sendable {
    private let app: LatchApp
    private let id: String

    init(app: LatchApp, id: String) {
        self.app = app
        self.id = id
    }

    public func toAppear(timeout: TimeInterval = 5, stallWindow: TimeInterval? = 5) async throws {
        try await app.pollUntil(
            label: "\(id) to appear", timeout: timeout, stallWindow: stallWindow
        ) {
            try await self.app.node(self.id) != nil
        }
    }

    public func toBeAbsent(
        timeout: TimeInterval = 10,
        stallWindow: TimeInterval? = 5
    ) async throws {
        try await app.pollUntil(
            label: "\(id) to be absent", timeout: timeout, stallWindow: stallWindow
        ) {
            try await self.app.node(self.id) == nil
        }
    }

    public func value(
        _ want: String,
        timeout: TimeInterval = 5,
        stallWindow: TimeInterval? = 5
    ) async throws {
        try await app.pollUntil(
            label: "\(id) value \(want)", timeout: timeout, stallWindow: stallWindow
        ) {
            try await self.app.node(self.id)?.value == want
        }
    }

    public func enabled(
        _ want: Bool = true,
        timeout: TimeInterval = 5,
        stallWindow: TimeInterval? = 5
    ) async throws {
        try await app.pollUntil(
            label: "\(id) enabled=\(want)", timeout: timeout, stallWindow: stallWindow
        ) {
            try await self.app.node(self.id)?.enabled == want
        }
    }

    /// Wait until the node's value has walked `states` in order and now
    /// sits on `states.last`. Faster-than-poll transitions can be
    /// missed — poll with a short `interval` when a state is transient.
    /// On timeout the error shows the observed sequence.
    public func through(
        _ states: [String],
        interval: TimeInterval = 0.05,
        timeout: TimeInterval = 15,
        stallWindow: TimeInterval? = 5
    ) async throws {
        guard let final = states.last else {
            throw LatchE2EError.invalidConfig(reason: "through([]) has no final state")
        }
        let wanted = states.joined(separator: " → ")
        var observed: [String] = []
        var watcher = StallWatcher(window: stallWindow)
        let started = Date()
        while true {
            if let node = try await app.node(id) {
                let value = node.value ?? ""
                if observed.last != value {
                    observed.append(value)
                }
                if value == final, Self.isSubsequence(states, of: observed) {
                    try await app.recordExpectation(
                        label: "\(id) through \(wanted)", outcome: "pass",
                        attempts: observed.count, detail: nil)
                    return
                }
            }
            if Date().timeIntervalSince(started) >= timeout {
                let got = observed.joined(separator: " → ")
                try await app.recordExpectation(
                    label: "\(id) through \(wanted)", outcome: "failed",
                    attempts: observed.count, detail: got)
                throw LatchE2EError.expectationFailed(got: got, want: wanted)
            }
            if let dumped = try? await app.snapshot(),
                let stalled = watcher.check(snapshot: dumped, at: Date())
            {
                try await app.recordExpectation(
                    label: "\(id) through \(wanted)", outcome: "stalled",
                    attempts: observed.count, detail: stalled.description)
                throw stalled
            }
            try await Task.sleep(for: .milliseconds(Int(interval * 1000)))
        }
    }

    /// Whether `needle` appears in `observed` in order, gaps allowed.
    static func isSubsequence(_ needle: [String], of observed: [String]) -> Bool {
        guard !needle.isEmpty else { return true }
        var index = 0
        for item in observed where index < needle.count && item == needle[index] {
            index += 1
        }
        return index == needle.count
    }
}

/// Detox's sync idea, harness-side: while a condition polls, hash the
/// labeled dump. When the catalog sits still past the window, waiting
/// longer cannot help — fail early with the last diff instead of
/// burning the full timeout.
struct StallWatcher {
    private let window: TimeInterval
    private var previous: CatalogSnapshot?
    private var lastChange: Date
    private var lastDiff: CatalogDiff?

    /// nil disables stall detection.
    init(window: TimeInterval?) {
        self.window = window ?? .greatestFiniteMagnitude
        self.lastChange = Date()
    }

    var lastSummary: String? {
        lastDiff?.summary
    }

    /// Returns the stall error once the catalog is stable past the
    /// window. An empty snapshot (boot, hidden windows) does not arm
    /// detection — there is nothing stable to wait against yet.
    mutating func check(snapshot: CatalogSnapshot, at now: Date) -> LatchE2EError? {
        guard window.isFinite else { return nil }
        guard snapshot.count > 0 else { return nil }
        defer { previous = snapshot }
        guard let previous, previous.stateHash == snapshot.stateHash else {
            lastChange = now
            lastDiff = previous.map { snapshot.diffed(from: $0) }
            return nil
        }
        if now.timeIntervalSince(lastChange) >= window {
            return LatchE2EError.stalled(
                stableSeconds: window,
                detail: lastDiff?.summary ?? "catalog unchanged since the first poll")
        }
        return nil
    }
}
