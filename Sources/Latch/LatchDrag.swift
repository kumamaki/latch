import SwiftUI

/// Declares the text a control would put on the drag pasteboard, so
/// `axDrag` can move it without a real dragging session.
///
/// Pair with `.latch(id, …)` on the same view: the catalog entry gives
/// the id its place in the tree, this gives it a payload.
private struct LatchDragSource: ViewModifier {
    let id: String
    let payload: () throws -> String
    #if DEBUG
        @State private var token = LatchCatalog.Token()
    #endif

    func body(content: Content) -> some View {
        #if DEBUG
            content
                .onAppear { publish() }
                .onChange(of: id) { previous, _ in
                    LatchCatalog.unregisterDrag(id: previous, token: token)
                    publish()
                }
                .onDisappear { LatchCatalog.unregisterDrag(id: id, token: token) }
        #else
            content
        #endif
    }

    #if DEBUG
        private func publish() {
            guard !Latch.isPreviewProcess else { return }
            LatchCatalog.registerDragSource(id: id, token: token, payload: payload)
        }
    #endif
}

/// Declares what a control does with dropped text, so `axDrag` can
/// deliver it without a real dragging session.
private struct LatchDropTarget: ViewModifier {
    let id: String
    let drop: (String) throws -> Void
    #if DEBUG
        @State private var token = LatchCatalog.Token()
    #endif

    func body(content: Content) -> some View {
        #if DEBUG
            content
                .onAppear { publish() }
                .onChange(of: id) { previous, _ in
                    LatchCatalog.unregisterDrag(id: previous, token: token)
                    publish()
                }
                .onDisappear { LatchCatalog.unregisterDrag(id: id, token: token) }
        #else
            content
        #endif
    }

    #if DEBUG
        private func publish() {
            guard !Latch.isPreviewProcess else { return }
            LatchCatalog.registerDropTarget(id: id, token: token, drop: drop)
        }
    #endif
}

extension View {
    /// What `axDrag` takes from this control. Use the same value you pass
    /// to `draggable`.
    public func latchDragSource(
        _ id: String, payload: @escaping () throws -> String
    ) -> some View {
        modifier(LatchDragSource(id: id, payload: payload))
    }

    /// What `axDrag` hands to this control. Use the same closure body you
    /// pass to `dropDestination`.
    public func latchDropTarget(
        _ id: String, drop: @escaping (String) throws -> Void
    ) -> some View {
        modifier(LatchDropTarget(id: id, drop: drop))
    }
}
