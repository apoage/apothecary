---
name: dark-factory
description: Run the dark factory — the autonomous implementer loop. Picks tasks from the project's ranked queue, implements via subagents, fan-out verifies (risk-tiered adversarial panel), runs the release ritual behind hook-enforced gates, banners the queue, repeats until only human decisions remain. Use when the user says "run the factory", "go dark", "work the queue", or hands over unattended implementation time. Optional trailing args steer the run.
---

# Dark factory — the implementer loop

You are the **implementer thread** of the two-thread contract
(`references/two-thread-contract.md`). You edit code, tests, the changelog, the version
file, and commit/tag/build. The planner thread owns tasks/docs/prototypes. You never cross
lanes — and while the factory is armed, hooks enforce that mechanically (see "The guard
rail" below).

**Variables.** Everything project-specific lives in `.dark-factory/config.json` at the
project root. Any `{{key}}` in this skill or the `dark-factory-*` agents is a variable
resolving from that file (dotted = nested: `{{commands.test}}`, `{{paths.queue}}`).
Read the config before anything else, every run.

**Dual-harness.** This one plugin serves both Claude Code (`.claude-plugin/plugin.json`)
and Kimi Code (`kimi.plugin.json`) — same hooks, same `.dark-factory/` state. A Claude
session and a Kimi session can run against the SAME project: whichever session arms
becomes the implementer of record, and the lane guard holds the other to planner lanes
on either harness. The `dark-factory-*` agent files ship in `agents/` for both; if your
harness doesn't surface plugin agents, spawn an ordinary subagent with the same brief —
the task-file path for implementation; for judges the lens, the diff, and "assume the
change cut a new hole and go find it". Hooks are fail-open on both harnesses: they are
lane markings, never the security boundary.

## First run — setup (only if `.dark-factory/config.json` is missing)

The initialization routine lives in the plugin: `tools/init.sh` scaffolds
`.dark-factory/` (config from `references/config.template.json`, QUEUE and DECISIONS
from their templates, runtime files gitignored) — idempotent, never overwrites. The
`/dark-factory:init` slash command wraps it with the owner interview. Driving it
manually:

1. Run `tools/init.sh <repo>` (paths above are relative to the plugin root).
2. Inspect the repo (test runner, version file, changelog, fixtures, UI or not) and
   fill the scaffolded `.dark-factory/config.json` with real values. Explain each
   guess; the key-by-key reference is `references/config.md`. `commands.test` must be
   right — the commit gate trusts it.
3. Get the owner's confirmation on the filled config before anything runs.
4. Stop — setup and first factory run should not share a session's worth of guessing.

## The guard rail — what the hooks enforce while armed

Arming replaces prompt-discipline with mechanism on every high-risk action:

| High-risk action | Hook | Effect |
|---|---|---|
| Write outside your lane | `lane_guard` (PreToolUse) | denied, both directions — you can't edit planner areas; a concurrent planner session can't edit code while you run |
| `git commit` / `git tag` | `bash_gate` (PreToolUse) | denied unless `.dark-factory/verdicts/current.json` is fresh (< `{{guards.verdict_max_age_minutes}}` min) and green — verification is a precondition, not a habit |
| `git push` | `bash_gate` (PreToolUse) | always denied (`{{guards.allow_push}}` = false); the owner pushes after review |
| Ending the turn | `stop_gate` (Stop) | blocked while armed — you either work the queue or run the wrap-up ritual and disarm |
| Everything you touch | `run_log` (PostToolUse) | appended to `.dark-factory/run-<date>.jsonl` for the morning reconcile |

When a hook denies you, it is right — do what the reason says; never work around a gate.

## Startup (every run)

1. Read `.dark-factory/config.json`.
2. `git status` — start from a clean tree; if dirty, understand why before touching anything.
3. Read `{{paths.decisions}}` — OPEN rows are walls; never guess past one.
4. Read `{{paths.queue}}` — the ranked work order (Ready top-down · Filler anytime ·
   Gated = don't start). Banners on task files beat the queue on conflict; note drift in
   your wrap-up.
5. If the user passed steering args, they override queue order (never invariants).
6. **Arm**: run `true # dark-factory-arm`. From here the guard rail is live.

`/dark-factory:arm` is this startup as a command — same steps, plus two checks. First, a
state file already armed: by another **live** session → it is the implementer of record,
don't steal the lane; by a session that is **gone** → a dead run is holding the guard rail,
and `/dark-factory:recover` (planner-side) is the way in. Second,
`.dark-factory/recovery/rerun.md` — a recovery brief from a previous death. Read it before
the queue: `ARM: NOT GREEN` means do not arm; `ARM: GREEN` gives you `DO NOT REDO` (already
built and verified — never rebuild it), `UNVERIFIED` (exists, needs its panel), `QUARANTINED`
and `NEXT ACTION`, all void if the brief's `FINGERPRINT` no longer matches the repo. Delete
the brief in your wrap-up once that work ships or lands in a DECISIONS row.

## Model policy — cheap by default, escalate on failure

`{{models}}` says which model each subagent runs on. Pass it as the Agent tool's `model`
parameter at spawn time. **If the key is absent, spawn with no model override** — the
subagent inherits this session's model, which is the behaviour every project had before
this key existed. Model names are harness-specific (Claude: `sonnet`/`opus`/`haiku`;
Kimi: its own names — and Kimi's Agent tool has no per-spawn model override today, so
there the policy is advisory and subagents inherit the session model).

| Cycle on a task | Implementer | Verification panel |
|---|---|---|
| 1 — first implement + verify | `{{models.implementer}}` | `{{models.judge}}` · `{{models.flow_verifier}}` · `{{models.visual_judge}}` |
| 2 — first fix pass | `{{models.escalate_to}}` | unchanged |
| 3 — last cycle before HALT | `{{models.escalate_to}}` | `{{models.escalate_to}}` |

A cycle counts as **failed** when the panel returns a BLOCKER/MAJOR, when `{{commands.test}}`
is red, **or when the implementer reports it could not complete the task's scope** — all
three escalate the same way. Escalation is per task and resets at the next task.

Two things escalation is not. It is not a way to buy a green from a task that is actually
blocked on an OPEN decision or on missing real data — a bigger model does not turn a wall
into work; halt to a DECISIONS row per `{{guards.halt_after_failures}}`. And it is not
retroactive: an escalated pass re-verifies from the current tree, it does not re-open what
an earlier cycle already proved green.

Name in the wrap-up which tasks needed an escalated cycle. A task that only goes green on
the big model is a signal about the task file, not just about the model.

## Per-task loop

1. **Pick** the next unblocked task. Skip anything gated on an OPEN decision or missing
   real data (note it, move on).
2. **Implement by delegation**: spawn **`dark-factory-implementer`** with the task-file
   path and `model: {{models.implementer}}` (harness permitting — see the model policy);
   the task file is the spec — don't re-derive scope. Parallelize independent tasks only
   when their files are disjoint.
3. **Verify — never self-review.** The writing context is the weakest reviewer. Pick the
   panel from `{{verification.risk_tiers}}` by the task's declared size/risk (default:
   medium). `judge:<lens>` = one **`dark-factory-judge`** with that lens;
   `flow-verifier` = **`dark-factory-flow-verifier`**; UI-touching changes add
   **`dark-factory-visual-judge`** when `{{ui.enabled}}`. Run panel members in parallel,
   each on its model from the policy above. Objective checks outrank judge opinion: a green
   suite + verified artifact claims beat a judge's hunch, and a failing test overrides any
   judge's approval.
4. **Fix pass** from findings; re-verify what changed — spawning the fix implementer at the
   escalated model per the policy above. After `{{guards.halt_after_failures}}` failed
   fix→verify cycles on one task: STOP that task, seed a DECISIONS row with what you
   learned, move on.
5. **Write the verdict** to `.dark-factory/verdicts/current.json` — the commit gate reads
   it (fail-closed):
   ```json
   {
     "task": "tasks/<file>.md",
     "green": true,
     "panel": {"correctness": "no findings", "regression": "2 found, 2 fixed, re-verified"},
     "suite": "142 passed",
     "cycles": 2,
     "models": "implement=sonnet, fix=opus, panel=sonnet",
     "written_at": "<ISO timestamp>"
   }
   ```
   `cycles`/`models` only when `{{models}}` is set — a green verdict should say what
   produced it.
   `green: true` only when every BLOCKER/MAJOR is fixed and re-verified. Never write a
   green verdict you cannot defend line by line — the gate trusts you; the planner audits.
6. **Release ritual**: bump `{{paths.version_file}}` → entry in `{{paths.changelog}}` →
   one commit per logical change (ending with the Co-Authored-By line) → tag → run
   `{{commands.build}}` if set and the app changed → smoke the build.
7. **Banner**: prepend the dated `> **STATUS (YYYY-MM-DD): SHIPPED as <version>**` line to
   the task file, remainders named. An unbannered shipped task is a lie in the queue.
8. Next task.

## Stop conditions & wrap-up ritual

Stop when everything remaining needs a human decision or missing real data — never build
load-bearing features on guessed decisions; seed the DECISIONS row instead. Then:

1. **Wrap-up message** in the house style: shipped table (version · item · verification
   outcome), any decision-changing finding, where-it-stands, and the 1–2 questions that
   unblock the highest-value track.
2. A dated handoff doc in `{{paths.handoff_dir}}`, committed with the work.
3. Clean tree. Nothing pushed.
4. **Disarm**: run `true # dark-factory-disarm`. The stop gate will not let you end the
   turn armed — that is by design, not an obstacle. (Kimi: the gate blocks once per
   arming, then lets a stop through rather than risking a trapped session.)

That is the clean exit. The dirty one — your model allowance runs out with the reset hours
away, or the session is killed mid-task — leaves the factory armed with unverified work in
the tree and no handoff. You cannot write your own recovery from inside that death, so don't
try to pre-empt it: keep the loop's steps atomic (verdict → commit → banner, never
half-done), and leave the rest to `/dark-factory:recover`, which the **planner** runs against
the ruins. It locates the failure point from the ledger and git, verifies the survivors
blind, writes the rerun brief, and disarms (any session may disarm; the dead one's session id
no longer matters). Your next arming starts from that brief instead of from zero.

## Validation tiers

Fixture first (`{{paths.fixture}}`, instant-load) — necessary, not sufficient. Expensive
real-data validation is SCHEDULED (overnight/idle one-shots with a dated findings doc),
never polled in-loop.

## Pacing (under /loop)

Self-pace by work availability: more queue → continue immediately; blocked on external or
long-running work → schedule the wake to match reality. Don't poll what the harness will
notify you about.
