# Codex Quota

A small, native macOS menu bar app for your remaining Codex quota.

[Русская версия](README.ru.md) · [MIT license](LICENSE)

Two monochrome rings. Left: **5-hour quota**. Right: **weekly quota**. Exact percentages and reset countdowns are one click away.

Unofficial community project. Not affiliated with or endorsed by OpenAI. The current menu and error messages are in Russian.

## Features

- Fixed 44-point footprint, including padding; native light/dark appearance and saved menu bar placement.
- Percentages in the tooltip, an expanded menu with reset countdowns, and accessible quota values.
- One persistent local `codex app-server` process with automatic reconnection.
- Event-driven updates plus a fallback check every two minutes using the same connection.
- No animations, third-party libraries, telemetry, or quota history storage in the widget.

This displays **account quota**, not token counts, costs, or per-chat usage.

## Requirements

- macOS 13 or newer. Tested on Apple Silicon; Intel Macs have not been tested.
- Swift 6 or newer to build. Check with `swift --version`.
- An installed Codex CLI, signed in to an account that reports 5-hour/weekly rate limits. A bundled CLI in the Codex/ChatGPT desktop app or a separate CLI installation can be used.
- Internet access to fetch current limits through Codex.

There are no prebuilt downloads in this initial source release. Build locally:

```sh
git clone https://github.com/DOFomintsev/codex-quota.git
cd codex-quota
./scripts/build-app.sh
open "dist/Codex Quota.app"
```

The script creates a release build and an ad-hoc signed app in `dist/`. It does not download Codex, install a background service, or enable launch at login. You can manually move the app to Applications after testing it.

The app is **not signed with an Apple Developer ID or notarized**. This project does not offer a notarized installer.

For development, run `swift run CodexQuota`. Use either this command or the packaged app, not both, to avoid duplicate indicators and app-server processes.

## Reading the indicator

| Appearance | Meaning |
| --- | --- |
| Solid arc | Remaining quota; a full ring means 100% |
| Empty solid ring | 0% remaining |
| Dashed ring | No data for that window yet |
| Dimmed rings with a small dot | Fetch failed; retained values are stale |

Hover for percentages. Click for details, reset countdowns, **Обновить** (Refresh), and **Выйти из Codex Quota** (Quit).

Hold **⌘ Command** and drag the indicator to reorder it. The compact size reduces crowding, but macOS controls layout and may still hide items when space is limited. Pinning to the left of the camera notch is not implemented.

## How updates work

The app initializes one local app-server connection, reads `account/rateLimits/read`, and listens for `account/rateLimits/updated`. Partial updates are merged with the previous snapshot. Windows are classified by reported duration; separate model buckets do not overwrite the main Codex quota.

A separate app-server process is not guaranteed to receive usage events from other Codex processes, so the app also reconciles every two minutes. Instantaneous updates for activity in other clients are not guaranteed. Manual refresh uses the existing connection; simultaneous requests are coalesced.

Requests time out after 20 seconds. Connection loss triggers retries with a 5–60-second backoff. Waking the Mac requests a refresh. A one-minute redraw timer only updates countdowns; it makes no network requests. The app terminates its child process when you quit through the menu.

Quota is never assumed to reset based on the local clock: a new server response must confirm it.

## Privacy and limitations

The widget does not read chat history, `.env`, cookies, API keys, or `auth.json`. It does not persist quota responses or send its own analytics. The official Codex child process uses its normal authentication and contacts OpenAI; that process is outside the widget's privacy guarantees.

Codex is located in known desktop app locations, `/opt/homebrew/bin`, `/usr/local/bin`, then `PATH`. Finder does not inherit your interactive shell's full `PATH`, so custom installations outside those locations may not be found.

The app-server protocol and quota availability may change after a Codex update. Missing or unsupported 5-hour windows produce an error rather than fabricated values. API-key-only accounts and all plan types have not been tested.

## Checks

Run these from the repository root. They are local and do not contact your Codex account:

```sh
swift run CodexQuota --self-test
swift run CodexQuota --icon-test
swift run CodexQuota --transport-test
```

They cover parsing, sparse updates, window classification, icon states, streaming, same-process refresh, reconnection, and shutdown. Optionally provide a PNG output path after `--icon-test` to inspect all icon states visually.

Live checks require an authenticated Codex installation and contact the service:

```sh
swift run CodexQuota --print-status
swift run CodexQuota --watch-status
```

The second command watches for 130 seconds, including the fallback reconciliation interval, then exits.

## Contributing

Bug reports and focused pull requests are welcome. Include macOS, Swift, and Codex CLI versions, plus reproduction steps. Never post tokens, credentials, chat logs, or authentication files. Redact account details and private information from screenshots.

## License

[MIT](LICENSE). Codex and OpenAI names belong to their respective owners; no OpenAI software is bundled in this repository.
