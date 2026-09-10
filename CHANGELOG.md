# Changelog

All notable changes to Latch live here.

## Unreleased

### Catalog

- Nodes may name a `parent` catalog id. Labeled dump nests that subtree
  under the parent. A missing parent stays at the window until it
  registers. Self-parent and cycles fail loud.
- Press and set refuse when live `enabled` is false. Find and dump
  still return the node. Wire code is `unavailable`.

### CLI

- `examples/Notes/latch.sh` is the project wrapper: exec the kernel
  client, then `cd` next to `.latch.json`. README and agent-setup
  teach that recipe. Kernel remains `cli/latch.sh`.

### Demo

- Notes toolbar **New** presents `sheet.compose` with
  `composer.title` / `save` / `cancel`.
- Notes `composer.save` is disabled while the compose draft is empty.

### Windows

- `query windows` reports live `NSWindow.isVisible`. Hide (`orderOut`)
  is `visible: false`, `exists: true`. Miniaturized is not visible.
  `wait window --hidden` waits for that row, not a missing name.

### Observation

- `screenshot` paints the window frame (title bar and toolbar), not
  just `contentView`.
- Unlabeled `ax dump` lists the window's own AX children after the
  content view, so toolbar items appear. Catalog press / set stay
  catalog-only.

## 0.1.1 — 2026-08-17

### Catalog

- Same-role register from another token takes over the id. SwiftUI
  appear-before-disappear remounts no longer throw `duplicate`. A role
  clash from another owner still fails loud.
- Window show / dump match namespaced identifiers (`app.window.main`)
  and `window.main` accessibility ids without rewriting the AppKit
  identifier.
- `start` accepts `Try again`; `revealInFinder` accepts `Show in Finder`.

## 0.1.0 — 2026-08-17

### Host sugar

- `.latch("id", text: $binding)` and `.latch("id", double: $binding)`
  register string and floating-point fields. `double:` uses `parseDouble`.
- SwiftUI preview processes (`XCODE_RUNNING_FOR_PREVIEWS=1`) do not
  register catalog ids and do not bind the DEBUG socket.
- In-process `Latch.updates(window:)` yields the current snapshot, then
  one coalesced emit per turn after register or unregister.

### Daily agent loop

- `ping` now reports `boot`, `windows`, and `catalog` alongside `status`.
- CLI resolves the slug from `--app`, then `LATCH_APP`, then cwd-to-root
  `.latch.json`. Invalid JSON or a missing `app` key fails loud.
- `latch doctor` prints a key:value health report. Exit 0 only if ping
  works and boot is not `failed`.
- `wait ax <id>` accepts `--value`, `--enabled`, and `--disabled`.
- `latch ids` prints a live markdown id table. No new kernel command.

### Catalog as the tool model

- Press / set / find are catalog-only. A miss names nearby ids and
  tells the agent to register. Unlabeled `ax dump` stays a probe.
- Snapshot nodes advertise `kind`, optional `choices`, and optional
  `description`. `enabled` is read live on snapshot.
- CLI `latch catalog` flattens labeled dump. No new kernel command.

### First-run reliability

- `.latchWindow("main")` sets the AppKit identifier and registers
  `window.main`. Control `window:` still only nests dump nodes.
- `Latch.start` stays sync. Boot is `starting` until the socket listens,
  then the host state (default `ready`). A failed bind reports `failed`.
- `examples/Notes` is a buildable sibling app. `just demo` launches it.
- CLI `wait` polls until the socket exists, so `wait boot --state ready`
  is not a race against `start`.

### Kernel

- Catalog-first control model. `.latch` registers press and set handlers.
  `.accessibilityIdentifier` alone is not enough.
- DEBUG-only unix socket. `Latch.start(app:)` is a no-op in Release.
- File token (`0600`) next to the socket. No Keychain, no pairing.
- Agent CLI (`cli/latch.sh`): newline-JSON, one request per connection.
  Wait lives in the CLI.
- In-process `snapshot` / `find` / `press` / `set` for in-app assistants.
- In-process AX probe and `cacheDisplay` screenshots. No System Events.
  No `screencapture`.
- Agent-agnostic skills: setup, register, audit, diagnose, plus a
  project `drive` template.

### Release

- `just release <major|minor|patch>` prints the plan. `just ship` stamps
  the changelog and SwiftPM pins, tags `vX.Y.Z`, and cuts a GitHub
  Release. Agents never run `just ship`.
