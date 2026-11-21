import AppKit
import Latch
import SwiftUI

/// A never-key floating panel — the shape a real context-menu card
/// takes. Its rows register with the catalog like any `.latch` view;
/// `mouseClick` reaches them through live view geometry because the
/// panel's SwiftUI rows never appear in the AX walk.
@MainActor
final class FloatingPanel {
    private let panel: NSPanel

    init(model: GalleryModel) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 140),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: PanelCard(model: model))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        self.panel = panel
    }

    func show() {
        panel.center()
        panel.orderFront(nil)
    }
}

private struct PanelCard: View {
    let model: GalleryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Ping") { model.panelPing() }
                .latch("panel.row", role: "button", title: "Ping", window: "panel")
            Text("pings: \(model.panelPings)")
                .latch(
                    "panel.pings", role: "label", title: "Pings",
                    value: String(model.panelPings), window: "panel")
        }
        .padding(12)
        .frame(width: 200)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .latch("panel.card", role: "group", title: "Panel", window: "panel")
        .latchWindow("panel")
    }
}
