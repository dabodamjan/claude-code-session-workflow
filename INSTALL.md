# Install

Two paths: let Claude Code do it (guided, with approvals), or do it by hand. Both end with the same files in the same places. Everything the installer writes is backed up first, written atomically, and can be removed again with `uninstall`.

## What gets installed

Into your Claude Code config directory (`$CLAUDE_CONFIG_DIR` if set, else `~/.claude`):

| Path | What |
| --- | --- |
| `commands/compact-check.md`, `end-session.md`, `archive-session.md`, `session-status.md` | the four slash commands |
| `includes/session-audit-core.md` | the audit payload the first two share |
| `hooks/compact-resume-store.sh`, `-precompact.sh`, `-inject.sh` | the compact-resume trio |
| `hooks/terse-prompt-stash.sh`, `terse-gate.sh`, `terse-report.sh` | the optional terse enforcer and its report |
| `settings.json` | two hook registrations added: `PreCompact` (`manual`) and `SessionStart` (`compact`); with `--terse-gate`, two more: `UserPromptSubmit` and `Stop` |
| `CLAUDE.md` | one block between `<!-- session-workflow-kit:begin -->` and `<!-- session-workflow-kit:end -->` with the tldr rule |
| `session-workflow-kit/manifest.json` | which commit was installed, when, with which options |
| `session-workflow-kit/backups/<timestamp>/` | every file the installer replaced, one directory per run |
| `session-workflow-kit/state/` | the hooks' private state (mode 700) |

Optionally, with `--karabiner` on macOS: `~/.config/karabiner/assets/complex_modifications/session-workflow.json`. A rule file there is inert until you enable it in the Karabiner UI (below).

## Path 1: guided install by Claude Code

These are the steps for the agent. If you are a person reading this, you can follow them too.

1. **Clone and read.**
   ```
   git clone https://github.com/dabodamjan/claude-code-session-workflow.git
   cd claude-code-session-workflow
   ```
   Read `README.md` (what the kit is and its limits) and this file. Tell the user in two sentences what will be installed and that nothing is written before they approve the plan.

2. **Check requirements.**
   ```
   bash install/install.sh check
   ```
   Stop and report if `python3` or `jq` is missing, or if the existing `settings.json` is not valid JSON (the installer will refuse to touch it). Tell the user which surface they are on: `/archive-session` only works in the desktop app, and the chords only on macOS with Karabiner-Elements.

3. **Ask about the two optional components before planning.** The terse gate (`--terse-gate`) blocks over-long replies when the user typed `tldr`; it is useful but opinionated. The chords (`--karabiner`) need Karabiner-Elements. Default to neither unless the user says yes.

4. **Plan, and show the user the output.**
   ```
   bash install/install.sh plan [--terse-gate] [--karabiner]
   ```
   This writes nothing. It prints, per file, `create` / `update` (with a diff) / `unchanged`, then the unified diff of `settings.json`, then the diff of `CLAUDE.md`. If `CLAUDE.md` already contains a rule about `tldr` or a word or line ceiling, the plan prints a `WARNING` naming the line: show it to the user, do not edit their rule, and let them decide whether to keep both. If the plan ends with `nothing to do`, the kit is already installed and current.

5. **Get an explicit yes on the plan, then apply.**
   ```
   bash install/install.sh apply [--terse-gate] [--karabiner] --yes
   ```
   `--yes` means "the user approved the plan above"; without a terminal to ask on, `apply` writes nothing unless it is given. The run prints the backup directory and the rollback line. Pin the revision: the manifest records `git rev-parse HEAD` of the checkout you installed from; mention that commit in your summary.

6. **Verify.**
   ```
   bash install/install.sh verify [--terse-gate]
   ```
   It checks every file is present and executable, the hook registrations exist, the `CLAUDE.md` block is present and current, the manifest exists, and it runs the three compact-resume hooks on sample input in a temporary state directory (store → precompact → inject, then a second inject that must emit nothing). It ends with `VERIFIED` or `FAILED`. Report the result verbatim. If it fails, do not retry blindly: show the failing line.

7. **Karabiner, if chosen.** The file is now in `~/.config/karabiner/assets/complex_modifications/`. Enabling it is a UI step the user does: Karabiner-Elements Settings → Complex Modifications → Add predefined rule → "Claude Code session workflow" → Enable. Tell them the chords assume a US-style layout and an empty input line, and that the scoped variant (`karabiner/session-workflow-scoped.json`, chords only in the Claude app, Terminal, Ghostty and VS Code) can be copied the same way if they want the chords off elsewhere.

8. **Finish.** Tell the user: the session may need a restart for the hooks to load, which commit was installed, where the backups are, and that `bash install/install.sh uninstall` reverses it. Suggest a first run: `/compact-check` in any repo.

## Path 2: by hand

Same result, no agent:

```
git clone https://github.com/dabodamjan/claude-code-session-workflow.git
cd claude-code-session-workflow
bash install/install.sh check
bash install/install.sh plan            # read the diffs
bash install/install.sh apply           # asks y/N per file; or add --yes
bash install/install.sh verify
```

Or copy the files yourself. Everything the installer does is plain file copies plus two edits:

1. Copy `commands/*.md` to `~/.claude/commands/`, `includes/session-audit-core.md` to `~/.claude/includes/`, and `hooks/*.sh` to `~/.claude/hooks/` (`chmod +x` the hooks).
2. Add to `~/.claude/settings.json` (merge into existing `hooks` if you have any):
   ```json
   {
     "hooks": {
       "PreCompact": [
         {"matcher": "manual", "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/compact-resume-precompact.sh", "timeout": 10}]}
       ],
       "SessionStart": [
         {"matcher": "compact", "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/compact-resume-inject.sh", "timeout": 10}]}
       ]
     }
   }
   ```
   For the terse gate, add `UserPromptSubmit` → `bash ~/.claude/hooks/terse-prompt-stash.sh` (timeout 5) and `Stop` → `bash ~/.claude/hooks/terse-gate.sh` (timeout 15), both without a matcher.
3. Append the contents of `claude-md/tldr-block.md` to `~/.claude/CLAUDE.md`, markers included.
4. Optional, macOS: copy `karabiner/session-workflow.json` to `~/.config/karabiner/assets/complex_modifications/` and enable it in the Karabiner UI.

If your config directory is not `~/.claude`, replace `~/.claude/` in the two hook commands and in the `includes` references inside the four command files with your directory. The installer does this substitution for you when `CLAUDE_CONFIG_DIR` is set or `--config-dir` is passed.

## Upgrade

Pull the repo and run `plan` then `apply` again. Files that changed show a diff; the `CLAUDE.md` block is replaced between its markers (your own text around it is untouched); hook registrations that already exist are reported as `present` and not added again. The manifest's commit moves to the new revision.

## Uninstall

```
bash install/install.sh uninstall [--yes]
```

Removes the kit's files, its hook registrations and its `CLAUDE.md` block, each after a prompt (or all at once with `--yes`). Backups and logs under `session-workflow-kit/` are kept. Disable the Karabiner rule in the UI before deleting its file.

## Tunables

All optional, as environment variables for the hooks:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SESSION_WORKFLOW_STATE_DIR` | `<config dir>/session-workflow-kit/state` | where the hooks keep state |
| `COMPACT_RESUME_TTL_SECONDS` | `1800` | a stored resume block older than this is dropped, never injected |
| `SESSION_WORKFLOW_DEBUG` | unset | set to `1` to append a trace to `state/compact-resume/debug.log` |
| `TERSE_TLDR_MODE` / `TERSE_TIC_MODE` | `enforce` / `observe` | `enforce`, `observe` or `off` |
| `TERSE_TLDR_WORDS` / `TERSE_TLDR_LINES` | `130` / `10` | the tldr ceiling; keep in sync with the CLAUDE.md block |
| `TERSE_LOG` | `<config dir>/session-workflow-kit/logs/terse-gate.tsv` | the per-turn log `terse-report.sh` reads |
