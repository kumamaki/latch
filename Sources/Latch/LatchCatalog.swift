import AppKit
import Foundation

/// Scene catalog. `.latch` registers here in every build. The DEBUG
/// socket reads the same table; it does not own it.
@MainActor
public enum LatchCatalog {
    /// Value schema. Distinct from `role`, which is chrome.
    public enum Kind: String, Sendable, Codable, Equatable {
        case bool
        case `enum`
        case int
        case uint64
        case double
        case text
        case time
        case weekdays
        case action
        case window
        case label
    }

    public struct Node: Equatable, Sendable {
        public let id: String
        public let role: String
        public let title: String?
        public let value: String?
        public let enabled: Bool
        public let actions: [String]
        public let window: String?
        public let kind: Kind?
        public let choices: [String]?
        public let description: String?

        public init(
            id: String,
            role: String,
            title: String? = nil,
            value: String? = nil,
            enabled: Bool = true,
            actions: [String] = [],
            window: String? = nil,
            kind: Kind? = nil,
            choices: [String]? = nil,
            description: String? = nil
        ) {
            self.id = id
            self.role = role
            self.title = title
            self.value = value
            self.enabled = enabled
            self.actions = actions
            self.window = window
            self.kind = kind
            self.choices = choices
            self.description = description
        }
    }

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case duplicate(id: String)
        case notFound(id: String, nearby: [String] = [])
        case actionUnavailable(id: String, action: String)
        case invalidValue(id: String, value: String, expected: String)

        public var description: String {
            switch self {
            case .duplicate(let id):
                return "Catalog already has id \(id) from another owner."
            case .notFound(let id, let nearby):
                return LatchCatalog.notFoundMessage(id: id, nearby: nearby)
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
            description: String? = nil,
            value: @escaping () -> String? = { nil },
            enabled: @escaping @autoclosure () -> Bool = true,
            actions: [String] = [],
            window: String? = nil,
            kind: Kind? = nil,
            choices: [String]? = nil,
            press: ((String?) throws -> Void)? = nil,
            set: ((String) throws -> Void)? = nil
        ) {
            guard !Latch.isPreviewProcess else { return }
            if currentID != id {
                clear()
                currentID = id
            }
            do {
                try LatchCatalog.register(
                    id: id,
                    role: role,
                    title: title,
                    description: description,
                    value: value,
                    enabled: enabled,
                    actions: actions,
                    window: window,
                    kind: kind,
                    choices: choices,
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
        var enabled: () -> Bool
        var press: ((String?) throws -> Void)?
        var set: ((String) throws -> Void)?
    }

    private static var entries: [String: Entry] = [:]
    private static let windowSyncToken = Token()
    private static var updateSubscribers: [UUID: UpdateSubscriber] = [:]
    private static var updateFlushScheduled = false
    private static var updateGeneration = 0

    private struct UpdateSubscriber {
        let window: String?
        let continuation: AsyncStream<[Node]>.Continuation
    }

    public static func reset() {
        entries.removeAll()
        updateFlushScheduled = false
        updateGeneration += 1
        for subscriber in updateSubscribers.values {
            subscriber.continuation.finish()
        }
        updateSubscribers.removeAll()
    }

    static func updates(window: String? = nil) -> AsyncStream<[Node]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[Node]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        updateSubscribers[id] = UpdateSubscriber(
            window: window, continuation: continuation)
        continuation.yield(snapshot(window: window))
        continuation.onTermination = { _ in
            Task { @MainActor in
                updateSubscribers.removeValue(forKey: id)
            }
        }
        return stream
    }

    private static func notifyChanged() {
        guard !updateSubscribers.isEmpty else { return }
        guard !updateFlushScheduled else { return }
        updateFlushScheduled = true
        let generation = updateGeneration
        Task { @MainActor in
            guard generation == updateGeneration else { return }
            updateFlushScheduled = false
            for subscriber in updateSubscribers.values {
                subscriber.continuation.yield(snapshot(window: subscriber.window))
            }
        }
    }

    public static func register(
        id: String,
        role: String,
        title: String? = nil,
        description: String? = nil,
        value: @escaping () -> String? = { nil },
        enabled: @escaping () -> Bool = { true },
        actions: [String] = [],
        window: String? = nil,
        kind: Kind? = nil,
        choices: [String]? = nil,
        token: Token,
        press: ((String?) throws -> Void)? = nil,
        set: ((String) throws -> Void)? = nil
    ) throws {
        let owner = ObjectIdentifier(token)
        if let existing = entries[id], existing.token != owner {
            throw Error.duplicate(id: id)
        }
        let resolvedChoices = (choices?.isEmpty == true) ? nil : choices
        entries[id] = Entry(
            token: owner,
            node: Node(
                id: id,
                role: role,
                title: title,
                value: nil,
                enabled: true,
                actions: actions,
                window: window,
                kind: kind,
                choices: resolvedChoices,
                description: description
            ),
            value: value,
            enabled: enabled,
            press: press,
            set: set
        )
        notifyChanged()
    }

    public static func unregister(id: String, token: Token) {
        guard let existing = entries[id] else { return }
        guard existing.token == ObjectIdentifier(token) else { return }
        entries.removeValue(forKey: id)
        notifyChanged()
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
        guard let entry = entries[id] else { throw missing(id: id) }
        return resolved(entry)
    }

    private static func resolved(_ entry: Entry) -> Node {
        Node(
            id: entry.node.id,
            role: entry.node.role,
            title: entry.node.title,
            value: entry.value(),
            enabled: entry.enabled(),
            actions: entry.node.actions,
            window: entry.node.window,
            kind: entry.node.kind,
            choices: entry.node.choices,
            description: entry.node.description
        )
    }

    public static func press(id: String, action: String? = nil) throws {
        guard let entry = entries[id] else { throw missing(id: id) }
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
        guard let entry = entries[id] else { throw missing(id: id) }
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
                kind: .window,
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

    public static func enumChoices<Value: CaseIterable>(
        _ type: Value.Type
    ) -> [String] where Value: RawRepresentable, Value.RawValue == String {
        type.allCases.map(\.rawValue)
    }

    nonisolated public static func notFoundMessage(id: String, nearby: [String]) -> String {
        var message = "No catalog entry with id \(id)."
        if !nearby.isEmpty {
            message += " Nearby: \(nearby.joined(separator: ", "))."
        }
        message += " Register it with .latch. Do not pin AX."
        return message
    }

    private static func missing(id: String) -> Error {
        .notFound(id: id, nearby: nearbyIDs(for: id))
    }

    static func nearbyIDs(for wanted: String, limit: Int = 5) -> [String] {
        let ids = entries.keys.sorted()
        var prefix: [String] = []
        var rest: [String] = []
        for id in ids {
            if id.hasPrefix(wanted) || wanted.hasPrefix(id) {
                prefix.append(id)
            } else {
                rest.append(id)
            }
        }
        let ranked = rest.sorted { lhs, rhs in
            let left = editDistance(lhs, wanted)
            let right = editDistance(rhs, wanted)
            if left != right { return left < right }
            return lhs < rhs
        }
        return Array((prefix + ranked).prefix(limit))
    }

    private static func editDistance(_ first: String, _ second: String) -> Int {
        let firstChars = Array(first)
        let secondChars = Array(second)
        if firstChars.isEmpty { return secondChars.count }
        if secondChars.isEmpty { return firstChars.count }
        var previous = Array(0...secondChars.count)
        var current = Array(repeating: 0, count: secondChars.count + 1)
        for i in 1...firstChars.count {
            current[0] = i
            for j in 1...secondChars.count {
                let cost = firstChars[i - 1] == secondChars[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }
        return previous[secondChars.count]
    }

    private static func windowCatalogID(_ window: NSWindow) -> String? {
        guard let raw = window.identifier?.rawValue else { return nil }
        if raw.hasPrefix("window.") {
            return raw
        }
        return "window.\(raw)"
    }
}
