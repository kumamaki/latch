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
{"ok":false,"error":{"code":"notFound","message":"No catalog entry with id editor.sav. Nearby: editor.save. Register it with .latch. Do not pin AX."}}
```

Codes: `unauthenticated` · `unknownCommand` · `ipc` · `notFound` · `unavailable` · `protocol`.

## Kernel commands

| Command | Args | Data |
|---|---|---|
| `ping` | — | `{status: ok}` |
| `queryBoot` | — | `{state}` (`starting` until the socket listens, then the host state, default `ready`; `failed` on bind error) |
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

Find / press / set and labeled dump use the catalog only. Unlabeled
`ax dump` walks the in-process AX tree as a probe. A miss names nearby
catalog ids and tells the agent to register. `.accessibilityIdentifier`
alone is not enough.

Catalog nodes may include `kind`, `choices`, and `description`. AX probe
nodes omit them. There is no `catalog` kernel command; `latch catalog`
is a CLI flatten of labeled dump.
