# Changelog

All notable changes to Latch live here.

## 0.1.0 — 2026-08-16

First public kernel.

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
