#if DEBUG
    import AppKit
    import Foundation

    /// In-process PNG of one of *this* app's windows.
    ///
    /// Uses `cacheDisplay` on the window's frame view (`contentView.superview`)
    /// so the title bar and toolbar paint. Not `screencapture`, not
    /// `CGWindowListCreateImage`. No Screen Recording permission. Material
    /// layers (Liquid Glass, vibrancy) and Metal-backed content may not
    /// composite; AX is the contract there.
    public enum LatchScreenshot {
        /// Reminder returned with every capture so agents learn the
        /// limitation at the point of use, not from a doc they may not read.
        public static let captureNote =
            "Material layers (Liquid Glass, vibrancy) and Metal-backed content "
            + "may not composite in this capture; verify that UI by eye or via AX."

        /// Window frame view when AppKit has attached one; otherwise the
        /// content view. Toolbar is a sibling of content, not a descendant.
        @MainActor
        static func captureRoot(in window: NSWindow) -> NSView? {
            guard let content = window.contentView else { return nil }
            return content.superview ?? content
        }

        @MainActor
        public static func capture(windowName: String, app: String) throws -> String {
            guard let window = LatchAX.preferredWindow(named: windowName) else {
                throw LatchError.unknownWindow(name: windowName)
            }
            guard window.isVisible else {
                throw LatchError.windowNotVisible(name: windowName)
            }
            guard let root = captureRoot(in: window) else {
                throw LatchError.windowEmpty(name: windowName)
            }
            root.layoutSubtreeIfNeeded()
            let bounds = root.bounds
            guard bounds.width > 1, bounds.height > 1 else {
                throw LatchError.windowEmpty(name: windowName)
            }
            guard let rep = root.bitmapImageRepForCachingDisplay(in: bounds) else {
                throw LatchError.screenshotFailed(reason: "Could not allocate bitmap.")
            }
            root.cacheDisplay(in: bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw LatchError.screenshotFailed(reason: "Could not encode PNG.")
            }
            let directory = try LatchPaths.screenshotDirectory(app: app)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter.string(
                from: Date(),
                timeZone: .current,
                formatOptions: [
                    .withInternetDateTime,
                    .withDashSeparatorInDate,
                    .withColonSeparatorInTime,
                ]
            )
            let safeStamp = stamp.replacingOccurrences(of: ":", with: "")
            let url = directory.appendingPathComponent("\(windowName)-\(safeStamp).png")
            do {
                try png.write(to: url, options: .atomic)
            } catch {
                throw LatchError.screenshotFailed(reason: error.localizedDescription)
            }
            return url.path
        }
    }
#endif
