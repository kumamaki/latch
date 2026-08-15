# Agent contract

Every Latch skill follows this. Claude Code, Codex, Droid, Cursor, and
any other coding agent can run them.

## Ask

- Numbered questions in **chat**, lettered options.
- One batch of 2–4, then wait.
- A host multi-choice tool is optional. Plain text is enough.
- Do not stall because Factory `AskUser`, a slash command, or a vendor
  skill loader is missing.
- Skip only what this thread already answered. Confirm that skip in one
  line. Do not invent a slug, boot site, id, or window name.

## Tools

- Drive the app with `bash <latch>/cli/latch.sh --app <slug> …`.
  `<latch>` is the Latch checkout the human pointed at.
- `latch` on PATH is optional. Do not require a brew install to proceed.
- Read and search the repo with whatever file tools the host has.
- Do not click the GUI. Do not photograph the screen. Do not grant
  Accessibility. Do not use System Events.

## Where instructions live

- **AGENTS.md** is the portable floor. Every agent reads it.
- Copy a skill file into `.agents/skills/`, `.claude/skills/`,
  `.cursor/skills/`, or another folder only when that folder exists or
  the human named it.
- Do not invent a hidden vendor directory.
- Cross-links to other Latch skills are markdown paths in the Latch
  repo. "Follow `skills/latch-register/SKILL.md`" means open that file.
  It does not mean a host-specific Skill tool.

## Product boundary

- Catalog is the model. `.accessibilityIdentifier` is not enough.
- `.latch` compiles in every build. The socket does not.
- In-app assistant: `Latch.snapshot` / `press` / `set`. No socket.
- Product verbs stay in the app.
- `Latch.start` is DEBUG-only. Do not ship the socket as a product feature.
