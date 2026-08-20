"""Shared helpers for dark-factory hooks. Tri-harness (Claude Code / Kimi Code / ZCode).

stdlib only. Guards fail OPEN on unexpected errors (a broken guard must not brick
the session) — except the git gate's verdict check, where failing closed is the point.

State model (one plugin serves all harnesses — all read the same files,
which is what makes "three harnesses, one repo" work):
  <root>/.dark-factory/config.json   committed, planner-owned, per-project settings
  <root>/.dark-factory/state.json    runtime: {armed, implementer_session, armed_at}
  <root>/.dark-factory/verdicts/current.json   written after fan-out verification

Envelope compatibility:
  All three harnesses post a JSON payload on stdin with snake_case fields
  (session_id, cwd, tool_name, tool_input). The deny JSON below is understood by
  Claude and ZCode; exit 2 + stderr is honored by all three as a block with the
  reason fed back to the model.
"""
import json
import os
import sys


def read_input():
    try:
        return json.load(sys.stdin)
    except Exception:
        return {}


def find_root(start):
    """Walk up from `start` to the first dir containing .dark-factory/config.json."""
    d = os.path.abspath(start or os.getcwd())
    while True:
        if os.path.isfile(os.path.join(d, ".dark-factory", "config.json")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def load_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def save_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)
    os.replace(tmp, path)


def config_path(root):
    return os.path.join(root, ".dark-factory", "config.json")


def state_path(root):
    return os.path.join(root, ".dark-factory", "state.json")


def verdict_path(root):
    return os.path.join(root, ".dark-factory", "verdicts", "current.json")


def get_state(root):
    return load_json(state_path(root), {}) or {}


def tool_file_path(tool_input):
    """The file a write/edit tool targets, across harness tool schemas.

    Claude's and ZCode's Write/Edit/MultiEdit/NotebookEdit carry ``file_path`` /
    ``notebook_path``; Kimi's Write/Edit carry ``path``.
    """
    return (tool_input.get("file_path") or tool_input.get("notebook_path")
            or tool_input.get("path") or "")


def deny(reason):
    """PreToolUse deny — the reason is fed back to the model. Valid on all harnesses."""
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def block_stop(reason):
    """Stop-hook block, portable: reason on stderr, exit 2.

    Upstream emits ``{"decision": "block", "reason": ...}`` on stdout, which is
    the Claude-only form; exit 2 + stderr carries the same semantic on every
    harness (Kimi and ZCode document it as the block contract; Claude treats it
    the same for Stop hooks).
    """
    sys.stderr.write(reason + "\n")
    sys.exit(2)


def allow():
    sys.exit(0)
