#!/usr/bin/env python3
"""Add or remove the session-workflow kit's hook registrations in a Claude Code
settings.json without touching anything else in the file.

Usage:
  merge-settings.py plan   --settings PATH --hooks-dir DIR [--terse]
  merge-settings.py apply  --settings PATH --hooks-dir DIR [--terse] --backup PATH
  merge-settings.py remove --settings PATH --backup PATH
  merge-settings.py check  --settings PATH [--terse]

The algorithm (plan / apply):
  1. Load the file. A missing file starts from {}. Invalid JSON, a non-object root, a
     `hooks` key that is not an object, or an event whose value is not a list aborts with
     exit 4 and nothing is written.
  2. For each kit registration (event, matcher, script, timeout): if any command hook under
     that event already runs the script (its command string names the script file), it is
     "present" and nothing is added, whatever its matcher. Otherwise the hook object
     {type: command, command, timeout} is appended to the group whose matcher matches (a
     missing matcher counts as ""), or a new group is appended. Nothing else is touched.
  3. A unified diff and a summary are printed. `apply` first copies the original to
     --backup (when the file exists), then writes to a temp file next to the target and
     renames it into place, so a crash cannot leave a half-written settings file.

`remove` deletes every command hook that runs one of the kit's scripts, drops groups and
events that become empty, and leaves everything else alone.

`check` exits 0 when every expected registration is present, 1 when one is missing,
4 when the file is malformed.

Exit codes: 0 ok, 1 check failed, 2 usage, 4 malformed input (nothing written), 5 write failed.
Requires Python 3.8+. Part of claude-code-session-workflow.
"""
import argparse
import difflib
import json
import os
import re
import shutil
import sys

CORE = [
    ("SessionStart", "compact", "compact-resume-inject.sh", 10),
    ("PreCompact", "manual", "compact-resume-precompact.sh", 10),
]
TERSE = [
    ("UserPromptSubmit", None, "terse-prompt-stash.sh", 5),
    ("Stop", None, "terse-gate.sh", 15),
]
KIT_SCRIPTS = [r[2] for r in CORE + TERSE] + ["compact-resume-store.sh", "terse-report.sh"]


def fail(code, msg):
    sys.stderr.write("merge-settings: %s\n" % msg)
    sys.exit(code)


def load(path):
    if not os.path.exists(path):
        return {}, ""
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        fail(4, "cannot read %s: %s" % (path, e))
    if not text.strip():
        return {}, text
    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        fail(4, "%s is not valid JSON (line %d col %d: %s). Nothing written. Fix the file first."
             % (path, e.lineno, e.colno, e.msg))
    if not isinstance(data, dict):
        fail(4, "%s: top-level value is not an object. Nothing written." % path)
    return data, text


def detect_indent(text):
    m = re.search(r"^([ \t]+)\"", text, re.M)
    if not m:
        return 2
    ws = m.group(1)
    return "\t" if "\t" in ws else len(ws)


def dump(data, text):
    indent = detect_indent(text) if text else 2
    out = json.dumps(data, indent=indent, ensure_ascii=False)
    if not text or text.endswith("\n"):
        out += "\n"
    return out


def command_for(hooks_dir, script):
    path = hooks_dir.rstrip("/") + "/" + script
    if path.startswith("~") or not re.search(r"[\s\"']", path):
        return "bash " + path
    return 'bash "%s"' % path


def mentions(command, script):
    return re.search(r"(^|[\s/\"'])" + re.escape(script) + r"([\s\"']|$)", command) is not None


def norm_matcher(group):
    m = group.get("matcher")
    return "" if m is None else str(m)


def validate_hooks(data):
    hooks = data.get("hooks")
    if hooks is None:
        return {}
    if not isinstance(hooks, dict):
        fail(4, "`hooks` is not an object. Nothing written.")
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            fail(4, "`hooks.%s` is not a list. Nothing written." % event)
        for g in groups:
            if not isinstance(g, dict):
                fail(4, "`hooks.%s` contains a non-object group. Nothing written." % event)
            if "hooks" in g and not isinstance(g["hooks"], list):
                fail(4, "`hooks.%s` has a group whose `hooks` is not a list. Nothing written." % event)
    return hooks


def find_present(groups, script):
    for g in groups:
        for h in g.get("hooks", []) or []:
            if isinstance(h, dict) and h.get("type", "command") == "command" \
                    and mentions(str(h.get("command", "")), script):
                return g
    return None


def merge(data, hooks_dir, regs):
    hooks = validate_hooks(data)
    data["hooks"] = hooks
    summary = []
    for event, matcher, script, timeout in regs:
        groups = hooks.setdefault(event, [])
        present = find_present(groups, script)
        label = "%s[%s] %s" % (event, matcher or "", script)
        if present is not None:
            have = norm_matcher(present)
            want = matcher or ""
            if have != want:
                summary.append("present (under matcher %r, expected %r; left as is): %s"
                               % (have, want, label))
            else:
                summary.append("present: " + label)
            continue
        entry = {"type": "command", "command": command_for(hooks_dir, script), "timeout": timeout}
        target = None
        for g in groups:
            if norm_matcher(g) == (matcher or ""):
                target = g
                break
        if target is None:
            target = {"hooks": []}
            if matcher is not None:
                target = {"matcher": matcher, "hooks": []}
            groups.append(target)
        target.setdefault("hooks", []).append(entry)
        summary.append("add: " + label)
    return summary


def remove(data):
    hooks = validate_hooks(data)
    summary = []
    for event in list(hooks.keys()):
        groups = hooks[event]
        kept_groups = []
        for g in groups:
            kept = []
            for h in g.get("hooks", []) or []:
                if isinstance(h, dict) and h.get("type", "command") == "command" and \
                        any(mentions(str(h.get("command", "")), s) for s in KIT_SCRIPTS):
                    summary.append("remove: %s[%s] %s" % (event, norm_matcher(g), h.get("command")))
                    continue
                kept.append(h)
            if kept or "hooks" not in g:
                g2 = dict(g)
                if "hooks" in g:
                    g2["hooks"] = kept
                kept_groups.append(g2)
        if kept_groups:
            hooks[event] = kept_groups
        else:
            del hooks[event]
    if not summary:
        summary.append("nothing to remove")
    return summary


def check(data, regs):
    hooks = validate_hooks(data)
    missing = []
    for event, matcher, script, _ in regs:
        if find_present(hooks.get(event, []), script) is None:
            missing.append("%s[%s] %s" % (event, matcher or "", script))
    return missing


def write(path, new_text, backup):
    if os.path.exists(path) and backup:
        os.makedirs(os.path.dirname(os.path.abspath(backup)), exist_ok=True)
        shutil.copy2(path, backup)
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".%s.tmp.%d" % (os.path.basename(path), os.getpid()))
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(new_text)
        os.replace(tmp, path)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        fail(5, "write failed: %s" % e)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["plan", "apply", "remove", "check"])
    ap.add_argument("--settings", required=True)
    ap.add_argument("--hooks-dir", default="~/.claude/hooks")
    ap.add_argument("--terse", action="store_true", help="also register the Stop/UserPromptSubmit enforcer")
    ap.add_argument("--backup", default=None, help="apply/remove: copy the original here first")
    a = ap.parse_args()

    regs = CORE + (TERSE if a.terse else [])
    data, text = load(a.settings)

    if a.mode == "check":
        missing = check(data, regs)
        for m in missing:
            print("missing: " + m)
        if not missing:
            print("all %d kit hook registrations present" % len(regs))
        sys.exit(1 if missing else 0)

    if a.mode == "remove":
        summary = remove(data)
    else:
        summary = merge(data, a.hooks_dir, regs)

    new_text = dump(data, text)
    changed = new_text != text
    if not os.path.exists(a.settings):
        print("%s does not exist; it will be created." % a.settings)
    for s in summary:
        print(s)
    if changed:
        diff = difflib.unified_diff(
            text.splitlines(True), new_text.splitlines(True),
            fromfile=a.settings + " (current)", tofile=a.settings + " (after)")
        sys.stdout.write("".join(diff))
        if text and not text.endswith("\n"):
            sys.stdout.write("\n")
    else:
        print("no changes to %s" % a.settings)

    if a.mode in ("apply", "remove") and changed:
        if a.mode == "apply" and not a.backup and os.path.exists(a.settings):
            fail(2, "--backup is required for apply on an existing file")
        write(a.settings, new_text, a.backup)
        print("written: %s" % a.settings)
        if a.backup and os.path.exists(a.backup):
            print("backup: %s" % a.backup)
    sys.exit(0)


if __name__ == "__main__":
    main()
