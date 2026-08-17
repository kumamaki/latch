import AppKit
import SwiftUI
import Testing

@testable import Latch

@Suite(.serialized)
@MainActor
struct LatchCatalogTests {
    init() {
        LatchCatalog.reset()
        Latch.previewProcessOverride = nil
    }

    @Test("register then find and set")
    @MainActor
    func registerFindSet() throws {
        let token = LatchCatalog.Token()
        var stored = "old"
        try LatchCatalog.register(
            id: "editor.title",
            role: "textfield",
            title: "Title",
            value: { stored },
            actions: ["set"],
            window: "main",
            token: token,
            set: { stored = $0 }
        )

        try LatchCatalog.set(id: "editor.title", value: "Hello")
        let node = try LatchCatalog.find(id: "editor.title")
        #expect(node.value == "Hello")
        #expect(stored == "Hello")
    }

    @Test("same-role remount takes the id")
    @MainActor
    func sameRoleTakeover() throws {
        let first = LatchCatalog.Token()
        let second = LatchCatalog.Token()
        try LatchCatalog.register(
            id: "editor.save", role: "button", title: "Old", token: first,
            press: { _ in })
        try LatchCatalog.register(
            id: "editor.save", role: "button", title: "New", token: second,
            press: { _ in })
        #expect(try LatchCatalog.find(id: "editor.save").title == "New")
        LatchCatalog.unregister(id: "editor.save", token: first)
        #expect(try LatchCatalog.find(id: "editor.save").title == "New")
    }

    @Test("role clash from another owner fails loud")
    @MainActor
    func roleClashFails() throws {
        let first = LatchCatalog.Token()
        let second = LatchCatalog.Token()
        try LatchCatalog.register(
            id: "editor.save", role: "button", token: first, press: { _ in })
        #expect(throws: LatchCatalog.Error.duplicate(id: "editor.save")) {
            try LatchCatalog.register(
                id: "editor.save", role: "textfield", token: second)
        }
    }

    @Test("same owner can re-register")
    @MainActor
    func sameOwnerUpserts() throws {
        let token = LatchCatalog.Token()
        try LatchCatalog.register(
            id: "editor.save", role: "button", title: "Save", token: token,
            press: { _ in })
        try LatchCatalog.register(
            id: "editor.save", role: "button", title: "Saved", token: token,
            press: { _ in })
        #expect(try LatchCatalog.find(id: "editor.save").title == "Saved")
    }

    @Test("unregister removes the node")
    @MainActor
    func unregisterRemoves() throws {
        let token = LatchCatalog.Token()
        try LatchCatalog.register(id: "editor.save", role: "button", token: token)
        LatchCatalog.unregister(id: "editor.save", token: token)
        #expect(throws: LatchCatalog.Error.notFound(id: "editor.save")) {
            try LatchCatalog.find(id: "editor.save")
        }
    }

    @Test("press unknown action fails")
    @MainActor
    func pressUnknownFails() throws {
        let token = LatchCatalog.Token()
        try LatchCatalog.register(
            id: "row.1",
            role: "row",
            actions: ["start"],
            token: token,
            press: { _ in }
        )
        #expect(
            throws: LatchCatalog.Error.actionUnavailable(id: "row.1", action: "stop")
        ) {
            try LatchCatalog.press(id: "row.1", action: "stop")
        }
    }

    @Test("set without handler fails")
    @MainActor
    func setWithoutHandlerFails() throws {
        let token = LatchCatalog.Token()
        try LatchCatalog.register(id: "editor.save", role: "button", token: token)
        #expect(
            throws: LatchCatalog.Error.actionUnavailable(id: "editor.save", action: "set")
        ) {
            try LatchCatalog.set(id: "editor.save", value: "x")
        }
    }

    @Test("parse helpers fail loud on bad values")
    @MainActor
    func parseHelpersFailLoud() throws {
        #expect(try LatchCatalog.parseBool(id: "x", "true"))
        #expect(
            throws: LatchCatalog.Error.invalidValue(
                id: "x", value: "yes", expected: "true or false")
        ) {
            try LatchCatalog.parseBool(id: "x", "yes")
        }
        #expect(try LatchCatalog.parseInt(id: "n", "12") == 12)
        #expect(try LatchCatalog.parseDouble(id: "n", "1.25") == 1.25)
        #expect(
            throws: LatchCatalog.Error.invalidValue(
                id: "n", value: "loud", expected: "a number")
        ) {
            try LatchCatalog.parseDouble(id: "n", "loud")
        }
        let time = try LatchCatalog.parseTime(id: "t", "09:30")
        #expect(time.hour == 9)
        #expect(time.minute == 30)
        #expect(
            try LatchCatalog.parseWeekdays(id: "d", "monday,friday")
                == ["monday", "friday"]
        )
        #expect(
            throws: LatchCatalog.Error.invalidValue(
                id: "d", value: "funday", expected: "monday,tuesday,…")
        ) {
            try LatchCatalog.parseWeekdays(id: "d", "funday")
        }
    }

    @Test("labeled dump nests controls under their window")
    @MainActor
    func labeledDumpNests() throws {
        let token = LatchCatalog.Token()
        try LatchCatalog.register(
            id: "window.main", role: "window", title: "Notes",
            window: "main", token: token)
        try LatchCatalog.register(
            id: "editor.title", role: "textfield", value: { "Hello" },
            window: "main", token: token)
        let tree = LatchCatalogDump.tree(window: "main", title: "Notes")
        #expect(tree.role == "application")
        #expect(tree.children.count == 1)
        #expect(tree.children[0].id == "window.main")
        #expect(tree.children[0].children.map(\.id) == ["editor.title"])
        #expect(tree.children[0].children[0].value == "Hello")
    }

    @Test("control window: nests under its window without a window row")
    @MainActor
    func controlWindowNestsWithoutWindowRow() throws {
        let token = LatchCatalog.Token()
        try LatchCatalog.register(
            id: "editor.save", role: "button", window: "main", token: token)
        do {
            _ = try LatchCatalog.find(id: "window.main")
            Issue.record("expected window.main to be missing")
        } catch let error as LatchCatalog.Error {
            guard case .notFound(let id, _) = error else {
                Issue.record("expected notFound, got \(error)")
                return
            }
            #expect(id == "window.main")
        }
        let tree = LatchCatalogDump.tree(window: nil, title: "Notes")
        #expect(tree.children.map(\.id) == ["editor.save"])
    }

    @Test("latchWindow identity matches name and window.name")
    @MainActor
    func latchWindowIdentityMatches() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        LatchWindowIdentity.apply(name: "main", to: window)
        #expect(window.identifier?.rawValue == "main")
        #expect(LatchAX.windowMatches(window, name: "main"))
    }

    @Test("namespaced window identifiers still match the short name")
    @MainActor
    func namespacedWindowIdentifiersMatch() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.identifier = NSUserInterfaceItemIdentifier("pulli.window.fetchBox")
        window.setAccessibilityIdentifier("window.fetchBox")
        #expect(LatchAX.windowMatches(window, name: "fetchBox"))
        #expect(LatchAX.catalogName(from: "pulli.window.fetchBox") == "fetchBox")
        #expect(LatchAX.catalogName(from: "window.fetchBox") == "fetchBox")
    }

    @Test("in-process Latch surface matches the catalog")
    @MainActor
    func inProcessSurface() throws {
        let token = LatchCatalog.Token()
        var stored = "old"
        try LatchCatalog.register(
            id: "editor.title",
            role: "textfield",
            value: { stored },
            actions: ["set"],
            token: token,
            set: { stored = $0 }
        )
        try Latch.set(id: "editor.title", value: "Hello")
        #expect(try Latch.find(id: "editor.title").value == "Hello")
        #expect(Latch.snapshot().map(\.id) == ["editor.title"])
    }

    @Test("kind choices and description round-trip on snapshot")
    @MainActor
    func kindChoicesDescriptionRoundTrip() throws {
        enum Appearance: String, CaseIterable {
            case light, dark
        }
        let token = LatchCatalog.Token()
        try LatchCatalog.register(
            id: "prefs.appearance",
            role: "popup",
            title: "Appearance",
            description: "Color scheme",
            value: { Appearance.dark.rawValue },
            actions: ["set"],
            window: "main",
            kind: .enum,
            choices: LatchCatalog.enumChoices(Appearance.self),
            token: token
        )
        let node = try LatchCatalog.find(id: "prefs.appearance")
        #expect(node.kind == .enum)
        #expect(node.choices == ["light", "dark"])
        #expect(node.description == "Color scheme")
        let leaf = try LatchCatalogDump.node(id: "prefs.appearance")
        #expect(leaf.kind == .enum)
        #expect(leaf.choices == ["light", "dark"])
        #expect(leaf.description == "Color scheme")
    }

    @Test("snapshot reads live enabled without re-register")
    @MainActor
    func liveEnabledFlips() throws {
        let token = LatchCatalog.Token()
        var canSave = false
        try LatchCatalog.register(
            id: "editor.save",
            role: "button",
            enabled: { canSave },
            actions: ["press"],
            kind: .action,
            token: token,
            press: { _ in }
        )
        #expect(try LatchCatalog.find(id: "editor.save").enabled == false)
        canSave = true
        #expect(try LatchCatalog.find(id: "editor.save").enabled)
        #expect(LatchCatalog.snapshot().first?.enabled == true)
    }

    @Test("notFound names nearby catalog ids")
    @MainActor
    func nearbyMissNamesRegisteredID() {
        let token = LatchCatalog.Token()
        try? LatchCatalog.register(
            id: "editor.save", role: "button", kind: .action, token: token)
        do {
            _ = try LatchCatalog.find(id: "editor.sav")
            Issue.record("expected editor.sav to miss")
        } catch let error as LatchCatalog.Error {
            guard case .notFound(let id, let nearby) = error else {
                Issue.record("expected notFound, got \(error)")
                return
            }
            #expect(id == "editor.sav")
            #expect(nearby.contains("editor.save"))
            #expect(error.description.contains("editor.save"))
            #expect(error.description.contains("Register it with .latch"))
        } catch {
            Issue.record("expected LatchCatalog.Error, got \(error)")
        }
    }

    @Test("unregistered id fails as a catalog miss")
    @MainActor
    func unregisteredIdFailsAsCatalogMiss() async {
        let token = LatchCatalog.Token()
        try? LatchCatalog.register(
            id: "editor.save", role: "button", kind: .action, token: token,
            press: { _ in })
        let ops = LatchDefaultOps(appName: "notes")
        do {
            _ = try await ops.axFind(id: "ghost.button")
            Issue.record("expected catalog miss")
        } catch let error as LatchError {
            #expect(error.description.contains("No catalog entry with id ghost.button"))
            #expect(error.description.contains("Register it with .latch"))
        } catch {
            Issue.record("expected LatchError, got \(error)")
        }
        do {
            try await ops.axPress(id: "ghost.button", action: nil)
            Issue.record("expected press miss")
        } catch let error as LatchError {
            #expect(error.description.contains("No catalog entry"))
        } catch {
            Issue.record("expected LatchError, got \(error)")
        }
        do {
            try await ops.axSet(id: "ghost.button", value: "x")
            Issue.record("expected set miss")
        } catch let error as LatchError {
            #expect(error.description.contains("No catalog entry"))
        } catch {
            Issue.record("expected LatchError, got \(error)")
        }
    }

    @Test("unlabeled dump walks AX")
    @MainActor
    func unlabeledDumpWalksAX() async {
        let ops = LatchDefaultOps(appName: "notes")
        do {
            _ = try await ops.axDump(window: nil, labeled: false)
            Issue.record("expected AX dump to fail without windows")
        } catch let error as LatchError {
            #expect(
                error.description.contains("No windows to dump")
                    || error.description.contains("Unknown window")
            )
        } catch {
            Issue.record("expected LatchError, got \(error)")
        }
    }

    @Test("catalog AX node omits empty optional fields")
    func catalogAXNodeOmitsEmptyOptionals() throws {
        let node = LatchAXNode(
            id: "editor.save",
            role: "button",
            title: "Save",
            value: nil,
            enabled: true,
            actions: ["press"],
            frame: .zero,
            children: []
        )
        let data = try JSONEncoder().encode(node)
        let object = try JSONSerialization.jsonObject(with: data)
        let dict = try #require(object as? [String: Any])
        #expect(dict["kind"] == nil)
        #expect(dict["choices"] == nil)
        #expect(dict["description"] == nil)
        #expect(dict["window"] == nil)
        #expect(dict["role"] as? String == "button")
    }

    @Test("text binding set writes the string")
    func textBindingRoundTrips() throws {
        var title = "old"
        let text = Binding(get: { title }, set: { title = $0 })
        let token = LatchCatalog.Token()
        try LatchCatalog.register(
            id: "editor.title",
            role: "textfield",
            title: "Title",
            value: { text.wrappedValue },
            actions: ["set"],
            window: "main",
            kind: .text,
            token: token,
            set: { text.wrappedValue = $0 }
        )

        try Latch.set(id: "editor.title", value: "Hello")
        let node = try Latch.find(id: "editor.title")
        #expect(node.value == "Hello")
        #expect(node.kind == .text)
        #expect(title == "Hello")
    }

    @Test("double binding parses and rejects non-numbers")
    func doubleBindingParses() throws {
        var volume = 0.5
        let value = Binding(get: { volume }, set: { volume = $0 })
        let token = LatchCatalog.Token()
        try LatchCatalog.register(
            id: "prefs.volume",
            role: "textfield",
            value: { String(value.wrappedValue) },
            actions: ["set"],
            kind: .double,
            token: token,
            set: {
                value.wrappedValue = try LatchCatalog.parseDouble(
                    id: "prefs.volume", $0)
            }
        )

        try Latch.set(id: "prefs.volume", value: "1.25")
        #expect(volume == 1.25)
        #expect(try Latch.find(id: "prefs.volume").kind == .double)
        #expect(
            throws: LatchCatalog.Error.invalidValue(
                id: "prefs.volume", value: "loud", expected: "a number")
        ) {
            try Latch.set(id: "prefs.volume", value: "loud")
        }
        #expect(volume == 1.25)
    }

    @Test("preview process does not register catalog ids")
    func previewDoesNotRegister() {
        Latch.previewProcessOverride = true
        defer { Latch.previewProcessOverride = nil }

        let binding = LatchCatalog.Binding()
        let id = "preview.isolation"
        binding.publish(id: id, role: "textfield")
        #expect(LatchCatalog.snapshot().contains { $0.id == id } == false)
    }

    @Test("updates yields the initial list then one coalesced emit")
    func updatesCoalesceTwoRegisters() async throws {
        let stream = Latch.updates()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial != nil)

        let token = LatchCatalog.Token()
        try LatchCatalog.register(id: "sugar.a", role: "button", token: token)
        try LatchCatalog.register(id: "sugar.b", role: "button", token: token)

        let next = await iterator.next()
        let ids = next?.map(\.id) ?? []
        #expect(ids.contains("sugar.a"))
        #expect(ids.contains("sugar.b"))
    }
}
