import Foundation
import Testing

@testable import LatchE2E

@Suite("Catalog snapshot")
struct CatalogSnapshotTests {
    private let dump: JSONValue = .object([
        "id": .string("app"),
        "role": .string("application"),
        "children": .array([
            .object([
                "id": .string("window.main"),
                "role": .string("window"),
                "children": .array([
                    .object([
                        "id": .string("editor.title"),
                        "role": .string("textfield"),
                        "value": .string("old"),
                    ]),
                    .object([
                        "id": .string("editor.save"),
                        "role": .string("button"),
                        "enabled": .bool(false),
                    ]),
                ]),
            ]),
            .object(["id": .string("gone.thing"), "role": .string("button")]),
        ]),
    ])

    @Test("flatten walks nested ids")
    func flatten() {
        let snapshot = CatalogSnapshot(dump: dump)
        #expect(snapshot.count == 5)
        #expect(
            snapshot.ids
                == ["app", "editor.save", "editor.title", "gone.thing", "window.main"])
        #expect(snapshot.node("editor.title")?.value == "old")
        #expect(snapshot.node("editor.save")?.enabled == false)
        #expect(snapshot.node("missing") == nil)
    }

    @Test("diff reports added removed changed")
    func diff() throws {
        let before = CatalogSnapshot(dump: dump)
        let afterDump: JSONValue = .object([
            "id": .string("app"),
            "children": .array([
                .object([
                    "id": .string("window.main"),
                    "children": .array([
                        .object([
                            "id": .string("editor.title"),
                            "value": .string("new"),
                        ]),
                        .object([
                            "id": .string("editor.save"),
                            "enabled": .bool(true),
                        ]),
                        .object(["id": .string("composer.title"), "value": .string("")]),
                    ]),
                ])
            ]),
        ])
        let after = CatalogSnapshot(dump: afterDump)
        let diff = after.diffed(from: before)
        #expect(diff.added == ["composer.title"])
        #expect(diff.removed == ["gone.thing"])
        #expect(diff.changed == ["editor.save", "editor.title"])
        #expect(!diff.isEmpty)
        #expect(diff.summary.contains("added composer.title"))
        #expect(diff.summary.contains("removed gone.thing"))
        #expect(diff.summary.contains("changed editor.save, editor.title"))
    }

    @Test("identical snapshots diff to empty")
    func identicalDiff() {
        let diff = CatalogSnapshot(dump: dump).diffed(from: CatalogSnapshot(dump: dump))
        #expect(diff.isEmpty)
        #expect(diff.summary == "no catalog changes")
    }

    @Test("state hash is stable and value-sensitive")
    func stateHash() {
        let first = CatalogSnapshot(dump: dump)
        #expect(first.stateHash == CatalogSnapshot(dump: dump).stateHash)
        #expect(first.stateHash.count == 64)

        var tweaked = dump
        tweaked["children"]?[0]?["children"]?[0]?["value"] = .string("changed")
        #expect(CatalogSnapshot(dump: tweaked).stateHash != first.stateHash)
    }

    @Test("value renders booleans as protocol text")
    func valueText() {
        let boolNode = CatalogNode(
            json: .object([
                "id": .string("toggle"), "value": .bool(true),
            ]))
        #expect(boolNode?.value == "true")
        let numberNode = CatalogNode(
            json: .object([
                "id": .string("count"), "value": .number(3),
            ]))
        #expect(numberNode?.value == "3")
        #expect(CatalogNode(json: .object(["role": .string("button")])) == nil)
    }
}

@Suite("Expectation helpers")
struct ExpectationHelperTests {
    @Test("subsequence matches ordered with gaps")
    func subsequence() {
        #expect(Expectation.isSubsequence(["a", "c"], of: ["a", "b", "c"]))
        #expect(Expectation.isSubsequence(["a", "c"], of: ["a", "b", "c", "d"]))
        #expect(!Expectation.isSubsequence(["c", "a"], of: ["a", "b", "c"]))
        #expect(Expectation.isSubsequence([], of: []))
        #expect(!Expectation.isSubsequence(["a"], of: []))
    }

    @Test("stall watcher arms on first dump and fires after the window")
    func stallWatcher() throws {
        var watcher = StallWatcher(window: 5)
        let snapshot = CatalogSnapshot(
            dump: .object([
                "id": .string("editor.title"), "value": .string("old"),
            ]))
        let started = Date()
        #expect(watcher.check(snapshot: snapshot, at: started) == nil)
        #expect(watcher.check(snapshot: snapshot, at: started.addingTimeInterval(4.9)) == nil)

        let stalled = watcher.check(snapshot: snapshot, at: started.addingTimeInterval(5.1))
        guard case .stalled(let stableSeconds, _)? = stalled else {
            Issue.record("expected a stall, got \(String(describing: stalled))")
            return
        }
        #expect(stableSeconds == 5)
    }

    @Test("stall watcher resets on catalog movement")
    func stallWatcherResets() {
        var watcher = StallWatcher(window: 5)
        let before = CatalogSnapshot(
            dump: .object([
                "id": .string("editor.title"), "value": .string("old"),
            ]))
        let started = Date()
        #expect(watcher.check(snapshot: before, at: started) == nil)

        let after = CatalogSnapshot(
            dump: .object([
                "id": .string("editor.title"), "value": .string("new"),
            ]))
        #expect(
            watcher.check(snapshot: after, at: started.addingTimeInterval(10)) == nil)
    }

    @Test("empty catalog never arms the watcher")
    func emptyCatalogDoesNotArm() {
        var watcher = StallWatcher(window: 0.01)
        let empty = CatalogSnapshot(dump: .object(["id": .string("app")]))
        #expect(
            watcher.check(snapshot: empty, at: Date().addingTimeInterval(60)) == nil)
    }
}

@Suite("Envelope decoding")
struct EnvelopeTests {
    @Test("success envelope with data")
    func successEnvelope() throws {
        let raw = Data(
            #"{"ok":true,"data":{"status":"ok","boot":"ready","windows":1,"catalog":3}}"#.utf8)
        let envelope = try JSONDecoder().decode(JSONValue.self, from: raw)
        #expect(envelope["ok"]?.boolValue == true)
        #expect(envelope["data"]?["boot"]?.stringValue == "ready")
        #expect(envelope["data"]?["windows"]?.intValue == 1)
    }

    @Test("failure envelope carries code and message")
    func failureEnvelope() throws {
        let raw = Data(
            #"{"ok":false,"error":{"code":"notFound","message":"No catalog entry with id editor.sav."}}"#
                .utf8)
        let envelope = try JSONDecoder().decode(JSONValue.self, from: raw)
        #expect(envelope["ok"]?.boolValue != true)
        #expect(envelope["error"]?["code"]?.stringValue == "notFound")
        #expect(envelope["error"]?["message"]?.stringValue?.contains("editor.sav") == true)
    }
}
