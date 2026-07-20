---
name: gate-recovery
description: >-
  Agent-only procedure for safely inspecting and recovering a no-mistakes gate.
  Use before cancelling or changing a gate run, or when a gate appears stuck.
user-invocable: false
metadata:
  internal: true
---

# gate-recovery

Use this procedure only for a no-mistakes gate that appears stuck, misrouted, or needs a change.
Do not cancel, restart, reconfigure, or otherwise change the gate until the captain explicitly approves that exact action.

## Preserve work and record context

First verify the affected work is on a named branch in a real worktree.
Confirm the worktree path, branch name, and commit with read-only Git inspection.
If the branch is detached, the worktree is missing, or its relationship to the gate cannot be proven, stop and report the preservation risk to the captain.

Record the gate's run id, branch, commit, current phase, and next action before recovery begins.
Keep that record in the active task status or brief so the recovering operator can reconcile the same gate rather than a similarly named run.

## Inspect before acting

Use read-only status, log, and process inspection first.
Read the no-mistakes run status and its relevant log tail, inspect the task's current crew state, and inspect the associated process or terminal only when needed.
Do not infer a stuck gate from an idle pane alone.

Classify the result as progressing, waiting on a human decision, externally blocked, or genuinely stalled.
For a progressing or externally blocked run, preserve it and report the observed next action.
For a human decision, route the decision through the normal captain-owned response path.

## Request approval and recover

When a genuine change is necessary, tell the captain the recorded run id, branch, commit, current phase, evidence, proposed action, and preservation check result.
Wait for explicit approval before cancellation or any gate-setting change.
After approval, apply only the approved action and re-check the same recorded run or its explicit replacement.

## Completion

Recovery is complete only when checks have passed and the PR URL is available.
Report both together with the final run id, branch, and commit.
