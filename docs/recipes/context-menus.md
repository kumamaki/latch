# Custom context menus

Custom menus (a floating card, a popover, your own dropdown) are not
`NSMenu`, so the AX probe cannot drive them. The catalog can, with
registrations the app already has the data for. No kernel verb is
needed.

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
latch.sh ax press fetch.menu.copy-url          # the row's handler
latch.sh key main escape                       # dismissal by keyboard
```

- Disabled rows report `enabled: false`; `ax press` refuses them.
- `mouse click … right` proves the opener, including never-key panels
  that only a real event reaches.
- `mouse click` finds its target through the accessibility tree, which
  SwiftUI builds only for an attached client. Give the opener an
  `NSView` that returns the catalog id from `accessibilityIdentifier()`
  (Gallery's `RightClickCatcher`), so the click does not depend on it.
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
`Tests/LatchE2ETests/GalleryJourneyTests.swift` drives it. The menu
there is plain SwiftUI inside the window. A never-key `NSPanel` takes
the same registrations, but whether it receives `key` depends on your
own event routing.
