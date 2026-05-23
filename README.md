# chandoff

A Claude Code skill that **tunes the base compaction mechanism** instead of working around it.

When your context fills up and `/compact` fires (manual or auto), Claude's built-in summarizer does a generic best-effort pass. It preserves file paths, SHAs, decisions, and TODOs — but it doesn't know which threads in *your* session are load-bearing vs. exploratory, which detail is already durably recorded elsewhere, or which tool output is safe to drop.

`/chandoff` runs **before** compaction, while you still have full context. It drafts a project-tuned rubric (KEEP / COMPRESS / DROP / POINTERS), lets you edit it, writes a durable handoff file as a safety net, and emits a paste-ready `/compact <instructions>` block.

## How it differs from other handoff skills

Most "handoff" skills produce a **narrative document for the next session** — essentially an alternative to compaction. They assume compaction is lossy and write a parallel artifact.

`/chandoff` produces a **rubric for the compactor itself**. The lore file is just a safety net; the primary product is the `/compact` instructions that steer the built-in summarizer to do a better job. You stay in the same session.

| | Most handoff skills | `/chandoff` |
|---|---|---|
| Primary output | Narrative doc | `/compact <instructions>` block |
| Relationship to `/compact` | Parallel artifact | Steers it |
| Pitch | "Compaction is lossy → write a doc" | "Compaction is tunable → tell it how" |
| Best when | Session ending, fresh start next | Mid-session, hitting threshold, want to keep going |

## What the rubric actually contains

Five things, deliberately narrow — anything else is either redundant with the base compactor or belongs in the lore file:

1. **Compression ratios** — which threads collapse to one line.
2. **Pointers** — threads that redirect to a file path instead of being re-summarized.
3. **Drop list** — project-specific noise to discard (tool stdout, intermediate git/ssh, resolved errors).
4. **Verbatim anchors** — specific SHAs / file:line / IDs that must survive unchanged.
5. **Uncertain** — items the model isn't sure are load-bearing, surfaced for user review.

The skill explicitly does **not** re-specify base behavior ("preserve file paths", "keep SHAs"). The base compactor already does these. Re-specifying them is wasted rubric tokens and a slower compaction.

## Install

```bash
mkdir -p ~/.claude/skills/chandoff
curl -fsSL https://raw.githubusercontent.com/<your-name>/chandoff/main/SKILL.md \
  -o ~/.claude/skills/chandoff/SKILL.md
```

Or clone and symlink:

```bash
git clone https://github.com/<your-name>/chandoff ~/code/chandoff
ln -s ~/code/chandoff ~/.claude/skills/chandoff
```

That's it. Type `/chandoff` in any Claude Code session.

## Usage

```
/chandoff
```

Drafts a rubric, asks you to confirm or edit, writes the lore file, emits the `/compact` block.

```
/chandoff focus on campaign state, drop QA detail entirely
```

Free-form trailing args steer the draft. Treated as authoritative when they conflict with project defaults.

```
/chandoff --quick
```

Skip the review step. Useful when context is critically high and the round-trip risks auto-compact firing first.

## Optional: project defaults

Create `<project-root>/.claude/handoff-defaults.md` to pre-load project conventions — lore directory path, task/campaign ID patterns, common noise to drop, common COMPRESS+POINT redirects. The skill reads it if present; works fine without.

Minimal example:

```markdown
# Handoff defaults

Lore: lore/notes_<YYYY-MM-DD>.md and lore/handoff_*.md
Tasks: tasks/TASK_NNN_*.md

Common DROP:
- training stdout once smoke passed
- intermediate ssh/rsync output
- sub-agent progress chatter (keep final verdicts only)

Common COMPRESS → POINT:
- multi-agent QA passes → lore/notes_<date>.md §<n>
- benchmark eval tables → runs/<id>/result.md
```

## What the skill produces

**1. A lore handoff file** — `lore/handoff_<YYYY-MM-DD>_<slug>.md` containing branch, working dir, session focus, the rubric, a short git state block (`git log -5 --oneline` + `git status --short`), a "next action" line, and a `Previous:` link if a prior handoff exists (chains across sessions).

**2. A paste-ready `/compact` block** — as the last thing in the assistant's message, in a fenced code block. Select-all-copy-paste to compact with the rubric as instructions.

The lore file is the safety net. Compaction is lossy by design; the lore file is not. If the next session has any doubt about re-entry, reading the most recent `lore/handoff_*.md` restores context.

## Why this might not be for you

- If you prefer to end sessions and start fresh with a doc to paste in, **the narrative-doc handoff skills are a better fit** (e.g. [REMvisual/claude-handoff](https://github.com/REMvisual/claude-handoff)).
- If your sessions are short enough to never hit compaction, you don't need this.
- If you don't have a `lore/`-style notes convention, the safety-net half of the skill is less useful — you'd be using only the rubric half.

## Background

The skill came out of noticing that pasting a structured "KEEP / COMPRESS / DROP" rubric to `/compact` visibly speeds up compaction. Investigating *why* led to the framing: the base compactor's built-in instructions already cover most of what people typically write in custom rubrics, so the rubric should contain only the **delta** — the five things above. Encoding that as a skill means the model drafts the delta from live context, the user just corrects it, and the redundancy guard (anti-patterns section in SKILL.md) prevents drift back toward re-specifying base behavior.

## License

MIT. Take it, fork it, change the framing if your project needs a different shape.
