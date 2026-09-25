# Issue goals and queues

Set `GOAL_RUN_ID` for a new invocation; on continue restore the persisted run
ID. Resolve list URL and count from arguments or config, run `issues list`,
and retain one branch and one PR per issue. For exactly one issue, run
`issues start <n>` and the normal goal loop without a queue-level Planner.

For 2+ issues, spawn one queue-level Planner to order dependencies, predict
file ownership, and form batches of disjoint issues (width at most configured
`concurrency`). Treat that number as a **global worker limit**, not a limit per
issue. Multi-repo issue queues remain sequential. If overlap or dependency is
uncertain, put the issues in different batches.

For a parallel single-repo batch, call `issues start <n> --worktree` for **all**
ready issues before waiting for one issue to finish. Set `GOAL_RUN_ID` and
`GOAL_ISSUE_BATCH` consistently; after each start, select it with
`GOAL_ISSUE=<n>` for every issue-specific command. Initialize each harness,
then launch independent ready workers in their assigned worktrees up to the
shared limit. MAIN directly coordinates the interleaved issue loops; do not
spawn an issue-level orchestrator. When one worker returns, advance only that
issue's gates and fill a free worker slot. Do not finish issue 1 before
starting issue 2 merely because issue 1 appears first in the plan. Keep one
branch and PR/MR per issue; never merge issue worktrees together.
If actual changed files overlap despite the plan, stop concurrent writes to
those files and run the affected issues sequentially.

Run the root checkout's `goal-git.sh` for every state/git command. Its
`state.json` is the sole queue/harness authority; issue worktrees contain code,
not independent state copies. Builders receive their own worktree path and
issue number, and may not run goal-state commands there. Serialize
state-changing `harness`, `issues`, commit, push, PR, and merge commands in
MAIN, always with the correct `GOAL_ISSUE`; code edits and read-only checks in
different worktrees may overlap. Run analyze, verify, review, conditional
QA/visual checks, and PR delivery separately per issue. Run `issues finish
<n>` only after that issue's `harness done` and delivery; it refuses to remove
a dirty worktree.

Persist the compact queue plan once after the first issue harness is initialized
using `harness context put queue_plan -`; its root `.codex/queue-plan.json`
mirror is available for resume. On `--continue`, read `issues queue` and the
persisted plan, restore the run ID, skip completed issues, reuse existing
worktrees/PRs, and resume each incomplete issue from its own phase. Start only
missing issues in the current batch; do not spawn another queue Planner or
rebuild finished issue context. Begin the next batch only when its dependencies
are delivered. If the agent delegation tool cannot run concurrent workers,
report the capability limit and run the batch sequentially without sharing a
checkout.
