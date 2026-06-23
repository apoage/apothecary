---
name: erythroxy
description: Playbook for JAX/GPU development under tight VRAM/RAM limits — fight OOM and systemd-oomd, choose host-RAM-resident vs VRAM-resident design, tune XLA memory and performance, write fast gathers, and avoid recompiles and host↔device thrash.
---
# Erythroxy — the apothecary's performance stimulant

*Erythroxylum, the coca leaf: a powerful stimulant used with care. Reach for it when the GPU is idle and the host is choking — to squeeze maximum throughput out of JAX under hostile memory limits. Deliberate doses only; substance below.*

Use this when JAX (or any GPU ML) work is bottlenecked by memory or speed: OOM kills, a RAM-contended host with idle GPUs, slow kernels, surprise recompiles, or host↔device thrash. For the correctness side (leakage, value-identity audits, experiment rigor) cross-reference the companion **`feverfew`** skill.

---

## 1. The VRAM-resident pattern (headline move)

On a host with **contended RAM but idle GPUs**, do NOT build big arrays in host RAM (numpy). systemd-oomd will pressure-kill you even under a cgroup cap. Instead:

- Keep **only the small base array** in host RAM — the raw data, a few hundred MB.
- Transfer it to VRAM **once** with `jnp.asarray`.
- Build **every heavy intermediate on the GPU** in JAX: feature gathers, the normal equations, the model, the eval. Nothing large ever lands in host RAM.

Host RAM stays flat and tiny, so oomd can't reach it — the job "lives in VRAM" while the host thrashes around it.

> Real result: a routine that needed ~57 GB host-RAM fit became **~3.3 GB host-flat** once features + ridge moved to VRAM.

```python
import jax, jax.numpy as jnp

base = load_raw()                 # small: stays in host RAM (few hundred MB)
xg   = jnp.asarray(base)          # ONE host->device transfer; base is now on GPU

@jax.jit
def fit(xg):
    feats = build_features(xg)    # heavy gather — built on GPU, never in numpy
    XtX   = feats.T @ feats
    XtY   = feats.T @ targets(xg)
    return jnp.linalg.solve(XtX + lam*jnp.eye(feats.shape[1]), XtY)

w = fit(xg)                       # weights live on device; pull only the small result
```

**When you reimplement a numpy routine in JAX for this, it's a memory relocation, not a method change — prove it.** Assert value-identity on a sample:

```python
assert jnp.max(jnp.abs(jax_out - numpy_ref)) < 1e-4, "relocation changed the math"
```

---

## 2. The systemd-oomd reality (why your cap doesn't save you)

On shared Linux hosts, **systemd-oomd kills on memory PRESSURE STALL (PSI), not on your cgroup `MemoryMax`**. It will kill a 4 GB job at 3 GB free during cache-reclaim churn.

- `ManagedOOMMemoryPressure=auto` does **not** reliably opt you out.
- A swap cap just trades a kill for a stall.

**Durable fixes (in order):**
1. Don't hold the memory on the host at all → §1 VRAM-resident.
2. Chunk/stream so the reclaim churn is small → §3.
3. Run when the host has real headroom (check `free -g`, PSI).

**Diagnose which OOM you hit** — they're different failures:

```bash
journalctl -k | grep -i 'killed process'        # kernel cgroup-OOM at your MemoryMax
journalctl     | grep -i 'systemd-oomd'          # PSI pressure-kill ("systemd-oomd killed ...")
cat /proc/pressure/memory                        # live PSI; "some"/"full" avg10 climbing = danger
```

If you see `systemd-oomd killed`, raising `MemoryMax` will NOT help — you're being killed on pressure, not the cap.

---

## 3. Chunk / stream to bound the working set

Never materialize a full `(N_huge × F)` design matrix.

**Ridge / linear solve** — accumulate the normal equations in row-blocks, solve once. Value-identical to the one-shot solve; peak memory = one block.

```python
F = feature_dim
XtX = jnp.zeros((F, F)); XtY = jnp.zeros((F,))
for i in range(0, N, BLOCK):
    Xb = build_features(xg[i:i+BLOCK])     # one block on GPU
    yb = targets(xg[i:i+BLOCK])
    XtX += Xb.T @ Xb
    XtY += Xb.T @ yb
w = jnp.linalg.solve(XtX + lam*jnp.eye(F), XtY)
```

- **Training:** build features **on-the-fly per minibatch window**, not a pre-built tensor.
- **Eval / predict:** build + predict **per chunk**, keep only the small outputs.
- **Standardization:** fit mean/std on a **subsample** or streaming (Welford); don't load the full array to compute stats.

---

## 4. XLA memory knobs

- Keep `XLA_PYTHON_CLIENT_PREALLOCATE` **ON** (the default) for fewer fragmentation issues. Don't force it `false` except when actively debugging an allocator problem.
- Set `XLA_PYTHON_CLIENT_MEM_FRACTION` (e.g. **0.5–0.7**) so you co-exist with other GPU tenants and leave headroom.
- Avoid `XLA_PYTHON_CLIENT_ALLOCATOR=platform` in production — it's slow (sync alloc/free every op). Debug only.
- Pin to a single **verified-idle** GPU with `CUDA_VISIBLE_DEVICES`.

```bash
export CUDA_VISIBLE_DEVICES=1
export XLA_PYTHON_CLIENT_MEM_FRACTION=0.6
# PREALLOCATE left default (on)
nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv  # confirm idle first
```

---

## 5. Fast gathers / no full materialization

- Gather sliding windows **lazily** with `jax.lax.dynamic_slice` inside `jax.vmap` — don't build a giant strided view.
- Prefer fused `jnp` ops over Python loops over arrays.
- Inside `vmap`, use `jnp.where` **NOT** `jax.lax.cond`.
- Guard every division: `x / jnp.maximum(denom, 1e-10)`.

```python
def window(start):
    return jax.lax.dynamic_slice(xg, (start, 0), (W, xg.shape[1]))

windows = jax.vmap(window)(starts)   # lazy gather; no (len(starts) × W × C) numpy view
```

---

## 6. Compile discipline (avoid recompiles & slow paths)

- `jit` your step function.
- Pass configs via `static_argnames` so they don't trigger retracing on every value.
- Keep **shapes STATIC**. Dynamic shapes in `lax.scan` / `jit` force recompiles or fail — **pad to a static `max_len`**.
- Use `donate_argnums` so XLA reuses input buffers in-place for big arrays (optimizer state, carry).
- **Never** let a recompile happen inside the loop — trace once, run many.

```python
from functools import partial

@partial(jax.jit, static_argnames=("n_layers",), donate_argnums=(0,))
def step(opt_state, batch, n_layers):   # opt_state donated -> reused in place
    ...
    return new_opt_state, metrics
```

Catch silent retraces while developing:

```python
import jax
with jax.log_compiles():
    step(opt_state, batch, n_layers=4)   # any line printed per-iteration = a recompile to kill
```

---

## 7. Host↔device thrash

- **Minimize transfers.** Each `np.asarray(jnp_array)` round-trips through the host — converting jnp→numpy every step kills throughput.
- Call `jax.block_until_ready()` before a device→host copy or any timing.
- Keep data **on-device across the whole loop**; pull only small scalars/metrics to host, and batch even those (e.g. stack metrics, transfer once at the end).

```python
losses = []
for batch in loader:
    state, loss = step(state, batch)     # loss stays on device
    losses.append(loss)                  # still a device array — no transfer yet
final = jax.device_get(jnp.stack(losses))  # ONE host transfer at the end
```

---

## 8. Measure honestly

Async dispatch lies — JAX returns before the GPU is done.

- Time with `block_until_ready()` around the region, not around the dispatch.
- **Separate first-step compile cost from steady state** (drop the first iteration, or warm up once before timing).
- Report **both** the true host RSS peak **and** the GPU memory peak.

```python
import time, jax

step(state, next(it))                    # warm-up: pays compile cost
jax.block_until_ready(state)

t0 = time.perf_counter()
for _ in range(100):
    state, _ = step(state, next(it))
jax.block_until_ready(state)             # don't time before the GPU finishes
print("steady ms/step:", (time.perf_counter() - t0) / 100 * 1e3)
```

```bash
/usr/bin/time -v python train.py 2>&1 | grep 'Maximum resident'   # host RSS peak
# GPU peak: jax.profiler memory trace, or watch: nvidia-smi --query-gpu=memory.used --format=csv -l 1
```

---

## Quick triage

| Symptom | First move |
|---|---|
| OOM-killed on a RAM-contended host, GPU idle | §1 VRAM-resident |
| `systemd-oomd killed` in journal, cap not exceeded | §2 — it's PSI; raising `MemoryMax` won't help |
| Big design matrix won't fit | §3 chunk/stream the normal equations |
| Co-tenant on GPU OOMs you | §4 `MEM_FRACTION` 0.5–0.7, single GPU |
| Loop slows over time / recompiles | §6 `static_argnames`, static shapes, `log_compiles` |
| Throughput tanks despite idle GPU | §7 stop per-step jnp→numpy; §8 time with `block_until_ready` |

---

# PART II — OFFENSE: make it go *woooooo*

> The first half of this skill keeps you alive: stay VRAM-resident, don't hand systemd-oomd anything to reach for, beat the watcher by construction. That's the floor. This half is the ceiling. Once you're not dying, the only sin left is **idle silicon**.
>
> The operator's law, verbatim: *"run small in fast memory, prepare data in slower stream, time to time write checkpoint, and if HW and pipeline allow parallelise — make things go woooooo on GPU, utilise every FLOP."*
>
> Six clauses. Each is a section below. Each is backed by a measured win from the campaign — not theory, receipts.

The defensive half asks *"will this fit?"* The offensive half asks *"is the GPU doing gradient math **right now**, or is it waiting on me?"* Most slow training is not compute-bound. It is the GPU stalled on a sync, a disk read, a recompile, or a Python loop. Hunt the stall, not the FLOP.

---

## 1. The memory hierarchy is a *pipeline*, not a *budget*

The defensive sections treat the hierarchy as a budget (what fits where). Offense treats it as a **conveyor belt**: hot working set + compute in the fastest tier, data *flowing in* from slower tiers to feed it, durability *draining out* to the slowest tier only periodically. The belt must never stall waiting on a slow tier.

| Tier | Resource | Offensive role | Iron rule |
|------|----------|----------------|-----------|
| 1 | GPU L1/L2 cache | JIT kernels live here | **LEGENDARY — never pollute.** Don't stage app data here. |
| 2 | VRAM | Active tensors, the compute itself, the prefetch buffer | Use freely if it fits. This is where work *happens*. |
| 3 | RAM | Staging / prep / batched data resident for fast indexing | Prep here *concurrently*, batch the transfers up to VRAM. |
| 4 | Disk | Checkpoints, logs, control data, configs | Load to RAM **once** at startup. **Never** in the loop. |
| 5 | Stream (disk→RAM) | Data too large for RAM | Last resort. Overlap with compute. Minimize touches. |

**The one unbreakable rule of the loop:**

```python
# BAD — disk is in the hot path; GPU stalls on every iteration
for batch in training_loop:
    data = load_from_disk()      # GPU idle, waiting on I/O
    train_step(data)

# GOOD — generate in the fastest tier, on the fly (JIT, ~20ms)
for batch in training_loop:
    data = generate_on_the_fly() # VRAM-resident, GPU never waits

# GOOD — pre-load to RAM once, stream the small slice to VRAM
data_in_ram = load_once_at_startup()
for batch in training_loop:
    batch = data_in_ram[idx]     # CPU index → tiny D2H transfer
    train_step(batch)
```

**Never, under any circumstances:**
- Pre-generate training data to `npz`/`pkl` and load it back. (`generate_oracle_data.py` was *deleted* for exactly this — on-the-fly generation took the loop from 50ms → 30ms/step with zero disk I/O.)
- Repeat disk reads inside the training loop.
- Stage intermediate tensors on disk.
- Let *any* compute touch disk when RAM or VRAM is available.

The hierarchy is sacred → disposable, top to bottom. Compute belongs at the top. Disk is where durability goes to rest, not where the loop goes to read.

---

## 2. Run small in fast memory — and **generate, don't load**

"Run small" is not "run weak." It is: size the model, batch, and buffer so the hot working set lives in the **fastest** tier that holds it, then keep the pipe full.

**Generate training data on-the-fly in VRAM.** Pre-generating to disk and reading it back is the cardinal anti-pattern — it trades a ~20ms JIT generation for a disk round-trip *every step* and pollutes the very tier you're trying to keep hot. On-the-fly generation with a background prefetch (a 2-worker `ThreadPoolExecutor` filling a VRAM buffer, zero-copy JAX, no `np.array` round-trips) took `train_easy.py` to **30ms/step, 3.0s/epoch, no disk I/O at all**.

**Pick architectures whose memory is O(n), not O(n²).** When Bella needed a 1440-step generation window in 6GB of VRAM, the WaveNet-style dilated-causal Conv family (302M params, O(n) memory) *fit* where the O(n²)-attention Transformer family did not. Choosing the linear-memory family **is** running small in fast memory — it's a modelling decision with a VRAM consequence.

**Keep frequently-needed data resident in RAM; batch the RAM→VRAM transfers.** The transfer itself is almost never the bottleneck — a 3MB price batch is ~0.25ms, 0.12% of a step. Caching prices *on the GPU* to "save" that transfer bought **1.001×** and was rejected. Don't optimize the cheap transfer; keep the data resident and move it in bulk.

**Compress before you store.** If a tensor is a broadcast of a smaller one, store the small form and expand at use:
- Encoder channels were all `jnp.tile` of a last-step value → store the `(27,64)` form, not `(27,64,64)`. **64× compression**, tile only at sample time.
- Bella's VAE latent (dim 256) is stored as `float16`, not `float32`.
- Precomputed oracle/state/policy targets stored `float16` at ~400MB/slot instead of recomputing every chunk.

**Size by the spike, not the steady state.** OOM came from a temporary 5.5GB refill spike (32 episodes generated at once) landing on top of a 5.5GB baseline. The fix was `n_envs 32→4` (spike → 0.7GB) and `buffer 32→16` (baseline → 2.8GB) — ~7GB of headroom reclaimed by accounting for the *transient*, not the average.

---

## 3. Stream the slow tier — overlap I/O with compute, never serialize it

When data exceeds RAM, you stream. The offensive move is that streaming and compute **happen at the same time** — the GPU is doing gradient math on batch *N* while the CPU prepares batch *N+1*.

**Two-phase async pipeline (the canonical pattern):**
- A **background thread** does CPU/numpy-only work: sampling, n-step reward vectorization, gather. It queues finished batches (`Queue(maxsize=prefetch=2)`).
- The **main thread** does *all* JAX: `numpy → device`, encode, train_step.
- **NEVER call `jnp.array` / `jit` / any `jax.*` from a background thread.** (`MarketDataLoader` is a plain dict cache and is *not* thread-safe — do not share it across threads.)

This overlap took an epoch from **85s → ~50–55s** by eating the 48% GPU-idle gap that serial gen-then-train had left.

**Don't preload everything — pool a working set with cursors.** Preloading 270 segments (~316MB each = **81GB**) onto a 45GB box hard-OOM'd it. The durable fix is a **SegmentPool**: ~6 active segments (~1.9GB) with per-segment linear cursors, rotating to a fresh asset-subset on exhaustion. You stream the *pool*, not the universe.

**Precompute the warehouse scan offline.** `benchmark_easy.py` triggered a `GROUP BY + COUNT(*)` over the full 25GB OHLCV table (~2min+) on *every* run. Load a precomputed list from `training_schedule.json` instead — the slow tier should be touched at build time, never at launch time.

**When the loop is starving, profile the phases before blaming transfers.** A spiky 40–50% GPU pattern was *structural*: generation spiked to 100% (Bella diffusion) while the train step sat at ~5% because latent caching made it too light. Diagnose spiky-vs-flat before assuming a sync bug.

---

## 4. Checkpoint periodically — durability without stalling the belt

Checkpoints and logs are the *only* sanctioned disk writes. Make them cheap, make them safe, make them rare enough that the GPU never waits on `pickle`.

**Write to the output/checkpoint dir, never `/tmp`.** A reboot wipes `/tmp` — periods.json and training logs gone. Log next to the checkpoints.

**Always save a final checkpoint in a `finally` block.** Track `last_checkpoint_epoch` to avoid double-saves and to catch `KeyboardInterrupt`, so a non-multiple-of-N final epoch isn't lost.

**Bound checkpoint disk with a 3-tier retention policy** (plateaus disk at ~5–8GB while keeping 100-epoch-resolution rollback):
- **Permanent** — best / complete / merged_latest. Never delete.
- **Milestones** — 1 per 100 epochs / every 10th merge.
- **Rolling** — last 5. Unlink the rest by parsing the epoch index from the filename.

**The merge/checkpoint loop is a RAM leak waiting to happen.** A long e-dojo run took `kbcached` from 12.9GB → 31GB and free RAM 27GB → 0.86GB, then *hard-froze before the OOM-killer fired*. After each merge: `del` the large ckpt dicts, `jax.clear_caches()`, `gc.collect()` in a `finally`; use `shutil.copy2` for the "latest" alias instead of re-serializing; reduce save frequency.

**Load checkpoints on CPU in the merge/orchestrator path.** Loading via `pickle → JAX arrays on GPU` OOM'd while branches held 85–90% VRAM. Add `load_checkpoint(path, cpu=True)` (params → numpy) for all orchestrator-side loads.

**Know the gotchas that silently lose work:**
- After a merge you **must restart the branches** to load the merged weights — `check_and_merge()` writes the file but the live process keeps training the old weights until restart.
- Flax `TrainState` checkpoints can be double-nested `{params:{params:{...}}}` — unwrap on load.
- Flag names differ: `train_easy.py` uses `--checkpoint`, `train_jax_fast.py` uses `--load-checkpoint`.

---

## 5. Parallelise when HW + pipeline allow — the **batch axis first**

Parallelism is a ladder. Climb it in order. The cheapest, safest rung is almost always the last one people reach for.

**Rung 1 — the batch/vmap axis (do this first, always).** At batch=1 a 50M-param forward is latency/bandwidth-bound; the GPU *idles* between sequential scan kernel launches. Batching independent episodes into one `scan` via `vmap` is **mathematically identical** and the single highest-value, zero-quality-risk win in the whole campaign:
- Batched rollout: **509s → 169s/epoch (3.0×)**, training quality unchanged.
- Parallel episode gen via `vmap` over `n_envs`: buffer refill **1.6s → 0.3s (~5×)** at `n_envs=8`; diminishing returns past that (memory bandwidth + kernel-launch overhead).
- "Put unbounded parallelism in the *batch* axis, not the device count." One GPU iterating batches already saturates an embarrassingly-parallel sample axis.

**Rung 2 — CPU/GPU concurrency (free real estate).** The CPU and GPU run at the same time. Offload everything that isn't gradient math to the CPU *while the GPU trains* — covered in §6.

**Rung 3 — multi-GPU, only when verified-safe.** This is the *last* rung, not the first, and it is dangerous on a shared box:
- `XLA_PYTHON_CLIENT_MEM_FRACTION` is **per-visible-device** with PREALLOCATE on. A blind `--gpu 1,2,3` grabs that fraction of *every* GPU at init and **OOMs the co-tenant** — the OOM is at init, not gradual.
- Default to **single-GPU on a verified-idle GPU** (`nvidia-smi --query-gpu=memory.used` ≈ 0). Treat multi-GPU as opportunistic, gated on the whole pool being empty. Lower `--gpu-frac` when co-tenanting.
- On the server: GPU 1/2/3 usable, GPU 0 is VirtualBox-reserved. Cap `train_phase2.py` at **≤2 concurrent per host** (rank-head contention deadlock, TASK_742) — but evals/inference can fill the remaining GPU in parallel. Target: 2-wide train on GPU 1/2, evals on GPU 3.
- On a **single** GPU, async/pipelined rollout to hide latency is *impossible* — JAX uses one CUDA stream. Don't chase it; batch instead.

**Two data sources on one GPU — half-cycle stagger.** Run a ~30s epoch cycle with a ~14s start delay so the GPU-heavy backprop of branch A overlaps the CPU-heavy generation of branch B, naturally spacing checkpoint saves and VRAM spikes. Merge periodically with Fisher-weighted averaging where Fisher ≈ Adam's second moment (`opt_state.nu`) — free, no extra backward pass; same-init branches are linearly mode-connected, so plain averaging works.

**Carry your launch params across restarts.** Dropping `gpu_id`/`batch_size`/`buffer_size`/`vram_fraction` on a level-progression restart silently fell back to batch=1024 with no `gpu_id`, landed two branches on one GPU, and ballooned the epoch **130s → 677s**. Parallelism gains evaporate the instant you forget where things were supposed to land.

---

## 6. Saturate every FLOP — keep the GPU on gradients, exile everything else

This is the thesis. The GPU exists to compute gradients. **Every cycle it spends on anything else is theft.** The fastest training loops in the campaign all came from the same move: find what the GPU is waiting on, and move it off the GPU's critical path.

**Kill device-to-host syncs in the hot loop — they're the #1 stall.** Every `float(jax_array)`, `int(arr[i])`, `history[key].append(float(value))` forces a D2H sync that drains the XLA pipeline *that step*. The fix is mechanical and the payoff is enormous:
- Convert a whole array to numpy *once* (`np.array(actions_jax)`) before the Python loop — never index JAX scalars inside it.
- Store metrics as async JAX futures; batch-convert to float *once* after the loop; NaN-check every ~50 iters.
- This cut **60k+ syncs/epoch → ~1–4**, raising GPU util from **~35% → ~80%+** and halving self-play time. VRAM cost: negligible (~4KB).

**Offload everything that isn't gradient math to CPU/RAM, concurrently:**
- **Price / synthetic-market generation** → CPU/RAM, transfer to VRAM.
- **Preprocessing, normalization** → CPU while the GPU trains.
- **Oracle / path solving** → CPU, in parallel to the GPU backward pass, when CPU-bound.
- **Logging, metrics aggregation** → CPU. *Never burn GPU on this.*

The rule: *if it's CPU-effective AND bandwidth is available AND it frees the GPU → do it on CPU + RAM.* The goal is one sentence — **keep the GPU saturated with gradient compute, offload everything else.**

**Hunt the op that snuck into the loop.** A 16K×16K geometry matrix computed *every step* dropped throughput from ~3,000 to **<100 steps/s** (and was ~1GB in a JIT loop). Profile the loop body; precompute or subsample any global structure that doesn't change per step.

**Precompute expensive targets once, then direct-sample.** When the oracle is a free index lookup, the episode/buffer abstraction is *pure overhead*. A profile showed **96% non-training** (55% AR rollout + 33% encoding + 8% I/O) and **4% actual gradient compute**. The fix: precompute oracle/state/policy/confidence once on the full segment at load time, then direct-sample 1024 random `(slot, cursor)` positions and encode only the tiny ~3MB price slices (not 330MB). Result: **~1850s → 60–140s/epoch (13–30×)**, training fraction 4% → 50%+. Keep a ~5% AR fraction as a hybrid to preserve state-awareness signal.

**Gate expensive auxiliaries behind a frequency counter — the cheapest win, do it first.** BC encoding ran 50×/epoch @ ~2.5s, pinning GPU util at 5–17% and the epoch at 144s. `iteration % bc_frequency == 0` with `bc_frequency=5` (50 → 10 calls) gave **2–3×** with no learning loss (lit: AWAC/IQL update BC every 4–10 steps). One-line frequency-gate *before* any fancy batched-encode rewrite.

**Collapse analytic state out of the rollout.** 4/5 state channels (position, PnL, hold_duration, heat) are deterministic arithmetic — compute them with `jnp.cumsum` under teacher forcing instead of a sequential model rollout: **~100–1000×** on that path. (Trade-off: exposure bias; mitigate with scheduled sampling and A/B before committing.)

**Reframe the cost metric.** Refill cost scales with the *number of buffer refills per epoch*, not raw GPU speed — a smaller batch means fewer refills. A laptop 90HX at batch=128 beat a 3090 at batch=512 on this axis. Conversely, too-small `n_envs=2` *starves* the batched rollout — bump to 4. Know which number you're actually paying.

---

## 7. XLA & JAX — the kernel-level go-fast knobs (and the traps)

The compiler is your ally only if you stop making it recompile and stop fighting its allocator.

**Don't trigger recompilation — it's a 10–60s tax each time:**
- Variable batch size retraces the whole graph. When per-refill episode count is random (e.g. Binomial 2–4), **pad to a fixed `B=n_envs`** and pass `B` as a `static_argname`; run padding episodes on zeros and discard.
- Keep per-call shapes constant. Pad to a fixed length (`MAX_EPISODE_LEN=512`) + mask; don't let `max_T` or per-slot counts vary.
- Pass configs and Python callables (e.g. `model_apply_fn`) via `static_argnames` — a traced callable forces a recompile or errors.
- Swap data **in place** (`env.set_prices(...)`), don't respawn a subprocess per market period — subprocess-per-period wasted ~30% of training on JIT warmup + ckpt save/load + env reinit.

**Allocator policy (settled — ignore stale guidance):**
- Keep **PREALLOCATE on (default)** + `XLA_PYTHON_CLIENT_MEM_FRACTION=0.7` (~16.8GB on a 24GB 3090). The default BFC preallocator gives smoother long-run memory and avoids fragmentation.
- **Do NOT** force `PREALLOCATE=false`, **do NOT** set `ALLOCATOR=platform`, **do NOT** use `cuda_malloc_async` (ILLEGAL_ADDRESS crashes). The old "VRAM-safety three-var recipe" is stale — the 2026-04-22 lockup was *reth I/O contention*, not JAX preallocation.
- `cuda_malloc_async` preallocating ~18GB is *expected* zero-copy buffering behavior, not a leak — but it crashes on this stack, so don't enable it. Standard usage sits ~4.3GB.
- Try `XLA_FLAGS='--xla_gpu_enable_latency_hiding_scheduler=true'` to overlap transfers with compute.

**Clear stale caches when verifying any fix.** Phantom 526%/259% alpha was a *cached buggy kernel* + leak-trained weights; alpha dropped to ~0% only after clearing `~/.cache/jax/ .jax_cache/ .xla_cache/`. Always clear JAX/XLA caches when validating a bug/leak fix.

**The JAX correctness rules that also keep you fast:**
- No `jax.lax.cond` inside `vmap` → use `jnp.where`. But know `jnp.where` **evaluates both branches** — it never saves compute, and conditional/sparse rollout is a dead end in JAX (a batched `cond` runs the full branch if *any* element triggers). Batch + reduce refinement depth instead.
- No Python control flow over traced values inside JIT (no `if jnp.any(...)`, no `len()` of a traced array). Watch for double-JIT (jitting an already-jitted fn).
- Per-step RNG: `jax.random.fold_in()`, **not** `split()` — direct split breaks seedability.
- Guard division: `jnp.maximum(x, 1e-10)`. Pad dynamic `lax.scan` shapes to a static `max_len`. Use `threading.RLock()` for reentrant contexts. `jax.block_until_ready()` before any D2H transfer.

**The scan tape is your hidden VRAM cost.** A `lax.scan`-over-time backward stores a carry tape of `O(T × |carry|)` — and `jax.checkpoint`/`stop_gradient` do **not** free it (the forward still reads the carry each step). Store the carry in **bf16** (upcast to fp32 inside the body, downcast on write) to halve the tape (18.2GB → 9.1GB). **But keep cumulative state accumulation (PnL/position/heat) in fp32** — bf16 over 336 cumulative adds gives ~260% worst-case relative error. bf16 the forward; fp32 the running sums.

**Don't let `scan` stack giant per-step outputs.** `scan` stacks every output along a new leading axis — `50 envs × 400 steps × 27×64×64 = 4.4GB` OOM on the D2H transfer. Store only tiny indices (`window_starts`, ~80KB) in the scan and reconstruct observations lazily per-env in a CPU loop.

**Trade compute for VRAM deliberately, and reverse it when speed wins:**
- `nn.remat` (gradient checkpointing) per layer: slower forward, ~50% less peak. A lever, not a default.
- `jax.lax.map` over a pass/chunk dimension caps VRAM at the **1-pass peak** (vmap materializes all passes and spikes linearly — fine at 10 passes, OOMs at 32–64). Chunk a `(1536,27,64,64)` encode (11.6GiB single-shot) into 4 chunks of 384 → ~2.9GiB peak; rows are independent so it's bit-identical. **Revert to `vmap` for single-instance runs when speed matters more than headroom.**
- SSM/Mamba: `use_parallel=False` (the 4D `(B,seq,d_inner,d_state)` parallel scan is ~12.8GB/tensor, instant OOM), `d_state=16` (4× less than 64), `nn.remat` on every block, `sequential_mode=True` on BiMamba to halve peak.
- Scan loop unrolling: start at `unroll=2`; `unroll=4` quadruples XLA code size for a forward-pass body.

---

## The offensive checklist (paste-ready triage)

When a run is slow, walk this in order — cheapest, highest-leverage first:

1. **`nvidia-smi dmon` — what's the GPU util?** If it's spiky/low (5–40%), you're stalled, not compute-bound. Don't buy a bigger GPU; find the stall.
2. **Count D2H syncs in the loop.** Any `float()`/`int()`/`.append(float(...))` on a JAX array per step? Batch-convert once after the loop. (35% → 80% util, single biggest lever.)
3. **Is anything reading disk in the loop?** Generate on-the-fly in VRAM, or load-once-to-RAM. Delete any `generate_*_to_disk` precompute.
4. **Is the batch axis full?** `vmap`/batch independent episodes into one `scan`. (3–5×, zero quality risk — do this before anything clever.)
5. **Is an expensive aux running every iteration?** Frequency-gate it (`% N == 0`). (2–3×, one line.)
6. **Are you recompiling?** Fix variable shapes → static `B` + padding; swap data in-place; configs to `static_argnames`.
7. **Is prep overlapped with compute?** Async pipeline: CPU prep in a background thread, all JAX on the main thread.
8. **Can expensive targets be precomputed once + direct-sampled?** (13–30× when the oracle is an index lookup.)
9. **Only now**, if HW + pipeline allow and the pool is verified-idle: add a GPU. Batch axis first, devices last.

Idle silicon is unrecoverable sunk cost. Every epoch the GPU spends waiting on you is an epoch you don't get back. Make it go *woooooo*.

Correctness, leakage, and audit live in **`feverfew`** — relocate the math here, prove it identical there.
