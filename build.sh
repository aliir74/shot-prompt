#!/bin/sh
# Build ShotPrompt.app into ~/Applications and (re)load its LaunchAgent.
set -eu
cd "$(dirname "$0")"
APP="$HOME/Applications/ShotPrompt.app"
LABEL=io.github.aliir74.shot-prompt
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$APP/Contents/MacOS"
swift build -c release --product ShotPrompt
cp "$(swift build -c release --show-bin-path)/ShotPrompt" "$APP/Contents/MacOS/ShotPrompt"
cp Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signing pins TCC grants to the cdhash, which changes on every build,
# so macOS asked for Downloads access again after each rebuild. A designated
# requirement on the bundle ID survives rebuilds.
codesign --force --sign - \
  --requirements "=designated => identifier \"$LABEL\"" "$APP"

# An unset variable keeps the installed agent's value, so a plain rebuild
# does not reset the default project to $HOME.
installed() {
  [ -f "$PLIST" ] && /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:$1" "$PLIST" 2>/dev/null || true
}
CWD="${SHOT_PROMPT_CWD:-$(installed SHOT_PROMPT_CWD)}"
DISPATCH="${SHOT_PROMPT_DISPATCH:-$(installed SHOT_PROMPT_DISPATCH)}"

sed -e "s|__APP__|$APP|" \
    -e "s|__CWD__|${CWD:-$HOME}|" \
    -e "s|__DISPATCH__|${DISPATCH:-$HOME/.local/bin/t3-dispatch}|" \
    launchagent.plist > "$PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout returns before the old agent is gone; bootstrapping too early fails
# with "Bootstrap failed: 5: Input/output error".
for _ in 1 2 3 4 5 6 7 8 9 10; do
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
  sleep 0.5
done
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "ShotPrompt running ($LABEL)"
