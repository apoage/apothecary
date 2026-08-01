#!/usr/bin/env python3
"""dark-factory stop gate — Stop hook. Dual-harness (Claude Code / Kimi Code).

While the factory is armed, the implementer session cannot simply end its turn:
either there is queue work left (keep going), or only human-decision walls remain —
then the wrap-up ritual must run (banners, handoff doc, clean tree, wrap-up message)
and the factory must DISARM before stopping. Turns the exit ritual from a convention
into a mechanism.

Blocking is portable: reason on stderr + exit 2, which both harnesses honor
(upstream's ``{"decision": "block"}`` stdout JSON is the Claude-only form).

Loop guard: Claude sends ``stop_hook_active`` so a gate can avoid trapping the
session; Kimi does not, so this gate blocks ONCE per arming — it records
``stop_blocked`` in the state file (which the hooks own) and lets the next stop
through. Arming again resets it. A gate that can trap a session forever is worse
than a gate that asks once.

Other sessions stop freely.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from df_common import (read_input, find_root, load_json, save_json, config_path,
                       state_path, get_state, block_stop)


def main():
    data = read_input()
    if data.get("stop_hook_active"):
        return  # Claude's loop breaker; Kimi payloads do not carry it (see docstring)
    root = find_root(data.get("cwd"))
    if not root:
        return
    state = get_state(root)
    if not state.get("armed"):
        return
    if data.get("session_id") != state.get("implementer_session"):
        return
    if state.get("stop_blocked"):
        # We already blocked once since the last arm — let this stop through.
        state["stop_blocked"] = False
        save_json(state_path(root), state)
        return

    cfg = load_json(config_path(root), {}) or {}
    queue = (cfg.get("paths") or {}).get("queue", "tasks/QUEUE.md")

    dirty = ""
    try:
        out = subprocess.run(["git", "status", "--porcelain"], cwd=root,
                             capture_output=True, text=True, timeout=10)
        lines = [l for l in out.stdout.splitlines() if l.strip()]
        if lines:
            shown = ", ".join(l.split()[-1] for l in lines[:8])
            dirty = " Tree is DIRTY (%d files: %s%s)." % (
                len(lines), shown, ", …" if len(lines) > 8 else "")
    except Exception:
        pass

    state["stop_blocked"] = True
    save_json(state_path(root), state)
    block_stop(
        "dark-factory stop gate: the factory is still ARMED. Either (a) take the next "
        "unblocked task from %s, or (b) if only human-decision walls / missing real data "
        "remain, run the wrap-up ritual — banner every shipped task, write the dated "
        "handoff doc, leave a clean tree, post the wrap-up message —%s then disarm by "
        "running: true # dark-factory-disarm — and stop." % (queue, dirty)
    )


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        pass  # fail open — never trap a session in a broken gate
    sys.exit(0)
