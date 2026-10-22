#!/usr/bin/env bash
# tests/run.sh: the kit's test suite. Runs in a throwaway HOME; touches nothing real.
#
#   ./tests/run.sh
#   ./tests/run.sh --system-bash    # run every script under /bin/bash (bash 3.2 on macOS)
#
# What it covers:
#   1. bash -n on every script, py_compile on every Python file, Karabiner files match the generator
#   2. the compact-resume hooks on sample stdin (store -> precompact -> inject), ownership,
#      once-only consume, TTL, foreign-session isolation, source gating
#   3. the terse hooks on sample stdin (stash, block on tldr, pass on short, loop guard,
#      code-block exemption, non-tldr pass)
#   4. the installer against a fake ~/.claude: fresh install, repeat install (no changes),
#      pre-existing hooks + CLAUDE.md preserved, conflict warning, malformed settings abort,
#      check without python3, aborted run recorded in the manifest, verify (with and
#      without a manifest), uninstall
# Runs every case; exits 1 if any assertion failed. Prints PASS/FAIL per case.
set -uo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'PASS %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '     %s\n' "$2"
         # the last lines of the most recent captured output, as a diagnostic
         [[ -n "${out:-}" ]] && printf '%s\n' "$out" | tail -12 | sed 's/^/     | /'; return 0; }
check(){ if eval "$2"; then ok "$1"; else bad "$1" "cond: $2"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/session-workflow-tests.XXXXXX")
trap 'rm -rf "$T"' EXIT
if [[ "${1:-}" == "--system-bash" && -x /bin/bash ]]; then
  # Every `bash <script>` below resolves through PATH; put the system bash first so the
  # kit is exercised under the oldest bash it claims to support.
  mkdir -p "$T/bin" && ln -s /bin/bash "$T/bin/bash" && export PATH="$T/bin:$PATH"
  echo "running the scripts under $(bash -c 'echo "bash $BASH_VERSION"')"
fi
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
# copied transcript (a branched session): once the original has claimed its block, a fork
# with the same transcript finds nothing
cp "$tp" "$T/transcript-fork.jsonl"
SESSION_WORKFLOW_STATE_DIR="$S" bash "$PRE" <<<"{\"session_id\":\"sid-fork\",\"transcript_path\":\"$T/transcript-fork.jsonl\",\"trigger\":\"manual\"}"
check "precompact: a fork with a copied transcript gets nothing after the original claimed" '[[ ! -f "$S/compact-resume/committed/sid-fork.md" ]]'
# ...but a fork that compacts FIRST takes the block (documented limit: the transcript is the only proof of ownership)
m4=$(SESSION_WORKFLOW_STATE_DIR="$S" bash "$STORE" <<<"Continuing from compacted session. BLOCK-FOUR")
printf '{"toolUseResult":"%s"}\n' "$m4" > "$T/transcript-b.jsonl"; cp "$T/transcript-b.jsonl" "$T/transcript-b-fork.jsonl"
SESSION_WORKFLOW_STATE_DIR="$S" bash "$PRE" <<<"{\"session_id\":\"sid-bfork\",\"transcript_path\":\"$T/transcript-b-fork.jsonl\",\"trigger\":\"manual\"}"
SESSION_WORKFLOW_STATE_DIR="$S" bash "$PRE" <<<"{\"session_id\":\"sid-b\",\"transcript_path\":\"$T/transcript-b.jsonl\",\"trigger\":\"manual\"}"
check "precompact: whichever session compacts first takes the block, the other gets nothing" '[[ -f "$S/compact-resume/committed/sid-bfork.md" && ! -f "$S/compact-resume/committed/sid-b.md" ]]'
rm -f "$S/compact-resume/committed/sid-bfork.md"
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
# no jq -> silent no-op. A PATH with every other utility the hooks use, and no jq.
mkdir -p "$T/nojq"
for u in cat find rm mv grep basename mkdir chmod date od tr; do p=$(command -v "$u") && ln -s "$p" "$T/nojq/$u"; done
mkdir -p "$S/compact-resume/committed"; printf 'NOJQ\n' > "$S/compact-resume/committed/sid-nojq.md"
out=$(PATH="$T/nojq" SESSION_WORKFLOW_STATE_DIR="$S" /bin/bash "$INJ" <<<'{"session_id":"sid-nojq","source":"compact"}' 2>"$T/nojq.err"); rc=$?
check "inject: without jq exits 0 with no stdout and no stderr" '[[ $rc -eq 0 && -z "$out" && ! -s "$T/nojq.err" ]]'
check "inject: without jq leaves the committed file alone" '[[ -f "$S/compact-resume/committed/sid-nojq.md" ]]'
out=$(PATH="$T/nojq" SESSION_WORKFLOW_STATE_DIR="$S" /bin/bash "$PRE" <<<"{\"session_id\":\"sid-nojq\",\"transcript_path\":\"$tp\"}" 2>"$T/nojq.err"); rc=$?
check "precompact: without jq exits 0 with no stdout and no stderr" '[[ $rc -eq 0 && -z "$out" && ! -s "$T/nojq.err" ]]'
rm -f "$S/compact-resume/committed/sid-nojq.md"

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
# the line ceiling applies however few words the reply holds
eleven=$(python3 -c 'print("\n".join(["w"]*11))')
SESSION_WORKFLOW_STATE_DIR="$S" bash "$STASH" <<<'{"session_id":"s1","prompt_id":"p6","prompt":"tldr"}'
SESSION_WORKFLOW_STATE_DIR="$S" TERSE_LOG="$LOG" bash "$GATE" <<<"$(payload s1 p6 "$eleven" 0)" >/dev/null 2>"$T/gate.err"; rc=$?
check "gate: 11-line 11-word tldr reply is blocked (line ceiling, not word minimum)" '[[ $rc -eq 2 ]] && grep -q "across 11 lines" "$T/gate.err"'
# a very long reply must still be evaluated, not break the hook (payload goes through a file)
huge=$(python3 -c 'print(" ".join(["word"]*70000))')
SESSION_WORKFLOW_STATE_DIR="$S" bash "$STASH" <<<'{"session_id":"s1","prompt_id":"p7","prompt":"tldr"}'
SESSION_WORKFLOW_STATE_DIR="$S" TERSE_LOG="$LOG" bash "$GATE" <<<"$(payload s1 p7 "$huge" 0)" >/dev/null 2>"$T/gate.err"; rc=$?
check "gate: a 300 KB reply is evaluated and blocked, no hook error" '[[ $rc -eq 2 ]] && grep -q "tldr ceiling exceeded" "$T/gate.err"'
check "gate: payload temp file removed" '[[ -z "$(ls "$S/terse"/.payload.* 2>/dev/null)" ]]'

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
# a by-hand install has no manifest: verify notes it and still passes
mv "$CFG/session-workflow-kit/manifest.json" "$T/manifest.aside"
out=$(bash "$INST" verify 2>&1); rc=$?
check "verify: a missing manifest is a note, not a failure" '[[ $rc -eq 0 ]] && grep -q "^VERIFIED" <<<"$out" && grep -q "^note: no manifest" <<<"$out"'
mv "$T/manifest.aside" "$CFG/session-workflow-kit/manifest.json"
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
out=$(TERSE_TLDR_MODE=observe bash "$INST" verify --terse-gate 2>&1); rc=$?
check "verify: the dry terse run blocks even when the user's environment sets observe mode" '[[ $rc -eq 0 ]] && grep -q "terse-gate blocked" <<<"$out"'
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
# 4j help text and relative config dir
out=$(bash "$INST" --help 2>&1)
check "help: prints the usage block and not the script body" 'grep -q "Usage:" <<<"$out" && ! grep -q "set -uo" <<<"$out"'
out=$(cd "$T" && bash "$INST" plan --config-dir rel-cfg 2>&1)
check "relative --config-dir resolves against the current directory" 'grep -qF -- "files -> $(cd "$T" && pwd)/rel-cfg" <<<"$out"'
# check without python3: a valid settings.json is reported as unchecked, not as invalid
rm -rf "$CFG"; mkdir -p "$CFG"; printf '{"theme": "dark"}\n' > "$CFG/settings.json"
mkdir -p "$T/nopy"
for u in bash uname date jq git gh head sed cat ls; do p=$(command -v "$u") && ln -s "$p" "$T/nopy/$u"; done
out=$(PATH="$T/nopy" bash "$INST" check 2>&1); rc=$?
check "check without python3: exits non-zero and names the missing tool" '[[ $rc -ne 0 ]] && grep -q "python3:   MISSING" <<<"$out"'
check "check without python3: a valid settings.json is not called invalid" 'grep -q "settings.json: present (not checked: python3 missing)" <<<"$out" && ! grep -q "NOT valid JSON" <<<"$out"'
# 4k a failed backup stops the run before the file is replaced
rm -rf "$CFG"; mkdir -p "$CFG/hooks" "$CFG/session-workflow-kit/backups"
printf 'ORIGINAL HOOK\n' > "$CFG/hooks/terse-gate.sh"
chmod 555 "$CFG/session-workflow-kit/backups"
out=$(bash "$INST" apply --yes 2>&1); rc=$?
check "unwritable backup dir: apply aborts with exit 5" '[[ $rc -eq 5 ]] && grep -q "backup failed" <<<"$out"'
check "unwritable backup dir: the original file is untouched" '[[ "$(cat "$CFG/hooks/terse-gate.sh")" == "ORIGINAL HOOK" ]]'
check "unwritable backup dir: settings.json and CLAUDE.md not written" '[[ ! -f "$CFG/settings.json" && ! -f "$CFG/CLAUDE.md" ]]'
check "unwritable backup dir: files created before the abort are in the manifest" '[[ "$(jq -r ".files[\"commands/compact-check.md\"].action" "$CFG/session-workflow-kit/manifest.json")" == "created" ]]'
check "unwritable backup dir: the untouched file is not in the manifest" '[[ "$(jq -r ".files[\"hooks/terse-gate.sh\"] // \"absent\"" "$CFG/session-workflow-kit/manifest.json")" == "absent" ]]'
chmod 755 "$CFG/session-workflow-kit/backups"
# the next apply finishes the job and uninstall removes what both runs did
bash "$INST" apply --yes >/dev/null 2>&1
bash "$INST" uninstall --yes >/dev/null 2>&1
check "after an aborted run: uninstall deletes the files that run created" '[[ ! -f "$CFG/commands/compact-check.md" && ! -f "$CFG/hooks/compact-resume-inject.sh" ]]'
check "after an aborted run: the original the second run replaced is restored" '[[ "$(cat "$CFG/hooks/terse-gate.sh")" == "ORIGINAL HOOK" ]]'
# 4l registration matching: a hook that names the script under another matcher or path is a conflict, not "present"
rm -rf "$CFG"; mkdir -p "$CFG"
cat > "$CFG/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {"matcher": "startup", "hooks": [{"type": "command", "command": "bash /old/compact-resume-inject.sh"}]}
    ]
  }
}
JSON
out=$(python3 -I "$KIT/install/merge-settings.py" check --settings "$CFG/settings.json" --hooks-dir "~/.claude/hooks" 2>&1); rc=$?
check "check: wrong matcher + path is reported missing with a conflict note" '[[ $rc -eq 1 ]] && grep -q "^conflict:" <<<"$out" && grep -q "^missing: SessionStart\[compact\]" <<<"$out"'
out=$(bash "$INST" apply --yes 2>&1); rc=$?
check "conflict: apply still adds the kit's registration" '[[ $rc -eq 0 ]] && grep -q "^conflict" <<<"$out" && jq -e ".hooks.SessionStart[] | select(.matcher==\"compact\") | .hooks[] | select(.command | test(\"compact-resume-inject.sh\"))" "$CFG/settings.json" >/dev/null'
check "conflict: the conflicting hook is left as is" 'jq -e ".hooks.SessionStart[0].hooks[0].command==\"bash /old/compact-resume-inject.sh\"" "$CFG/settings.json" >/dev/null'
out=$(bash "$INST" verify 2>&1); rc=$?
check "conflict: verify passes once the real registration exists" '[[ $rc -eq 0 ]]'
check "manifest: records only the registrations the kit added" '[[ "$(jq -r ".registrations | length" "$CFG/session-workflow-kit/manifest.json")" -eq 2 ]]'
# 4m a config dir with shell-significant characters
ODD="$T/odd \$x&y#z'q"; mkdir -p "$ODD"
out=$(bash "$INST" apply --yes --config-dir "$ODD" 2>&1); rc=$?
check "odd config dir: apply exits 0" '[[ $rc -eq 0 ]]'
check "odd config dir: commands point at it literally" 'grep -qF -- "$ODD/includes/session-audit-core.md" "$ODD/commands/compact-check.md"'
check "odd config dir: manifest is valid JSON with the exact path" '[[ "$(jq -r .config_dir "$ODD/session-workflow-kit/manifest.json")" == "$ODD" ]]'
mkdir -p "$T/oddstate/compact-resume/committed"; printf 'ODDBLOCK\n' > "$T/oddstate/compact-resume/committed/sid-odd.md"
cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ODD/settings.json")
out=$(SESSION_WORKFLOW_STATE_DIR="$T/oddstate" bash -c "$cmd" <<<'{"session_id":"sid-odd","source":"compact"}' 2>&1)
check "odd config dir: the registered command string runs the hook" 'grep -q ODDBLOCK <<<"$out"'
out=$(bash "$INST" verify --config-dir "$ODD" 2>&1); rc=$?
check "odd config dir: verify passes" '[[ $rc -eq 0 ]]'
# 4n declining changes changes nothing: existing install, no terminal, no --yes
rm -rf "$CFG"; mkdir -p "$CFG"
bash "$INST" apply --yes --terse-gate >/dev/null 2>&1
chmod 644 "$CFG/hooks/compact-resume-inject.sh"
out=$(bash "$INST" plan 2>&1)
check "plan: a present but non-executable hook is listed as a chmod change" 'grep -q "^chmod 755: ~/.claude/hooks/compact-resume-inject.sh" <<<"$out"'
out=$(bash "$INST" apply 2>&1 </dev/null)
check "apply declined: the hook stays non-executable" '[[ ! -x "$CFG/hooks/compact-resume-inject.sh" ]] && grep -q "skipping" <<<"$out"'
out=$(bash "$INST" uninstall 2>&1 </dev/null); rc=$?
check "uninstall declined: files, registrations and manifest all stay" '[[ -f "$CFG/commands/compact-check.md" && -f "$CFG/session-workflow-kit/manifest.json" ]] && grep -q "terse-gate" "$CFG/settings.json" && grep -q "session-workflow-kit:begin" "$CFG/CLAUDE.md"'
chmod 755 "$CFG/hooks/compact-resume-inject.sh"
# 4o manifest commit follows the checkout even when no file changes
jq '.commit="old"' "$CFG/session-workflow-kit/manifest.json" > "$T/m.json" && mv "$T/m.json" "$CFG/session-workflow-kit/manifest.json"
bash "$INST" apply --yes --terse-gate >/dev/null 2>&1
check "manifest: commit refreshed on a no-op apply" '[[ "$(jq -r .commit "$CFG/session-workflow-kit/manifest.json")" == "$(git -C "$KIT" rev-parse HEAD)" ]]'
# 4p uninstall undoes what the manifest records: restores a replaced original, deletes created files,
#    leaves a registration it did not add, removes a CLAUDE.md it created, keeps provenance across an upgrade
rm -rf "$CFG"; mkdir -p "$CFG/commands" "$CFG/hooks"
printf 'ORIGINAL COMMAND\n' > "$CFG/commands/compact-check.md"
cat > "$CFG/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {"matcher": "compact", "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/compact-resume-inject.sh"}]}
    ]
  }
}
JSON
out=$(bash "$INST" apply --yes --terse-gate 2>&1); rc=$?
check "provenance: apply exits 0" '[[ $rc -eq 0 ]]'
check "provenance: the replaced command is recorded with its backup" '[[ "$(jq -r ".files[\"commands/compact-check.md\"].action" "$CFG/session-workflow-kit/manifest.json")" == "replaced" ]] && [[ -f "$(jq -r ".files[\"commands/compact-check.md\"].backup" "$CFG/session-workflow-kit/manifest.json")" ]]'
check "provenance: created files recorded as created" '[[ "$(jq -r ".files[\"commands/end-session.md\"].action" "$CFG/session-workflow-kit/manifest.json")" == "created" ]]'
check "provenance: the pre-existing registration is not recorded as added" '! jq -e ".registrations[] | select(. == \"SessionStart|compact|compact-resume-inject.sh\")" "$CFG/session-workflow-kit/manifest.json" >/dev/null'
check "provenance: CLAUDE.md recorded as created" '[[ "$(jq -r .claude_md "$CFG/session-workflow-kit/manifest.json")" == "created" ]]'
first_backup=$(jq -r ".files[\"commands/compact-check.md\"].backup" "$CFG/session-workflow-kit/manifest.json")
printf '\n<!-- local edit -->\n' >> "$CFG/commands/compact-check.md"
sleep 1
bash "$INST" apply --yes --terse-gate >/dev/null 2>&1
check "provenance: an upgrade keeps the first backup as the original" '[[ "$(jq -r ".files[\"commands/compact-check.md\"].backup" "$CFG/session-workflow-kit/manifest.json")" == "$first_backup" ]]'
out=$(bash "$INST" uninstall --yes 2>&1); rc=$?
check "uninstall: exits 0 (manifest-driven)" '[[ $rc -eq 0 ]]'
check "uninstall: the replaced original is restored" '[[ "$(cat "$CFG/commands/compact-check.md")" == "ORIGINAL COMMAND" ]]'
check "uninstall: created files deleted" '[[ ! -f "$CFG/commands/end-session.md" && ! -f "$CFG/hooks/terse-gate.sh" ]]'
check "uninstall: the registration the kit did not add stays" '[[ "$(grep -c compact-resume-inject "$CFG/settings.json")" -eq 1 ]] && ! grep -q "terse-" "$CFG/settings.json"'
check "uninstall: a CLAUDE.md the kit created and that holds only the block is deleted" '[[ ! -f "$CFG/CLAUDE.md" ]]'
check "uninstall: manifest deleted when nothing managed remains" '[[ ! -f "$CFG/session-workflow-kit/manifest.json" ]]'
# 4q uninstall leaves what the install did not record: a Karabiner rule file that was already
#    there (install run without --karabiner) and a CLAUDE.md block that was already in place
rm -rf "$CFG" "$HOME/.config/karabiner"; mkdir -p "$CFG" "$HOME/.config/karabiner/assets/complex_modifications"
KFILE="$HOME/.config/karabiner/assets/complex_modifications/session-workflow.json"
printf 'MY OWN RULES\n' > "$KFILE"
printf 'my own notes\n' > "$CFG/CLAUDE.md"
python3 -I "$KIT/install/update-claude-md.py" apply --file "$CFG/CLAUDE.md" --block "$KIT/claude-md/tldr-block.md" --backup "$T/md-backup.md" >/dev/null 2>&1
md_before=$(cat "$CFG/CLAUDE.md")
bash "$INST" apply --yes >/dev/null 2>&1
check "unrecorded: the install records neither the rule file nor the block" '[[ -f "$CFG/session-workflow-kit/manifest.json" ]] && [[ "$(jq -r ".karabiner_file // .claude_md // empty" "$CFG/session-workflow-kit/manifest.json")" == "" ]]'
out=$(bash "$INST" uninstall --yes 2>&1); rc=$?
check "unrecorded: uninstall exits 0" '[[ $rc -eq 0 ]]'
check "unrecorded: a Karabiner rule file the install did not record stays as it was" '[[ -f "$KFILE" && "$(cat "$KFILE")" == "MY OWN RULES" ]]'
check "unrecorded: a CLAUDE.md block the install did not record stays as it was" '[[ "$(cat "$CFG/CLAUDE.md")" == "$md_before" ]] && grep -q session-workflow-kit:begin "$CFG/CLAUDE.md"'

echo
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
