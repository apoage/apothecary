# `.dark-factory/config.json` — key by key

The single place a project teaches the factory its specifics. Committed, planner-owned
(the lane guard denies the implementer session from editing it while armed). Every
`{{key}}` in the skill and the `dark-factory-*` agents resolves from here.

| Key | What it is | Example |
|---|---|---|
| `project_name` | Short name, used in reports | `"videoED"` |
| `owner` | The human who answers DECISIONS rows | `"Lukas"` |
| `commands.test` | Full test command, green = precondition for every report | `"source .venv/bin/activate && python -m pytest -q"` |
| `commands.lint` | Extra per-file checks the implementer runs on touched files | `["node --check {file}"]` |
| `commands.build` | Release build, `null` = no build step | `"pyinstaller app.spec"` |
| `commands.ui_test` | Deterministic UI smoke layer, `null` if no UI | `"python -m pytest -m ui -q"` |
| `commands.ui_boot` | Headless boot for the visual judge | `"python -m uvicorn app.server:app --port {port}"` |
| `paths.queue` / `paths.decisions` | The two shared surfaces | defaults `tasks/QUEUE.md`, `tasks/DECISIONS.md` |
| `paths.version_file` | What the release ritual bumps, `null` = no versioning | `"app/version.py"` |
| `paths.changelog` | Where ritual entries go | `"CHANGELOG.md"` |
| `paths.fixture` | Small instant-load fixture; the whole verification story leans on it — build one FIRST | `"fixtures/sample_project"` |
| `paths.ui_playbook` | The visual judge's playbook of record | `"tests/ui_smoke_playbook.md"` |
| `paths.design_principles` | The project's own design-system doc the visual judge grades against | `"docs/design.md"` |
| `paths.handoff_dir` | Where dated handoff/validation docs land | `"docs/"` |
| `invariants` | The 5–10 rules a wrong change must never violate. Inlined here — agents read them as law; never referenced by memory slug (dead pointers on fresh installs) | `["never modify source media", "all times = seconds in original clip timeline"]` |
| `protected` | Paths/volumes never written to or run against | `["/Volumes/Blue"]` |
| `ui.enabled` | Whether a visual judge exists for this project | `false` |
| `ui.engine` | Playwright engine, matched to the REAL runtime | `"webkit"` for a pywebview/WKWebView app |
| `lanes.planner_owns` | Dir prefixes only the planner writes | `["docs/", "prototype/", ".claude/"]` |
| `lanes.shared` | Both threads write here (banners/DECISIONS rows for the factory — discipline stays prompt-level inside shared dirs) | `["tasks/"]` |
| `lanes.implementer_doc_exceptions` | Filename substrings the factory MAY write inside planner lanes | `["handoff", "validation"]` |
| `guards.allow_push` | `false` = the bash gate denies every `git push` while armed | keep `false` |
| `guards.require_verdict` | `true` = commit/tag requires a green verdict file that is fresh AND newer than the current arming | keep `true` |
| `guards.verdict_max_age_minutes` | How fresh the verdict must be at commit time. Independent of the arming rule: a verdict older than the arming is refused at any age | `60` |
| `guards.halt_after_failures` | Failed fix→verify cycles before the task HALTs to a DECISIONS row | `3` |
| `verification.risk_tiers` | Panel composition per declared task risk (`judge:<lens>`, `flow-verifier`). Governs the `full` tier; `Verify: diff` scopes the panel to the diff (1-2 lenses), `Verify: suite` runs suite + planner audit only | see template |
| `models` | **Optional.** Model per subagent role, passed as the Agent tool's `model` at spawn. Omit the whole block and every subagent inherits the armed session's model — the pre-existing behaviour. Names are harness-specific; Kimi has no per-spawn override today, so there the block is advisory | see template |
| `models.escalate_to` | Model a task escalates to after a failed fix→verify cycle | `"opus"` |

## Design notes

- **Why inline invariants instead of a doc pointer?** Fresh installs have no project
  memory; slugs rot silently. Ten lines of law in the config survive any transplant.
- **Why risk tiers?** A constant 3-judge panel is the wrong cost model — verification
  effort should scale with blast radius (XS filler ≠ strategic change). Tier `low` on
  small mechanical tasks, `high` on anything touching gates, locks, money, or data
  destruction.
- **Why task-declared verification tiers (`Verify:`)?** Verification is most of a run's
  spend and the fixed costs dominate on small tasks. The planner declares intensity at
  filing (`full` default / `diff` / `suite`), the gate enforces escalate-never-downgrade
  against the verdict's `verify_tier`, and `suite` is restricted to diffs invisible to
  the suite — because a prose sentence can be pinned false by a test, "only prose
  changed" is NOT safe; "invisible to the suite" is. Auto-tiering by diff size or path
  heuristics is banned on principle: a heuristic may propose, never set.
- **Why is the verdict freshness-checked?** A verdict older than the code it approves is
  a lie with a timestamp. The gate compares mtimes, not intentions — and since 0.3.3 it
  also refuses any verdict written before the current arming, because freshness alone
  cannot tell whose work a verdict approved. A run that dies mid-task (the allowance
  running out is the common way) leaves a green verdict for the task it already shipped;
  without the arming rule that file would open the gate for the next session's unverified
  ruins.
- **Why escalate the model instead of just running the big one?** Same cost model as the
  risk tiers, one level down: most queue tasks are specced tightly enough that a mid-tier
  model executes them exactly, and the ones that aren't announce themselves by failing.
  Paying top-tier rates on every task to cover the minority that need it is the constant
  3-judge panel again. The failure signal is free — use it.
