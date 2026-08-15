# Latch

DEBUG-only scene catalog so a coding agent can drive a live macOS Swift app
without computer-use or Screen Recording.

The app registers named controls. An agent talks to them over a local unix
socket. `.accessibilityIdentifier` is not enough.

```swift
import Latch

#if DEBUG
Latch.start(app: "notes")   // outside agent — DEBUG socket only
#endif

Toggle("Dark mode", isOn: $dark)
    .latch("prefs.appearance.dark", bool: $dark)

Button("Save") { save() }
    .latch("editor.save", press: save)

// in-app assistant — same catalog, no socket
try Latch.set(id: "prefs.appearance.dark", value: "true")
try Latch.press(id: "editor.save")
```

```sh
latch --app notes ping
latch --app notes wait boot --state ready
latch --app notes ax dump --labeled
latch --app notes ax set prefs.appearance.dark true
latch --app notes ax press editor.save
latch --app notes screenshot main
```

**Status:** 0.1 — kernel (catalog, DEBUG socket, CLI, skills). `.latch`
compiles in Release. No GPUI. No product verbs.

## What you get

| Piece | Role |
|---|---|
| `Latch` Swift package | Host: catalog, socket, in-process AX probe, screenshot, SwiftUI `.latch` |
| `cli/latch.sh` | Agent CLI |
| `skills/latch-setup` | Install in an app |
| `skills/latch-register` | Mark a control |
| `skills/latch-audit` | Coverage check |
| `skills/latch-diagnose` | Socket / miss / encoding |
| `skills/latch-drive` | **Copy into the adopter repo** and fill the id table |

Product verbs (`add-note`, `seed`) stay in the app. The kernel does not know them.

## Paths

```
~/Library/Application Support/<app>-dev/latch.sock
~/Library/Application Support/<app>-dev/latch.token   # 0600
~/Library/Logs/<app>-dev/latch/<window>-<stamp>.png
```

Auth is the token file. No Keychain. No pairing. Release `start` is a no-op.

## Skills

Skills are agent-agnostic (Claude Code, Codex, Droid, Cursor). Shared
rules: [docs/agent-contract.md](docs/agent-contract.md). Setup writes a
project runbook into **AGENTS.md** and into a skill dir only if that dir
exists or the human named it. Ids stay theirs. The other four skills
live with Latch.

| Skill | Lives | Job |
|---|---|---|
| `latch-setup` | this repo | Add the host and first control |
| `latch-register` | this repo | How to mark a control |
| `latch-audit` | this repo | Can the catalog actually drive this app |
| `latch-diagnose` | this repo | Ping fail, empty dump, missing id |
| `latch-drive` | **user project** | Agent runbook + id table |

## Docs

- [docs/protocol.md](docs/protocol.md) — socket wire
- [docs/in-process.md](docs/in-process.md) — in-app assistant
- [docs/agent-setup.md](docs/agent-setup.md) — paste-to-agent install
- [examples/NotesHost.swift](examples/NotesHost.swift) — one-screen host sketch

## Develop

```sh
just test
bash cli/latch.sh --help
```

## License

MIT.
