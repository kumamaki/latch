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
            return nodes.filter { $0.role == "window" }.map {
                windowStatus(for: $0, catalogNodes: catalogNodes)
            }
        }

        /// `visible` is `NSWindow.isVisible`. Miniaturized and ordered-out
        /// windows are false. `exists` is a matching AppKit window still in
        /// `NSApp.windows`. `catalogNodes` counts snapshot rows whose
        /// `window` matches, excluding the window chrome row.
        private static func windowStatus(
            for node: LatchCatalog.Node,
            catalogNodes: [String: Int]
        ) -> LatchWindowStatus {
            let name = node.window ?? String(node.id.dropFirst("window.".count))
            let count = catalogNodes[name] ?? 0
            guard
                let window = NSApp.windows.first(where: { LatchAX.windowMatches($0, name: name) })
            else {
                return LatchWindowStatus(
                    name: name, visible: false, exists: false, catalogNodes: count)
            }
            return LatchWindowStatus(
                name: name, visible: window.isVisible, exists: true, catalogNodes: count)
        }

        public static func orderFront(_ name: String) throws {
            guard let window = NSApp.windows.first(where: { LatchAX.windowMatches($0, name: name) })
            else {
                throw LatchError.unknownWindow(name: name)
            }
            window.makeKeyAndOrderFront(nil)
        }

        public static func orderOut(_ name: String) throws {
            guard let window = NSApp.windows.first(where: { LatchAX.windowMatches($0, name: name) })
            else {
                throw LatchError.unknownWindow(name: name)
            }
            window.orderOut(nil)
        }
    }
#endif
