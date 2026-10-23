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

`<app>` is the slug passed to `Latch.start(app:)`. The CLI
resolves it from `--app`, then `LATCH_APP`, then a cwd-to-root
`.latch.json` of `{"app":"<slug>"}`. Token file is `0600`.
Socket file is `0600`. Parent dir is `0700`.

`LATCH_DATA_DIR` relocates the socket directory (tests, isolated
e2e). Token and socket stay `0600` under that path. Screenshots
still write to `~/Library/Logs/<app>-dev/latch/`.

## Envelope

Request:

```json
{"token":"<hex>","command":"ping"}
{"token":"<hex>","command":"axSet","args":{"id":"editor.title","value":"Hello"}}
```

Success:

```json
{"ok":true,"data":{"status":"ok","boot":"ready","windows":1,"catalog":3,"display":"awake"}}
```

Failure:

```json
{"ok":false,"error":{"code":"notFound","message":"No catalog entry with id editor.sav. Nearby: editor.save. Register it with .latch. Do not pin AX."}}
```

Codes: `unauthenticated` · `unknownCommand` · `ipc` · `notFound` · `unavailable` · `protocol`.

## Kernel commands

| Command | Args | Data |
|---|---|---|
| `ping` | — | `{status: ok, boot, windows, catalog, display}` |
| `queryBoot` | — | `{state}` (`starting` until the socket listens, then the host state, default `ready`; `failed` on bind error) |
| `queryWindows` | — | `{items:[{name,visible,exists,catalogNodes}]}` |
| `windowShow` | `{window}` | `{}` |
| `windowHide` | `{window}` | `{}` |
| `axDump` | `{window?, labeled?}` | `{root}` |
| `axFind` | `{id}` | `{node}` |
| `axPress` | `{id, action?}` | `{}` |
| `axSet` | `{id, value}` | `{}` |
| `axDismiss` | `{button?}` | `{}` — press a button on the frontmost system dialog (NSAlert, SwiftUI `.alert`). Omit `button` for the default. A miss lists the titles. |
| `mouseClick` | `{id, button?}` | `{}` — synthesize a real mouse click (`left` default, `right` for context menus) at the element's frame center via `NSApp.sendEvent`. Runs the full dispatch path: hit-testing, local event monitors, window ordering. |
| `mouseClickPoint` | `{window, x, y, button?}` | `{}` — same injected click, aimed at a point instead of a catalog id. `x`/`y` are points from the top-left of the named window's outer frame; points outside the frame are rejected, not clamped. For dead space between rows and spots with no catalog id. |
| `mouseDrag` | `{from, to}` | `{}` — mouse drag from one catalog id to another. Both ids are registered and carry that `accessibilityIdentifier`. The press point is an inset inside the element's frame that is clear of labeled children, so the center of a container is not a child row. Left button only. The system pointer stays where it is. |
| `mouseDragPoint` | `{window, x, y, toX, toY, toWindow?}` | `{}` — same mouse drag between window points. Coordinates match `mouseClickPoint`. `toWindow` defaults to `window`. The system pointer stays where it is. |
| `mouseDragSession` | `{from, to}` | `{}` — dragging session between the same two catalog ids, same aim as `mouseDrag`. The system pointer tracks the path and returns when the command finishes. The left button is posted for the gesture. The app has to already be in front. |
| `mouseDragSessionPoint` | `{window, x, y, toX, toY, toWindow?}` | `{}` — same dragging session between window points. The system pointer tracks the path and returns. The left button is posted for the gesture. |
| `screenshot` | `{window, id?, frame?, padding?}` | `{path, note}` — `id` crops to that catalog element's frame; omit it for the whole window. Set `frame` to `white` or `black` for rounded image corners and a matching matte. `padding` sets matte width in points (0–256); when omitted with a frame, it defaults to 32. Supplying `padding` alone uses a white matte. Styling is applied after an optional crop. `note` warns that material layers (Liquid Glass, vibrancy) and Metal content may not composite in the capture |

Unknown command names fail. Product verbs are not in the kernel.

The CLI exposes these options as `screenshot <window> [id]
[--frame white|black] [--padding <points>]`. Plain screenshots keep the
window's original rectangular bitmap. Request either style option to add
rounded corners and a monochrome matte; padding is measured in points and
scaled to the capture's backing resolution. `--frame` alone uses 32 points
of padding, while `--padding` alone selects white. Values outside 0–256 or
non-finite values fail.

`axPress` and `axSet` refuse when the catalog node is disabled. Find
and dump still return it. Wire code is `unavailable`; the message names
the id.

`queryWindows` `visible` is `NSWindow.isVisible`. Miniaturized and
ordered-out windows are false. `exists` is a matching AppKit window
still in `NSApp.windows`. `catalogNodes` is registered content in that
window, excluding the window chrome row. Visible plus zero nodes means
the window ordered front but SwiftUI never mounted. CLI `wait window`
needs `exists && visible`. `wait window --hidden` needs
`exists && !visible`. A missing name or `exists: false` is not hidden.
SwiftUI `WindowGroup` identifiers (`main-AppWindow-1`) match as `main` while that scene has one window. A second instance is listed under its own name (`main-AppWindow-2`). `screenshot`, `window show`, and catalog reads follow the instance already on screen, or the exact instance name when the drive passes one. `window show` of a window that stays off screen fails.

`ping.display` is `awake` or `asleep` from `CGDisplayIsAsleep` on the
main display. AppKit animation completions may not fire while asleep.
CLI `wait` timeout names that on the `timeout:` line and prints a
`diagnostic:` compact window list (`name ✓/✗ n nodes`).

## Encodings

| Kind | Wire |
|---|---|
| Bool | `true` / `false` only |
| Enum | `rawValue` |
| Number | decimal |
| Time | `HH:MM` 24h |
| Work days | `monday,tuesday` |

No synonyms. `yes`, `1`, and `on` fail.

## Catalog vs AX vs input

Three channels. The catalog drives: find / press / set and labeled
dump hit registered handlers only. Unlabeled `ax dump` walks the
in-process AX tree as a probe. `mouseClick` injects input: it resolves
a catalog id to a frame, then sends a real `NSEvent` through
`NSApp.sendEvent`, so hit-testing, local event monitors, and window
ordering all run. `mouseClickPoint` is the same injection aimed at a
window-relative point — the window is a required name, resolved like
`screenshot`, and off-frame points fail instead of clamping. Reach for
these when the behavior under test lives in event dispatch —
outside-click dismissal, click-through swallowing, right-click menus —
not to press a registered handler faster.

`mouseDrag` is that same input channel held down. It posts
`leftMouseDown`, `leftMouseDragged` samples about 8 points apart, and
`leftMouseUp` through `sendEvent`. The system pointer stays where it
is. `DragGesture` and `mouseDragged` read the event location. A path
shorter than `DragGesture`'s 10-point minimum is a click.
`mouseDragPoint` is the same sequence aimed at window points.

`mouseDragSession` is the other consumer. SwiftUI `draggable` / `onDrag`
and `NSDraggingSession` follow the system pointer and the left button,
so this command moves the pointer along the path, posts that button
for the gesture, and puts the pointer back when mouse-up has been
delivered. It does not activate the app and it does not ask for
Accessibility permission. If this app is not already in front the
command fails. `mouseDragSessionPoint` is the same session aimed at
window points.

A miss names nearby catalog ids and tells the agent to register.
`.accessibilityIdentifier` alone is not enough for any channel.
`axDismiss` is chrome: it presses a system dialog in this app, not a
catalog id.

Screenshot by `id` uses the same registration rule. `.latch` controls
use their live visible view bounds, including clipping by ancestor
views; an AppKit registration falls back to that id's accessibility
frame, clipped by its nearest visible ancestor view when available. The
crop must overlap the named window and have visible pixels. Only an
omitted `id` selects the whole window; an empty `id` fails as a catalog
miss. The crop comes from the window bitmap, so material layers behave
exactly as in a whole-window shot. The filename carries the id.

Named unlabeled dump nests attached sheets under that window so an
alert is visible next to the parent content. `cell` / `statictext` /
`textarea` nodes keep title and value anywhere, so copy is assertable
from the dump. Inside `alert` / `dialog` / `sheet` subtrees, dump
keeps title and value on any node even when it is not interactive.
Screenshot still paints the overlay; dismiss, then dump or shot to
see underneath.

Catalog nodes may include `kind`, `choices`, `description`, and
`parent`. `parent` is a catalog id. Labeled dump nests the child under
that node when it exists in the same window; a missing parent stays
under the window. AX probe nodes omit them. There is no `catalog`
kernel command; `latch catalog` is a CLI flatten of labeled dump and
copies `parent`. `doctor` and `ids` are CLI-only. `ping.catalog`
counts labeled nodes except the synthetic application root.
