# dark-factory

```
        *                    .                          ☾                    .
   .           .                       *                          .
                    .                            .        *              *
        ▐█▌            ▐█▌                ▐█▌
        ▐█▌ ░░         ▐█▌ ░░░            ▐█▌ ░░
        ▐█▌            ▐█▌                ▐█▌
   ┌────███────────────███────────────────███──────────────────────────────┐
   │ /\      /\      /\      /\      /\      /\      /\      /\      /\    │
   │/  \    /  \    /  \    /  \    /  \    /  \    /  \    /  \    /  \   │
   ├────────────────────────────────────────────────────────────────────────┤
   │                                                                        │
   │   ██████╗  █████╗ ██████╗ ██╗  ██╗                                     │
   │   ██╔══██╗██╔══██╗██╔══██╗██║ ██╔╝                                     │
   │   ██║  ██║███████║██████╔╝█████╔╝                                      │
   │   ██║  ██║██╔══██║██╔══██╗██╔═██╗                                      │
   │   ██████╔╝██║  ██║██║  ██║██║  ██╗                                     │
   │   ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝                                     │
   │   ███████╗ █████╗  ██████╗████████╗ ██████╗ ██████╗ ██╗   ██╗          │
   │   ██╔════╝██╔══██╗██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗╚██╗ ██╔╝          │
   │   █████╗  ███████║██║        ██║   ██║   ██║██████╔╝ ╚████╔╝           │
   │   ██╔══╝  ██╔══██║██║        ██║   ██║   ██║██╔══██╗  ╚██╔╝            │
   │   ██║     ██║  ██║╚██████╗   ██║   ╚██████╔╝██║  ██║   ██║             │
   │   ╚═╝     ╚═╝  ╚═╝ ╚═════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝   ╚═╝             │
   │                                                                        │
   │      ▓▓░░▓▓     ▓▓░░▓▓     ▓▓░░▓▓     ▓▓░░▓▓     ▓▓░░▓▓     ▓▓░░▓▓     │
   └────────────────────────────────────────────────────────────────────────┘
      ══╦══════════╦══════════╦══════════╦══════════╦══════════╦══════════
        ║          ║          ║          ║          ║          ║

              t h e   l i g h t s   a r e   o f f .
              t h e   l i n e   i s   r u n n i n g .
```

*Codename: **moonflower** — the night-blooming datura: powerful, careful-handling-required,
and it only opens in the dark. Its entry in the apothecary's garden ledger; the working name
stays dark-factory.*

An autonomous implementer loop for Claude Code and Kimi Code: a ranked task queue, a
build agent, a risk-tiered panel of adversarial verifiers, and a release ritual — running
unattended while the humans (and the planner thread) sleep. Extracted from a real project
where it shipped a working queue end-to-end; rebuilt project-neutral, with the contract's
high-risk rules moved from prompt-discipline into **hooks the loop cannot ignore**.

**Dual-harness.** This directory is one plugin with two manifests: Claude Code reads
`.claude-plugin/plugin.json`, Kimi Code reads `kimi.plugin.json` — same hooks, same skill,
same `.dark-factory/` state, so a Claude session and a Kimi session can run against the
same repo (whichever arms is the implementer of record; the other is held to planner
lanes). Install: Claude — via the apothecary marketplace; Kimi —
`/plugins install https://github.com/apoage/apothecary` (or `/plugins marketplace` with
this repo's `kimi-marketplace.json`).

## What's in the box

```
dark-factory/
├── .claude-plugin/plugin.json       ← Claude Code manifest
├── kimi.plugin.json                 ← Kimi Code manifest (same hooks, same skill)
├── skills/dark-factory/
│   ├── SKILL.md                     ← the loop itself (/dark-factory)
│   └── references/
│       ├── config.md                ← every {{variable}}, key by key
│       ├── config.template.json     ← per-project config the setup step fills in
│       ├── two-thread-contract.md   ← the operating doctrine (planner ↔ factory)
│       ├── QUEUE.template.md        ← the ranked work order
│       └── DECISIONS.template.md    ← the blocked-on-human surface
├── commands/                        ← the three ways in
│   ├── init.md                      ← /dark-factory:init — build the factory in a repo
│   ├── arm.md                       ← /dark-factory:arm — preflight, arm, run the loop
│   └── recover.md                   ← /dark-factory:recover — after a run dies
├── tools/
│   ├── init.sh                      ← idempotent scaffold (config, queue, decisions, gitignore)
│   └── postmortem.sh                ← read-only forensic dump of a failed run
├── agents/                          ← the roster
│   ├── dark-factory-implementer.md  ← builds ONE task file, exactly as specced
│   ├── dark-factory-judge.md        ← adversarial reviewer, ONE lens, refutation-first
│   ├── dark-factory-flow-verifier.md← runs the real flow, inspects the artifacts
│   └── dark-factory-visual-judge.md ← boots the app headless, screenshots, JUDGES
├── hooks/                           ← the guard rail (armed/disarmed at runtime)
│   ├── hooks.json                   ← wiring (PreToolUse / PostToolUse / Stop)
│   ├── lane_guard.py                ← single-writer lanes, enforced both directions
│   ├── bash_gate.py                 ← arm/disarm · no-push wall · fail-closed commit gate
│   ├── stop_gate.py                 ← no ending the turn armed: ritual, then disarm
│   └── run_log.py                   ← JSONL telemetry for the morning reconcile
├── tests/
│   └── test-hooks.sh                ← synthetic-payload suite, both harness envelopes
└── docs/
    ├── RESEARCH.md                  ← the comparative review that shaped v0.2
    └── examples/                    ← live queue/decisions/playbook files from the source project
```

## Three ways in

| Command | When | What it does |
|---|---|---|
| `/dark-factory:init` | fresh repo, no `.dark-factory/` | scaffolds config + QUEUE + DECISIONS from templates (`tools/init.sh`, idempotent), then interviews the owner to fill the config. Stops there. |
| `/dark-factory:arm` | normal start of a run | preflight (config · state · clean tree · decisions · queue), `true # dark-factory-arm`, then the loop. Refuses to steal a lane another live session holds. |
| `/dark-factory:recover` | a run died armed — **planner-side** | `tools/postmortem.sh` (read-only: guard state, verdict age, ledger, silence, state fingerprint, git evidence, banner check) → locate the failure point → triage the ruins → verify the survivors blind → write the rerun brief with `ARM: GREEN` / `NOT GREEN` → disarm. Never implements, never commits. |

`/dark-factory` (Kimi: `/skill:dark-factory`) still runs the loop directly; `arm` is that
startup made explicit.

**Why recovery is planner work.** The death this plugin actually sees is not a crash — it is
the session running out of model allowance with the reset hours away. That stops the run
*between tool calls*: the files are whole, the work is possibly fine, and **nothing has been
verified**. The state file still names the dead session as implementer of record, so the next
session is held to planner lanes anyway — which is exactly the lane recovery needs. So the
planner reads the ruins, verifies the survivors blind (the dead run's word is not evidence),
writes `.dark-factory/recovery/rerun.md` — *do not redo this, this is unverified, this is
quarantined, next action is that* — and only then disarms. `/dark-factory:arm` reads the
brief before the queue and refuses to start on `NOT GREEN`. The factory resumes instead of
restarting, which is the whole point when the good model is the one that ran dry.

## The assembly line

```
  {{paths.queue}} ──► pick top unblocked task
        │
        ▼
  dark-factory-implementer ── task file = the contract; smallest faithful build
        │
        ▼
  fan-out verify ──── NEVER self-review; panel sized by task risk
        ├── dark-factory-judge ×1–4   (parallel; lenses: correctness / fail-closed /
        │                              regression / security — refute or list attacks)
        ├── dark-factory-flow-verifier (run the real pass on a fixture copy;
        │                              task-file claims = test cases)
        └── dark-factory-visual-judge (headless boot + Playwright + screenshot
                                       judgment; findings with evidence, never pass/fail)
        │
        ▼
  verdict file ────── .dark-factory/verdicts/current.json — green + fresh, or no commit
        │
        ▼
  release ritual ──── version bump · changelog · commit · tag · build · smoke
        │                               (git gate open only behind a green verdict;
        │                                push always denied)
        ▼
  banner the task ─── dated STATUS line 1, mapped to the changelog, never guessed
        │
        └──► next task … until only human decisions remain, then wrap up, disarm, STOP
```

## Hooks, not honor

v0.1 enforced its contract by prompt; v0.2 arms a guard rail. `true # dark-factory-arm`
binds the running session as the implementer; from then on:

| High-risk action | Guard | Outcome |
|---|---|---|
| Out-of-lane write (either thread) | `lane_guard` | denied with the lane map |
| `git commit` / `git tag` without a green verdict, fresh AND newer than the arming | `bash_gate` | denied, fail closed |
| `git push` | `bash_gate` | denied, always |
| Ending the turn without the wrap-up ritual | `stop_gate` | blocked until bannered, handed off, clean, disarmed |
| Any mutation | `run_log` | appended to `.dark-factory/run-<date>.jsonl` |

Disarmed (or in projects with no `.dark-factory/config.json`), every hook is a fast no-op —
the plugin costs nothing outside factory runs.

## Portability — variables, not paint

Nothing project-specific lives in the skill or agents. Every specific — test command,
version file, fixture path, invariants, protected volumes, lane map, risk tiers — is a
`{{variable}}` resolving from `.dark-factory/config.json`. First run of `/dark-factory` in
a fresh repo walks the owner through writing that file from the template; see
`skills/dark-factory/references/config.md` for the full key reference.

## The three rules that make it work

1. **Single-writer areas.** The planner thread writes tasks/docs/prototypes; the factory
   writes code/changelog/version. Nobody crosses. *(hook-enforced)*
2. **Never self-review.** The context that wrote a change is its weakest reviewer. Every
   load-bearing change faces separate adversarial verifiers with named lenses — and
   objective checks (suite, artifact diffs, real execution) outrank judge opinion.
   *(commit-gated)*
3. **Decisions are walls.** Anything needing a human lands as a recommendation-first row
   in DECISIONS and the factory stops cleanly — it never builds on a guessed decision.
   *(stop-gated)*

Full doctrine: `skills/dark-factory/references/two-thread-contract.md`.

## Changelog

- **0.3.5** — shared-mutable-state doctrine in the skill + agent briefs: freeze before
  you lens, private scratch per agent, no shared default paths, mutation harnesses
  fail closed on build failure; drift-guard checks in the suite.
- **0.3.4** — task-declared verification tiers (`Verify:` in the task file; `full`
  default / `diff` / `suite`) enforced by the commit gate escalate-never-downgrade
  against the verdict's `verify_tier`; sprint batching (N disjoint tasks, one panel,
  one verdict at the strictest declared tier, splits on any red).
- **0.3.3** — a verdict must postdate the arming it ships under (`armed_epoch`).
- **0.3.2** — `arm` + `recover` commands: planner-side recovery from an allowance death.
- **0.3.1** — initialization routine (`init.sh` + `/dark-factory:init`).
- **0.3.0** — dual-harness: one plugin directory serves Claude Code and Kimi Code.
