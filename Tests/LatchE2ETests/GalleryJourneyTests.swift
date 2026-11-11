import Foundation
import Testing

@testable import LatchE2E

@Suite(.serialized)
struct GalleryJourneyTests {
    private static func app(_ scenario: String) throws -> LatchApp {
        LatchApp(
            config: LatchApp.Config(
                executableURL: try Fixture.binary("Gallery"), slug: "gallery"),
            journey: try Journey(scenario: scenario)
        )
    }

    @Test("a sheet adds an item that both windows show")
    func sheetJourney() async throws {
        try await Self.app("gallery-sheet").run { app in
            try await app.expect("item.new").toAppear(timeout: 15)
            try await app.press("item.new")
            try await app.expect("sheet.new").toAppear()
            try await app.expect("sheet.save").enabled(false)
            try await app.set("sheet.title", value: "Fresh")
            try await app.expect("sheet.save").enabled(true)
            try await app.press("sheet.save")
            try await app.expect("sheet.new").toBeAbsent()
            try await app.expect("selection.card").value("Fresh")
            try await app.expect("inspector.title").value("Fresh")
        }
    }

    @Test("recycled list rows follow the data they show")
    func recycledRowsJourney() async throws {
        try await Self.app("gallery-rows").run { app in
            try await app.expect("item.row.3").toAppear(timeout: 15)
            try await app.press("item.row.3")
            try await app.expect("selection.card").value("Item 3")

            try await app.press("item.bottom")
            try await app.expect("item.row.60").toAppear()
            try await app.press("item.row.60")
            try await app.expect("selection.card").value("Item 60")

            let mounted = try await app.snapshot().ids.filter { $0.hasPrefix("item.row.") }
            #expect(mounted.count < 60, "rows are reused, not one per item: \(mounted.count)")
        }
    }

    @Test("a catalog drop pins the dragged text")
    func dropJourney() async throws {
        try await Self.app("gallery-drop").run { app in
            try await app.expect("tray.target").toAppear(timeout: 15)
            try await app.drop("tray.source", onto: "tray.target")
            try await app.expect("tray.target").value("report.pdf")
        }
    }

    @Test("a custom context menu opens, refuses a disabled row, nests, and dismisses")
    func contextMenuJourney() async throws {
        try await Self.app("gallery-menu").run { app in
            try await app.expect("selection.card").toAppear(timeout: 15)
            try await app.expect("menu").toBeAbsent()

            try await app.click("selection.card", button: "right")
            try await app.expect("menu").toAppear()
            #expect(try await app.node("menu.row.open")?.enabled == true)
            #expect(try await app.node("menu.row.delete")?.enabled == false)
            await #expect(throws: LatchE2EError.self) {
                try await app.press("menu.row.delete")
            }

            try await app.press("menu.row.move")
            try await app.expect("menu.submenu").toAppear()
            try await app.expect("menu.row.archive").toAppear()

            try await app.key("escape", in: "main")
            try await app.expect("menu.submenu").toBeAbsent()
        }
    }

    @Test("a row's flash is recorded even though it is too short to poll")
    func flashJourney() async throws {
        try await Self.app("gallery-flash").run { app in
            try await app.expect("selection.card").toAppear(timeout: 15)
            try await app.click("selection.card", button: "right")
            try await app.expect("menu.row.copy").toAppear()
            try await app.press("menu.row.copy")
            try await app.expect("menu").toBeAbsent()
            let values = try await app.history("menu.flash").map(\.value)
            #expect(values == ["none", "copy", "none"])
        }
    }
}
