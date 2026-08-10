---
description: Planner-side recovery after a factory run dies — find where it stopped, verify the survivors independently, and hand the next run a GREEN TO ARM brief
---

**This is a planner-thread routine.** You investigate a dead factory run, decide what
survived, and hand the next run a green light — you do **not** implement, commit, tag or
ship. The factory does that, on the next arming, from the brief you write.

That division is why recovery works at all: the state file still names the dead run's
session as implementer of record, so the lane guard holds you to **planner lanes** — and
planner lanes are exactly what this job needs (`{{paths.queue}}`, `{{paths.decisions}}`,
`{{paths.handoff_dir}}`, `.dark-factory/recovery/`). You do not need to disarm to
investigate. Disarming is the **last** step, not the first.

Trailing args narrow the job: "just disarm" → Phase 1, then Phase 6's release, no verification;
a task path → assess that task only and leave the rest for the owner.

## The failure mode this is built for

**The session ran out of model allowance and the reset is far away.** That is the common
death, not a crash — and it fails differently:

- It stops **between tool calls**, so files on disk are *whole*. There is no truncated write
  to repair. "Partially done" means *step N of the loop finished and step N+1 never
  started*, not "corrupt".
- It leaves **no error and no statement of intent**. The ledger just ends: no wrap-up doc,
  no disarm, no verdict for whatever was in flight.
- The work may be **fine and entirely unvouched-for**. Coherent code proves nothing: the
  panel either never ran or never got recorded.
- You are likely on a **weaker model**, because the good one is the one that ran dry. So the
  budget goes to *verifying what exists* — never to rebuilding it, and never to lowering
  the bar (Phase 4).

Crashes, kills and interrupted releases recover the same way; only Phase 2's reading changes.

## Phase 0 — your lane

Writable by you here: task files and the queue (shared), docs and the recovery doc
(planner-owned), `.dark-factory/recovery/` (runtime, always open). **Not** writable: code,
tests, changelog, version file — the armed record still owns them, and even after disarming
you leave them alone. A ruin that needs a code change is a line in the brief, not your edit.

If `.dark-factory/config.json` is missing there is no factory to recover: `/dark-factory:init`.

## Phase 1 — evidence (script, no guessing)

Run the plugin's postmortem against the repo:

- Claude: `bash "${CLAUDE_PLUGIN_ROOT}/tools/postmortem.sh"`
- Kimi: `bash "$KIMI_PLUGIN_ROOT/tools/postmortem.sh"`

Read-only, mutates nothing. It prints the guard state (armed? whose session? how long ago?),
the verdict and its age, the run ledger (counts, files written, last 25 entries, banner check
on every task file touched), how long the ledger has been **silent**, the git evidence (dirty
tree, `diff --stat`, commits and tags since arming, stashes, reflog), a **state fingerprint**
(HEAD plus a hash of the ruins) to bind your verification to, any prior recovery artifacts,
and a failure fingerprint.

Then read what a script cannot judge: `git diff` for the uncommitted work, the task file the
run was on, and the last handoff doc in `{{paths.handoff_dir}}`.

## Phase 2 — locate the failure point

The boundary is between the **last ledger entry** and the **last thing git kept**. Name it:
which task, which step of the loop, what the last successful mechanical act was.

| Signal | Reading |
|---|---|
| ledger ends mid-loop, no wrap-up write, no disarm, long silence | **ran out of allowance or was killed** — the default case; artifacts whole, nothing verified |
| verdict green + fresh, no commit after it | died in the **release ritual** — approved work sits unshipped |
| verdict red or missing, tree dirty | died in **implement or verify** — nothing was ever approved |
| commit and tag present, task file unbannered | died at the **banner** step — code is fine, the queue is lying |
| last entries are all Bash test runs | died in a **fix→verify cycle**, likely at `{{guards.halt_after_failures}}` |
| armed, but no ledger entry after `armed_at` | died at **startup** — config, lanes, or before the first tool call |
| ledger `role: other` entries during the run | a **second session** wrote while the factory ran — suspect an edit race |

The ledger cannot distinguish an exhausted allowance from a kill — both stop between tool
calls. It can tell you that nothing wrapped up and nothing disarmed, which is what matters.

## Phase 3 — triage the ruins

Bucket every artifact; the buckets are what the brief is made of:

1. **Shipped & verified** — committed under a green verdict. Confirm the banner, nothing else.
2. **Built but unverified** — coherent work in the tree, or a commit with no verdict behind
   it. The main bucket in a budget death: salvageable, but *nobody checked it*. Untrusted,
   not nearly-done.
3. **Half-built** — a step the loop never finished: code without its test, a test written but
   never run, a version bump with no changelog entry. Name the missing half; don't guess it.
4. **Debris** — scratch files, fixture copies, partial build output. Quarantine, and delete
   only what you can trace to a ledger entry.
5. **Lies** — a SHIPPED banner with no commit or tag, a green verdict for absent work, a
   changelog entry for an unreleased version. **Fixing the record is your job** (task files
   and the queue are your lane) and it comes first: a wrong banner poisons every later run.

## Phase 4 — verify the survivors independently (read-only)

This is where the budget goes. Rebuilding what already exists is the expensive mistake.

1. **The dead run's word is not evidence.** No transcript, no self-report, no checked box in
   the task file, no comment claiming a test passed. Evidence is artifacts only: the diff, a
   suite you ran yourself, the flow actually executed.
2. **Verify blind.** Spawn the panel from `{{verification.risk_tiers}}` with the task file and
   the diff — never the dead run's reasoning. A judge told "the previous session believed this
   was done" reviews the belief instead of the code. Judges are read-only: they report
   findings, they do not fix.
3. Run `{{commands.test}}` yourself first — objective checks are cheap and they outrank
   opinion. A red suite ends the question.
4. **Bind the result to the state fingerprint** the postmortem printed. Your verification is
   valid for exactly that HEAD and that set of ruins; if either moves, it is void. Record the
   fingerprint in the brief so the next run can tell whether your work still counts.
5. **You never write `.dark-factory/verdicts/current.json`.** That file is the commit gate,
   and it belongs to the armed session that ships. Your findings feed it; they don't replace
   it. If you ran a downgraded model, say which — the next run may need to re-judge.
6. **Void the dead run's verdict by MOVING it — first, before anything else.** The gate checks
   that a verdict is green, fresh and written by the armed session; it does **not** check which
   task it is for. A dead run's verdict is often only minutes old, so left in place it opens
   the gate for the next session to commit *anything*, verified or not. Convert the doctrine
   into mechanism, keeping the evidence:

   ```bash
   mkdir -p .dark-factory/recovery
   mv .dark-factory/verdicts/current.json .dark-factory/recovery/<date>-void-verdict.json
   ```

   The gate now fails closed on absence, and the resuming run must earn its own verdict. The
   postmortem flags this explicitly when the leftover verdict is still green and fresh.

## Phase 5 — preserve, don't repair

1. **Quarantine what is not going forward:** `git stash push -m "df-recover <date>: <what>"`,
   or `git diff > .dark-factory/recovery/<date>-<slug>.patch` for what you want on record.
   NEVER `git reset --hard`, `git checkout --`, or delete untracked files the owner has not
   seen — that destroys the only copy of the ruin.
2. Fix the record in your own lane: banners, queue rows, and a DECISIONS row for anything
   that now needs the owner (an ambiguous ruin, a decision the dead run guessed at, a gate
   that should have caught this).
3. Leave the code exactly as it is otherwise. The next armed run finishes it — with your
   brief, it does not start from zero.

## Phase 6 — the rerun brief, and the green light

1. **Write `.dark-factory/recovery/rerun.md`.** This is the deliverable: the next session must
   not re-derive any of it. `/dark-factory:arm` reads this file before the queue. Short and
   mechanical:

   ```markdown
   # Rerun brief — <date>
   ARM: GREEN            # or: NOT GREEN — <the one blocker, and who clears it>
   FAILURE POINT: <task, step of the loop, last successful mechanical act>
   FINGERPRINT: head=<sha> ruins=<hash>    # this brief is void if these move
   DO NOT REDO: <file — what already exists and works, per the verification below>
   UNVERIFIED: <file — exists, no panel passed it, needs tier <low|medium|high>>
   VERIFIED BY ME: <lens/suite results, and on which model>
   QUARANTINED: <what, and the exact command to restore it>
   NEXT ACTION: <the single next step for the armed run>
   ```

   If `.dark-factory/recovery/` is not in `.gitignore` (a repo scaffolded before this
   version), run `tools/init.sh <repo>` first — it is idempotent and only appends the
   missing ignore line. An un-ignored brief dirties the tree and trips the next run's
   clean-tree check.

2. **`ARM: GREEN` is the point of this routine** — the factory reads it as permission to
   start. Write GREEN only when all of it holds: the guard rail is released (step 4), the
   tree's state is bucketed and recorded, the record carries no lies, no OPEN decision blocks
   the next action, and NEXT ACTION is a single unambiguous step. Otherwise write `NOT GREEN`
   with the one blocker named — a stalled allowance, an owner decision, an unreadable ruin.
   Never write GREEN to be agreeable; an unearned green light is the same failure as an
   unearned verdict, one step earlier.
3. A dated recovery doc in `{{paths.handoff_dir}}` for the human record — failure point, the
   per-bucket table, verification results, what is quarantined and how to restore it,
   decisions seeded, and the mechanism fix as a task file if a gate should have caught this.
   (You are the planner, so the whole directory is your lane. An *armed implementer* writing
   here would need `handoff`/`validation` in the filename — one of
   `{{lanes.implementer_doc_exceptions}}`.)
4. **Release the state: `true # dark-factory-disarm`.** Any session may disarm; that is the
   valve for a run whose session no longer exists. Then stop — you are the planner. The
   owner (or `/dark-factory:arm`) starts the next run, and the factory itself deletes
   `.dark-factory/recovery/rerun.md` in the wrap-up once that work ships or lands in a
   DECISIONS row. A stale brief misdirects the next run exactly like a stale banner.
5. Never push, never commit code. Recovered work faces the same review as everything else.
