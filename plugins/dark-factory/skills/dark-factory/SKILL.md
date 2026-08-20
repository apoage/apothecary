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

**Tri-harness.** This one plugin serves Claude Code, Kimi Code, and ZCode — same
hooks, same `.dark-factory/` state. Claude reads `.claude-plugin/plugin.json`; Kimi
reads `kimi.plugin.json`; ZCode probes `.claude-plugin/plugin.json` as a documented
compatibility location and reads the same `hooks/hooks.json`, so no third manifest
exists to drift. Sessions from any of the three harnesses can run against the SAME
project: whichever session arms becomes the implementer of record, and the lane guard
holds the others to planner lanes on whichever harness they use. The
`dark-factory-*` agent files ship in `agents/`; if your harness doesn't surface
plugin agents, spawn an ordinary subagent with the same brief — the task-file path
for implementation; for judges the lens, the diff, and "assume the change cut a new
hole and go find it". Hooks are fail-open on every harness: they are lane markings,
never the security boundary.

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
| `git commit` / `git tag` | `bash_gate` (PreToolUse) | denied unless `.dark-factory/verdicts/current.json` is green, fresh (< `{{guards.verdict_max_age_minutes}}` min), **written after this arming, and verified at the task's declared `Verify:` tier or higher** — verification is a precondition, not a habit, a previous run's verdict is never yours, and the tier never goes down (see below) |
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
Kimi: its own names). Kimi's and ZCode's Agent tools take no per-spawn model override
today, so on those harnesses the policy is advisory and subagents inherit the session
model.

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
   the task file is the spec — don't re-derive scope. **Name the agent's private scratch
   dir in the brief** (`/var/tmp/<task>-implementer` — see the concurrency rules below).
   Parallelize independent tasks only when their files are disjoint.
3. **Verify — never self-review.** The writing context is the weakest reviewer. The
   intensity is the task's declared `Verify:` tier (below — the planner sets it at
   filing; absent = `full`). At `full`, pick the panel from
   `{{verification.risk_tiers}}` by the task's declared size/risk (default:
   medium). `judge:<lens>` = one **`dark-factory-judge`** with that lens;
   `flow-verifier` = **`dark-factory-flow-verifier`**; UI-touching changes add
   **`dark-factory-visual-judge`** when `{{ui.enabled}}`. Run panel members in parallel,
   each on its model from the policy above. **Freeze before you lens**: judges get a
   frozen snapshot of the tree (worktree or copy), never a tree a fix pass is editing.
   Objective checks outrank judge opinion: a green
   suite + verified artifact claims beat a judge's hunch, and a failing test overrides any
   judge's approval.
4. **Fix pass** from findings; re-verify what changed — spawning the fix implementer at the
   escalated model per the policy above. The fix pass and the verification pass never
   hold the same file at the same time (concurrency rules below). After
   `{{guards.halt_after_failures}}` failed
   fix→verify cycles on one task: STOP that task, seed a DECISIONS row with what you
   learned, move on.
5. **Write the verdict** to `.dark-factory/verdicts/current.json` — the commit gate reads
   it (fail-closed):
   ```json
   {
     "task": "tasks/<file>.md",
     "green": true,
     "verify_tier": "full",
     "panel": {"correctness": "no findings", "regression": "2 found, 2 fixed, re-verified"},
     "suite": "142 passed",
     "cycles": 2,
     "models": "implement=sonnet, fix=opus, panel=sonnet",
     "written_at": "<ISO timestamp>"
   }
   ```
   `verify_tier` names the tier actually used (suite | diff | full) — the gate refuses a
   commit whose tier is below the task's declared `Verify:` and a verdict without the
   field. For a sprint batch add `"sprint_tasks": ["tasks/<a>.md", "tasks/<b>.md"]`
   naming every task the verdict covers; the gate holds the batch to the strictest
   declared tier among them. `cycles`/`models` only when `{{models}}` is set — a green
   verdict should say what produced it.
   `green: true` only when every BLOCKER/MAJOR is fixed and re-verified. Never write a
   green verdict you cannot defend line by line — the gate trusts you; the planner audits.
6. **Release ritual**: bump `{{paths.version_file}}` → entry in `{{paths.changelog}}` →
   one commit per logical change (ending with the Co-Authored-By line) → tag → run
   `{{commands.build}}` if set and the app changed → smoke the build.
7. **Banner**: prepend the dated `> **STATUS (YYYY-MM-DD): SHIPPED as <version>**` line to
   the task file, remainders named. An unbannered shipped task is a lie in the queue.
8. Next task.

### Shared mutable state — the four concurrency rules

Provenance: a factory run that self-reported three orchestration errors in one night,
all the same shape — concurrent actors sharing mutable state (a fix pass racing its own
regression judge on one file; six agents cleaning up one shared scratchpad; two smoke
subprocesses racing one default output path). Each was a hole in this loop's doctrine.
The rules run as law, not advice:

1. **Freeze before you lens.** A fix pass and a verification pass must never hold the
   same file at the same time. Before handing a tree to a judge, freeze a snapshot
   (worktree or copy) and point the lens at the snapshot — or serialize fix → verify.
   A red observed mid-fix is not a verdict on the fix; confirm at rest.
2. **Private scratch per agent.** Every spawned agent gets its own
   `/var/tmp/<task>-<role>` directory, named in its brief. The session scratchpad is
   for single-agent runs only. No agent may `rm -rf` outside its own dir.
3. **No shared default paths.** An instruction that relocates writes names
   per-invocation or per-agent destinations; two back-to-back runs of the same builder
   must not collide on a literal path. A suite that can only pass on lucky disk timing
   is a defect report, not a flake.
4. **Mutation harnesses fail closed on build failure.** "Mutant could not be
   constructed" FAILS the suite and is distinct from "mutant built and the scenario
   failed" (a real kill); re-anchoring one drifted instance leaves the trap armed for
   every other mutation on the next edit. "I could not construct the test case" never
   scores as "the guard is live" — a green total nobody ran and read is not evidence.

### Verification tiers — intensity is a declared property of the task

Verification is ~80-90% of a run's spend; the fixed costs dominate absolutely on small
tasks. The lever: **the PLANNER declares verification intensity at filing** as a
`Verify:` line in the task file, and the gate enforces it — escalate-never-downgrade,
in `bash_gate`, not in prose. The factory may always verify HARDER than declared; never
less.

| Tier | What runs | Who qualifies |
|---|---|---|
| `full` | Panel per `{{verification.risk_tiers}}` | **The default** (absent `Verify:` = full). Mandatory for anything touching production code, gate paths, security claims, or routing. |
| `diff` | Panel scoped to the diff with drive-the-claims briefs, 1-2 lenses | Small changes whose risk lives entirely inside the diff |
| `suite` | Suite green + planner audit, no panel | **Bookkeeping-class diffs only** (`tasks/`, `lore/`, queue grooms, changelogs) — *nothing the suite imports, pins, or executes*. A prose sentence can be pinned false by a test (a measured MAJOR: a zero-byte claim diff still paid full panels; a "only prose changed" ship still lost to a test), so the eligibility test is "invisible to the suite", not "only prose changed". |

Rules that have no exceptions:
- **The planner holds the key.** Only the planner writes `Verify:` at filing. The
  factory never edits a task file's tier (the lane guard allows the implementer into
  `tasks/` for banners — the tier line is not yours to touch), and a verdict naming a
  tier below the declaration is denied by the gate with the reason named. The gate's
  subject does not release itself — same law as the armed-session disarm refusal.
- **Escalation is free, downgrade is a gate.** A task that turns out riskier than filed
  gets verified at the higher tier and the verdict says so; a `Verify: full` task never
  ships behind a `suite` verdict.
- **No auto-tiering.** Diff size or path heuristics may PROPOSE a tier in the task-file
  conversation, never set one. The tier is a planner act.

### Sprint batching — N small tasks, one verification pass

For N tasks with **disjoint file sets and independent failure modes** (stated in the
sprint declaration), the fixed verification costs can be shared:

1. The planner declares a sprint in `{{paths.queue}}`: the task list, the
   disjoint-files statement, and the failure-mode independence claim.
2. Dispatch, worktrees, and idempotency stay PER-TASK — a sprint shares verification,
   never implementation. Run the implementer once per task as usual.
3. ONE panel over the union diff (brief carries the diff↔task map), ONE suite run, ONE
   verdict (`task` = first task, `sprint_tasks` = all), ONE release: one version bump,
   one changelog entry, one commit, one tag.
4. The verdict's `verify_tier` must satisfy the STRICTEST declared tier in the batch —
   a batch is only as bookkeeping-class as its least bookkeeping-class member.
5. **On any red, the panel names the task and the batch SPLITS.** The named task
   re-verifies (and re-ships) on its own; a partially-red batch never ships. What
   shipped green in the batch stays shipped.

## Stop conditions & wrap-up ritual

Stop when everything remaining needs a human decision or missing real data — never build
load-bearing features on guessed decisions; seed the DECISIONS row instead. Then:

1. **Wrap-up message** in the house style: shipped table (version · item · verification
   outcome), any decision-changing finding, where-it-stands, and the 1–2 questions that
   unblock the highest-value track.
2. A dated handoff doc in `{{paths.handoff_dir}}`, committed with the work.
3. Clean tree. Nothing pushed.
4. **Disarm**: run `true # dark-factory-disarm`. The stop gate will not let you end the
   turn armed — that is by design, not an obstacle. (Kimi and ZCode: the gate blocks
   once per arming, then lets a stop through rather than risking a trapped session.)

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
