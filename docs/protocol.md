# Latch protocol

The **outside-agent** wire. Newline-JSON over a unix socket. One
request, one response, then the connection closes. Wait lives in the
CLI.

In-app assistants do not use this file. They call
`Latch.snapshot` / `press` / `set` — see [in-process.md](in-process.md).

## Paths

```
~/Library/Application Support/<app>-dev/latch.sock
~/Library/Application Support/<app>-dev/latch.token
```

`<app>` is the slug passed to `Latch.start(app:)`. Token file is `0600`.
Socket file is `0600`. Parent dir is `0700`.

## Envelope

Request:

```json
{"token":"<hex>","command":"ping"}
{"token":"<hex>","command":"axSet","args":{"id":"editor.title","value":"Hello"}}
```

Success:

```json
{"ok":true,"data":{"status":"ok"}}
```

Failure:

```json
{"ok":false,"error":{"code":"notFound","message":"No catalog or accessibility element with id editor.save."}}
```

Codes: `unauthenticated` · `unknownCommand` · `ipc` · `notFound` · `unavailable` · `protocol`.

## Kernel commands

| Command | Args | Data |
|---|---|---|
| `ping` | — | `{status: ok}` |
| `queryBoot` | — | `{state}` |
| `queryWindows` | — | `{items:[{name,visible,exists}]}` |
| `windowShow` | `{window}` | `{}` |
| `windowHide` | `{window}` | `{}` |
| `axDump` | `{window?, labeled?}` | `{root}` |
| `axFind` | `{id}` | `{node}` |
| `axPress` | `{id, action?}` | `{}` |
| `axSet` | `{id, value}` | `{}` |
| `screenshot` | `{window}` | `{path}` |

Unknown command names fail. Product verbs are not in the kernel.

## Encodings

| Kind | Wire |
|---|---|
| Bool | `true` / `false` only |
| Enum | `rawValue` |
| Number | decimal |
| Time | `HH:MM` 24h |
| Work days | `monday,tuesday` |

No synonyms. `yes`, `1`, and `on` fail.

## Catalog vs AX

Labeled dump / find / press / set go through the catalog first. Unlabeled
`ax dump` walks the in-process AX tree as a probe. A control is driveable
when it is registered. `.accessibilityIdentifier` alone is not enough.
