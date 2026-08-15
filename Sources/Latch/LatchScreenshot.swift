import AppKit
import Foundation

/// In-process PNG of one of *this* app's windows.
///
/// Uses `cacheDisplay` on the window's content view — not `screencapture`,
/// not `CGWindowListCreateImage`. No Screen Recording permission. Metal
/// layers may render blank; AX is the contract there.
public enum LatchScreenshot {
    @MainActor
    public static func capture(windowName: String, app: String) throws -> String {
        let window = NSApp.windows.first { LatchAX.windowMatches($0, name: windowName) }
        guard let window else {
            throw LatchError.unknownWindow(name: windowName)
        }
        guard window.isVisible else {
            throw LatchError.windowNotVisible(name: windowName)
        }
        guard let content = window.contentView else {
            throw LatchError.windowEmpty(name: windowName)
        }
        content.layoutSubtreeIfNeeded()
        let bounds = content.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            throw LatchError.windowEmpty(name: windowName)
        }
        guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw LatchError.screenshotFailed(reason: "Could not allocate bitmap.")
        }
        content.cacheDisplay(in: bounds, to: rep)
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
