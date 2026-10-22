---
description: Short orientation summary of THIS session. One-line topic, what is done, what is in progress, what is left, and repo/disk state. For re-orienting when juggling many parallel sessions.
disable-model-invocation: true
---

# /session-status

When you run many sessions in parallel you lose track of what each one is doing. This command re-orients you fast: it summarizes **this session's** state from the conversation so far, not the whole repo. Keep it short; this is a glance, not a report.

## Sources (in priority order)

1. **The conversation itself**, the primary source. What was this session asked to do, what got done, what is mid-flight, what is still open. Derive honestly from the actual transcript; do not invent progress and do not claim something is done when it is not.
2. **Live todo list**: if this session has an active todo list, use its checked and unchecked items as the spine of Done / Left.
3. **Running background work**: any background agents, background shells or workflows still executing. Name them and their state.
4. **Repo/disk state**: run these once, fast, for the session's primary repo (if the session touched several repos, report the main one and name the others in one line):
   ```
   git status --short | wc -l                                   # uncommitted files
   git rev-parse --abbrev-ref HEAD                              # current branch
   git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null   # upstream, if any
   git rev-list --count @{u}..HEAD 2>/dev/null                  # unpushed commits (only meaningful if the line above succeeded)
   ```
   If there is no upstream, report `unpushed: unknown (no upstream)`, not 0. This tells you whether work is safe on disk or still only in chat.

## Output format

Keep it tight; aim for under 25 lines. Lead with the one-line topic; that is what tells you *which* session this is at a glance.

```
## Session Status: <one line: what this session is about>

**Repo:** <repo> · <branch> · <N uncommitted · M unpushed | unpushed unknown (no upstream) | clean>
<if several repos were touched: one line naming the others>

### Done
- <completed items, most recent first; concrete, not vague>

### In progress
- <the thing being worked on right now>
- <any running background agent / task / workflow and its state>

### Left
- <what remains; from the todo list if present, else inferred from the ask>

**Next:** <the single most useful next action>
```

## Rules

- **Be honest about state.** If nothing is committed and it only lives in chat, say so plainly; that is exactly the risk this command surfaces. If a step failed or was skipped, it goes in the summary, not hidden.
- **No filler.** If a section is empty, write a single dash rather than padding.
- **Don't do the work.** This command reports state; it does not continue the task. End after the summary.
- **If the session is essentially empty** (just started, no real work yet), say that in one line instead of forcing the template.
