#!/usr/bin/env bash
# install.sh: guided installer for claude-code-session-workflow.
#
# Usage:
#   bash install/install.sh check                      # requirements and what is already there
#   bash install/install.sh plan   [options]           # show every change as a diff, write nothing
#   bash install/install.sh apply  [options] [--yes]   # write, with backup + approval per file
#   bash install/install.sh verify [options]           # files, registrations, a dry hook run
#   bash install/install.sh uninstall [--yes]          # remove what the kit added, keep backups
#
# Options:
#   --terse-gate        also register the Stop/UserPromptSubmit enforcer hooks
#   --karabiner         also copy the Karabiner rule file (macOS, Karabiner-Elements installed)
#   --config-dir DIR    Claude Code config dir (default: $CLAUDE_CONFIG_DIR, else ~/.claude)
#   --yes               apply/uninstall without per-file prompts (what an agent passes after
#                       the user approved the plan)
#
# Every write is: backup (timestamped dir, never overwritten) -> temp file -> rename.
# Running plan or apply twice adds nothing the second time.
# Part of claude-code-session-workflow. Requires bash 3.2+, python3 (3.8+), jq.
set -uo pipefail

KIT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
MODE="${1:-}"
[[ -n "$MODE" ]] && shift

YES=0; TERSE=0; KARABINER=0; CFG_FLAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1 ;;
    --terse-gate) TERSE=1 ;;
    --karabiner) KARABINER=1 ;;
    --config-dir) shift; CFG_FLAG="${1:-}" ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

CFG="${CFG_FLAG:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
CFG="${CFG%/}"
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
    mkdir -p "$STAGE/$(dirname "$rel")"
    if [[ "$CFG_DISPLAY" != '~/.claude' ]] && [[ "$rel" == *.md ]]; then
      # Custom config dir: the commands reference ~/.claude/...; point them at the real dir.
      sed "s#~/\\.claude/#$CFG/#g" "$KIT_ROOT/$src" > "$STAGE/$rel"
    else
      cp "$KIT_ROOT/$src" "$STAGE/$rel"
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

backup_file() {  # $1 dst, $2 relative label
  [[ -e "$1" ]] || return 0
  mkdir -p "$BACKUP_DIR/$(dirname "$2")"
  cp -p "$1" "$BACKUP_DIR/$2"
}

atomic_copy() {  # $1 src, $2 dst
  mkdir -p "$(dirname "$2")"
  local tmp="$2.tmp.$$"
  cp "$1" "$tmp" && mv -f "$tmp" "$2"
}

plan_or_apply() {  # $1 = plan | apply
  local mode="$1" changes=0 written=0 skipped=0
  need python3 || { say "python3 is required"; exit 1; }
  if [[ -f "$CFG/settings.json" ]] && ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CFG/settings.json" 2>/dev/null; then
    say "ABORT: $CFG/settings.json is not valid JSON. Nothing was written. Fix the file, then rerun."
    exit 4
  fi
  # Validate the structured targets BEFORE copying anything, so a malformed settings.json
  # or a broken marker pair in CLAUDE.md aborts with nothing written at all.
  local terse_flag=""; [[ "$TERSE" -eq 1 ]] && terse_flag="--terse"
  local settings_out claude_out
  settings_out=$(python3 -I "$KIT_ROOT/install/merge-settings.py" plan --settings "$CFG/settings.json" \
        --hooks-dir "$HOOKS_DIR_DISPLAY" $terse_flag 2>&1) || { say "ABORT: $settings_out"; say "Nothing was written."; exit 4; }
  claude_out=$(python3 -I "$KIT_ROOT/install/update-claude-md.py" plan --file "$CFG/CLAUDE.md" \
        --block "$KIT_ROOT/claude-md/tldr-block.md" 2>&1) || { say "ABORT: $claude_out"; say "Nothing was written."; exit 4; }

  stage_files
  hr "files -> $CFG_DISPLAY"
  while IFS='|' read -r -u 3 src rel; do
    [[ -n "$src" ]] || continue
    local dst="$CFG/$rel" st
    st=$(file_status "$STAGE/$rel" "$dst")
    say "$st: $CFG_DISPLAY/$rel"
    if [[ "$st" == "update" ]]; then
      diff -u "$dst" "$STAGE/$rel" | sed '1,2d' | head -200
    fi
    if [[ "$st" != "unchanged" ]]; then
      changes=$((changes+1))
      if [[ "$mode" == "apply" ]]; then
        if approve "write $CFG_DISPLAY/$rel?"; then
          backup_file "$dst" "$rel"
          atomic_copy "$STAGE/$rel" "$dst" || { say "write failed: $dst"; exit 5; }
          written=$((written+1))
        else
          skipped=$((skipped+1))
        fi
      fi
    fi
    if [[ "$mode" == "apply" && "$rel" == hooks/*.sh && -f "$dst" ]]; then chmod 755 "$dst"; fi
  done 3<<< "$FILES"

  hr "settings.json hook registrations ($CFG_DISPLAY/settings.json)"
  say "$settings_out"
  if ! grep -q '^no changes' <<<"$settings_out"; then
    changes=$((changes+1))
    if [[ "$mode" == "apply" ]]; then
      if approve "write $CFG_DISPLAY/settings.json?"; then
        mkdir -p "$BACKUP_DIR"
        python3 -I "$KIT_ROOT/install/merge-settings.py" apply --settings "$CFG/settings.json" \
          --hooks-dir "$HOOKS_DIR_DISPLAY" $terse_flag --backup "$BACKUP_DIR/settings.json" >/dev/null || exit 5
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
        mkdir -p "$BACKUP_DIR"
        python3 -I "$KIT_ROOT/install/update-claude-md.py" apply --file "$CFG/CLAUDE.md" \
          --block "$KIT_ROOT/claude-md/tldr-block.md" --backup "$BACKUP_DIR/CLAUDE.md" >/dev/null || exit 5
        written=$((written+1))
      else skipped=$((skipped+1)); fi
    fi
  fi

  if [[ "$KARABINER" -eq 1 ]]; then
    hr "karabiner rule file ($KARABINER_DST)"
    if [[ "$(uname -s)" != "Darwin" ]]; then
      say "skipped: not macOS"
    else
      local st; st=$(file_status "$KIT_ROOT/karabiner/session-workflow.json" "$KARABINER_DST")
      say "$st: $KARABINER_DST"
      [[ "$st" == "update" ]] && diff -u "$KARABINER_DST" "$KIT_ROOT/karabiner/session-workflow.json" | sed '1,2d' | head -100
      if [[ "$st" != "unchanged" ]]; then
        changes=$((changes+1))
        if [[ "$mode" == "apply" ]]; then
          if approve "write $KARABINER_DST?"; then
            backup_file "$KARABINER_DST" "karabiner/session-workflow.json"
            atomic_copy "$KIT_ROOT/karabiner/session-workflow.json" "$KARABINER_DST" || exit 5
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
  if [[ "$mode" == "apply" && $written -gt 0 ]]; then
    mkdir -p "$KIT_DIR"
    chmod 700 "$KIT_DIR" 2>/dev/null || true
    local files_json="" ; local first=1
    while IFS='|' read -r -u 3 src rel; do
      [[ -n "$src" ]] || continue
      if [[ $first -eq 1 ]]; then first=0; else files_json+=", "; fi
      files_json+="\"$rel\""
    done 3<<< "$FILES"
    local tmp="$MANIFEST.tmp.$$"
    printf '{\n  "kit": "claude-code-session-workflow",\n  "commit": "%s",\n  "installed_at": "%s",\n  "config_dir": "%s",\n  "components": {"terse_gate": %s, "karabiner": %s},\n  "files": [%s],\n  "backup_dir": "%s"\n}\n' \
      "$commit" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$CFG" \
      "$( [[ $TERSE -eq 1 ]] && echo true || echo false )" "$( [[ $KARABINER -eq 1 ]] && echo true || echo false )" \
      "$files_json" "$BACKUP_DIR" > "$tmp" && mv -f "$tmp" "$MANIFEST"
    say "written: $MANIFEST"
  elif [[ "$mode" == "apply" ]]; then
    say "manifest not written (nothing was installed in this run)"
  fi

  hr "summary"
  if [[ "$mode" == "plan" ]]; then
    if [[ $changes -eq 0 ]]; then say "nothing to do: everything is already installed and current"
    else say "$changes item(s) would change. Nothing was written. Review the diffs above, then: bash install/install.sh apply$( [[ $TERSE -eq 1 ]] && echo ' --terse-gate')$( [[ $KARABINER -eq 1 ]] && echo ' --karabiner') --yes"; fi
  else
    say "written: $written, skipped: $skipped"
    if [[ -d "$BACKUP_DIR" ]]; then
      say "backups of every replaced file: $BACKUP_DIR"
      say "rollback: copy a file back from that directory, or run: bash install/install.sh uninstall"
    fi
    say "next: bash install/install.sh verify$( [[ $TERSE -eq 1 ]] && echo ' --terse-gate')"
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
  if python3 -I "$KIT_ROOT/install/merge-settings.py" check --settings "$CFG/settings.json" $terse_flag; then :; else fails=$((fails+1)); fi

  hr "CLAUDE.md block"
  if python3 -I "$KIT_ROOT/install/update-claude-md.py" check --file "$CFG/CLAUDE.md" --block "$KIT_ROOT/claude-md/tldr-block.md"; then :; else fails=$((fails+1)); fi

  hr "manifest"
  if [[ -f "$MANIFEST" ]]; then say "ok   $MANIFEST ($(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("commit", d.get("commit"), "installed", d.get("installed_at"))' "$MANIFEST" 2>/dev/null))"
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
do_uninstall() {
  need python3 || { say "python3 is required"; exit 1; }
  local removed=0
  hr "remove kit files from $CFG_DISPLAY"
  while IFS='|' read -r -u 3 src rel; do
    [[ -n "$src" ]] || continue
    local dst="$CFG/$rel"
    [[ -f "$dst" ]] || continue
    if approve "delete $CFG_DISPLAY/$rel?"; then
      backup_file "$dst" "$rel"; rm -f "$dst"; removed=$((removed+1)); say "deleted: $dst"
    fi
  done 3<<< "$FILES"
  say "removed $removed file(s)"
  hr "settings.json"
  if [[ -f "$CFG/settings.json" ]]; then
    if approve "remove the kit's hook registrations from $CFG_DISPLAY/settings.json?"; then
      mkdir -p "$BACKUP_DIR"
      python3 -I "$KIT_ROOT/install/merge-settings.py" remove --settings "$CFG/settings.json" --backup "$BACKUP_DIR/settings.json" || exit 5
    fi
  fi
  hr "CLAUDE.md"
  if [[ -f "$CFG/CLAUDE.md" ]] && approve "remove the kit's block from $CFG_DISPLAY/CLAUDE.md?"; then
    mkdir -p "$BACKUP_DIR"
    python3 -I "$KIT_ROOT/install/update-claude-md.py" remove --file "$CFG/CLAUDE.md" --backup "$BACKUP_DIR/CLAUDE.md" || exit 5
  fi
  if [[ -f "$KARABINER_DST" ]] && approve "delete $KARABINER_DST? (disable the rule in Karabiner-Elements first)"; then
    backup_file "$KARABINER_DST" "karabiner/session-workflow.json"; rm -f "$KARABINER_DST"
  fi
  hr "state and manifest"
  if [[ -d "$KIT_DIR/state" ]] && approve "delete kit state ($KIT_DIR/state)?"; then rm -rf "$KIT_DIR/state"; fi
  [[ -f "$MANIFEST" ]] && rm -f "$MANIFEST" && say "deleted: $MANIFEST"
  say "kept: $KIT_DIR/backups and $KIT_DIR/logs (delete by hand if you want them gone)"
}

case "$MODE" in
  check) do_check ;;
  plan) plan_or_apply plan ;;
  apply) plan_or_apply apply ;;
  verify) do_verify ;;
  uninstall) do_uninstall ;;
  *) sed -n '2,22p' "$0"; exit 2 ;;
esac
