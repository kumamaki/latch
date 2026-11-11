import AppKit
import Latch
import SwiftUI

struct GalleryRoot: View {
    @Bindable var model: GalleryModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ItemTable(model: model)
                .frame(width: 220)
                .latch("item.table", role: "list", title: "Items", window: "main")
            VStack(alignment: .leading, spacing: 16) {
                SelectionCard(model: model)
                Tray(model: model)
                HStack {
                    Button("New") { model.composing = true }
                        .latch("item.new", title: "New", window: "main") {
                            model.composing = true
                        }
                    Button("Bottom") { model.scrollToEnd() }
                        .latch("item.bottom", title: "Bottom", window: "main") {
                            model.scrollToEnd()
                        }
                }
            }
        }
        .padding(16)
        .sheet(isPresented: $model.composing) { NewItemSheet(model: model) }
    }
}

struct InspectorView: View {
    let model: GalleryModel

    var body: some View {
        Text(model.selectedTitle)
            .padding(24)
            .latch(
                "inspector.title", role: "label", title: "Selected",
                value: model.selectedTitle, window: "inspector")
    }
}

/// The right-click target. `mouseClick … right` reaches it like a real
/// right-click; the menu it opens is plain SwiftUI, not an `NSMenu`.
private struct SelectionCard: View {
    @Bindable var model: GalleryModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(model.selectedTitle)
                .frame(width: 280, height: 90)
                .background(Color.gray.opacity(0.2))
                .overlay { RightClickCatcher(id: "selection.card") { model.openMenu() } }
                .latch(
                    "selection.card", role: "group", title: "Selection",
                    value: model.selectedTitle, window: "main")
            if model.menu != .closed {
                ContextMenuCard(model: model)
            }
            // The rows vanish with the menu, so the flash is recorded on
            // an id that outlives it.
            Text(model.flash ?? "none")
                .hidden()
                .frame(width: 0, height: 0)
                .latch(
                    "menu.flash", role: "label", title: "Flash",
                    value: model.flash ?? "none", window: "main")
        }
        .frame(width: 280, height: 90, alignment: .topLeading)
    }
}

private struct ContextMenuCard: View {
    let model: GalleryModel

    var body: some View {
        let rows =
            model.menu == .submenu ? GalleryModel.submenuRows : GalleryModel.menuRows
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                Button(row.title) { model.perform(row) }
                    .disabled(!row.isEnabled)
                    .latch(
                        "menu.row.\(row.id)", role: "menuitem", title: row.title,
                        enabled: row.isEnabled, window: "main",
                        parent: model.menu == .submenu ? "menu.submenu" : "menu"
                    ) { model.perform(row) }
            }
            // Hidden, so Escape dismisses without adding a control.
            Button("Dismiss") { model.dismissMenu() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
                .frame(width: 0, height: 0)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .latch(
            model.menu == .submenu ? "menu.submenu" : "menu", role: "menu",
            window: "main")
    }
}

private struct Tray: View {
    let model: GalleryModel

    var body: some View {
        HStack(spacing: 16) {
            Text("report.pdf")
                .padding(12)
                .background(Color.blue.opacity(0.2))
                .draggable("report.pdf")
                .latchDragSource("tray.source") { "report.pdf" }
                .latch("tray.source", role: "group", title: "Source", window: "main")
            Text(model.pinned.joined(separator: ", "))
                .frame(width: 160, height: 44)
                .background(Color.green.opacity(0.2))
                .dropDestination(for: String.self) { items, _ in
                    items.forEach(model.pin)
                    return !items.isEmpty
                }
                .latchDropTarget("tray.target") { model.pin($0) }
                .latch(
                    "tray.target", role: "group", title: "Pinned",
                    value: model.pinned.joined(separator: ", "), window: "main")
        }
    }
}

private struct NewItemSheet: View {
    @Bindable var model: GalleryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $model.draft)
                .latch(
                    "sheet.title", title: "Title", window: "main",
                    parent: "sheet.new", text: $model.draft)
            HStack {
                Button("Cancel") { model.composing = false }
                    .latch(
                        "sheet.cancel", title: "Cancel", window: "main",
                        parent: "sheet.new"
                    ) { model.composing = false }
                Spacer()
                Button("Save", action: save)
                    .disabled(model.draft.isEmpty)
                    .latch(
                        "sheet.save", title: "Save", enabled: !model.draft.isEmpty,
                        window: "main", parent: "sheet.new", press: save)
            }
        }
        .padding()
        .frame(minWidth: 280)
        .latch("sheet.new", role: "sheet", title: "New item", window: "main")
    }

    private func save() {
        model.add(title: model.draft)
        model.draft = ""
        model.composing = false
    }
}

/// Catches only the right button. A left click falls through to the view
/// behind it. It is a real `NSView` that carries the catalog id as its
/// accessibility identifier, so `mouseClick` finds it without SwiftUI
/// building its accessibility tree.
private struct RightClickCatcher: NSViewRepresentable {
    var id: String
    var onRightClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.axID = id
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.axID = id
        view.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var axID = ""
        var onRightClick: (() -> Void)?

        override func accessibilityIdentifier() -> String { axID }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?()
        }
    }
}
