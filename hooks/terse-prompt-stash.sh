#!/usr/bin/env bash
# terse-prompt-stash.sh: UserPromptSubmit hook. Stash this turn's prompt so the Stop hook
# can see it.
#
# Injects NOTHING into the model's context. Its only job is to write the submitted prompt
# text to a per-turn state file keyed by session_id + prompt_id, which terse-gate.sh (Stop)
# reads to decide whether "tldr" was asked for. The Stop hook's own payload does not carry
# the user's prompt, and the hooks reference says transcript_path "may lag the in-memory
# conversation", so the prompt is captured here or not at all.
#
# State lives under the kit's private state dir (mode 700), never in a shared /tmp.
# Retention is bounded: files older than one day are deleted on every run.
#
# Fail-silent: any error exits 0 with no output and never blocks a prompt.
# Part of claude-code-session-workflow (pairs with hooks/terse-gate.sh).
set -uo pipefail

: "${SESSION_WORKFLOW_STATE_DIR:=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-workflow-kit/state}"
: "${TERSE_PROMPT_RETENTION_MINUTES:=1440}"

umask 077
dir="$SESSION_WORKFLOW_STATE_DIR/terse"
mkdir -p "$dir" 2>/dev/null || exit 0
chmod 700 "$SESSION_WORKFLOW_STATE_DIR" "$dir" 2>/dev/null || true

input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

sid=$(jq -r '.session_id // ""' <<<"$input" 2>/dev/null) || exit 0
pid=$(jq -r '.prompt_id // ""' <<<"$input" 2>/dev/null) || pid=""
# `prompt` is the documented UserPromptSubmit field ("the submitted text").
txt=$(jq -r '.prompt // ""' <<<"$input" 2>/dev/null) || txt=""

[[ -n "$sid" ]] || exit 0
[[ -n "$pid" ]] || pid="noprompt"
case "$sid$pid" in *[!A-Za-z0-9._-]*) exit 0;; esac

tmp="$dir/.prompt-${sid}-${pid}.tmp"
printf '%s' "$txt" > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/prompt-${sid}-${pid}" 2>/dev/null
rm -f "$tmp" 2>/dev/null || true

# Bounded retention: drop state files older than the retention window.
find "$dir" -type f -mmin +"$TERSE_PROMPT_RETENTION_MINUTES" -delete 2>/dev/null || true

exit 0
