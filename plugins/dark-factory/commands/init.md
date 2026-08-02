---
description: Build the factory in this repo — scaffold .dark-factory/, then fill the config with the owner
---

Initialise dark-factory in the current repository. Two phases — mechanical, then judgment.

## Phase 1 — scaffold (script, no guessing)

Run the plugin's init script against the current repo root:

- Claude: `bash "${CLAUDE_PLUGIN_ROOT}/tools/init.sh"`
- Kimi: `bash "$KIMI_PLUGIN_ROOT/tools/init.sh"`

It creates `.dark-factory/config.json` from the template, `tasks/QUEUE.md` and
`tasks/DECISIONS.md` from their templates, and gitignores the runtime files —
idempotently: anything that already exists is kept, so it is safe on a repo that
was partially set up by hand.

## Phase 2 — fill the config (interview, not invention)

The scaffold's values are placeholders. Now make them real:

1. Inspect the repo: test runner and how it's invoked, version file, changelog,
   fixtures, whether there's a UI. Draft real values over the template —
   `commands.test` is the one that MUST be right (the commit gate trusts it);
   the lane map (`lanes.planner_owns` / `lanes.shared`) is the one that MUST
   match how the owner actually works. The key-by-key reference is the plugin's
   `skills/dark-factory/references/config.md`.
2. Show the owner the filled config, explaining each guess and flagging every
   value you could not ground in the repo. Get explicit confirmation, then write
   `.dark-factory/config.json`.
3. If the owner has tasks in mind, seed the first ranked rows in `tasks/QUEUE.md`;
   otherwise leave the template's example row for the planner to replace.

Then STOP. Setup and the first factory run should not share a session's worth of
guessing — the first run starts clean with `/dark-factory` (Kimi: `/skill:dark-factory`),
which reads the config, arms, and takes the top queue row.
