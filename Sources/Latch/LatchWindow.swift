import AppKit
import SwiftUI

/// Window identity for catalog dump, `window show`, and screenshot.
///
/// Control `.latch(..., window:)` only nests a node. This binder sets
/// `NSWindow.identifier` and registers `window.<name>`.
public struct LatchWindow: ViewModifier {
    private let name: String
    #if DEBUG
        @State private var token = LatchCatalog.Token()
    #endif

    public init(_ name: String) {
        self.name = name
    }

    public func body(content: Content) -> some View {
        #if DEBUG
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
        #else
            content
        #endif
    }

    #if DEBUG
        private func publish() {
            guard !Latch.isPreviewProcess else { return }
            do {
                try LatchCatalog.register(
                    id: LatchWindowIdentity.catalogID(name: name),
                    role: "window",
                    title: LatchWindowIdentity.title(for: name),
                    window: name,
                    kind: .window,
                    token: token
                )
            } catch {
                assertionFailure("Latch catalog: \(error)")
            }
        }
    #endif
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

#if DEBUG
    enum LatchWindowIdentity {
        static func catalogID(name: String) -> String {
            "window.\(name)"
        }

        /// Leave an identifier SwiftUI already set (`name-AppWindow-N`).
        /// A second window of the same scene gets its own suffix so
        /// the one already on screen keeps the short name.
        @MainActor
        static func apply(name: String, to window: NSWindow) {
            if let raw = window.identifier?.rawValue, !raw.isEmpty,
                LatchAX.catalogName(from: raw) == name
            {
                return
            }
            let taken = NSApplication.shared.windows.contains { other in
                other !== window && LatchAX.windowMatches(other, name: name)
            }
            guard taken else {
                window.identifier = NSUserInterfaceItemIdentifier(name)
                return
            }
            var index = 2
            while NSApplication.shared.windows.contains(where: { other in
                other.identifier?.rawValue == "\(name)-AppWindow-\(index)"
            }) {
                index += 1
            }
            window.identifier = NSUserInterfaceItemIdentifier("\(name)-AppWindow-\(index)")
        }

        @MainActor
        static func title(for name: String) -> String? {
            let title = LatchAX.preferredWindow(named: name)?.title
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
#endif
