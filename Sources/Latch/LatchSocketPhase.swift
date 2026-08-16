/// DEBUG socket lifecycle. Boot is `starting` until listen, then the
/// host state. A failed bind cannot look ready.
enum LatchSocketPhase: Equatable, Sendable {
    case idle
    case starting
    case listening
    case failed

    func resolvedBoot(host: String) -> String {
        switch self {
        case .idle, .starting:
            return "starting"
        case .failed:
            return "failed"
        case .listening:
            return host
        }
    }
}
