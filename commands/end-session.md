---
description: Pre-shutdown audit. Captures unwritten chat content, drives the repo to committed-pushed-in-a-PR (with your yes for each git action), and green-lights only when nothing of value lives in the working tree or chat alone.
disable-model-invocation: true
---

# /end-session

Terminal-state audit. Sibling to `/compact-check`, but the session ends after this; in remote or web environments the container is reclaimed. So the hard requirement is: **nothing of value may be left only in the working tree, only on a local branch, or only in chat.** Everything is committed, pushed, surfaced through a PR, or explicitly handed back to the user.

Where `/compact-check` is a safety net before lossy summarization, `/end-session` is a green-light before walking away.

**Shared payload lives in `~/.claude/includes/session-audit-core.md`** (the same file backs `/compact-check`). Read it and apply the sections named below; this file carries only the end-session-specific gating, verdict symbols, extra checks, green-light checklist and overrides.

## Detect which repos to check

Read `~/.claude/includes/session-audit-core.md` and apply **§1**.

## Run these checks in parallel

Read `~/.claude/includes/session-audit-core.md` and apply **§2** (checks 1 to 9 and the "do not run" list) and **§3** (the check-9 unwritten-content detail). Then run the **end-session-only checks 10 to 13** below. Total budget under 5 seconds per repo.

**end-session verdict mapping for §2 and §3.** The session is ending and the container may be reclaimed, so several caution-level items from `/compact-check` become hard **❌** blockers here:
- Severity symbols are ✅ / ❌.
- Check 3 (push state): commits ahead of the upstream, or no upstream at all, is a **❌**: unpushed work may be gone with the container.
- Check 4 (open PR): a pushed branch with no open PR is a **❌** unless the user waived PRs for this session. A commit newer than the PR's last update means the description drifted; fix with `gh pr edit` before green-lighting. An open PR that matches its commits is not a ❌, but it IS surfaced in the green-light checklist as a pending-merge reminder with the full URL. `unknown` (gh missing, network or auth error) is reported as unknown and blocks the green-light; say what could not be checked.
- Check 5 (merge-conflict state): a local in-progress conflict is **❌**; PR-vs-base `CONFLICTING` / `DIRTY` is **❌** (resolve before walking away, do not defer).
- Check 6 (project checks): a failing static check is a **❌**. `detected, not run` is informational. `unknown` blocks the green-light.
- Check 8 (background processes): any still-running background task or in-flight agent is a **❌**: wait for it, stop it, or surface it before walking away.
- Check 9 (unwritten chat content): either sub-check tripping is a **❌** (at end-session the chat is about to vanish).

**end-session-only checks:**

- **10. Branch hygiene**: confirm the current branch is NOT `main` or `master`. Direct work on the default branch is a ❌ unless the user explicitly authorized it this session.
- **11. Index sync** (only if `.md` files were created, renamed, moved or deleted this session AND the repo keeps index files such as a `docs/README.md` or folder READMEs): list the affected folders and grep their indexes. Flag orphans (file on disk, not in the index) and stale entries (in the index, not on disk).
- **12. Status doc** (only if the repo has an in-flight-state doc such as `docs/ship-status.md`, `STATUS.md` or `TODO.md`): reconcile it with what actually shipped this session. Mark done items done, add new followups, retire stale ones. A stale status doc at end-of-session is a ❌.
- **13. Scratch sweep**: list recently modified files in `/tmp` and in the session's scratch directory, if it has one. Flag anything created this session that holds substantive content (drafts, specs, long-form copy, scripts the repo needs). Move it into the repo before pushing. Container reclaim eats scratch space.

## Output flow, gated on the verdict

Unlike `/compact-check`, there is no resume block; the session is ending. The output is a green-light checklist. Either the user gets ✅ "Safe to end session" or a blocker list.

**Three flow paths:**

**Path A: ✅ on first pass.** Output: Recommendation banner → State → Green-light checklist. Done.

**Path B: ❌ on first pass with fixable items.** Output: Recommendation → State → Fix plan. Then act:
1. Propose the smallest set of fixes that flips the verdict to ✅. Lead with the recommendation; do not bounce open-ended "should we?" back. Do the file writes immediately (save unwritten content, update the status doc, fix indexes).
2. For every git action follow **§6** of the include: commit when the user has said so in this session; push, PR creation, rebase and branch deletion each need the user's explicit yes to the exact command, given in this session. Ask once, listing the exact commands (`git push -u origin <branch>`, `gh pr create --title "..." --body-file ...`), and wait. After a push, surface the full PR URL on the same line as any merge mention.
3. Execute the approved fixes.
4. **Re-run** the relevant checks (whichever would have flipped). Report the new verdict in a single short banner.
5. If ✅, emit the Green-light checklist. If still ❌, loop back to step 1 with the remaining items.

**Path C: ❌ with truly in-flight work** (background build, mid-debug fix loop, unfinished agent, work the user explicitly wants to keep iterating on). Do NOT force a fake green-light. Surface the in-flight state, say explicitly that ending now would lose working memory or partial work, and stop. The user decides whether to wait, stop it, or accept the loss.

## Sections, same shape, conditional emission

### 1. State

Use the base table from **§4** of the include, with ✅/❌ symbols. end-session adds rows for its extra checks:

```
CWD          /Users/.../my-app (matches git root)
Branch       feature/end-session-cmd @ 4ab12cd (not main)
Working tree clean
Push state   in sync with origin
PR #42       OPEN "add: /end-session command"  https://github.com/you/my-app/pull/42
PR drift     none (PR updated after the last commit)
Conflicts    none
Checks       tsc clean; lint clean; tests detected, not run
Background   none
Indexes      n/a (no .md changes)
Status doc   n/a
Scratch      clean
Unwritten    none
```

If anything is off, show it inline.

### 2. Recommendation

One banner line, one short reason. Pick exactly one. **In multi-repo mode, the worst case wins.**

- ✅ **Safe to end session**: everything committed, pushed, in a PR; no in-flight work
- ❌ **Not safe to end yet**: one-line summary of what is loose

If ❌, the Fix plan follows.

**Default ❌ triggers** (any one fails the audit):
- Modified or untracked files in the working tree (excluding known noise)
- Commits ahead of the upstream, or no upstream
- Pushed branch with no open PR (unless the user waived PRs this session)
- Open PR with a description older than the latest commit
- Current branch is main/master with direct work on it (not user-authorized)
- Background tasks still running, or in-flight agents
- Failing type check or lint
- Substantive unwritten chat content (deliverables OR shaping items) per §3 of the include
- Stale status doc per check 12
- Substantive files in scratch space that belong in the repo per check 13
- Index drift per check 11
- Any check reporting `unknown`

### 3a. Fix plan (only when the verdict is ❌)

Use the fix-plan mechanics and the conflict template from **§5** of the include. Order items by what unblocks shutdown fastest. Example:

```
Fix plan, flips ❌ → ✅:
1. Save the "Library/ subtree" decision to docs/decisions/005-library-subtree.md (~15 lines).
2. Update docs/ship-status.md: PR #41 shipped, followup "reconcile script" added.
3. Commit both: "add: ADR-005 library subtree convention".   [needs your yes]
4. git push -u origin feature/library-subtree                  [needs your yes]
5. gh pr create --title "add: ADR-005 library subtree convention" --body-file /tmp/pr.md   [needs your yes]
6. Paste the PR URL back in the recheck banner.
```

After listing the plan, say which items run immediately (file writes) and which wait for your yes (every git action). Then act on the immediate ones in the same turn.

After fixes land and the git actions are approved and done, re-check and report the new verdict in a single short banner (for example "Recheck → ✅: ADR-005 saved, branch pushed, PR #43 open at <url>"). Then emit the Green-light checklist.

### 3b. Green-light checklist (only when the verdict is ✅)

A short fenced block confirming each gate:

```
Safe to end session.

✅ Working tree clean
✅ Branch pushed, in sync with origin
✅ PR #42 open: https://github.com/you/my-app/pull/42
✅ PR description matches the latest commit
✅ No background tasks, no in-flight agents
✅ No substantive unwritten chat content
✅ Indexes match the filesystem        [omit if n/a]
✅ Status doc reconciled              [omit if n/a]
✅ Scratch space clean
```

**Then, AFTER the fenced block, end the message with the merge footer in normal text** (merge-links-last, §7 of the include; links inside a fence are not clickable):

> Next: merge [PR #42: add: /end-session command](https://github.com/you/my-app/pull/42), then `/archive-session` to close this session out.

One line per PR this session needs merged, full `https://github.com/...` URL every time, nothing after the list. Omit checklist lines that do not apply to the repo; never invent green checks for things the repo does not have. The green-light block stays at or under 15 lines.

## Output discipline

Read `~/.claude/includes/session-audit-core.md` and apply **§7**. end-session specifics on top of the shared rules:

- The clean-exit hand-off is the **Green-light checklist** (3b), followed by the merge footer as the message's final lines. Never emit it alongside a ❌ verdict.
- Every git action waits for the user's yes (§6 of the include). Never merge.
- If `gh` is not installed or there is no remote, say "unknown" / "n/a" and do not go green. Surface the no-remote case loudly: an unpushed branch with no remote is data that lives only on this machine or container.
- The green-light block stays at or under 15 lines.
