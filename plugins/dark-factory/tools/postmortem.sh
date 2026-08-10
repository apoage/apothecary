#!/usr/bin/env bash
# dark-factory postmortem — READ-ONLY forensic dump of a factory run.
#
#   postmortem.sh [target-repo]     (default: current directory)
#
# Prints the guard state, the verdict and its age, the run ledger (counts,
# targets, tail), the git evidence (dirty tree, commits/tags since arming,
# stashes, reflog) and the banner-vs-commit cross-check. It writes NOTHING and
# mutates no state — a dead run is evidence before it is mess. The
# /dark-factory:recover command reads this bundle, then judges.
set -u

TARGET="$(cd "${1:-.}" 2>/dev/null && pwd)" || { echo "postmortem: no such directory: ${1:-.}" >&2; exit 1; }

# Walk up to the project that owns the .dark-factory state.
ROOT="$TARGET"
while [ ! -f "$ROOT/.dark-factory/config.json" ]; do
  parent="$(dirname "$ROOT")"
  [ "$parent" = "$ROOT" ] && { echo "postmortem: no .dark-factory/config.json in or above $TARGET — nothing to recover; run /dark-factory:init to build the factory first." >&2; exit 1; }
  ROOT="$parent"
done

hdr() { echo; echo "== $* =="; }
echo "dark-factory postmortem — $ROOT"

hdr "GUARD STATE (.dark-factory/state.json)"
python3 - "$ROOT" <<'PY'
import datetime, json, os, sys
root = sys.argv[1]
p = os.path.join(root, ".dark-factory", "state.json")
try:
    st = json.load(open(p, encoding="utf-8"))
except Exception as e:
    print("no readable state file (%s) — the factory was never armed here, or the "
          "run predates the state model." % e)
    raise SystemExit(0)
for k in ("armed", "implementer_session", "armed_at", "disarmed_at", "stop_blocked"):
    if k in st:
        print("  %-20s %s" % (k, st[k]))
for k in sorted(set(st) - {"armed", "implementer_session", "armed_at", "disarmed_at", "stop_blocked"}):
    print("  %-20s %s" % (k, st[k]))
if st.get("armed"):
    since = ""
    try:
        d = datetime.datetime.fromisoformat(st["armed_at"])
        since = " (%d min ago)" % ((datetime.datetime.now() - d).total_seconds() / 60)
    except Exception:
        pass
    print("  → STILL ARMED%s by session %r. If that session is gone, this is a dead "
          "run holding the guard rail." % (since, st.get("implementer_session")))
else:
    print("  → disarmed: lane guard, commit gate and stop gate are inert.")
PY

hdr "VERDICT (.dark-factory/verdicts/current.json)"
python3 - "$ROOT" <<'PY'
import json, os, sys, time
root = sys.argv[1]
p = os.path.join(root, ".dark-factory", "verdicts", "current.json")
if not os.path.exists(p):
    print("  no verdict file — nothing was ever approved for commit in this run.")
    raise SystemExit(0)
age = (time.time() - os.path.getmtime(p)) / 60.0
try:
    v = json.load(open(p, encoding="utf-8"))
except Exception as e:
    print("  unreadable verdict file (%s) — treat as red." % e)
    raise SystemExit(0)
print("  task    %s" % v.get("task", "?"))
print("  green   %s" % v.get("green"))
print("  suite   %s" % v.get("suite", "?"))
print("  panel   %s" % json.dumps(v.get("panel", {})))
print("  age     %d min (written_at %s)" % (age, v.get("written_at", "?")))
print("  → the dead run's verdict is VOID for recovery: it was written for a state that\n"
      "    may have moved, by a run that then died. Re-verify from scratch.")

# The commit gate checks green + freshness + session — never that `task` matches what is
# being committed. So a still-fresh green verdict left by a dead run would open the gate
# for a resuming session that has verified NOTHING. Say so, with the fix.
try:
    cfg = json.load(open(os.path.join(root, ".dark-factory", "config.json"), encoding="utf-8"))
    max_age = (cfg.get("guards") or {}).get("verdict_max_age_minutes", 60)
except Exception:
    max_age = 60
if v.get("green") is True and age <= max_age:
    print("  → STILL GREEN AND FRESH (%d of %d min) but written for the task named above.\n"
          "    Since 0.3.3 the commit gate also refuses any verdict older than the current\n"
          "    arming, so re-arming voids this one mechanically. Move it aside anyway —\n"
          "    hooks fail open, installs in the field may predate that rule, and a lying\n"
          "    file in verdicts/ misleads whoever reads it next:\n"
          "      mkdir -p .dark-factory/recovery && mv .dark-factory/verdicts/current.json \\\n"
          "        .dark-factory/recovery/<date>-void-verdict.json"
          % (age, max_age))
PY

hdr "RUN LEDGER (.dark-factory/run-*.jsonl)"
python3 - "$ROOT" <<'PY'
import collections, datetime, glob, json, os, sys
root = sys.argv[1]
files = sorted(glob.glob(os.path.join(root, ".dark-factory", "run-*.jsonl")))
if not files:
    print("  no ledger — the run made no logged mutation. It died at startup "
          "(config, lanes, or before the first tool call).")
    raise SystemExit(0)
entries = []
for f in files:
    n = 0
    for line in open(f, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        n += 1
        try:
            entries.append(json.loads(line))
        except Exception:
            pass
    print("  %s — %d entries" % (os.path.relpath(f, root), n))
tools = collections.Counter(e.get("tool", "?") for e in entries)
roles = collections.Counter(e.get("role", "?") for e in entries)
print("  tools: %s" % ", ".join("%s=%d" % kv for kv in tools.most_common()))
print("  roles: %s" % ", ".join("%s=%d" % kv for kv in roles.most_common()))
if entries:
    print("  first %s   last %s   ← the last entry is the failure boundary"
          % (entries[0].get("ts", "?"), entries[-1].get("ts", "?")))

files_touched = collections.Counter(
    e.get("target", "") for e in entries if e.get("tool") != "Bash" and e.get("target"))
if files_touched:
    print("\n  files written (count, most-touched first):")
    for t, n in files_touched.most_common(20):
        print("    %3d  %s" % (n, t))

if entries:
    try:
        last = datetime.datetime.fromisoformat(entries[-1]["ts"])
        print("  silence: %d min since the last logged action"
              % ((datetime.datetime.now() - last).total_seconds() / 60))
    except Exception:
        pass

print("\n  last 25 entries:")
for e in entries[-25:]:
    print("    %s %-14s %-6s %s" % (e.get("ts", "?"), e.get("tool", "?"),
                                    e.get("role", "?"), (e.get("target") or "")[:100]))

# Task files the run touched, and whether they carry a STATUS banner.
tasks = [t for t in files_touched if t.endswith(".md") and "/tasks/" in ("/" + t)]
if tasks:
    print("\n  task files touched — banner check:")
    for t in sorted(tasks):
        path = t if os.path.isabs(t) else os.path.join(root, t)
        try:
            head = open(path, encoding="utf-8").read(600)
        except Exception:
            print("    MISSING   %s" % t)
            continue
        print("    %-9s %s" % ("bannered" if "STATUS (" in head else "NO BANNER", t))
PY

hdr "GIT — dirty tree (uncommitted ruins)"
# -uall: list untracked files individually — a collapsed "?? dir/" hides the debris
# bucket, and triage needs every filename.
git -C "$ROOT" status --porcelain -uall 2>/dev/null || echo "  (not a git repo)"
echo "  --- diff --stat vs HEAD ---"
git -C "$ROOT" diff --stat HEAD 2>/dev/null | tail -30

hdr "STATE FINGERPRINT (bind the rerun brief to this)"
# HEAD plus a hash over the ruins (tracked diff + the untracked file list). Independent
# verification is valid for exactly this state; if the fingerprint moves, the brief's
# verification is void. Cite both lines in .dark-factory/recovery/rerun.md.
FP_HEAD="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo none)"
# Untracked CONTENT counts: a dead run's ruins are often brand-new files, and a status
# line only carries their names. ls-files honours .gitignore, so the brief and the runtime
# state don't perturb their own fingerprint.
FP_RUINS="$( {
  git -C "$ROOT" diff HEAD 2>/dev/null
  git -C "$ROOT" status --porcelain -uall 2>/dev/null
  git -C "$ROOT" ls-files --others --exclude-standard -z 2>/dev/null \
    | ( cd "$ROOT" && xargs -0 -r sha1sum 2>/dev/null )
} | sha1sum | cut -c1-12)"
echo "  head=$FP_HEAD  ruins=$FP_RUINS"

hdr "GIT — recent commits and tags"
git -C "$ROOT" log --oneline -15 2>/dev/null
ARMED_AT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]+"/.dark-factory/state.json")).get("armed_at") or "")' "$ROOT" 2>/dev/null || true)"
if [ -n "$ARMED_AT" ]; then
  echo "  --- commits since arming ($ARMED_AT) ---"
  git -C "$ROOT" log --oneline --since="$ARMED_AT" 2>/dev/null || true
fi
echo "  --- tags, newest first ---"
git -C "$ROOT" tag --sort=-creatordate 2>/dev/null | head -10

hdr "GIT — stashes and reflog (what a recovery can restore from)"
git -C "$ROOT" stash list 2>/dev/null | head -10
git -C "$ROOT" reflog -15 2>/dev/null

hdr "PRIOR RECOVERY ARTIFACTS (.dark-factory/recovery/)"
if [ -d "$ROOT/.dark-factory/recovery" ] && [ -n "$(ls -A "$ROOT/.dark-factory/recovery" 2>/dev/null)" ]; then
  ls -1t "$ROOT/.dark-factory/recovery"
  if [ -f "$ROOT/.dark-factory/recovery/rerun.md" ]; then
    echo "  --- rerun.md (a previous recovery already left a brief — READ IT FIRST) ---"
    # Quoted with a gutter: the brief carries its own FINGERPRINT line, and quoted text
    # must never be mistakable for this run's live readings.
    sed -n '1,60p' "$ROOT/.dark-factory/recovery/rerun.md" | sed 's/^/  | /'
  fi
else
  echo "  none"
fi

hdr "FAILURE FINGERPRINT"
python3 - "$ROOT" <<'PY'
import datetime, glob, json, os, sys
root = sys.argv[1]

def j(*parts, default=None):
    try:
        return json.load(open(os.path.join(root, *parts), encoding="utf-8"))
    except Exception:
        return default

state = j(".dark-factory", "state.json", default={}) or {}
verdict = j(".dark-factory", "verdicts", "current.json")
entries = []
for f in sorted(glob.glob(os.path.join(root, ".dark-factory", "run-*.jsonl"))):
    for line in open(f, encoding="utf-8"):
        line = line.strip()
        if line:
            try:
                entries.append(json.loads(line))
            except Exception:
                pass

idle = None
if entries:
    try:
        idle = (datetime.datetime.now()
                - datetime.datetime.fromisoformat(entries[-1]["ts"])).total_seconds() / 60
    except Exception:
        pass
WRAPUP = ("handoff", "validation", "recovery", "changelog")
wrapped = any(k in (e.get("target") or "").lower() for e in entries for k in WRAPUP)
armed = bool(state.get("armed"))

print("  armed=%s  wrap-up write=%s  ledger entries=%d  silence=%s"
      % (armed, wrapped, len(entries), "?" if idle is None else "%d min" % idle))

if armed and entries and not wrapped:
    print("  → STOPPED, NOT WRAPPED UP. The ledger ends mid-loop with no handoff write and\n"
          "    no disarm. This is the shape of an exhausted model allowance or a killed\n"
          "    session: it stops BETWEEN tool calls, so the files on disk are whole — and\n"
          "    nothing in them has been verified. The ledger cannot tell allowance from\n"
          "    kill; it can tell you nothing wrapped up.")
elif armed and not entries:
    print("  → armed with an EMPTY ledger: died at startup (config, lanes, or before the\n"
          "    first tool call). Nothing to salvage; fix the cause and re-arm.")
elif not armed and entries and not wrapped:
    print("  → disarmed but never wrapped up: someone released the guard rail without the\n"
          "    exit ritual. Check for unbannered shipped tasks and an unwritten handoff.")
elif wrapped:
    print("  → a wrap-up write is in the ledger: this run may have ended cleanly. Confirm\n"
          "    against the banner check and the commit list above before recovering.")

if verdict is not None:
    print("  → a verdict file exists (green=%s). For recovery it is VOID: it was written\n"
          "    for a state that may have moved, by a run that then died. Treat as red."
          % verdict.get("green"))
else:
    print("  → no verdict: whatever is in the tree was never approved by any panel.")
PY

cat <<'EOF'

Next: locate the failure point (last ledger entry vs last thing git kept), triage
the ruins, then VERIFY the survivors independently before rebuilding anything —
the dead run's word is not evidence. Quarantine (stash / patch under
.dark-factory/recovery/) is always cheaper than a lost ruin.
EOF
