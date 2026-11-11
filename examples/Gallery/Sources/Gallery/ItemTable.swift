import AppKit
import Latch
import SwiftUI

/// An AppKit list. Its cells are reused as it scrolls, so each cell owns
/// a `LatchCatalog.Binding` and republishes under the id of whatever item
/// it now shows.
struct ItemTable: NSViewRepresentable {
    let model: GalleryModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: Coordinator.column))
        table.headerView = nil
        table.rowHeight = 24
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        model.scrollToEnd = { [weak table] in
            table?.scrollRowToVisible((table?.numberOfRows ?? 1) - 1)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        (scroll.documentView as? NSTableView)?.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let column = NSUserInterfaceItemIdentifier("item")

        var model: GalleryModel

        init(model: GalleryModel) {
            self.model = model
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            model.items.count
        }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int)
            -> NSView?
        {
            let cell =
                tableView.makeView(withIdentifier: Self.column, owner: nil) as? ItemCell
                ?? ItemCell()
            cell.identifier = Self.column
            let item = model.items[row]
            cell.show(item) { [model] in model.select(item.id) }
            return cell
        }
    }
}

private final class ItemCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let binding = LatchCatalog.Binding()

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.frame = bounds
        label.autoresizingMask = [.width, .height]
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ item: GalleryModel.Item, select: @escaping () -> Void) {
        label.stringValue = item.title
        binding.publish(
            id: "item.row.\(item.id)", role: "row", title: item.title,
            window: "main", parent: "item.table", press: { _ in select() })
    }
}
