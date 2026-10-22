# Claude Code session workflow

Four slash commands, a pair of hooks and five one-handed chords that close the loop around `/compact` and the end of a session.

`/compact-check` audits the repo, drives it to a clean state and writes a resume block. The hooks put that block back after `/compact`, so you never copy and paste it. `/end-session` refuses to green-light while anything of value lives only in chat or on an unpushed branch. `/archive-session` closes the session once its PRs are merged. A `tldr` reply rule keeps answers short, with an optional hook that enforces the ceiling. This is the setup I run every day.

## Install with one prompt

Paste this into Claude Code:

```
Read https://github.com/dabodamjan/claude-code-session-workflow and set it up for me by following its INSTALL.md.
```

This is a guided install, not an unattended one. Claude clones the repo, runs the requirements check, shows you every change as a diff (the files it copies, the hook registrations it adds to `settings.json`, the block it appends to `CLAUDE.md`), asks before writing, backs up every file it replaces, and verifies the result with a dry run of the hooks. Running it twice adds nothing the second time. `uninstall` undoes what the install recorded: files the kit created go, files it replaced come back from their backup, and only the registrations it added are removed. If you would rather not have an agent touch your config, [INSTALL.md](INSTALL.md) has the manual path too.

## What you get

| You type | Or press | What happens |
| --- | --- | --- |
| `/compact-check` | Right Option + `,` | Audits the repo (tree, upstream, PR, conflicts, type check, unwritten chat content). A green verdict prints a resume block and stores it for the hooks. Yellow or red lists the fixes and does the file-side ones. |
| `/compact` | Right Option + `.` | Claude Code's own compact. The hooks inject the stored resume block into the compacted session; the chord also types a `go` that starts the next turn. |
| `tldr` | Right Option + `/` | Short, plain reply: 10 lines or 130 words, ending with what you still need to do. |
| `/end-session` | Right Option + `'` | Same audit with a harder bar: everything committed, pushed, in a PR, or handed back. Green-light checklist plus the merge links. |
| `/archive-session` | Right Option + `\` | Checks this session's PRs are merged, then asks the desktop app to archive the session. |
| `/session-status` | | A short "what is this session doing" summary, under 25 lines, for when you run many at once. |

## What it looks like

The shape of a `/compact-check` pass that comes back green (names made up, format real):

```
🟢 Safe to compact: clean tree, in sync, PR open, nothing in flight.

CWD          ~/code/my-app (matches git root)
Branch       feature/mailer-migration @ 05a0298
Working tree clean
Push state   in sync with origin
PR #12       OPEN "add: mailer migration"  https://github.com/you/my-app/pull/12
Conflicts    none (PR mergeable, no rebase/merge in progress)
Checks       tsc clean; lint clean; tests detected, not run
Dev server   none
Background   none
In-flight    none
Unwritten    none

Continuing from compacted session.

State:
- Repo: my-app @ feature/mailer-migration @ 05a0298
- PR: https://github.com/you/my-app/pull/12 ("add: mailer migration")
- Working dir: ~/code/my-app
- Plan: docs/plans/mailer-migration.md (read it fully, start at its RESUME block)

Last completed: stages 1 to 3 of the plan; stage 4 (cut over the queue) not started.

Next up: execute docs/plans/mailer-migration.md from its RESUME block.
```

And the same command when the tree is not clean: no resume block, a fix plan instead, and the command does the file writes itself before asking you about commits and pushes.

```
🟡 Compact with caution: 2 modified files and an unsaved 8-stage plan.

...
Fix plan:
1. Save the migration plan to docs/plans/mailer-migration.md (~40 lines).   [doing now]
2. Commit it with the two modified files: "add: mailer migration plan".      [needs your yes]
```

A chord firing, keystroke by keystroke:

```
you press         Right Option + ,
Karabiner types   /compact-check          the slash opens Claude Code's autocomplete menu
400 ms later      Escape                  closes the menu; Enter does not submit while a suggestion is highlighted
then              Enter                   submits the command
```

## How the pieces fit

```
/compact-check ──prints──▶ resume block ──pipes into──▶ compact-resume-store.sh
                                                         writes pending/<nonce>.md
                                                         prints compact-resume:stored:<nonce>
                                                         (that marker lands in the transcript)
            you press Right Option + .
/compact ──PreCompact hook──▶ compact-resume-precompact.sh
                              finds the pending file whose nonce is in THIS transcript
                              moves it to committed/<session_id>.md
         ──SessionStart(compact) hook──▶ compact-resume-inject.sh
                              emits committed/<session_id>.md as additionalContext, once
         ──the chord's queued "go"──▶ a turn starts and Claude continues from the block
```

The nonce step is what keeps parallel sessions apart. A slash command's shell has no reliable handle on its own session id. The PreCompact hook has both the id and the transcript, so it proves ownership by finding the marker the store step printed. One case the transcript cannot settle: a session branched with `/branch` after `/compact-check` carries a copy of the same transcript, marker included. Whichever of the two compacts first takes the block; the other finds nothing.

## Requirements

- Claude Code on macOS or Linux. The commands and hooks work in the terminal CLI, the VS Code extension and the desktop app. `/archive-session` needs the desktop app.
- `bash` (3.2 is fine), `jq`, `python3` (3.8 or newer), `git`. `gh` is optional; without it the PR checks say "unknown" instead of pretending.
- Karabiner-Elements for the chords, macOS only. Optional.
- A `CLAUDE_CONFIG_DIR` other than `~/.claude` is honoured by the installer and the hooks.

## Honest limits

- **Guided means approvals.** The one-prompt install shows diffs and asks; it is not unattended. Claude Code reloads `settings.json` on change, but if a hook does not fire after the install, restart the session.
- **`/archive-session` is desktop-only.** It uses the session tools the desktop app gives Claude. In the CLI, VS Code or a cloud session it says so and stops.
- **The chords are macOS-only and assume a US-style layout** and an empty input line. They type text; if something is already in the input box, that text gets the command appended. On another layout, `karabiner/build.py` says how to find your key codes.
- **Slash commands cannot be bound to a key inside Claude Code.** `~/.claude/keybindings.json` binds built-in actions only, and none of them types text or runs a command. That is why the chord lives one layer down, in Karabiner. [docs/decisions/001-chords-live-in-karabiner.md](docs/decisions/001-chords-live-in-karabiner.md) has the full reasoning.
- **Escape before Enter.** Typing `/` opens the command menu. The docs say plain Enter does not submit while a suggestion is highlighted (Tab accepts it, Escape closes the menu), and that in fullscreen rendering the list opens with no row highlighted. Escape first covers both cases; Tab would be wrong because it accepts whatever is highlighted, and `/compact` prefix-matches `/compact-check`. I have verified the sequence on the desktop app only.
- **Injection is not resumption.** The post-compact hook puts the block in context; the Claude Code docs say the `initialUserMessage` output is for `-p` mode, so nothing starts a turn. The `/compact` chord types `go` afterwards. Claude Code documents that messages typed while it is busy are queued; that this also holds during a compaction is something I have only observed on my own machine.
- **Only manual `/compact`.** The hooks register for the `manual` matcher. Auto-compact gets no resume block because nobody ran `/compact-check` before it.
- **Session id across compaction.** The inject hook assumes the session id is the same before and after a compaction. I measured that on my machine; the docs do not promise it.
- **The terse gate is best-effort.** It is a Stop hook: it fires after the reply was already shown, it sees only the final message of a turn, and it counts words and lines (prose only, code and quotes exempt). A block produces a second, shorter reply; it does not retract the first. The UserPromptSubmit stash hook writes each prompt's text to a private file (mode 600) under the kit's state directory and deletes it after a day; without it the gate cannot know you typed `tldr`. CLAUDE.md itself is context, not enforcement, which is the whole reason the hook exists.
- **The commands use the `commands/` file format.** Claude Code documents it as the older format that still works; skills are the newer one. If that changes, the four files port one-to-one.

## Prior art

- [claude-handoff](https://github.com/392fyc/claude-handoff): a `/handoff` command that writes a handoff document and a SessionStart hook that injects it into a *new* session. Explicit only, no PreCompact. This kit stays inside the same session and is gated on a repo audit.
- [A PreCompact snapshot with a SessionStart(compact) restore](https://zenn.dev/ryuka_lucas/articles/1e50ed03029b49?locale=en): saves recent messages automatically before compaction and injects them after. Automatic and content-based; this kit is deliberate and state-based, with a nonce that ties a block to the session whose transcript holds its marker.
- [anthropics/claude-code#11455](https://github.com/anthropics/claude-code/issues/11455): the feature request for a built-in handoff file.

## Who made this

Damjan Dabo, indie developer in Croatia. I build ReleaseRocket (release announcements drafted from GitHub tags, with my wife Sara as co-founder) and the iOS apps Itemlist, QRGenie and BarcodeCraft. I build in public and write at [dabo.dev](https://dabo.dev). Find me on [X](https://x.com/DamjanDabo) and [LinkedIn](https://www.linkedin.com/in/damjan-dabo/). I run Claude Code daily from the desktop app.

## License

MIT. See [LICENSE](LICENSE).
