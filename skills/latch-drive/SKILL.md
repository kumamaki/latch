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
`docs/agent-contract.md`. `examples/Notes` (`just demo`) is the
reference host to drive by hand.

## Preconditions

- Debug app has finished boot.
- Socket: `~/Library/Application Support/<app>-dev/latch.sock`
- CLI (do not assume `latch` is on PATH). Prefer the project wrapper:

```bash
./latch.sh <command>
```

Kernel fallback if that file is missing:

```bash
bash <latch>/cli/latch.sh --app <app> <command>
```

Replace `<app>` and `<latch>` when this file is copied.
Drop `--app` when this repo has `.latch.json` or `LATCH_APP` is set.

If ping fails, wait for boot, then doctor again:

```bash
bash <latch>/cli/latch.sh --app <app> doctor
bash <latch>/cli/latch.sh --app <app> wait boot --state ready
bash <latch>/cli/latch.sh --app <app> doctor
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
| `coverage [window] [--fail-under <percent>]` | Actionable controls the app shows that no catalog id drives, with the nearest registered id. Reports only. `--fail-under` exits 1 below the percent, for CI. |
| `ax find` / `ax press` / `ax set` | Catalog only. A miss names nearby ids. |
| `ax find <id> --history` | Every value the id published, oldest first, with ms timestamps. For states shorter than a poll. Only ids the host opted in with `Latch.start(app:history:)`; any other id fails loud. Two changes in one main-actor turn collapse. |
| `mouse click <id>` / `mouse click <id> right` | Real `NSEvent` on the accessibility frame of that catalog id. Use for dispatch behavior — outside-click dismissal, click-through, right-click menus — not as a faster `press`. |
| `ax drag <from-id> <to-id>` | Moves a drag between two catalog ids in-process: the source's `.latchDragSource` payload goes to the destination's `.latchDropTarget`. No pointer, no focus. The default for drag-and-drop. A miss or a missing handler fails loud. |
| `key <window> <key> [command] [shift] [option] [control]` | A real key down and up in that window's responder chain: shortcuts, `escape`, arrows, `return`. Fails loud on an unknown key name. Text entry is `ax set`. |
| `mouse drag <from-id> <to-id>` | Mouse drag between two catalog ids. Aims at an inset clear of labeled children. The pointer stays where it is. For `DragGesture` and `mouseDragged`. |
| `mouse drag-session <from-id> <to-id>` | Escape hatch: only to prove the real `draggable` / `NSDraggingSession` wiring, since it takes the user's pointer. Same aim as `mouse drag`. The pointer tracks the path and returns. The app has to already be in front. Posts the left button for the gesture, without an Accessibility prompt, so a dragging session can follow it. |
| `ax dump` (no `--labeled`) | In-process AX probe. Not the driver. Named dump includes attached sheets. |
| `ax dismiss` / `ax dismiss <button>` | Frontmost system dialog in this app. Not a catalog id. |

Window-point forms are `mouse click-point`, `mouse drag-point`, and
`mouse drag-session-point`. Same rules, aimed at a point in the window
instead of a catalog id. Wire arguments live in the Latch repo's
`docs/protocol.md`.

A control is driveable only when it is registered.
`.accessibilityIdentifier` alone is not enough. Do not pin AX.
System alerts are chrome: `ax dismiss`, not `ax press action-button-1`.

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
bash <latch>/cli/latch.sh --app <app> window hide main
bash <latch>/cli/latch.sh --app <app> wait window main --hidden
bash <latch>/cli/latch.sh --app <app> ids
bash <latch>/cli/latch.sh --app <app> catalog
bash <latch>/cli/latch.sh --app <app> ax find <id>
bash <latch>/cli/latch.sh --app <app> ax find <id> --history
bash <latch>/cli/latch.sh --app <app> ax set <id> <value>
bash <latch>/cli/latch.sh --app <app> wait ax <id> --value <value>
bash <latch>/cli/latch.sh --app <app> wait ax <id> --enabled
bash <latch>/cli/latch.sh --app <app> ax press <id>
bash <latch>/cli/latch.sh --app <app> ax drag <from-id> <to-id>
bash <latch>/cli/latch.sh --app <app> mouse drag <from-id> <to-id>
bash <latch>/cli/latch.sh --app <app> mouse drag-session <from-id> <to-id>
bash <latch>/cli/latch.sh --app <app> ax dismiss
bash <latch>/cli/latch.sh --app <app> ax dismiss Cancel
bash <latch>/cli/latch.sh --app <app> screenshot main
bash <latch>/cli/latch.sh --app <app> screenshot main <id>
bash <latch>/cli/latch.sh --app <app> screenshot main --frame black
bash <latch>/cli/latch.sh --app <app> screenshot main <id> --padding 48
```

`screenshot <window> <id>` crops the window bitmap to that catalog
element's visible area. `.latch` registrations use current view geometry
and respect ancestor clipping; AppKit registrations use the accessibility
frame, clipped by a visible ancestor view when available. The id must be
registered and mounted in that window.

Add `--frame white|black` for rounded corners and a matching matte.
`--padding <points>` controls its width (0–256 points, default 32); using
padding without `--frame` selects white. Styling also works without an id.

Screenshots skip material layers — Liquid Glass, vibrancy, and
Metal-backed content may not composite. The response `note` repeats
this. Verify that UI by eye or via AX, not from the image.

## When a control is missing

1. Confirm the window is visible (`query windows` / `wait window`).
   `window hide` leaves `exists: true`, `visible: false`. A missing
   name is not hidden. Visible plus `catalogNodes: 0` is a render
   stall, often `ping.display` `asleep`. `wait ax` timeout prints
   that as `diagnostic:`.
2. Press the host that mounts it.
3. `ax find` the id. If not found, register the nearby suggestion or
   a new id. Follow the Latch repo `skills/latch-register/SKILL.md`.
4. Do not add an AX pin.
