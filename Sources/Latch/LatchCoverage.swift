import AppKit
import Foundation

/// A control the AX probe finds that no catalog id covers.
public struct LatchCoverageGap: Sendable, Encodable, Equatable {
    public let role: String
    public let title: String?
    public let frame: LatchAXFrame
    /// Smallest registered id whose frame contains this control: where to
    /// look for the registration that stops short of it.
    public let near: String?

    public init(role: String, title: String?, frame: LatchAXFrame, near: String?) {
        self.role = role
        self.title = title
        self.frame = frame
        self.near = near
    }
}

/// How much of the app's actionable UI the catalog drives.
public struct LatchCoverageReply: Sendable, Encodable, Equatable {
    public let covered: Int
    public let uncovered: [LatchCoverageGap]
    /// Registered press or set ids the probe never found a control for. The
    /// probe cannot see every control (a glass-effect container hides its
    /// buttons from AX), so `uncovered` may be short by at least these.
    public let unprobed: [String]

    public init(covered: Int, uncovered: [LatchCoverageGap], unprobed: [String] = []) {
        self.covered = covered
        self.uncovered = uncovered
        self.unprobed = unprobed
    }
}

#if DEBUG
    /// The registration gap: what the AX probe sees minus what the catalog
    /// registers. Reports only; press, set, and find still never fall
    /// through to AX.
    enum LatchCoverage {
        /// A registered frame covers a control only when the two are about
        /// the same size. A registered parent stack contains its buttons
        /// without driving them, which is the mistake this finds.
        static let minimumOverlap = 0.6

        struct Registered: Equatable {
            let id: String
            let frame: NSRect
            /// Press or set reaches a handler, so a mounted one implies a control.
            var drivable = false
        }

        @MainActor
        static func report(window name: String?) throws -> LatchCoverageReply {
            LatchCatalog.syncWindows()
            let ids = Set(LatchCatalog.snapshot().map(\.id))
            var covered = 0
            var uncovered: [LatchCoverageGap] = []
            var unprobed: [String] = []
            for window in try LatchAX.coverageWindows(named: name) {
                let probe = LatchAX.actionableControls(in: window)
                let registered = registeredFrames(in: window)
                if probe.controls.isEmpty, let drivable = registered.first(where: \.drivable) {
                    // Registered controls are on screen, so an empty probe is
                    // a blind probe, not an app with nothing to cover.
                    throw LatchError.opsUnavailable(
                        reason:
                            "The AX probe found no controls in \(window.title) after "
                            + "\(probe.visited) nodes, but \(drivable.id) is mounted there. "
                            + "SwiftUI may not have built its accessibility tree.")
                }
                let result = classify(
                    controls: probe.controls,
                    registered: registered,
                    registeredIDs: ids)
                covered += result.covered
                uncovered += result.uncovered
                unprobed += result.unprobed
            }
            return LatchCoverageReply(covered: covered, uncovered: uncovered, unprobed: unprobed)
        }

        @MainActor
        private static func registeredFrames(in window: NSWindow) -> [Registered] {
            LatchCatalog.snapshot().compactMap { node in
                guard node.role != "window" else { return nil }
                guard
                    case .visible(let frame) = LatchCatalog.screenshotFrame(id: node.id, in: window)
                else { return nil }
                return Registered(id: node.id, frame: frame, drivable: !node.actions.isEmpty)
            }
        }

        static func classify(
            controls: [LatchAXControl], registered: [Registered], registeredIDs: Set<String>
        ) -> LatchCoverageReply {
            var covered = 0
            var uncovered: [LatchCoverageGap] = []
            for control in unique(controls) {
                if control.identifier.map(registeredIDs.contains) == true
                    || registered.contains(where: {
                        overlap($0.frame, control.frame) >= minimumOverlap
                    })
                {
                    covered += 1
                    continue
                }
                uncovered.append(
                    LatchCoverageGap(
                        role: control.role,
                        title: control.title,
                        frame: LatchAXFrame(control.frame),
                        near: smallest(containing: control.frame, in: registered)?.id))
            }
            let unprobed = registered.filter { entry in
                entry.drivable
                    && !controls.contains { overlap(entry.frame, $0.frame) >= minimumOverlap }
            }.map(\.id)
            return LatchCoverageReply(covered: covered, uncovered: uncovered, unprobed: unprobed)
        }

        /// The AX walk reaches one control over several paths, so the same
        /// role, title, and frame is one control.
        private static func unique(_ controls: [LatchAXControl]) -> [LatchAXControl] {
            var seen: [LatchAXControl] = []
            for control in controls where !seen.contains(control) {
                seen.append(control)
            }
            return seen
        }

        /// Intersection over union.
        private static func overlap(_ lhs: NSRect, _ rhs: NSRect) -> Double {
            let shared = lhs.intersection(rhs)
            guard !shared.isNull else { return 0 }
            let intersection = shared.width * shared.height
            let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
            return union > 0 ? intersection / union : 0
        }

        private static func smallest(containing frame: NSRect, in registered: [Registered])
            -> Registered?
        {
            registered
                .filter { $0.frame.contains(frame) }
                .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }
    }
#endif
