#!/usr/bin/env python3
"""Add or remove the session-workflow kit's hook registrations in a Claude Code
settings.json without touching anything else in the file.

Usage:
  merge-settings.py plan   --settings PATH --hooks-dir DIR [--terse]
  merge-settings.py apply  --settings PATH --hooks-dir DIR [--terse] --backup PATH
  merge-settings.py remove --settings PATH --hooks-dir DIR --backup PATH [--only EVENT|MATCHER|SCRIPT ...]
  merge-settings.py check  --settings PATH --hooks-dir DIR [--terse]

The algorithm (plan / apply):
  1. Load the file. A missing file starts from {}. Invalid JSON, a non-object root, a
     `hooks` key that is not an object, or an event whose value is not a list aborts with
     exit 4 and nothing is written.
  2. For each kit registration (event, matcher, script, timeout): it is "present" only when
     a command hook under that event sits in a group with the same matcher (a missing
     matcher counts as "") and one of its command's words resolves to <hooks-dir>/<script>
     (after ~ and $HOME expansion). Then nothing is added. A hook under the same event that
     names the script file but has another matcher or another path is reported as a
     "conflict" and left alone; the required registration is still added. Otherwise the
     hook object {type: command, command, timeout} is appended to the group whose matcher
     matches, or a new group is appended. Nothing else is touched.
  3. A unified diff and a summary are printed. `apply` first copies the original to
     --backup (when the file exists), then writes to a temp file next to the target and
     renames it into place, so a crash cannot leave a half-written settings file.

`remove` deletes command hooks that resolve to a kit script under --hooks-dir, drops groups
and events that become empty, and leaves everything else alone. With --only, it deletes
only the listed registrations (the ones the installer's manifest says it added).

`check` exits 0 when every expected registration is present under the right event, matcher
and path, 1 when one is missing (conflicting registrations are named), 4 when the file is
malformed.

Exit codes: 0 ok, 1 check failed, 2 usage, 4 malformed input (nothing written), 5 write failed.
Requires Python 3.8+. Part of claude-code-session-workflow.
"""
import argparse
import difflib
import json
import os
import re
import shlex
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
SAFE = re.compile(r"^[A-Za-z0-9_./~-]+$")


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


def resolve(path):
    """Normalise a hook path for comparison: expand ~ and $HOME, collapse . and .."""
    return os.path.normpath(os.path.expanduser(os.path.expandvars(path)))


def command_for(hooks_dir, script):
    """The command string the kit registers. Plain paths stay unquoted so a leading ~
    still expands; anything with shell-significant characters is quoted."""
    path = hooks_dir.rstrip("/") + "/" + script
    if SAFE.match(path):
        return "bash " + path
    if path.startswith("~/"):
        return "bash ~/" + shlex.quote(path[2:])
    return "bash " + shlex.quote(path)


def words_of(command):
    try:
        return shlex.split(command)
    except ValueError:
        return command.split()


def names_script(command, script):
    """True when some word of the command is the script file (any directory)."""
    return any(os.path.basename(w) == script for w in words_of(command))


def runs_path(command, expected):
    """True when some word of the command resolves to the expected file path."""
    return any(resolve(w) == expected for w in words_of(command) if os.path.basename(w) == os.path.basename(expected))


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


def command_hooks(groups):
    for g in groups:
        for h in g.get("hooks", []) or []:
            if isinstance(h, dict) and h.get("type", "command") == "command":
                yield g, h, str(h.get("command", ""))


def classify(groups, matcher, script, expected):
    """Return ("present", group) when the exact registration exists, else
    ("conflict", [descriptions]) or ("absent", [])."""
    want = matcher or ""
    conflicts = []
    for g, h, cmd in command_hooks(groups):
        if not names_script(cmd, script):
            continue
        if norm_matcher(g) == want and runs_path(cmd, expected):
            return "present", g
        why = []
        if norm_matcher(g) != want:
            why.append("matcher %r, expected %r" % (norm_matcher(g), want))
        if not runs_path(cmd, expected):
            why.append("runs %r, expected %s" % (cmd, expected))
        conflicts.append("; ".join(why))
    return ("conflict" if conflicts else "absent"), conflicts


def label(event, matcher, script):
    return "%s[%s] %s" % (event, matcher or "", script)


def merge(data, hooks_dir, regs):
    hooks = validate_hooks(data)
    data["hooks"] = hooks
    summary = []
    for event, matcher, script, timeout in regs:
        groups = hooks.setdefault(event, [])
        expected = resolve(hooks_dir.rstrip("/") + "/" + script)
        state, info = classify(groups, matcher, script, expected)
        if state == "present":
            summary.append("present: " + label(event, matcher, script))
            continue
        for why in info:
            summary.append("conflict (left as is, the kit's own registration is added next to it): %s has a hook that names %s with %s"
                           % (event, script, why))
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
        summary.append("add: " + label(event, matcher, script))
    return summary


def parse_only(items):
    out = set()
    for item in items or []:
        parts = item.split("|")
        if len(parts) != 3:
            fail(2, "--only expects EVENT|MATCHER|SCRIPT, got %r" % item)
        out.add((parts[0], parts[1], parts[2]))
    return out


def remove(data, hooks_dir, only):
    hooks = validate_hooks(data)
    summary = []
    expected = {s: resolve(hooks_dir.rstrip("/") + "/" + s) for s in KIT_SCRIPTS}
    for event in list(hooks.keys()):
        groups = hooks[event]
        kept_groups = []
        for g in groups:
            kept = []
            for h in g.get("hooks", []) or []:
                drop = False
                if isinstance(h, dict) and h.get("type", "command") == "command":
                    cmd = str(h.get("command", ""))
                    for s, path in expected.items():
                        if not runs_path(cmd, path):
                            continue
                        if only is not None and (event, norm_matcher(g), s) not in only:
                            continue
                        drop = True
                        break
                if drop:
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


def check(data, hooks_dir, regs):
    hooks = validate_hooks(data)
    missing, notes = [], []
    for event, matcher, script, _ in regs:
        expected = resolve(hooks_dir.rstrip("/") + "/" + script)
        state, info = classify(hooks.get(event, []), matcher, script, expected)
        if state != "present":
            missing.append(label(event, matcher, script))
            for why in info:
                notes.append("conflict: %s has a hook naming %s with %s" % (event, script, why))
    return missing, notes


def write(path, new_text, backup):
    if os.path.exists(path) and backup:
        try:
            os.makedirs(os.path.dirname(os.path.abspath(backup)), exist_ok=True)
            shutil.copy2(path, backup)
        except OSError as e:
            fail(5, "backup failed, nothing written: %s" % e)
    d = os.path.dirname(os.path.abspath(path))
    tmp = os.path.join(d, ".%s.tmp.%d" % (os.path.basename(path), os.getpid()))
    try:
        os.makedirs(d, exist_ok=True)
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
    ap.add_argument("--only", action="append", default=None,
                    help="remove: only this EVENT|MATCHER|SCRIPT registration (repeatable)")
    a = ap.parse_args()

    regs = CORE + (TERSE if a.terse else [])
    data, text = load(a.settings)

    if a.mode == "check":
        missing, notes = check(data, a.hooks_dir, regs)
        for n in notes:
            print(n)
        for m in missing:
            print("missing: " + m)
        if not missing:
            print("all %d kit hook registrations present" % len(regs))
        sys.exit(1 if missing else 0)

    if a.mode == "remove":
        summary = remove(data, a.hooks_dir, parse_only(a.only) if a.only is not None else None)
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
