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

## Auto-fix worktrees are evidence-only

The pipeline's own auto-fix worktrees are validation evidence, never a delivery source.
Never treat an auto-fix worktree's contents, commits, or SHA as the deliverable, never report ready from one, and never promote one into a branch, PR, or merge.
The only deliverable source is a committed real task branch in the task's own worktree.
If fix work exists only in an auto-fix worktree and not as commits on the task branch, the gate is not done; report that state to the captain instead of promoting the worktree.

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
Before reporting ready, independently verify the deliverable with read-only Git and PR inspection, never from the run's own summary alone: read the task branch's commit SHA, and when a PR exists, read its head SHA and confirm the two match.
A mismatch means what was validated is not what would ship - stop and report the discrepancy instead of ready.
Report checks and the PR URL together with the final run id, branch, and verified commit.
