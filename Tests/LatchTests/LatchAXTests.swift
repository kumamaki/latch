import AppKit
import SwiftUI
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

    @Test("dismiss with no dialog fails loud")
    func dismissWithoutDialogFails() {
        do {
            try LatchAX.dismiss()
            Issue.record("expected noSystemDialog")
        } catch let error as LatchError {
            guard case .noSystemDialog = error else {
                Issue.record("expected noSystemDialog, got \(error)")
                return
            }
            #expect(error.description.contains("No system dialog to dismiss"))
        } catch {
            Issue.record("expected LatchError, got \(error)")
        }
    }

    @Test("NSAlert sheet dumps copy and dismisses the default button")
    func nsAlertSheetDumpAndDismiss() throws {
        let fixture = ChromeWindowFixture()
        defer { fixture.close() }
        let alert = makeAlert(ok: "OK", cancel: "Cancel")
        present(alert, on: fixture.window)
        defer { endSheet(on: fixture.window) }

        #expect(spin(until: { fixture.window.attachedSheet != nil }))

        let root = try LatchAX.dump(windowName: "main")
        let nodes = flatten(root)
        #expect(
            nodes.contains {
                $0.title == "Failed" || $0.value == "Failed"
                    || $0.title == "Token expired" || $0.value == "Token expired"
            })
        #expect(nodes.contains { $0.role == "button" && $0.title == "OK" })
        #expect(
            nodes.contains { $0.role == "toolbar" || $0.title == "Save" })

        try LatchAX.dismiss()
        #expect(spin(until: { fixture.window.attachedSheet == nil }))
    }

    @Test("NSAlert sheet dismisses a titled Cancel button")
    func nsAlertSheetDismissesCancel() throws {
        let fixture = ChromeWindowFixture()
        defer { fixture.close() }
        let alert = makeAlert(ok: "OK", cancel: "Cancel")
        present(alert, on: fixture.window)
        defer { endSheet(on: fixture.window) }

        #expect(spin(until: { fixture.window.attachedSheet != nil }))
        try LatchAX.dismiss(button: "Cancel")
        #expect(spin(until: { fixture.window.attachedSheet == nil }))
    }

    @Test("NSAlert sheet lists buttons when the title misses")
    func nsAlertSheetMissingTitleListsButtons() throws {
        let fixture = ChromeWindowFixture()
        defer { fixture.close() }
        let alert = makeAlert(ok: "OK", cancel: "Cancel")
        present(alert, on: fixture.window)
        defer { endSheet(on: fixture.window) }

        #expect(spin(until: { fixture.window.attachedSheet != nil }))
        do {
            try LatchAX.dismiss(button: "Nope")
            Issue.record("expected dialogButtonNotFound")
        } catch let error as LatchError {
            guard case .dialogButtonNotFound(let wanted, let available) = error else {
                Issue.record("expected dialogButtonNotFound, got \(error)")
                return
            }
            #expect(wanted == "Nope")
            #expect(available.contains("OK"))
            #expect(available.contains("Cancel"))
            #expect(error.description.contains("Nope"))
        } catch {
            Issue.record("expected LatchError, got \(error)")
        }
    }

    @Test("ax press of an alert AX id is a catalog miss")
    func axPressOfAlertAXIdIsCatalogMiss() async throws {
        let fixture = ChromeWindowFixture()
        defer { fixture.close() }
        let alert = makeAlert(ok: "OK", cancel: nil)
        present(alert, on: fixture.window)
        defer { endSheet(on: fixture.window) }
        #expect(spin(until: { fixture.window.attachedSheet != nil }))

        let ops = LatchDefaultOps(appName: "notes")
        do {
            try await ops.axPress(id: "action-button-1", action: nil)
            Issue.record("expected catalog miss")
        } catch let error as LatchError {
            #expect(error.description.contains("No catalog entry"))
            #expect(error.description.contains("Do not pin AX"))
        } catch {
            Issue.record("expected LatchError, got \(error)")
        }
    }

    @Test("SwiftUI alert dismisses the default button")
    func swiftUIAlertDismisses() throws {
        let fixture = SwiftUIAlertFixture()
        defer { fixture.close() }
        #expect(
            spin(until: {
                (try? LatchAX.dump(windowName: "main")).map {
                    flatten($0).contains { $0.role == "button" && $0.title == "OK" }
                } ?? false
            }))
        try LatchAX.dismiss()
        #expect(
            spin(until: {
                (try? LatchAX.dump(windowName: "main")).map {
                    !flatten($0).contains { $0.role == "button" && $0.title == "OK" }
                } ?? false
            }))
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

@MainActor
private func makeAlert(ok: String, cancel: String?) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = "Failed"
    alert.informativeText = "Token expired"
    alert.addButton(withTitle: ok)
    if let cancel {
        alert.addButton(withTitle: cancel)
    }
    return alert
}

@MainActor
private func present(_ alert: NSAlert, on window: NSWindow) {
    alert.beginSheetModal(for: window) { _ in }
}

@MainActor
private func endSheet(on window: NSWindow) {
    if let sheet = window.attachedSheet {
        window.endSheet(sheet)
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
}

@MainActor
private func spin(until condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    return condition()
}

private struct AlertHost: View {
    @State private var presented = true

    var body: some View {
        Text("Underneath")
            .frame(width: 400, height: 240)
            .alert("Failed", isPresented: $presented) {
                Button("OK") { presented = false }
            } message: {
                Text("Token expired")
            }
    }
}

@MainActor
private final class SwiftUIAlertFixture {
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
        window.contentView = NSHostingView(rootView: AlertHost())
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        self.window = window
    }

    func close() {
        if let sheet = window.attachedSheet {
            window.endSheet(sheet)
        }
        window.orderOut(nil)
        window.close()
    }
}
