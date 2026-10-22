---
description: Audit the session before /compact, drive it to a clean state, and produce a resume block that the compact-resume hooks re-inject after compaction.
disable-model-invocation: true
---

# /compact-check

Pre-compact audit. Compacting drops the prompt cache and replaces the conversation with a summary, so it is most useful at clean stopping points where the next chunk of work does not depend on lived session memory. This command makes that judgment evidence-based instead of vibes-based.

**Shared payload lives in `~/.claude/includes/session-audit-core.md`** (the same file backs `/end-session`). Read it and apply the sections named below; this file carries only the compact-check-specific gating, verdict symbols, resume block and overrides.

## Detect which repos to check

Read `~/.claude/includes/session-audit-core.md` once, then apply **§1**.

## Run these checks in parallel

Apply **§2** (checks 1 to 9 and the "do not run" list) and **§3** (the check-9 unwritten-content detail) of the include.

**compact-check verdict mapping for §2 and §3:**
- Severity symbols are 🟢 / 🟡 / 🔴.
- Check 3 (push state): commits ahead of the upstream, or no upstream at all (`unknown`), is a **🟡** trigger.
- Check 4 (open PR): a pushed branch with no open PR is a **🟡** when the user normally opens PRs; PR-body drift (commit newer than the PR's last update) is a **🟡**. `unknown` (gh missing, network or auth error) is reported as unknown and counts as **🟡**, never as green.
- Check 5 (merge-conflict state): a local in-progress conflict is **🔴** (never compact here: the unresolved hunks and the resolution plan live only in working memory); PR-vs-base `CONFLICTING` / `DIRTY` is **🟡**.
- Check 6 (project checks): a failing static check is **🔴** (compacting would lose the active fix loop); `detected, not run` and `n/a` are informational; `unknown` is **🟡**.
- Check 9 (unwritten chat content): either sub-check tripping is a **🟡**. `/compact` summarizes chat, and the structured detail (file paths, stage breakdowns, decision gates, naming choices, numeric findings) gets flattened. Save to disk before compacting.

## Output flow, gated on the verdict

The resume block is **only emitted when the verdict is 🟢**. The point of the audit is to land at a clean state before compacting, not to hand over a resume block that papers over loose ends.

**A non-green verdict is work to do, not a status to hand back.** When the verdict is 🟡 or 🔴, your job is to drive the state TO green: not to report the loose ends and ask how to proceed, and never to say "safe to compact" or emit a resume block while non-green.

**Do not rationalize compacting on a dirty tree.** "The content is already saved to disk" and "the plan file survives `/compact`" make the *content* safe; they do NOT make the verdict green. Uncommitted, untracked or wrong-branch work is still 🟡, and the response is to save, commit or branch it (Path B, within §6 of the include), not to wave it through because nothing would be lost. Files-survive-compact is true and irrelevant to the verdict.

**Three flow paths:**

**Path A: 🟢 on first pass.** Output all three sections in one message: Recommendation → State → Copy-paste resume. **Then stop; the turn is over.** The user's next action is `/compact`; do not pick up new work (see Output discipline).

**Path B: 🟡 or 🔴 on first pass.** Output two sections plus a Fix plan, in this order: Recommendation → State → Fix plan. Then act:
1. Propose the smallest set of fixes that flips the verdict to 🟢. Lead with the recommendation; do not bounce open-ended "should we?" questions back. Do the file writes immediately (save unwritten content, write the plan file). For anything git-shaped, follow **§6** of the include: commit only when the user has said so in this session; push, PR, rebase and branch deletion need the user's explicit yes to the exact command. Ask once, with the commands, and wait.
2. Execute the approved fixes.
3. **Re-run** the relevant checks (only whichever would have flipped). Report the new verdict in a single short banner.
4. If 🟢, emit the Copy-paste resume. If still 🟡 / 🔴, loop back to step 1 with the remaining items.

**Path C: 🔴 with truly in-flight work** (background build, mid-debug fix loop, unfinished agent). Do NOT propose fixing just to unblock compact. Surface the in-flight state, say explicitly that compacting now would lose useful working memory, and stop. The user decides whether to wait or pull the plug.

## Sections, same shape, conditional emission

### 1. State

Use the base table from **§4** of the include, with 🟢/🟡/🔴 symbols. compact-check adds an `In-flight` row:

```
CWD          /Users/.../my-app (matches git root)
Branch       feature/mailer-migration @ 05a0298
Working tree clean
Push state   in sync with origin
PR #12       OPEN "add: mailer migration"  https://github.com/you/my-app/pull/12
Conflicts    none (PR mergeable, no rebase/merge in progress)
Checks       tsc clean; lint clean; tests detected, not run
Dev server   :3000 (next-server)
Background   none
In-flight    none
Unwritten    none
```

If anything is off, show it inline (for example `Working tree  3 modified: foo.ts, bar.tsx, baz.md`).

### 2. Recommendation

One banner line, one short reason. Pick exactly one. **In multi-repo mode, the recommendation is the worst case across all repos.**

- 🟢 **Safe to compact**: clean state, no in-flight work
- 🟡 **Compact with caution**: one-line description of what is loose; handle it first
- 🔴 **Don't compact yet**: one-line description of what is actively in flight

If 🟡 or 🔴, list the specific actions to clear it.

**Default 🟡 triggers** (any of these flips a 🟢 to 🟡):
- Commits ahead of the upstream, or a branch with no upstream (unpushed count unknown)
- Pushed branch with no open PR yet (when the user normally opens PRs)
- Open PR whose description has not been updated since the last push
- Untracked files in the repo that are not known noise (`.DS_Store`, editor files)
- Modified working tree (unless the dirty file is known recurring noise from a dev server; call it out as "known noise" inline)
- Substantive chat content not yet written to a repo file (§3 of the include): big deliverables AND smaller shaping items (decisions, findings, conventions, reframes, followups)
- Open PR in `CONFLICTING` / `DIRTY` state
- Any check reporting `unknown`

**Default 🔴 triggers:**
- Background bash tasks still running
- In-flight agents not yet returned
- Dev server actively serving a feature that is mid-edit
- Failing type check or lint (compacting would lose the active fix loop)
- Working tree mid-conflict: unmerged paths, or a rebase/merge in progress with unresolved hunks

### 3a. Fix plan (only when the verdict is 🟡 or 🔴)

Use the fix-plan mechanics and the conflict template from **§5** of the include. Order items by what unblocks compact fastest.

After listing the plan, say which items you will do immediately (file writes) and which need the user's yes (§6 of the include). Then act on the immediate ones in the same turn. **Do not emit the resume block while items remain.**

After fixes land, re-check and report the new verdict in a single short banner (for example "Recheck → 🟢: plan saved, branch pushed, PR open"). Only then move to 3b.

### 3b. Copy-paste resume (only when the verdict is 🟢)

Fenced code block, at most 10 lines, ready to paste verbatim into the post-compact session if the hooks are not installed.

**Durable-plan pattern: use it whenever the next chunk is a substantial multi-step task.** Do not cram a multi-step plan into the 10-line resume, and do not rely on the conversation summary to carry it. Instead, *before* compacting, write a single self-contained **plan file** to disk (§3 of the include says where) containing the facts, the decisions made, the step order, and a `RESUME block` at the end, written so a fresh session can execute it cold. Then the resume block's only job is to POINT at it. (The plan file covers the genuinely incomplete *remainder* of mid-task work. It is not a license to compact on a dirty tree: reach a committed 🟢 first per Path B.)

Format:

```
Continuing from compacted session.

State:
- Repo: <repo-name> @ <branch> @ <commit-hash>
- PR: <url> ("<title>")  [omit if no PR]
- Dev server: :<port> (still running)  [omit if none]
- Working dir: <pwd>
- Plan: <path to plan file>  [if one exists: read it fully and start at its RESUME block]

Last completed: <one-line summary of the last meaningful work in this session>

Next up: <next action, OR "execute the plan at <path> from its RESUME block">
```

The "Last completed" and "Next up" lines are the only ones you cannot get from bash: synthesize them from the conversation. Be specific (file, PR and feature names), not generic. **Any PR or merge gate the resume mentions carries its review state plainly** ("reviewed by <who> at <sha>" or "not reviewed"), never a bare "reviewed", so the post-compact session cannot inherit an unreviewed merge ask as done.

**Then persist it for auto-injection (in addition to printing it).** Right after you emit the resume block, write it to disk so the `SessionStart` (`compact`) hook can re-inject it automatically after the next `/compact`. Pipe the exact block you just printed, verbatim, into the store helper with a quoted heredoc so nothing in it is expanded:

```
bash ~/.claude/hooks/compact-resume-store.sh <<'RESUME_EOF'
<the exact resume block, the same lines you just printed>
RESUME_EOF
```

The helper writes a pending copy and prints a `compact-resume:stored:<nonce>` marker. That marker is how the `PreCompact` hook later confirms the block belongs to THIS session before committing it under the session id, so a parallel session never receives your resume. This step is best-effort and MUST NOT change your output: run it only on the 🟢 path where you actually emit a resume block, and if the helper is missing or errors, ignore it silently. The printed block is still the source of truth.

## Output discipline

Apply **§7** of the include. compact-check specifics on top of the shared rules:

- The clean-exit hand-off is the **Copy-paste resume** (3b). Never emit it alongside a 🟡 or 🔴 verdict, and never tell the user they are "clear to compact" while non-green.
- **PRs the user still needs to merge go last, in normal text** (§7 merge-links-last): after the resume block, one plain markdown line per pending-merge PR with the full `https://github.com/...` URL, outside any fence. This footer is the only thing allowed after the resume block.
- **After a 🟢 verdict, STOP; the turn is over.** The resume block (plus the merge footer, if any) is the LAST thing you emit. Do not pick up the next task, write code, or start a new sub-goal in the same turn. `/compact-check` hands the floor to the user; the next action is theirs, running `/compact`. Work done after the check makes the resume block stale and erases the clean stopping point the check exists to create. The only continuation allowed is the Path B fix loop; once green, you stop there too.
- The resume block stays at or under 10 lines.
