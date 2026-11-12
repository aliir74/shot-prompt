# ShotPrompt

[![GitHub Sponsors](https://img.shields.io/badge/sponsor-30363D?style=for-the-badge&logo=GitHub-Sponsors&logoColor=#EA4AAA)](https://github.com/sponsors/aliir74)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-ffdd00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/aliir74)

Take a [Shottr](https://shottr.cc) capture, start typing (or click the icon), press Enter: a new [T3 Code](https://t3.codes) thread opens with the screenshot and your prompt.

- Watches `~/Pictures` for new `SCR-*.png` or `.jpeg` files (turn on Shottr's "save after capture").
- Shows a small thumbnail icon by the mouse, where the capture region ended. Typing, or clicking the icon, opens the prompt panel. Both take the keyboard without bringing the app forward. No Accessibility or Input Monitoring permission is needed (only the optional [paste into T3](#paste-into-t3) setting needs Accessibility).
- The icon leaves 3 seconds after you switch to another app, so you can still click it on the way. Esc, a Cmd/Ctrl shortcut, or 20 seconds idle removes it.
- The project picker at the bottom right says which T3 project gets the thread. It starts on `$SHOT_PROMPT_CWD`; Tab (or a click) opens the list of your T3 projects, pinned first, then most recently used. Arrow keys or type-to-select, then Enter, pick one.
- Enter runs `$SHOT_PROMPT_DISPATCH --cwd <project folder> --image <capture> "<prompt>"`.
- Before you type in the panel, Esc, switching to another app, or 5 seconds idle closes it. Once you have typed, only Esc closes it: switching apps leaves it on screen with your text (click it to keep typing), and a new capture swaps the screenshot but keeps the text. The usual edit shortcuts (Cmd+V, Cmd+A, Cmd+C, Cmd+X, Cmd+Z) work in the panel, empty or not. If Shottr also copies captures, the first Cmd+V while only the icon shows removes the icon; press it again to paste.
- Dictation (Wispr Flow): holding Fn, or Wispr recording from the microphone (any hotkey, or hands-free mode), opens the prompt from the icon. An empty prompt stays open while you dictate and for 10 seconds after, so the words have time to arrive.

## iPhone

The app can also take screenshots from your iPhone: an iOS Shortcuts automation sends each screenshot with a prompt over Tailscale to an opt-in receiver in the app, which opens the thread the same way. Setup: [ios/README.md](ios/README.md).

## Paste into T3

With this setting on, a capture taken while T3 Code is the app in use skips the icon and the panel: the screenshot lands in the chat open in T3, as if you had pressed Cmd+V there, and you type your message in T3 itself. Captures taken in other apps work as before.

```sh
defaults write io.github.aliir74.shot-prompt pasteIntoT3 -bool true    # on
defaults write io.github.aliir74.shot-prompt pasteIntoT3 -bool false   # off
```

It is read at every capture, so no restart is needed. How it works:

- Shottr is in front during a capture, so the app the capture was taken in is the last other app that came forward.
- The capture goes on the clipboard (as PNG), T3's chat composer takes the focus through the macOS Accessibility API, and Cmd+V goes to T3. Focusing the composer first matters: T3 drops a pasted image when the focus is elsewhere, for example after you select text in the chat or in an HTML render.
- This drives another app, so ShotPrompt needs Accessibility (System Settings > Privacy & Security > Accessibility). macOS asks the first time. Until you allow it, or when T3 shows no chat to paste into, the capture gets the icon as usual.

## Dispatch command

ShotPrompt only reads T3's database (`$SHOT_PROMPT_T3_DB`, default `~/.t3/userdata/statev2.sqlite`, read-only) for the project list; if it cannot, the panel has no picker and every thread goes to `$SHOT_PROMPT_CWD`. To open the thread it runs a command you provide, which must accept `--cwd DIR --image PATH PROMPT`, open the thread, and exit 0 (non-zero output is shown in the panel). To attach an image, the command can upload it through T3's `attachments.createUploadUrl` RPC, POST the bytes to the returned URL, and pass the `pending-…` attachment id in `orchestration.launchThread`'s `initialMessage.attachments`.

## Install

```sh
SHOT_PROMPT_CWD=~/my/project SHOT_PROMPT_DISPATCH=~/bin/t3-dispatch ./build.sh
```

This builds `~/Applications/ShotPrompt.app` and loads the `io.github.aliir74.shot-prompt` LaunchAgent (starts at login, restarts if it dies). Defaults: `SHOT_PROMPT_CWD=$HOME`, `SHOT_PROMPT_DISPATCH=~/.local/bin/t3-dispatch`, `SHOT_PROMPT_CAPTURE_DIR=~/Pictures`. Log: `/tmp/shot-prompt.log`.

The app is ad-hoc signed with a designated requirement of just its bundle ID, so macOS keeps folder-access grants (for example Downloads, when the dispatch command lives there) across rebuilds. The tradeoff: any ad-hoc binary with the same bundle ID would match those grants too.

Uninstall: `launchctl bootout gui/$(id -u)/io.github.aliir74.shot-prompt`, then delete the plist in `~/Library/LaunchAgents` and the app.

macOS 13+, Swift 5.9+ (`build.sh` runs `swift build`).

## Tests

```sh
swift test               # run the tests
scripts/coverage.sh      # run them with coverage; fails below 100% of lines
```

The code is a Swift package with two targets:

- `Sources/ShotPromptCore`: everything that decides something. Capture detection and the wait for Shottr to finish writing, the T3 project list from SQLite (ordering, archived/deleted and missing-folder filtering), the picker list (default project first, parent folder on duplicate titles), what Esc, Cmd/Ctrl, Tab, Enter and app switches do, panel and prompt sizing, the scroll fade, running the dispatch command, and for the paste into T3: which app a capture was taken in, finding T3's composer in its accessibility tree, and the capture as PNG. `scripts/coverage.sh` requires every line here to be covered.
Core also holds the iPhone receiver: HTTP and multipart parsing, the `/projects` and `/shot` routes, the `@project` prefix, and the loopback listener (tested over real sockets).
- `Sources/ShotPrompt/main.swift`: the AppKit shell, excluded from the threshold. It holds the panel and view subclasses, the window setup and teardown in `Controller`, the key monitor, timers, notification observers, the Accessibility calls and Cmd+V for the paste into T3, and the run loop. Each of these needs a window server and real AppKit events, so it calls into Core for every decision and only applies the result to windows and views.

CI (`.github/workflows/tests.yml`) runs `scripts/coverage.sh` and a release build of the app on every pull request.

## Support This Project

If you find this project useful, consider supporting its development:

- Star this repo
- Report bugs and submit PRs
- [Sponsor on GitHub](https://github.com/sponsors/aliir74) or [Buy me a coffee](https://www.buymeacoffee.com/aliir74)

## License

MIT
