import CryptoKit
import Foundation

/// One labeled catalog node, flattened out of an axDump response.
public struct CatalogNode: Sendable, Equatable {
    public let id: String
    public let role: String?
    public let title: String?
    public let value: String?
    public let enabled: Bool?

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue else { return nil }
        self.id = id
        self.role = json["role"]?.stringValue
        self.title = json["title"]?.stringValue
        self.value = Self.text(json["value"])
        self.enabled = json["enabled"]?.boolValue
    }

    /// Catalog values are strings on the wire; booleans and numbers
    /// render as their protocol text so a `--value true` style match
    /// still works against toggles.
    static func text(_ json: JSONValue?) -> String? {
        guard let json else { return nil }
        switch json {
        case .string(let value):
            return value
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(value))
                : String(value)
        case .null:
            return nil
        case .array, .object:
            return nil
        }
    }
}

/// The whole labeled catalog reduced to one entry per id. This is the
/// diff baseline and the stall detector's input.
public struct CatalogSnapshot: Sendable, Equatable {
    private var nodesById: [String: CatalogNode]

    public init(dump: JSONValue) {
        var nodes: [String: CatalogNode] = [:]
        Self.walk(dump, into: &nodes)
        nodesById = nodes
    }

    private static func walk(_ node: JSONValue, into nodes: inout [String: CatalogNode]) {
        if let parsed = CatalogNode(json: node) {
            nodes[parsed.id] = parsed
        }
        for child in node["children"]?.arrayValue ?? [] {
            walk(child, into: &nodes)
        }
    }

    public var ids: [String] {
        nodesById.keys.sorted()
    }

    public var count: Int {
        nodesById.count
    }

    public func node(_ id: String) -> CatalogNode? {
        nodesById[id]
    }

    /// Added / removed / changed relative to a baseline. Changed means
    /// the value or the enabled flag moved.
    public func diffed(from baseline: CatalogSnapshot) -> CatalogDiff {
        let added = ids.filter { baseline.nodesById[$0] == nil }
        let removed = baseline.ids.filter { nodesById[$0] == nil }
        let changed = ids.filter { id -> Bool in
            guard let before = baseline.nodesById[id], let after = nodesById[id] else {
                return false
            }
            return before.value != after.value || before.enabled != after.enabled
        }
        return CatalogDiff(added: added, removed: removed, changed: changed)
    }

    /// Stable content hash over id+value+enabled. The stall detector
    /// hashes this every second; equal hashes mean the catalog sat
    /// still, regardless of AX tree churn the catalog does not model.
    public var stateHash: String {
        let lines = ids.map { id -> String in
            let node = nodesById[id]!
            let enabled = node.enabled.map { $0 ? "true" : "false" } ?? "-"
            return "\(id)=\(node.value ?? "-")=\(enabled)"
        }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// What one mutating action did to the catalog.
public struct CatalogDiff: Sendable, Equatable {
    public let added: [String]
    public let removed: [String]
    public let changed: [String]

    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty
    }

    public var summary: String {
        if isEmpty { return "no catalog changes" }
        var parts: [String] = []
        if !added.isEmpty { parts.append("added \(added.joined(separator: ", "))") }
        if !removed.isEmpty { parts.append("removed \(removed.joined(separator: ", "))") }
        if !changed.isEmpty { parts.append("changed \(changed.joined(separator: ", "))") }
        return parts.joined(separator: "; ")
    }
}
