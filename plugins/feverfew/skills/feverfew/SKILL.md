---
name: feverfew
description: Use when designing or about to run a rigorous ML/quant/time-series experiment and you need it leakage-guarded and audit-ready — enforces causal-feature checks, label/input separation, purged forward splits, value-identity on reused code, correct holding-period Sharpe, pre-registered grids/gates, smoke-first validation, OOM-safety, artifact re-derivation, and honest nulls.
---

# Feverfew — taken before the run, to prevent the fevers that ruin results

Feverfew guards a fever before it starts. This skill guards an ML experiment
against its silent killers — leakage, OOM, measurement artifacts, un-audited
results — by making you start it correctly. It is a checklist, not an essay.
Work top to bottom. A failed check means the **design** is wrong; fix the
design, do not "just run it and see."

Companion: **`erythroxy`** (JAX VRAM / performance) owns the memory-fight
mechanics referenced in §6.

---

## 1. Leakage guards — assert these BEFORE training

Leakage is the disease feverfew exists to prevent. Every item is an assertion
to encode in code, not a vibe to check by eye.

- [ ] **Features are causal.** A feature at decision time `t` uses ONLY
      information available at or before `t`. The classic trap is a rolling
      window or shift that peeks one step ahead (`shift(-1)`, centered windows,
      `pct_change` aligned to the wrong edge). Assert `feature[t]` is
      computable from `data[:t+1]` alone.
- [ ] **The target is a LABEL, never an input.** The thing you predict enters
      the loss and the eval ONLY. Assert the forward pass receives `features`
      and the target is never concatenated, leaked through normalization stats,
      or reachable from any model input. A unit assertion on the input tensor's
      column set is worth more than a comment.
- [ ] **Execution / entry lag is honest.** A decision made at `t` ENTERS at
      `t+1`. It can never fill at `t`'s own close — that close was already a
      feature the model saw. Assert position changes apply to the *next* bar's
      return. Off-by-one here silently fabricates alpha.
- [ ] **Splits are forward-ordered, contiguous, and PURGED.** Train precedes
      val precedes test in time, each a contiguous block. Insert a **purge gap
      ≥ the label horizon** between adjacent splits so a train label cannot
      overlap a val/test feature window. No shuffling, no k-fold across time.
- [ ] **Fitted transforms see TRAIN only.** Standardization, winsorization,
      PCA, vocab — fit on train, apply frozen to val/test. Fitting on the full
      series leaks test-set moments into train.
- [ ] **No oracle, no leaky teacher.** A model distilled from a future-peeking
      oracle, or supervised on labels derived with hindsight, becomes a
      *classifier of the past*, not a *predictor of the future*. If a teacher
      saw `t+k` to make the target, the student inherits the leak.

> If any box above is unchecked, stop. Nothing downstream is trustworthy.

---

## 2. Value-identity — when you reuse or reimplement an audited path

Rewriting an audited routine (numpy→JAX, or chunking it for memory) is a
quiet leakage/correctness risk: the new path can diverge silently.

- [ ] **Bit-identity (or tight tolerance) on a sample.** Run old and new
      implementations on the same sample; assert `|Δ| < 1e-4` (ideally exact)
      before trusting the rewrite. Do this in a test, not by squinting at two
      printouts.
- [ ] **Reproduce a published metric.** Reproduce an inherited reference number
      (e.g. inherited IC == reference within `1e-3`) as the correctness gate
      for the whole path. If you cannot reproduce the known-good number, you
      cannot trust the new one.

---

## 3. Measurement — don't fool yourself

The most expensive bugs are the ones that *flatter* you.

- [ ] **Annualize Sharpe at the HOLDING PERIOD, never per-bar.** A persistent
      or min-hold position makes per-bar returns autocorrelated. Computing a
      per-bar Sharpe and scaling by `√(periods/yr)` over-counts independent
      periods and **wildly inflates** the number.
      - *Real lesson:* a reported **"+5.08 Sharpe" was purely a
        per-bar-annualization artifact** — it vanished under correct
        aggregation.
      - **Honest recipe:** aggregate per-bar returns up to the holding period
        first, then annualize by `√(rebalances per year)`.
- [ ] **Block-bootstrap CI.** Report a confidence interval from a block
      bootstrap with **block length ≥ the holding length**, so the resampling
      respects the autocorrelation you just accounted for.
- [ ] **Pre-cost AND post-cost.** Report both. **Gate on post-cost.** A strategy
      that only works gross of fees does not work.

---

## 4. Pre-register the grid and the gate

Decide the verdict rule before you can be tempted by the result.

- [ ] Fix the experiment **cells** (the grid: seeds, periods, variants) BEFORE
      running.
- [ ] Fix the **pass/fail threshold** BEFORE running (e.g. "promote iff mean
      Δ ≥ +3pp and no seed < −3pp").
- [ ] **Never add cells post-hoc to chase a number.** Expanding the grid after
      seeing results is how noise becomes a "finding."
- [ ] The verdict follows the gate **mechanically** — you read it off, you do
      not argue it.

---

## 5. Smoke first

A tiny cheap run with HARD mechanical checks catches design flaws in minutes
that a 30-minute full run would only reveal at the end (if ever).

- [ ] Run a minimal smoke (few steps, tiny data) BEFORE the expensive run.
- [ ] Attach **mechanical** pass/fail checks, e.g.:
      - "turnover MUST drop when the cost penalty rises"
      - "the cost model may not MINT money (no negative cost)"
      - "the reported metric MUST match the reference within tolerance"
      - "the gate must actually fire on a known-good and known-bad input"
- [ ] If a mechanical check fails, the **design** is wrong (an inert gate, a
      fiction-producing cost model, a scale bug). Fix it. **Do not launch the
      full run.**

---

## 6. OOM-safety by construction — not by watcher

Build the run so it cannot endanger the host, rather than babysitting it.

- [ ] Size a memory cap to `verified_peak × ~1.5`, well under host RAM.
- [ ] Run with `python -u` (unbuffered) and **persist the true RSS peak** so
      the next cap is grounded in measurement, not guesswork.
- [ ] **Know the shared-host trap:** `systemd-oomd` kills on memory **pressure**
      (PSI), NOT on your cgroup cap. It can kill you *under* the cap, and
      **raising the cap does not help.** The cap protects the host; it does not
      protect your job.
- [ ] **The real fix is to stop churning memory:** chunk / stream, or push heavy
      arrays to VRAM (see **`erythroxy`**). A clean **self-kill that never
      endangers the host** is the goal — the host surviving beats your job
      surviving.

---

## 7. Audit from artifacts

A summary is a claim, not evidence — yours, a teammate's, or a model's.

- [ ] Before a result enters canon, **re-derive it from the artifacts** (code,
      logs, raw data). Do not trust the writeup.
- [ ] Keep a **`GUARDS.md`** mapping each guard — inherited vs. new — to the
      **exact code** that enforces it, so an independent auditor can re-derive
      every guarantee without asking you. If a guard isn't pinned to code, it
      isn't a guard.

---

## 8. Honest nulls

Feverfew prevents fevers; it does not invent cures.

- [ ] If nothing clears the pre-registered gate, **say so plainly.** A clean
      negative that **sets the ceiling** is a real result — it tells the next
      experiment where not to dig. Hiding or re-framing a null to look like a
      partial win poisons the canon for everyone downstream, including future
      you.

---

### One-line creed

> Causal features, labels out of the forward pass, purged forward splits,
> identity-checked rewrites, holding-period Sharpe, a pre-registered gate, a
> smoke that bites, an OOM that only hurts the job, results re-derived from
> artifacts, and nulls told straight.
