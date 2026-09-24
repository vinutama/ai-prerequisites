# Markdown delivery groups

Read only for Markdown goals with `delivery_mode=multi-pr` (new `auto` or
`task` strategy). An in-progress legacy Markdown goal with single delivery
mode keeps its one-PR flow. Planner must still run unless classify returned
TRIVIAL. For TRIVIAL, synthesize one inseparable delivery group with a reason.

Validate Planner's `delivery_groups` JSON using `groups validate -`, persist
with `groups init -`, and emit a grouping event. No `goal/` aggregation PR.
Use `groups list`/`groups ready` and `max_parallel_prs` to start independent
groups in separate worktrees. Dependencies must be merged or otherwise on
the intended base before their groups start. Use `groups start <id>` for a
new group or idempotent `groups continue <id>` on resume; never `worktree add`
for a group and never put two builders in the same group worktree.

For each group, activate its typed branch/worktree, initialize its own harness
from Planner signals, persist its discovery context, pass PLAN, enter BUILDING,
and `groups persist`. Run the common build/analyze/verify/review/conditional
QA/visual loop only for its tasks/files. Every builder brief names that group
worktree. One group's PASS gates never clear another's. In inline review mode,
push and run `groups pr <id>` before Reviewer so it can review that group's
PR. In local review mode, do so only after the clean `harness done` gate.
Report one PR URL per group. If auto-merge is on,
`groups merge <id>` and then start newly unblocked groups from the updated
base. On conflict, stop. If auto-merge is off, report ready for manual merge
and do not start a dependent group until its prerequisite is available.

On continue, reconcile persisted groups, worktrees, PRs, and harness phases;
resume incomplete groups and start newly unblocked ones without recreation.
Root `state complete` must wait until every required group is merged,
completed, or cancelled. Never create a final combined PR.
