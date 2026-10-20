import AppKit
import Latch
import SwiftUI

/// Live window for the drag journey. A real app, so it can become key
/// and SwiftUI will honor the injected drag.
@main
struct DragFixtureApp: App {
    init() {
        Latch.start(app: "drag-fixture")
    }

    var body: some Scene {
        WindowGroup("Drag", id: "main") {
            DragFixtureRoot()
        }
        .defaultSize(width: 520, height: 420)
    }
}

@Observable
final class DragFixtureModel {
    var gesture = "0"
    var frame = ""
    var source = "token"
    var dest = ""
    var row = "idle"
}

private struct DragFixtureRoot: View {
    @State private var model = DragFixtureModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GestureWell(model: model)
            HStack(spacing: 24) {
                Bin(
                    model: model, id: "bin.source", child: "bin.source.row", payload: "token",
                    drop: false)
                Bin(model: model, id: "bin.dest", child: "bin.dest.row", payload: nil, drop: true)
            }
        }
        .padding(24)
        .latchWindow("main")
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct GestureWell: View {
    @Bindable var model: DragFixtureModel

    var body: some View {
        Color.blue.opacity(0.2)
            .frame(width: 180, height: 80)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 10).onEnded { value in
                    let distance = hypot(value.translation.width, value.translation.height)
                    model.gesture = String(Int(distance.rounded()))
                }
            )
            .background {
                FrameProbe { rect in
                    let next = [
                        Int(rect.minX.rounded()),
                        Int(rect.minY.rounded()),
                        Int(rect.width.rounded()),
                        Int(rect.height.rounded()),
                    ].map(String.init).joined(separator: ",")
                    if model.frame != next { model.frame = next }
                }
            }
            .latch(
                "gesture.well", role: "group", title: "Gesture",
                value: model.gesture, window: "main"
            )
            .latch(
                "gesture.frame", role: "label", title: "Frame",
                value: model.frame, window: "main")
    }
}

private struct Bin: View {
    @Bindable var model: DragFixtureModel
    var id: String
    var child: String
    var payload: String?
    var drop: Bool

    var body: some View {
        ZStack {
            pad
            Text("row")
                .frame(width: 100, height: 100)
                .background(Color.gray.opacity(0.35))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1).onChanged { _ in
                        if child == "bin.source.row" { model.row = "dragged" }
                    }
                )
                .latch(
                    child, role: "group", title: child,
                    value: child == "bin.source.row" ? model.row : "idle",
                    window: "main", parent: id)
        }
        .frame(width: 160, height: 200)
        .background { IdentifiedPlateView(id: id, child: child) }
        .latch(
            id, role: "group", title: id,
            value: id == "bin.source" ? model.source : model.dest,
            window: "main")
    }

    @ViewBuilder private var pad: some View {
        let base = Color.black.opacity(0.04).contentShape(Rectangle())
        if let payload {
            base.draggable(payload)
        } else if drop {
            base.dropDestination(for: String.self) { items, _ in
                guard let item = items.first else { return false }
                model.dest = item
                model.source = ""
                return true
            }
        } else {
            base
        }
    }
}

/// Accessibility frame for a container and the child centered in it.
/// `hitTest` is nil so the SwiftUI pad and row keep the mouse.
private struct IdentifiedPlateView: NSViewRepresentable {
    var id: String
    var child: String

    func makeNSView(context: Context) -> IdentifiedPlate {
        let view = IdentifiedPlate()
        view.axID = id
        view.childID = child
        return view
    }

    func updateNSView(_ view: IdentifiedPlate, context: Context) {
        view.axID = id
        view.childID = child
    }
}

private final class IdentifiedPlate: NSView {
    var axID = ""
    var childID = ""
    private var child: IdentifiedPlate?

    override func accessibilityIdentifier() -> String { axID }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard !childID.isEmpty else { return }
        let plate = child ?? IdentifiedPlate()
        if child == nil {
            plate.axID = childID
            addSubview(plate)
            child = plate
        }
        let side: CGFloat = 100
        plate.frame = NSRect(
            x: max(0, (bounds.width - side) / 2),
            y: max(0, (bounds.height - side) / 2),
            width: min(side, bounds.width),
            height: min(side, bounds.height)
        )
    }
}

/// The view's rect in `mouseDragPoint` space: points from the top-left
/// of the window's outer frame.
private struct FrameProbe: NSViewRepresentable {
    var onFrame: (CGRect) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onFrame = onFrame
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onFrame = onFrame
        view.report()
    }

    final class ProbeView: NSView {
        var onFrame: ((CGRect) -> Void)?

        override func layout() {
            super.layout()
            report()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func report() {
            guard let window, bounds.width > 1, bounds.height > 1 else { return }
            let screen = window.convertToScreen(convert(bounds, to: nil))
            onFrame?(
                CGRect(
                    x: screen.minX - window.frame.minX,
                    y: window.frame.maxY - screen.maxY,
                    width: screen.width,
                    height: screen.height
                ))
        }
    }
}
