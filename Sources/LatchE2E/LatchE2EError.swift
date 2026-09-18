import Foundation

/// Failure modes of the e2e harness itself. Expectation failures carry
/// got/want so a red run reads without opening the trace.
public enum LatchE2EError: Error, Sendable, CustomStringConvertible {
    case socket(reason: String)
    case server(code: String, message: String)
    case appLaunch(reason: String)
    case tokenMissing(path: String)
    case timeout(label: String, detail: String)
    case expectationFailed(got: String, want: String)
    case stalled(stableSeconds: Double, detail: String)
    case trace(reason: String)
    case invalidConfig(reason: String)

    public var description: String {
        switch self {
        case .socket(let reason):
            return "Latch socket failed: \(reason)."
        case .server(let code, let message):
            return "Latch server error (\(code)): \(message)"
        case .appLaunch(let reason):
            return "App under test failed to launch: \(reason)"
        case .tokenMissing(let path):
            return "Latch token missing at \(path). Is the app running?"
        case .timeout(let label, let detail):
            return "Timed out waiting for \(label). \(detail)"
        case .expectationFailed(let got, let want):
            return "Expectation failed. Want \(want), got \(got)."
        case .stalled(let stableSeconds, let detail):
            return
                "Catalog stable for \(stableSeconds)s while the condition stayed unmet — the app went idle without what we wait for. \(detail)"
        case .trace(let reason):
            return "Trace write failed: \(reason)"
        case .invalidConfig(let reason):
            return "Invalid LatchE2E config: \(reason)"
        }
    }

    /// The wire error code when the failure came from the server.
    public var serverCode: String? {
        guard case .server(let code, _) = self else { return nil }
        return code
    }
}
