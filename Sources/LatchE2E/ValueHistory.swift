import Foundation

/// One value a history-recorded catalog id published.
public struct HistoryEntry: Sendable, Equatable, CustomStringConvertible {
    /// Milliseconds on the app's monotonic history clock.
    public let milliseconds: Int
    public let value: String

    init?(json: JSONValue) {
        guard let milliseconds = json["at"]?.intValue, let value = json["value"]?.stringValue
        else { return nil }
        self.milliseconds = milliseconds
        self.value = value
    }

    public var description: String {
        "\(value)@\(milliseconds)ms"
    }
}
