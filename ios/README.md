# ShotPrompt on iPhone

Take a screenshot on the iPhone, type a prompt, and a new T3 Code thread opens on your Mac with the screenshot and the prompt. The Mac app's receiver takes the request; the phone reaches it over Tailscale.

```
iPhone screenshot → Shortcuts automation → Ask for Input → POST /shot (tailnet) → ShotPrompt.app → $SHOT_PROMPT_DISPATCH → T3 thread
```

Start the prompt with `@project` to send the thread to that T3 project, for example `@shot-prompt why is this icon blurry?`. Case does not matter and names may have spaces. A title T3 shows twice matches the first one in the picker: the default project, then the most recently used. Without it, the thread goes to `$SHOT_PROMPT_CWD`.

## Mac: turn on the receiver

```sh
defaults write io.github.aliir74.shot-prompt receiverPort -int 8790
defaults write io.github.aliir74.shot-prompt receiverToken -string "$(openssl rand -hex 24)"
launchctl kickstart -k gui/$(id -u)/io.github.aliir74.shot-prompt
tailscale serve --bg --https=8444 http://127.0.0.1:8790
```

The receiver listens on 127.0.0.1 only and needs the token on every request. `tailscale serve` publishes it to your tailnet, never the internet. Pick any free HTTPS port; T3's own Tailscale setting owns `:443`. Check it:

```sh
curl -H "Authorization: Bearer $(defaults read io.github.aliir74.shot-prompt receiverToken)" \
  https://<your-mac>.<tailnet>.ts.net:8444/projects
```

Routes:

- `GET /projects`: a JSON array of the picker's project names.
- `POST /shot`: JSON `{"prompt": "...", "image": "<base64 PNG/JPEG/GIF/WebP>", "project": "<optional name>"}`, or a multipart form with the same fields (`image` as a file). Replies with JSON: `{"ok": true, "message": "Started a T3 thread in <project>.", "project": ..., "threadUrl": ..., "appLink": "t3code://threads/<environment>/<thread>"}`, or `{"ok": false, "message": "<error>"}`. An explicit `project` wins over an `@project` prefix.

## iPhone: install the shortcut

1. Get Tailscale on the iPhone and turn on VPN On Demand, so the shortcut reaches the Mac without opening Tailscale first.
2. Open `ShotPrompt.shortcut` on the iPhone (AirDrop, a chat, or a tailnet URL in Safari; a Taildrop file in Files asks for Face ID first). When asked, paste the receiver URL (`https://<your-mac>.<tailnet>.ts.net:8444`) and the token.
3. Shortcuts → Automation → New Automation → the screenshot trigger (iOS 27.2 words it "When I save a screenshot to Photos, Files or Clipboard") → Run ShotPrompt. Keep **Automation** on; leave **Notify** off.

Every screenshot now asks for a prompt; Cancel skips it. After sending, an **Open in T3?** alert names the project: OK opens the new thread in the T3 Code app (`t3code://threads/<environment>/<thread>`), Cancel stays where you are. The first run asks to allow sending the photo to your Mac and opening T3 Code: choose Always Allow / Allow.

iOS runs the automation only once the screenshot is saved, which is when the corner thumbnail goes away (about 3 seconds). Swipe the thumbnail off the screen to save it, and get the prompt, at once.

Before iOS 27, or to send only when you choose: install `ShotPrompt-BackTap.shortcut` instead. It takes the screenshot itself, so put it on Settings → Accessibility → Touch → Back Tap, or on the Action button.

Make your own copies (for example with your URL and token as the import defaults) with `scripts/make-shortcut.py --help`. It signs them with `shortcuts sign`, which needs a Mac signed in to iCloud.
