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

Correctness, leakage, and audit live in **`feverfew`** — relocate the math here, prove it identical there.
