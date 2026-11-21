# Contributing

Latch is a small kernel. Keep it one.

## Develop

```sh
just test            # unit tests — desk-safe, no GUI
just test-journeys   # GUI journeys in a Tart VM on the mini
just check           # unit tests + swift-format lint + shellcheck
just demo            # launch examples/Notes
just demo gallery    # launch examples/Gallery
just demo-transcript # rerun the Gallery demo journey, rewrite the README transcript
just release minor   # dry-run the next tag; agents stop here
```

The journeys warp the real pointer, so `just test` skips them and
`just test-journeys` runs them in a disposable Tart VM on the mini —
see `scripts/vm/`. `just demo-transcript` still drives the GUI app on
this machine by hand.

Mini host setup: the runner needs Removable Volumes (or Full Disk
Access) for `~/.tart`, which lives on the T7. Local Network is not
needed — the guest is driven over Tart's virtio share and guest agent,
never the LAN, so launchd-agent CI cannot be blocked by the Local
Network prompt macOS never shows agents.

`just ship` is USER-only. It stamps the changelog and SwiftPM pins,
pushes `main`, tags `vX.Y.Z`, and creates the GitHub Release.

macOS 15+, Swift 6.

## Rules

- Catalog is the driver. Press / set / find hit registered handlers
  only. Unlabeled `ax dump` is a probe.
- Kernel verbs only: ping, boot, windows, `ax *`, `mouseClick`,
  `keyPress`, `mouseDrag`, `mouseDragSession`, screenshot. Product verbs stay in
  the host app.
- Socket is DEBUG-only. Do not ship it as a product feature.
- Fail loud. Bool is `true` / `false`. No synonym encodings.
- No out-of-process AX. No System Events. No `screencapture`.

## Patches

MIT. Open a GitHub issue or a PR against `main`. Match the surrounding
style. Do not add a second API surface. Do not use beads; that tracker
is local to maintainers.

Security reports: open a GitHub issue. See [SECURITY.md](SECURITY.md).
