# Install

Two paths: let Claude Code do it (guided, with approvals), or do it by hand. Both end with the same files in the same places. Everything the installer writes is backed up first and written atomically. A manifest records what the installer actually did, and `uninstall` undoes exactly that: files the kit created are deleted, files it replaced come back from their backup, only the hook registrations it added are removed.

## What gets installed

Into your Claude Code config directory (`$CLAUDE_CONFIG_DIR` if set, else `~/.claude`):

| Path | What |
| --- | --- |
| `commands/compact-check.md`, `end-session.md`, `archive-session.md`, `session-status.md` | the four slash commands |
| `includes/session-audit-core.md` | the audit payload the first two share |
| `hooks/compact-resume-store.sh`, `-precompact.sh`, `-inject.sh` | the compact-resume trio |
| `hooks/terse-prompt-stash.sh`, `terse-gate.sh`, `terse-report.sh` | the terse enforcer and its report (always copied; registered only with `--terse-gate`) |
| `settings.json` | two hook registrations added: `PreCompact` (`manual`) and `SessionStart` (`compact`); with `--terse-gate`, two more: `UserPromptSubmit` and `Stop` |
| `CLAUDE.md` | one block between `<!-- session-workflow-kit:begin -->` and `<!-- session-workflow-kit:end -->` with the tldr rule |
| `session-workflow-kit/manifest.json` | what the kit did: which commit, when, which files it created or replaced (with the backup of each replaced original), which hook registrations it added, whether it created `CLAUDE.md` or appended to it |
| `session-workflow-kit/backups/<timestamp>/` | every file the installer replaced, one directory per run |
| `session-workflow-kit/state/` | the hooks' private state (mode 700) |

Optionally, with `--karabiner` on macOS: `~/.config/karabiner/assets/complex_modifications/session-workflow.json`. A rule file there is inert until you enable it in the Karabiner UI (below).

## Path 1: guided install by Claude Code

These are the steps for the agent. If you are a person reading this, you can follow them too.

1. **Clone and read.**
   ```
   cd "$(mktemp -d)"
   git clone https://github.com/dabodamjan/claude-code-session-workflow.git
   cd claude-code-session-workflow
   ```
   The clone is only needed for this install; the manifest records the commit. If a checkout already exists (an earlier install or upgrade), reuse it instead of cloning: confirm `git remote get-url origin` names this repository, then `git pull`.

   Read `README.md` (what the kit is and its limits) and this file. Tell the user in two sentences what will be installed and that nothing is written before they approve the plan.

2. **Check requirements.**
   ```
   bash install/install.sh check
   ```
   Stop and report if `python3` or `jq` is missing, or if the existing `settings.json` is not valid JSON (the installer will refuse to touch it). Tell the user which surface they are on: `/archive-session` only works in the desktop app, and the keyboard shortcuts only on macOS with Karabiner-Elements.

3. **Ask about the two optional components before planning.** The terse gate (`--terse-gate`) blocks over-long replies when the user typed `tldr`; it is useful but opinionated. Tell the user the stash hook keeps a copy of each prompt on disk (a private file under the kit's state directory; the Stop hook needs it to know `tldr` was asked for). Prompt files older than 24 hours are deleted on the next stash-hook run; without another run, they remain on disk. The keyboard shortcuts (`--karabiner`) need Karabiner-Elements. Default to neither unless the user says yes.

4. **Plan, and show the user the output.**
   ```
   bash install/install.sh plan [--terse-gate] [--karabiner]
   ```
   This writes nothing. It prints, per file, `create` / `update` (with a diff) / `unchanged`, then the unified diff of `settings.json`, then the diff of `CLAUDE.md`. If `CLAUDE.md` already contains a rule about `tldr` or a word or line ceiling, the plan prints a `WARNING` naming the line: show it to the user, do not edit their rule, and let them decide whether to keep both. If the plan ends with `nothing to do`, the kit is already installed and current.

5. **Get an explicit yes on the plan, then apply.**
   ```
   bash install/install.sh apply [--terse-gate] [--karabiner] --yes
   ```
   `--yes` means "the user approved the plan above"; without a terminal to ask on, `apply` writes nothing unless it is given, and that includes the permission change on a hook that is present but not executable. The run prints the backup directory and the undo line. Pin the revision: the manifest records `git rev-parse HEAD` of the checkout you installed from; mention that commit in your summary.

6. **Verify.**
   ```
   bash install/install.sh verify [--terse-gate]
   ```
   It checks every file is present and executable, the hook registrations exist, the `CLAUDE.md` block is present and current, whether a manifest exists (a by-hand install has none; that is a note, not a failure), and it runs the three compact-resume hooks on sample input in a temporary state directory (store → precompact → inject, then a second inject that must emit nothing). It ends with `VERIFIED` or `FAILED`. Report the result verbatim. If it fails, do not retry blindly: show the failing line.

7. **Karabiner, if chosen.** The file is now in `~/.config/karabiner/assets/complex_modifications/`. Enabling it is a UI step the user does: Karabiner-Elements Settings → Complex Modifications → Add predefined rule → "Claude Code session workflow" → Enable. Tell them the shortcuts assume a US-style layout and an empty input line. The scoped variant (`karabiner/session-workflow-scoped.json`) fires only in the Claude app, Terminal, Ghostty, VS Code and iTerm2; copy it the same way if they want the shortcuts off elsewhere. In the Karabiner list it appears as "Claude Code session workflow (Claude app and terminals only)".

8. **Finish.** Tell the user: the session may need a restart for the hooks to load, which commit was installed, where the backups are, and that `bash install/install.sh uninstall` undoes what the manifest recorded (see Uninstall below for what that covers). Suggest a first run: `/compact-check` in any repo.

## Path 2: by hand

Same result, no agent:

```
cd "$(mktemp -d)"
git clone https://github.com/dabodamjan/claude-code-session-workflow.git
cd claude-code-session-workflow
bash install/install.sh check
bash install/install.sh plan            # read the diffs
bash install/install.sh apply           # asks y/N per change; or add --yes
bash install/install.sh verify
```

With an existing checkout, `git pull` in it instead of cloning.

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
3. Add the block from `claude-md/tldr-block.md` to `~/.claude/CLAUDE.md` through the marked-block updater, which replaces an existing block instead of appending a second one:
   ```
   python3 install/update-claude-md.py apply --file ~/.claude/CLAUDE.md --block claude-md/tldr-block.md --backup ~/.claude/CLAUDE.md.bak
   ```
   Pasting the file's contents by hand works once; a second paste leaves two marker pairs, and the updater then refuses to touch the file until one pair is removed.
4. Optional, macOS: copy `karabiner/session-workflow.json` to `~/.config/karabiner/assets/complex_modifications/` and enable it in the Karabiner UI.

If your config directory is not `~/.claude`, replace `~/.claude/` in the two hook commands and in the `includes` references inside the four command files with your directory, and quote the hook path in `settings.json` if it contains spaces or other shell-significant characters. The installer does this substitution and quoting for you when `CLAUDE_CONFIG_DIR` is set or `--config-dir` is passed. A manual install has no manifest, so a later `uninstall` falls back to removing the kit's files by name. `--config-dir` is for a directory Claude Code itself uses, which means `CLAUDE_CONFIG_DIR` is set to it; the hooks find their state through that same variable.

## Upgrade

Pull the repo and run `plan` then `apply` again. Files that changed show a diff; the `CLAUDE.md` block is replaced between its markers (your own text around it is untouched); hook registrations that already exist under the right event, matcher and path are reported as `present` and not added again. A hook that names a kit script under another matcher or another path is reported as a `conflict`, left alone, and the kit's own registration is added next to it. The manifest's commit moves to the new revision even when no file changed, and the provenance of each file is kept: an original the kit replaced on the first install stays restorable after any number of upgrades.

## Uninstall

```
bash install/install.sh uninstall [--yes]
```

Undoes what the manifest recorded, each item after a prompt (or all at once with `--yes`):

- a file the kit created is deleted; a file the kit replaced is restored from the backup of the original
- only the hook registrations the kit added are removed; one that was already there, even if it runs a kit script, stays
- the `CLAUDE.md` block is removed when the manifest records that the kit wrote it; a block that was already in place stays; a `CLAUDE.md` the kit created is deleted if nothing else is in it, and one the kit appended to keeps everything outside the block
- the Karabiner rule file is deleted or restored the same way when the manifest records it (disable the rule in the UI first); a rule file the install did not write stays
- the manifest is deleted only when nothing managed remains; a declined prompt keeps it, so a later run can finish the job

Backups and logs under `session-workflow-kit/` are kept. Without a manifest (a manual install), the kit's files are removed by name and registrations that run a kit script under the hooks directory are removed; nothing can be restored that way.

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

Set them in the `env` block of `settings.json` (for example `"env": {"TERSE_TLDR_MODE": "observe"}`) or export them before starting Claude Code; hooks inherit Claude Code's environment.
