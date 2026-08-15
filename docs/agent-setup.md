# Agent setup guide

You are reading this because a human asked you to **install Latch** in a
macOS Swift app.

This file is the setup interview. Shared rules for every Latch skill:
[agent-contract.md](agent-contract.md). Follow both in Claude Code,
Codex, Droid, Cursor, or any other coding agent. Do not assume a
Factory tool, a slash command, or a particular skill directory.

**Do not edit the app yet.** Run the intake. Wait for answers. Restate.
Get a go-ahead. Then install.

Canonical tree: the Latch repo the human pointed you at (often
`~/Work/latch`). After setup, day-to-day drive is the project runbook you
write in **their** repo.

---

## 0. What you are installing (say this once, short)

In your own words, cover:

- The app registers named controls with `.latch` (every build).
- A **coding agent** drives them over a **DEBUG unix socket**. No
  computer-use. No Screen Recording. No Accessibility permission.
- An **in-app assistant** calls `Latch.snapshot` / `press` / `set`.
  No socket. See [in-process.md](in-process.md).
- `.accessibilityIdentifier` is not enough.
- Product verbs (`add-note`, `seed`) stay in the app.

Then run the intake. Do not add the package yet.

---

## 1. How to ask

Ask in **chat**, as numbered questions with lettered options. One batch of
2–4 questions, then wait. If a harness multi-choice tool exists, you may
use it. If it does not, **plain numbered text is the interface**. Do not
stall because a specific ask-user tool is missing.

If the human already answered a question in this thread, skip only that
one and confirm in one line.

Do not invent a slug, boot site, or first control. Guessing those is how
the socket lands in the wrong folder.

---

## 2. Interactive intake (required)

### Q0 — What is Latch for?

> Who should drive the app?

| Option | Meaning |
|--------|---------|
| **1. Coding agent (DEBUG socket)** | Outside process. `Latch.start` + CLI. Default for this guide. |
| **2. In-app assistant** | Same process. `Latch.snapshot` / `press` / `set`. No socket. |
| **3. Both** | Register once. Socket in DEBUG. In-process in every build. |

If **2**, skip Q1 (slug), Q2–Q3 (CLI runbook), and Q5 (`start`). Still register
`.latch`. Point them at [in-process.md](in-process.md).

### Q1 — App slug (if Q0 is 1 or 3)

> What slug should Latch use for the socket directory?

Examples: `notes`, `todos`, `drafts`. Lowercase, no spaces.

This becomes:

```
~/Library/Application Support/<slug>-dev/latch.sock
```

`Notes` and `notes` are different folders. Prefer the repo or bundle
stem in lowercase.

If they have no preference, propose the directory name of the app
target, lowercase, and wait for yes.

### Q2 — Who drives Latch day to day?

> Who will call the CLI?

| Option | Meaning |
|--------|---------|
| **A. Coding agent** | You (this agent) ping / dump / press / set |
| **B. Human in terminal** | They type `latch` themselves |
| **C. Both** | Install a project runbook + show a short cheat sheet |

Default if unclear: **C**.

### Q3 — Which coding agents should see the runbook? (if Q2 is A or C)

> Where should I put the drive instructions?

| Option | Write |
|--------|-------|
| **1. AGENTS.md only** | Works in every agent. Lowest common denominator. |
| **2. Detect project skill dirs** | `.agents/skills/`, `.claude/skills/`, `.cursor/skills/` if they exist |
| **3. Both** | AGENTS.md pointer + copy `latch-drive` into every skill dir that exists (and any they name) |
| **4. Skip the runbook** | Host + first control only |

Default if unclear: **3**.

Do not invent a vendor folder that is not there and was not named.
AGENTS.md is the portable floor.

### Q4 — Package source

> How should I add the Swift package?

| Option | When |
|--------|------|
| **Path** | Latch already on disk (default if `~/Work/latch` or a path they gave exists) |
| **Git** | They want a remote dependency (only if they give a URL) |
| **This repo** | cwd is already the Latch clone — do not nest it inside itself |

### Q5 — Debug boot site (if Q0 is 1 or 3)

> Where should `Latch.start(app:)` run?

| Option | Meaning |
|--------|---------|
| **App.init** | SwiftUI `@main` App |
| **applicationDidFinishLaunching** | AppKit delegate |
| **You find it** | Search the target; propose the file and wait |
| **I'll point** | They will paste a path |

Do not insert `start` in a preview, a test, or a Release-only path.

### Q6 — First control

> What is the first control to register? One is enough.

Ask for: a short id (`editor.save`), the view (button / toggle / field),
and the window name (`main`). If they say "you pick", open the main
window's primary button or a single obvious field, propose the id, and
wait.

Do not register a whole screen on the first pass.

### Q7 — First project (only if cwd is not the app)

> Path to the macOS app repo? Default: current workspace.

Store as `APP_ROOT`.

### After answers

1. Restate in bullets: slug, who drives, runbook targets, package source,
   boot file, first control id.
2. One line on fit: "Debug socket at `<slug>-dev`; agents will
   `latch --app <slug> ax press <id>` instead of clicking."
3. Ask: **Proceed with install?** Continue only on yes / implicit
   go-ahead.

Do not open a PR, commit, or push unless they ask.

---

## 3. Prerequisites (check before install)

From `APP_ROOT`:

1. A macOS Swift app target (SwiftPM, Xcode, or Tuist).
2. Debug builds exist or can be produced.
3. Latch checkout readable if Q4 is Path.

If this is not a Swift macOS app, stop and say so. Do not force Latch
into a web or GPUI project.

---

## 4. Install (only after proceed)

### 4.1 Package

**Path** (typical):

```swift
// Package.swift or Xcode Swift Packages
.package(path: "/absolute/path/to/latch")
// target:
.product(name: "Latch", package: "Latch")
```

**Git**: use the URL they gave. Do not invent a GitHub remote.

Import `Latch` in every build that registers controls. Only wrap
`Latch.start` in `#if DEBUG`.

### 4.2 Start

In the boot site from Q5, after the app can show a window:

```swift
#if DEBUG
import Latch

Latch.start(app: "<slug>")
#endif
```

Release `start` is a no-op. `.latch` is not. Do not wrap the modifier
in `#if DEBUG`.

### 4.3 First control

On the **interactive** view, not a parent stack. See
`skills/latch-register/SKILL.md`.

```swift
Button("Save") { save() }
    .latch("editor.save", title: "Save", window: "main", press: save)
```

### 4.4 Runbook

Copy `skills/latch-drive/SKILL.md` only where Q3 said.

Always replace `<app>`, the id table, window list, and boot states.
Do not leave template ids.

If Q3 includes AGENTS.md, add a short pointer, not a second full skill:

```markdown
## Latch

DEBUG agent drive. Slug: `<slug>`.
CLI: `bash <latch>/cli/latch.sh --app <slug> …`
Do not click the GUI. Catalog first. See the `latch-drive` skill if present.
```

If they use an agent whose skill path you do not know, AGENTS.md is
enough. Ask before creating a new hidden vendor directory.

Optional: symlink or copy `cli/latch.sh` as `latch` on their PATH. Do
not require that for smoke.

---

## 5. Smoke

The Debug app must be running.

```sh
bash <latch>/cli/latch.sh --app <slug> ping
bash <latch>/cli/latch.sh --app <slug> ax dump --labeled
bash <latch>/cli/latch.sh --app <slug> ax find <first-id>
```

Ping fail → follow `skills/latch-diagnose/SKILL.md`. Do not grant
Accessibility. Do not use computer-use.

---

## 6. Close

Leave them with a recipe that matches Q2, not the full protocol.

**Agent (Q2 = A or C)**

```sh
bash <latch>/cli/latch.sh --app <slug> ping
bash <latch>/cli/latch.sh --app <slug> wait boot --state ready
bash <latch>/cli/latch.sh --app <slug> ax dump --labeled
bash <latch>/cli/latch.sh --app <slug> ax press <first-id>
```

**Human (Q2 = B or C)** — same commands, plus: token and socket live
under `~/Library/Application Support/<slug>-dev/`.

Hard rules (max 6 lines):

1. Catalog is the model. `.accessibilityIdentifier` is not enough.
2. `.latch` compiles in every build. `Latch.start` does not.
3. Bool wire is `true` / `false`. No `yes`.
4. Wait lives in the CLI. In-app drive uses `Latch.snapshot` / `press` / `set`.
5. DEBUG-only socket. No Screen Recording. No System Events.
6. Missing id → register, do not add an AX pin.

---

## Session checklist

```
[ ] Said what Latch is (one short beat)
[ ] Intake Q0–Q6 (Q7 if needed) — answers recorded
[ ] Restate + proceed confirmation
[ ] Package added
[ ] Latch.start(app:) only if Q0 is 1 or 3
[ ] One control registered
[ ] Runbook written where they asked (or deliberate skip)
[ ] Smoke or explained why the app is not running
[ ] Hard rules (short)
```
