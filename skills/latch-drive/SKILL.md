---
name: latch-drive
description: Drive the running Debug app through Latch (catalog dump/find/press/set, wait, screenshot). Use when smoking a UI change or when an agent would otherwise reach for computer-use, Screen Recording, or out-of-process AX. Agent-agnostic — works from AGENTS.md or any copied skill file.
---

# Latch drive

Drive the **running Debug app**. Do not click the GUI. Do not photograph
the screen.

This file is the **project** runbook. Setup copies it into the adopter
repo (AGENTS.md and/or a skill dir they named) and fills the id table.
Kernel docs stay in the Latch repo.

Works in any coding agent. Shared rules live in the Latch repo:
`docs/agent-contract.md`.

## Preconditions

- Debug app has finished boot.
- Socket: `~/Library/Application Support/<app>-dev/latch.sock`
- CLI (do not assume `latch` is on PATH):

```bash
bash <latch>/cli/latch.sh --app <app> <command>
```

Replace `<app>` and `<latch>` when this file is copied.

If ping fails, wait for boot, then ping again:

```bash
bash <latch>/cli/latch.sh --app <app> ping
bash <latch>/cli/latch.sh --app <app> wait boot --state ready
bash <latch>/cli/latch.sh --app <app> ping
```

## Forbidden

- Computer-use / GUI click-through
- `screencapture` or any screen/window-grab API
- System Events / out-of-process AX
- Product IPC as a stand-in for Latch

## Catalog vs AX

| Command | Hits |
|---|---|
| `catalog` / `ax dump --labeled` | Scene catalog (registered handlers) |
| `ax find` / `press` / `set` | Catalog only. A miss names nearby ids. |
| `ax dump` (no `--labeled`) | In-process AX probe. Not the driver. |

A control is driveable only when it is registered.
`.accessibilityIdentifier` alone is not enough. Do not pin AX.

## Encoding

`ax set` writes the view-model binding. Fail loud. Do not invent
synonyms.

| Kind | Wire |
|---|---|
| Bool | `true` / `false` only (`yes` fails) |
| Enum | `rawValue` |
| Number | decimal |
| Time | `HH:MM` 24h |
| Work days | `monday,tuesday` |

## Identifiers

Fill this table for **this app**. Delete unused rows. Do not keep
template ids.

| Id | Surface |
|---|---|
| `window.main` | main window |
| *(add this app's ids)* | |

Windows this app can `window show`: *(list them)*.

Boot states: `starting` until the socket listens, then *(ready · failed — or this app's set)*.

Latch checkout used by this project: *(absolute path)*.

## Recipes

```bash
bash <latch>/cli/latch.sh --app <app> window show main
bash <latch>/cli/latch.sh --app <app> wait window main
bash <latch>/cli/latch.sh --app <app> catalog
bash <latch>/cli/latch.sh --app <app> ax find <id>
bash <latch>/cli/latch.sh --app <app> ax set <id> <value>
bash <latch>/cli/latch.sh --app <app> ax press <id>
bash <latch>/cli/latch.sh --app <app> screenshot main
```

## When a control is missing

1. Confirm the window is visible (`query windows` / `wait window`).
2. Press the host that mounts it.
3. `ax find` the id. If not found, register the nearby suggestion or
   a new id. Follow the Latch repo `skills/latch-register/SKILL.md`.
4. Do not add an AX pin.
