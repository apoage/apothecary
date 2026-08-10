#!/usr/bin/env bash
# dark-factory init — scaffold .dark-factory/ in a target repo. Idempotent:
# existing files are never overwritten; re-running only fills in what's missing.
#
#   init.sh [target-repo]     (default: current directory)
#
# After the scaffold, the config values still need a human pass — init.sh lays
# the tracks, it does not guess the project's test command. The /dark-factory:init
# command wraps this script with that interview.
set -eu

TARGET="$(cd "${1:-.}" 2>/dev/null && pwd)" || { echo "init: no such directory: ${1:-.}" >&2; exit 1; }
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REFS="$PLUGIN_ROOT/skills/dark-factory/references"

put() { # put <src> <dst> — copy only if dst is missing
  if [ -e "$2" ]; then
    echo "keep   $2 (exists)"
  else
    mkdir -p "$(dirname "$2")"
    cp "$1" "$2"
    echo "create $2"
  fi
}

mkdir -p "$TARGET/.dark-factory/verdicts" "$TARGET/.dark-factory/recovery" "$TARGET/tasks"

put "$REFS/config.template.json"   "$TARGET/.dark-factory/config.json"
put "$REFS/QUEUE.template.md"      "$TARGET/tasks/QUEUE.md"
put "$REFS/DECISIONS.template.md"  "$TARGET/tasks/DECISIONS.md"

# Runtime files the hooks and the recovery routine write — keep them out of git.
# recovery/ carries the rerun brief and quarantine patches — a dead run's handover to the
# next session. It must not dirty the tree: a clean tree is the precondition both
# /dark-factory:arm and the wrap-up ritual check.
for pat in ".dark-factory/state.json" ".dark-factory/run-*.jsonl" ".dark-factory/verdicts/" ".dark-factory/recovery/"; do
  if [ -f "$TARGET/.gitignore" ] && grep -qxF "$pat" "$TARGET/.gitignore"; then
    echo "keep   .gitignore has $pat"
  else
    echo "$pat" >> "$TARGET/.gitignore"
    echo "append .gitignore += $pat"
  fi
done

cat <<EOF

Scaffold done in $TARGET
Next:
  1. Fill in .dark-factory/config.json — at minimum commands.test, the lane map,
     and paths.version_file/changelog if the project has them (key reference:
     skills/dark-factory/references/config.md). Anything left as REPLACE/null
     stays a guess — the factory reads this file before anything else.
  2. Seed tasks/QUEUE.md with the first ranked tasks.
  3. Run the loop: /dark-factory (or /skill:dark-factory on Kimi).
EOF
