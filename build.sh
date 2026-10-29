#!/bin/sh
# Build ShotPrompt.app into ~/Applications and (re)load its LaunchAgent.
set -eu
cd "$(dirname "$0")"
APP="$HOME/Applications/ShotPrompt.app"
LABEL=io.github.aliir74.shot-prompt
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/ShotPrompt" main.swift
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

sed -e "s|__APP__|$APP|" \
    -e "s|__CWD__|${SHOT_PROMPT_CWD:-$HOME}|" \
    -e "s|__DISPATCH__|${SHOT_PROMPT_DISPATCH:-$HOME/.local/bin/t3-dispatch}|" \
    launchagent.plist > "$PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "ShotPrompt running ($LABEL)"
