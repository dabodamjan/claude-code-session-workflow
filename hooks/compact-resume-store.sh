#!/usr/bin/env bash
# compact-resume-store.sh: persist the resume block that /compact-check printed, so the
# SessionStart (compact) hook can inject it after the next manual /compact.
#
# This is a command helper, NOT a registered hook. /compact-check pipes the exact block
# it just printed to this script on stdin. The script writes it to
#   <state>/compact-resume/pending/<nonce>.md
# and prints an ownership marker, compact-resume:stored:<nonce>, to stdout. That marker
# is Bash tool output, so it lands in the session transcript. compact-resume-precompact.sh
# later greps the transcript for the marker to prove the pending file belongs to THAT
# session, which is what keeps parallel sessions from picking up each other's block.
#
# Fail-silent: every error path exits 0 so a storage problem never breaks /compact-check.
#
# Part of claude-code-session-workflow (hooks/compact-resume-*.sh).
set -uo pipefail

: "${SESSION_WORKFLOW_STATE_DIR:=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-workflow-kit/state}"
: "${COMPACT_RESUME_TTL_SECONDS:=1800}"   # a pending block older than this is stale (30 min)

umask 077
state="$SESSION_WORKFLOW_STATE_DIR/compact-resume"
pending_dir="$state/pending"
mkdir -p "$pending_dir" 2>/dev/null || exit 0
chmod 700 "$SESSION_WORKFLOW_STATE_DIR" "$state" "$pending_dir" 2>/dev/null || true

# Debug trail, off unless SESSION_WORKFLOW_DEBUG is set. Append-only, fail-silent.
_swlog() { [[ -n "${SESSION_WORKFLOW_DEBUG:-}" ]] || return 0
  printf '%s [store] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$state/debug.log" 2>/dev/null || true; }

block=$(cat 2>/dev/null) || exit 0
# Nothing to store: silent no-op, never create empty files.
[[ -z "${block//[[:space:]]/}" ]] && exit 0

ttl_min=$(( COMPACT_RESUME_TTL_SECONDS / 60 ))
[[ "$ttl_min" -lt 1 ]] && ttl_min=1

# Prune stale pending files so an abandoned block never resurfaces days later.
find "$pending_dir" -maxdepth 1 -type f -name '*.md' -mmin +"$ttl_min" -delete 2>/dev/null || true

# Unguessable nonce = the ownership token. Hex only, so it is safe in a filename.
nonce=$(od -An -N12 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
[[ -z "$nonce" ]] && nonce="$$${RANDOM}${RANDOM}"

tmp="$pending_dir/.$nonce.tmp"
printf '%s\n' "$block" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; exit 0; }
mv -f "$tmp" "$pending_dir/$nonce.md" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; exit 0; }
_swlog "wrote pending/$nonce.md"

# The marker goes to stdout on purpose: it must end up in the transcript.
printf 'compact-resume:stored:%s\n' "$nonce"
exit 0
