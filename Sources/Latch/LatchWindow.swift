import AppKit
import SwiftUI

/// Window identity for catalog dump, `window show`, and screenshot.
///
/// Control `.latch(..., window:)` only nests a node. This binder sets
/// `NSWindow.identifier` and registers `window.<name>`.
public struct LatchWindow: ViewModifier {
    private let name: String
    @State private var token = LatchCatalog.Token()

    public init(_ name: String) {
        self.name = name
    }

    public func body(content: Content) -> some View {
        content
            .background {
                LatchWindowProbeRepresentable(name: name)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .onAppear { publish() }
            .onChange(of: name) { oldName, _ in
                LatchCatalog.unregister(
                    id: LatchWindowIdentity.catalogID(name: oldName),
                    token: token
                )
                publish()
            }
            .onDisappear {
                LatchCatalog.unregister(
                    id: LatchWindowIdentity.catalogID(name: name),
                    token: token
                )
            }
    }

    private func publish() {
        do {
            try LatchCatalog.register(
                id: LatchWindowIdentity.catalogID(name: name),
                role: "window",
                title: LatchWindowIdentity.title(for: name),
                window: name,
                token: token
            )
        } catch {
            assertionFailure("Latch catalog: \(error)")
        }
    }
}

extension View {
    /// Mark this view as the root of catalog window `name`.
    ///
    /// Sets the AppKit identifier so `window show` / screenshot resolve
    /// the same name. Prefer pairing with `WindowGroup(id: name)` when
    /// the scene is already identified.
    public func latchWindow(_ name: String) -> some View {
        modifier(LatchWindow(name))
    }
}

enum LatchWindowIdentity {
    static func catalogID(name: String) -> String {
        "window.\(name)"
    }

    @MainActor
    static func apply(name: String, to window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier(name)
    }

    @MainActor
    static func title(for name: String) -> String? {
        let title = NSApp.windows.first { LatchAX.windowMatches($0, name: name) }?
            .title
        guard let title, !title.isEmpty else { return nil }
        return title
    }
}

private struct LatchWindowProbeRepresentable: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> LatchWindowProbe {
        let view = LatchWindowProbe()
        view.name = name
        return view
    }

    func updateNSView(_ view: LatchWindowProbe, context: Context) {
        view.name = name
        view.applyIdentifier()
    }
}

final class LatchWindowProbe: NSView {
    var name = ""

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyIdentifier()
    }

    func applyIdentifier() {
        guard let window, !name.isEmpty else { return }
        LatchWindowIdentity.apply(name: name, to: window)
    }
}
