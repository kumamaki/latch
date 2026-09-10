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
        .defaultSize(width: 360, height: 220)
    }
}

struct NotesRoot: View {
    @State private var title = ""
    @State private var dark = false
    @State private var composing = false
    @State private var draft = ""

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
        }
        .padding()
        .toolbar {
            Button("New") { composing = true }
                .latch("editor.new", title: "New", window: "main") {
                    composing = true
                }
        }
        .sheet(isPresented: $composing) {
            ComposeSheet(draft: $draft, composing: $composing) { saved in
                title = saved
                draft = ""
            }
        }
        .preferredColorScheme(dark ? .dark : .light)
    }
}

private struct ComposeSheet: View {
    @Binding var draft: String
    @Binding var composing: Bool
    let onSave: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $draft)
                .latch(
                    "composer.title",
                    title: "Title",
                    window: "main",
                    parent: "sheet.compose",
                    text: $draft
                )
            HStack {
                Button("Cancel") { composing = false }
                    .latch(
                        "composer.cancel",
                        title: "Cancel",
                        window: "main",
                        parent: "sheet.compose"
                    ) { composing = false }
                Spacer()
                Button("Save") { save() }
                    .latch(
                        "composer.save",
                        title: "Save",
                        window: "main",
                        parent: "sheet.compose",
                        press: save
                    )
            }
        }
        .padding()
        .frame(minWidth: 280)
        .latch(
            "sheet.compose",
            role: "sheet",
            title: "New note",
            window: "main"
        )
    }

    private func save() {
        onSave(draft)
        composing = false
    }
}
