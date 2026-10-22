# claude-code-session-workflow

A public kit that installs a session workflow into someone's Claude Code: four slash commands, a shared audit include, the compact-resume hooks, an optional terseness enforcer, a CLAUDE.md block, and Karabiner chords. Read `README.md` for what it is and `INSTALL.md` for how it installs. `docs/README.md` indexes the design docs.

## Layout

- `commands/` the four slash commands (installed to the user's `commands/` directory)
- `includes/session-audit-core.md` the payload `/compact-check` and `/end-session` share
- `hooks/` the compact-resume trio and the terse hooks; each script is self-contained and fail-silent
- `claude-md/tldr-block.md` the marked block the installer appends to the user's CLAUDE.md
- `karabiner/` `build.py` generates both rule files; never edit the JSON by hand
- `install/` `install.sh` (check / plan / apply / verify / uninstall) plus the three Python helpers it calls: `merge-settings.py` (hook registrations), `update-claude-md.py` (the marked block), `manifest.py` (the install record uninstall replays)
- `tests/run.sh` the whole suite, in a throwaway HOME

## Rules for changes

- This repo is public. No private paths, personal data, or internal tooling vocabulary anywhere: not in code, docs, commits or PR text.
- Only verifiable claims. Behaviour seen on the author's machine but not in the Claude Code docs is labelled as such in the docs.
- One tldr policy: 10 lines / 130 words. It lives in `claude-md/tldr-block.md` and in the defaults of `hooks/terse-gate.sh`; change both or neither.
- Changing a chord: edit `karabiner/build.py`, run it, commit the regenerated JSON.
- Changing a hook registration: edit `CORE` / `TERSE` in `install/merge-settings.py` and the `FILES` list in `install/install.sh` if a file is added.
- Run `./tests/run.sh` before every PR. It must end with `failed: 0`. Every behaviour fix gets a test in the same change.
- Commit messages: lowercase, imperative, type prefix (`add:`, `fix:`, `update:`, `docs:`).
- Voice in docs: first person, plain sentences, no em dashes, no emojis, no hype.
