# Latch

Scene catalog so a coding agent (DEBUG socket) or an in-app assistant
(in-process `snapshot` / `press` / `set`) can drive a live macOS Swift
app without computer-use or Screen Recording.

## Layout

| Path | Role |
|---|---|
| `Sources/Latch` | Swift host: catalog, socket, AX probe, screenshot, SwiftUI modifier |
| `cli/latch.sh` | Agent CLI (newline-JSON over the unix socket) |
| `skills/` | Setup, register, audit, diagnose, plus the project `drive` template |
| `docs/protocol.md` | Socket wire contract |
| `docs/in-process.md` | In-app assistant (no socket) |
| `docs/agent-contract.md` | Agent-agnostic ask / CLI / runbook rules |
| `docs/agent-setup.md` | Paste-to-agent install (any coding agent) |
| `examples/NotesHost.swift` | One-screen host sketch (not a buildable target) |

## Interface (locked — do not casually reopen)

1. **Catalog is the model.** Press and set call registered handlers. `.accessibilityIdentifier` alone is not enough.
2. **Catalog first, AX second.** Unlabeled `ax dump` is a probe, not the driver.
3. **Newline-JSON, one-shot.** Wait lives in the CLI so the server never pins a Task.
4. **File token.** `0600` sibling of the socket. No Keychain, no pairing.
5. **Socket is DEBUG-only.** `Latch.start` is a no-op in Release. `.latch` and the catalog compile in every build.
6. **Fail loud.** Bool is `true` / `false`. No synonym encodings.
7. **Kernel verbs only.** ping, boot, windows, ax \*, screenshot. Product verbs stay in the app.
8. **No out-of-process AX.** No System Events. No `screencapture`. Screenshot is `cacheDisplay` on this app's windows.

## Commands

```sh
just test
just check
bash cli/latch.sh --help
```

## Socket

`~/Library/Application Support/<app>-dev/latch.sock`  
`~/Library/Application Support/<app>-dev/latch.token`

`<app>` is the slug passed to `Latch.start(app:)`.
