#!/usr/bin/env python3
"""Build and sign the "ShotPrompt" iPhone shortcut (see ios/README.md).

The shortcut: Take or Get Latest Screenshot -> Ask for Input (the prompt) ->
Base64 Encode -> POST JSON {prompt, image} to <receiver>/shot with the bearer
token -> Show Notification with the reply.

The receiver URL and token are Text actions with import questions, so the
iPhone asks for them when the file is imported; --url and --token only fill
the defaults. Without --token the file holds no secret.

  scripts/make-shortcut.py --output ios/ShotPrompt.shortcut
  scripts/make-shortcut.py --capture take --output ShotPrompt-BackTap.shortcut
  scripts/make-shortcut.py --url https://mac.tailnet.ts.net:8444 --token "$(defaults read io.github.aliir74.shot-prompt receiverToken)" --output /tmp/mine.shortcut
"""
import argparse
import plistlib
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path


def ref(action_uuid, name):
    return {"OutputName": name, "OutputUUID": action_uuid, "Type": "ActionOutput"}


def attachment(action_uuid, name):
    return {"Value": ref(action_uuid, name), "WFSerializationType": "WFTextTokenAttachment"}


def text(*pieces):
    """A text field: plain strings and (uuid, name) variable references, in order."""
    out, attachments = "", {}
    for piece in pieces:
        if isinstance(piece, str):
            out += piece
        else:
            attachments[f"{{{len(out)}, 1}}"] = ref(*piece)
            out += "￼"
    return {"Value": {"string": out, "attachmentsByRange": attachments}, "WFSerializationType": "WFTextTokenString"}


def dictionary(items):
    return {
        "Value": {"WFDictionaryFieldValueItems": [
            {"WFItemType": 0, "WFKey": text(key), "WFValue": value} for key, value in items
        ]},
        "WFSerializationType": "WFDictionaryFieldValue",
    }


def action(identifier, **params):
    return {"WFWorkflowActionIdentifier": f"is.workflow.actions.{identifier}", "WFWorkflowActionParameters": params}


def build(url, token, capture):
    ids = {k: str(uuid.uuid4()).upper() for k in ("url", "token", "shot", "prompt", "b64", "post")}
    shot_name = "Screenshot" if capture == "take" else "Latest Screenshots"
    actions = [
        action("gettext", UUID=ids["url"], WFTextActionText=url),
        action("gettext", UUID=ids["token"], WFTextActionText=token),
        action("takescreenshot" if capture == "take" else "getlastscreenshot", UUID=ids["shot"]),
        action("ask", UUID=ids["prompt"], WFInputType="Text",
               WFAskActionPrompt="Prompt for T3 (start with @project to pick one)"),
        action("base64encode", UUID=ids["b64"], WFInput=attachment(ids["shot"], shot_name),
               WFEncodeMode="Encode", WFBase64LineBreakMode="None"),
        action("downloadurl", UUID=ids["post"], ShowHeaders=True,
               WFURL=text((ids["url"], "Text"), "/shot"),
               WFHTTPMethod="POST", WFHTTPBodyType="JSON",
               WFHTTPHeaders=dictionary([("Authorization", text("Bearer ", (ids["token"], "Text")))]),
               WFJSONValues=dictionary([("prompt", text((ids["prompt"], "Provided Input"))),
                                        ("image", text((ids["b64"], "Base64 Encoded")))])),
        action("notification", WFNotificationActionTitle="ShotPrompt",
               WFNotificationActionBody=text((ids["post"], "Contents of URL"))),
    ]
    question = lambda index, prompt, default: {
        "ActionIndex": index, "Category": "Parameter", "Parameter": "WFTextActionText",
        "Text": prompt, "DefaultValue": default,
    }
    return {
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "2607.0.2",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 463140863, "WFWorkflowIconGlyphNumber": 59511},
        "WFWorkflowImportQuestions": [
            question(0, "Receiver URL: https://<your Mac>.<tailnet>.ts.net:8444 (no trailing slash)", url),
            question(1, "Receiver token: defaults read io.github.aliir74.shot-prompt receiverToken", token),
        ],
        "WFWorkflowInputContentItemClasses": ["WFImageContentItem"],
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowTypes": [],
        "WFQuickActionSurfaces": [],
        "WFWorkflowHasShortcutInputVariables": False,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default="https://your-mac.your-tailnet.ts.net:8444")
    parser.add_argument("--token", default="")
    parser.add_argument("--capture", choices=["latest", "take"], default="latest",
                        help="latest: for the screenshot automation; take: for Back Tap or the Action button")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--unsigned", action="store_true", help="write the plist without signing")
    args = parser.parse_args()
    data = plistlib.dumps(build(args.url.rstrip("/"), args.token, args.capture), fmt=plistlib.FMT_BINARY)
    if args.unsigned:
        args.output.write_bytes(data)
        return
    with tempfile.TemporaryDirectory() as tmp:
        raw = Path(tmp) / "ShotPrompt.shortcut"
        raw.write_bytes(data)
        result = subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", raw, "--output", args.output],
                                capture_output=True, text=True)
        if result.returncode != 0 or not args.output.exists():
            sys.exit(f"shortcuts sign failed: {result.stderr.strip() or result.stdout.strip()}")


if __name__ == "__main__":
    main()
