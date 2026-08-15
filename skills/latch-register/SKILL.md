---
name: latch-register
description: Register a Latch catalog control on a SwiftUI or AppKit view. Use when adding .latch, making a button or field driveable, or when dump/find cannot see a control. Agent-agnostic — ask in chat if the id or view is missing.
---

# Register a Latch control

A control is driveable when it is on `LatchCatalog`. SwiftUI
`.accessibilityIdentifier` is not enough.

Works in any coding agent. Shared rules: [docs/agent-contract.md](../../docs/agent-contract.md).

## Before you edit

If this thread does not already have **id**, **view kind** (button /
toggle / field / popup / row), **window name**, and **which file**, ask
in chat. Numbered options. Wait.

Do not invent an id. Do not register a parent stack because the control
was hard to find.

## Where

- Modifier: `Sources/Latch/LatchControl.swift` in the Latch repo
- Catalog: `LatchCatalog.swift`
- AppKit recycle: `LatchCatalog.Binding`

Put `.latch` on the interactive view, not a parent stack. The modifier
compiles in Release. Do not wrap it in `#if DEBUG`.

## Wrappers

| Need | Call |
|---|---|
| Host / label (dump only) | `.latch("id", role:title:window:)` |
| Button | `.latch("id", press: { … })` |
| Field | `.latch("id", value: { … }, set: { … })` |
| Switch | `.latch("id", bool: $binding)` |
| Popup / option group | `.latch("id", selection: $binding)` |
| Integer field | `.latch("id", integer: $binding)` |
| Named row actions | `.latch("id", actions: […], press: { action in … })` |

Bool / enum / int wrappers call `LatchCatalog.parse*`. Do not invent
encodings. Bad values throw `invalidValue`.

```swift
Toggle("Dark mode", isOn: $dark)
    .latch("prefs.appearance.dark", title: "Dark mode", window: "main", bool: $dark)

Button("Save") { save() }
    .latch("editor.save", title: "Save", window: "main", press: save)

TextField("Title", text: $title)
    .latch("editor.title", title: "Title", window: "main", value: { title }, set: { title = $0 })
```

## Lifetime

The modifier registers on appear and unregisters on disappear. Hidden or
off-tab controls must vanish.

Duplicate id from another owner fails loud. Same owner may upsert.

`window:` is the catalog window name (`main`, `preferences`, …). It nests
the node in labeled dump.

## AppKit rows

Use `LatchCatalog.Binding` when a cell recycles. `publish` on reuse,
`clear` on teardown. Do not leave a stale id on a recycled row.

## After

If the project has a drive runbook (AGENTS.md Latch section or a copied
`latch-drive` skill), add the new id there. Do not create a vendor skill
folder that does not exist.

## Do not

- Add AX pins instead of registering.
- Swallow parse errors or accept `yes` / `1` / `on` for bools.
- Register live telemetry.
- Put product behavior behind the catalog. Handlers call the same
  view-model / press path as the human control.
