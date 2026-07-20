---
name: bootstrap-diagnostics
description: >-
  Agent-only handling playbook for session-start bootstrap diagnostics.
  Use whenever the session-start digest's bootstrap section prints any diagnostic or capability line - MISSING, MISSING_MANUAL, BACKEND_INVALID, NEEDS_GH_AUTH, TANGLE, CREW_HARNESS_OVERRIDE, CREW_DISPATCH, FLEET_SYNC, SECONDMATE_LIVENESS, TASKS_AXI, or FMX - or when a standalone bin/fm-bootstrap.sh run prints one.
  A silent bootstrap section means all good and needs no skill load.
user-invocable: false
metadata:
  internal: true
---

# bootstrap-diagnostics

Handle each printed line as below, before dispatching work that depends on it.
The line formats themselves are owned by `bin/fm-bootstrap.sh`'s header; this playbook owns the response.
The inline rules in `AGENTS.md` section 3 still bind: detect, then consent, then install - never install anything the captain has not approved in this session - and no work is dispatched until the tools it needs are present and GitHub auth is good.

- `MISSING: <tool> (install: <command>)` - list the missing tools to the captain with a one-line purpose each plus the printed install commands, wait for consent (one approval may cover the list), then run `bin/fm-bootstrap.sh install <approved tools...>`.
  For `treehouse`, this also covers an installed version whose `treehouse get` lacks `--lease`; treat it as an upgrade request.
  For `no-mistakes`, this also covers an installed version older than 1.31.2, because crewmate validation briefs delegate gate mechanics to no-mistakes' version-matched guidance.
  For `tasks-axi`, this also covers an installed build that fails the compatibility probe (`docs/configuration.md` "Backlog backend" owns the definition); `config/backlog-backend=manual` only suppresses the `TASKS_AXI: available` capability line, not this missing-tool report.
  For `quota-axi`, bootstrap requires it because crew-dispatch `quota-balanced` may call it; `bin/fm-dispatch-select.sh` still degrades at runtime when quota data is unavailable.
- `MISSING_MANUAL: <tool> (instructions: <url>)` - tell the captain why the tool is required and give them the printed instructions URL, but do not pass the tool to `bin/fm-bootstrap.sh install`; wait for the captain to complete the manual installation, then rerun session start to confirm the dependency is present.
- `BACKEND_INVALID: <name> (known: <names>)` - the resolved runtime backend has no verified dependency or lifecycle contract, so do not dispatch work until the invalid `FM_BACKEND` or `config/backend` value is corrected to one of the listed backends.
- `NEEDS_GH_AUTH` - ask the captain to run `! gh auth login` (interactive; you cannot run it for them).
- `TANGLE: <remediation>` - the primary checkout is stranded on a feature branch instead of its default branch; `AGENTS.md` section 8 explains why this guard exists and what it protects.
  The work is safe on that branch ref; restore the primary to its default branch with the printed `git -C <root> checkout <default>`, then re-validate that branch in a proper worktree.
  This is the only sanctioned firstmate-initiated git write to the primary, and it is a non-destructive branch switch that strands nothing.
- `CREW_HARNESS_OVERRIDE: <name>` - record and use the override silently; surface a harness fact only if it actually blocks work or the captain asks.
- `CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>` - the optional dispatch profile file exists but failed low-cost bootstrap validation; continue with the normal fallback chain, resolve and pass the chosen fallback harness explicitly while the file remains present, fix the malformed schema, unverified harness name, unknown selector, or invalid harness/effort pair when convenient, and do not select a bad profile.
- `CREW_DISPATCH: active config/crew-dispatch.json` - bootstrap validated the optional dispatch profile file and printed its active rules and `default:` when present.
  Keep this block top-of-mind during intake; it is the reminder that every crewmate or scout dispatch must consult the rules before spawning (`AGENTS.md` section 4).
- `FLEET_SYNC: <repo>: skipped: <reason>` - a benign one-off skip (offline, no origin, local-only); bootstrap continued, investigate only if it blocks work.
  A skip can also report the bounded fleet-refresh timeout (`FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT`, or a fleet-size-aware default with a 20 second floor); a timeout never blocks startup.
- `FLEET_SYNC: <repo>: recovered: <detail>` - the clone had drifted onto a clean detached HEAD holding no unique commits and the sync self-healed it (re-attached the default branch and fast-forwarded); no action needed, it is reported only so the self-heal is visible.
- `FLEET_SYNC: <repo>: STUCK: on <state>, N commits behind <base> - needs attention` - the clone is dirty, on a non-default branch, detached with unique commits, or diverged, so the sync left it untouched (never forcing or discarding); it will keep falling behind until you look.
  A loud STUCK, especially a growing N across bootstraps, means that clone needs hands-on attention; dispatch a crewmate or resolve it before it strands work.
- `SECONDMATE_LIVENESS: secondmate <id>: stopped|liveness unproven` - the session-start liveness report checked a recorded endpoint for a real agent process without changing it.
  Report a stopped coordinator and resume it only when the captain chooses to run `secondmate <harness>` from that project's container; inspect an unproven endpoint before any recovery.
- `TASKS_AXI: available` - a default-backend capability fact, not a problem; record it silently and use `AGENTS.md` section 10 for backlog mutations.
  It prints only when `config/backlog-backend` is absent or set to `tasks-axi` and the shared compatibility probe passes (`docs/configuration.md` "Backlog backend").
  If the backend is not opted out and `tasks-axi` is missing or incompatible, bootstrap reports the `MISSING: tasks-axi` line but firstmate still hand-edits routine backlog updates and never blocks work.
  If `config/backlog-backend=manual`, firstmate hand-edits routine backlog updates and bootstrap does not suggest installing `tasks-axi`.
- `FMX: X mode on ...` / `FMX: X mode off ...` - bootstrap confirmed or removed the local X-mode poll artifacts (`docs/configuration.md` "X mode (.env)").
  Only when a running watcher needs the cadence transition applied immediately, restart the home-scoped watcher through the emitted harness supervision protocol; bootstrap deliberately never restarts the watcher itself.
