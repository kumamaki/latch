#if DEBUG
    import AppKit
    import CoreGraphics
    import Foundation
    import Synchronization

    /// In-process AX walk of `NSApp`. No System Events, no Accessibility
    /// permission for the agent process — the app reports on itself.
    ///
    /// AppKit's `NSAccessibility` name is the attribute/role *namespace*,
    /// not a walkable type. The live tree is `NSWindow` / `NSView` /
    /// `NSAccessibilityElement` (SwiftUI hosting children land in the last).
    public enum LatchAX {
        static let maxDepth = 24
        static let maxNodes = 800

        @MainActor
        public static func dump(windowName: String?, labeledOnly: Bool = false) throws
            -> LatchAXNode
        {
            let windows = targetWindows(named: windowName)
            guard !windows.isEmpty else {
                if let windowName {
                    throw LatchError.unknownWindow(name: windowName)
                }
                throw LatchError.opsUnavailable(reason: "No windows to dump.")
            }
            var remaining = maxNodes
            let topLevel = Set(windows.map { ObjectIdentifier($0) })
            let children = windows.compactMap { window -> LatchAXNode? in
                guard
                    var node = snapshot(
                        Lens.window(window),
                        depth: 0,
                        remaining: &remaining,
                        labeledOnly: labeledOnly
                    )
                else { return nil }
                // Named dump filters by identifier, so attached sheets miss
                // the parent name. Nest them under that window. Unscoped dump
                // already lists sheet windows at the top level.
                if windowName != nil {
                    let extras = attachedDialogs(of: window).compactMap { sheet -> LatchAXNode? in
                        guard !topLevel.contains(ObjectIdentifier(sheet)) else { return nil }
                        return snapshot(
                            Lens.window(sheet),
                            depth: 1,
                            remaining: &remaining,
                            labeledOnly: labeledOnly,
                            inChrome: true
                        )
                    }
                    if !extras.isEmpty {
                        node = node.appending(children: extras)
                    }
                }
                return node
            }
            return LatchAXNode(
                id: nil,
                role: "application",
                title: NSApplication.shared.applicationName,
                value: nil,
                enabled: true,
                actions: [],
                frame: .zero,
                children: children
            )
        }

        @MainActor
        public static func find(id: String) throws -> (element: AnyObject, node: LatchAXNode) {
            let hits = findAll(id: id)
            guard let hit = preferredHit(hits) else {
                throw LatchError.elementNotFound(id: id)
            }
            var remaining = 1
            let node =
                snapshot(hit, depth: 0, remaining: &remaining)
                ?? LatchAXNode(
                    id: id,
                    role: hit.roleName,
                    title: hit.title,
                    value: hit.stringValue,
                    enabled: hit.isEnabled,
                    actions: hit.actionNames,
                    frame: LatchAXFrame(hit.frame),
                    children: []
                )
            return (hit.object, node)
        }

        /// Post a real mouse click at the element's frame center via
        /// `NSApp.sendEvent`. Unlike catalog `press`, this runs the whole
        /// dispatch path — hit-testing, local event monitors, window
        /// ordering — so drives can reach behavior that only real clicks
        /// exercise (outside-click dismissal, right-click menus).
        @MainActor
        public static func click(id: String, button: String?) throws {
            let hits = findAll(id: id)
            guard let hit = preferredHit(hits) else {
                throw LatchError.elementNotFound(id: id)
            }
            let types = try clickTypes(button: button, id: id)
            let frame = hit.frame
            guard frame != .zero, let window = hostWindow(of: hit) else {
                throw LatchError.actionUnavailable(id: id, action: "click")
            }
            // accessibilityFrame is already AppKit screen space: origin
            // at the bottom-left of the primary screen.
            let screenPoint = CGPoint(x: frame.midX, y: frame.midY)
            try postClick(types, in: window, atScreen: screenPoint)
        }

        /// Post a real mouse click at a point inside a named window.
        /// `x`/`y` are points from the top-left of the window's outer
        /// frame, so a drive can aim at spots between catalog rows —
        /// dead space that should only dismiss a menu — without a
        /// catalog id to anchor to.
        @MainActor
        public static func clickPoint(
            window name: String, x: Double, y: Double, button: String?
        ) throws {
            let types = try clickTypes(button: button, id: name)
            let sample = try windowPoint(window: name, x: x, y: y)
            try postClick(types, in: sample.window, atScreen: sample.screen)
        }

        /// Mouse drag from one catalog id to another. Each id is
        /// registered and has that accessibility identifier. The press
        /// point is an inset clear of labeled children, so the center of
        /// a container is not a child row. Posts `leftMouseDown`,
        /// `leftMouseDragged`, and `leftMouseUp` through `sendEvent`.
        /// The system pointer stays where it is. `DragGesture` and
        /// `mouseDragged` read these events.
        @MainActor
        public static func drag(from sourceID: String, to destID: String) throws {
            try performDrag(from: try aim(id: sourceID), to: try aim(id: destID), delivery: .mouse)
        }

        /// Mouse drag between window points. Coordinates match
        /// `clickPoint`. `toWindow` defaults to `window`. The system
        /// pointer stays where it is.
        @MainActor
        public static func dragPoint(
            window: String, x: Double, y: Double,
            toWindow: String?, toX: Double, toY: Double
        ) throws {
            let start = try windowPoint(window: window, x: x, y: y)
            let end = try windowPoint(window: toWindow ?? window, x: toX, y: toY)
            try performDrag(from: start, to: end, delivery: .mouse)
        }

        /// Dragging session from one catalog id to another. Same aim as
        /// `drag`. The system pointer tracks the path and returns when
        /// the command finishes, and the left button is posted for the
        /// gesture so `NSDraggingSession` and SwiftUI `draggable` can
        /// follow it. The app has to already be in front; this does not
        /// activate it.
        @MainActor
        public static func mouseDragSession(from sourceID: String, to destID: String) throws {
            try performDrag(
                from: try aim(id: sourceID), to: try aim(id: destID), delivery: .session)
        }

        /// Dragging session between window points. The system pointer
        /// tracks the path and returns when the command finishes, and
        /// the left button is posted for the gesture.
        @MainActor
        public static func mouseDragSessionPoint(
            window: String, x: Double, y: Double,
            toWindow: String?, toX: Double, toY: Double
        ) throws {
            let start = try windowPoint(window: window, x: x, y: y)
            let end = try windowPoint(window: toWindow ?? window, x: toX, y: toY)
            try performDrag(from: start, to: end, delivery: .session)
        }

        private static func clickTypes(
            button: String?, id: String
        ) throws -> (down: NSEvent.EventType, up: NSEvent.EventType) {
            switch button {
            case nil, "left":
                return (.leftMouseDown, .leftMouseUp)
            case "right":
                return (.rightMouseDown, .rightMouseUp)
            case let other?:
                throw LatchError.invalidValue(
                    id: id, value: other, expected: "left or right")
            }
        }

        @MainActor
        private static func postClick(
            _ types: (down: NSEvent.EventType, up: NSEvent.EventType),
            in window: NSWindow,
            atScreen screenPoint: CGPoint
        ) throws {
            let location = window.convertPoint(fromScreen: screenPoint)
            for type in [types.down, types.up] {
                guard
                    let event = NSEvent.mouseEvent(
                        with: type,
                        location: location,
                        modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil,
                        eventNumber: 0,
                        clickCount: 1,
                        pressure: type == types.down ? 1 : 0
                    )
                else {
                    throw LatchError.opsUnavailable(
                        reason: "NSEvent.mouseEvent could not synthesize \(type).")
                }
                NSApp.sendEvent(event)
            }
        }

        @MainActor
        private static var nextDragEventNumber = 80_001

        /// One point on a drag, already in AppKit screen space.
        private struct DragSample {
            var window: NSWindow
            var screen: CGPoint
        }

        /// `x`/`y` are points from the top-left of the window's outer frame.
        @MainActor
        private static func windowPoint(
            window name: String, x: Double, y: Double
        ) throws -> DragSample {
            guard let window = preferredWindow(named: name) else {
                throw LatchError.unknownWindow(name: name)
            }
            guard window.isVisible || window.isMiniaturized else {
                throw LatchError.windowNotVisible(name: name)
            }
            guard x.isFinite, y.isFinite else {
                throw LatchError.invalidValue(
                    id: name, value: "\(x),\(y)", expected: "finite points")
            }
            let frame = window.frame
            guard frame.width > 0, frame.height > 0,
                x >= 0, y >= 0, x < frame.width, y < frame.height
            else {
                throw LatchError.invalidValue(
                    id: name, value: "\(x),\(y)",
                    expected: "0 ≤ x < \(Int(frame.width)), 0 ≤ y < \(Int(frame.height))")
            }
            // The caller's origin is the window's top-left; AppKit
            // window frames count up from the screen's bottom-left.
            return DragSample(
                window: window,
                screen: CGPoint(x: frame.minX + x, y: frame.maxY - y)
            )
        }

        /// Catalog id first, then the accessibility frame. A labeled
        /// child (a row in the middle of a bin) is not a legal aim point.
        @MainActor
        private static func aim(id: String) throws -> DragSample {
            do {
                _ = try LatchCatalog.find(id: id)
            } catch let error as LatchCatalog.Error {
                throw LatchError(error)
            }
            let hits = findAll(id: id)
            guard let hit = preferredHit(hits) else {
                throw LatchError.actionUnavailable(
                    id: id,
                    action:
                        "drag (no accessibility frame; set accessibilityIdentifier to this id)"
                )
            }
            let frame = hit.frame
            guard frame.width >= 2, frame.height >= 2, let window = hostWindow(of: hit) else {
                throw LatchError.actionUnavailable(
                    id: id,
                    action:
                        "drag (no accessibility frame; set accessibilityIdentifier to this id)"
                )
            }
            let blocked = labeledChildFrames(under: hit, root: id)
            let screen = try aimPoint(id: id, frame: frame, avoiding: blocked, window: window)
            return DragSample(window: window, screen: screen)
        }

        @MainActor
        private static func labeledChildFrames(under lens: Lens, root: String) -> [NSRect] {
            var frames: [NSRect] = []
            func walk(_ lens: Lens) {
                for child in children(of: lens) {
                    let frame = child.frame
                    if let childID = child.identifier, childID != root, frame.width >= 2,
                        frame.height >= 2
                    {
                        frames.append(frame)
                    }
                    walk(child)
                }
            }
            walk(lens)
            return frames
        }

        /// Corners and edges before the center. The center of a container
        /// is where the child row sits.
        @MainActor
        private static func aimPoint(
            id: String, frame: NSRect, avoiding: [NSRect], window: NSWindow
        ) throws -> CGPoint {
            let candidates = aimCandidates(in: frame, avoiding: avoiding)
            guard !candidates.isEmpty else {
                throw LatchError.actionUnavailable(
                    id: id, action: "drag (no inset clear of child controls)")
            }
            for candidate in candidates {
                let screen = try appKitScreen(fromAX: candidate)
                let local = window.convertPoint(fromScreen: screen)
                if let view = window.contentView?.hitTest(local),
                    let owner = contentIdentifier(from: view, in: window), owner != id
                {
                    continue
                }
                return screen
            }
            throw LatchError.actionUnavailable(
                id: id, action: "drag (no inset clear of child controls)")
        }

        private static func aimCandidates(in frame: NSRect, avoiding: [NSRect]) -> [CGPoint] {
            func clear(_ point: CGPoint) -> Bool {
                frame.contains(point)
                    && !avoiding.contains {
                        $0.insetBy(dx: -0.5, dy: -0.5).contains(point)
                    }
            }
            let margin = min(6, min(frame.width, frame.height) / 4)
            let inner = frame.insetBy(dx: margin, dy: margin)
            var points = [
                CGPoint(x: inner.minX, y: inner.minY),
                CGPoint(x: inner.maxX, y: inner.minY),
                CGPoint(x: inner.minX, y: inner.maxY),
                CGPoint(x: inner.maxX, y: inner.maxY),
                CGPoint(x: inner.midX, y: inner.minY),
                CGPoint(x: inner.minX, y: inner.midY),
                CGPoint(x: inner.maxX, y: inner.midY),
                CGPoint(x: inner.midX, y: inner.maxY),
            ]
            if inner.width > 0, inner.height > 0 {
                var y = inner.minY
                while y <= inner.maxY + 0.5 {
                    var x = inner.minX
                    while x <= inner.maxX + 0.5 {
                        points.append(CGPoint(x: x, y: y))
                        x += 12
                    }
                    y += 12
                }
            }
            points.append(CGPoint(x: frame.midX, y: frame.midY))
            var seen = Set<String>()
            return points.filter { point in
                let key = "\(Int(point.x.rounded())):\(Int(point.y.rounded()))"
                guard seen.insert(key).inserted else { return false }
                return clear(point)
            }
        }

        /// Walk views inside the content view. The window's own identifier
        /// is chrome and does not count as a child control.
        @MainActor
        private static func contentIdentifier(from view: NSView, in window: NSWindow) -> String? {
            var current: NSView? = view
            while let view = current {
                if view === window.contentView { break }
                if let id = nonempty(view.accessibilityIdentifier()) { return id }
                current = view.superview
            }
            return nil
        }

        /// `accessibilityFrame` is AppKit screen space, same as
        /// `NSWindow.frame`. Flipping Y aims at the opposite side of
        /// the window.
        @MainActor
        private static func appKitScreen(fromAX point: CGPoint) throws -> CGPoint {
            guard NSScreen.screens.first != nil else {
                throw LatchError.opsUnavailable(reason: "drag needs a display.")
            }
            return point
        }

        /// `mouse` posts events and leaves the pointer. `session` moves
        /// the system pointer because a dragging session reads it.
        private enum DragDelivery {
            case mouse
            case session
        }

        @MainActor
        private static func performDrag(
            from start: DragSample, to end: DragSample, delivery: DragDelivery
        ) throws {
            let points = interpolated(from: start.screen, to: end.screen)
            let samples = points.enumerated().map { index, point in
                let window: NSWindow
                if index == 0 {
                    window = start.window
                } else if index == points.count - 1 {
                    window = end.window
                } else {
                    window = hostingWindow(at: point, start: start, end: end)
                }
                return DragSample(window: window, screen: point)
            }
            try deliver(samples, delivery: delivery)
        }

        private static func interpolated(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let distance = hypot(dx, dy)
            let steps = max(1, Int((distance / 8).rounded(.up)))
            return (0...steps).map { index in
                let t = CGFloat(index) / CGFloat(steps)
                return CGPoint(x: start.x + dx * t, y: start.y + dy * t)
            }
        }

        @MainActor
        private static func hostingWindow(
            at screen: CGPoint, start: DragSample, end: DragSample
        ) -> NSWindow {
            let number = NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0)
            if let window = NSApp.window(withWindowNumber: number),
                window === start.window || window === end.window
            {
                return window
            }
            let fromStart = hypot(screen.x - start.screen.x, screen.y - start.screen.y)
            let fromEnd = hypot(screen.x - end.screen.x, screen.y - end.screen.y)
            return fromStart <= fromEnd ? start.window : end.window
        }

        /// Down, dragged samples, up. A tracking loop started inside
        /// mouse-down pulls the rest with `nextEvent` in
        /// `NSEventTrackingRunLoopMode`, so a timer in that mode posts
        /// whatever `sendEvent` could not. Mouse-up is posted either way.
        /// `.mouse` injects `NSEvent`s and leaves the pointer.
        /// `.session` moves the system pointer along the samples and
        /// puts it back. It also reports the left button down and posts
        /// that button. A dragging session reads both; either one alone
        /// does not start it.
        @MainActor
        private static func deliver(_ samples: [DragSample], delivery: DragDelivery) throws {
            if delivery == .session {
                guard NSApp.isActive else {
                    throw LatchError.opsUnavailable(
                        reason: "drag session needs this app in front.")
                }
                let savedCursor = NSEvent.mouseLocation
                // A dragging session will not start while
                // `pressedMouseButtons` is zero, and an injected event
                // does not set it. Report the left button down until
                // mouse-up, then put the real state back. A backstop
                // stops the run loop so a tracking loop that ignores
                // the up cannot wedge the socket.
                LatchPressedButtons.begin()
                let stop = stopMainRunLoopLater()
                defer { stop?.disarm() }
                defer {
                    LatchPressedButtons.end()
                    postSystemMouse(.leftMouseUp, atAppKit: NSEvent.mouseLocation)
                    warpCursor(toAppKit: savedCursor)
                }
                try feed(samples, movesCursor: true)
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            } else {
                try feed(samples, movesCursor: false)
            }
        }

        @MainActor
        private static func feed(_ samples: [DragSample], movesCursor: Bool) throws {
            guard let first = samples.first, samples.count >= 2 else {
                throw LatchError.opsUnavailable(reason: "drag needs two points.")
            }
            let number = nextDragEventNumber
            nextDragEventNumber += 1
            let base = ProcessInfo.processInfo.systemUptime
            let down = try mouseEvent(
                .leftMouseDown, sample: first, timestamp: base,
                eventNumber: number, clickCount: 1, pressure: 1)
            var rest: [(event: NSEvent, screen: CGPoint)] = []
            for (index, sample) in samples.enumerated() where index > 0 {
                let dragged = try mouseEvent(
                    .leftMouseDragged, sample: sample,
                    timestamp: base + Double(index) * 0.016,
                    eventNumber: number, clickCount: 0, pressure: 1)
                rest.append((dragged, sample.screen))
            }
            let last = samples[samples.count - 1]
            let up = try mouseEvent(
                .leftMouseUp, sample: last,
                timestamp: base + Double(samples.count) * 0.016,
                eventNumber: number, clickCount: 1, pressure: 0)
            rest.append((up, last.screen))

            let feeder = LatchDragFeeder(
                eventNumber: number, pending: rest, up: up, movesCursor: movesCursor)
            let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
                if event.eventNumber == number, event.type == .leftMouseUp {
                    MainActor.assumeIsolated { feeder.upSeen = true }
                }
                return event
            }
            let pump = Timer(
                timeInterval: 0.016, target: feeder, selector: #selector(LatchDragFeeder.pump),
                userInfo: nil, repeats: true)
            let watchdog = Timer(
                timeInterval: 1.5, target: feeder, selector: #selector(LatchDragFeeder.forceUp),
                userInfo: nil, repeats: false)
            RunLoop.current.add(pump, forMode: .eventTracking)
            RunLoop.current.add(watchdog, forMode: .eventTracking)
            if movesCursor {
                RunLoop.current.add(pump, forMode: .default)
                RunLoop.current.add(watchdog, forMode: .default)
                RunLoop.current.add(pump, forMode: .common)
                RunLoop.current.add(watchdog, forMode: .common)
            }
            defer {
                pump.invalidate()
                watchdog.invalidate()
                if let monitor { NSEvent.removeMonitor(monitor) }
            }

            if movesCursor {
                warpCursor(toAppKit: first.screen)
                postSystemMouse(.leftMouseDown, atAppKit: first.screen)
            }
            NSApp.sendEvent(down)
            if !feeder.upSeen {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
            if !feeder.upSeen {
                feeder.sendRemaining()
            }
            if !feeder.upSeen {
                if movesCursor {
                    warpCursor(toAppKit: last.screen)
                    LatchPressedButtons.end()
                    postSystemMouse(.leftMouseUp, atAppKit: last.screen)
                }
                NSApp.sendEvent(up)
            }
            guard feeder.upSeen else {
                throw LatchError.opsUnavailable(
                    reason: movesCursor
                        ? "drag session timed out before mouse up."
                        : "mouse drag timed out before mouse up.")
            }
        }

        @MainActor
        private static func mouseEvent(
            _ type: NSEvent.EventType,
            sample: DragSample,
            timestamp: TimeInterval,
            eventNumber: Int,
            clickCount: Int,
            pressure: Float
        ) throws -> NSEvent {
            let location = sample.window.convertPoint(fromScreen: sample.screen)
            guard
                let event = NSEvent.mouseEvent(
                    with: type,
                    location: location,
                    modifierFlags: [],
                    timestamp: timestamp,
                    windowNumber: sample.window.windowNumber,
                    context: nil,
                    eventNumber: eventNumber,
                    clickCount: clickCount,
                    pressure: pressure
                )
            else {
                throw LatchError.opsUnavailable(
                    reason: "NSEvent.mouseEvent could not synthesize \(type).")
            }
            return event
        }

        /// Drag sessions track the system cursor, not the event's location.
        /// Quartz points count down from the primary display's top-left.
        @MainActor
        fileprivate static func warpCursor(toAppKit screen: CGPoint) {
            guard let height = NSScreen.screens.first?.frame.height else { return }
            CGAssociateMouseAndMouseCursorPosition(1)
            CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: height - screen.y))
        }

        /// Quartz mouse button at an AppKit screen point. Dropped
        /// without a prompt when the process cannot post HID.
        @MainActor
        fileprivate static func postSystemMouse(_ type: CGEventType, atAppKit screen: CGPoint) {
            guard let height = NSScreen.screens.first?.frame.height else { return }
            guard
                let event = CGEvent(
                    mouseEventSource: CGEventSource(stateID: .hidSystemState),
                    mouseType: type,
                    mouseCursorPosition: CGPoint(x: screen.x, y: height - screen.y),
                    mouseButton: .left
                )
            else { return }
            event.post(tap: .cghidEventTap)
        }

        /// Last resort if a dragging loop never returns to `feed`.
        /// Several stops cover a loop that re-enters after the first one.
        /// A finished drag disarms them so the app's run loop stays up.
        private static func stopMainRunLoopLater() -> RunLoopStop? {
            guard let loop = CFRunLoopGetMain() else { return nil }
            let box = RunLoopStop(loop)
            for delay in [1.5, 2.0, 2.5] {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    box.stop()
                }
            }
            return box
        }

        /// The window hit-testing should target: the view's own window,
        /// or the nearest windowed AX ancestor for backing elements.
        @MainActor
        private static func hostWindow(of lens: Lens) -> NSWindow? {
            switch lens {
            case .window(let window):
                return window
            case .view(let view):
                return view.window
            case .element, .object:
                var parent = lens.parent
                while let current = parent, let next = Lens(current) {
                    switch next {
                    case .window(let window): return window
                    case .view(let view): return view.window
                    case .element, .object: parent = next.parent
                    }
                }
                return nil
            }
        }

        @MainActor
        public static func press(id: String, action: String? = nil) throws {
            let hits = findAll(id: id)
            guard !hits.isEmpty else {
                throw LatchError.elementNotFound(id: id)
            }
            if let action {
                for hit in preferredOrder(hits, action: action)
                where performNamedAction(action, on: hit) {
                    return
                }
                throw LatchError.actionUnavailable(id: id, action: action)
            }
            for hit in preferredOrder(hits) where performPress(on: hit) {
                return
            }
            throw LatchError.actionUnavailable(id: id, action: "press")
        }

        @MainActor
        public static func setValue(id: String, value: String) throws {
            let hit = try find(id: id)
            guard let lens = Lens(hit.element), setStringValue(value, on: lens) else {
                throw LatchError.actionUnavailable(id: id, action: "set")
            }
        }

        /// Press a button on the frontmost system dialog in this app.
        /// Catalog press stays catalog-only; this is chrome, not a product id.
        @MainActor
        public static func dismiss(button: String? = nil) throws {
            let chrome = try frontmostChrome()
            let buttons = collectButtons(in: chrome)
            let titles = uniqueTitles(buttons)
            let target: Lens
            if let button, !button.isEmpty {
                guard let match = buttons.first(where: { $0.title == button }) else {
                    throw LatchError.dialogButtonNotFound(wanted: button, available: titles)
                }
                target = match
            } else {
                target = try defaultButton(in: chrome, buttons: buttons, titles: titles)
            }
            if performPress(on: target) { return }
            throw LatchError.actionUnavailable(id: target.title ?? "dialog", action: "press")
        }

        @MainActor
        public static func windowMatches(_ window: NSWindow, name: String) -> Bool {
            if let ident = Lens.window(window).identifier, nameFits(ident, name: name) {
                return true
            }
            if let raw = window.identifier?.rawValue, nameFits(raw, name: name) {
                return true
            }
            return false
        }

        /// Short name (`main`) or the instance name (`main-AppWindow-2`).
        private static func nameFits(_ raw: String, name: String) -> Bool {
            catalogName(from: raw) == name || instanceName(from: raw) == name
        }

        /// `main`, `window.main`, `app.window.main`, and
        /// `main-AppWindow-1` all name `main`. SwiftUI `WindowGroup`
        /// rewrites the identifier; we match it rather than overwrite.
        static func catalogName(from raw: String) -> String {
            var name = instanceName(from: raw)
            if let range = name.range(of: "-AppWindow-", options: .backwards) {
                let suffix = name[range.upperBound...]
                if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) {
                    name = String(name[..<range.lowerBound])
                }
            }
            return name
        }

        /// Identifier with the `window.` prefix removed. Keeps
        /// SwiftUI's `-AppWindow-N` so two instances of one scene
        /// stay addressable.
        static func instanceName(from raw: String) -> String {
            if raw.hasPrefix("window.") {
                return String(raw.dropFirst("window.".count))
            }
            if let range = raw.range(of: ".window.") {
                return String(raw[range.upperBound...])
            }
            return raw
        }

        @MainActor
        static func instanceName(of window: NSWindow) -> String? {
            let accessibility = window.accessibilityIdentifier()
            let raw =
                accessibility.isEmpty
                ? window.identifier?.rawValue
                : accessibility
            guard let raw, !raw.isEmpty else { return nil }
            return instanceName(from: raw)
        }

        /// The window a drive means by `name`.
        ///
        /// An exact instance name (`fetchBox-AppWindow-2`) selects that
        /// window. A short name selects the instance already on screen,
        /// which is the earlier window when a later `window show` has
        /// spawned another. A hidden window is the match only when
        /// nothing of that name is on screen.
        @MainActor
        static func preferredWindow(named name: String) -> NSWindow? {
            let matches = NSApplication.shared.windows.filter {
                windowMatches($0, name: name)
            }
            let exact = matches.filter { instanceName(of: $0) == name }
            let pool = exact.isEmpty ? matches : exact
            let visible = pool.filter(\.isVisible)
            let ranked = visible.isEmpty ? pool : visible
            return ranked.min { $0.windowNumber < $1.windowNumber }
        }

        @MainActor
        private static func targetWindows(named name: String?) -> [NSWindow] {
            let windows = NSApplication.shared.windows.filter {
                $0.isVisible || $0.isMiniaturized
            }
            guard let name else { return windows }
            guard let window = preferredWindow(named: name) else { return [] }
            guard window.isVisible || window.isMiniaturized else { return [] }
            return [window]
        }

        private static let dismissRoles: Set<String> = ["alert", "dialog"]
        private static let copyRoles: Set<String> = ["alert", "dialog", "sheet"]
        private static let textRoles: Set<String> = ["cell", "statictext", "textarea"]
        private static let chromeSubroles: Set<String> = ["dialog", "systemdialog"]

        @MainActor
        private static func isCopyChrome(_ lens: Lens) -> Bool {
            if copyRoles.contains(lens.roleName) { return true }
            if let subrole = lens.subroleName, chromeSubroles.contains(subrole) {
                return true
            }
            return false
        }

        @MainActor
        private static func isDismissChrome(_ lens: Lens) -> Bool {
            if dismissRoles.contains(lens.roleName) { return true }
            if let subrole = lens.subroleName, chromeSubroles.contains(subrole) {
                return true
            }
            return false
        }

        @MainActor
        private static func isSystemDialogWindow(_ window: NSWindow) -> Bool {
            if window === NSApplication.shared.modalWindow { return true }
            if isDismissChrome(.window(window)) { return true }
            if window.isSheet, window.defaultButtonCell != nil { return true }
            return false
        }

        @MainActor
        private static func attachedDialogs(of window: NSWindow) -> [NSWindow] {
            var seen = Set<ObjectIdentifier>()
            var result: [NSWindow] = []
            func add(_ candidate: NSWindow?) {
                guard let candidate, candidate !== window else { return }
                guard seen.insert(ObjectIdentifier(candidate)).inserted else { return }
                result.append(candidate)
            }
            add(window.attachedSheet)
            for sheet in window.sheets {
                add(sheet)
            }
            if let modal = NSApplication.shared.modalWindow, modal.sheetParent === window {
                add(modal)
            }
            return result
        }

        @MainActor
        private static func preferredWindows() -> [NSWindow] {
            var seen = Set<ObjectIdentifier>()
            var result: [NSWindow] = []
            func add(_ window: NSWindow?) {
                guard let window else { return }
                guard seen.insert(ObjectIdentifier(window)).inserted else { return }
                result.append(window)
            }
            let app = NSApplication.shared
            add(app.keyWindow)
            add(app.mainWindow)
            for window in app.windows {
                if window.isVisible || window.isMiniaturized || window.isSheet {
                    add(window)
                }
            }
            return result
        }

        @MainActor
        private static func frontmostChrome() throws -> Lens {
            if let modal = NSApplication.shared.modalWindow, isSystemDialogWindow(modal) {
                return .window(modal)
            }
            for window in preferredWindows() {
                if let sheet = window.attachedSheet, isSystemDialogWindow(sheet) {
                    return .window(sheet)
                }
                for sheet in window.sheets where isSystemDialogWindow(sheet) {
                    return .window(sheet)
                }
            }
            for window in preferredWindows() {
                if let node = firstChromeNode(in: .window(window)) {
                    return node
                }
            }
            throw LatchError.noSystemDialog
        }

        @MainActor
        private static func firstChromeNode(in lens: Lens, depth: Int = 0) -> Lens? {
            if isDismissChrome(lens) { return lens }
            guard depth < maxDepth else { return nil }
            for child in children(of: lens) {
                if let hit = firstChromeNode(in: child, depth: depth + 1) {
                    return hit
                }
            }
            return nil
        }

        @MainActor
        private static func collectButtons(in lens: Lens, depth: Int = 0) -> [Lens] {
            var seen = Set<ObjectIdentifier>()
            var result: [Lens] = []
            func walk(_ lens: Lens, depth: Int) {
                let isButton = lens.roleName == "button" || lens.object is NSButton
                if isButton, seen.insert(ObjectIdentifier(lens.object)).inserted {
                    result.append(lens)
                }
                guard depth < maxDepth else { return }
                for child in children(of: lens) {
                    walk(child, depth: depth + 1)
                }
            }
            walk(lens, depth: depth)
            return result
        }

        @MainActor
        private static func defaultButton(
            in chrome: Lens,
            buttons: [Lens],
            titles: [String]
        ) throws -> Lens {
            if case .window(let window) = chrome, let cell = window.defaultButtonCell {
                if let button = cell.controlView as? NSButton {
                    return .view(button)
                }
                if let title = nonempty(cell.title),
                    let match = buttons.first(where: { $0.title == title })
                {
                    return match
                }
            }
            if let enter = buttons.first(where: isReturnKey) {
                return enter
            }
            let uniqueTitles = Set(buttons.compactMap(\.title))
            if uniqueTitles.count == 1, let only = buttons.first {
                return only
            }
            throw LatchError.dialogButtonNotFound(wanted: nil, available: titles)
        }

        @MainActor
        private static func isReturnKey(_ lens: Lens) -> Bool {
            (lens.object as? NSButton)?.keyEquivalent == "\r"
        }

        @MainActor
        private static func uniqueTitles(_ buttons: [Lens]) -> [String] {
            var seen = Set<String>()
            var result: [String] = []
            for title in buttons.compactMap(\.title) {
                if seen.insert(title).inserted {
                    result.append(title)
                }
            }
            return result
        }

        @MainActor
        private static func findAll(id: String) -> [Lens] {
            var hits: [Lens] = []
            for window in NSApplication.shared.windows {
                collect(id: id, in: .window(window), depth: 0, into: &hits)
            }
            return hits
        }

        @MainActor
        private static func collect(id: String, in lens: Lens, depth: Int, into hits: inout [Lens])
        {
            if lens.identifier == id { hits.append(lens) }
            guard depth < maxDepth else { return }
            for child in children(of: lens) {
                collect(id: id, in: child, depth: depth + 1, into: &hits)
            }
        }

        @MainActor
        private static func preferredHit(_ hits: [Lens]) -> Lens? {
            preferredOrder(hits).first
        }

        @MainActor
        private static func preferredOrder(_ hits: [Lens], action: String? = nil) -> [Lens] {
            hits.sorted { lhs, rhs in
                if let action {
                    let leftHas = hasNamedAction(action, on: lhs)
                    let rightHas = hasNamedAction(action, on: rhs)
                    if leftHas != rightHas { return leftHas }
                }
                if lhs.actionNames.count != rhs.actionNames.count {
                    return lhs.actionNames.count > rhs.actionNames.count
                }
                return lhs.isEnabled && !rhs.isEnabled
            }
        }

        @MainActor
        private static func hasNamedAction(_ name: String, on lens: Lens) -> Bool {
            let wanted = LatchCatalog.normalizeActionName(name)
            let aliases = LatchCatalog.actionAliases(for: wanted)
            return lens.customActions.contains { action in
                aliases.contains(LatchCatalog.normalizeActionName(action.name))
            } || (wanted == "press" && (lens.object is NSControl || lens.roleName == "button"))
        }

        @MainActor
        private static func snapshot(
            _ lens: Lens,
            depth: Int,
            remaining: inout Int,
            labeledOnly: Bool = false,
            inChrome: Bool = false
        ) -> LatchAXNode? {
            guard remaining > 0 else { return nil }
            let id = lens.identifier
            let role = lens.roleName
            let nextChrome = inChrome || isCopyChrome(lens)
            let childNodes: [LatchAXNode]
            if depth < maxDepth {
                childNodes = children(of: lens).compactMap {
                    snapshot(
                        $0,
                        depth: depth + 1,
                        remaining: &remaining,
                        labeledOnly: labeledOnly,
                        inChrome: nextChrome
                    )
                }
            } else {
                childNodes = []
            }
            let keep: Bool
            if labeledOnly {
                keep = id != nil || !childNodes.isEmpty
            } else {
                let hasCopy = lens.title != nil || lens.stringValue != nil
                keep =
                    id != nil || !childNodes.isEmpty || lens.isInteractive
                    || (hasCopy && (nextChrome || textRoles.contains(role)))
            }
            guard keep else { return nil }
            remaining -= 1
            return LatchAXNode(
                id: id,
                role: role,
                title: lens.title,
                value: lens.stringValue,
                enabled: lens.isEnabled,
                actions: lens.actionNames,
                frame: LatchAXFrame(lens.frame),
                children: childNodes
            )
        }

        @MainActor
        static func children(of lens: Lens) -> [Lens] {
            var seen = Set<ObjectIdentifier>()
            var result: [Lens] = []
            func append(_ child: Lens) {
                let identity = ObjectIdentifier(child.object)
                guard seen.insert(identity).inserted else { return }
                result.append(child)
            }
            // Toolbar and titlebar live in the window's AX children, not
            // inside contentView. Content stays first so existing dumps
            // keep the same leading child when both mention it.
            if case .window(let window) = lens, let content = window.contentView {
                append(.view(content))
            }
            if case .view(let view) = lens {
                for subview in view.subviews {
                    append(.view(subview))
                }
            }
            for child in lens.rawChildren.compactMap(Lens.init) {
                append(child)
            }
            return result
        }

        @MainActor
        private static func performNamedAction(_ name: String, on lens: Lens) -> Bool {
            let wanted = LatchCatalog.normalizeActionName(name)
            let aliases = LatchCatalog.actionAliases(for: wanted)
            if let match = lens.customActions.first(where: { action in
                aliases.contains(LatchCatalog.normalizeActionName(action.name))
            }) {
                return match.handler?() == true
            }
            if wanted == "press" {
                return performPress(on: lens)
            }
            return false
        }

        @MainActor
        private static func performPress(on lens: Lens) -> Bool {
            if lens.performCustomAction() { return true }
            if lens.performPress() { return true }
            if let control = lens.object as? NSControl {
                control.performClick(nil)
                return true
            }
            return false
        }

        @MainActor
        private static func setStringValue(_ value: String, on lens: Lens) -> Bool {
            if let textView = deepestTextView(in: lens) {
                textView.string = value
                NotificationCenter.default.post(
                    name: NSText.didChangeNotification, object: textView)
                return true
            }
            if let field = lens.object as? NSTextField {
                field.stringValue = value
                NotificationCenter.default.post(
                    name: NSControl.textDidChangeNotification, object: field)
                return true
            }
            return lens.setValue(value)
        }

        @MainActor
        private static func deepestTextView(in lens: Lens) -> NSTextView? {
            if let textView = lens.object as? NSTextView { return textView }
            if let scroll = lens.object as? NSScrollView,
                let textView = scroll.documentView as? NSTextView
            {
                return textView
            }
            if let view = lens.object as? NSView {
                for child in view.subviews {
                    if let hit = deepestTextView(in: .view(child)) { return hit }
                }
            }
            for child in children(of: lens) {
                if let hit = deepestTextView(in: child) { return hit }
            }
            return nil
        }
    }

    /// Feeds dragged and up events into a drag session's tracking loop.
    /// The loop calls `nextEvent` on the main thread; a timer in
    /// `NSEventTrackingRunLoopMode` is the only thing that runs there.
    @MainActor
    private final class LatchDragFeeder: NSObject {
        var pending: [(event: NSEvent, screen: CGPoint)]
        var upSeen = false
        let eventNumber: Int
        let upEvent: NSEvent
        let movesCursor: Bool

        init(
            eventNumber: Int,
            pending: [(event: NSEvent, screen: CGPoint)],
            up: NSEvent,
            movesCursor: Bool
        ) {
            self.eventNumber = eventNumber
            self.pending = pending
            self.upEvent = up
            self.movesCursor = movesCursor
        }

        @objc nonisolated func pump() {
            MainActor.assumeIsolated {
                self.postNext()
            }
        }

        @objc nonisolated func forceUp() {
            MainActor.assumeIsolated {
                guard !self.upSeen else { return }
                self.placeCursor(self.upEvent)
                self.releaseButton(before: self.upEvent)
                self.postSystemButton(self.upEvent)
                NSApp.postEvent(self.upEvent, atStart: true)
            }
        }

        func postNext() {
            guard !upSeen, !pending.isEmpty else { return }
            let next = pending.removeFirst()
            placeCursor(next.event, screen: next.screen)
            releaseButton(before: next.event)
            postSystemButton(next.event, screen: next.screen)
            NSApp.postEvent(next.event, atStart: true)
        }

        func sendRemaining() {
            var spins = 0
            while !upSeen, !pending.isEmpty, spins < 80 {
                let next = pending.removeFirst()
                placeCursor(next.event, screen: next.screen)
                releaseButton(before: next.event)
                postSystemButton(next.event, screen: next.screen)
                NSApp.sendEvent(next.event)
                spins += 1
                if upSeen { return }
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.016))
            }
        }

        /// The tracking loop keeps going while the button still reads
        /// as down. Release the reported button before mouse-up.
        private func releaseButton(before event: NSEvent) {
            guard event.type == .leftMouseUp else { return }
            LatchPressedButtons.end()
        }

        /// A dragging session ends on the system button, which an
        /// `NSEvent` does not press. Post the matching Quartz event
        /// from inside the tracking loop. No prompt if it is dropped.
        private func postSystemButton(_ event: NSEvent, screen: CGPoint? = nil) {
            guard movesCursor else { return }
            let point: CGPoint
            if let screen {
                point = screen
            } else if let window = event.window {
                point = window.convertPoint(toScreen: event.locationInWindow)
            } else {
                return
            }
            let type: CGEventType =
                event.type == .leftMouseUp ? .leftMouseUp : .leftMouseDragged
            LatchAX.postSystemMouse(type, atAppKit: point)
        }

        private func placeCursor(_ event: NSEvent, screen: CGPoint? = nil) {
            guard movesCursor else { return }
            if let screen {
                LatchAX.warpCursor(toAppKit: screen)
                return
            }
            if let window = event.window {
                LatchAX.warpCursor(toAppKit: window.convertPoint(toScreen: event.locationInWindow))
            }
        }
    }

    /// Reports the left mouse button down for a dragging session.
    /// An injected `NSEvent` does not change `NSEvent.pressedMouseButtons`.
    @MainActor
    private enum LatchPressedButtons {
        private static var installed = false

        static func begin() {
            guard !installed else { return }
            exchange()
            installed = true
        }

        static func end() {
            guard installed else { return }
            exchange()
            installed = false
        }

        private static func exchange() {
            let originalSel = NSSelectorFromString("pressedMouseButtons")
            let hookedSel = NSSelectorFromString("latch_pressedMouseButtons")
            guard let meta: AnyClass = object_getClass(NSEvent.self) else { return }
            guard
                let source = class_getClassMethod(
                    LatchPressedButtonSource.self,
                    #selector(LatchPressedButtonSource.pressedMouseButtons))
            else { return }
            if !installed {
                _ = class_addMethod(
                    meta, hookedSel,
                    method_getImplementation(source),
                    method_getTypeEncoding(source))
            }
            guard
                let original = class_getInstanceMethod(meta, originalSel),
                let hooked = class_getInstanceMethod(meta, hookedSel)
            else { return }
            method_exchangeImplementations(original, hooked)
        }
    }

    private final class LatchPressedButtonSource: NSObject {
        @objc class func pressedMouseButtons() -> Int { 1 }
    }

    /// `CFRunLoop` is not `Sendable`. The stop is a pointer write.
    private final class RunLoopStop: @unchecked Sendable {
        private let loop: CFRunLoop
        private let armed = Mutex(true)

        init(_ loop: CFRunLoop) { self.loop = loop }

        func stop() {
            guard armed.withLock({ $0 }) else { return }
            CFRunLoopStop(loop)
        }

        func disarm() {
            armed.withLock { $0 = false }
        }
    }

    @MainActor
    enum Lens {
        case window(NSWindow)
        case view(NSView)
        case element(NSAccessibilityElement)
        case object(NSObject)

        init?(_ object: Any) {
            if let window = object as? NSWindow {
                self = .window(window)
            } else if let view = object as? NSView {
                self = .view(view)
            } else if let element = object as? NSAccessibilityElement {
                self = .element(element)
            } else if let object = object as? NSObject {
                self = .object(object)
            } else {
                return nil
            }
        }

        var object: AnyObject {
            switch self {
            case .window(let window): return window
            case .view(let view): return view
            case .element(let element): return element
            case .object(let object): return object
            }
        }

        var identifier: String? {
            let raw: String?
            switch self {
            case .window(let window):
                raw =
                    nonempty(window.accessibilityIdentifier())
                    ?? windowIdentifier(window)
            case .view(let view):
                raw = nonempty(view.accessibilityIdentifier())
            case .element(let element):
                raw = nonempty(element.accessibilityIdentifier())
            case .object(let object):
                raw = nonempty(object.ax.accessibilityIdentifier?())
            }
            return raw
        }

        var roleName: String {
            let role: NSAccessibility.Role?
            switch self {
            case .window(let window): role = window.accessibilityRole()
            case .view(let view): role = view.accessibilityRole()
            case .element(let element): role = element.accessibilityRole()
            case .object(let object):
                role = object.ax.accessibilityRole?()
            }
            if let role {
                return axName(role.rawValue)
            }
            switch self {
            case .window: return "window"
            case .view: return "group"
            case .element, .object: return "unknown"
            }
        }

        var subroleName: String? {
            let subrole: NSAccessibility.Subrole?
            switch self {
            case .window(let window): subrole = window.accessibilitySubrole()
            case .view(let view): subrole = view.accessibilitySubrole()
            case .element(let element): subrole = element.accessibilitySubrole()
            case .object(let object):
                subrole = object.ax.accessibilitySubrole?()
            }
            guard let subrole else { return nil }
            let name = axName(subrole.rawValue)
            return name.isEmpty ? nil : name
        }

        var stringValue: String? {
            let value: Any?
            switch self {
            case .window(let window): value = window.accessibilityValue()
            case .view(let view): value = view.accessibilityValue()
            case .element(let element): value = element.accessibilityValue()
            case .object(let object): value = object.ax.accessibilityValue?()
            }
            if let text = value as? String { return nonempty(text) }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }

        var title: String? {
            switch self {
            case .window(let window):
                return nonempty(window.accessibilityTitle())
                    ?? nonempty(window.accessibilityLabel())
                    ?? nonempty(window.title)
            case .view(let view):
                return nonempty(view.accessibilityTitle())
                    ?? nonempty(view.accessibilityLabel())
            case .element(let element):
                return nonempty(element.accessibilityTitle())
                    ?? nonempty(element.accessibilityLabel())
            case .object(let object):
                return nonempty(object.ax.accessibilityTitle?())
                    ?? nonempty(object.ax.accessibilityLabel?())
            }
        }

        var isEnabled: Bool {
            switch self {
            case .window(let window): return window.isAccessibilityEnabled()
            case .view(let view): return view.isAccessibilityEnabled()
            case .element(let element): return element.isAccessibilityEnabled()
            case .object(let object):
                return object.ax.isAccessibilityEnabled?() ?? true
            }
        }

        var frame: NSRect {
            switch self {
            case .window(let window): return window.accessibilityFrame()
            case .view(let view): return view.accessibilityFrame()
            case .element(let element): return element.accessibilityFrame()
            case .object(let object):
                return object.ax.accessibilityFrame?() ?? .zero
            }
        }

        var parent: Any? {
            switch self {
            case .window(let window):
                return window.accessibilityParent()
            case .view(let view):
                return view.accessibilityParent()
            case .element(let element):
                return element.accessibilityParent()
            case .object(let object):
                return object.ax.accessibilityParent?()
            }
        }

        var rawChildren: [Any] {
            switch self {
            case .window(let window):
                return window.accessibilityChildren() ?? []
            case .view(let view):
                return mergedAXChildren(
                    view.accessibilityChildren(),
                    view.ax.accessibilityChildrenInNavigationOrder?()
                )
            case .element(let element):
                return mergedAXChildren(
                    element.accessibilityChildren(),
                    element.ax.accessibilityChildrenInNavigationOrder?()
                )
            case .object(let object):
                return mergedAXChildren(
                    object.ax.accessibilityChildren?(),
                    object.ax.accessibilityChildrenInNavigationOrder?()
                )
            }
        }

        var actionNames: [String] {
            var names: [String] = []
            if object is NSControl || roleName == "button" {
                names.append("press")
            }
            names.append(contentsOf: customActions.map(\.name))
            return names
        }

        var isInteractive: Bool {
            if ["button", "textfield", "checkbox", "radiobutton", "tab", "menuitem", "row"]
                .contains(roleName)
            {
                return true
            }
            return !customActions.isEmpty
        }

        var customActions: [NSAccessibilityCustomAction] {
            switch self {
            case .window(let window):
                return window.accessibilityCustomActions() ?? []
            case .view(let view):
                return view.accessibilityCustomActions() ?? []
            case .element(let element):
                return element.accessibilityCustomActions() ?? []
            case .object(let object):
                return object.ax.accessibilityCustomActions?() ?? []
            }
        }

        func performPress() -> Bool {
            switch self {
            case .window(let window): return window.accessibilityPerformPress()
            case .view(let view): return view.accessibilityPerformPress()
            case .element(let element): return element.accessibilityPerformPress()
            case .object(let object):
                return object.ax.accessibilityPerformPress?() ?? false
            }
        }

        func performCustomAction() -> Bool {
            customActions.contains { action in
                action.handler?() == true
            }
        }

        func setValue(_ value: String) -> Bool {
            switch self {
            case .window(let window):
                window.setAccessibilityValue(value)
            case .view(let view):
                view.setAccessibilityValue(value)
            case .element(let element):
                element.setAccessibilityValue(value)
            case .object(let object):
                guard object.responds(to: #selector(LatchAXSpeaking.setAccessibilityValue(_:)))
                else {
                    return false
                }
                object.ax.setAccessibilityValue?(value)
            }
            return true
        }
    }

    @objc private protocol LatchAXSpeaking: NSObjectProtocol {
        @objc optional func accessibilityIdentifier() -> String
        @objc optional func accessibilityRole() -> NSAccessibility.Role
        @objc optional func accessibilitySubrole() -> NSAccessibility.Subrole
        @objc optional func accessibilityValue() -> Any
        @objc optional func accessibilityTitle() -> String
        @objc optional func accessibilityLabel() -> String
        @objc optional func isAccessibilityEnabled() -> Bool
        @objc optional func accessibilityFrame() -> NSRect
        @objc optional func accessibilityParent() -> Any
        @objc optional func accessibilityChildren() -> [Any]
        @objc optional func accessibilityChildrenInNavigationOrder() -> [Any]
        @objc optional func accessibilityCustomActions() -> [NSAccessibilityCustomAction]
        @objc optional func accessibilityPerformPress() -> Bool
        @objc optional func setAccessibilityValue(_ value: Any)
    }

    extension NSObject {
        fileprivate var ax: LatchAXSpeaking {
            unsafeBitCast(self, to: LatchAXSpeaking.self)
        }
    }

    @MainActor
    private func mergedAXChildren(_ first: [Any]?, _ second: [Any]?) -> [Any] {
        var seen = Set<ObjectIdentifier>()
        var result: [Any] = []
        for child in (first ?? []) + (second ?? []) {
            if let object = child as AnyObject? {
                guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            }
            result.append(child)
        }
        return result
    }

    @MainActor
    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func axName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "AX", with: "").lowercased()
    }

    extension LatchAXNode {
        fileprivate func appending(children extra: [LatchAXNode]) -> LatchAXNode {
            guard !extra.isEmpty else { return self }
            return LatchAXNode(
                id: id,
                role: role,
                title: title,
                value: value,
                enabled: enabled,
                actions: actions,
                frame: frame,
                children: children + extra,
                window: window,
                parent: parent,
                kind: kind,
                choices: choices,
                description: description
            )
        }
    }

    @MainActor
    private func windowIdentifier(_ window: NSWindow) -> String? {
        guard let raw = window.identifier?.rawValue else { return nil }
        if raw.hasPrefix("window.") {
            return raw
        }
        return "window.\(raw)"
    }

    extension LatchAXFrame {
        static let zero = Self(x: 0, y: 0, width: 0, height: 0)

        init(_ rect: NSRect) {
            if rect.isNull || rect.isInfinite {
                self = .zero
            } else {
                self = Self(
                    x: rect.origin.x,
                    y: rect.origin.y,
                    width: rect.size.width,
                    height: rect.size.height
                )
            }
        }
    }

    extension NSApplication {
        fileprivate var applicationName: String? {
            NSRunningApplication.current.localizedName
        }
    }
#endif
