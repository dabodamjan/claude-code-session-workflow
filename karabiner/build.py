#!/usr/bin/env python3
"""Generate the Karabiner-Elements rule files for the session-workflow chords.

  python3 karabiner/build.py          # rewrite session-workflow.json and session-workflow-scoped.json
  python3 karabiner/build.py --check  # exit 1 if the committed files differ from the generator output

Both files hold the same five chords. The "scoped" file adds a frontmost_application_if
condition so the chords only fire in the apps listed in BUNDLE_IDS; the plain file fires
everywhere Karabiner is active.

Key-code assumptions: a US-style (ANSI) layout, where the physical keys to the right of the
spacebar carry , . / ' and \\ and typing a character means pressing the key of the same name.
On another layout, open Karabiner-EventViewer, press the key you want, read its key_code,
and change CHORDS (the trigger keys) or KEYCODES (the characters typed) below, then rerun.

Part of claude-code-session-workflow.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PLAIN = os.path.join(HERE, "session-workflow.json")
SCOPED = os.path.join(HERE, "session-workflow-scoped.json")

MODIFIER = "right_option"
DELAY_MS = 400          # wait for the typed text to land before pressing Escape/Enter
ESCAPE_HOLD_MS = 150
GO_WAIT_MS = 1200       # pause between the /compact Enter and the queued follow-up message

# (trigger key_code, text to type, needs Escape before Enter, trailing queued message)
CHORDS = [
    ("comma",     "/compact-check",    True,  None),
    ("period",    "/compact",          True,  "go"),
    ("slash",     "tldr",              False, None),
    ("quote",     "/end-session",      True,  None),
    ("backslash", "/archive-session",  True,  None),
]

# Bundle identifiers the scoped variant fires in. The first four were read from each app's
# Info.plist on the author's Mac on 2026-10-22; iTerm2 is the identifier the Karabiner
# documentation itself uses as its frontmost_application example (not verified locally).
# Add your own terminal: Karabiner-EventViewer > Frontmost Application tab shows the
# identifier of whatever app is in front.
BUNDLE_IDS = [
    "^com\\.anthropic\\.claudefordesktop$",   # Claude desktop app
    "^com\\.apple\\.Terminal$",              # Terminal.app
    "^com\\.mitchellh\\.ghostty$",           # Ghostty
    "^com\\.microsoft\\.VSCode$",            # Visual Studio Code
    "^com\\.googlecode\\.iterm2$",           # iTerm2
]

KEYCODES = {"/": "slash", "-": "hyphen", " ": "spacebar", ".": "period", ",": "comma"}


def keycode(ch):
    if ch in KEYCODES:
        return KEYCODES[ch]
    if ch.isalnum() and ch.islower() or ch.isdigit():
        return ch
    raise SystemExit("no key_code mapping for %r; add it to KEYCODES" % ch)


def typed(text):
    return [{"key_code": keycode(c), "modifiers": []} for c in text]


def rule(trigger, text, escape, follow_up, scoped):
    invoked = []
    if escape:
        invoked.append({"key_code": "escape", "modifiers": [], "hold_down_milliseconds": ESCAPE_HOLD_MS})
    invoked.append({"key_code": "return_or_enter", "modifiers": []})
    if follow_up:
        invoked.append({"key_code": "vk_none", "hold_down_milliseconds": GO_WAIT_MS})
        invoked.extend(typed(follow_up))
        invoked.append({"key_code": "return_or_enter", "modifiers": []})
    label = "Right Option + %s  ->  type %s%s" % (
        {"comma": ",", "period": ".", "slash": "/", "quote": "'", "backslash": "\\"}[trigger],
        text, " then the queued follow-up '%s'" % follow_up if follow_up else "")
    manipulator = {
        "type": "basic",
        "from": {"key_code": trigger, "modifiers": {"mandatory": [MODIFIER]}},
        "to": typed(text),
        "to_delayed_action": {"to_if_invoked": invoked, "to_if_canceled": []},
        "parameters": {"basic.to_delayed_action_delay_milliseconds": DELAY_MS},
    }
    if scoped:
        manipulator["conditions"] = [{"type": "frontmost_application_if", "bundle_identifiers": BUNDLE_IDS}]
    return {"description": label, "manipulators": [manipulator]}


def build(scoped):
    title = "Claude Code session workflow" + (" (Claude app and terminals only)" if scoped else "")
    return {"title": title, "rules": [rule(*c, scoped=scoped) for c in CHORDS]}


def render(obj):
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"


def main():
    outputs = {PLAIN: render(build(False)), SCOPED: render(build(True))}
    if "--check" in sys.argv:
        # Structural comparison: the committed files must parse to exactly what the
        # generator builds. Whitespace differences do not count; a changed key does.
        bad = []
        for path, want in outputs.items():
            try:
                with open(path, "r", encoding="utf-8") as f:
                    have = json.load(f)
            except (OSError, ValueError):
                have = None
            if have != json.loads(want):
                bad.append(path)
        if bad:
            print("out of date: " + ", ".join(os.path.relpath(p) for p in bad))
            sys.exit(1)
        print("karabiner rule files match the generator")
        return
    for path, text in outputs.items():
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        print("wrote " + os.path.relpath(path))


if __name__ == "__main__":
    main()
