import Latch
import SwiftUI

/// Minimal host sketch. Not a buildable app target.
/// `.latch` is always on. `Latch.start` is the DEBUG socket only.
@main
struct NotesApp: App {
    init() {
        #if DEBUG
            Latch.start(app: "notes")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            NotesRoot()
        }
    }
}

struct NotesRoot: View {
    @State private var title = ""
    @State private var dark = false

    var body: some View {
        VStack {
            TextField("Title", text: $title)
                .latch(
                    "editor.title",
                    title: "Title",
                    window: "main",
                    value: { title },
                    set: { title = $0 }
                )
            Toggle("Dark mode", isOn: $dark)
                .latch("prefs.appearance.dark", title: "Dark mode", window: "main", bool: $dark)
            Button("Save") { save() }
                .latch("editor.save", title: "Save", window: "main", press: save)
        }
    }

    private func save() {}
}
