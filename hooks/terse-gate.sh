#!/usr/bin/env bash
# terse-gate.sh: Stop hook. Best-effort enforcer for the "tldr" reply rule, plus a log of
# every turn's length and filler score so the trend is measurable instead of felt.
#
# WHY THIS EXISTS
# The tldr rule lives in CLAUDE.md as prose, and the Claude Code docs say CLAUDE.md is
# "context, not enforced configuration" with "no guarantee of strict compliance". A Stop
# hook is the one place a reply can be checked mechanically against the text that was
# actually produced.
#
# WHAT THE HOOK CAN SEE (hooks reference, checked 2026-10-22)
#   - Stop input carries `last_assistant_message`, the final assistant text of the turn.
#   - Stop input carries `stop_hook_active`, true when Claude is already continuing because
#     of a stop hook. That is the documented loop guard; a per-turn marker file backs it up.
#   - Exit code 2 blocks the stop and hands stderr to Claude as the reason to continue.
#   - It does NOT see the user's prompt. terse-prompt-stash.sh (UserPromptSubmit) writes it
#     to a per-turn file; this script reads it back. Without that hook registered, the tldr
#     rule never fires and only the filler log runs.
#
# WHAT IT CANNOT DO (stated plainly rather than worked around)
#   - It cannot suppress the reply you already saw. Stop fires after the response is shown.
#     A block produces a SECOND, shorter reply; it does not retract the first.
#   - It only sees the FINAL message of a turn. Text between tool calls is never gated.
#   - It counts words and lines. It cannot judge whether the short reply is the right one.
# This is why the kit calls it best-effort.
#
# ONE TLDR POLICY: 10 lines / 130 words, counted on prose only. Fenced code blocks and
# quoted lines (> ...) are stripped before counting. The same numbers appear in
# claude-md/tldr-block.md; change both together.
#
# MODES (env overrides the defaults below)
#   enforce  - block on exit 2 and ask for a rewrite
#   observe  - log only, never block
#   off      - do not evaluate the rule at all
# Default: the tldr rule ENFORCES (it checks numbers the user stated); the filler-phrase
# rule OBSERVES until the log shows where a threshold belongs.
#
# Log: <config dir>/session-workflow-kit/logs/terse-gate.tsv, one row per turn.
# Report: bash terse-report.sh
#
# Fail-silent: any missing field, parse error or unexpected state exits 0.
# Part of claude-code-session-workflow (pairs with hooks/terse-prompt-stash.sh).
set -uo pipefail

: "${TERSE_TLDR_MODE:=enforce}"    # enforce | observe | off
: "${TERSE_TIC_MODE:=observe}"     # enforce | observe | off
: "${TERSE_TLDR_WORDS:=130}"       # the tldr ceiling (words)
: "${TERSE_TLDR_LINES:=10}"        # the tldr ceiling (lines)
: "${TERSE_TIC_THRESHOLD:=3}"      # block when the weighted filler score reaches this
: "${TERSE_TIC_MIN_WORDS:=40}"     # below this, a filler phrase is not padding
: "${TERSE_MIN_WORDS:=25}"         # below this, skip the turn entirely
: "${SESSION_WORKFLOW_STATE_DIR:=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-workflow-kit/state}"
: "${TERSE_LOG:=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-workflow-kit/logs/terse-gate.tsv}"

umask 077
input=$(cat 2>/dev/null) || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

PAYLOAD="$input" \
TERSE_TLDR_MODE="$TERSE_TLDR_MODE" TERSE_TIC_MODE="$TERSE_TIC_MODE" \
TERSE_TLDR_WORDS="$TERSE_TLDR_WORDS" TERSE_TLDR_LINES="$TERSE_TLDR_LINES" \
TERSE_TIC_THRESHOLD="$TERSE_TIC_THRESHOLD" TERSE_TIC_MIN_WORDS="$TERSE_TIC_MIN_WORDS" \
TERSE_MIN_WORDS="$TERSE_MIN_WORDS" TERSE_LOG="$TERSE_LOG" \
TERSE_STATE_DIR="$SESSION_WORKFLOW_STATE_DIR/terse" \
python3 -I - <<'PY'
import os, re, sys, json, time, pathlib

def env_int(name, default):
    try:
        return int(os.environ.get(name, "") or default)
    except Exception:
        return default

try:
    d = json.loads(os.environ.get("PAYLOAD", "") or "{}")
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)

msg = d.get("last_assistant_message") or ""
if not isinstance(msg, str) or not msg.strip():
    sys.exit(0)

sid = str(d.get("session_id") or "")
pid = str(d.get("prompt_id") or "noprompt")
safe = re.compile(r"^[A-Za-z0-9._-]+$")
if not safe.match(sid or "x") or not safe.match(pid):
    sys.exit(0)

state = pathlib.Path(os.environ.get("TERSE_STATE_DIR") or "")
try:
    state.mkdir(parents=True, exist_ok=True)
    os.chmod(state, 0o700)
except Exception:
    state = None

# --- Loop guard -----------------------------------------------------------------
# Documented: stop_hook_active is true when Claude is already continuing because of a
# stop hook. The per-turn marker is a second guard in case the field is absent.
already_blocked = bool(d.get("stop_hook_active"))
marker = None
if state is not None and sid:
    marker = state / ("blocked-%s-%s" % (sid, pid))
    already_blocked = already_blocked or marker.exists()

# --- Recover the user's prompt for this turn ------------------------------------
prompt = ""
if state is not None and sid:
    try:
        prompt = (state / ("prompt-%s-%s" % (sid, pid))).read_text(errors="replace")
    except Exception:
        prompt = ""

asked_tldr = bool(re.search(r"\btl[;:, ]?dr\b", prompt, re.I))

# --- Prose extraction -----------------------------------------------------------
# Fenced code and quoted lines are exempt: they are usually someone else's words (a file,
# a doc, a command) and must not count against the reply.
prose = re.sub(r"```.*?```", " ", msg, flags=re.S)
prose = re.sub(r"~~~.*?~~~", " ", prose, flags=re.S)
prose = "\n".join(l for l in prose.splitlines() if not l.lstrip().startswith(">"))

words = len(prose.split())
lines = len([l for l in prose.splitlines() if l.strip()])

# --- Filler phrase table --------------------------------------------------------
# (weight, label, regex). The phrases came from the author's own transcripts; the weights
# are judgment. Counted per occurrence, so repetition scores. Labels land in the log.
TICS = [
    # Weight 2: the "here is the honest/real X" preamble family.
    (2, "the honest answer",  r"\bthe honest answer\b"),
    (2, "the honest version", r"\bthe honest version\b"),
    (2, "the honest truth",   r"\bthe honest truth\b"),
    (2, "the real question",  r"\bthe real question\b"),
    (2, "the real answer",    r"\bthe real answer\b"),
    (2, "the real cost",      r"\bthe real cost\b"),
    (2, "the short version",  r"\bthe short version\b"),
    (2, "the catch is",       r"\bthe catch is\b"),
    (2, "one trap",           r"\bone trap\b"),
    (2, "one wrinkle",        r"\bone wrinkle\b"),
    (2, "here's the thing",   r"\bhere'?s the thing\b"),
    (2, "the key insight",    r"\bthe key insight\b"),
    # Weight 1: hedges and connectives. Individually fine, cumulatively the padding layer.
    (1, "load-bearing",       r"\bload[- ]bearing\b"),
    (1, "worth noting",       r"\bworth noting\b"),
    (1, "in practice",        r"\bin practice\b"),
    (1, "that said",          r"\bthat said\b"),
    (1, "the tradeoff",       r"\bthe trade-?off\b"),
    (1, "to be clear",        r"\bto be clear\b"),
    (1, "notably",            r"\bnotably\b"),
    (1, "it's worth X-ing",   r"\bit'?s worth (flagging|saying|calling out)\b"),
    (1, "the upshot",         r"\bthe upshot\b"),
    (1, "net-net",            r"\bnet[- ]net\b"),
    (1, "the bottom line",    r"\bthe bottom line\b"),
    # Weight 1: process narration. Deliberately narrow: meta sentences about how the work
    # was done. Reporting a fact ("the branch is pushed") must not match.
    (1, "what I did was",     r"\bwhat i did (was|here)\b"),
    (1, "my approach was",    r"\bmy approach (was|here)\b"),
    (1, "let me explain",     r"\blet me explain\b"),
    (1, "the reason I",       r"\bthe reason i\b"),
    (1, "I chose X over Y",   r"\bi (chose|picked|went with) \w+ (over|rather than)\b"),
    (1, "I verified it by",   r"\bi verified (this|that|it) by\b"),
    (1, "worth explaining",   r"\bworth explaining\b"),
    (1, "to be transparent",  r"\bto be transparent\b"),
]

score = 0
hits = []
if words >= env_int("TERSE_TIC_MIN_WORDS", 40):
    for weight, label, pat in TICS:
        n = len(re.findall(pat, prose, re.I))
        if n:
            score += weight * n
            hits.append("%s x%d" % (label, n))

# --- Verdict --------------------------------------------------------------------
tldr_mode = os.environ.get("TERSE_TLDR_MODE", "enforce")
tic_mode = os.environ.get("TERSE_TIC_MODE", "observe")
tldr_words = env_int("TERSE_TLDR_WORDS", 130)
tldr_lines = env_int("TERSE_TLDR_LINES", 10)
tic_thresh = env_int("TERSE_TIC_THRESHOLD", 3)

too_short = words < env_int("TERSE_MIN_WORDS", 25)

tldr_over = (tldr_mode != "off" and asked_tldr and not too_short
             and (words > tldr_words or lines > tldr_lines))
tic_over = (tic_mode != "off" and not too_short and score >= tic_thresh)

reason = None
if already_blocked:
    verdict = "retry-pass"
elif too_short:
    verdict = "skip-short"
elif tldr_over and tldr_mode == "enforce":
    verdict = "block-tldr"
    reason = (
        "TERSE-GATE BLOCK: tldr ceiling exceeded.\n"
        "The user asked for \"tldr\". The rule (CLAUDE.md, session-workflow block): hard ceiling "
        "%d lines / %d words, counted on prose only (code blocks and quotes are exempt).\n"
        "You wrote %d words across %d lines.\n"
        "Rewrite now. Output ONLY the replacement reply. No apology, no \"here's the shorter "
        "version\", no note about what you cut. Lead with the real-world thing that changed. "
        "End with what the user still has to do; write \"nothing needs you\" only when that "
        "list is empty. If it does not fit, give the single most important thing and stop."
        % (tldr_lines, tldr_words, words, lines)
    )
elif tic_over and tic_mode == "enforce":
    verdict = "block-tic"
    reason = (
        "TERSE-GATE BLOCK: filler-phrase score %d (threshold %d).\n"
        "Hits: %s\n"
        "Report what happened and what needs the user. Cut process narration, rationale for "
        "decisions the user did not question, and how you verified something.\n"
        "Rewrite now. Output ONLY the replacement reply, with those phrases and the padding "
        "around them gone. No apology, no meta-commentary."
        % (score, tic_thresh, "; ".join(hits) or "-")
    )
elif tldr_over or tic_over:
    verdict = "observe-would-block"
else:
    verdict = "pass"

# --- Log every turn -------------------------------------------------------------
try:
    log = pathlib.Path(os.environ["TERSE_LOG"]).expanduser()
    log.parent.mkdir(parents=True, exist_ok=True)
    new = not log.exists()
    with log.open("a", encoding="utf-8") as f:
        if new:
            f.write("ts\tsession\tprompt\ttldr\twords\tlines\ttic_score\tverdict\thits\n")
        f.write("%s\t%s\t%s\t%d\t%d\t%d\t%d\t%s\t%s\n" % (
            time.strftime("%Y-%m-%dT%H:%M:%S"),
            sid[:8], pid[:8], 1 if asked_tldr else 0,
            words, lines, score, verdict,
            "; ".join(hits).replace("\t", " ") or "-",
        ))
except Exception:
    pass

if reason is None:
    sys.exit(0)

# Arm the loop guard BEFORE blocking, so the rewrite is never re-blocked.
try:
    if marker is None:
        raise RuntimeError("no state dir")
    marker.write_text("1")
except Exception:
    # If the guard cannot be armed, do NOT block: an unguarded block risks a rewrite loop,
    # which is worse than one long reply.
    sys.exit(0)

# Visible note for the user alongside the model-facing stderr.
try:
    sys.stdout.write(json.dumps({
        "systemMessage": "terse-gate: rewrite requested (%s, %d words, %d lines, filler %d)"
                         % (verdict, words, lines, score)
    }))
except Exception:
    pass

sys.stderr.write(reason + "\n")
sys.exit(2)
PY
