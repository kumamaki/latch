#if DEBUG
    import AppKit
    import Foundation

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
