# In-process drive

An assistant **inside** the app calls the catalog directly. No socket.
No token. No Accessibility permission.

```swift
let nodes = Latch.snapshot()
try Latch.set(id: "prefs.appearance.dark", value: "true")
try Latch.press(id: "editor.save")
```

`.latch` compiles in Release. The model only sees what you registered.
Hidden views vanish. Live telemetry stays unlabeled.

The app owns the allow-list and the model. Latch is the hand.

Do **not** call `Latch.start` for this path. That binds the DEBUG
socket for an outside agent.
