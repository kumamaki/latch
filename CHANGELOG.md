# Changelog

All notable changes to Latch live here.

## Unreleased

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
