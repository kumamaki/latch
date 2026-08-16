import AppKit
import Foundation

/// Scene catalog. `.latch` registers here in every build. The DEBUG
/// socket reads the same table; it does not own it.
@MainActor
public enum LatchCatalog {
    public struct Node: Equatable, Sendable {
        public let id: String
        public let role: String
        public let title: String?
        public let value: String?
        public let enabled: Bool
        public let actions: [String]
        public let window: String?

        public init(
            id: String,
            role: String,
            title: String? = nil,
            value: String? = nil,
            enabled: Bool = true,
            actions: [String] = [],
            window: String? = nil
        ) {
            self.id = id
            self.role = role
            self.title = title
            self.value = value
            self.enabled = enabled
            self.actions = actions
            self.window = window
        }
    }

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case duplicate(id: String)
        case notFound(id: String)
        case actionUnavailable(id: String, action: String)
        case invalidValue(id: String, value: String, expected: String)

        public var description: String {
            switch self {
            case .duplicate(let id):
                return "Catalog already has id \(id) from another owner."
            case .notFound(let id):
                return "No catalog entry with id \(id)."
            case .actionUnavailable(let id, let action):
                return "Catalog entry \(id) cannot \(action)."
            case .invalidValue(let id, let value, let expected):
                return "Catalog entry \(id) expected \(expected), got \(value)."
            }
        }
    }

    public final class Token: NSObject {}

    /// Owns one catalog id for an AppKit row that can recycle.
    @MainActor
    public final class Binding {
        private let token = Token()
        private var currentID: String?

        public init() {}

        public func publish(
            id: String,
            role: String,
            title: String? = nil,
            value: @escaping () -> String? = { nil },
            enabled: Bool = true,
            actions: [String] = [],
            window: String? = nil,
            press: ((String?) throws -> Void)? = nil,
            set: ((String) throws -> Void)? = nil
        ) {
            if currentID != id {
                clear()
                currentID = id
            }
            do {
                try LatchCatalog.register(
                    id: id,
                    role: role,
                    title: title,
                    value: value,
                    enabled: enabled,
                    actions: actions,
                    window: window,
                    token: token,
                    press: press,
                    set: set
                )
            } catch {
                assertionFailure("Latch catalog: \(error)")
            }
        }

        public func clear() {
            guard let id = currentID else { return }
            LatchCatalog.unregister(id: id, token: token)
            currentID = nil
        }
    }

    private struct Entry {
        let token: ObjectIdentifier
        var node: Node
        var value: () -> String?
        var press: ((String?) throws -> Void)?
        var set: ((String) throws -> Void)?
    }

    private static var entries: [String: Entry] = [:]
    private static let windowSyncToken = Token()

    public static func reset() {
        entries.removeAll()
    }

    public static func register(
        id: String,
        role: String,
        title: String? = nil,
        value: @escaping () -> String? = { nil },
        enabled: Bool = true,
        actions: [String] = [],
        window: String? = nil,
        token: Token,
        press: ((String?) throws -> Void)? = nil,
        set: ((String) throws -> Void)? = nil
    ) throws {
        let owner = ObjectIdentifier(token)
        if let existing = entries[id], existing.token != owner {
            throw Error.duplicate(id: id)
        }
        entries[id] = Entry(
            token: owner,
            node: Node(
                id: id,
                role: role,
                title: title,
                value: nil,
                enabled: enabled,
                actions: actions,
                window: window
            ),
            value: value,
            press: press,
            set: set
        )
    }

    public static func unregister(id: String, token: Token) {
        guard let existing = entries[id] else { return }
        guard existing.token == ObjectIdentifier(token) else { return }
        entries.removeValue(forKey: id)
    }

    public static func snapshot(window: String? = nil) -> [Node] {
        entries.values
            .map(resolved)
            .filter { node in
                guard let window else { return true }
                return node.window == window || node.id == "window.\(window)"
            }
            .sorted { $0.id < $1.id }
    }

    public static func find(id: String) throws -> Node {
        guard let entry = entries[id] else { throw Error.notFound(id: id) }
        return resolved(entry)
    }

    private static func resolved(_ entry: Entry) -> Node {
        Node(
            id: entry.node.id,
            role: entry.node.role,
            title: entry.node.title,
            value: entry.value(),
            enabled: entry.node.enabled,
            actions: entry.node.actions,
            window: entry.node.window
        )
    }

    public static func press(id: String, action: String? = nil) throws {
        guard let entry = entries[id] else { throw Error.notFound(id: id) }
        let wanted = action ?? "press"
        guard let press = entry.press else {
            throw Error.actionUnavailable(id: id, action: wanted)
        }
        if let action {
            let aliases = actionAliases(for: normalizeActionName(action))
            let known = entry.node.actions.map(normalizeActionName)
            let matchesKnown = known.contains { aliases.contains($0) }
            if !matchesKnown && normalizeActionName(action) != "press" {
                throw Error.actionUnavailable(id: id, action: action)
            }
        }
        try press(action)
    }

    public static func set(id: String, value: String) throws {
        guard let entry = entries[id] else { throw Error.notFound(id: id) }
        guard let set = entry.set else {
            throw Error.actionUnavailable(id: id, action: "set")
        }
        try set(value)
    }

    /// Refresh `window.*` entries from the live `NSApp` window list.
    ///
    /// Only owns rows this helper registered. `.latchWindow` keeps its
    /// own token, so a dump cannot steal `window.main` out from under it.
    public static func syncWindows() {
        let app = NSApplication.shared
        guard app.isRunning else { return }
        let token = windowSyncToken
        let owner = ObjectIdentifier(token)
        let liveIDs = Set(
            app.windows.compactMap { window -> String? in
                guard window.isVisible || window.isMiniaturized else { return nil }
                return windowCatalogID(window)
            }
        )
        for entry in entries.values
        where entry.node.role == "window" && entry.token == owner {
            if !liveIDs.contains(entry.node.id) {
                unregister(id: entry.node.id, token: token)
            }
        }
        for window in app.windows where window.isVisible || window.isMiniaturized {
            guard let id = windowCatalogID(window) else { continue }
            if entries[id] != nil { continue }
            let name = String(id.dropFirst("window.".count))
            try? register(
                id: id,
                role: "window",
                title: window.title.isEmpty ? nil : window.title,
                window: name,
                token: token
            )
        }
    }

    public static func actionAliases(for wanted: String) -> Set<String> {
        [wanted]
    }

    public static func normalizeActionName(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    public static func formatBool(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    public static func parseBool(id: String, _ raw: String) throws -> Bool {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true": return true
        case "false": return false
        default:
            throw Error.invalidValue(id: id, value: raw, expected: "true or false")
        }
    }

    public static func parseEnum<Value: RawRepresentable>(
        id: String,
        _ raw: String,
        as type: Value.Type = Value.self
    ) throws -> Value where Value.RawValue == String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = type.init(rawValue: trimmed) else {
            throw Error.invalidValue(id: id, value: raw, expected: "a \(type) rawValue")
        }
        return value
    }

    public static func parseInt(id: String, _ raw: String) throws -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed) else {
            throw Error.invalidValue(id: id, value: raw, expected: "an integer")
        }
        return value
    }

    public static func parseUInt64(id: String, _ raw: String) throws -> UInt64 {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = UInt64(trimmed) else {
            throw Error.invalidValue(id: id, value: raw, expected: "an unsigned integer")
        }
        return value
    }

    public static func parseDouble(id: String, _ raw: String) throws -> Double {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed) else {
            throw Error.invalidValue(id: id, value: raw, expected: "a number")
        }
        return value
    }

    public static func formatTime(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    public static func parseTime(id: String, _ raw: String) throws -> (hour: Int, minute: Int) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
            let hour = Int(parts[0]),
            let minute = Int(parts[1]),
            (0...23).contains(hour),
            (0...59).contains(minute)
        else {
            throw Error.invalidValue(id: id, value: raw, expected: "HH:MM")
        }
        return (hour, minute)
    }

    public static let weekdayNames = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]

    public static func formatWeekdays(_ names: [String]) -> String {
        let wanted = Set(names.map { $0.lowercased() })
        return weekdayNames.filter { wanted.contains($0) }.joined(separator: ",")
    }

    public static func parseWeekdays(id: String, _ raw: String) throws -> Set<String> {
        let parts = raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty }
        var days = Set<String>()
        for part in parts {
            guard weekdayNames.contains(part) else {
                throw Error.invalidValue(
                    id: id, value: part, expected: "monday,tuesday,…")
            }
            days.insert(part)
        }
        return days
    }

    private static func windowCatalogID(_ window: NSWindow) -> String? {
        guard let raw = window.identifier?.rawValue else { return nil }
        if raw.hasPrefix("window.") {
            return raw
        }
        return "window.\(raw)"
    }
}
