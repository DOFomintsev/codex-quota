# Codex Quota

A small macOS menu-bar widget for checking the remaining quota on your Codex account. One ring shows the current 5-hour window; the other shows the weekly window.

[Русская версия](README.ru.md) · [MIT license](LICENSE)

Unofficial community project. It is not affiliated with or endorsed by OpenAI.

## What it shows

- Remaining quota for the 5-hour and weekly windows.
- Percentage values and reset times when Codex provides them.
- A compact ring in the menu bar and a larger view with details.
- Clear states when quota data is not available or the last update is stale.

A full ring means 100% remains; an empty ring means 0%. A dashed ring means no value has been received yet. Dimmed rings with a small dot mean the last request failed, so the displayed value may be old.

Hover to see percentages. Click the widget to view details, request **Обновить** (Refresh), or quit. Hold **⌘ Command** and drag the widget to move it in the menu bar. macOS controls the final layout and may hide items when space is limited.

## How it works

Codex Quota starts a local Codex app-server using your existing Codex installation and sign-in. It reads the account's rate limits and listens for quota updates. Because activity in other Codex windows does not always send an update to this separate process, the widget also checks for fresh values every two minutes.

The app does not estimate a reset from the local clock. It waits for Codex to provide the reset information. If Codex cannot be reached, the widget keeps the last values and marks them as stale. Quitting the widget also stops its local app-server process.

Codex Quota displays **account quota** only. It does not show token counts, API costs, or usage by chat. It does not read chat history, save quota history, or send its own analytics. Fresh values require an internet connection to Codex.

## Install on macOS

There is no prebuilt installer or downloadable app release yet. Build the app on your Mac:

1. **Install Codex and sign in.** If you do not already have Codex CLI, install it with the [official Codex CLI installer](https://learn.chatgpt.com/docs/codex/cli):

   ```sh
   curl -fsSL https://chatgpt.com/codex/install.sh | sh
   ```

   Then run `codex` and sign in with your ChatGPT account. If Codex CLI is already available through the Codex or ChatGPT desktop app, you can use that installation.

2. **Install Swift 6 or newer.** Check with `swift --version`. You need a Swift toolchain to build the app.

3. **Build and open the app:**

   ```sh
   git clone https://github.com/DOFomintsev/codex-quota.git
   cd codex-quota
   ./scripts/build-app.sh
   open "dist/Codex Quota.app"
   ```

The build creates `dist/Codex Quota.app` on your Mac. After checking that it works, you can move it to Applications. The build is ad-hoc signed and is not notarized with an Apple Developer ID, so macOS may ask you to confirm that you want to open it. Do not disable Gatekeeper globally.

The app supports macOS 13 and newer. Apple Silicon has been tested; Intel Macs have not. It does not enable launch at login automatically. Add it under **System Settings → General → Login Items** if you want it to start when you sign in.

## Privacy and limitations

- The widget uses Codex's existing sign-in through the local app-server; it does not ask you to paste a password or API key into the app.
- It does not read conversations or store quota history.
- The app-server protocol and quota information can change with Codex updates. The account must provide the 5-hour rate-limit window; API-key-only sign-in and all account types have not been tested.
- This project is an independent community tool, not an official OpenAI product.

## License

[MIT](LICENSE).
