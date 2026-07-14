# Primary entry, resume, and fleet recap

`bin/firstmate` is the captain's entry command for the PRIMARY firstmate session.
It is an ergonomic alias for `bin/fm-primary-entry.sh`, exactly as `bin/secondmate` aliases `bin/fm-secondmate.sh`, and it is on PATH wherever `secondmate` already resolves.
The script header owns the exact flags and parsing rules; this document owns the daily workflow, the recap mechanism, and its verified limitation.

## Daily workflow

```sh
firstmate claude          # resume the most recent primary conversation for this repo
firstmate codex           # same, on codex
firstmate claude --new    # start a fresh session that greets the captain with a recap
firstmate codex --model gpt-5.5   # extra arguments forward to the harness verbatim
```

From any directory, the command anchors its cwd to the firstmate repository root before launching, so the harness loads this repo's tracked project hooks and resumes the conversation history recorded for this repository.
Default mode uses each harness's documented native resume command: `claude --continue` (the most recent conversation in the current directory) and `codex resume --last`.
`--new` starts a normal interactive session whose short positional initial prompt requests the mandatory Firstmate session start (recovery per AGENTS.md sections 3 and 5) and a concise captain greeting/recap; it never uses print/headless mode.
Anything after the harness name that is not a firstmate flag (`--new`, `-h/--help`) forwards to the harness verbatim, and `--` stops firstmate's own flag scan, so there is no ambiguous parsing.

When there is no prior session to resume, both harnesses fail fast with their own diagnostic and a non-zero exit; the wrapper then prints one pointer at `firstmate <harness> --new` and propagates the exit code.
It deliberately inspects no undocumented transcript formats and never auto-falls-back to a fresh session, so a resume failure can never silently fork a second conversation.

Autonomy posture: codex launches carry `--yolo` (the codex alias for `--dangerously-bypass-approvals-and-sandbox`), the standing captain-approved posture for this local primary entry; claude launches intentionally carry no bypass-permissions flag.

## Fleet recap on fresh or cleared context

`bin/fm-session-recap.sh` is registered additively as a SessionStart hook in both `.claude/settings.json` and `.codex/hooks.json`, alongside the untouched existing Stop and PreToolUse hooks.
On sources `startup` and `clear` it instructs the next response to lead with a concise captain-facing greeting and recap; on `resume` and `compact` it refreshes fleet state without forcing a repeated greeting.
The recap body is the bounded, LOCAL-ONLY `bin/fm-bearings-snapshot.sh` projection, run from the repository root - the single owner of cross-home fleet aggregation.

Secondmates do not need to push a separate chat transcript for this.
Their durable records - each home's own backlog Done roll-up, task meta, and status files - are what `fm-bearings-snapshot.sh` aggregates at primary entry, so a fresh primary session sees the whole fleet without ever reading a secondmate's private chat.

**The limitation, precisely:** on both harnesses, SessionStart additional context is consumed by the NEXT model request; the lifecycle hook cannot fabricate a model turn by itself.
A wrapper-started fresh session (`firstmate <harness> --new`) greets immediately because the wrapper supplies an initial prompt that becomes that first request.
After `/clear`, the hook refreshes the context, and the captain's next message - whatever it is - gets a response that leads with the recap; nothing is said until the captain speaks.

The helper fails open by design: on empty stdin, missing `jq`, an unknown source, or a snapshot failure it exits 0 (with at most a one-line unavailable note), so a broken recap can never block a session start.
Both hook registrations carry their own 30-second timeout, and the helper additionally caps the snapshot at `FM_RECAP_TIMEOUT` seconds (default 20) when a timeout tool is available.

## Verified platform facts

Verified 2026-07-14 on this machine (Darwin 25.5.0), Claude Code 2.1.209 and codex-cli 0.144.4.

- `claude --help` documents `-c, --continue` (most recent conversation in the current directory), `-r, --resume [value]`, `--model`, and `--effort`.
- `codex resume --help` documents `--last` plus an optional `[PROMPT]`, `-m/--model`, and `-c` config overrides.
- `--yolo` is accepted by both `codex` and `codex resume`: `codex --yolo --help` and `codex resume --last --yolo --help` parse with exit 0 while the control `codex resume --badflagxyz --help` exits 2 (it is the hidden alias for `--dangerously-bypass-approvals-and-sandbox`).
- `claude --continue` with nothing to resume exits 1 with an error instead of starting a session, which is what the wrapper's no-session diagnostic keys on.
- Claude SessionStart wiring was validated live in a scratch project with the exact tracked hook shape (matcher `startup|resume|clear|compact`, command anchored through `"$CLAUDE_PROJECT_DIR"`, `timeout` 30): `claude -p 'If your context contains a token of the form SMOKETOKEN-..., reply with exactly that token...'` ran the hook, the recorded payload contained `{"hook_event_name":"SessionStart","source":"startup","cwd":"<scratch>"}`, and the model replied with the hook's stdout token, proving plain stdout is injected as next-request context.
- Codex SessionStart wiring reuses the Stop-hook wrapper pattern already validated in `docs/turnend-guard.md` (payload read once, executable anchored to the hook process working directory, firstmate-shape and hook-bearing checks, payload piped through).
  Codex's support for the same four SessionStart sources and next-request context consumption is per the platform verification recorded in this feature's task brief; the helper validates `source` from the payload and fails open on anything unexpected, so a payload-shape drift degrades to "no recap", never a broken session.
