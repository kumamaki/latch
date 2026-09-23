# In-process drive

An assistant **inside** the app calls the catalog directly. No socket.
No token. No Accessibility permission.

```swift
let nodes = Latch.snapshot()
try Latch.set(id: "prefs.appearance.dark", value: "true")
try Latch.press(id: "editor.save")
try Latch.dismiss()
try Latch.dismiss(button: "Cancel")

for await snapshot in Latch.updates() {
    // current catalog, then one emit per turn after
    // register / unregister / press / set
}
```

`.latch` compiles in Release but the catalog populates only in DEBUG:
`.latch` passes content through, `snapshot()` returns `[]`,
`find`/`press`/`set` throw `notFound`, `updates()` finishes
immediately, and `dismiss()` throws `noSystemDialog`. A production
in-app assistant needs its own drive path — Latch does not ship one.

In DEBUG the model only sees what you registered. Hidden views vanish.
Live telemetry stays unlabeled. A miss is a catalog miss; there is no
AX fallback in-process. Press and set refuse when `enabled` is false.
Find still returns the node. `Latch.dismiss` is chrome for the
frontmost system dialog, not a catalog press.

`Latch.updates(window:)` is in-process wait. It yields the current
snapshot immediately, then one coalesced snapshot on the next main
turn after register, unregister, press, or set. Human typing does
not emit. Coding-agent wait stays in the CLI. There is no socket
subscriber.

The app owns the allow-list and the model. Latch is the hand.

Do **not** call `Latch.start` for this path. That binds the DEBUG
socket for an outside agent.
