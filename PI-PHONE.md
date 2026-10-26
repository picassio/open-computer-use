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
  - A host may opt out with `OPEN_COMPUTER_USE_ALLOW_PASSWORD_INPUT=1`.
- **Linux `type_text`:** writes into the focused editable field first, then the first editable field, as upstream did.
- **Releases:**
  - `.github/workflows/pi-phone.yml` tests both runtimes, including a real WPF password-box smoke on Windows.
  - On a `v*-pp.*` tag, it publishes `open-computer-use-linux-x64`, `open-computer-use-linux-arm64` and `open-computer-use-windows-x64.exe` with `SHA256SUMS`.
  - Upstream's macOS/npm `release.yml` runs only by hand in this fork.

macOS is unchanged and not built here.
