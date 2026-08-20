#!/usr/bin/env bash
# Synthetic-payload tests for the dark-factory hooks — both harness envelopes
# (Kimi `path`, Claude `file_path`). Not a pytest suite — a marker-file /
# exit-code proof in the house style.
# Usage: test-hooks.sh [hooks-dir]   (default: ../hooks relative to this script)
set -u
HOOKS="$(cd "${1:-$(dirname "$0")/../hooks}" 2>/dev/null && pwd)" || { echo "hooks dir not found: ${1:-$(dirname "$0")/../hooks}" >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ=/tmp/df-test
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; }

# run_hook <script> <json-payload> ; sets RC, OUT, ERR
run_hook() {
  OUT=$(printf '%s' "$2" | python3 "$HOOKS/$1" 2>/tmp/df-test-err); RC=$?
  ERR=$(cat /tmp/df-test-err)
}
expect_allow() { run_hook "$1" "$2"; [ $RC -eq 0 ] && [ -z "$ERR" ] && [ -z "$OUT" ] && ok "$3" || bad "$3 (rc=$RC out=$OUT err=$ERR)"; }
expect_deny()  { run_hook "$1" "$2"; [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '"permissionDecision": "deny"' && ok "$3" || bad "$3 (rc=$RC out=$OUT)"; }
expect_block() { run_hook "$1" "$2"; [ $RC -eq 2 ] && [ -n "$ERR" ] && ok "$3" || bad "$3 (rc=$RC err=$ERR)"; }

rm -rf "$PROJ"; mkdir -p "$PROJ/.dark-factory" "$PROJ/docs" "$PROJ/tasks" "$PROJ/src"
cd "$PROJ" && git init -q .
cat > "$PROJ/.dark-factory/config.json" <<'EOF'
{
  "lanes": {"planner_owns": ["docs/", ".claude/"], "shared": ["tasks/"],
            "implementer_doc_exceptions": ["handoff", "validation"]},
  "guards": {"allow_push": false, "require_verdict": true, "verdict_max_age_minutes": 60},
  "paths": {"queue": "tasks/QUEUE.md"}
}
EOF

S1='{"session_id":"kimi-s1","cwd":"/tmp/df-test","tool_name":"Bash","tool_input":{"command":"%s"}}'
W1='{"session_id":"kimi-s1","cwd":"/tmp/df-test","tool_name":"Edit","tool_input":{"path":"%s"}}'
W2='{"session_id":"claude-s2","cwd":"/tmp/df-test","tool_name":"Edit","tool_input":{"file_path":"%s"}}'
W3='{"session_id":"kimi-s2","cwd":"/tmp/df-test","tool_name":"Edit","tool_input":{"path":"%s"}}'

echo "== bash_gate: untouched when no config / disarmed =="
rm -rf /tmp/df-nocfg && mkdir -p /tmp/df-nocfg
expect_allow bash_gate.py '{"session_id":"x","cwd":"/tmp/df-nocfg","tool_input":{"command":"git commit -m x"}}' "no config: git commit allowed"
expect_allow bash_gate.py "$(printf "$S1" 'git commit -m x')" "disarmed: git commit allowed"

echo "== arm =="
expect_allow bash_gate.py "$(printf "$S1" 'true # dark-factory-arm')" "arm command allowed"
grep -q '"armed": true' "$PROJ/.dark-factory/state.json" && ok "state armed" || bad "state armed"

echo "== arm/disarm: prose quoting the markers changes nothing =="
BEFORE=$(cat "$PROJ/.dark-factory/state.json")
expect_allow bash_gate.py "$(printf "$S1" 'grep -r "dark-factory-arm" docs/')" "prose grep of arm marker allowed"
expect_allow bash_gate.py "$(printf "$S1" 'cat handoff.md  # mentions dark-factory-disarm')" "comment mention of disarm marker allowed"
expect_allow bash_gate.py "$(printf "$S1" 'echo "true # dark-factory-arm"')" "echo of the arm command is prose, not arming"
expect_allow bash_gate.py '{"session_id":"claude-s2","cwd":"/tmp/df-test","tool_input":{"command":"cat design.md # says: true # dark-factory-arm"}}' "planner prose quoting arm marker allowed"
[ "$(cat "$PROJ/.dark-factory/state.json")" = "$BEFORE" ] && ok "state untouched by marker-quoting prose (no theft, no disarm)" || bad "state untouched by marker-quoting prose"
grep -q '"implementer_session": "kimi-s1"' "$PROJ/.dark-factory/state.json" && ok "implementer-of-record not stolen" || bad "implementer-of-record not stolen"

echo "== bash_gate: the argv-parse FP class is dead =="
expect_allow bash_gate.py "$(printf "$S1" 'echo "do not git commit"')" "prose mention of git commit allowed"
expect_allow bash_gate.py "$(printf "$S1" 'cat tasks/x.md # mentions git push')" "comment mention of git push allowed"
expect_allow bash_gate.py "$(printf "$S1" 'git status')" "git status allowed"
expect_allow bash_gate.py "$(printf "$S1" 'make git-commit')" "make git-commit allowed"

echo "== bash_gate: real gates fire =="
expect_deny bash_gate.py "$(printf "$S1" 'git push origin main')" "git push denied while armed"
expect_deny bash_gate.py "$(printf "$S1" 'git commit -m x')" "implementer commit without verdict denied"
expect_deny bash_gate.py "$(printf "$S1" 'git -C /tmp/df-test commit -m x')" "git -C ... commit denied (global flags skipped)"
expect_deny bash_gate.py "$(printf "$S1" 'git tag v1')" "git tag denied without verdict"
expect_deny bash_gate.py "$(printf "$S1" 'env GIT_EDITOR=true git commit -m x')" "env-wrapped git commit denied"
expect_deny bash_gate.py '{"session_id":"claude-s2","cwd":"/tmp/df-test","tool_input":{"command":"git commit -m x"}}' "other session commit denied (not implementer)"

echo "== verdict gate: green+fresh allows, stale denies =="
mkdir -p "$PROJ/.dark-factory/verdicts"
cat > "$PROJ/.dark-factory/verdicts/current.json" <<'EOF'
{"task": "tasks/x.md", "green": true, "verify_tier": "full", "suite": "1 passed", "written_at": "2026-08-01T00:00:00Z"}
EOF
expect_allow bash_gate.py "$(printf "$S1" 'git commit -m x')" "green fresh verdict: commit allowed"
touch -d '2 hours ago' "$PROJ/.dark-factory/verdicts/current.json"
expect_deny bash_gate.py "$(printf "$S1" 'git commit -m x')" "stale verdict: commit denied"
cat > "$PROJ/.dark-factory/verdicts/current.json" <<'EOF'
{"task": "tasks/x.md", "green": false, "verify_tier": "full", "suite": "0", "written_at": "2026-08-01T00:00:00Z"}
EOF
expect_deny bash_gate.py "$(printf "$S1" 'git commit -m x')" "red verdict: commit denied"

echo "== verification tiers: escalate-never-downgrade =="
# t-suite declares suite, t-diff declares diff, t-plain declares nothing (= full)
printf '# task suite\n\nVerify: suite\n' > "$PROJ/tasks/t-suite.md"
printf '# task diff\n\nVerify: diff\n' > "$PROJ/tasks/t-diff.md"
printf '# task plain\n\nno Verify line here\n' > "$PROJ/tasks/t-plain.md"
printf '{"task": "tasks/t-suite.md", "green": true, "verify_tier": "suite", "suite": "1 passed", "written_at": "now"}\n' > "$PROJ/.dark-factory/verdicts/current.json"
expect_allow bash_gate.py "$(printf "$S1" 'git commit -m x')" "declared Verify: suite ships behind a suite-tier verdict"
printf '{"task": "tasks/t-plain.md", "green": true, "verify_tier": "suite", "suite": "1 passed", "written_at": "now"}\n' > "$PROJ/.dark-factory/verdicts/current.json"
expect_deny bash_gate.py "$(printf "$S1" 'git commit -m x')" "no Verify: line in the task = full; a suite verdict is a downgrade"
run_hook bash_gate.py "$(printf "$S1" 'git commit -m x')"; printf '%s' "$OUT" | grep -q 'ESCALATE-NEVER-DOWNGRADE' \
  && ok "  → denied as a downgrade (named), not as staleness" || bad "downgrade deny wording"
printf '{"task": "tasks/t-suite.md", "green": true, "verify_tier": "full", "suite": "1 passed", "written_at": "now"}\n' > "$PROJ/.dark-factory/verdicts/current.json"
expect_allow bash_gate.py "$(printf "$S1" 'git commit -m x')" "a RAISED tier is always legal (suite task, full verdict)"
printf '{"task": "tasks/t-suite.md", "green": true, "suite": "1 passed", "written_at": "now"}\n' > "$PROJ/.dark-factory/verdicts/current.json"
expect_deny bash_gate.py "$(printf "$S1" 'git commit -m x')" "verdict without verify_tier denied (cannot prove the tier it used)"
run_hook bash_gate.py "$(printf "$S1" 'git commit -m x')"; printf '%s' "$OUT" | grep -q 'verify_tier' \
  && ok "  → the deny names the missing field" || bad "missing-tier deny wording"
printf '{"task": "tasks/t-suite.md", "sprint_tasks": ["tasks/t-diff.md"], "green": true, "verify_tier": "diff", "suite": "1 passed", "written_at": "now"}\n' > "$PROJ/.dark-factory/verdicts/current.json"
expect_allow bash_gate.py "$(printf "$S1" 'git commit -m x')" "sprint batch verifying at its strictest declared tier (diff) allowed"
printf '{"task": "tasks/t-suite.md", "sprint_tasks": ["tasks/t-diff.md"], "green": true, "verify_tier": "suite", "suite": "1 passed", "written_at": "now"}\n' > "$PROJ/.dark-factory/verdicts/current.json"
expect_deny bash_gate.py "$(printf "$S1" 'git commit -m x')" "sprint held to its STRICTEST member (diff), not its first row (suite)"
printf '{"task": "tasks/gone.md", "green": true, "verify_tier": "suite", "suite": "1 passed", "written_at": "now"}\n' > "$PROJ/.dark-factory/verdicts/current.json"
expect_deny bash_gate.py "$(printf "$S1" 'git commit -m x')" "unreadable task file fails toward full, never toward trust"

echo "== lane_guard: kimi (path) and claude/zcode (file_path) schemas =="
expect_deny  lane_guard.py "$(printf "$W2" '/tmp/df-test/src/code.py')" "claude-shape: other session denied code lane"
expect_deny  lane_guard.py "$(printf "$W3" '/tmp/df-test/src/code.py')" "kimi-shape: other session denied code lane"
expect_deny  lane_guard.py '{"session_id":"zcode-s9","cwd":"/tmp/df-test","tool_name":"Write","tool_input":{"file_path":"/tmp/df-test/src/code.py"}}' "zcode-shape (file_path): other session denied code lane"
expect_allow lane_guard.py "$(printf "$W2" '/tmp/df-test/tasks/queue.md')" "other session allowed shared lane"
expect_deny  lane_guard.py "$(printf "$W1" '/tmp/df-test/docs/design.md')" "implementer denied planner lane"
expect_allow lane_guard.py "$(printf "$W1" '/tmp/df-test/docs/2026-08-01-handoff-x.md')" "implementer allowed handoff doc"
expect_deny  lane_guard.py "$(printf "$W1" '/tmp/df-test/.dark-factory/config.json')" "implementer denied config.json"
expect_allow lane_guard.py "$(printf "$W1" '/tmp/outside-project.txt')" "outside project untouched"

echo "== stop_gate: block once per arm =="
STOP1='{"session_id":"kimi-s1","cwd":"/tmp/df-test"}'
expect_block stop_gate.py "$STOP1" "armed implementer: stop blocked (exit 2 + reason)"
expect_allow stop_gate.py "$STOP1" "second stop allowed (loop guard)"
run_hook bash_gate.py "$(printf "$S1" 'true # dark-factory-arm')"
expect_block stop_gate.py "$STOP1" "re-arm: stop blocked again"
expect_allow stop_gate.py '{"session_id":"claude-s2","cwd":"/tmp/df-test"}' "non-implementer stops freely"

echo "== run_log: one ledger, harness tagged =="
export KIMI_CODE_HOME=/home/lukas/.kimi-code
expect_allow run_log.py "$(printf "$W1" '/tmp/df-test/tasks/queue.md')" "run_log allows"
expect_allow run_log.py "$(printf "$S1" 'git status')" "run_log allows (bash)"
LOG=$(ls "$PROJ"/.dark-factory/run-*.jsonl)
grep -q '"harness": "kimi"' "$LOG" && grep -q '"role": "implementer"' "$LOG" && ok "run log entries written with harness+role" || bad "run log entries ($LOG: $(cat "$LOG" 2>/dev/null))"
unset KIMI_CODE_HOME
export ZCODE_PLUGIN_ROOT=/home/lukas/.zcode
expect_allow run_log.py "$(printf "$S1" 'git status')" "run_log allows (zcode env)"
LOG=$(ls "$PROJ"/.dark-factory/run-*.jsonl)
grep -q '"harness": "zcode"' "$LOG" && ok "zcode-tagged entry in the one ledger (ZCODE_PLUGIN_ROOT marker)" || bad "zcode harness tag ($LOG)"
unset ZCODE_PLUGIN_ROOT

echo "== disarm =="
expect_allow bash_gate.py "$(printf "$S1" 'true # dark-factory-disarm')" "disarm allowed"
expect_allow bash_gate.py "$(printf "$S1" 'git commit -m x')" "disarmed: commit allowed"

echo "== init.sh: scaffold, idempotent =="
INIT_PROJ=/tmp/df-init
rm -rf "$INIT_PROJ"; mkdir -p "$INIT_PROJ"
bash "$SCRIPT_DIR/../tools/init.sh" "$INIT_PROJ" >/dev/null
[ -f "$INIT_PROJ/.dark-factory/config.json" ] && [ -f "$INIT_PROJ/tasks/QUEUE.md" ] && [ -f "$INIT_PROJ/tasks/DECISIONS.md" ] && ok "init creates config+queue+decisions" || bad "init creates config+queue+decisions"
grep -qxF '.dark-factory/state.json' "$INIT_PROJ/.gitignore" && grep -qxF '.dark-factory/verdicts/' "$INIT_PROJ/.gitignore" && ok "init gitignores runtime files" || bad "init gitignores runtime files"
echo '{"custom": true}' > "$INIT_PROJ/.dark-factory/config.json"
bash "$SCRIPT_DIR/../tools/init.sh" "$INIT_PROJ" >/dev/null
grep -q '"custom": true' "$INIT_PROJ/.dark-factory/config.json" && [ "$(grep -c 'state\.json' "$INIT_PROJ/.gitignore")" = 1 ] && ok "init re-run keeps existing files, no gitignore dupes" || bad "init idempotency"

echo "== postmortem.sh: reads a dead run, mutates nothing =="
RUIN=/tmp/df-ruin
rm -rf "$RUIN"; mkdir -p "$RUIN/tasks" "$RUIN/src"
bash "$SCRIPT_DIR/../tools/init.sh" "$RUIN" >/dev/null
git -C "$RUIN" init -q .
printf '# task one\n\nno banner here.\n' > "$RUIN/tasks/t1.md"
git -C "$RUIN" add -A >/dev/null 2>&1
git -C "$RUIN" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
# a run that armed under a session which is now gone, then died in the tree
RUIN_S='{"session_id":"dead-session","cwd":"/tmp/df-ruin","tool_name":"%s","tool_input":{"%s":"%s"}}'
run_hook bash_gate.py "$(printf "$RUIN_S" Bash command 'true # dark-factory-arm')"
run_hook run_log.py  "$(printf "$RUIN_S" Edit path '/tmp/df-ruin/tasks/t1.md')"
run_hook run_log.py  "$(printf "$RUIN_S" Edit path '/tmp/df-ruin/src/half.py')"
printf 'def half(\n' > "$RUIN/src/half.py"
BEFORE_STATE=$(cat "$RUIN/.dark-factory/state.json")
PM=$(bash "$SCRIPT_DIR/../tools/postmortem.sh" "$RUIN" 2>&1); PMRC=$?
[ $PMRC -eq 0 ] && ok "postmortem exits 0 on a ruined project" || bad "postmortem exits 0 (rc=$PMRC: $PM)"
printf '%s' "$PM" | grep -q 'STILL ARMED' && printf '%s' "$PM" | grep -q 'dead-session' \
  && ok "postmortem reports the dead run still holds the guard rail" || bad "postmortem reports armed state"
printf '%s' "$PM" | grep -q 'src/half.py' && printf '%s' "$PM" | grep -q 'NO BANNER' \
  && ok "postmortem surfaces the dirty ruin and the unbannered task" || bad "postmortem ledger/banner cross-check"
printf '%s' "$PM" | grep -q 'STOPPED, NOT WRAPPED UP' \
  && ok "postmortem fingerprints the budget-death shape (armed, no wrap-up, no disarm)" || bad "postmortem failure fingerprint"
[ "$(cat "$RUIN/.dark-factory/state.json")" = "$BEFORE_STATE" ] && ok "postmortem is read-only (state untouched)" || bad "postmortem mutated state"
# the state fingerprint the rerun brief binds to must move when the ruins move
FP1=$(printf '%s' "$PM" | grep -o 'ruins=[0-9a-f]*')
printf 'def half(\n  x\n' > "$RUIN/src/half.py"
FP2=$(bash "$SCRIPT_DIR/../tools/postmortem.sh" "$RUIN" 2>&1 | grep -o 'ruins=[0-9a-f]*')
[ -n "$FP1" ] && [ -n "$FP2" ] && [ "$FP1" != "$FP2" ] && ok "state fingerprint changes when the ruins change" || bad "state fingerprint ($FP1 vs $FP2)"
# a brief left by a previous recovery must be surfaced, not buried
mkdir -p "$RUIN/.dark-factory/recovery"
printf 'ARM: NOT GREEN — waiting on owner decision D-7\nFINGERPRINT: head=deadbee ruins=000000000000\nNEXT ACTION: none\n' > "$RUIN/.dark-factory/recovery/rerun.md"
bash "$SCRIPT_DIR/../tools/postmortem.sh" "$RUIN" 2>&1 | grep -q 'ARM: NOT GREEN' \
  && ok "postmortem surfaces an existing rerun brief" || bad "postmortem surfaces rerun brief"
grep -qxF '.dark-factory/recovery/' "$RUIN/.gitignore" \
  && ok "init gitignores the recovery dir (brief never dirties the tree)" || bad "recovery dir gitignored"
echo "== recover is planner work: its lanes are open while the dead run holds the code =="
# /dark-factory:recover runs as the PLANNER against a factory still armed by a session
# that no longer exists. Everything the routine writes must be allowed, everything it
# promises not to touch must be denied — proven against the SHIPPED template lane map.
PL='{"session_id":"planner-x","cwd":"/tmp/df-ruin","tool_name":"Edit","tool_input":{"file_path":"%s"}}'
PLK='{"session_id":"planner-x","cwd":"/tmp/df-ruin","tool_name":"Write","tool_input":{"path":"%s"}}'
PLB='{"session_id":"planner-x","cwd":"/tmp/df-ruin","tool_name":"Bash","tool_input":{"command":"%s"}}'
expect_allow lane_guard.py "$(printf "$PL"  '/tmp/df-ruin/.dark-factory/recovery/rerun.md')" "planner may write the rerun brief"
expect_allow lane_guard.py "$(printf "$PLK" '/tmp/df-ruin/.dark-factory/recovery/2026-08-10-half.patch')" "planner may write a quarantine patch (kimi envelope)"
expect_allow lane_guard.py "$(printf "$PL"  '/tmp/df-ruin/tasks/t1.md')" "planner may fix a lying banner (shared lane)"
expect_allow lane_guard.py "$(printf "$PL"  '/tmp/df-ruin/tasks/DECISIONS.md')" "planner may seed a DECISIONS row"
expect_allow lane_guard.py "$(printf "$PL"  '/tmp/df-ruin/docs/2026-08-10-recovery.md')" "planner may write the recovery doc under any filename"
expect_deny  lane_guard.py "$(printf "$PL"  '/tmp/df-ruin/src/half.py')" "planner may NOT repair code"
expect_deny  lane_guard.py "$(printf "$PL"  '/tmp/df-ruin/CHANGELOG.md')" "planner may NOT touch the changelog"
# quarantine and inspection must survive the no-push wall: `git stash push` is not a push
expect_allow bash_gate.py "$(printf "$PLB" 'git stash push -m \"df-recover 2026-08-10: half-built\"')" "git stash push allowed (not caught by the no-push wall)"
expect_allow bash_gate.py "$(printf "$PLB" 'git stash push --include-untracked')" "git stash push --include-untracked allowed"
expect_allow bash_gate.py "$(printf "$PLB" 'git stash list')" "git stash list allowed"
expect_allow bash_gate.py "$(printf "$PLB" 'git diff HEAD')" "git diff allowed"
expect_deny  bash_gate.py "$(printf "$PLB" 'git push origin main')" "a real git push still denied"
expect_deny  bash_gate.py "$(printf "$PLB" 'git commit -m recovered')" "planner may NOT commit (verdict belongs to the armed run)"
# /dark-factory:arm claims the gate refuses to arm without a config — prove it
expect_deny bash_gate.py '{"session_id":"planner-x","cwd":"/tmp/df-nocfg","tool_input":{"command":"true # dark-factory-arm"}}' "arming without a config is denied, with the init pointer"

echo "== the arming rule: a verdict from a previous run cannot ship this one =="
# The gate cannot tell WHICH task a verdict approved, so freshness alone let a dead run's
# minutes-old green verdict open the gate for whatever the next session armed over
# (tasks/2026-08-11-bug-verdict-predates-arming.md). A verdict must postdate the arming.
mkdir -p "$RUIN/.dark-factory/verdicts"
cat > "$RUIN/.dark-factory/verdicts/current.json" <<'EOF'
{"task": "tasks/t1.md", "green": true, "verify_tier": "full", "suite": "1 passed", "written_at": "2026-08-10T21:00:00"}
EOF
sleep 1   # mtime resolution: the verdict must be demonstrably OLDER than the arming
run_hook bash_gate.py '{"session_id":"resumer","cwd":"/tmp/df-ruin","tool_name":"Bash","tool_input":{"command":"true # dark-factory-arm"}}'
grep -q '"armed_epoch"' "$RUIN/.dark-factory/state.json" && ok "arming stamps armed_epoch into the state file" || bad "armed_epoch missing"
RES='{"session_id":"resumer","cwd":"/tmp/df-ruin","tool_name":"Bash","tool_input":{"command":"git commit -m resumed"}}'
expect_deny bash_gate.py "$RES" "green+fresh verdict PREDATING the arming is denied"
run_hook bash_gate.py "$RES"; printf '%s' "$OUT" | grep -q 'PREDATES this arming' \
  && ok "the denial names the real problem (previous run's verdict), not just staleness" || bad "deny reason wording"
# the same session, having re-verified, rewrites the verdict — the gate opens
touch "$RUIN/.dark-factory/verdicts/current.json"
expect_allow bash_gate.py "$RES" "rewriting the verdict after arming re-opens the gate"
# with a green, fresh verdict on disk the postmortem must SAY SO — the leftover-verdict
# warning is the recovery routine's cue to move it aside (two-sided: absent again below)
bash "$SCRIPT_DIR/../tools/postmortem.sh" "$RUIN" 2>&1 | grep -q 'STILL GREEN AND FRESH' \
  && ok "postmortem flags a green+fresh verdict as a leftover to move aside" || bad "leftover-verdict warning missing"
# the two rules are independent: a LONG run whose verdict postdates the arming but has
# aged out must still be refused, and with the staleness reason (the arming rule must not
# shadow it — with a seconds-old arming every stale verdict also predates, so this is the
# only place the STALE branch is exercised)
python3 - "$RUIN" <<'PY'
import datetime, json, os, sys, time
p = os.path.join(sys.argv[1], ".dark-factory", "state.json")
st = json.load(open(p))
long_ago = time.time() - 3 * 3600                      # armed three hours ago
st["armed_epoch"] = long_ago
st["armed_at"] = datetime.datetime.fromtimestamp(long_ago).isoformat(timespec="seconds")
json.dump(st, open(p, "w"), indent=2)
PY
touch -d '90 minutes ago' "$RUIN/.dark-factory/verdicts/current.json"
expect_deny bash_gate.py "$RES" "verdict newer than the arming but aged out: denied"
run_hook bash_gate.py "$RES"; printf '%s' "$OUT" | grep -q 'is STALE (90 min old, max 60)' \
  && ok "  → refused as STALE, not as predating (the rules stay independent)" || bad "stale reason shadowed by the arming rule"

# back-compat: a state file from <= 0.3.2 carries armed_at but no armed_epoch
python3 - "$RUIN" <<'PY'
import json, os, sys, time
p = os.path.join(sys.argv[1], ".dark-factory", "state.json")
st = json.load(open(p)); st.pop("armed_epoch", None)
st["armed_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")  # now, in the 0.3.2 format
json.dump(st, open(p, "w"), indent=2)
PY
# armed_at is second-truncated, so the fallback can only resolve whole seconds: make the
# verdict plainly older than the arming (still fresh — 1 min, well under the 60 min cap).
touch -d '1 minute ago' "$RUIN/.dark-factory/verdicts/current.json"
expect_deny bash_gate.py "$RES" "pre-0.3.3 state (armed_at only) still enforces the arming rule"
python3 - "$RUIN" <<'PY'
import json, os, sys
p = os.path.join(sys.argv[1], ".dark-factory", "state.json")
st = json.load(open(p)); st.pop("armed_epoch", None); st.pop("armed_at", None)
json.dump(st, open(p, "w"), indent=2)
PY
expect_allow bash_gate.py "$RES" "state with neither stamp degrades to 0.3.2 behaviour, never bricks"
run_hook bash_gate.py '{"session_id":"resumer","cwd":"/tmp/df-ruin","tool_name":"Bash","tool_input":{"command":"true # dark-factory-arm"}}'
# recovery still moves the file aside: hooks fail open, and a green lie misleads readers
mkdir -p "$RUIN/.dark-factory/recovery"
mv "$RUIN/.dark-factory/verdicts/current.json" "$RUIN/.dark-factory/recovery/2026-08-10-void-verdict.json"
expect_deny bash_gate.py "$RES" "with the verdict moved aside, the gate fails closed on absence"
[ -f "$RUIN/.dark-factory/recovery/2026-08-10-void-verdict.json" ] && ok "voided verdict is preserved as evidence, not deleted" || bad "voided verdict lost"
PMV=$(bash "$SCRIPT_DIR/../tools/postmortem.sh" "$RUIN" 2>&1)
# A brief carries its own FINGERPRINT line, so the output holds two `ruins=` values: this
# run's live reading, and the quoted one from the brief. They must be unmistakable.
LIVE_FP=$(printf '%s' "$PMV" | grep -c '^  head=.*ruins=')
QUOTED_FP=$(printf '%s' "$PMV" | grep -c '^  | FINGERPRINT:')
[ "$LIVE_FP" = 1 ] && [ "$QUOTED_FP" = 1 ] \
  && ok "quoted brief is gutter-prefixed; the live fingerprint stays unambiguous" \
  || bad "fingerprint ambiguity (live=$LIVE_FP quoted=$QUOTED_FP)"
printf '%s' "$PMV" | grep -q 'STILL GREEN AND FRESH' \
  && bad "leftover-verdict warning still shown after the verdict was voided" || ok "warning clears once the verdict is voided"

echo "== init.sh: migrates a repo scaffolded before recovery/ existed =="
MIG=/tmp/df-migrate
rm -rf "$MIG"; mkdir -p "$MIG/.dark-factory" "$MIG/tasks"
printf '{"project_name":"real","commands":{"test":"pytest -q"}}\n' > "$MIG/.dark-factory/config.json"
printf '# QUEUE\n- [ ] a real row\n' > "$MIG/tasks/QUEUE.md"
printf '.dark-factory/state.json\n.dark-factory/run-*.jsonl\n.dark-factory/verdicts/\n' > "$MIG/.gitignore"
MIG_CFG=$(sha1sum < "$MIG/.dark-factory/config.json"); MIG_Q=$(sha1sum < "$MIG/tasks/QUEUE.md")
bash "$SCRIPT_DIR/../tools/init.sh" "$MIG" >/dev/null
[ "$(sha1sum < "$MIG/.dark-factory/config.json")" = "$MIG_CFG" ] && [ "$(sha1sum < "$MIG/tasks/QUEUE.md")" = "$MIG_Q" ] \
  && ok "migration leaves a filled config and edited queue byte-identical" || bad "migration mutated existing files"
[ "$(wc -l < "$MIG/.gitignore")" = 4 ] && grep -qxF '.dark-factory/recovery/' "$MIG/.gitignore" \
  && ok "migration appends exactly the one missing ignore line" || bad "migration gitignore delta ($(tr '\n' ' ' < "$MIG/.gitignore"))"

echo "== docs: every {{variable}} in the commands resolves against the template =="
python3 - "$SCRIPT_DIR/.." <<'PY' && ok "no unresolved {{variables}} in commands/*.md" || bad "unresolved {{variable}} in commands/*.md"
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
tpl = json.load(open(root / "skills/dark-factory/references/config.template.json"))
missing = []
for f in sorted((root / "commands").glob("*.md")):
    for v in sorted(set(re.findall(r"\{\{([a-zA-Z0-9_.]+)\}\}", f.read_text()))):
        cur = tpl
        for part in v.split("."):
            if not isinstance(cur, dict) or part not in cur:
                missing.append("%s: {{%s}}" % (f.name, v)); break
            cur = cur[part]
if missing:
    print("\n".join(missing), file=sys.stderr)
sys.exit(1 if missing else 0)
PY

echo "== doctrine drift guard: concurrency rules in the skill + every agent brief =="
# The shared-mutable-state doctrine (run-36 lessons) must survive in whatever copy runs
# this suite — source or managed install. Drop a rule here, fail there too.
DOCTRINE=1
grep -q "Freeze before you lens" "$SCRIPT_DIR/../skills/dark-factory/SKILL.md" || DOCTRINE=0
grep -q "Private scratch per agent" "$SCRIPT_DIR/../skills/dark-factory/SKILL.md" || DOCTRINE=0
grep -qi "No shared default paths" "$SCRIPT_DIR/../skills/dark-factory/SKILL.md" || DOCTRINE=0
grep -qi "fail closed on build failure" "$SCRIPT_DIR/../skills/dark-factory/SKILL.md" || DOCTRINE=0
[ $DOCTRINE = 1 ] && ok "skill carries the four concurrency rules" || bad "skill missing concurrency doctrine"
N_AGENTS=$(ls "$SCRIPT_DIR/../agents"/dark-factory-*.md 2>/dev/null | wc -l)
N_SCRATCH=$(grep -li "private scratch" "$SCRIPT_DIR/../agents"/dark-factory-*.md 2>/dev/null | wc -l)
[ "$N_SCRATCH" = "$N_AGENTS" ] && [ "$N_AGENTS" -ge 4 ] \
  && ok "every agent brief names its private scratch ($N_SCRATCH/$N_AGENTS)" \
  || bad "agent briefs missing private-scratch naming ($N_SCRATCH/$N_AGENTS)"
# no agent brief may point a multi-agent run at the shared session scratchpad:
# every "scratchpad" mention in a brief must be a BAN (negated), never a destination
N_DEST=$(grep -hi "scratchpad" "$SCRIPT_DIR/../agents"/dark-factory-*.md 2>/dev/null | grep -vic "never")
[ "$N_DEST" = 0 ] && ok "no agent brief directs output to a shared session scratchpad" \
  || bad "agent brief uses the session scratchpad as a destination ($N_DEST lines)"

echo "== tri-harness portability: manifests + hooks.json valid on all three =="
# ZCode's manifest/hook rules are the strictest published set: name regex, component
# paths inside the plugin root, exactly seven event names, valid matcher regexes,
# command-type hooks only. What passes here loads on Claude and Kimi too (both accept
# this same shape — it is the shared contract the dual-harness merge was built on).
python3 - "$SCRIPT_DIR/.." <<'PY' && ok "manifests + hooks.json valid on Claude, Kimi, and ZCode" || bad "tri-harness manifest/hook schema"
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
pj = json.load(open(root / ".claude-plugin" / "plugin.json"))
kj = json.load(open(root / "kimi.plugin.json"))
assert pj["version"] == kj["version"], "manifest version drift"
for m in (pj, kj):
    assert re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,127}", m["name"]), m["name"]
for comp in (pj.get("skills"), pj.get("commands")):
    if comp:
        for d in ([comp] if isinstance(comp, str) else comp):
            assert not pathlib.Path(d).is_absolute(), d
hooks = json.load(open(root / "hooks" / "hooks.json"))["hooks"]
events = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
          "PostToolUse", "PostToolUseFailure", "Stop"}
assert set(hooks) <= events, set(hooks) - events
for groups in hooks.values():
    for g in groups:
        re.compile(g.get("matcher", ""))   # an invalid regex never matches anywhere
        for hk in g["hooks"]:
            assert hk["type"] == "command" and hk["command"], hk
            assert "${CLAUDE_PLUGIN_ROOT}" in hk["command"], hk["command"]
PY

# recovery's release valve: a session that is NOT the dead implementer may disarm
expect_allow bash_gate.py "$(printf "$RUIN_S" Bash command 'true # dark-factory-disarm')" "recover can disarm a dead run"
rm -rf /tmp/df-nostate && mkdir -p /tmp/df-nostate
OUT_NC=$(bash "$SCRIPT_DIR/../tools/postmortem.sh" /tmp/df-nostate 2>&1); RC_NC=$?
[ $RC_NC -ne 0 ] && printf '%s' "$OUT_NC" | grep -q 'dark-factory:init' && ok "postmortem on a repo with no factory points at init" || bad "postmortem no-config path (rc=$RC_NC: $OUT_NC)"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
