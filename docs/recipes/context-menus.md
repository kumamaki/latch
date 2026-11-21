# Custom context menus

Custom menus (a floating card, a popover, your own dropdown) are not
`NSMenu`, so the AX probe cannot drive them. The catalog can, with
registrations the app already has the data for. No kernel verb is
needed. `mouse click` resolves a `.latch` id through the view's live
geometry — the same source element screenshots use — so it reaches
rows even when the menu lives in a floating `NSPanel` whose SwiftUI
content never appears in the AX walk. Catalog `press` stays the
handler path when the point is the action, not the event.

## Register the opener and the rows

```swift
Row(item)
    .latch("fetch.row.\(item.id)", role: "row", window: "main")

// Where the menu is built:
ForEach(menu.rows) { row in
    MenuRow(row)
        .latch(
            "fetch.menu.\(row.id)",
            role: "menuitem",
            title: row.title,
            enabled: row.isEnabled,
            window: "main",
            parent: "fetch.menu",
            press: { row.perform() })
}
.latch("fetch.menu", role: "menu", window: "main")
```

Rows mount with the menu and vanish on dismiss, so a snapshot shows
exactly what is open.

## Drive it

```sh
latch.sh mouse click fetch.row.7 right         # the real right-click path
latch.sh wait ax fetch.menu                    # the menu mounted
latch.sh catalog main                          # row titles and enabled flags
latch.sh mouse click fetch.menu.copy-url       # a real click on a .latch row
latch.sh ax press fetch.menu.copy-url          # or the row's handler directly
latch.sh key main escape                       # dismissal by keyboard
```

- Disabled rows report `enabled: false`; `ax press` refuses them.
- `mouse click … right` proves the opener, including never-key panels
  that only a real event reaches.
- `mouse click` resolves a `.latch` id through live view geometry, so
  it works inside panels the AX tree cannot see. An id with no `.latch`
  probe — a bare `NSView` carrying `accessibilityIdentifier`, like
  Gallery's `RightClickCatcher` — still resolves through the
  in-process accessibility frame.
- Keyboard selection (`up`, `down`, `return`) goes through
  `latch.sh key <window> <key>`. Whether a panel that never becomes key
  receives it depends on the app's own event routing.

## What this cannot show

The catalog reports final state. A selected-row flash before dismissal
lasts a few frames, and in-process window capture can miss animation
frames. Record the flash as a value instead. Publish it on an id that outlives
the menu (a hidden label), because history of an unmounted row cannot
be read. Opt that id into value history with
`Latch.start(app:history:)`, then assert the recorded sequence, which a
poll would miss.

`examples/Gallery` runs this recipe end to end:
`examples/Gallery/Sources/Gallery/GalleryViews.swift` builds the menu and
`examples/Gallery/Sources/Gallery/FloatingPanel.swift` hosts the same
kind of rows in a never-key `NSPanel`;
`Tests/LatchE2ETests/GalleryJourneyTests.swift` drives both. Whether the
panel receives `key` depends on your own event routing.
