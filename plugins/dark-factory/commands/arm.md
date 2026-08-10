---
description: Arm the guard rail and run the factory — the normal way to start a run
---

Start a factory run in this repository. Preflight, arm, then the loop. Trailing args
steer the run (which task first, a time budget, "filler only") — steering never
overrides an invariant: no self-review, no guessed decisions, no push.

## Preflight — read, don't fix

1. `.dark-factory/config.json` missing → STOP and run `/dark-factory:init` first
   (the bash gate denies arming without a config anyway).
2. Read `.dark-factory/state.json`:
   - `armed: true` with **your** session id → already running; continue the loop.
   - armed by **another live session** → it is the implementer of record. Do NOT
     steal the lane: say who holds it and stop.
   - armed by a session that is **gone** — not your id, and the ledger has been silent
     (`tools/postmortem.sh` prints how long) → this is not a start, it is a dead run
     holding the guard rail: `/dark-factory:recover`, which is planner work.
3. **`.dark-factory/recovery/rerun.md` exists?** Read it before the queue — a previous run
   died and the planner's `/dark-factory:recover` left you a brief.
   - `ARM: NOT GREEN` → **do not arm.** Report the named blocker and stop; clearing it is
     the planner's or the owner's job, not yours.
   - `ARM: GREEN` → this is your starting point and it outranks queue order for the task it
     names. Check its `FINGERPRINT` against the repo now (`git rev-parse HEAD`, and whether
     the ruins still match): if the tree has moved since the brief was written, the brief's
     verification is void — treat everything in it as UNVERIFIED.
   - Honour `DO NOT REDO`: that work exists and was verified. Rebuilding it is the expensive
     mistake the brief exists to prevent. Take `UNVERIFIED` items through the panel their
     line names, and start from `NEXT ACTION`.
   - Delete the brief in your wrap-up once that work ships or lands in a DECISIONS row — a
     stale brief misdirects the next run exactly like a stale banner.
4. `git status` — normally a clean tree. Dirty is **expected and fine** when a GREEN brief
   accounts for exactly what you see: those are the recovered ruins you are resuming from.
   Dirt the brief does not explain is different — the owner is mid-something (ask), or a
   death nobody has recovered yet (`/dark-factory:recover` first).
5. Read `{{paths.decisions}}` — OPEN rows are walls. Read `{{paths.queue}}` — the
   ranked order (Ready top-down · Filler anytime · Gated = don't start). If nothing
   is unblocked, there is nothing to arm for: report what blocks the top rows and stop.

## Arm

Run `true # dark-factory-arm`. The bash gate records THIS session as implementer of
record and the whole guard rail goes live: single-writer lane guard, fail-closed
commit gate, no-push wall, exit-ritual stop gate.

## Then run the loop

You are now inside the skill — follow `skills/dark-factory/SKILL.md` from the per-task
loop onward: implement by delegation, fan-out verify (never self-review), write the
verdict, release ritual, banner the task, next task. Stop only when what remains needs
a human, then run the wrap-up ritual and disarm with `true # dark-factory-disarm`.

The stop gate will not let you end the turn armed. That is the design, not an obstacle.
