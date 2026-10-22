#!/usr/bin/env bash
# tests/run.sh: the kit's test suite. Runs in a throwaway HOME; touches nothing real.
#
#   bash tests/run.sh
#
# What it covers:
#   1. bash -n on every script, py_compile on every Python file, Karabiner files match the generator
#   2. the compact-resume hooks on sample stdin (store -> precompact -> inject), ownership,
#      once-only consume, TTL, foreign-session isolation, source gating
#   3. the terse hooks on sample stdin (stash, block on tldr, pass on short, loop guard,
#      code-block exemption, non-tldr pass)
#   4. the installer against a fake ~/.claude: fresh install, repeat install (no changes),
#      pre-existing hooks + CLAUDE.md preserved, conflict warning, malformed settings abort,
#      verify, uninstall
# Exit 1 on the first failed assertion group; prints PASS/FAIL per case.
set -uo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'PASS %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '     %s\n' "$2"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1" "cond: $2"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/session-workflow-tests.XXXXXX")
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR
S="$T/state"   # hook state dir for the unit tests

echo "== 1. syntax"
for f in "$KIT"/hooks/*.sh "$KIT"/install/*.sh "$KIT"/tests/run.sh; do
  if bash -n "$f"; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done
for f in "$KIT"/install/*.py "$KIT"/karabiner/build.py; do
  if python3 -I -m py_compile "$f"; then ok "py_compile $(basename "$f")"; else bad "py_compile $(basename "$f")"; fi
done
if python3 -I "$KIT/karabiner/build.py" --check >/dev/null; then ok "karabiner json matches build.py"; else bad "karabiner json out of date (run python3 karabiner/build.py)"; fi
for f in "$KIT"/karabiner/*.json; do
  if python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$f"; then ok "valid json $(basename "$f")"; else bad "invalid json $(basename "$f")"; fi
done

echo "== 2. compact-resume hooks"
STORE="$KIT/hooks/compact-resume-store.sh"; PRE="$KIT/hooks/compact-resume-precompact.sh"; INJ="$KIT/hooks/compact-resume-inject.sh"
# empty input stores nothing
out=$(SESSION_WORKFLOW_STATE_DIR="$S" bash "$STORE" <<<"   ")
check "store: empty input prints nothing" '[[ -z "$out" ]]'
check "store: empty input creates no file" '[[ -z "$(ls "$S/compact-resume/pending" 2>/dev/null)" ]]'
# store a block
m1=$(SESSION_WORKFLOW_STATE_DIR="$S" bash "$STORE" <<<"Continuing from compacted session. BLOCK-ONE")
check "store: prints marker" '[[ "$m1" == compact-resume:stored:* ]]'
n1=${m1#compact-resume:stored:}
check "store: pending file exists" '[[ -f "$S/compact-resume/pending/$n1.md" ]]'
check "store: state dir is 700" '[[ "$(stat -f %Lp "$S" 2>/dev/null || stat -c %a "$S")" == "700" ]]'
# a second block from the same session (newer)
sleep 1
m2=$(SESSION_WORKFLOW_STATE_DIR="$S" bash "$STORE" <<<"Continuing from compacted session. BLOCK-TWO")
n2=${m2#compact-resume:stored:}
# a block from another session (never in our transcript)
m3=$(SESSION_WORKFLOW_STATE_DIR="$S" bash "$STORE" <<<"OTHER SESSION BLOCK")
n3=${m3#compact-resume:stored:}
tp="$T/transcript-a.jsonl"
printf '{"toolUseResult":"%s"}\n{"toolUseResult":"%s"}\n' "$m1" "$m2" > "$tp"
# precompact without jq input fields -> no-op
SESSION_WORKFLOW_STATE_DIR="$S" bash "$PRE" <<<'{}' ; check "precompact: empty payload is a no-op" '[[ ! -d "$S/compact-resume/committed" || -z "$(ls "$S/compact-resume/committed")" ]]'
SESSION_WORKFLOW_STATE_DIR="$S" bash "$PRE" <<<"{\"session_id\":\"sid-a\",\"transcript_path\":\"$tp\",\"trigger\":\"manual\"}"
check "precompact: committed newest owned block under session id" '[[ -f "$S/compact-resume/committed/sid-a.md" ]] && grep -q BLOCK-TWO "$S/compact-resume/committed/sid-a.md"'
check "precompact: older owned block deleted" '[[ ! -f "$S/compact-resume/pending/$n1.md" ]]'
check "precompact: newest owned block moved" '[[ ! -f "$S/compact-resume/pending/$n2.md" ]]'
check "precompact: foreign block left alone" '[[ -f "$S/compact-resume/pending/$n3.md" ]]'
# unsafe session id
SESSION_WORKFLOW_STATE_DIR="$S" bash "$PRE" <<<"{\"session_id\":\"../evil\",\"transcript_path\":\"$tp\"}"
check "precompact: unsafe session id ignored" '[[ ! -e "$S/compact-resume/evil.md" ]]'
# inject: wrong source
out=$(SESSION_WORKFLOW_STATE_DIR="$S" bash "$INJ" <<<'{"session_id":"sid-a","source":"startup"}')
check "inject: source=startup emits nothing" '[[ -z "$out" ]]'
check "inject: source=startup leaves the file" '[[ -f "$S/compact-resume/committed/sid-a.md" ]]'
# inject: other session
out=$(SESSION_WORKFLOW_STATE_DIR="$S" bash "$INJ" <<<'{"session_id":"sid-b","source":"compact"}')
check "inject: other session gets nothing" '[[ -z "$out" ]]'
# inject: right session
out=$(SESSION_WORKFLOW_STATE_DIR="$S" bash "$INJ" <<<'{"session_id":"sid-a","source":"compact"}')
check "inject: emits JSON with additionalContext" 'jq -e ".hookSpecificOutput.additionalContext" <<<"$out" >/dev/null'
check "inject: block text is inside" 'jq -r ".hookSpecificOutput.additionalContext" <<<"$out" | grep -q BLOCK-TWO'
check "inject: hookEventName is SessionStart" '[[ "$(jq -r .hookSpecificOutput.hookEventName <<<"$out")" == "SessionStart" ]]'
check "inject: no initialUserMessage field" '! jq -e ".hookSpecificOutput.initialUserMessage" <<<"$out" >/dev/null 2>&1'
out=$(SESSION_WORKFLOW_STATE_DIR="$S" bash "$INJ" <<<'{"session_id":"sid-a","source":"compact"}')
check "inject: second run emits nothing (consumed once)" '[[ -z "$out" ]]'
# TTL: stale committed file is dropped, not injected
mkdir -p "$S/compact-resume/committed"; printf 'STALE\n' > "$S/compact-resume/committed/sid-c.md"
touch -t 202001010000 "$S/compact-resume/committed/sid-c.md"
out=$(SESSION_WORKFLOW_STATE_DIR="$S" bash "$INJ" <<<'{"session_id":"sid-c","source":"compact"}')
check "inject: stale block not injected" '[[ -z "$out" && ! -f "$S/compact-resume/committed/sid-c.md" ]]'
# TTL: stale pending is pruned by store
printf 'OLD\n' > "$S/compact-resume/pending/deadbeef.md"; touch -t 202001010000 "$S/compact-resume/pending/deadbeef.md"
SESSION_WORKFLOW_STATE_DIR="$S" bash "$STORE" <<<"fresh" >/dev/null
check "store: prunes stale pending files" '[[ ! -f "$S/compact-resume/pending/deadbeef.md" ]]'
# no jq -> silent no-op (simulate by emptying PATH for jq)
out=$(PATH="$T/nopath" SESSION_WORKFLOW_STATE_DIR="$S" /bin/bash "$INJ" <<<'{"session_id":"sid-a","source":"compact"}' 2>&1)
check "inject: without jq exits 0 silently" '[[ -z "$out" ]]'

echo "== 3. terse hooks"
STASH="$KIT/hooks/terse-prompt-stash.sh"; GATE="$KIT/hooks/terse-gate.sh"; LOG="$T/terse.tsv"
SESSION_WORKFLOW_STATE_DIR="$S" bash "$STASH" <<<'{"session_id":"s1","prompt_id":"p1","prompt":"tldr what broke?"}'
check "stash: prompt file written" '[[ "$(cat "$S/terse/prompt-s1-p1")" == "tldr what broke?" ]]'
check "stash: prompt file is private" '[[ "$(stat -f %Lp "$S/terse/prompt-s1-p1" 2>/dev/null || stat -c %a "$S/terse/prompt-s1-p1")" == "600" ]]'
out=$(SESSION_WORKFLOW_STATE_DIR="$S" bash "$STASH" <<<'{"session_id":"s1","prompt_id":"p1","prompt":"x"}')
check "stash: emits nothing to context" '[[ -z "$out" ]]'
SESSION_WORKFLOW_STATE_DIR="$S" bash "$STASH" <<<'{"session_id":"s1","prompt_id":"p1","prompt":"tldr what broke?"}'
long=$(python3 -c 'print(" ".join(["word"]*200))')
short="Fixed it. The build is green and nothing needs you."
payload() { python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"prompt_id":sys.argv[2],"last_assistant_message":sys.argv[3],"stop_hook_active":sys.argv[4]=="1"}))' "$@"; }
SESSION_WORKFLOW_STATE_DIR="$S" TERSE_LOG="$LOG" bash "$GATE" <<<"$(payload s1 p1 "$long" 0)" >"$T/gate.out" 2>"$T/gate.err"; rc=$?
check "gate: 200-word tldr reply blocked with exit 2" '[[ $rc -eq 2 ]]'
check "gate: stderr carries the rewrite reason" 'grep -q "tldr ceiling exceeded" "$T/gate.err"'
check "gate: stdout carries a systemMessage" 'grep -q systemMessage "$T/gate.out"'
check "gate: reason names 10 lines / 130 words" 'grep -q "10 lines / 130 words" "$T/gate.err"'
SESSION_WORKFLOW_STATE_DIR="$S" TERSE_LOG="$LOG" bash "$GATE" <<<"$(payload s1 p1 "$long" 0)" >/dev/null 2>&1; rc=$?
check "gate: second pass on the same turn passes (marker loop guard)" '[[ $rc -eq 0 ]]'
SESSION_WORKFLOW_STATE_DIR="$S" bash "$STASH" <<<'{"session_id":"s1","prompt_id":"p2","prompt":"tldr again"}'
SESSION_WORKFLOW_STATE_DIR="$S" TERSE_LOG="$LOG" bash "$GATE" <<<"$(payload s1 p2 "$long" 1)" >/dev/null 2>&1; rc=$?
check "gate: stop_hook_active=true never blocks" '[[ $rc -eq 0 ]]'
SESSION_WORKFLOW_STATE_DIR="$S" bash "$STASH" <<<'{"session_id":"s1","prompt_id":"p3","prompt":"tldr please"}'
SESSION_WORKFLOW_STATE_DIR="$S" TERSE_LOG="$LOG" bash "$GATE" <<<"$(payload s1 p3 "$short" 0)" >/dev/null 2>&1; rc=$?
check "gate: short reply passes" '[[ $rc -eq 0 ]]'
codey=$(python3 -c 'print("Done. Output below.\n\n```\n" + " ".join(["word"]*300) + "\n```\n\nNothing needs you.")')
SESSION_WORKFLOW_STATE_DIR="$S" bash "$STASH" <<<'{"session_id":"s1","prompt_id":"p4","prompt":"tldr"}'
SESSION_WORKFLOW_STATE_DIR="$S" TERSE_LOG="$LOG" bash "$GATE" <<<"$(payload s1 p4 "$codey" 0)" >/dev/null 2>&1; rc=$?
check "gate: code block is exempt from the count" '[[ $rc -eq 0 ]]'
SESSION_WORKFLOW_STATE_DIR="$S" bash "$STASH" <<<'{"session_id":"s1","prompt_id":"p5","prompt":"explain in detail"}'
SESSION_WORKFLOW_STATE_DIR="$S" TERSE_LOG="$LOG" bash "$GATE" <<<"$(payload s1 p5 "$long" 0)" >/dev/null 2>&1; rc=$?
check "gate: long reply without tldr passes" '[[ $rc -eq 0 ]]'
check "gate: log has a header and rows" '[[ "$(head -1 "$LOG")" == ts* && $(wc -l <"$LOG") -ge 6 ]]'
out=$(TERSE_LOG="$LOG" bash "$KIT/hooks/terse-report.sh" 1)
check "report: runs and names the ceiling" 'grep -q "10 lines / 130 words" <<<"$out"'
out=$(SESSION_WORKFLOW_STATE_DIR="$S" TERSE_LOG="$LOG" bash "$GATE" <<<'not json' 2>&1); rc=$?
check "gate: garbage input exits 0 silently" '[[ $rc -eq 0 && -z "$out" ]]'

echo "== 4. installer against a fake home"
INST="$KIT/install/install.sh"; CFG="$HOME/.claude"
# 4a fresh install
mkdir -p "$CFG"
out=$(bash "$INST" plan 2>&1); rc=$?
check "plan: exits 0 on a fresh home" '[[ $rc -eq 0 ]]'
check "plan: writes nothing" '[[ ! -f "$CFG/settings.json" && ! -f "$CFG/CLAUDE.md" && ! -d "$CFG/hooks" ]]'
check "plan: lists creates" 'grep -q "create: ~/.claude/hooks/compact-resume-inject.sh" <<<"$out"'
out=$(bash "$INST" apply --yes 2>&1); rc=$?
check "apply: exits 0" '[[ $rc -eq 0 ]]'
check "apply: hooks copied and executable" '[[ -x "$CFG/hooks/compact-resume-inject.sh" && -x "$CFG/hooks/terse-gate.sh" ]]'
check "apply: commands and include copied" '[[ -f "$CFG/commands/compact-check.md" && -f "$CFG/includes/session-audit-core.md" ]]'
check "apply: settings.json created with both core registrations" 'jq -e ".hooks.SessionStart[] | select(.matcher==\"compact\") | .hooks[] | select(.command | test(\"compact-resume-inject.sh\"))" "$CFG/settings.json" >/dev/null && jq -e ".hooks.PreCompact[] | select(.matcher==\"manual\") | .hooks[] | select(.command | test(\"compact-resume-precompact.sh\"))" "$CFG/settings.json" >/dev/null'
check "apply: terse hooks NOT registered without --terse-gate" '! grep -q terse-gate "$CFG/settings.json"'
check "apply: hook command uses ~/.claude path" 'grep -q "bash ~/.claude/hooks/compact-resume-inject.sh" "$CFG/settings.json"'
check "apply: CLAUDE.md created with the marked block" 'grep -q "session-workflow-kit:begin" "$CFG/CLAUDE.md" && grep -q "session-workflow-kit:end" "$CFG/CLAUDE.md"'
check "apply: manifest written with a commit field" 'jq -e ".commit and .files and .config_dir" "$CFG/session-workflow-kit/manifest.json" >/dev/null'
check "apply: kit dir is private" '[[ "$(stat -f %Lp "$CFG/session-workflow-kit" 2>/dev/null || stat -c %a "$CFG/session-workflow-kit")" == "700" ]]'
# 4b repeat install: nothing changes
before=$(cat "$CFG/settings.json"; cat "$CFG/CLAUDE.md")
out=$(bash "$INST" plan 2>&1)
check "repeat plan: reports nothing to do" 'grep -q "nothing to do" <<<"$out"'
out=$(bash "$INST" apply --yes 2>&1)
after=$(cat "$CFG/settings.json"; cat "$CFG/CLAUDE.md")
check "repeat apply: settings.json and CLAUDE.md byte-identical" '[[ "$before" == "$after" ]]'
check "repeat apply: registrations not duplicated" '[[ "$(grep -c compact-resume-inject "$CFG/settings.json")" -eq 1 ]]'
# 4c verify
out=$(bash "$INST" verify 2>&1); rc=$?
check "verify: passes after install" '[[ $rc -eq 0 ]] && grep -q "^VERIFIED" <<<"$out"'
# 4d pre-existing hooks + CLAUDE.md with own rules, plus terse gate
rm -rf "$CFG"; mkdir -p "$CFG/hooks"
cat > "$CFG/settings.json" <<'JSON'
{
    "theme": "dark",
    "permissions": {"allow": ["Bash(npm test)"]},
    "hooks": {
        "SessionStart": [
            {"hooks": [{"type": "command", "command": "echo hello"}]},
            {"matcher": "compact", "hooks": [{"type": "command", "command": "echo after-compact"}]}
        ],
        "Stop": [
            {"hooks": [{"type": "command", "command": "afplay /System/Library/Sounds/Blow.aiff"}]}
        ],
        "PreToolUse": [
            {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/mine.sh"}]}
        ]
    }
}
JSON
printf '# My rules\n\nWhen I say tldr keep it to 3 lines.\n\n- Always run tests.\n' > "$CFG/CLAUDE.md"
out=$(bash "$INST" plan --terse-gate 2>&1)
check "plan: warns about an existing tldr rule" 'grep -q "WARNING: possible existing rule" <<<"$out"'
check "plan: shows a unified diff for settings.json" 'grep -q "^+.*compact-resume-inject.sh" <<<"$out"'
out=$(bash "$INST" apply --terse-gate --yes 2>&1); rc=$?
check "apply (existing): exits 0" '[[ $rc -eq 0 ]]'
check "existing: unrelated keys preserved" '[[ "$(jq -r .theme "$CFG/settings.json")" == "dark" ]] && jq -e ".permissions.allow[0]==\"Bash(npm test)\"" "$CFG/settings.json" >/dev/null'
check "existing: unrelated hooks preserved" 'jq -e ".hooks.PreToolUse[0].hooks[0].command==\"bash ~/.claude/hooks/mine.sh\"" "$CFG/settings.json" >/dev/null && jq -e ".hooks.Stop[0].hooks[0].command | test(\"afplay\")" "$CFG/settings.json" >/dev/null'
check "existing: inject appended to the existing compact group" '[[ "$(jq ".hooks.SessionStart | length" "$CFG/settings.json")" -eq 2 ]] && jq -e ".hooks.SessionStart[1].hooks | length == 2" "$CFG/settings.json" >/dev/null'
check "existing: PreCompact group created" 'jq -e ".hooks.PreCompact[0].matcher==\"manual\"" "$CFG/settings.json" >/dev/null'
check "existing: Stop gate appended to the matcher-less Stop group" 'jq -e ".hooks.Stop | length == 1" "$CFG/settings.json" >/dev/null && jq -e ".hooks.Stop[0].hooks[1].command | test(\"terse-gate.sh\")" "$CFG/settings.json" >/dev/null'
check "existing: UserPromptSubmit stash registered" 'jq -e ".hooks.UserPromptSubmit[0].hooks[0].command | test(\"terse-prompt-stash.sh\")" "$CFG/settings.json" >/dev/null'
check "existing: 4-space indent preserved" 'grep -q "^    \"theme\"" "$CFG/settings.json"'
check "existing: CLAUDE.md own rules kept, block appended" 'grep -q "Always run tests" "$CFG/CLAUDE.md" && grep -q "keep it to 3 lines" "$CFG/CLAUDE.md" && grep -q "session-workflow-kit:begin" "$CFG/CLAUDE.md"'
check "existing: backups taken with a timestamp" '[[ -n "$(ls -d "$CFG"/session-workflow-kit/backups/*/ 2>/dev/null)" ]] && [[ -f "$(ls -d "$CFG"/session-workflow-kit/backups/*/ | tail -1)settings.json" ]]'
out=$(bash "$INST" verify --terse-gate 2>&1); rc=$?
check "verify (existing, terse): passes" '[[ $rc -eq 0 ]]'
# 4e upgrade: block edited in place, not duplicated
printf '\n- Another rule after the block.\n' >> "$CFG/CLAUDE.md"
sed -i.bak 's/10 lines or 130 words/9 lines or 99 words/' "$CFG/CLAUDE.md" && rm -f "$CFG/CLAUDE.md.bak"
out=$(bash "$INST" plan 2>&1)
check "upgrade plan: replaces the block" 'grep -q "replace block" <<<"$out"'
bash "$INST" apply --yes >/dev/null 2>&1
check "upgrade: one block, current text, trailing rule kept" '[[ "$(grep -c session-workflow-kit:begin "$CFG/CLAUDE.md")" -eq 1 ]] && grep -q "10 lines or 130 words" "$CFG/CLAUDE.md" && grep -q "Another rule after the block" "$CFG/CLAUDE.md"'
# 4f malformed settings: abort, nothing written
rm -rf "$CFG"; mkdir -p "$CFG"
printf '{ "hooks": { "Stop": [ ' > "$CFG/settings.json"
out=$(bash "$INST" plan 2>&1); rc=$?
check "malformed: plan aborts non-zero" '[[ $rc -ne 0 ]] && grep -q "not valid JSON" <<<"$out"'
out=$(bash "$INST" apply --yes 2>&1); rc=$?
check "malformed: apply aborts before writing anything" '[[ $rc -ne 0 && ! -d "$CFG/hooks" && ! -f "$CFG/CLAUDE.md" ]]'
printf '{ "hooks": { "Stop": "oops" } }\n' > "$CFG/settings.json"
out=$(bash "$INST" apply --yes 2>&1); rc=$?
check "malformed: event that is not a list aborts" '[[ $rc -ne 0 ]] && grep -q "is not a list" <<<"$out"'
check "malformed: settings untouched" '[[ "$(cat "$CFG/settings.json")" == "{ \"hooks\": { \"Stop\": \"oops\" } }" ]]'
# 4g no TTY and no --yes: nothing written
rm -rf "$CFG"; mkdir -p "$CFG"
out=$(bash "$INST" apply 2>&1 </dev/null)
check "apply without --yes and without a terminal writes nothing" '[[ ! -d "$CFG/hooks" && ! -f "$CFG/settings.json" ]] && grep -q "skipping" <<<"$out"'
# 4h custom config dir rewrites the include path
CUSTOM="$T/custom-cfg"; mkdir -p "$CUSTOM"
out=$(bash "$INST" apply --yes --config-dir "$CUSTOM" 2>&1)
check "custom config dir: commands point at it" 'grep -q "$CUSTOM/includes/session-audit-core.md" "$CUSTOM/commands/compact-check.md" && ! grep -q "~/.claude/includes" "$CUSTOM/commands/compact-check.md"'
check "custom config dir: hook command uses the absolute path" 'grep -q "bash $CUSTOM/hooks/compact-resume-inject.sh" "$CUSTOM/settings.json"'
# 4i uninstall
bash "$INST" apply --yes --terse-gate >/dev/null 2>&1
printf '\n# keep me\n' >> "$CFG/CLAUDE.md"
out=$(bash "$INST" uninstall --yes 2>&1); rc=$?
check "uninstall: exits 0" '[[ $rc -eq 0 ]]'
check "uninstall: kit files gone" '[[ ! -f "$CFG/hooks/compact-resume-inject.sh" && ! -f "$CFG/commands/compact-check.md" ]]'
check "uninstall: registrations gone" '! grep -q "compact-resume\|terse-" "$CFG/settings.json"'
check "uninstall: CLAUDE.md block gone, other text kept" '! grep -q session-workflow-kit "$CFG/CLAUDE.md" && grep -q "keep me" "$CFG/CLAUDE.md"'
check "uninstall: backups kept" '[[ -d "$CFG/session-workflow-kit/backups" ]]'

echo
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
