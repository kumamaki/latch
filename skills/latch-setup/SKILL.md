---
name: latch-setup
description: Interactively install Latch in a macOS Swift app for any coding agent. Use when adding Latch, wiring a Debug socket, or bootstrapping agent drive. Ask intake questions in chat first; do not edit the app until the human proceeds.
---

# Latch setup

Follow [docs/agent-setup.md](../../docs/agent-setup.md) exactly. Shared
rules for every Latch skill: [docs/agent-contract.md](../../docs/agent-contract.md).

## Hard rules

- **Interview first.** Numbered questions in chat. Wait. Restate. Ask to
  proceed. Then install.
- **Agent-agnostic ask.** A host multi-choice tool is optional. Plain
  lettered options are enough.
- **Do not invent** the slug, boot site, or first control.
- **AGENTS.md is the portable runbook floor.** Copy `latch-drive` into a
  skill dir only when that folder exists or the human named it.
- Release `start` is a no-op. `.latch` compiles in every build. Do not
  wrap the modifier in `#if DEBUG`.

If this skill's body and `docs/agent-setup.md` ever disagree, the doc
wins.
