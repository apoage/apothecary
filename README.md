# 🜍 Apothecary — a Claude Code skill marketplace

An apothecary's shelf of Claude Code skills: careful remedies for machine-learning / quant
work and long agent sessions. **Medicinal plants, not dark** — careful work with powerful tools.

## The shelf

| Skill | What it is |
|---|---|
| **feverfew** | *Taken before the run, to prevent the fevers that ruin results.* Rigorous ML/quant experiment discipline — data-leakage guards (causal features, label/input separation, purged forward splits), value-identity on reused/reimplemented code, **correct holding-period Sharpe** (never the per-bar annualization trap), pre-registered grids & gates, smoke-first validation, OOM-safety by construction, audit-from-artifacts, and honest nulls. |
| **erythroxy** | *The apothecary's performance stimulant* (from *Erythroxylum*, the coca plant). JAX/GPU on small hardware, in two halves. **Defense:** the **VRAM-resident pattern** (host RAM flat, the job lives in VRAM while a contended host thrashes around it), beating **systemd-oomd**, chunk/stream, XLA tuning, fast lazy gathers. **Offense:** the memory hierarchy as a **pipeline** — generate on-the-fly in VRAM (never read disk in the loop), stream prep from slower tiers overlapped with compute, checkpoint periodically, parallelise the batch axis, and **saturate every FLOP** (GPU pinned on gradients, everything else exiled to CPU). *Make it go woooooo.* |
| **chandoff** | Write a project-tuned **compaction rubric** before `/compact` fires, so the summarizer keeps what's load-bearing in *your* session. Drafts the rubric, writes a durable lore handoff, and emits a paste-ready `/compact` block. |
| **dark-factory** | *The night shift — the one specimen on the shelf that blooms only in the dark* (a moonflower, whenever it earns its herb name). An **autonomous implementer loop**, bigger than a skill: `/dark-factory` + a roster of four agents (implementer, adversarial judge, flow verifier, visual judge) + **five hooks** that turn the two-thread contract's high-risk rules into runtime guard rails — single-writer lane guard, fail-closed commit gate (no verdict, no commit), an absolute no-push wall, and a stop gate that won't let the loop end its turn without the wrap-up ritual. Project-neutral by construction: every specific is a `{{variable}}` in `.dark-factory/config.json`. |

`feverfew` (does it measure the truth?) and `erythroxy` (does it run at all, fast, in the
memory you have?) are companions — the correctness side and the performance side of the same
experiment. `dark-factory` is what runs while the apothecary sleeps.

## Install

```
/plugin marketplace add apoage/apothecary
/plugin install feverfew@apothecary
/plugin install erythroxy@apothecary
/plugin install chandoff@apothecary
/plugin install dark-factory@apothecary
```

Update later with `/plugin marketplace update apothecary`.

## Layout

```
.claude-plugin/marketplace.json     # the catalog (marketplace name: "apothecary")
plugins/
  feverfew/     .claude-plugin/plugin.json   skills/feverfew/SKILL.md
  erythroxy/    .claude-plugin/plugin.json   skills/erythroxy/SKILL.md
  chandoff/     .claude-plugin/plugin.json   skills/chandoff/SKILL.md
  dark-factory/ .claude-plugin/plugin.json   skills/dark-factory/SKILL.md (+references/)
                agents/dark-factory-{implementer,judge,flow-verifier,visual-judge}.md
                hooks/hooks.json + lane_guard.py bash_gate.py stop_gate.py run_log.py
                docs/RESEARCH.md + examples/
```

## Provenance

These skills distill hard-won lessons from a long quantitative-ML campaign: a dozen rounds
of fighting `systemd-oomd` on a contended shared host, a per-bar-Sharpe artifact that nearly
got mistaken for a working trader, leak surfaces in differentiable backtests, and the move to
make a whole JAX pipeline *live in VRAM* so it couldn't be touched by host-memory pressure.
The skills are the methodology written down so it doesn't have to be re-derived each time.

`dark-factory` came the other way — extracted from a video-editing project where it ran a
queue of shippable features unattended overnight (implement → fan-out verify → release
ritual → banner → next), then rebuilt project-neutral after a comparative review of the
autonomous-loop ecosystem (BMAD, Aider, Roo, OpenHands, SWE-agent, spec-kit, Ralph — the
full report ships in `plugins/dark-factory/docs/RESEARCH.md`). Its v0.2 headline: the
contract's high-risk rules moved from prompt-discipline into hooks the loop cannot ignore.
