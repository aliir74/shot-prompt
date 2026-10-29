# ShotPrompt

Take a [Shottr](https://shottr.cc) capture, start typing, press Enter: a new [T3 Code](https://t3.codes) thread opens with the screenshot and your prompt.

- Watches `~/Pictures` for new `SCR-*.png` files (turn on Shottr's "save after capture").
- Shows a small panel by the mouse that takes the keyboard without bringing the app forward. No Accessibility or Input Monitoring permission is needed.
- Enter runs `$SHOT_PROMPT_DISPATCH --cwd "$SHOT_PROMPT_CWD" --image <capture> "<prompt>"`.
- Esc, switching to another app, a Cmd/Ctrl shortcut before typing, or 5 seconds idle closes the panel. If Shottr also copies captures, the first Cmd+V after a capture only closes the panel; press it again to paste.

## Dispatch command

ShotPrompt does not talk to T3 itself. It runs a command you provide, which must accept `--cwd DIR --image PATH PROMPT`, open the thread, and exit 0 (non-zero output is shown in the panel). To attach an image, the command can upload it through T3's `attachments.createUploadUrl` RPC, POST the bytes to the returned URL, and pass the `pending-…` attachment id in `orchestration.launchThread`'s `initialMessage.attachments`.

## Install

```sh
SHOT_PROMPT_CWD=~/my/project SHOT_PROMPT_DISPATCH=~/bin/t3-dispatch ./build.sh
```

This builds `~/Applications/ShotPrompt.app` and loads the `io.github.aliir74.shot-prompt` LaunchAgent (starts at login, restarts if it dies). Defaults: `SHOT_PROMPT_CWD=$HOME`, `SHOT_PROMPT_DISPATCH=~/.local/bin/t3-dispatch`, `SHOT_PROMPT_CAPTURE_DIR=~/Pictures`. Log: `/tmp/shot-prompt.log`.

Uninstall: `launchctl bootout gui/$(id -u)/io.github.aliir74.shot-prompt`, then delete the plist in `~/Library/LaunchAgents` and the app.

macOS, Swift 5.9+.
