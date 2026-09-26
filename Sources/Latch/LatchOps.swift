import AppKit
import Foundation

/// Capability the DEBUG Latch socket dispatches against.
///
/// The host app implements this. Kernel verbs live here. Product verbs
/// stay in the app.
public protocol LatchOpsProviding: AnyObject, Sendable {
    func queryBoot() async -> String
    func queryWindows() async -> [LatchWindowStatus]
    func showWindow(_ name: String) async throws
    func hideWindow(_ name: String) async throws
    func axDump(window: String?, labeled: Bool) async throws -> LatchAXNode
    func axFind(id: String) async throws -> LatchAXNode
    func axPress(id: String, action: String?) async throws
    func axSet(id: String, value: String) async throws
    func axDismiss(button: String?) async throws
    func screenshot(window: String) async throws -> String
}

/// Default ops: catalog drive, unlabeled AX dump, screenshot.
/// Window show/hide and boot state stay with the host unless it
/// overrides them.
#if DEBUG
    @MainActor
    public final class LatchDefaultOps: LatchOpsProviding {
        private let boot: @MainActor () -> String
        private let windows: @MainActor () -> [LatchWindowStatus]
        private let show: @MainActor (String) throws -> Void
        private let hide: @MainActor (String) throws -> Void
        private let appName: String

        public init(
            appName: String,
            boot: @escaping @MainActor () -> String = { "ready" },
            windows: @escaping @MainActor () -> [LatchWindowStatus] = {
                LatchDefaultOps.liveWindows()
            },
            show: @escaping @MainActor (String) throws -> Void = { name in
                try LatchDefaultOps.orderFront(name)
            },
            hide: @escaping @MainActor (String) throws -> Void = { name in
                try LatchDefaultOps.orderOut(name)
            }
        ) {
            self.appName = appName
            self.boot = boot
            self.windows = windows
            self.show = show
            self.hide = hide
        }

        public func queryBoot() async -> String {
            boot()
        }

        public func queryWindows() async -> [LatchWindowStatus] {
            windows()
        }

        public func showWindow(_ name: String) async throws {
            try show(name)
        }

        public func hideWindow(_ name: String) async throws {
            try hide(name)
        }

        public func axDump(window: String?, labeled: Bool) async throws -> LatchAXNode {
            if labeled {
                return LatchCatalogDump.tree(window: window, title: appName)
            }
            return try LatchAX.dump(windowName: window, labeledOnly: false)
        }

        public func axFind(id: String) async throws -> LatchAXNode {
            do {
                return try LatchCatalogDump.node(id: id)
            } catch let error as LatchCatalog.Error {
                throw LatchError(error)
            }
        }

        public func axPress(id: String, action: String?) async throws {
            do {
                try LatchCatalog.press(id: id, action: action)
            } catch let error as LatchCatalog.Error {
                throw LatchError(error)
            }
        }

        public func axSet(id: String, value: String) async throws {
            do {
                try LatchCatalog.set(id: id, value: value)
            } catch let error as LatchCatalog.Error {
                throw LatchError(error)
            }
        }

        public func axDismiss(button: String?) async throws {
            try LatchAX.dismiss(button: button)
        }

        public func screenshot(window: String) async throws -> String {
            try LatchScreenshot.capture(windowName: window, app: appName)
        }

        public static func liveWindows() -> [LatchWindowStatus] {
            LatchCatalog.syncWindows()
            let nodes = LatchCatalog.snapshot()
            var catalogNodes: [String: Int] = [:]
            for node in nodes where node.role != "window" {
                guard let window = node.window else { continue }
                catalogNodes[window, default: 0] += 1
            }
            var rows: [LatchWindowStatus] = []
            for node in nodes where node.role == "window" {
                let logical = node.window ?? String(node.id.dropFirst("window.".count))
                let matches = NSApplication.shared.windows.filter {
                    LatchAX.windowMatches($0, name: logical)
                }
                let count = catalogNodes[logical] ?? 0
                if matches.isEmpty {
                    rows.append(
                        LatchWindowStatus(
                            name: logical, visible: false, exists: false, catalogNodes: count)
                    )
                    continue
                }
                for window in matches.sorted(by: { $0.windowNumber < $1.windowNumber }) {
                    rows.append(
                        windowStatus(
                            name: listedName(of: window, among: matches, logical: logical),
                            window: window,
                            catalogNodes: count
                        )
                    )
                }
            }
            return rows
        }

        /// One instance keeps the short name (`main`). Further instances
        /// keep the SwiftUI suffix so a drive can target each one.
        private static func listedName(
            of window: NSWindow,
            among matches: [NSWindow],
            logical: String
        ) -> String {
            guard matches.count > 1 else { return logical }
            guard let instance = LatchAX.instanceName(of: window) else { return logical }
            let same = matches.filter { LatchAX.instanceName(of: $0) == instance }
            guard same.count > 1 else { return instance }
            let earliest = matches.min { $0.windowNumber < $1.windowNumber }
            if window === earliest { return logical }
            return "\(logical)-\(window.windowNumber)"
        }

        /// `visible` is `NSWindow.isVisible`. Miniaturized and ordered-out
        /// windows are false. `exists` is this AppKit window still in
        /// `NSApp.windows`. `catalogNodes` counts snapshot rows whose
        /// `window` matches the logical name, excluding the window chrome row.
        private static func windowStatus(
            name: String,
            window: NSWindow,
            catalogNodes: Int
        ) -> LatchWindowStatus {
            LatchWindowStatus(
                name: name,
                visible: window.isVisible,
                exists: true,
                catalogNodes: catalogNodes
            )
        }

        public static func orderFront(_ name: String) throws {
            guard let window = LatchAX.preferredWindow(named: name) else {
                throw LatchError.unknownWindow(name: name)
            }
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            if !window.isVisible {
                window.orderFrontRegardless()
            }
            guard window.isVisible else {
                throw LatchError.windowNotVisible(name: name)
            }
        }

        public static func orderOut(_ name: String) throws {
            guard let window = LatchAX.preferredWindow(named: name) else {
                throw LatchError.unknownWindow(name: name)
            }
            window.orderOut(nil)
        }
    }
#endif
