# Security

Latch is a development harness. The socket is DEBUG-only. Treat it as one.

## What Latch trusts

- Same user, same machine. The socket is a unix domain socket under
  `~/Library/Application Support/<app>-dev/`. Parent dir is `0700`.
- Auth is a `0600` sibling file, `latch.token`. Anyone who can read that
  file can drive the Debug app. There is no pairing UI and no network.
- `Latch.start` compiles to a no-op in Release. Do not ship the socket
  as a product feature. The catalog (`.latch`) is an in-process
  allow-list and compiles in every build.

## What Latch does not do

- No TCP. No mDNS. No Keychain. No Accessibility grant. No Screen
  Recording.
- No product verbs. An agent can only press and set what the app
  registered.
- Screenshots are `cacheDisplay` of this app's own windows.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/kumamaki/latch/security)
on this repository.

Do not open a public issue for an unfixed vulnerability.
