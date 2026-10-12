# Codex Sentinel

A local, native macOS menu bar app for monitoring Codex usage limits and chats
interrupted by usage limits. Optional automatic continuation is disabled by
default. Independent community project; not affiliated with or endorsed by OpenAI.

Free to use, modify and redistribute under the [MIT license](../LICENSE).
The current app interface is in Brazilian Portuguese.

## Install

Requires macOS 14+, and an installed, authenticated Codex CLI for real monitoring.
Install the CLI using the [official guide](https://developers.openai.com/codex/cli).
Run `codex --version` and `command -v codex` in Terminal to check your installation.

Prebuilt downloads, when available, are listed under
[Releases](https://github.com/paulopvm/codex-sentinel/releases). Read each release's
architecture and signing notes. Unsigned downloads may be blocked by Gatekeeper;
use macOS Privacy & Security's Open Anyway option only after verifying the source.
Do not disable Gatekeeper. You can always build from source:

```sh
git clone https://github.com/paulopvm/codex-sentinel.git
cd codex-sentinel
./scripts/build-app.sh --install
open "$HOME/Applications/Codex Sentinel.app"
```

Building requires Swift 6+ and the macOS SDK (Xcode or Command Line Tools).
`xcode-select --install` installs Command Line Tools if missing. Check
`swift --version`; an older toolchain must be updated. Local builds target the
host architecture (Apple Silicon or Intel). Tests additionally require Python 3:

```sh
./scripts/test-models.sh
```

## First run

Open **Configurações** (Settings), set the full executable path returned by
`command -v codex` if automatic discovery fails, and click **Atualizar** (Refresh).
Leave **retomada automática** (automatic continuation) off until you understand
its global scope: it applies to all eligible chats, including older chats outside
the displayed retention period. Notifications and login launch are optional.

The documented App Server over stdio provides monitoring and direct continuation.
When the desktop owns a chat, continuation may use its internal, versioned local
IPC after an explicit ownership refusal. This fallback can break with Codex updates
and rejects incompatible protocol/state. Continuing a chat starts new work and
consumes normal account usage; it does not increase or bypass your quota.

## Troubleshooting

- **CLI not found:** Finder-launched apps may have a different PATH than Terminal.
  Set the absolute path in Settings; Homebrew commonly uses `/opt/homebrew/bin`
  on Apple Silicon and `/usr/local/bin` on Intel.
- **Login/limits unavailable:** verify authentication in the Codex CLI. Missing
  quota information blocks automatic continuation.
- **Ownership/IPC error:** update compatible CLI/desktop versions, refresh and
  review the original chat. Never delete lock/socket files to force continuation.
- **No Dock icon:** this is a menu bar app; closing its window keeps monitoring alive.

Quit the app and delete `~/Applications/Codex Sentinel.app` to uninstall. Optional
full data removal: delete `~/Library/Application Support/Codex Sentinel` and run
`defaults delete dev.codex.sentinel` (also clears preferences and retry history).

## Contribute

Issues and PRs in English or Portuguese are welcome. See
[CONTRIBUTING.md](../CONTRIBUTING.md), [SECURITY.md](../SECURITY.md), and the
[roadmap](ROADMAP.md). Offline tests exercise fake servers; a successful build
is separate from validation on a real account or another Mac.

Maintainers can run `./scripts/package-release.sh` to create a universal ZIP
(arm64 + x86_64) with a bundled license and SHA-256 checksum in `dist/`.
It uses ad-hoc signing, not Apple Developer ID or notarization.
