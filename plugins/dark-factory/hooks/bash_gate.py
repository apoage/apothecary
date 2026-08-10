#!/usr/bin/env python3
"""dark-factory bash gate — PreToolUse on Bash. Dual-harness (Claude Code / Kimi Code).

Three jobs:
  1. Arm / disarm. `true # dark-factory-arm` records THIS session as the implementer
     and arms every guard; `true # dark-factory-disarm` releases them. The hook owns
     the state file — the model can only ask, never write the state itself.
  2. No-push wall. While armed, `git push` is denied outright (commits/tags stay
     local) unless guards.allow_push is explicitly true in config.
  3. Commit gate. While armed, `git commit` / `git tag` require a GREEN verdict file
     (.dark-factory/verdicts/current.json) written after fan-out verification, fresh
     by mtime, and NEWER THAN THE CURRENT ARMING. Missing / not-green / stale /
     predating the arming → deny, fail closed. The arming clause is what stops a
     previous run's leftover verdict (green, minutes old, written for work that
     already shipped) from opening the gate for whatever the next session arms over.

Git detection is PARSED, not substring. The command text is split into segments
(``&& || ; | newline``), each segment is lexed, and a gate only fires when an
argv actually EXECUTES git with that subcommand (global flags and one level of
env/sudo wrappers skipped). A raw regex against the command text would deny
prose that merely MENTIONS `git commit` — a `cat` of a task file, an echo, the
instruction NOT to commit (the live false-positive class in factory-multiline's
#7 design lesson). An unparseable segment fails OPEN — these hooks are lane
markings, never the boundary.

Arm/disarm detection is parsed the same way, and here it matters more because
those branches MUTATE state instead of denying: a raw substring test lets a
`grep`/`cat`/`echo` that merely quotes ``dark-factory-disarm`` silently disarm
an armed factory, and lets a planner session quoting the arm marker steal
implementer-of-record (both observed live during dual-harness self-validation).
So a command only counts as arm/disarm when every executed segment is the no-op
(``true`` or ``:``) with the marker confined to a comment — see marker_command().

Disarmed projects and projects without a dark-factory config are untouched.
"""
import datetime
import os
import re
import shlex
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from df_common import (read_input, find_root, load_json, save_json, config_path,
                       state_path, verdict_path, get_state, deny, allow)

ARM = "dark-factory-arm"
DISARM = "dark-factory-disarm"

_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_WRAPPERS = {"env", "sudo", "time", "nohup", "command"}
#: git global flags that consume the NEXT token as their value.
_GIT_VALUE_FLAGS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}


def marker_command(cmd, marker):
    """True iff CMD executes nothing but the no-op marker command for MARKER.

    Every parsed segment must lex to exactly ``true`` (or ``:``) plus an ignored
    ``#`` comment, and at least one such comment must contain the marker. Prose
    that merely QUOTES the marker — `grep -r "dark-factory-arm" docs/`, an echo,
    a heredoc writing instructions — fails the no-op test and falls through to
    the normal gates instead of mutating state. Unparseable → False (falls
    through; fail open).
    """
    saw = False
    for segment in re.split(r"&&|\|\||[;|\n]", cmd):
        segment = segment.strip()
        if not segment:
            continue
        try:
            argv = shlex.split(segment)
        except ValueError:
            return False
        if "#" in argv:
            i = argv.index("#")
            code, comment = argv[:i], " ".join(argv[i + 1:])
        else:
            code, comment = argv, ""
        if code not in (["true"], [":"]):
            return False
        if marker in comment:
            saw = True
    return saw


def git_subcommands(cmd):
    """The git subcommands this command text would actually EXECUTE, in order.

    Parsed, never substring: `echo "do not git commit"` yields nothing; `git -C
    repo commit` yields ``commit``; `make git-commit` yields nothing.
    """
    out = []
    for segment in re.split(r"&&|\|\||[;|\n]", cmd):
        segment = segment.strip()
        if not segment:
            continue
        try:
            argv = shlex.split(segment)
        except ValueError:
            continue  # unparseable — fail open, this is a lane marking
        after_wrapper = False
        while argv:
            if _ASSIGNMENT.match(argv[0]):
                argv = argv[1:]                    # VAR=value prefix
            elif os.path.basename(argv[0]) in _WRAPPERS:
                argv = argv[1:]                    # one level of env/sudo/time/...
                after_wrapper = True
            elif after_wrapper and argv[0].startswith("-"):
                argv = argv[1:]                    # the wrapper's own flags
            else:
                break
        if not argv or os.path.basename(argv[0]) != "git":
            continue
        i = 1
        while i < len(argv):
            tok = argv[i]
            if tok in _GIT_VALUE_FLAGS:
                i += 2
            elif tok.startswith("-"):
                i += 1
            else:
                out.append(tok)
                break
    return out


def main():
    data = read_input()
    cmd = (data.get("tool_input") or {}).get("command") or ""
    root = find_root(data.get("cwd"))

    if marker_command(cmd, DISARM):
        if root:
            state = get_state(root)
            state.update({"armed": False, "implementer_session": None,
                          "stop_blocked": False,
                          "disarmed_at": datetime.datetime.now().isoformat(timespec="seconds")})
            save_json(state_path(root), state)
        allow()

    if marker_command(cmd, ARM):
        if not root:
            deny("dark-factory: no .dark-factory/config.json found in or above %r — "
                 "run the skill's setup step first (it writes the config from the "
                 "template after the owner confirms)." % (data.get("cwd") or "?"))
        now = datetime.datetime.now()
        save_json(state_path(root), {
            "armed": True,
            "implementer_session": data.get("session_id"),
            "armed_at": now.isoformat(timespec="seconds"),
            # Epoch beside the ISO string: the commit gate compares it against the
            # verdict's mtime, and an unambiguous float beats reparsing local time
            # (second-truncated, DST-ambiguous). armed_at stays for humans and for
            # state files written by <= 0.3.2.
            "armed_epoch": now.timestamp(),
            "stop_blocked": False,
        })
        allow()

    if not root:
        allow()
    state = get_state(root)
    if not state.get("armed"):
        allow()

    cfg = load_json(config_path(root), {}) or {}
    guards = cfg.get("guards", {})
    subs = git_subcommands(cmd)

    if "push" in subs and not guards.get("allow_push", False):
        deny("dark-factory git gate: PUSH IS FORBIDDEN while the factory is armed — "
             "commits and tags stay local; the owner pushes after morning review. "
             "(Override only via guards.allow_push in .dark-factory/config.json.)")

    if any(s in ("commit", "tag") for s in subs) and guards.get("require_verdict", True):
        if data.get("session_id") != state.get("implementer_session"):
            deny("dark-factory git gate: the factory is armed — commits/tags belong to "
                 "the implementer session. If you are the planner, document instead; "
                 "if the factory is done, disarm first: true # dark-factory-disarm")
        vp = verdict_path(root)
        verdict = load_json(vp)
        if verdict is None:
            deny("dark-factory git gate: no verdict file at .dark-factory/verdicts/"
                 "current.json — run the fan-out verification for this task and write "
                 "the verdict file (schema in the dark-factory skill), then commit.")
        if verdict.get("green") is not True:
            deny("dark-factory git gate: verdict for %r is NOT green — fix the findings, "
                 "re-verify what changed, and rewrite the verdict file before committing."
                 % verdict.get("task", "?"))
        max_age_min = guards.get("verdict_max_age_minutes", 60)
        try:
            mtime = os.path.getmtime(vp)
        except OSError:
            mtime = None
        if mtime is None:
            deny("dark-factory git gate: verdict file is STALE (%s min old, max %s) — "
                 "verification must be fresher than the code it approves. Re-run the "
                 "panel and rewrite the verdict file." % ("?", max_age_min))

        # A verdict must POSTDATE the arming it ships under. `task`/`green`/mtime-age say
        # nothing about which RUN wrote it, so a green, still-fresh verdict left behind by
        # a previous run — the classic allowance-death leftover, minutes old and for work
        # that already shipped — would otherwise open the gate for whatever the next
        # session arms over. armed_epoch is authoritative; armed_at is the <= 0.3.2
        # fallback; if neither parses we skip THIS check only (the other three still fail
        # closed) rather than brick a session over an unreadable state file. The fallback
        # resolves whole seconds only (armed_at is truncated), so on a legacy state file a
        # verdict written inside the arming second still passes — a sub-second window that
        # armed_epoch closes for everything armed by 0.3.3+.
        armed_ts = state.get("armed_epoch")
        if not isinstance(armed_ts, (int, float)):
            try:
                armed_ts = datetime.datetime.fromisoformat(state.get("armed_at") or "").timestamp()
            except Exception:
                armed_ts = None
        if armed_ts is not None and mtime <= armed_ts:
            deny("dark-factory git gate: the verdict PREDATES this arming — it was written "
                 "by a previous run (%r), not for the work you are committing now. A new "
                 "arming is a new run of record: run the panel for this task and rewrite "
                 ".dark-factory/verdicts/current.json. If a dead run left it behind, "
                 "/dark-factory:recover moves it to .dark-factory/recovery/ as evidence."
                 % verdict.get("task", "?"))

        age_min = (datetime.datetime.now().timestamp() - mtime) / 60.0
        if age_min > max_age_min:
            deny("dark-factory git gate: verdict file is STALE (%s min old, max %s) — "
                 "verification must be fresher than the code it approves. Re-run the "
                 "panel and rewrite the verdict file." % (int(age_min), max_age_min))
    allow()


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)  # fail open on unexpected errors — arming/gating bugs must not brick the shell
