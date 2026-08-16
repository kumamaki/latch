# In-process drive

An assistant **inside** the app calls the catalog directly. No socket.
No token. No Accessibility permission.

```swift
let nodes = Latch.snapshot()
try Latch.set(id: "prefs.appearance.dark", value: "true")
try Latch.press(id: "editor.save")

for await snapshot in Latch.updates() {
    // current catalog, then one emit per turn after register / unregister
}
```

`.latch` compiles in Release. The model only sees what you registered.
Hidden views vanish. Live telemetry stays unlabeled. A miss is a catalog
miss; there is no AX fallback in-process.

`Latch.updates(window:)` is in-process wait. It yields the current
snapshot immediately, then one coalesced snapshot on the next main
turn after register or unregister. Coding-agent wait stays in the CLI.
There is no socket subscriber.

The app owns the allow-list and the model. Latch is the hand.

Do **not** call `Latch.start` for this path. That binds the DEBUG
socket for an outside agent.
