import AppKit
import Testing

@testable import Latch

@Suite(.serialized)
@MainActor
struct LatchAXTests {
    @Test("window children include toolbar AX after contentView")
    func windowChildrenIncludeToolbar() {
        let fixture = ChromeWindowFixture()
        defer { fixture.close() }

        let children = LatchAX.children(of: .window(fixture.window))
        #expect(children.count > 1)
        if let content = fixture.window.contentView {
            #expect(children.first?.object === content)
        }

        let nodes = descendants(of: .window(fixture.window))
        #expect(nodes.contains { $0.roleName == "toolbar" || $0.title == "Save" })
        #expect(
            nodes.contains { node in
                (node.roleName == "button" || node.title == "Save")
                    && node.frame.width > 0 && node.frame.height > 0
            })
    }

    @Test("unlabeled dump lists toolbar children with frames")
    func dumpListsToolbar() throws {
        let fixture = ChromeWindowFixture()
        defer { fixture.close() }

        let root = try LatchAX.dump(windowName: "main")
        let nodes = flatten(root)
        #expect(nodes.contains { $0.role == "toolbar" || $0.title == "Save" })
        #expect(
            nodes.contains { node in
                (node.role == "button" || node.title == "Save")
                    && node.frame.width > 0 && node.frame.height > 0
            })
    }

    @Test("screenshot root is the frame view, taller than content")
    func screenshotRootIncludesChrome() throws {
        let fixture = ChromeWindowFixture()
        defer { fixture.close() }

        let content = try #require(fixture.window.contentView)
        let root = try #require(LatchScreenshot.captureRoot(in: fixture.window))
        #expect(root !== content)
        root.layoutSubtreeIfNeeded()
        #expect(root.bounds.height > content.bounds.height)

        guard fixture.window.isVisible else { return }
        let bounds = root.bounds
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: bounds))
        root.cacheDisplay(in: bounds, to: rep)
        #expect(rep.size.height > content.bounds.height)
    }
}

@MainActor
private final class ChromeWindowFixture {
    private let owner = SaveToolbarOwner()
    let window: NSWindow

    init() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.title = "Notes"
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))

        let toolbar = NSToolbar(identifier: "latch.chrome")
        toolbar.delegate = owner
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        self.window = window
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}

private final class SaveToolbarOwner: NSObject, NSToolbarDelegate {
    let save = NSToolbarItem.Identifier("save")

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [save]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [save]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Save"
        item.toolTip = "Save"
        let button = NSButton(title: "Save", target: nil, action: nil)
        button.bezelStyle = .texturedRounded
        item.view = button
        return item
    }
}

@MainActor
private func descendants(of lens: Lens, depth: Int = 0) -> [Lens] {
    guard depth < 8 else { return [] }
    var nodes: [Lens] = []
    for child in LatchAX.children(of: lens) {
        nodes.append(child)
        nodes.append(contentsOf: descendants(of: child, depth: depth + 1))
    }
    return nodes
}

private func flatten(_ node: LatchAXNode) -> [LatchAXNode] {
    [node] + node.children.flatMap(flatten)
}
