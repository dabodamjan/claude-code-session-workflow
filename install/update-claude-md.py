#!/usr/bin/env python3
"""Install, upgrade or remove the kit's marked block in a CLAUDE.md.

Usage:
  update-claude-md.py plan   --file PATH --block FILE
  update-claude-md.py apply  --file PATH --block FILE --backup PATH
  update-claude-md.py remove --file PATH --backup PATH
  update-claude-md.py check  --file PATH --block FILE

The block file must start with the begin marker and end with the end marker:
  <!-- session-workflow-kit:begin -->
  ...
  <!-- session-workflow-kit:end -->

plan / apply: if the target already holds exactly one marked block, only that block is
replaced; everything outside it is kept byte for byte. If it holds no block, the block is
appended after a blank line. If the file does not exist it is created. A begin marker
without an end marker (or vice versa, or more than one pair) aborts with exit 4.

Conflict surfacing: lines OUTSIDE the block that look like an existing rule on the same
subject (they mention "tldr", "tl;dr", or a word/line ceiling or limit) are printed as
warnings so the user can reconcile them by hand. They are never edited.

check: exit 0 if the block is present and identical to the block file, 1 otherwise.

Exit codes: 0 ok, 1 check failed, 2 usage, 4 malformed input (nothing written), 5 write failed.
Requires Python 3.8+. Part of claude-code-session-workflow.
"""
import argparse
import difflib
import os
import re
import shutil
import sys

BEGIN = "<!-- session-workflow-kit:begin -->"
END = "<!-- session-workflow-kit:end -->"
CONFLICT = re.compile(r"\btl;?dr\b|\b(words?|lines?)\s+(ceiling|limit|max(imum)?)\b", re.I)


def fail(code, msg):
    sys.stderr.write("update-claude-md: %s\n" % msg)
    sys.exit(code)


def read(path):
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        fail(4, "cannot read %s: %s" % (path, e))


def load_block(path):
    text = read(path)
    if text is None:
        fail(2, "block file not found: %s" % path)
    text = text.strip("\n") + "\n"
    if not text.startswith(BEGIN) or not text.rstrip("\n").endswith(END):
        fail(4, "block file must start with %s and end with %s" % (BEGIN, END))
    return text


def locate(text):
    """Return (start, end) character offsets of the marked block, or None."""
    b = [m.start() for m in re.finditer(re.escape(BEGIN), text)]
    e = [m.end() for m in re.finditer(re.escape(END), text)]
    if not b and not e:
        return None
    if len(b) != 1 or len(e) != 1 or e[0] < b[0]:
        fail(4, "found %d begin and %d end markers; expected exactly one pair. Nothing written."
             % (len(b), len(e)))
    end = e[0]
    if end < len(text) and text[end] == "\n":
        end += 1
    return b[0], end


def conflicts(text, span):
    out = []
    pos = 0
    for i, line in enumerate(text.splitlines(True), 1):
        start, stop = pos, pos + len(line)
        pos = stop
        if span and start >= span[0] and stop <= span[1]:
            continue
        if CONFLICT.search(line):
            out.append((i, line.rstrip("\n")))
    return out


def compose(text, block):
    if text is None:
        return block, None
    span = locate(text)
    if span:
        return text[:span[0]] + block + text[span[1]:], span
    base = text if text.endswith("\n") or not text else text + "\n"
    if base and not base.endswith("\n\n"):
        base += "\n"
    return base + block, None


def strip_block(text):
    span = locate(text)
    if not span:
        return text
    before, after = text[:span[0]], text[span[1]:]
    if before.endswith("\n\n") and (after == "" or after.startswith("\n")):
        before = before[:-1]
    return before + after


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
    ap.add_argument("--file", required=True)
    ap.add_argument("--block", default=None)
    ap.add_argument("--backup", default=None)
    a = ap.parse_args()

    text = read(a.file)

    if a.mode == "check":
        block = load_block(a.block) if a.block else fail(2, "--block required")
        if text is None:
            print("missing: %s does not exist" % a.file)
            sys.exit(1)
        span = locate(text)
        if not span:
            print("missing: no kit block in %s" % a.file)
            sys.exit(1)
        if text[span[0]:span[1]].strip("\n") != block.strip("\n"):
            print("outdated: kit block in %s differs from the kit's block file" % a.file)
            sys.exit(1)
        print("kit block present and current in %s" % a.file)
        sys.exit(0)

    if a.mode == "remove":
        if text is None:
            print("nothing to remove: %s does not exist" % a.file)
            sys.exit(0)
        new_text = strip_block(text)
        action = "remove"
    else:
        if not a.block:
            fail(2, "--block is required for plan/apply")
        block = load_block(a.block)
        new_text, span = compose(text, block)
        action = "create" if text is None else ("replace block" if span else "append block")
        for line_no, line in conflicts(text or "", span):
            print("WARNING: possible existing rule on the same subject at %s:%d (left untouched):\n    %s"
                  % (a.file, line_no, line[:120]))

    old = text or ""
    if new_text == old:
        print("no changes to %s" % a.file)
        sys.exit(0)
    print("%s: %s" % (action, a.file))
    diff = difflib.unified_diff(old.splitlines(True), new_text.splitlines(True),
                                fromfile=a.file + " (current)", tofile=a.file + " (after)")
    sys.stdout.write("".join(diff))
    if old and not old.endswith("\n"):
        sys.stdout.write("\n")

    if a.mode in ("apply", "remove"):
        if a.mode == "apply" and text is not None and not a.backup:
            fail(2, "--backup is required for apply on an existing file")
        write(a.file, new_text, a.backup)
        print("written: %s" % a.file)
        if a.backup and os.path.exists(a.backup):
            print("backup: %s" % a.backup)
    sys.exit(0)


if __name__ == "__main__":
    main()
