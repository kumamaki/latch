---
name: latch-audit
description: Audit whether a Swift app's current UI is driveable by Latch. Use when checking catalog coverage, reviewing a Latch integration, or asking if agents can drive the live Debug app. Agent-agnostic — ask for slug and expected chrome in chat if missing.
---

# Latch audit

Walk the app and say whether Latch can drive the chrome an agent needs.
Do not grant Accessibility. Do not click the GUI.

Works in any coding agent. Shared rules: [docs/agent-contract.md](../../docs/agent-contract.md).

## Before you walk

If slug, expected chrome, or "is the Debug app running?" are unknown,
ask in chat. Numbered options. Wait.

Expected chrome comes from, in order:

1. This thread
2. The project's AGENTS.md Latch section
3. A copied `latch-drive` skill in a skill dir that exists
4. Questions to the human — not a guessed id list

## Pass

1. Confirm `Latch.start(app:)` is DEBUG-only and the slug matches
   `--app`.
2. List durable chrome the agent must reach (tabs, primary buttons,
   fields, window names).
3. Search for `.latch(` / `LatchCatalog.register` / `LatchCatalog.Binding`.
4. Search for `.accessibilityIdentifier` without a matching `.latch`.
   Those are probes, not drivers.
5. If the Debug app is running:

   ```sh
   bash <latch>/cli/latch.sh --app <slug> ax dump --labeled
   ```

   Compare to the list.

## Fail

| Finding | Why |
|---|---|
| Id only on `.accessibilityIdentifier` | Catalog will miss it. Register. |
| `.latch` on a parent stack | Press/set hit the wrong owner. Move it to the control. |
| Off-tab interiors stay registered | Hidden chrome must vanish on disappear. |
| Live telemetry labeled | Chunk cells, FPS, graphs stay unlabeled. |
| Bool accepts `yes` / `1` / `on` | Fail loud. Wire is `true` / `false`. |
| Product verbs in the kernel | Keep them in the app ops type. |
| Socket started in Release | `Latch.start` is DEBUG-only. |
| `.latch` wrapped in `#if DEBUG` | Catalog must exist in Release for in-app drive. |

## Report

Group by severity. Each finding: id or path, what is missing, the fix
(follow `skills/latch-register/SKILL.md`). End with a coverage line:
driveable / missing / unlabeled-on-purpose.

Do not invent ids.
