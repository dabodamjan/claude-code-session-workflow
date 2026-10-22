#!/usr/bin/env bash
# install.sh: guided installer for claude-code-session-workflow.
#
# Usage:
#   install/install.sh check                      # requirements and what is already there
#   install/install.sh plan   [options]           # show every change as a diff, write nothing
#   install/install.sh apply  [options] [--yes]   # write, with backup + approval per change
#   install/install.sh verify [options]           # files, registrations, a dry hook run
#   install/install.sh uninstall [--yes]          # undo what the manifest says the kit did
#
# Options:
#   --terse-gate        also register the Stop/UserPromptSubmit enforcer hooks
#   --karabiner         also copy the Karabiner rule file (macOS, Karabiner-Elements installed)
#   --config-dir DIR    Claude Code config dir (default: $CLAUDE_CONFIG_DIR, else ~/.claude)
#   --yes               apply/uninstall without per-change prompts (what an agent passes after
#                       the user approved the plan)
#
# Every write is: backup (timestamped dir, never overwritten) -> temp file -> rename. A backup
# that fails stops the run before the file is touched. Running plan or apply twice adds
# nothing the second time. The manifest records what was actually created, replaced or
# added, and uninstall undoes exactly that: replaced files come back from their backup.
# Part of claude-code-session-workflow. Requires bash 3.2+, python3 (3.8+), jq.
set -uo pipefail

KIT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
MODE="${1:-}"
[[ -n "$MODE" ]] && shift

usage() { sed -n '2,22p' "$0"; }

YES=0; TERSE=0; KARABINER=0; CFG_FLAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1 ;;
    --terse-gate) TERSE=1 ;;
    --karabiner) KARABINER=1 ;;
    --config-dir) shift; CFG_FLAG="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

CFG="${CFG_FLAG:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
CFG="${CFG%/}"
case "$CFG" in /*) ;; *) CFG="$PWD/$CFG" ;; esac   # a relative dir is relative to where you ran this
if [[ "$CFG" == "$HOME/.claude" ]]; then
  CFG_DISPLAY='~/.claude'
else
  CFG_DISPLAY="$CFG"
fi
HOOKS_DIR_DISPLAY="$CFG_DISPLAY/hooks"
KIT_DIR="$CFG/session-workflow-kit"
MANIFEST="$KIT_DIR/manifest.json"
STAMP="$(date '+%Y%m%d-%H%M%S')-$$"
BACKUP_DIR="$KIT_DIR/backups/$STAMP"
KARABINER_DST="$HOME/.config/karabiner/assets/complex_modifications/session-workflow.json"
MERGE="$KIT_ROOT/install/merge-settings.py"
CLAUDEMD="$KIT_ROOT/install/update-claude-md.py"
MANIFEST_PY="$KIT_ROOT/install/manifest.py"
BLOCK="$KIT_ROOT/claude-md/tldr-block.md"

# Files the kit installs: "<repo path>|<config-dir relative path>"
FILES="commands/compact-check.md|commands/compact-check.md
commands/end-session.md|commands/end-session.md
commands/archive-session.md|commands/archive-session.md
commands/session-status.md|commands/session-status.md
includes/session-audit-core.md|includes/session-audit-core.md
hooks/compact-resume-store.sh|hooks/compact-resume-store.sh
hooks/compact-resume-precompact.sh|hooks/compact-resume-precompact.sh
hooks/compact-resume-inject.sh|hooks/compact-resume-inject.sh
hooks/terse-prompt-stash.sh|hooks/terse-prompt-stash.sh
hooks/terse-gate.sh|hooks/terse-gate.sh
hooks/terse-report.sh|hooks/terse-report.sh"

STAGE=""
cleanup() { [[ -n "$STAGE" && -d "$STAGE" ]] && rm -rf "$STAGE"; }
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
hr() { printf -- '---- %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- staging
stage_files() {
  STAGE=$(mktemp -d "${TMPDIR:-/tmp}/session-workflow-stage.XXXXXX") || { say "cannot create temp dir"; exit 5; }
  while IFS='|' read -r -u 3 src rel; do
    [[ -n "$src" ]] || continue
    mkdir -p "$STAGE/$(dirname "$rel")" || { say "ABORT: cannot stage $rel"; exit 5; }
    if [[ "$CFG_DISPLAY" != '~/.claude' ]] && [[ "$rel" == *.md ]]; then
      # Custom config dir: the commands reference ~/.claude/...; point them at the real dir.
      # A literal replacement in Python, so a path with $, &, # or quotes stays intact.
      python3 -I -c 'import sys
src, dst, old, new = sys.argv[1:5]
with open(src, encoding="utf-8") as f: t = f.read()
with open(dst, "w", encoding="utf-8") as f: f.write(t.replace(old, new))' \
        "$KIT_ROOT/$src" "$STAGE/$rel" '~/.claude/' "$CFG/" || { say "ABORT: cannot stage $rel for $CFG"; exit 5; }
    else
      cp "$KIT_ROOT/$src" "$STAGE/$rel" || { say "ABORT: cannot stage $rel"; exit 5; }
    fi
  done 3<<< "$FILES"
}
# The file loops read the FILES list on fd 3 so that stdin stays the terminal for approve().

# ---------------------------------------------------------------- check
do_check() {
  hr "requirements"
  say "os:        $(uname -s) $(uname -r)"
  say "bash:      ${BASH_VERSION}"
  if need python3; then say "python3:   $(python3 --version 2>&1)"; else say "python3:   MISSING (required: installer, terse-gate.sh)"; fi
  if need jq; then say "jq:        $(jq --version 2>&1)"; else say "jq:        MISSING (required: the hooks read their JSON input with jq)"; fi
  if need git; then say "git:       $(git --version 2>&1)"; else say "git:       missing (the audit commands need it)"; fi
  if need gh; then say "gh:        $(gh --version 2>&1 | head -1)"; else say "gh:        missing (optional: PR checks report 'unknown' without it)"; fi
  hr "claude code"
  say "config dir: $CFG $( [[ -d "$CFG" ]] && echo '(exists)' || echo '(missing: has Claude Code run on this machine?)' )"
  [[ -n "${CLAUDE_CONFIG_DIR:-}" ]] && say "CLAUDE_CONFIG_DIR is set; the kit installs there"
  if [[ -f "$CFG/settings.json" ]]; then
    if need python3 && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CFG/settings.json" 2>/dev/null; then
      say "settings.json: present, valid JSON"
    else
      say "settings.json: present but NOT valid JSON. The installer will refuse to touch it; fix it first."
    fi
  else
    say "settings.json: absent (will be created)"
  fi
  if [[ -f "$CFG/CLAUDE.md" ]]; then say "CLAUDE.md: present"; else say "CLAUDE.md: absent (will be created)"; fi
  if [[ -f "$MANIFEST" ]]; then say "kit manifest: present (a previous install; plan/apply upgrade in place)"; else say "kit manifest: none (fresh install)"; fi
  hr "surfaces"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    [[ -d "/Applications/Claude.app" ]] && say "Claude desktop app: found (/archive-session works there)" || say "Claude desktop app: not found in /Applications (/archive-session needs it)"
    [[ -d "/Applications/Karabiner-Elements.app" ]] && say "Karabiner-Elements: found (chords available with --karabiner)" || say "Karabiner-Elements: not found (chords are optional; https://karabiner-elements.pqrs.org)"
  else
    say "not macOS: Karabiner chords unavailable; /archive-session needs the desktop app"
  fi
  if ! need python3 || ! need jq; then
    say; say "Install python3 and jq, then rerun."; return 1
  fi
  return 0
}

# ---------------------------------------------------------------- plan / apply
file_status() {  # $1 staged, $2 dst -> create | update | unchanged
  if [[ ! -e "$2" ]]; then echo create
  elif cmp -s "$1" "$2"; then echo unchanged
  else echo update; fi
}

approve() {  # $1 description -> 0 yes, 1 no
  [[ "$YES" -eq 1 ]] && return 0
  if [[ -t 0 ]]; then
    printf '%s [y/N] ' "$1"
    read -r ans
    [[ "$ans" == "y" || "$ans" == "Y" ]]
  else
    say "no terminal to ask on and --yes not given; skipping: $1"
    return 1
  fi
}

backup_file() {  # $1 dst, $2 relative label -> 0 backed up (or nothing to back up), 1 failed
  [[ -e "$1" ]] || return 0
  mkdir -p "$BACKUP_DIR/$(dirname "$2")" 2>/dev/null || { say "backup failed: cannot create $BACKUP_DIR/$(dirname "$2")"; return 1; }
  cp -p "$1" "$BACKUP_DIR/$2" 2>/dev/null || { say "backup failed: cannot copy $1 to $BACKUP_DIR/$2"; return 1; }
  return 0
}

atomic_copy() {  # $1 src, $2 dst
  mkdir -p "$(dirname "$2")" || return 1
  local tmp="$2.tmp.$$"
  cp "$1" "$tmp" && mv -f "$tmp" "$2"
}

# "add: Event[matcher] script.sh" lines from merge-settings.py -> "Event|matcher|script.sh"
added_registrations() { sed -n 's/^add: \([^[]*\)\[\([^]]*\)\] \(.*\)$/\1|\2|\3/p'; }

plan_or_apply() {  # $1 = plan | apply
  local mode="$1" changes=0 written=0 skipped=0
  MF_ARGS=()   # what this run actually did, for the manifest
  need python3 || { say "python3 is required"; exit 1; }
  if [[ -f "$CFG/settings.json" ]] && ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CFG/settings.json" 2>/dev/null; then
    say "ABORT: $CFG/settings.json is not valid JSON. Nothing was written. Fix the file, then rerun."
    exit 4
  fi
  # Validate the structured targets BEFORE copying anything, so a malformed settings.json
  # or a broken marker pair in CLAUDE.md aborts with nothing written at all.
  local terse_flag=""; [[ "$TERSE" -eq 1 ]] && terse_flag="--terse"
  local settings_out claude_out
  settings_out=$(python3 -I "$MERGE" plan --settings "$CFG/settings.json" \
        --hooks-dir "$HOOKS_DIR_DISPLAY" $terse_flag 2>&1) || { say "ABORT: $settings_out"; say "Nothing was written."; exit 4; }
  claude_out=$(python3 -I "$CLAUDEMD" plan --file "$CFG/CLAUDE.md" --block "$BLOCK" 2>&1) \
        || { say "ABORT: $claude_out"; say "Nothing was written."; exit 4; }

  stage_files
  hr "files -> $CFG_DISPLAY"
  while IFS='|' read -r -u 3 src rel; do
    [[ -n "$src" ]] || continue
    local dst="$CFG/$rel" st
    st=$(file_status "$STAGE/$rel" "$dst")
    if [[ "$st" == "unchanged" && "$rel" == hooks/*.sh && ! -x "$dst" ]]; then st="chmod 755"; fi
    say "$st: $CFG_DISPLAY/$rel"
    if [[ "$st" == "update" ]]; then
      diff -u "$dst" "$STAGE/$rel" | sed '1,2d' | head -200
    fi
    [[ "$st" != "unchanged" ]] || continue
    changes=$((changes+1))
    [[ "$mode" == "apply" ]] || continue
    if [[ "$st" == "chmod 755" ]]; then
      if approve "make $CFG_DISPLAY/$rel executable (chmod 755)?"; then
        chmod 755 "$dst" || { say "chmod failed: $dst"; exit 5; }
        written=$((written+1))
      else skipped=$((skipped+1)); fi
      continue
    fi
    if approve "write $CFG_DISPLAY/$rel?"; then
      backup_file "$dst" "$rel" || { say "ABORT: $dst left untouched. Nothing further was written."; exit 5; }
      atomic_copy "$STAGE/$rel" "$dst" || { say "write failed: $dst"; exit 5; }
      if [[ "$rel" == hooks/*.sh ]]; then chmod 755 "$dst" || { say "chmod failed: $dst"; exit 5; }; fi
      if [[ "$st" == "create" ]]; then MF_ARGS+=(--file "$rel|created")
      else MF_ARGS+=(--file "$rel|replaced|$BACKUP_DIR/$rel"); fi
      written=$((written+1))
    else
      skipped=$((skipped+1))
    fi
  done 3<<< "$FILES"

  hr "settings.json hook registrations ($CFG_DISPLAY/settings.json)"
  say "$settings_out"
  if ! grep -q '^no changes' <<<"$settings_out"; then
    changes=$((changes+1))
    if [[ "$mode" == "apply" ]]; then
      if approve "write $CFG_DISPLAY/settings.json?"; then
        mkdir -p "$BACKUP_DIR" || { say "ABORT: cannot create $BACKUP_DIR; settings.json left untouched."; exit 5; }
        local apply_out
        apply_out=$(python3 -I "$MERGE" apply --settings "$CFG/settings.json" \
          --hooks-dir "$HOOKS_DIR_DISPLAY" $terse_flag --backup "$BACKUP_DIR/settings.json" 2>&1) \
          || { say "$apply_out"; say "ABORT: settings.json was not written."; exit 5; }
        local reg
        while IFS= read -r reg; do
          [[ -n "$reg" ]] && MF_ARGS+=(--registration "$reg")
        done <<<"$(added_registrations <<<"$apply_out")"
        written=$((written+1))
      else skipped=$((skipped+1)); fi
    fi
  fi

  hr "CLAUDE.md tldr block ($CFG_DISPLAY/CLAUDE.md)"
  say "$claude_out"
  if ! grep -q '^no changes' <<<"$claude_out"; then
    changes=$((changes+1))
    if [[ "$mode" == "apply" ]]; then
      if approve "write $CFG_DISPLAY/CLAUDE.md?"; then
        mkdir -p "$BACKUP_DIR" || { say "ABORT: cannot create $BACKUP_DIR; CLAUDE.md left untouched."; exit 5; }
        local md_out md_action=""
        md_out=$(python3 -I "$CLAUDEMD" apply --file "$CFG/CLAUDE.md" --block "$BLOCK" --backup "$BACKUP_DIR/CLAUDE.md" 2>&1) \
          || { say "$md_out"; say "ABORT: CLAUDE.md was not written."; exit 5; }
        if grep -q '^create:' <<<"$md_out"; then md_action=created
        elif grep -q '^append block:' <<<"$md_out"; then md_action=appended
        elif grep -q '^replace block:' <<<"$md_out"; then md_action=replaced; fi
        [[ -n "$md_action" ]] && MF_ARGS+=(--claude-md "$md_action")
        written=$((written+1))
      else skipped=$((skipped+1)); fi
    fi
  fi

  if [[ "$KARABINER" -eq 1 ]]; then
    hr "karabiner rule file ($KARABINER_DST)"
    if [[ "$(uname -s)" != "Darwin" ]]; then
      say "skipped: not macOS"
    else
      local kst; kst=$(file_status "$KIT_ROOT/karabiner/session-workflow.json" "$KARABINER_DST")
      say "$kst: $KARABINER_DST"
      [[ "$kst" == "update" ]] && diff -u "$KARABINER_DST" "$KIT_ROOT/karabiner/session-workflow.json" | sed '1,2d' | head -100
      if [[ "$kst" != "unchanged" ]]; then
        changes=$((changes+1))
        if [[ "$mode" == "apply" ]]; then
          if approve "write $KARABINER_DST?"; then
            backup_file "$KARABINER_DST" "karabiner/session-workflow.json" || { say "ABORT: $KARABINER_DST left untouched."; exit 5; }
            atomic_copy "$KIT_ROOT/karabiner/session-workflow.json" "$KARABINER_DST" || { say "write failed: $KARABINER_DST"; exit 5; }
            if [[ "$kst" == "create" ]]; then MF_ARGS+=(--karabiner-file "$KARABINER_DST|created")
            else MF_ARGS+=(--karabiner-file "$KARABINER_DST|replaced|$BACKUP_DIR/karabiner/session-workflow.json"); fi
            written=$((written+1))
          else skipped=$((skipped+1)); fi
        fi
      fi
      say "note: a rule file in assets/ is inert until you enable it: Karabiner-Elements Settings > Complex Modifications > Add predefined rule > 'Claude Code session workflow' > Enable."
    fi
  fi

  hr "manifest ($MANIFEST)"
  local commit; commit=$(git -C "$KIT_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
  say "kit commit: $commit"
  if [[ "$mode" == "apply" ]] && [[ $written -gt 0 || -f "$MANIFEST" ]]; then
    mkdir -p "$KIT_DIR" || { say "cannot create $KIT_DIR"; exit 5; }
    chmod 700 "$KIT_DIR" 2>/dev/null || true
    if [[ ${#MF_ARGS[@]} -gt 0 ]]; then
      python3 -I "$MANIFEST_PY" update --manifest "$MANIFEST" --commit "$commit" --config-dir "$CFG" \
        --backup-dir "$BACKUP_DIR" "${MF_ARGS[@]}" || exit 5
    else
      python3 -I "$MANIFEST_PY" update --manifest "$MANIFEST" --commit "$commit" --config-dir "$CFG" \
        --backup-dir "$BACKUP_DIR" || exit 5
    fi
  elif [[ "$mode" == "apply" ]]; then
    say "manifest not written (nothing was installed in this run)"
  fi

  hr "summary"
  if [[ "$mode" == "plan" ]]; then
    if [[ $changes -eq 0 ]]; then say "nothing to do: everything is already installed and current"
    else say "$changes item(s) would change. Nothing was written. Review the diffs above, then: install/install.sh apply$( [[ $TERSE -eq 1 ]] && echo ' --terse-gate')$( [[ $KARABINER -eq 1 ]] && echo ' --karabiner') --yes"; fi
  else
    say "written: $written, skipped: $skipped"
    if [[ -d "$BACKUP_DIR" ]]; then
      say "backups of every replaced file: $BACKUP_DIR"
    fi
    say "undo: install/install.sh uninstall (removes what the manifest says the kit added, restores replaced files from their backups)"
    say "next: install/install.sh verify$( [[ $TERSE -eq 1 ]] && echo ' --terse-gate')"
    say "Claude Code reloads settings.json on change; restart the session if a hook does not fire."
  fi
}

# ---------------------------------------------------------------- verify
do_verify() {
  local fails=0
  need python3 || { say "FAIL python3 missing"; exit 1; }
  need jq || { say "FAIL jq missing (hooks need it)"; fails=$((fails+1)); }
  stage_files
  hr "files"
  while IFS='|' read -r -u 3 src rel; do
    [[ -n "$src" ]] || continue
    local dst="$CFG/$rel"
    if [[ ! -f "$dst" ]]; then say "FAIL missing: $dst"; fails=$((fails+1)); continue; fi
    if cmp -s "$STAGE/$rel" "$dst"; then say "ok   $CFG_DISPLAY/$rel (matches kit)"
    else say "ok   $CFG_DISPLAY/$rel (present, differs from this kit checkout: local edits or another version)"; fi
    if [[ "$rel" == hooks/*.sh && ! -x "$dst" ]]; then say "FAIL not executable: $dst"; fails=$((fails+1)); fi
  done 3<<< "$FILES"

  hr "settings.json registrations"
  local terse_flag=""; [[ "$TERSE" -eq 1 ]] && terse_flag="--terse"
  if python3 -I "$MERGE" check --settings "$CFG/settings.json" --hooks-dir "$HOOKS_DIR_DISPLAY" $terse_flag; then :; else fails=$((fails+1)); fi

  hr "CLAUDE.md block"
  if python3 -I "$CLAUDEMD" check --file "$CFG/CLAUDE.md" --block "$BLOCK"; then :; else fails=$((fails+1)); fi

  hr "manifest"
  if [[ -f "$MANIFEST" ]]; then
    say "ok   $MANIFEST (commit $(python3 -I "$MANIFEST_PY" get --manifest "$MANIFEST" --key commit 2>/dev/null), installed $(python3 -I "$MANIFEST_PY" get --manifest "$MANIFEST" --key installed_at 2>/dev/null))"
  else say "FAIL missing manifest: $MANIFEST"; fails=$((fails+1)); fi

  hr "dry hook run (temp state dir, nothing touches your real state)"
  local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/session-workflow-verify.XXXXXX")
  local marker transcript="$tmp/transcript.jsonl" out
  marker=$(SESSION_WORKFLOW_STATE_DIR="$tmp/state" bash "$CFG/hooks/compact-resume-store.sh" <<<"Continuing from compacted session. (verify)")
  if [[ "$marker" == compact-resume:stored:* ]]; then say "ok   store printed a marker"; else say "FAIL store printed no marker"; fails=$((fails+1)); fi
  printf '{"type":"tool_result","toolUseResult":"%s"}\n' "$marker" > "$transcript"
  SESSION_WORKFLOW_STATE_DIR="$tmp/state" bash "$CFG/hooks/compact-resume-precompact.sh" \
    <<<"{\"session_id\":\"verify-sid\",\"transcript_path\":\"$transcript\",\"trigger\":\"manual\",\"hook_event_name\":\"PreCompact\"}"
  if [[ -f "$tmp/state/compact-resume/committed/verify-sid.md" ]]; then say "ok   precompact committed the block for the owning session"; else say "FAIL precompact did not commit"; fails=$((fails+1)); fi
  out=$(SESSION_WORKFLOW_STATE_DIR="$tmp/state" bash "$CFG/hooks/compact-resume-inject.sh" \
    <<<'{"session_id":"verify-sid","source":"compact","hook_event_name":"SessionStart"}')
  if grep -q '"additionalContext"' <<<"$out" && grep -q '(verify)' <<<"$out"; then say "ok   inject emitted additionalContext"; else say "FAIL inject emitted nothing usable"; fails=$((fails+1)); fi
  out=$(SESSION_WORKFLOW_STATE_DIR="$tmp/state" bash "$CFG/hooks/compact-resume-inject.sh" \
    <<<'{"session_id":"verify-sid","source":"compact","hook_event_name":"SessionStart"}')
  if [[ -z "$out" ]]; then say "ok   second inject emitted nothing (consumed once)"; else say "FAIL block re-injected"; fails=$((fails+1)); fi
  if [[ "$TERSE" -eq 1 ]]; then
    SESSION_WORKFLOW_STATE_DIR="$tmp/state" bash "$CFG/hooks/terse-prompt-stash.sh" \
      <<<'{"session_id":"verify-sid","prompt_id":"p1","prompt":"tldr what happened"}'
    local long; long=$(printf 'word %.0s' $(seq 1 200))
    SESSION_WORKFLOW_STATE_DIR="$tmp/state" TERSE_LOG="$tmp/log.tsv" bash "$CFG/hooks/terse-gate.sh" \
      <<<"{\"session_id\":\"verify-sid\",\"prompt_id\":\"p1\",\"last_assistant_message\":\"$long\"}" >/dev/null 2>&1
    if [[ $? -eq 2 ]]; then say "ok   terse-gate blocked a 200-word tldr reply"; else say "FAIL terse-gate did not block"; fails=$((fails+1)); fi
  fi
  rm -rf "$tmp"

  hr "result"
  if [[ $fails -eq 0 ]]; then say "VERIFIED: $CFG_DISPLAY has the kit installed and the hooks work on sample input."; return 0
  else say "FAILED: $fails problem(s) above."; return 1; fi
}

# ---------------------------------------------------------------- uninstall
remove_or_restore() {  # $1 dst, $2 label (relative, for backups and messages), $3 action, $4 original backup
  local dst="$1" rel="$2" action="$3" orig="$4"
  if [[ "$action" == "replaced" && -n "$orig" && -f "$orig" ]]; then
    if approve "restore the original $rel from $orig (replacing the kit's copy)?"; then
      backup_file "$dst" "$rel" || { say "ABORT: $dst left as is."; exit 5; }
      cp -p "$orig" "$dst" || { say "ABORT: restore failed for $dst"; exit 5; }
      say "restored: $dst"; return 0
    fi
    return 1
  fi
  [[ "$action" == "replaced" ]] && say "note: the original of $rel was recorded but its backup is missing ($orig); deleting the kit's copy instead"
  if approve "delete $rel?"; then
    backup_file "$dst" "$rel" || { say "ABORT: $dst left as is."; exit 5; }
    rm -f "$dst" || { say "ABORT: cannot delete $dst"; exit 5; }
    say "deleted: $dst"; return 0
  fi
  return 1
}

do_uninstall() {
  need python3 || { say "python3 is required"; exit 1; }
  local have_manifest=0; [[ -f "$MANIFEST" ]] && have_manifest=1
  PRUNE_ARGS=()
  local removed=0 kept=0 line rel action orig dst

  hr "kit files in $CFG_DISPLAY"
  if [[ $have_manifest -eq 1 ]]; then
    while IFS='|' read -r -u 3 rel action orig; do
      [[ -n "$rel" ]] || continue
      dst="$CFG/$rel"
      if [[ ! -e "$dst" ]]; then PRUNE_ARGS+=(--file "$rel"); continue; fi
      if remove_or_restore "$dst" "$rel" "$action" "$orig"; then
        removed=$((removed+1)); PRUNE_ARGS+=(--file "$rel")
      else kept=$((kept+1)); fi
    done 3<<< "$(python3 -I "$MANIFEST_PY" get --manifest "$MANIFEST" --key files)"
  else
    say "no manifest at $MANIFEST: removing the kit's files by name; an original that the kit replaced cannot be restored this way"
    while IFS='|' read -r -u 3 _src rel; do
      [[ -n "$rel" ]] || continue
      dst="$CFG/$rel"
      [[ -f "$dst" ]] || continue
      if remove_or_restore "$dst" "$rel" "unknown" ""; then removed=$((removed+1)); else kept=$((kept+1)); fi
    done 3<<< "$FILES"
  fi
  say "files: $removed removed or restored, $kept kept"

  hr "settings.json"
  if [[ -f "$CFG/settings.json" ]]; then
    if [[ $have_manifest -eq 1 ]]; then
      local regs; regs=$(python3 -I "$MANIFEST_PY" get --manifest "$MANIFEST" --key registrations)
      if [[ -z "$regs" ]]; then
        say "the manifest records no hook registrations added by the kit; settings.json left alone"
      else
        local reg; only=()
        while IFS= read -r reg; do [[ -n "$reg" ]] && only+=(--only "$reg"); done <<<"$regs"
        say "registrations the kit added:"; sed 's/^/  /' <<<"$regs"
        if approve "remove these ${#only[@]} registration(s) from $CFG_DISPLAY/settings.json? (hooks the kit did not add stay)"; then
          mkdir -p "$BACKUP_DIR" || { say "ABORT: cannot create $BACKUP_DIR"; exit 5; }
          python3 -I "$MERGE" remove --settings "$CFG/settings.json" --hooks-dir "$HOOKS_DIR_DISPLAY" \
            --backup "$BACKUP_DIR/settings.json" "${only[@]}" || exit 5
          while IFS= read -r reg; do [[ -n "$reg" ]] && PRUNE_ARGS+=(--registration "$reg"); done <<<"$regs"
        fi
      fi
    else
      if approve "remove every hook registration that runs a kit script under $HOOKS_DIR_DISPLAY from $CFG_DISPLAY/settings.json?"; then
        mkdir -p "$BACKUP_DIR" || { say "ABORT: cannot create $BACKUP_DIR"; exit 5; }
        python3 -I "$MERGE" remove --settings "$CFG/settings.json" --hooks-dir "$HOOKS_DIR_DISPLAY" \
          --backup "$BACKUP_DIR/settings.json" || exit 5
      fi
    fi
  fi

  hr "CLAUDE.md"
  if [[ -f "$CFG/CLAUDE.md" ]]; then
    local md_prov="" del_flag=""
    [[ $have_manifest -eq 1 ]] && md_prov=$(python3 -I "$MANIFEST_PY" get --manifest "$MANIFEST" --key claude_md)
    [[ "$md_prov" == "created" ]] && del_flag="--delete-if-empty"
    if approve "remove the kit's block from $CFG_DISPLAY/CLAUDE.md?$( [[ -n "$del_flag" ]] && echo ' (the kit created the file; it is deleted if nothing else is in it)')"; then
      mkdir -p "$BACKUP_DIR" || { say "ABORT: cannot create $BACKUP_DIR"; exit 5; }
      python3 -I "$CLAUDEMD" remove --file "$CFG/CLAUDE.md" --backup "$BACKUP_DIR/CLAUDE.md" $del_flag || exit 5
      PRUNE_ARGS+=(--claude-md)
    fi
  fi

  hr "karabiner"
  local kline="" kpath="$KARABINER_DST" kaction="unknown" korig=""
  [[ $have_manifest -eq 1 ]] && kline=$(python3 -I "$MANIFEST_PY" get --manifest "$MANIFEST" --key karabiner_file)
  if [[ -n "$kline" ]]; then IFS='|' read -r kpath kaction korig <<<"$kline"; fi
  if [[ -f "$kpath" ]]; then
    say "disable the rule in Karabiner-Elements first if it is enabled"
    if remove_or_restore "$kpath" "karabiner/session-workflow.json" "$kaction" "$korig"; then
      [[ -n "$kline" ]] && PRUNE_ARGS+=(--karabiner-file)
    fi
  elif [[ -n "$kline" ]]; then
    PRUNE_ARGS+=(--karabiner-file)
  else
    say "no rule file at $kpath"
  fi

  hr "state and manifest"
  if [[ -d "$KIT_DIR/state" ]] && approve "delete kit state ($KIT_DIR/state)?"; then rm -rf "$KIT_DIR/state"; fi
  if [[ $have_manifest -eq 1 ]]; then
    if [[ ${#PRUNE_ARGS[@]} -gt 0 ]]; then
      python3 -I "$MANIFEST_PY" prune --manifest "$MANIFEST" "${PRUNE_ARGS[@]}" || exit 5
    else
      say "kept: $MANIFEST (nothing was removed)"
    fi
  fi
  say "kept: $KIT_DIR/backups and $KIT_DIR/logs (delete by hand if you want them gone)"
}

case "$MODE" in
  check) do_check ;;
  plan) plan_or_apply plan ;;
  apply) plan_or_apply apply ;;
  verify) do_verify ;;
  uninstall) do_uninstall ;;
  *) usage; exit 2 ;;
esac
