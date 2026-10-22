#!/usr/bin/env bash
# terse-report.sh: not a hook. Run by hand.
#
# Reads the log written by terse-gate.sh and prints the trend: per-day reply length and
# filler score, the top offending phrases, and an optional before/after split so a change
# to the rules can be judged by numbers instead of impression.
#
# Usage:
#   bash ~/.claude/hooks/terse-report.sh                  # last 14 days
#   bash ~/.claude/hooks/terse-report.sh 30               # last 30 days
#   bash ~/.claude/hooks/terse-report.sh 14 2026-08-14    # split before/after a date
#
# Part of claude-code-session-workflow (reads the log of hooks/terse-gate.sh).
set -uo pipefail

DAYS="${1:-14}"
SPLIT="${2:-}"
LOG="${TERSE_LOG:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-workflow-kit/logs/terse-gate.tsv}"
: "${TERSE_TLDR_WORDS:=130}"
: "${TERSE_TLDR_LINES:=10}"

[[ -f "$LOG" ]] || { echo "no log yet at $LOG (terse-gate.sh has not run)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }

LOG="$LOG" DAYS="$DAYS" SPLIT="$SPLIT" \
TERSE_TLDR_WORDS="$TERSE_TLDR_WORDS" TERSE_TLDR_LINES="$TERSE_TLDR_LINES" \
python3 -I - <<'PY'
import os, csv, statistics, collections, datetime

path = os.environ["LOG"]
days = int(os.environ.get("DAYS") or 14)
split = (os.environ.get("SPLIT") or "").strip()
ceil_words = int(os.environ.get("TERSE_TLDR_WORDS") or 130)
ceil_lines = int(os.environ.get("TERSE_TLDR_LINES") or 10)

cutoff = datetime.date.today() - datetime.timedelta(days=days)
rows = []
with open(path, newline="", encoding="utf-8", errors="replace") as f:
    for r in csv.DictReader(f, delimiter="\t"):
        try:
            day = datetime.date.fromisoformat(r["ts"][:10])
        except Exception:
            continue
        if day < cutoff:
            continue
        try:
            r["_day"] = day
            r["words"] = int(r["words"]); r["lines"] = int(r["lines"])
            r["tic_score"] = int(r["tic_score"]); r["tldr"] = int(r["tldr"])
        except Exception:
            continue
        rows.append(r)

if not rows:
    print("no rows in the last %d days" % days)
    raise SystemExit(0)

def med(xs):
    return int(statistics.median(xs)) if xs else 0

def block(rs, label):
    real = [r for r in rs if r["verdict"] != "skip-short"]
    if not real:
        print("%-12s  no scored turns" % label); return
    w = [r["words"] for r in real]
    t = [r["tic_score"] for r in real]
    blocked = sum(1 for r in real if r["verdict"].startswith("block"))
    would = sum(1 for r in real if r["verdict"] == "observe-would-block")
    ticky = sum(1 for r in real if r["tic_score"] > 0)
    print("%-12s  turns %-5d  median words %-5d  p90 words %-5d  median filler %-3d  "
          "turns with filler %d%%  blocked %d  would-block %d"
          % (label, len(real), med(w),
             sorted(w)[int(len(w) * 0.9)] if w else 0,
             med(t), round(100 * ticky / len(real)), blocked, would))

print("terse-gate report  (%s, last %d days, %d turns)\n" % (path, days, len(rows)))

print("PER DAY")
byday = collections.defaultdict(list)
for r in rows:
    byday[r["_day"]].append(r)
for day in sorted(byday):
    block(byday[day], str(day))

print("\nTLDR TURNS ONLY  (the user typed tldr; ceiling is %d lines / %d words)" % (ceil_lines, ceil_words))
tl = [r for r in rows if r["tldr"] == 1 and r["verdict"] != "skip-short"]
if tl:
    over = sum(1 for r in tl if r["words"] > ceil_words or r["lines"] > ceil_lines)
    print("  %d tldr turns, median %d words / %d lines, %d over the ceiling (%d%%)"
          % (len(tl), med([r["words"] for r in tl]), med([r["lines"] for r in tl]),
             over, round(100 * over / len(tl))))
else:
    print("  none")

print("\nTOP PHRASES")
c = collections.Counter()
for r in rows:
    h = r.get("hits") or "-"
    if h == "-":
        continue
    for part in h.split(";"):
        part = part.strip()
        if not part:
            continue
        name, _, n = part.rpartition(" x")
        try:
            c[name.strip()] += int(n)
        except Exception:
            c[part] += 1
for name, n in c.most_common(15):
    print("  %5d  %s" % (n, name))
if not c:
    print("  none")

if split:
    try:
        d = datetime.date.fromisoformat(split)
    except Exception:
        raise SystemExit(0)
    print("\nBEFORE / AFTER %s" % d)
    block([r for r in rows if r["_day"] < d], "before")
    block([r for r in rows if r["_day"] >= d], "after")
PY
