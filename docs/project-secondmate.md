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

- A confirmed-live coordinator is attached: inside tmux the client switches to its window, outside tmux the launcher execs `tmux attach-session`, and on a non-tmux backend such as Orca it reports the live coordinator terminal, whose focus is owned by that backend's own UI; running it twice always lands on the same coordinator.
- A confidently dead endpoint (bare shell left by an exited agent) is cleared and respawned via `bin/fm-spawn.sh --secondmate` on the backend its metadata records, so recovery never migrates a coordinator to a different backend.
- Anything unprovable - ambiguous or unregistered paths, a malformed or foreign-marked home, duplicate or overlapping registry entries, a pane whose agent identity cannot be confirmed, a stale launch lock whose owner cannot be proven dead, or a concurrent launcher run - fails closed with the reason.

An explicit harness wins for that launch; `auto` defers to the documented secondmate chain (`config/secondmate-harness` -> `config/crew-harness` -> the primary's own harness, including the file's optional model/effort tokens).
A claude coordinator with no model or effort pinned from any source launches on the recommended Fable 5 medium posture, while `secondmate codex` stays a fully supported explicit choice with no injected flags; `docs/configuration.md` "Coordinator posture" owns that default.
Backend selection starts from the existing spawn contract (`--backend`, `FM_BACKEND`, `config/backend`, runtime auto-detection, then tmux), with one launcher-owned bridge: when no explicit `--backend` is given and that resolution lands on cmux, which cannot host a secondmate coordinator, the launcher starts the coordinator on tmux and prints a note.
Orca hosts coordinators natively and is never bridged; an explicit `--backend` is always forwarded verbatim.

## Inspect project coordinators

```sh
bin/fm-secondmate-fleet.sh status
```

Run these commands from the primary firstmate home.
`status` is read-only and reports each project-bearing registered secondmate as live, stopped, unknown, or needing metadata reconciliation.
There is deliberately no fleet-wide start or reset command.
Open the relevant project and run `secondmate <harness>` only when that coordinator is useful.

## Daily Orca workflow

With the Orca backend selected (typically `config/backend=orca`), each project's coordinator lives natively in its own Orca terminal inside the project's `.secondmate` worktree - `docs/orca-backend.md` ("Secondmate hosting") owns the mechanics.
Open the product container in Orca and run `secondmate <harness>` (or `secondmate auto`): the launcher adopts the existing `.secondmate` home as the Orca workspace, starts the coordinator in one `fm-<id>`-titled terminal, and on a rerun reports the already-live terminal instead of duplicating it.
Several products run their coordinators simultaneously in fully independent Orca terminals; nothing is shared through a tmux session, so no two project windows can mirror each other.
On launch, a coordinator performs quiet safety recovery only, then asks the captain what they want to work on.
Crewmate work the secondmate dispatches may still use any spawn-capable backend, including Orca-owned task worktrees, per `bin/fm-spawn.sh`.
