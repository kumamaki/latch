---
name: latch-diagnose
description: Diagnose a Latch socket, token, or catalog miss. Use when ping fails, dump is empty, press/set cannot find an id, or the Debug app is running but the CLI cannot connect. Agent-agnostic — ask for slug and CLI path in chat if missing.
---

# Latch diagnose

Fail loud. Do not grant Accessibility. Do not use computer-use.

Works in any coding agent. Shared rules: [docs/agent-contract.md](../../docs/agent-contract.md).

## Before you probe

If slug, Latch checkout path, or whether the Debug app is running are
unknown, ask in chat. Numbered options. Wait.

CLI:

```sh
bash <latch>/cli/latch.sh --app <slug> <command>
```

## Socket / token

```sh
bash <latch>/cli/latch.sh --app <slug> ping
ls -l ~/Library/Application\ Support/<slug>-dev/latch.sock \
      ~/Library/Application\ Support/<slug>-dev/latch.token
```

| Symptom | Cause | Fix |
|---|---|---|
| token missing | Debug app never started Latch | `Latch.start(app:)` in DEBUG boot |
| socket not listening | Release build, or start still binding | `wait boot --state ready`; rebuild Debug if it stays down |
| boot stays `starting` | Socket has not reached listen | Wait; if it never flips, start failed before listen |
| boot is `failed` | Bind/listen error | Check path length / leftover socket; restart Debug |
| `unauthenticated` | CLI reading a stale token | Restart the app so it rewrites `latch.token` |
| slug mismatch | `--app notes` vs `Latch.start(app: "Notes")` | Same slug both sides |

## Catalog miss

```sh
bash <latch>/cli/latch.sh --app <slug> catalog
bash <latch>/cli/latch.sh --app <slug> ax find <id>
```

1. Window visible? `query windows` / `wait window`.
2. Host that mounts the control pressed? (tab rail, sheet, mode).
3. `ax find` the id. Not found → not registered. The message lists
   nearby catalog ids. Follow `skills/latch-register/SKILL.md`.
4. Do not add an AX pin.

Unlabeled `ax dump` is a probe. Press / set / find never fall through
to it. Catalog is the contract.

## Press / set fail

| Error | Meaning |
|---|---|
| `notFound` | Id is not registered. Nearby ids are a hint to register. |
| `actionUnavailable` | Registered, but no press/set handler, or unknown named action |
| `invalidValue` | Encoding wrong (`yes` instead of `true`) |

Set writes the view-model binding. If find shows the VoiceOver label
instead of the value, the control is not registered as a field.

## Screenshot

`cacheDisplay` on this app's window. Metal layers may come back blank.
Catalog frames stay 0. That is not a Latch outage.
