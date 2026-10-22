# 001: The keyboard shortcuts live in Karabiner, not in Claude Code

Status: accepted (2026-08-04, revalidated against the docs 2026-10-22)

## Context

I wanted one key for `/compact-check`, one for `/compact`, one for `tldr`, and later one each for `/end-session` and `/archive-session`. The first question was whether Claude Code itself could bind them.

Two facts, both checked against the current docs:

1. **No default shortcut compacts.** The interactive-mode reference lists every built-in shortcut; none runs `/compact`.
2. **No binding can type text or run a slash command.** `~/.claude/keybindings.json` maps keystrokes to built-in actions in namespaces such as `app:`, `chat:`, `autocomplete:`, `select:`. The full action list contains nothing that inserts text or invokes a command. So a slash command cannot be bound inside Claude Code, in any surface.

## Decision

The binding lives one layer down, at the HID level, as a Karabiner-Elements complex modification: Right Option plus a key types the command text, waits, presses Escape, then Enter. The receiving application only sees keystrokes, so the same rule reaches the desktop app, any terminal and VS Code. I have verified the Escape-then-Enter sequence on the desktop app; the other two surfaces receive the same keys but I have not tested them.

Right Option specifically, so that left Option stays free for special characters and for Claude Code's own Option+O / Option+P / Option+T bindings. The `, . /` cluster sits under the right hand's resting position, which keeps the three frequent shortcuts one-handed. The two rare ones (`'` and `\`) sit further out on purpose: a shortcut that must never fire by accident should cost a reach.

## What the shortcut types

One shortcut, keystroke by keystroke:

```
you press         Right Option + ,
Karabiner types   /compact-check          the slash opens Claude Code's autocomplete menu
400 ms later      Escape                  closes the menu; Enter does not submit while a suggestion is highlighted
then              Enter                   submits the command
```

The `/compact` shortcut adds a pause and a queued `go` + Enter after the first Enter (see below).

## Consequences

- **macOS only.** Karabiner-Elements is a macOS tool. On Linux the equivalent is a text-expander or a keyboard daemon; the kit does not ship one.
- **Layout-dependent.** The rule names physical keys (`comma`, `period`, `slash`, `quote`, `backslash`) and types characters by key name, which matches a US-style layout. Other layouts regenerate the rule with their own key codes via `karabiner/build.py`.
- **It types blind.** Karabiner cannot see the input box. If text is already there, the command is appended to it. The shortcuts assume an empty line.
- **Escape before Enter.** Typing `/` opens the command menu, which puts Claude Code in the `Autocomplete` keybinding context. That context binds Tab (accept), Escape (dismiss), Up and Down. The keybindings reference says plain Enter does not submit while a suggestion is highlighted, so a synthetic Enter can leave the command typed but unsent; the interactive-mode reference adds that in fullscreen rendering the list opens with no row highlighted and Enter submits as typed. Escape first covers both cases. Not Tab: Tab accepts whatever entry is highlighted, and `/compact` prefix-matches both `/compact` and `/compact-check`, so Tab could run the wrong command. Escape does not care what is highlighted.
- **A delay is needed between typing and submitting.** Karabiner fires a `to` array in about a millisecond; the app has not processed the text when the next key lands. `to_delayed_action` with a 400 ms delay gives the gap. `hold_down_milliseconds` does not: it sets the key-down/key-up interval of the single event it is attached to.
- **The `/compact` shortcut types a trailing `go`.** The post-compact hook injects the resume block as context, which does not start a turn. The shortcut types `go` + Enter after the compact Enter. Claude Code queues messages typed while it is busy, so the `go` fires whenever the compaction finishes, and no fixed delay has to guess the compaction's duration. The 1200 ms `vk_none` pause before it is belt and braces; the queue does the real work. That a message typed during a compaction is queued is something I observed on my own machine, not something the docs state.

## Alternatives considered

- **Claude Code keybindings.** Not possible; see context.
- **Terminal-specific snippets** (iTerm2 triggers, Ghostty keybinds that send text). They work in one terminal, not in the desktop app, and not in VS Code. The HID layer covers all three.
- **A text expander** (typing `;cc` expands to `/compact-check`). Works, but still needs the Escape-then-Enter sequence and a delay, which expanders generally do not provide.
- **A UserPromptSubmit hook that rewrites a short alias into the command.** Hooks can block or add context to a prompt; they cannot replace the prompt with a slash command.
