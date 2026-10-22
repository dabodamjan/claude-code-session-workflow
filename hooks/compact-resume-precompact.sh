#!/usr/bin/env bash
# compact-resume-precompact.sh: PreCompact hook (matcher: manual).
#
# Right before a manual /compact, re-key the pending resume block from its nonce to the
# real session id. PreCompact fires BEFORE compaction, so this session's transcript still
# contains the marker (compact-resume:stored:<nonce>) that compact-resume-store.sh printed.
# After compaction the transcript holds a summary and that proof is gone. So ownership is
# settled here; injection happens later in compact-resume-inject.sh, keyed on session_id.
#
# Reads the hook JSON on stdin: { session_id, transcript_path, trigger, ... }.
# Finds the pending file(s) whose nonce appears in THIS session's transcript, keeps the
# newest, deletes any older ones it also owns, and moves the newest to
#   <state>/compact-resume/committed/<session_id>.md
# A pending file whose nonce is not in this transcript is left alone for its owner.
#
# Fail-silent: any missing field, unreadable path or no match exits 0 with no output.
# Part of claude-code-session-workflow (hooks/compact-resume-*.sh).
set -uo pipefail

: "${SESSION_WORKFLOW_STATE_DIR:=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-workflow-kit/state}"
: "${COMPACT_RESUME_TTL_SECONDS:=1800}"

umask 077
state="$SESSION_WORKFLOW_STATE_DIR/compact-resume"
pending_dir="$state/pending"
committed_dir="$state/committed"

_swlog() { [[ -n "${SESSION_WORKFLOW_DEBUG:-}" ]] || return 0
  printf '%s [precompact] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$state/debug.log" 2>/dev/null || true; }

input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || { _swlog "abort: no jq"; exit 0; }
sid=$(jq -r '.session_id // ""' <<<"$input" 2>/dev/null) || exit 0
tp=$(jq -r '.transcript_path // ""' <<<"$input" 2>/dev/null) || exit 0
[[ -n "$sid" && -f "$tp" ]] || { _swlog "abort: empty session_id or missing transcript"; exit 0; }
# session_id becomes a filename: refuse anything that is not a plain token.
case "$sid" in *[!A-Za-z0-9._-]*) _swlog "abort: unsafe session_id"; exit 0;; esac
[[ -d "$pending_dir" ]] || { _swlog "abort: no pending dir"; exit 0; }

mkdir -p "$committed_dir" 2>/dev/null || exit 0
chmod 700 "$committed_dir" 2>/dev/null || true

ttl_min=$(( COMPACT_RESUME_TTL_SECONDS / 60 ))
[[ "$ttl_min" -lt 1 ]] && ttl_min=1

best=""
for f in "$pending_dir"/*.md; do
  [[ -f "$f" ]] || continue
  # Stale: drop and skip, never resurface an abandoned block.
  if [[ -n "$(find "$f" -maxdepth 0 -mmin +"$ttl_min" 2>/dev/null)" ]]; then
    rm -f "$f" 2>/dev/null || true
    continue
  fi
  nonce=$(basename "$f" .md)
  case "$nonce" in *[!A-Za-z0-9-]*) continue;; esac
  # Ownership: did THIS session's transcript record the store marker for this nonce?
  grep -Fq "compact-resume:stored:$nonce" "$tp" 2>/dev/null || { _swlog "no match: $nonce"; continue; }
  if [[ -z "$best" || "$f" -nt "$best" ]]; then
    # Newer owned block wins; an older one this session stored must not resurface.
    [[ -n "$best" ]] && rm -f "$best" 2>/dev/null
    best="$f"
  else
    rm -f "$f" 2>/dev/null || true
  fi
done

[[ -n "$best" ]] || { _swlog "end: no owned pending file"; exit 0; }
mv -f "$best" "$committed_dir/$sid.md" 2>/dev/null || true
_swlog "committed $(basename "$best") -> committed/$sid.md"
exit 0
