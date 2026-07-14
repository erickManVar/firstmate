# Project secondmates: onboarding and the daily launcher

The fleet runs one global primary plus any number of project secondmates.
The global primary firstmate loads fleet routing, summaries, and the captain conversation; it coordinates across every project.
A project secondmate is a full firstmate whose home is the container's own `.secondmate/` directory: its session lock, recovery digest, backlog, state, watcher, memory, and dispatch config are all scoped to that home, so several project secondmates and the primary run concurrently without contending for anything.
A multi-repo product gets ONE secondmate across its registered sibling repos; crewmates it spawns still work in isolated task worktrees.

## Onboard a project once

```sh
bin/fm-project-init.sh /Users/you/orca/<project> --charter '<product intent and secondmate scope>'
```

One guarded command performs the whole flow: read-only repository analysis, the `data/projects.md` registry line, delivery-gate initialization where the chosen mode authorizes it, and transactional `.secondmate` seeding through `bin/fm-home-seed.sh`.
It requires shared-container mode (`config/projects-root`) and the `primary` home role, never touches checkouts, branches, or existing homes, and rolls back its registry edit if seeding fails.
Exact flags (`--repo`, `--mode`, `--yolo`, `--id`, `--scope`, `--charter-file`) live in `bin/fm-project-init.sh --help`.

## Launch or attach daily

```sh
secondmate codex     # or: claude, opencode, pi, grok
secondmate claude
secondmate auto
```

Run `bin/secondmate` (put `bin/` on PATH or alias it) from the project container, any registered repo, or a repo subdirectory.
It routes the current directory to the project's registered secondmate and then attaches or starts, never both:

- A confirmed-live coordinator is attached: inside tmux the client switches to its window, outside tmux the launcher execs `tmux attach-session`; running it twice always lands on the same coordinator.
- A confidently dead endpoint (bare shell left by an exited agent) is cleared and respawned via `bin/fm-spawn.sh --secondmate`.
- Anything unprovable - ambiguous or unregistered paths, a malformed or foreign-marked home, duplicate or overlapping registry entries, a pane whose agent identity cannot be confirmed, or a concurrent launcher run - fails closed with the reason.

An explicit harness wins for that launch; `auto` defers to the documented secondmate chain (`config/secondmate-harness` -> `config/crew-harness` -> the primary's own harness, including the file's optional model/effort tokens).
Backend selection starts from the existing spawn contract (`--backend`, `FM_BACKEND`, `config/backend`, runtime auto-detection, then tmux), with one launcher-owned bridge: when no explicit `--backend` is given and that resolution lands on a backend that cannot host a secondmate coordinator (Orca, cmux), the launcher starts the coordinator on tmux and prints a note, so a `config/backend=orca` primary still gets the daily attach workflow below.
An explicit `--backend orca` (or `cmux`) is forwarded verbatim and surfaces `bin/fm-spawn.sh`'s refusal as a fail-closed diagnostic; the launcher never overrides a backend the caller explicitly requested.

## Daily Orca workflow

Orca terminals are worktree-bound, so the Orca backend does not host secondmate agents directly; the coordinator lives in the tmux backend.
This holds even when the primary's `config/backend` is `orca`: the implicit-resolution bridge above hosts the coordinator on tmux automatically, no per-launch flag needed.
Open an Orca terminal anywhere in the project and run `secondmate <harness>` there: the launcher attaches the tmux-backed coordinator inside that terminal, and re-running it from any other terminal switches to the same one.
Crewmate work the secondmate dispatches may still use any spawn-capable backend, including Orca-owned task worktrees, per `bin/fm-spawn.sh`.
