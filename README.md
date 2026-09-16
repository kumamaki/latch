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

Button("New") { composing = true }
    .latch("editor.new", press: { composing = true })

NotesRoot()
    .latchWindow("main")
```

From this repo, with Notes running (`just demo`):

```sh
examples/Notes/latch.sh doctor
examples/Notes/latch.sh wait boot --state ready
examples/Notes/latch.sh window show main
examples/Notes/latch.sh catalog
examples/Notes/latch.sh ax set prefs.appearance.dark true
examples/Notes/latch.sh wait ax prefs.appearance.dark --value true
examples/Notes/latch.sh ax press editor.new
examples/Notes/latch.sh ax set composer.title Hello
examples/Notes/latch.sh wait ax composer.save --enabled
examples/Notes/latch.sh ax press composer.save
examples/Notes/latch.sh screenshot main
```

Your app should have the same named command. Put a thin wrapper at
`latch.sh` that execs Latch's kernel client. Do not paste the kernel
into that wrapper. `examples/Notes/latch.sh` is the recipe.

`--app` is optional once a `.latch.json` of `{"app":"notes"}` sits in
the project (or an ancestor). `examples/Notes` ships one. Keep the
`--app` form when no slug file exists.

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
grows into a second, undocumented API surface.

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
  window frames (title bar and toolbar included) to PNG. Screen
  Recording permission never comes up.
- **AX is a probe.** An unlabeled `ax dump` walks the in-process AX tree
  for orientation. Press, set, and find never fall through to it. A miss
  means register the control.

Encodings fail loud. A bool is `true` or `false` on the wire; `yes`,
`1`, and `on` are errors, so an agent learns the contract instead of
guessing synonyms.

## What you get

| Piece | Role |
|---|---|
| `Latch` Swift package | Host: catalog, DEBUG socket, in-process AX probe, screenshot, SwiftUI `.latch` |
| `cli/latch.sh` | Kernel CLI (newline-JSON over the socket) |
| `examples/Notes/latch.sh` | Project CLI: execs the kernel client, cd's so `.latch.json` resolves |
| `skills/` | Agent-agnostic runbooks: setup, register, audit, diagnose, drive |
| `docs/` | Wire protocol, in-process API, agent contract |

Product verbs (`add-note`, `seed`) stay in your app. The kernel knows
ping, boot, windows, `ax *`, and screenshot, and nothing else.

## Quick start

1. Add the package to your app target. The product name is `Latch`
   (capital L), not `latch`.

   Xcode: File → Add Package Dependencies →
   `https://github.com/kumamaki/latch`

   SwiftPM:

   ```swift
   .package(url: "https://github.com/kumamaki/latch", from: "0.1.2")
   // target dependency:
   .product(name: "Latch", package: "Latch")
   ```

2. Bind the socket at Debug boot.

   ```swift
   #if DEBUG
       Latch.start(app: "notes")
   #endif
   ```

3. Mark the window root, then register a control on the interactive
   view, without `#if DEBUG`.

   ```swift
   NotesRoot()
       .latchWindow("main")

   Button("New") { composing = true }
       .latch("editor.new", title: "New", window: "main") {
           composing = true
       }
   ```

4. Add a project CLI. `examples/Notes/latch.sh` is the recipe: exec
   Latch's kernel client, `cd` next to `.latch.json`.

   Path package: point `root` at the Latch checkout you added.
   Git package: copy `cli/latch.sh` once to `scripts/latch`, then exec
   that file. Do not paste kernel envelopes into your wrapper.

5. Run the Debug app, then drive it.

   ```sh
   examples/Notes/latch.sh doctor
   examples/Notes/latch.sh wait boot --state ready
   examples/Notes/latch.sh window show main
   examples/Notes/latch.sh ax press editor.new
   ```

`just demo` launches `examples/Notes`, a one-window host. `just e2e`
builds that app, drives the catalog, and quits it. For a guided
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

`<app>` is the slug you pass to `Latch.start(app:)`. The CLI takes
it from `--app`, `LATCH_APP`, or `.latch.json`. `LATCH_DATA_DIR`
relocates the socket directory; screenshots still go under
`~/Library/Logs/<app>-dev/latch/`. The kernel client is
`cli/latch.sh`. Adopter apps call it through a project wrapper, not
by pasting that path into every command.

## Limits

- macOS 15+, Swift 6.
- You register controls by hand. That is deliberate; the catalog is an
  allow-list, and the agent can only touch what you put on it.
- Screenshots include the title bar and toolbar. Metal-backed layers
  may still render blank. The catalog and the AX probe stay the source
  of truth there.
- The socket serves one local user in Debug builds. Latch is a
  development harness, so treat it as one.

## Skills

The runbooks in `skills/` are agent-agnostic. Claude Code, Codex, Cursor,
and any other coding agent can follow them. Shared rules live in
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
just test            # unit tests
just check           # tests + swift-format lint + shellcheck
just e2e             # launch Notes and drive the catalog
just demo            # launch examples/Notes
just release minor   # dry-run the next tag; agents stop here
```

`just ship` is USER-only. It stamps, tags `vX.Y.Z`, and creates the
GitHub Release.

Status: 0.1. The kernel covers the catalog, the DEBUG socket, the CLI,
and the skills. See [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE), [CONTRIBUTING.md](CONTRIBUTING.md), and
[SECURITY.md](SECURITY.md).
