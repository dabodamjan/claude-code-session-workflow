# Session-audit core (shared payload)

> **Referenced by both `~/.claude/commands/compact-check.md` and `~/.claude/commands/end-session.md`.**
> This file holds what the two audit commands share: repo detection, the parallel check suite, the unwritten-chat-content check, the where-to-save heuristic, the state table, and the fix-plan mechanics. Each command reads the sections it names and layers its own verdict symbols, gating and extra checks on top. A change here changes both commands; re-read both after editing.
>
> **Sections:**
> - §1 Detect which repos to check
> - §2 Run these checks in parallel (checks 1 to 9 + the "do not run" list)
> - §3 Unwritten chat content (check 9 detail: triggers + where-to-save heuristic)
> - §4 State table (base shape)
> - §5 Fix-plan mechanics + conflict template
> - §6 Git defaults (what needs the user's explicit yes)
> - §7 Output discipline (shared rules)

---

## §1 Detect which repos to check

Most sessions touch one repo. Some touch two or more (a work repo plus a notes repo, or a parent repo plus a worktree). Before running checks:

1. Identify every distinct git repo touched in this session: the current directory, the working directories of recent Bash calls, and any explicit `cd` you ran. Resolve each to its git root with `git rev-parse --show-toplevel`.
2. De-duplicate by git root.
3. Detect linked worktrees: if `git rev-parse --git-dir` and `git rev-parse --git-common-dir` differ, this checkout is a worktree. Run the checks in the worktree (that is where the branch lives) and name the main checkout in the State table so the reader knows where the branch will be visible.
4. Run the full check suite against each unique repo, in parallel where possible. Output one **State** block per repo.

If only one repo is in play, do this implicitly: single State block, no labeling. If the directory is not a git repo at all, say so in one line and run only checks 8 and 9.

---

## §2 Run these checks in parallel

Send a single message with multiple Bash tool calls. Skip checks that do not apply (write "n/a" in the report, do not fail). Every check is cheap; total budget under 5 seconds per repo.

> **Verdict-symbol note:** the checks below name their severity generically ("a caution-level trigger" / "a blocker"). Each command maps these to its own symbols: `/compact-check` uses 🟢 / 🟡 / 🔴, `/end-session` uses ✅ / ❌. Where a command upgrades a caution-level item to a blocker, the command file says so.

> **Unknown is not green.** Whenever a check cannot be run (tool missing, no network, no upstream, no credentials, command errored), report `unknown` with the reason. Never let a failure to check turn into a passing row.

1. **CWD guard**: `pwd` and `git rev-parse --show-toplevel`. Catches the worktree-vs-repo drift where you think you are in one checkout and are in another.
2. **Git state**: `git status --short` and `git log -1 --pretty=format:'%h %s'`.
3. **Push state**: first `git rev-parse --abbrev-ref --symbolic-full-name @{u}`. If that fails there is **no upstream**: report `unpushed: unknown (no upstream)`, a caution-level trigger; do not report "0 unpushed". If it succeeds: `git rev-list --count @{u}..HEAD` (ahead) and `git rev-list --count HEAD..@{u}` (behind). Ahead > 0 is a caution-level trigger.
4. **Open PR**: if `gh` is not installed, report `PR: unknown (gh not installed)`. Otherwise `gh pr view --json number,title,state,url,updatedAt 2>&1`; a "no pull requests found" result means no PR for this branch; any other error (auth, network, rate limit) is `unknown (<first line of the error>)`. If the branch is pushed and has an open PR, compare the PR's `updatedAt` with the latest commit's timestamp (`git log -1 --format=%cI`): a commit newer than the PR's last update means the description may have drifted (a trigger; fix with `gh pr edit` where the command requires it).
5. **Merge-conflict state**, two sub-checks, because a conflict that already exists is worse than an unpushed change:
   - **Local in-progress conflict (blocker):** `git status` shows unmerged paths, or a merge/rebase is mid-flight: `git rev-parse --git-path MERGE_HEAD`, `rebase-merge`, `rebase-apply` exist (use `--git-path` so worktrees resolve correctly). The unresolved hunks and the resolution plan live only in working memory.
   - **PR-vs-base conflict (caution):** if a PR exists, `gh pr view --json mergeable,mergeStateStatus`. `mergeable: CONFLICTING` or `mergeStateStatus: DIRTY` means the base advanced after the push and the branch no longer merges. If there is no PR but the branch is behind its base, predict it: `git diff --name-only HEAD origin/<base>` and flag any path this branch also changed. Either way, surface it AND propose the fix (template in §5) rather than only reporting "CONFLICTING".
6. **Project checks**: detect what the repo has, run only the fast static ones, and label the rest.
   - `tsconfig.json` present: `npx tsc --noEmit 2>&1 | tail -3`.
   - `package.json` with a `lint` or `typecheck` script: run it with `npm run <script> 2>&1 | tail -3` (or the repo's package manager if a lockfile says so).
   - `Cargo.toml`: `cargo check 2>&1 | tail -3`. `go.mod`: `go vet ./... 2>&1 | tail -3`. `pyproject.toml` or `setup.cfg` with ruff configured: `ruff check . 2>&1 | tail -3`.
   - Test suites (`npm test`, `pytest`, `cargo test`, `go test`) are detected and reported as `detected, not run (test suite)`; never run them here.
   - Report each row as `clean`, `failing: <last line>`, `detected, not run (<why>)`, `unknown: <tool missing / errored>`, or `n/a`. A check that exists but could not run is `unknown`, not `clean`.
7. **Dev server**: `lsof -iTCP -sTCP:LISTEN -nP 2>/dev/null | grep -E 'next-server|vite|webpack|turbopack|nodemon|rails|puma' | head -5`. Match on process name, not port number: on macOS, system services listen on common ports and a port-only check produced false positives.
8. **Background processes**: note any `run_in_background` Bash tasks or in-flight agents in this session. You know this from your own state, not from bash.
9. **Unwritten chat content**: self-audit the last ~10 assistant turns. See **§3** for the trigger list and the where-to-save heuristic. Either sub-check tripping is a trigger (severity per command).

Do **not** run: full test suites, full builds, expensive scans, anything destructive. Those belong in pre-commit or CI. This is a fast audit.

---

## §3 Unwritten chat content (check 9 detail)

Self-audit the last ~10 assistant turns. Two checks; either tripping is a trigger (the command sets the severity: caution in `/compact-check`, blocker in `/end-session` because the chat is about to vanish).

**(a) Substantive deliverables**, any of:
- A multi-stage plan with 3 or more numbered stages (migration plan, rollout plan, ADR draft)
- A research synthesis of 30 lines or more
- A long-form spec or design doc (40 lines or more of structured content)
- An email, blog or copy draft of 20 lines or more
- Code blocks of 40 lines or more that are not throwaway

**(b) Smaller-but-shaping items, regardless of size.** These are what the size-thresholded check misses:
- **Decisions**: a tech, design or convention choice that future work depends on (folder layout, naming convention, file location, env var name, schema change, library choice). Not micro-choices like "use lowercase" for one string.
- **Findings and measurements**: an observation that influences design ("the API returns 403 on new dev apps", "endpoint X has rate limit Y", "dependency Z dropped support for Python 3.10"). Not ephemeral debug data.
- **Conventions agreed**: a name, format or rule chosen for repeat use. Not one-off choices nobody will reference again.
- **Reframes**: a meaningful correction to an earlier doc claim. The earlier doc is now wrong and needs editing; flag it.
- **Followups and known issues**: a problem you noticed but did not fix, which the next session will forget without a written breadcrumb.
- **Cross-repo implications**: work in repo A that implies an action in repo B. That B-side action is itself unwritten content.

For ANY hit in (a) or (b), list it in the State section as `Unwritten:` with the file path it should be saved to.

**Where to save (quick heuristic):**
- **Tech or design decision** → an ADR under `docs/decisions/` (or extend a related existing one)
- **Finding or measurement** → the latest audit doc, or `docs/architecture.md` if it shapes a design rule
- **Convention** → the relevant component's doc, or `docs/conventions.md`
- **Reframe** → edit the doc that held the wrong framing; do not just append
- **Followup or known issue** → the project's open-tasks or status doc (`docs/ship-status.md`, `TODO.md`, an issue tracker)
- **Cross-repo implication** → a written TODO in the other repo, or an issue there
- **In-flight multi-step task** (about to compact or end mid-task with substantial work ahead) → a single self-contained **plan file** (`docs/plans/<name>.md` or the project's equivalent) written so a fresh session can execute it cold: the facts, the decisions already made, the step order, the chosen-vs-rejected options, and a **RESUME block** at the end listing exactly what to do first. A file on disk survives `/compact` verbatim; the conversation summary that replaces lived memory does not. In `/compact-check`, the resume block then just POINTS at this file instead of inlining the plan.

---

## §4 State table (base shape)

Compact table. One line per check. Show the actual values, not "OK / FAIL". If anything is off, show it inline (for example `Working tree  3 modified: foo.ts, bar.tsx, baz.md`).

Base rows (each command adds or removes rows per its own check set and uses its own verdict symbols):

```
CWD          /Users/.../<repo> (matches git root)
Branch       feature/<name> @ <hash>          [worktree of /path/to/main-checkout, if applicable]
Working tree clean
Push state   in sync with origin               [or: 2 ahead | unknown (no upstream)]
PR #<n>      OPEN "<title>"  <full-url>       [or: none | unknown (gh not installed)]
Conflicts    none (PR mergeable, no rebase/merge in progress)
Checks       tsc clean; lint clean; tests detected, not run   [or n/a]
Dev server   none
Background   none
Unwritten    none  (or: 8-stage migration plan → docs/plans/migrate-mailer.md; finding "API 403 on new dev apps" → docs/architecture.md)
```

---

## §5 Fix-plan mechanics + conflict template

A short numbered list. Each item is a concrete action with the file, branch or command involved. Order by what unblocks the goal (compact, or shutdown) fastest. Example:

```
Fix plan:
1. Save the migration plan to docs/plans/migrate-mailer.md (~40 lines).
2. Commit it with the two modified files: "add: mailer migration plan".
3. Push the branch and open a PR (needs your yes, see §6).
```

**Acting on the plan:** lead with which items you will do immediately (writing files, saving unwritten content to disk) and which need the user's explicit yes (see §6: commits, pushes, PRs, rebases, branch deletion). Do the immediate ones in the same turn. Ask for the rest once, with the exact commands, and wait. Do not be a verification loop that only lists problems; close the ones you are allowed to close. **Do not emit the resume block or green-light while items remain.** After fixes land, re-run only the checks that would have flipped and report the new verdict in a single short banner.

### CONFLICTING / DIRTY PR (base advanced after the branch was pushed)

Prefer a merge of the base into the branch when the PR will be squash-merged: `git merge origin/<base>`, resolve once, then a normal `git push`. The squash discards the merge commit, so the base history stays linear anyway, and no history is rewritten. This is merging the base INTO the working branch, which §6 permits after the user's yes; it is not merging the PR, which stays the user's action. Use a rebase only when the PR is merged with a merge commit or rebase, or when the user asks for one.

Merge template (steps 2 and 4 need the user's yes):

```
Fix plan, resolves a CONFLICTING PR:
1. git fetch origin <base>
2. git merge origin/<base>, resolving each conflict.
3. Verify: no conflict markers remain, and git diff origin/<base> --stat shows only the intended files.
4. git push
5. Re-check: gh pr view <n> --json mergeable,mergeStateStatus, expect MERGEABLE / CLEAN.
```

Rebase template (every step past 1 needs the user's yes, because it rewrites a pushed branch):

```
Fix plan, resolves a CONFLICTING PR:
1. git fetch origin <base>
2. git rebase origin/<base>, resolving each conflict.
3. Verify: no conflict markers remain (grep '^<<<<<<<\|^=======\|^>>>>>>>'), and git diff origin/<base> --stat shows only the intended files.
4. git push --force-with-lease. PAUSE first: a force-push rewrites the pushed branch; state the command and the branch, then wait for the explicit yes.
5. Re-check: gh pr view <n> --json mergeable,mergeStateStatus, expect MERGEABLE / CLEAN.
```

---

## §6 Git defaults (what needs the user's explicit yes)

These commands never assume standing permission. In every session:

- **Commit locally** only when the user has said so in this session (an explicit "commit it", or a yes to a fix plan that names the commit). Stage explicit paths, never `git add -A`.
- **Never push, open a PR, rebase, force-push, reset, merge a base branch into the working branch, or delete a branch** without the user's explicit yes in this session, given after you stated the exact command and target. A yes to one of these does not carry over to the next one, and never carries over from an earlier session.
- **Never merge a PR.** Merging the PR into its base is the user's action, from wherever they merge. Merging the base INTO the working branch to resolve a conflict (§5) is allowed after the user's yes to that command; it changes only the working branch.
- Writing files to disk (saving a plan, a decision, a draft) is always allowed; that is the point of these commands.

If a user wants a looser default (for example "always push feature branches"), that belongs in their own CLAUDE.md, not in these commands.

---

## §7 Output discipline (shared)

- **Lead with the recommendation banner.** State table second; then either the Fix plan (non-clean verdict) or the clean-exit hand-off (resume block for `/compact-check`, green-light checklist for `/end-session`). The verdict is always above the fold.
- **Never emit the clean-exit hand-off alongside a non-clean verdict.** The resume block or green-light is a confirmation that everything passed; emitting it with loose ends papers over work the next session inherits. Non-clean → do the work to reach clean first, then the hand-off.
- No preamble, no "I'll now run the checks" narration. Jump straight to the verdict.
- Run the checks without asking permission. Same for re-checks after fixes land. Git actions follow §6.
- If `gh` is not installed or there is no remote, say "unknown" or "n/a" as §2 specifies; do not error, and do not go green.
- Keep total output under about 30 lines per pass (initial audit or recheck). Fix-plan items can extend it slightly.
- **Merge links go LAST, in normal text.** Every PR the user still needs to merge is listed at the very end of the message, after the green-light checklist or resume block, as plain markdown lines with the full `https://github.com/...` URL, outside any fenced code block (fences kill clickability). One line per PR; nothing after the list.
