import Latch
import SwiftUI

/// Buildable Latch demo. `just demo` from the Latch repo launches it.
/// `.latchWindow` is always on. `Latch.start` is the DEBUG socket only.
@main
struct NotesApp: App {
    init() {
        #if DEBUG
            Latch.start(app: "notes")
        #endif
    }

    var body: some Scene {
        WindowGroup("Notes", id: "main") {
            NotesRoot()
                .latchWindow("main")
        }
        .defaultSize(width: 360, height: 180)
    }
}

struct NotesRoot: View {
    @State private var title = ""
    @State private var dark = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $title)
                .latch(
                    "editor.title",
                    title: "Title",
                    window: "main",
                    text: $title
                )
            Toggle("Dark mode", isOn: $dark)
                .latch(
                    "prefs.appearance.dark",
                    title: "Dark mode",
                    window: "main",
                    bool: $dark
                )
            Button("Save") { save() }
                .latch("editor.save", title: "Save", window: "main", press: save)
        }
        .padding()
        .preferredColorScheme(dark ? .dark : .light)
    }

    private func save() {}
}
