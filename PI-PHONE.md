# open-computer-use: pi-phone build

This is a fork of [iFurySt/open-computer-use](https://github.com/iFurySt/open-computer-use)
(MIT, Copyright (c) 2026 Leo) for [pi-phone](https://github.com/picassio/pi-phone).
pi-phone runs it on the owner's own computers to let its agent operate desktop
apps, one approved control session at a time. All credit for open-computer-use
goes to its author; see [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), which ship with every release.

The fork's work is on the `pi-phone` branch. `main` follows upstream.

## Changes

- **Password fields** (Linux and Windows):
  - The outline marks them with `[password]` after the element's name. On Linux this is AT-SPI `ROLE_PASSWORD_TEXT`; on Windows it is UI Automation `IsPassword`.
  - The focused-element summary carries the same marker.
  - Their value and selection are never read. Element records carry `isPassword: true`.
  - `set_value`, `type_text`, and character keys from `press_key` (`a`, `shift+a`, `space`) are refused when the target or the focused element is a password field. Command keys (`Return`, `Tab`, `ctrl+a`) still work.
  - One call may opt out with `allow_password_input: true` on `set_value`, `type_text` or `press_key` (pi-phone sets it only for the owner typing on a taken-over window, and for a saved secret filled by name); every other call keeps the guard. Anything but a boolean `true` is no opt-out.
  - A host may opt out for every call with `OPEN_COMPUTER_USE_ALLOW_PASSWORD_INPUT=1`.
- **Linux `type_text`:** writes into the focused editable field first, then the first editable field, as upstream did.

PP-270 phase 1 (ideas from [vercel-labs/agent-desktop](https://github.com/vercel-labs/agent-desktop), Apache-2.0, reimplemented here; no code copied):

- **Covered-window screenshots** (PP-271; Linux and Windows):
  - A window screenshot is a copy of the screen inside the window's rectangle, so other windows on top showed in it. The windows above it are now found from the stacking order: on Linux the X11 `_NET_CLIENT_LIST_STACKING` list (or the root's children without a window manager) plus mapped override-redirect windows above the target's frame, with `_NET_FRAME_EXTENTS`, `_NET_WM_STATE_HIDDEN` and `_NET_WM_DESKTOP` (read with a small ctypes Xlib client; the AT-SPI window is matched to its X11 client by `_NET_WM_PID`, then title, then rectangle); on Windows `EnumWindows` z-order with DWM extended frame bounds, skipping invisible, minimised, cloaked, tool and click-through layered windows.
  - Their parts of the picture are black and reported: `Covered: [{x: 240, y: 90, width: 122, height: 173}] (other windows; blacked out in the screenshot)`, and `covered` / `cover` in `structuredContent`. On Windows the invisible resize borders outside the painted frame are blacked out too (not reported).
  - Fully covered or minimised: no image, and `Screenshot omitted: other windows cover the whole window. …` / `Screenshot omitted: the window is minimised. …`. When the stacking cannot be read: `Covered: unknown (…)`.
  - `get_app_state` `refuse_if_covered: true` refuses (code `covered`) instead, also when the cover is unknown, and the refused read does not become the app's snapshot.
  - Coordinate clicks and drags at a point covered in the last read are refused (`covered`); on Linux, real pointer input re-checks the stacking just before it is sent.
- **Snapshot-scoped refs** (Linux and Windows):
  - Every read has `Snapshot: <8 hex>` and `Window id: <id>` lines after `Window:` (Windows: the window handle; Linux: `<pid>:<AT-SPI object id>`), and `Other windows: <id> "title" (app), …` when the app query matches more windows. `get_app_state` takes `window_id` to read one of them.
  - Every action takes optional `snapshot_id` and `window_id`. A `snapshot_id` that is not the app's latest read, or a `window_id` that is not its window, is refused with `stale_ref` (naming the snapshot that replaced it). Only ids and app names of old snapshots are kept, in memory; nothing is written to disk.
  - Each action carries the snapshot's window: when it was closed or replaced, `stale_ref`. The element is re-identified before acting, with or without `snapshot_id`: same role, name (a name cut by `text_limit` still matches) and actions, and the same AT-SPI object path / UIA RuntimeId (Windows treats Expand/Collapse as one action). An element that moved keeps its identity and is found again; another element at its number, or a rebuilt one, is `stale_ref`; without a runtime id, twins are `ambiguous_target`. ocu never acts on a re-numbered element.
  - The read after an action still follows the app's main window (as upstream) unless the call named a `window_id`.
- **Element states** (Linux and Windows): element lines carry `States: checked, selected, expanded, collapsed, focused, disabled, readonly, secure` (only those that hold), after `Secondary Actions:` and before `Frame:`. Linux reads the AT-SPI StateSet (`checked`, `selected`, `expanded`/`expandable`, `focused`, no `enabled`/`sensitive`, `read-only` or an editable role without `editable`, password role); Windows reads TogglePattern, SelectionItemPattern, ExpandCollapsePattern, `IsEnabled`, `HasKeyboardFocus`, `IsPassword` and `ValuePattern.IsReadOnly`. Records carry `states`. `[password]` is unchanged.
- **Structured errors:** every refusal and failure ends with `Error: <code> retry=<safe|unsafe> suggestion=<text>` after the human message, and `structuredContent.error` holds the same. Codes: `stale_ref`, `ambiguous_target`, `policy_denied`, `covered`, `not_found`, `password_field`, plus `invalid_argument` (bad arguments), `action_failed` (an action failed in the runtime; it may have happened, so `retry=unsafe`) and `failed` (a read failed). Every other code is raised before anything reaches the app, so `retry=safe`.
- **Releases:**
  - `.github/workflows/pi-phone.yml` tests both runtimes, including real WPF smokes on Windows: the password box, and `windows-pi-phone-smoke.ps1` (snapshot refs, check box state, a covering window). `windows-pi-phone.test.ps1` runs runtime.ps1's own functions against doubles under Windows PowerShell and, on Linux, pwsh.
  - On a `v*-pp.*` tag, it publishes `open-computer-use-linux-x64`, `open-computer-use-linux-arm64` and `open-computer-use-windows-x64.exe` with `SHA256SUMS`.
  - Upstream's macOS/npm `release.yml` runs only by hand in this fork.

macOS is unchanged and not built here.
