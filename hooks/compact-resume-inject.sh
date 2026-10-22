#!/usr/bin/env bash
# compact-resume-inject.sh: SessionStart hook (matcher: compact).
#
# After a compaction, inject the resume block that /compact-check stored for THIS session,
# so nobody has to copy it before /compact and paste it after.
#
# Reads the hook JSON on stdin: { session_id, source, ... }. If
#   <state>/compact-resume/committed/<session_id>.md
# exists and is fresh, the block is consumed (claimed atomically, then deleted) and emitted
# as hookSpecificOutput.additionalContext. Consume-before-emit means it fires exactly once;
# a second run finds nothing. The common case, an auto-compact or any compaction where
# /compact-check never ran, has no committed file and produces no output at all.
#
# Why additionalContext and not initialUserMessage: the hooks reference documents
# initialUserMessage as the first user message "in non-interactive mode with the -p flag".
# In an interactive session after /compact it is accepted and ignored (observed by the
# author on 2026-08-04). additionalContext is delivered on source=compact. It lands as
# context, not as a turn, which is why the block is worded as a directive and why the
# /compact shortcut in karabiner/ types a follow-up message to start the turn.
#
# Fail-silent: any missing field, stale or absent file exits 0 with no output.
# Part of claude-code-session-workflow (hooks/compact-resume-*.sh).
set -uo pipefail

: "${SESSION_WORKFLOW_STATE_DIR:=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-workflow-kit/state}"
: "${COMPACT_RESUME_TTL_SECONDS:=1800}"

umask 077
state="$SESSION_WORKFLOW_STATE_DIR/compact-resume"
committed_dir="$state/committed"

_swlog() { [[ -n "${SESSION_WORKFLOW_DEBUG:-}" ]] || return 0
  printf '%s [inject] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$state/debug.log" 2>/dev/null || true; }

input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || { _swlog "abort: no jq"; exit 0; }
sid=$(jq -r '.session_id // ""' <<<"$input" 2>/dev/null) || exit 0
src=$(jq -r '.source // ""' <<<"$input" 2>/dev/null) || exit 0

# The `compact` matcher already gates this; the guard keeps the script correct on its own.
[[ "$src" == "compact" ]] || { _swlog "abort: source=$src"; exit 0; }
[[ -n "$sid" ]] || { _swlog "abort: empty session_id"; exit 0; }
case "$sid" in *[!A-Za-z0-9._-]*) exit 0;; esac

f="$committed_dir/$sid.md"
[[ -f "$f" ]] || { _swlog "abort: no committed file for this session"; exit 0; }

ttl_min=$(( COMPACT_RESUME_TTL_SECONDS / 60 ))
[[ "$ttl_min" -lt 1 ]] && ttl_min=1
if [[ -n "$(find "$f" -maxdepth 0 -mmin +"$ttl_min" 2>/dev/null)" ]]; then
  rm -f "$f" 2>/dev/null || true
  _swlog "dropped stale block"
  exit 0
fi

# Claim atomically: rename to a private name first. If two hook runs race, only one
# rename succeeds and the other finds nothing, so a block can never be injected twice.
claim="$f.$$.claimed"
mv -f "$f" "$claim" 2>/dev/null || exit 0
block=$(cat "$claim" 2>/dev/null) || block=""
rm -f "$claim" 2>/dev/null || true
[[ -z "${block//[[:space:]]/}" ]] && exit 0

_swlog "emitting ${#block} chars"

ctx="Compact-resume (auto-injected by the session-workflow kit's compact-resume-inject.sh hook).
This is THIS session's own resume block, written by /compact-check before the compaction you
just went through. Treat it as the user's resume instruction: continue from it directly,
without asking what to do next and without reading it back to the user.

$block"

note="Auto-resumed from /compact-check (this session's pre-compact resume block)."
jq -n --arg c "$ctx" --arg n "$note" '{
  systemMessage: $n,
  hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: $c }
}'
exit 0
