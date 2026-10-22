# Architecture

## Components

| Piece | Kind | Runs when |
| --- | --- | --- |
| `commands/compact-check.md` | slash command (prompt) | you type `/compact-check` |
| `commands/end-session.md` | slash command | you type `/end-session` |
| `commands/archive-session.md` | slash command | you type `/archive-session` (desktop app) |
| `commands/session-status.md` | slash command | you type `/session-status` |
| `includes/session-audit-core.md` | shared prompt payload | read by the first two commands |
| `hooks/compact-resume-store.sh` | helper, not a hook | `/compact-check` pipes the resume block into it |
| `hooks/compact-resume-precompact.sh` | `PreCompact` hook, matcher `manual` | right before a manual `/compact` |
| `hooks/compact-resume-inject.sh` | `SessionStart` hook, matcher `compact` | right after any compaction |
| `hooks/terse-prompt-stash.sh` | `UserPromptSubmit` hook (optional) | every prompt |
| `hooks/terse-gate.sh` | `Stop` hook (optional) | end of every turn |
| `hooks/terse-report.sh` | script, run by hand | never automatically |
| `claude-md/tldr-block.md` | CLAUDE.md block | loaded into every session |
| `karabiner/*.json` | Karabiner-Elements rules (optional, macOS) | at the HID level, in any app (or the listed ones) |

The commands are prompts: Claude Code reads the Markdown and follows it. The hooks are shell scripts Claude Code runs with a JSON payload on stdin. The two never call each other directly; the only bridge is the store helper that `/compact-check` runs through the Bash tool.

## The compact-resume flow

The problem: `/compact` replaces the conversation with a summary, and the summary flattens the structured detail (paths, step order, decisions) that a resume needs. The old fix was manual: `/compact-check` prints a resume block, you copy it, run `/compact`, paste it. The hooks remove the copy and the paste.

```
1. /compact-check reaches 🟢 and prints the resume block.
2. It pipes the same text into compact-resume-store.sh, which writes
      <state>/compact-resume/pending/<nonce>.md
   and prints  compact-resume:stored:<nonce>  to stdout.
   Bash tool output is recorded in the session transcript, so the marker is now in the transcript.
3. You run /compact (or press the chord).
4. PreCompact (matcher manual) runs compact-resume-precompact.sh with {session_id, transcript_path}.
   It greps the transcript for each pending nonce. The one it finds is this session's.
   It moves that file to <state>/compact-resume/committed/<session_id>.md
   and deletes any older pending file this session also owned.
5. Compaction happens. The transcript is now a summary; the marker is gone, but ownership is settled.
6. SessionStart (matcher compact) runs compact-resume-inject.sh with {session_id, source: "compact"}.
   It claims committed/<session_id>.md with an atomic rename, deletes it, and emits the text as
   hookSpecificOutput.additionalContext, worded as a directive to continue from it.
7. Nothing starts a turn by itself, so the /compact chord types "go" + Enter after the compact Enter.
   Claude Code queues messages typed while it is busy; the queued "go" fires when compaction ends.
```

### Why the nonce

A slash command's shell has no reliable handle on the current session id: it is delivered to hooks on stdin, not exposed to the Bash tool, and the per-project transcript directory can hold many files from parallel sessions, so "the newest transcript" is not this session either. The store step therefore keys by an unguessable nonce, and the PreCompact hook, which does receive `session_id` and `transcript_path`, proves ownership by finding the nonce marker in its own transcript. A pending file whose nonce is in no transcript is left alone for its owner and expires after the TTL.

### Why PreCompact and not SessionStart for the ownership step

PreCompact fires before compaction, while the transcript still contains the marker. After compaction the transcript is a summary and the proof is gone. So ownership is settled before, and injection, which only needs `session_id`, happens after.

### Why `additionalContext` and not `initialUserMessage`

The hooks reference documents `initialUserMessage` as the first user message "in non-interactive mode with the `-p` flag". In an interactive session after `/compact` it is accepted and ignored, which I measured on 2026-08-04 with a debug trace (a clean store → precompact → inject chain and an emit that never became a turn). `additionalContext` is delivered on `source: compact`. It lands as context, not as a turn, hence the directive wording and the chord's trailing `go`.

### Guarantees the scripts give

- Session-scoped: keyed by `session_id`; one session's block can never surface in another.
- Fires once: the committed file is claimed by rename and deleted before the text is emitted, so a racing second run finds nothing.
- An older block cannot resurface: the precompact step keeps only the newest owned pending file, and every stage drops files older than `COMPACT_RESUME_TTL_SECONDS` (30 minutes by default).
- Silent when unused: an auto-compact, or any compaction without a prior `/compact-check`, finds no committed file and emits nothing.
- Fail-silent: every error path exits 0 with no output. A broken hook never blocks a compaction.
- Private: the state directory is created with mode 700 under the config directory, never in a shared `/tmp`.

### Documented versus observed

| Claim | Status |
| --- | --- |
| `PreCompact` has matchers `manual` / `auto`; `SessionStart` has `startup` / `resume` / `clear` / `compact` / `fork` | documented (hooks reference, checked 2026-10-22) |
| `SessionStart` output accepts `additionalContext`; `initialUserMessage` is for `-p` mode | documented |
| Stop input carries `last_assistant_message` and `stop_hook_active`; exit 2 blocks and hands stderr to Claude | documented |
| `UserPromptSubmit` input carries `prompt`; the transcript file may lag the current turn | documented |
| Messages typed while Claude is busy are queued and sent when the turn ends | documented (interactive mode) |
| The queue also holds a message typed during a compaction | observed on the author's machine (2026-08-04), not in the docs |
| `session_id` is identical on the PreCompact and the post-compact SessionStart side | measured on the author's machine, not promised by the docs |
| Bash tool stdout is stored verbatim in the transcript file | observed; the nonce lookup depends on it |
| Typing `/` opens the autocomplete menu, in which Enter is not bound | documented (keybindings: Autocomplete context binds Tab, Escape, Up, Down) |
| A synthetic Enter arriving while the menu is open does nothing | observed on the author's machine |

## The terse gate

`terse-prompt-stash.sh` writes each prompt to `<state>/terse/prompt-<session>-<prompt_id>` (mode 600, deleted after a day). `terse-gate.sh` reads it back on Stop, strips fenced code and quoted lines from `last_assistant_message`, counts words and lines, and when the prompt contained `tldr` and the reply exceeds 10 lines or 130 words, exits 2 with the rewrite instruction on stderr. `stop_hook_active` plus a per-turn marker file guarantee at most one block per turn. Every turn is logged to a TSV, whatever the verdict, so `terse-report.sh` can show the trend. A filler-phrase score is computed alongside and only logged by default.

## State directory

```
<config dir>/session-workflow-kit/
  manifest.json            commit, time, options, file list, backup dir of the last install
  backups/<timestamp>/     one directory per install/uninstall run; never overwritten
  state/                   mode 700
    compact-resume/pending/<nonce>.md
    compact-resume/committed/<session_id>.md
    compact-resume/debug.log          only with SESSION_WORKFLOW_DEBUG=1
    terse/prompt-<session>-<prompt>   24h retention
    terse/blocked-<session>-<prompt>  per-turn loop guard
  logs/terse-gate.tsv
```

## The installer

`install/install.sh` is a thin orchestrator; the two edits with real logic are Python:

- `merge-settings.py` adds hook registrations keyed by event + matcher + script name. It never copies a settings file wholesale, aborts on invalid JSON or a wrong shape with nothing written, treats a hook that already runs the script as present (whatever its matcher), appends to the existing group with the same matcher or creates one, preserves the file's indentation, prints a unified diff, and writes through a temp file and rename after taking a timestamped backup. `remove` does the inverse; `check` verifies.
- `update-claude-md.py` replaces the text between the two markers, or appends the block after a blank line, or creates the file. Lines outside the block that mention `tldr` or a word/line ceiling are printed as warnings and left alone. Same diff, backup and atomic write.

`install.sh` validates both targets before copying a single file, so a malformed `settings.json` aborts the whole run with nothing changed. `apply` needs either a terminal (it asks per file) or `--yes` (the agent passes it after the user approved the plan). `verify` runs the compact-resume hooks on sample input in a temporary state directory and checks a second inject emits nothing. `tests/run.sh` exercises all of this against a throwaway `HOME`: fresh install, repeat install, pre-existing hooks and CLAUDE.md, malformed settings, custom config directory, upgrade, uninstall.
