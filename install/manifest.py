#!/usr/bin/env python3
"""Read and write the kit's install manifest (<config dir>/session-workflow-kit/manifest.json).

The manifest records what the installer actually did, so that `uninstall` can undo exactly
that and nothing else: which files it created, which existing files it replaced (and where
the original was backed up), which hook registrations it added, and what it did to CLAUDE.md.
Provenance is kept across upgrades: a file first recorded as "replaced" with a backup keeps
that backup even when later runs replace the kit's own copy again.

Usage:
  manifest.py update --manifest PATH --commit SHA --config-dir DIR --backup-dir DIR
                     [--file REL|created] [--file REL|replaced|BACKUP] ...
                     [--registration EVENT|MATCHER|SCRIPT] ...
                     [--claude-md created|appended|replaced]
                     [--karabiner-file PATH|created] | [--karabiner-file PATH|replaced|BACKUP]
  manifest.py get    --manifest PATH --key KEY
                     KEY: commit | config_dir | claude_md | files | registrations | karabiner_file
                     files prints one "REL|ACTION|BACKUP" line per entry, registrations one
                     "EVENT|MATCHER|SCRIPT" line each, karabiner_file "PATH|ACTION|BACKUP".
  manifest.py prune  --manifest PATH [--file REL] ... [--registration EVENT|MATCHER|SCRIPT] ...
                     [--claude-md] [--karabiner-file]
                     Drops the named entries. Deletes the manifest when nothing managed remains.

Exit codes: 0 ok, 2 usage, 4 unreadable manifest, 5 write failed.
Requires Python 3.8+. Part of claude-code-session-workflow.
"""
import argparse
import json
import os
import sys
import time

KIT = "claude-code-session-workflow"


def fail(code, msg):
    sys.stderr.write("manifest: %s\n" % msg)
    sys.exit(code)


def load(path):
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        fail(4, "cannot read %s: %s" % (path, e))
    if not isinstance(data, dict):
        fail(4, "%s is not a JSON object" % path)
    files = data.get("files")
    if isinstance(files, list):  # an older shape: file names only, provenance unknown
        data["files"] = {str(rel): {"action": "unknown"} for rel in files}
    elif not isinstance(files, dict):
        data["files"] = {}
    if not isinstance(data.get("registrations"), list):
        data["registrations"] = []
    return data


def save(path, data):
    d = os.path.dirname(os.path.abspath(path))
    tmp = os.path.join(d, ".manifest.tmp.%d" % os.getpid())
    try:
        os.makedirs(d, exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, path)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        fail(5, "write failed: %s" % e)


def parse_entry(spec, what):
    parts = spec.split("|")
    if len(parts) == 2 and parts[1] in ("created", "replaced", "unknown"):
        return parts[0], {"action": parts[1]}
    if len(parts) == 3 and parts[1] == "replaced":
        return parts[0], {"action": "replaced", "backup": parts[2]}
    fail(2, "bad %s spec %r (want NAME|created or NAME|replaced|BACKUP)" % (what, spec))


def components(data):
    regs = data.get("registrations") or []
    return {
        "terse_gate": any(r.endswith("|terse-gate.sh") for r in regs),
        "karabiner": bool(data.get("karabiner_file")),
    }


def managed_count(data):
    n = len(data.get("files") or {}) + len(data.get("registrations") or [])
    n += 1 if data.get("claude_md") else 0
    n += 1 if data.get("karabiner_file") else 0
    return n


def do_update(a):
    data = load(a.manifest) or {"kit": KIT, "files": {}, "registrations": []}
    now = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    data["kit"] = KIT
    data["commit"] = a.commit
    data["installed_at"] = now
    data.setdefault("first_installed_at", now)
    data["config_dir"] = a.config_dir
    data["backup_dir"] = a.backup_dir
    for spec in a.file or []:
        rel, entry = parse_entry(spec, "--file")
        data["files"].setdefault(rel, entry)  # first provenance wins
    for reg in a.registration or []:
        if reg.count("|") != 2:
            fail(2, "bad --registration %r (want EVENT|MATCHER|SCRIPT)" % reg)
        if reg not in data["registrations"]:
            data["registrations"].append(reg)
    if a.claude_md and not data.get("claude_md"):
        data["claude_md"] = a.claude_md
    if a.karabiner_file and not data.get("karabiner_file"):
        path, entry = parse_entry(a.karabiner_file, "--karabiner-file")
        entry["path"] = path
        data["karabiner_file"] = entry
    data["components"] = components(data)
    save(a.manifest, data)
    print("written: %s" % a.manifest)


def do_get(a):
    data = load(a.manifest)
    if data is None:
        fail(4, "no manifest at %s" % a.manifest)
    k = a.key
    if k == "files":
        for rel, e in sorted(data["files"].items()):
            print("%s|%s|%s" % (rel, e.get("action", "unknown"), e.get("backup", "")))
    elif k == "registrations":
        for r in data["registrations"]:
            print(r)
    elif k == "karabiner_file":
        e = data.get("karabiner_file")
        if e:
            print("%s|%s|%s" % (e.get("path", ""), e.get("action", "unknown"), e.get("backup", "")))
    elif k in ("commit", "config_dir", "claude_md", "backup_dir", "installed_at"):
        v = data.get(k)
        print("" if v is None else v)
    else:
        fail(2, "unknown key %r" % k)


def do_prune(a):
    data = load(a.manifest)
    if data is None:
        print("no manifest at %s" % a.manifest)
        return
    for rel in a.file or []:
        data["files"].pop(rel, None)
    for reg in a.registration or []:
        if reg in data["registrations"]:
            data["registrations"].remove(reg)
    if a.claude_md:
        data["claude_md"] = None
    if a.karabiner_file:
        data["karabiner_file"] = None
    data["components"] = components(data)
    n = managed_count(data)
    if n == 0:
        try:
            os.unlink(a.manifest)
        except OSError as e:
            fail(5, "cannot delete %s: %s" % (a.manifest, e))
        print("deleted: %s (nothing managed remains)" % a.manifest)
    else:
        save(a.manifest, data)
        print("kept: %s (%d managed item(s) remain)" % (a.manifest, n))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["update", "get", "prune"])
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--commit")
    ap.add_argument("--config-dir")
    ap.add_argument("--backup-dir")
    ap.add_argument("--file", action="append")
    ap.add_argument("--registration", action="append")
    ap.add_argument("--claude-md", nargs="?", const="prune", default=None)
    ap.add_argument("--karabiner-file", nargs="?", const="prune", default=None)
    ap.add_argument("--key")
    a = ap.parse_args()
    if a.mode == "update":
        if not (a.commit and a.config_dir and a.backup_dir):
            fail(2, "update needs --commit, --config-dir and --backup-dir")
        if a.claude_md == "prune" or a.karabiner_file == "prune":
            fail(2, "update needs a value for --claude-md / --karabiner-file")
        do_update(a)
    elif a.mode == "get":
        if not a.key:
            fail(2, "get needs --key")
        do_get(a)
    else:
        do_prune(a)


if __name__ == "__main__":
    main()
