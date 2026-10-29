# ShotPrompt

[![GitHub Sponsors](https://img.shields.io/badge/sponsor-30363D?style=for-the-badge&logo=GitHub-Sponsors&logoColor=#EA4AAA)](https://github.com/sponsors/aliir74)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-ffdd00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/aliir74)

Take a [Shottr](https://shottr.cc) capture, start typing, press Enter: a new [T3 Code](https://t3.codes) thread opens with the screenshot and your prompt.

- Watches `~/Pictures` for new `SCR-*.png` or `.jpeg` files (turn on Shottr's "save after capture").
- Shows a small panel by the mouse that takes the keyboard without bringing the app forward. No Accessibility or Input Monitoring permission is needed.
- Enter runs `$SHOT_PROMPT_DISPATCH --cwd "$SHOT_PROMPT_CWD" --image <capture> "<prompt>"`.
- Before you type, Esc, switching to another app, a Cmd/Ctrl shortcut, or 5 seconds idle closes the panel. Once you have typed, only Esc closes it: switching apps leaves it on screen with your text (click it to keep typing), and a new capture swaps the screenshot but keeps the text. If Shottr also copies captures, the first Cmd+V after a capture only closes the panel; press it again to paste.

## Dispatch command

ShotPrompt does not talk to T3 itself. It runs a command you provide, which must accept `--cwd DIR --image PATH PROMPT`, open the thread, and exit 0 (non-zero output is shown in the panel). To attach an image, the command can upload it through T3's `attachments.createUploadUrl` RPC, POST the bytes to the returned URL, and pass the `pending-…` attachment id in `orchestration.launchThread`'s `initialMessage.attachments`.

## Install

```sh
SHOT_PROMPT_CWD=~/my/project SHOT_PROMPT_DISPATCH=~/bin/t3-dispatch ./build.sh
```

This builds `~/Applications/ShotPrompt.app` and loads the `io.github.aliir74.shot-prompt` LaunchAgent (starts at login, restarts if it dies). Defaults: `SHOT_PROMPT_CWD=$HOME`, `SHOT_PROMPT_DISPATCH=~/.local/bin/t3-dispatch`, `SHOT_PROMPT_CAPTURE_DIR=~/Pictures`. Log: `/tmp/shot-prompt.log`.

The app is ad-hoc signed with a designated requirement of just its bundle ID, so macOS keeps folder-access grants (for example Downloads, when the dispatch command lives there) across rebuilds. The tradeoff: any ad-hoc binary with the same bundle ID would match those grants too.

Uninstall: `launchctl bootout gui/$(id -u)/io.github.aliir74.shot-prompt`, then delete the plist in `~/Library/LaunchAgents` and the app.

macOS, Swift 5.9+.

## Support This Project

If you find this project useful, consider supporting its development:

- Star this repo
- Report bugs and submit PRs
- [Sponsor on GitHub](https://github.com/sponsors/aliir74) or [Buy me a coffee](https://www.buymeacoffee.com/aliir74)

## License

MIT
