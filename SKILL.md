---
name: chandoff
description: Use before compaction (manual `/compact` or imminent auto-compact) to write a project-tuned compaction rubric while full context is still live. Drafts the rubric, lets the user edit, writes a durable lore handoff file, and emits a paste-ready `/compact <instructions>` block. Accepts free-form trailing arguments (e.g. `/chandoff focus on 762 W2 + drop QA detail`) which steer the draft. Triggers: `/chandoff`, "handoff", "wrap up", "pre-compact this".
---

# /chandoff

User arguments (may be empty): `$ARGUMENTS`

## Goal

Write a rubric the compactor will use to compress this session well. The base compactor already preserves file paths, SHAs, function names, errors, decisions, TODOs, and recent turns — **do not re-specify those**. The rubric adds only what base will not do by default.

## The five legitimate rubric contents

1. **Compression ratios** — which threads collapse to one line.
2. **Pointers** — threads that redirect to `lore/<file>` instead of being re-summarized.
3. **Drop list** — project-specific noise to discard.
4. **Verbatim anchors** — specific SHAs / file:line / IDs that must appear unchanged.
5. **Uncertain** — items you are not sure are load-bearing; surfaced for user correction.

Anything else belongs in the lore file, not the rubric.

## Inputs

- `$ARGUMENTS` — per-invocation steering. Treat as authoritative when it conflicts with defaults.
- `<project-root>/.claude/handoff-defaults.md` — read if present. Contains project conventions (lore path, ID patterns, common noise). Optional.
- Live session context — you have it; the compactor will not.

## Template

```
Compaction rubric (chandoff <YYYY-MM-DD>):

KEEP IN FULL:
- ...

COMPRESS + POINT:
- <thread> → see <lore/file>

DROP:
- ...

UNCERTAIN:
- ...
```

## What to do

Use judgment. Rough shape:

- Draft the rubric from live context, honoring `$ARGUMENTS` and any defaults file.
- Show it to the user, ask for edits, unless `$ARGUMENTS` says `--quick` / "no review" or context is critically high.
- After confirmation, write `lore/handoff_<YYYY-MM-DD>_<slug>.md`. The file should contain: branch, working dir, session focus, the confirmed rubric, a short git state block (`git log -5 --oneline` + `git status --short`), a "next action" line, and — if a prior `lore/handoff_*.md` exists — a `Previous: <path>` link and an incremented sequence number in the filename or header.
- End your turn with a fenced code block containing `/compact <rubric flattened to text>` as the last thing in the message. Nothing after it.

The git state and chain link go in the **lore file only**, never in the rubric. The compactor doesn't need them; the next-session safety net does.

## Anti-patterns

- Re-specifying base behavior (file paths, SHAs, TODO preservation).
- Long rubrics (>10 items in any section means over-specification).
- Describing what the session did (that is the compactor's job).
- Skipping UNCERTAIN because you feel confident.
- Writing the lore file before user confirms (unless --quick).
