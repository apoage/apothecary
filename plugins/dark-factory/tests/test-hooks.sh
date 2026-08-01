#!/usr/bin/env bash
# Synthetic-payload tests for the dark-factory hooks — both harness envelopes
# (Kimi `path`, Claude `file_path`). Not a pytest suite — a marker-file /
# exit-code proof in the house style.
# Usage: test-hooks.sh [hooks-dir]   (default: ../hooks relative to this script)
set -u
HOOKS="$(cd "${1:-$(dirname "$0")/../hooks}" 2>/dev/null && pwd)" || { echo "hooks dir not found: ${1:-$(dirname "$0")/../hooks}" >&2; exit 1; }
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
{"task": "tasks/x.md", "green": true, "suite": "1 passed", "written_at": "2026-08-01T00:00:00Z"}
EOF
expect_allow bash_gate.py "$(printf "$S1" 'git commit -m x')" "green fresh verdict: commit allowed"
touch -d '2 hours ago' "$PROJ/.dark-factory/verdicts/current.json"
expect_deny bash_gate.py "$(printf "$S1" 'git commit -m x')" "stale verdict: commit denied"
cat > "$PROJ/.dark-factory/verdicts/current.json" <<'EOF'
{"task": "tasks/x.md", "green": false, "suite": "0", "written_at": "2026-08-01T00:00:00Z"}
EOF
expect_deny bash_gate.py "$(printf "$S1" 'git commit -m x')" "red verdict: commit denied"

echo "== lane_guard: kimi (path) and claude (file_path) schemas =="
expect_deny  lane_guard.py "$(printf "$W2" '/tmp/df-test/src/code.py')" "claude-shape: other session denied code lane"
expect_deny  lane_guard.py "$(printf "$W3" '/tmp/df-test/src/code.py')" "kimi-shape: other session denied code lane"
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

echo "== disarm =="
expect_allow bash_gate.py "$(printf "$S1" 'true # dark-factory-disarm')" "disarm allowed"
expect_allow bash_gate.py "$(printf "$S1" 'git commit -m x')" "disarmed: commit allowed"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
