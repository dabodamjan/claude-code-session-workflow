---
description: Post-merge close-out. Verifies this session's PRs are actually merged, then asks the desktop app to archive this session. Desktop app only.
disable-model-invocation: true
---

# /archive-session

The last step of the session lifecycle: `/end-session` → the user merges the PRs from the GitHub UI → `/archive-session`. Invoking this command IS the user's request to archive, but the archive only happens after the merge gate below passes. Never archive with this session's PRs still open.

## 0. Capability check (do this first)

Archiving needs the session-management tools the Claude Code desktop app gives Claude for its own Code-tab sessions (the desktop docs describe them as listing, renaming and archiving sessions, with an approval card before an archive in Manual mode). Check whether such a tool is available in this session: look for a session-management tool whose name includes `archive_session` (it may be a deferred tool you have to load first).

If no such tool exists (terminal CLI, VS Code extension, cloud session), say so in one line and stop:

> This session has no session-management tool, so I can't archive it from here. Archive or close it from where you started it (the desktop app sidebar, or exit the terminal).

Do not pretend to archive, and do not run the merge gate for nothing.

## 1. Collect this session's PRs

- Every PR this session opened or pushed to (you know these from the conversation; the `/end-session` green-light named them).
- Plus `gh pr view --json number,state,url 2>/dev/null` on the current branch, in case one exists that the conversation did not surface.
- NOT in scope: pre-existing open PRs from other sessions. Only PRs this session touched.

If `gh` is not installed or errors, the gate result is `unknown`: say what could not be checked and stop. Do not archive on an unknown.

## 2. The merge gate

For each PR: `gh pr view <n> --repo <owner>/<repo> --json state,url`.

- `MERGED` → pass
- `OPEN` → blocker
- `CLOSED` without merge → a blocker of a different kind: the work was discarded. Surface it and ask. Closed-not-merged is a decision the user made or a mistake, never silently treated as done.

Quick sanity alongside: `git status --short` and `git status -sb`. A dirty tree or unpushed commits at archive time means `/end-session` was skipped or work happened after it. Stop, say so, and point at `/end-session` instead of archiving.

## 3. Outcome

**Gate fails →** do NOT archive. One line per blocker, then end the message with the PRs still to merge as normal clickable markdown links, last, outside any fenced block (merge-links-last rule, §7 of `~/.claude/includes/session-audit-core.md`).

**Gate passes** (all merged, or the session opened no PRs, and the tree is clean) **→** archive:

1. State the outcome in one line first ("All N PRs merged. Archiving this session."), because the conversation ends after the tool call.
2. Call the archive tool for this session (on the author's desktop app the tool takes `session_id: "self"` and a short `reason`; follow the tool's own schema if it differs). Invoking this command authorizes archiving after the checks pass. In Manual mode the desktop app shows an approval card before archiving; in Auto or Bypass permissions mode it does not and may archive immediately, so the merge gate above and your one-line outcome statement are the only checks. Do not re-ask in chat.

Worktree cleanup is handled by the archive itself. Do not delete local branches; merged branches are cleanup for another day, not this command's job.
