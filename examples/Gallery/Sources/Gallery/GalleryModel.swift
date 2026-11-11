import Observation

@MainActor
@Observable
final class GalleryModel {
    struct Item: Identifiable, Hashable {
        let id: Int
        var title: String
    }

    struct MenuRow: Identifiable, Hashable {
        let id: String
        let title: String
        var isEnabled = true
        var opensSubmenu = false
    }

    enum Menu: Equatable {
        case closed
        case open
        case submenu
    }

    static let menuRows = [
        MenuRow(id: "open", title: "Open"),
        MenuRow(id: "copy", title: "Copy link"),
        MenuRow(id: "move", title: "Move to", opensSubmenu: true),
        MenuRow(id: "delete", title: "Delete", isEnabled: false),
    ]
    static let submenuRows = [
        MenuRow(id: "inbox", title: "Inbox"),
        MenuRow(id: "archive", title: "Archive"),
    ]

    var items = (1...60).map { Item(id: $0, title: "Item \($0)") }
    var selectedID: Int?
    var pinned: [String] = []
    var menu = Menu.closed
    var lastAction = "none"
    /// The row being confirmed, for the few frames before the menu closes.
    var flash: String?
    var composing = false
    var draft = ""
    /// Set by the list view; there is no catalog verb for scrolling.
    @ObservationIgnored var scrollToEnd: () -> Void = {}

    var selectedTitle: String {
        items.first { $0.id == selectedID }?.title ?? "none"
    }

    func select(_ id: Int) {
        selectedID = id
    }

    func add(title: String) {
        let next = (items.map(\.id).max() ?? 0) + 1
        items.append(Item(id: next, title: title))
        selectedID = next
    }

    func pin(_ text: String) {
        pinned.append(text)
    }

    func openMenu() {
        menu = .open
    }

    func dismissMenu() {
        menu = .closed
    }

    /// A row flashes for a moment, then the menu closes. The flash is too
    /// short to poll for, which is why the rows record value history.
    func perform(_ row: MenuRow) {
        if row.opensSubmenu {
            menu = .submenu
            return
        }
        flash = row.id
        lastAction = row.id
        _ = Task {
            try await Task.sleep(for: .milliseconds(120))
            flash = nil
            menu = .closed
        }
    }
}
