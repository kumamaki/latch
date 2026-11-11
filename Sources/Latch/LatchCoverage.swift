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

    public init(covered: Int, uncovered: [LatchCoverageGap]) {
        self.covered = covered
        self.uncovered = uncovered
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
        }

        @MainActor
        static func report(window name: String?) throws -> LatchCoverageReply {
            LatchCatalog.syncWindows()
            let ids = Set(LatchCatalog.snapshot().map(\.id))
            var covered = 0
            var uncovered: [LatchCoverageGap] = []
            for window in try LatchAX.coverageWindows(named: name) {
                let result = classify(
                    controls: LatchAX.actionableControls(in: window),
                    registered: registeredFrames(in: window),
                    registeredIDs: ids)
                covered += result.covered
                uncovered += result.uncovered
            }
            return LatchCoverageReply(covered: covered, uncovered: uncovered)
        }

        @MainActor
        private static func registeredFrames(in window: NSWindow) -> [Registered] {
            LatchCatalog.snapshot().compactMap { node in
                guard node.role != "window" else { return nil }
                guard
                    case .visible(let frame) = LatchCatalog.screenshotFrame(id: node.id, in: window)
                else { return nil }
                return Registered(id: node.id, frame: frame)
            }
        }

        static func classify(
            controls: [LatchAXControl], registered: [Registered], registeredIDs: Set<String>
        ) -> LatchCoverageReply {
            var covered = 0
            var uncovered: [LatchCoverageGap] = []
            for control in controls {
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
            return LatchCoverageReply(covered: covered, uncovered: uncovered)
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
