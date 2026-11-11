import Latch
import SwiftUI

/// Buildable Latch demo of what Notes leaves out: two windows, a sheet,
/// an AppKit list whose rows recycle, drag and drop, and a custom
/// context menu. `just demo gallery` launches it.
@main
struct GalleryApp: App {
    @State private var model = GalleryModel()

    init() {
        Latch.start(app: "gallery", history: ["menu.flash"])
    }

    var body: some Scene {
        WindowGroup("Gallery", id: "main") {
            GalleryRoot(model: model)
                .latchWindow("main")
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 640, height: 420)
        .defaultLaunchBehavior(.presented)

        Window("Inspector", id: "inspector") {
            InspectorView(model: model)
                .latchWindow("inspector")
        }
        .defaultSize(width: 260, height: 120)
        .defaultLaunchBehavior(.presented)
    }
}
