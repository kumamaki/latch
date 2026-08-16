# Contributing

Latch is a small kernel. Keep it one.

## Develop

```sh
just test            # unit tests
just check           # tests + swift-format lint + shellcheck
just demo            # launch examples/Notes
just release minor   # dry-run the next tag; agents stop here
```

`just ship` is USER-only. It stamps the changelog and SwiftPM pins,
pushes `main`, tags `vX.Y.Z`, and creates the GitHub Release. The
first cut is `just ship minor` → `v0.1.0`.

macOS 15+, Swift 6.

## Rules

- Catalog is the driver. Press / set / find hit registered handlers
  only. Unlabeled `ax dump` is a probe.
- Kernel verbs only: ping, boot, windows, `ax *`, screenshot. Product
  verbs stay in the host app.
- Socket is DEBUG-only. Do not ship it as a product feature.
- Fail loud. Bool is `true` / `false`. No synonym encodings.
- No out-of-process AX. No System Events. No `screencapture`.

## Patches

MIT. Open a PR against `main`. Match the surrounding style. Do not add
a second API surface.

Security reports go through [SECURITY.md](SECURITY.md), not a public issue.
