import AppKit
import Testing

@testable import Latch

@Suite
@MainActor
struct LatchCatalogTests {
    init() {
        LatchCatalog.reset()
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

    @Test("duplicate id from another owner fails loud")
    @MainActor
    func duplicateFails() throws {
        let first = LatchCatalog.Token()
        let second = LatchCatalog.Token()
        try LatchCatalog.register(
            id: "editor.save", role: "button", token: first, press: { _ in })
        #expect(throws: LatchCatalog.Error.duplicate(id: "editor.save")) {
            try LatchCatalog.register(
                id: "editor.save", role: "button", token: second, press: { _ in })
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
        #expect(throws: LatchCatalog.Error.notFound(id: "window.main")) {
            try LatchCatalog.find(id: "window.main")
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
}
