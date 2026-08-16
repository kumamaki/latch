# Latch

Latch lets a coding agent drive your live macOS app through controls the
app registers itself. No computer use. No Screen Recording. No
Accessibility grants.

```swift
import Latch

#if DEBUG
    Latch.start(app: "notes")   // DEBUG-only socket for an outside agent
#endif

Toggle("Dark mode", isOn: $dark)
    .latch("prefs.appearance.dark", bool: $dark)

Button("Save") { save() }
    .latch("editor.save", press: save)
```

```sh
bash cli/latch.sh --app notes ping
bash cli/latch.sh --app notes wait boot --state ready
bash cli/latch.sh --app notes ax dump --labeled
bash cli/latch.sh --app notes ax set prefs.appearance.dark true
bash cli/latch.sh --app notes ax press editor.save
bash cli/latch.sh --app notes screenshot main
```

## The problem

You build a macOS app with a coding agent. The agent writes a view,
builds, and launches. Now it needs to check its work: press the button
it just wired, flip the toggle, read the field back. macOS gives it no
good way to reach the running app.

## Why the usual routes disappoint

**Computer use.** Screenshot-and-click automation needs Screen Recording
and Accessibility grants, and it moves your real pointer while you work.
The agent guesses coordinates from pixels, so a resize or a theme change
breaks the run. A picture of a toggle also hides the one thing the agent
needs, the bound value.

**Out-of-process accessibility.** macOS gates `AXUIElement` behind an
Accessibility grant per host binary. Every terminal and every IDE the
agent runs from needs its own approval. Past the grant, SwiftUI's AX
tree is unstable and mostly unlabeled. `.accessibilityIdentifier` often
fails to surface where you expect, and what a press reaches depends on
what the framework happens to expose that release.

**XCUITest.** The supported automation path launches a fresh app
instance under a test runner. The agent cannot poke the copy of the app
already on your screen. Each interaction costs a test bundle run, and an
exploratory session costs many.

**Hand-rolled debug IPC.** A custom socket or URL scheme works until it
grows into a second, undocumented API surface. Then it ships.

## What Latch does instead

Latch runs inside the app, so the app reports on itself and drives
itself.

- **The catalog is the model.** You register each control under a stable
  id with the `.latch` modifier. A control is driveable when it is
  registered. `.accessibilityIdentifier` alone is not enough.
- **Press and set call your handlers.** A registered handler is the same
  code path the human control uses. Latch synthesizes nothing from
  pixels or AX guesses.
- **The socket is DEBUG-only.** `Latch.start` binds a unix socket in
  Debug builds and compiles to a no-op in Release. The catalog compiles
  in every build.
- **Auth is a file.** A `0600` token sits next to the socket. Same user,
  same machine, no network, no Keychain, no pairing UI, no TCC prompt.
- **One request, one response.** The CLI speaks newline-JSON over the
  socket. Waiting and polling live in the CLI, never in the server.
- **Screenshots stay in-process.** `cacheDisplay` renders this app's own
  windows to PNG. Screen Recording permission never comes up.
- **AX is a probe.** An unlabeled `ax dump` walks the in-process AX tree
  for orientation. The catalog stays the contract.

Encodings fail loud. A bool is `true` or `false` on the wire; `yes`,
`1`, and `on` are errors, so an agent learns the contract instead of
guessing synonyms.

## What you get

| Piece | Role |
|---|---|
| `Latch` Swift package | Host: catalog, DEBUG socket, in-process AX probe, screenshot, SwiftUI `.latch` |
| `cli/latch.sh` | Agent CLI (newline-JSON over the socket) |
| `skills/` | Agent-agnostic runbooks: setup, register, audit, diagnose, drive |
| `docs/` | Wire protocol, in-process API, agent contract |

Product verbs (`add-note`, `seed`) stay in your app. The kernel knows
ping, boot, windows, `ax *`, and screenshot, and nothing else.

## Quick start

1. Add the package to your app target.

   ```swift
   // Package.swift
   .package(url: "https://github.com/kumamaki/latch", from: "0.1.0")
   // target dependency:
   .product(name: "Latch", package: "Latch")
   ```

2. Bind the socket at Debug boot.

   ```swift
   #if DEBUG
       Latch.start(app: "notes")
   #endif
   ```

3. Register a control on the interactive view, without `#if DEBUG`.

   ```swift
   Button("Save") { save() }
       .latch("editor.save", title: "Save", window: "main", press: save)
   ```

4. Run the Debug app, then drive it.

   ```sh
   bash cli/latch.sh --app notes ping
   bash cli/latch.sh --app notes ax press editor.save
   ```

`examples/NotesHost.swift` sketches a one-screen host. For a guided
install, point your agent at [docs/agent-setup.md](docs/agent-setup.md).

## In-app assistants

An assistant that lives inside the app skips the socket and calls the
same catalog directly:

```swift
let nodes = Latch.snapshot()
try Latch.set(id: "prefs.appearance.dark", value: "true")
try Latch.press(id: "editor.save")
```

This works in Release builds. The model only sees what you registered,
and hidden views vanish from the snapshot. See
[docs/in-process.md](docs/in-process.md).

## Paths

```
~/Library/Application Support/<app>-dev/latch.sock    # 0600, dir 0700
~/Library/Application Support/<app>-dev/latch.token   # 0600
~/Library/Logs/<app>-dev/latch/<window>-<stamp>.png
```

`<app>` is the slug you pass to `Latch.start(app:)` and to `--app`.

## Limits

- macOS 15+, Swift 6.
- You register controls by hand. That is deliberate; the catalog is an
  allow-list, and the agent can only touch what you put on it.
- Metal-backed layers may render blank in screenshots. The catalog and
  the AX probe stay the source of truth there.
- The socket serves one local user in Debug builds. Latch is a
  development harness, so treat it as one.

## Skills

The runbooks in `skills/` are agent-agnostic. Claude Code, Codex, Droid,
and Cursor can all follow them; the shared rules live in
[docs/agent-contract.md](docs/agent-contract.md).

| Skill | Lives | Job |
|---|---|---|
| `latch-setup` | this repo | Add the host and first control |
| `latch-register` | this repo | Mark a control |
| `latch-audit` | this repo | Check catalog coverage |
| `latch-diagnose` | this repo | Ping fail, empty dump, missing id |
| `latch-drive` | **your repo** | Agent runbook + id table (copy it in) |

## Docs

- [docs/protocol.md](docs/protocol.md) describes the socket wire.
- [docs/in-process.md](docs/in-process.md) covers the in-app assistant.
- [docs/agent-setup.md](docs/agent-setup.md) is the paste-to-agent install.
- [docs/agent-contract.md](docs/agent-contract.md) holds the shared skill rules.

## Develop

```sh
just test    # unit tests
just check   # tests + swift-format lint + shellcheck
```

Status: 0.1. The kernel covers the catalog, the DEBUG socket, the CLI,
and the skills. See [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).
