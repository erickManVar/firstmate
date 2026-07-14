# Orca Backend

Orca is an experimental runtime backend for firstmate.
It is distinct from the crewmate harness: the harness is the agent process firstmate launches (`claude`, `codex`, `opencode`, `pi`, or `grok`), while Orca owns the task worktree and terminal endpoint underneath that process.
Firstmate agents operating this backend should load the agent-only [`firstmate-orca`](../.agents/skills/firstmate-orca/SKILL.md) checklist before switching to Orca, spawning or supervising Orca-backed work, smoke-testing, debugging task state, or reconciling Orca metadata.

## Setup

Pick Orca if you already run the Orca macOS app as your terminal environment and want firstmate tasks to live in Orca-managed worktrees and terminals instead of a treehouse/tmux pair.
Orca is macOS-only and explicit-only (never auto-detected).

Prerequisites:

- The Orca app installed at `/Applications/Orca.app`, and **running**.
- The `orca` CLI: `brew install orca`.
- `node`, used by firstmate's adapter to parse Orca's JSON output and to gate spawns on runtime readiness.
- The universal firstmate prerequisites - a verified crew harness plus the required toolchain, owned by [`docs/configuration.md`](configuration.md) ("Harness support", "Toolchain") - with `orca` as the only backend-specific tool, since Orca replaces both the session multiplexer CLI and the `treehouse` worktree provider that the other backends require.

Select Orca by putting `orca` in a local `config/backend` file - the durable way to pick it - or by exporting `FM_BACKEND=orca` when you launch your harness for a one-off session; telling the first mate in chat to use Orca also works.
It is never auto-detected.

First run: before spawn mutates any repo or worktree state, firstmate runs `orca status --json` and requires the app to report `reachable=true` and `state="ready"` - start the Orca app and wait for it to finish loading before spawning.
Spawn fails closed if the runtime is not ready.
The first spawn against a given project also auto-registers that project's repo in Orca (`orca repo add --path`) if it is not already registered - no manual registration step is needed.
Repository placement is independent of the Orca runtime backend: `config/projects-root` may select a registry-driven project-container base, and Orca receives one explicit registered repo path before creating its isolated task worktree.
`~/orca/workspaces` is Orca's task-worktree area and is never a canonical project, container, or repo input.
Opening a non-git project container or one of its registered repos directly in Orca can use `bin/fm-project-route.sh` from the firstmate checkout to discover the project, its colocated secondmate, and the supported `fm-send` command without placing extra operational files in a repo.

Watching and attaching: Orca owns both the worktree and the terminal for its tasks, so there is nothing to attach to outside the Orca app itself - open the app and find the terminal for the task (recorded as `terminal=<handle>` in the task's meta, with `window=fm-<id>` as the shared firstmate alias).
You do not need to open the app for routine supervision: from an active firstmate session, `bin/fm-peek.sh <id>` reads a task's terminal without opening Orca, and `FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> "<text>"` steers it unless `FM_HOME` is already set to the active firstmate home (the stable `fm-<id>` alias also works; Enter and Ctrl-C are supported; Escape is not).

Verify it works by spawning a trivial task with `--backend orca` and confirming the task's meta records `backend=orca`, `terminal=`, `orca_worktree_id=`, and `worktree=`; the Orca app should show a new terminal for the task.

Limitations: Escape is unsupported, Orca is macOS-only and explicit-only, and it exposes no stable CLI version marker, so spawn gates on runtime reachability instead of a version floor - see "Limitations" below for the complete list.

## Status

PR #210 landed the primitive Orca terminal adapter: bounded capture, text send, Enter, Ctrl-C interrupt, and close for already-created Orca terminals.
This follow-up adds full ship/scout task lifecycle support for `backend=orca`: spawn, metadata, send/peek/watch/crew-state routing from metadata, and guarded teardown through Orca.

Orca remains explicit-only.
Select it by putting `orca` in a local `config/backend` file, by exporting `FM_BACKEND=orca`, or by telling the first mate in chat to use Orca.
It is not auto-detected from the current process environment.
Before spawn mutates any repo/worktree state, firstmate runs `orca status --json` and requires the Orca runtime to report reachable/ready.

## Task Shape

An Orca task is one Orca-managed git worktree plus one Orca terminal.
Unlike `tmux`, `herdr`, `zellij`, and `cmux`, Orca is not only a session provider; it also provides the task worktree, so `fm-spawn.sh` does not run `treehouse get` for Orca tasks.

The normal firstmate invariant still applies: a ship or scout task must run outside the project primary checkout, and teardown must refuse to discard unlanded ship work.

## Metadata

An Orca-spawned task records the normal task fields plus these Orca-specific fields:

```text
backend=orca
window=fm-<id>
terminal=<orca terminal handle>
orca_worktree_id=<orca worktree id>
worktree=<absolute path to the Orca-created git worktree>
```

`window=` remains the shared firstmate alias used by selector-driven supervision tools after a task selector has resolved through metadata.
`fm-teardown.sh <id>` uses the same recorded fields after loading `state/<id>.meta`.
For Orca, `window=` keeps the stable firstmate alias while `terminal=` carries the stable Orca terminal handle that backend operations use.
The recorded `backend=orca` field tells shared call sites to route capture, send, interrupt, and close through `bin/backends/orca.sh` instead of tmux assumptions.

## Lifecycle

Spawn:

1. Ensure the project repo is registered in Orca, adding it with `orca repo add --path` when needed.
2. Create an independent Orca worktree with `orca worktree create --repo id:<repo> --name fm-<id> --no-parent --setup skip`.
3. Reuse the terminal returned by Orca worktree creation only when it appears in the verified `result.terminal.handle` shape, or create a titled terminal in that worktree when Orca returns only the worktree.
4. Install firstmate's per-harness turn-end hooks in the Orca worktree.
5. Write metadata, then send `GOTMPDIR` export and the selected harness launch through the recorded Orca terminal.

Operation routing:

- `fm-peek.sh` captures with `orca terminal read`.
- `fm-send.sh` types text with `orca terminal send --text ...`, submits with Enter, and verifies the composer row cleared before returning; when Orca reports a limited page, the verifier follows `oldestCursor` and preserves the current tail so older text cannot hide still-pending composer input.
  A slash-command popup that closes by filling an argument-hint placeholder still reads as pending, so the retry loop sends the required second Enter rather than treating the first Enter as a submission.
  The bordered row is classified through the shared composer classifier; a bare shell prompt has no genuine composer row and reads `unknown`, not confirmed empty.
- `fm-send.sh --key Enter` and `--key C-c` are supported.
- `fm-watch.sh` treats Orca as a pull backend with no native busy-state primitive, so it falls back to the same terminal-tail busy regex used for tmux, zellij, and cmux.
- `fm-crew-state.sh` reads the recorded Orca terminal when no no-mistakes run-step applies.

Teardown:

- Scout teardown still requires `data/<id>/report.md` unless `--force` is explicitly used.
- Ship teardown still refuses dirty or unlanded work before any terminal/worktree cleanup.
- Ship teardown resolves `orca_worktree_id` back through Orca and verifies it matches the inspected `worktree=` path before removing anything; mismatches or uninspectable paths preserve metadata and fail closed.
- After the existing firstmate safety checks pass, teardown closes the recorded Orca terminal and releases the recorded worktree through `orca worktree rm --worktree id:<orca_worktree_id> --force`.
- Teardown does not raw-delete Orca worktrees.

## Secondmate hosting

A `--secondmate` spawn on `backend=orca` hosts the persistent coordinator natively: the already-provisioned secondmate home (for a project container, its `.secondmate/` worktree) IS the Orca worktree.
`fm_backend_orca_worktree_adopt` registers the home as an Orca repo when needed (`orca repo add --path`, making the home the repo's main worktree), resolves it with `orca worktree show --worktree path:<home>`, and fails closed when Orca resolves the selector to any other physical path; it never runs `orca worktree create` or `orca worktree rm`, so no duplicate repository, branch, or task worktree ever appears.
One coordinator terminal per home, titled `fm-<id>`: `fm_backend_orca_terminal_find` reuses an exact-title match, and spawn clears it only on a confidently dead reading, refuses a live or liveness-unproven one, fails closed on duplicates, and re-checks after creating its own terminal so a concurrent duplicate launch also fails closed.
Meta records the same fields as ship/scout Orca tasks plus the secondmate `home=`/`projects=` fields, so `fm-peek.sh`, `fm-send.sh`, `fm-crew-state.sh`, and the watcher route through the recorded `terminal=` unchanged.

Agent liveness for the session-start sweep and the `bin/secondmate` launcher comes from `fm_backend_orca_agent_alive`.
Orca exposes no foreground-process primitive (verified 2026-07-14 against Orca app 1.4.116: `orca terminal show --json` carries no process fields, and `orca terminal wait --for exit` returns `{"ok":false,"error":{"code":"timeout"}}` even on an idle shell), so the classifier ports the tmux probe's semantics to the OS level: `lsof -a -d cwd -Fpc -- <terminal worktreePath>` enumerates the processes rooted in the home, and any verified harness comm or bare dotted version token reads `alive`, an only-shells result reads `dead`, and everything else (no processes, a bare interpreter such as pi's `node`, an unreadable terminal, a missing `lsof`) reads `unknown` and is never acted on.
The probe is cwd-scoped to the worktree rather than the single terminal, which can only err toward `alive` - the direction that never spawns a duplicate.
Dead respawns (bootstrap sweep and launcher) pass the recorded `backend=` explicitly, so a dead Orca coordinator always comes back on Orca regardless of the session's ambient backend resolution.

Retirement teardown for `kind=secondmate` on Orca closes only the recorded coordinator terminal, then removes the home through the same guarded path every secondmate uses; `orca worktree rm` never runs for a home.
The Orca CLI has no `repo rm`, so a retired home's Orca repo registration lingers in the app's repo list until removed there manually.

Adoption evidence (2026-07-14, `orca` CLI against `/Applications/Orca.app` 1.4.116, runtime `reachable=true`/`state="ready"`): `orca worktree show --worktree path:/Users/erickmanrique/orca/ggstore/.secondmate --json` returned `result.worktree.id="118c3929-...::/Users/erickmanrique/orca/ggstore/.secondmate"`, `path` equal to the home, and `isMainWorktree=true`; `orca terminal create --help` documents the `--worktree path:<path>` selector used for terminal placement, and `orca terminal list/show --json` return `handle`, `title`, and `worktreePath` as parsed here.
Disposable end-to-end smoke, same date and versions, against a fresh scratch home never previously known to Orca: `fm_backend_orca_worktree_adopt` registered and resolved it (`id=13c632c5-...::<home>`, path equal to the home); `fm_backend_orca_terminal_find` returned rc=1 before creation; `fm_backend_orca_terminal_create` returned `term_f065fc88-...`; `fm_backend_orca_send_text_line` + `fm_backend_orca_capture` round-tripped `echo fm-orca-smoke-ok`; `fm_backend_orca_agent_alive` classified the bare shell `dead`; find-after returned exactly the created handle; `fm_backend_orca_kill` closed it.

## Limitations

- Escape is unsupported because the current Orca terminal send primitive exposes Enter and interrupt-style input but no verified Escape operation.
- Orca is explicit-only and is not selected by runtime auto-detection.
- Orca currently exposes no stable CLI version or protocol marker. Unlike the herdr/zellij/cmux docs, this backend intentionally gates spawn support on runtime reachability from `orca status --json` rather than a version floor.

## Verification

Real-Orca smoke verification was run against `/usr/local/bin/orca` with `/Applications/Orca.app` reporting bundle version `1.4.116`; `orca status --json` reported `result.runtime.reachable=true` and `result.runtime.state="ready"`.
The verified terminal creation handle field is `result.terminal.handle` from `orca terminal create --json`; worktree creation returned `result.worktree.id` and `result.worktree.path` in the same smoke run.
Firstmate intentionally ignores speculative terminal-handle shapes such as bare `result.id` and nested `result.worktree.terminal` until a real Orca smoke run proves them.

Fake-Orca tests cover:

- helper parsing for repo registration, worktree creation, verified implicit-terminal reuse, terminal creation, terminal sends, and worktree removal;
- rejection of undocumented terminal-handle result shapes;
- runtime readiness gating through `orca status --json`;
- `fm-spawn.sh --backend orca` metadata creation and harness launch;
- `fm-peek.sh`, `fm-send.sh`, and `fm-crew-state.sh` routing through recorded Orca metadata;
- slash-command popup placeholder handling that requires a second Enter before `fm-send.sh` reports submission;
- scout teardown releasing an Orca worktree through `orca worktree rm`;
- ship teardown failing closed when the recorded Orca worktree id is missing, cannot resolve to a path, or resolves to a different path than `worktree=`.

Native secondmate hosting (home adoption, titled-terminal reuse and duplicate prevention, the lsof liveness classifier, recorded-backend sweep recovery, and terminal-only retirement) is covered by `tests/fm-backend-orca-secondmate.test.sh`, with the launcher's native-Orca attach/respawn and stale-lock behavior in `tests/fm-secondmate-launcher.test.sh`.

Run the focused suite with:

```sh
tests/fm-backend-orca.test.sh
tests/fm-backend-orca-secondmate.test.sh
tests/fm-secondmate-launcher.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
```
