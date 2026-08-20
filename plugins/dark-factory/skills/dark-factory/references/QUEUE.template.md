# QUEUE — the ranked dark-factory work order

The factory's single entry point (planner-maintained). STATUS banners on task files remain the
truth for what's done; this file only orders what's OPEN. The factory takes from the top, skips
gated rows (noting why), and treats FILLER rows as parallel/anytime slices. Last groomed:
**YYYY-MM-DD**.

## Ready — take from the top

| # | Task | Size | Tier | Note |
|---|------|------|------|------|
| 1 | `tasks/<date>-<slug>.md` | S–M | full | one line of orientation the loop needs before opening it |
| 2 | `tasks/<date>-<slug>.md` | M | full | dependencies / what it unblocks |

The **Tier** column mirrors the `Verify:` line inside each task file (planner-set at
filing; the task file is the truth, this column is orientation). `full` = panel per
risk tier; `diff` = panel scoped to the diff; `suite` = suite green + planner audit —
bookkeeping-class diffs only, nothing the suite imports, pins, or executes. Absent
`Verify:` means `full`. The factory may verify harder, never softer.

## Sprint — N tasks, one verification pass (optional)

> **Sprint:** `tasks/<a>.md`, `tasks/<b>.md`, `tasks/<c>.md`
> Disjoint file sets: <a touches only X, b only Y, c only Z>. Failure modes
> independent: <statement>. Strictest declared tier: <tier> — the batch verifies at
> this level, no exceptions.

Only for tasks with disjoint file sets AND independent failure modes — both stated
above; if either claim is false, the rows run solo. Dispatch stays per-task; the panel
(one pass over the union diff, brief carries the diff↔task map), suite run, verdict,
and release are shared. On any red the panel names the task and the batch splits — a
partially-red batch never ships.

## Filler — anytime, parallel-safe

- `tasks/<date>-<hygiene-or-debt>.md` (independent XS–S slices; safe to interleave)

## Gated — do NOT start (named gate must open first)

| Task | Gate |
|------|------|
| `tasks/<date>-<slug>.md` | DECISIONS **D<n>** open / real data missing / hardware not arrived |

## Grooming rules
Planner re-ranks after each factory run + banners; a row leaves this file only by shipping
(banner) or being explicitly parked. If the factory finds the top row blocked in practice, it
takes the next and records why in its wrap-up.
