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
            try capture(windowName: windowName, elementID: nil, app: app)
        }

        /// Full window, or one catalog element cropped out of it. The crop
        /// comes from the same `cacheDisplay` bitmap, so an element shot
        /// shows exactly what the window shot would.
        @MainActor
        public static func capture(
            windowName: String, elementID: String?, app: String
        ) throws -> String {
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
            let png: Data
            if let elementID {
                png = try elementPNG(
                    from: rep, root: root, window: window,
                    elementID: elementID, windowName: windowName)
            } else {
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    throw LatchError.screenshotFailed(reason: "Could not encode PNG.")
                }
                png = data
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
            let windowComponent = fileComponent(windowName)
            let elementSuffix = elementID.map { "-\(fileComponent($0))" } ?? ""
            let url = directory.appendingPathComponent(
                "\(windowComponent)\(elementSuffix)-\(safeStamp).png")
            do {
                try png.write(to: url, options: .atomic)
            } catch {
                throw LatchError.screenshotFailed(reason: error.localizedDescription)
            }
            return url.path
        }

        /// Crop the window bitmap to a registered element's frame. `.latch`
        /// and AX frames are in AppKit screen space; the rep is in backing
        /// pixels, and image row 0 is the top of the view.
        @MainActor
        private static func elementPNG(
            from rep: NSBitmapImageRep,
            root: NSView,
            window: NSWindow,
            elementID: String,
            windowName: String
        ) throws -> Data {
            let frame = try LatchAX.elementFrame(
                id: elementID, in: window, windowName: windowName)
            guard let image = rep.cgImage else {
                throw LatchError.screenshotFailed(reason: "Could not read the window bitmap.")
            }
            let bounds = root.bounds
            let inView = root.convert(window.convertFromScreen(frame), from: nil)
            let clipped = inView.intersection(bounds)
            guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
                throw LatchError.screenshotFailed(
                    reason: "Element \(elementID) is outside window \(windowName).")
            }
            let scaleX = CGFloat(image.width) / bounds.width
            let scaleY = CGFloat(image.height) / bounds.height
            let top =
                root.isFlipped
                ? clipped.minY - bounds.minY
                : bounds.maxY - clipped.maxY
            let pixels = CGRect(
                x: (clipped.minX - bounds.minX) * scaleX,
                y: top * scaleY,
                width: clipped.width * scaleX,
                height: clipped.height * scaleY
            ).integral.intersection(
                CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1,
                let cropped = image.cropping(to: pixels)
            else {
                throw LatchError.screenshotFailed(
                    reason: "Could not crop to element \(elementID).")
            }
            guard
                let png = NSBitmapImageRep(cgImage: cropped).representation(
                    using: .png, properties: [:])
            else {
                throw LatchError.screenshotFailed(reason: "Could not encode PNG.")
            }
            return png
        }

        /// One path-safe filename component. Catalog ids use dots; a slash
        /// or colon would escape the screenshot directory.
        private static func fileComponent(_ value: String) -> String {
            let allowed = Set(
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            let mapped = String(value.map { allowed.contains($0) ? $0 : "-" })
            let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
            let clipped = String(trimmed.prefix(80))
            return clipped.isEmpty ? "element" : clipped
        }
    }
#endif
