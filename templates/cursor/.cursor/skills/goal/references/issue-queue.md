# Issue goals and queues

Set `GOAL_RUN_ID` for a new invocation; on continue restore the persisted run
ID. Resolve list URL/count from arguments or config, run `issues list`, and
retain one branch and one PR per issue. For exactly one issue, run
`issues start <n>` and the normal goal loop without a queue-level Planner.

For 2+ issues, queue planning must happen **before** any `issues start`:

```bash
export GOAL_RUN_ID=… GOAL_ID='' GOAL_ISSUE='' GOAL_GROUP='' GOAL_TASK=''
"$GOAL_GIT" issues plan begin --url <url> --count <n>
# → {goal_id:"queue-<run_id>", run_id, status:"planning", issues:[…]}

export GOAL_ID=queue-$GOAL_RUN_ID
# models planner → harness spawn planner → delegate to @planner
# after Planner returns ## Issue Execution Plan JSON:
"$GOAL_GIT" harness context put queue_plan -
"$GOAL_GIT" issues plan done
# → writes .cursor/queue-plans/<run_id>.json (+ queue-plan.json mirror)

export GOAL_ID=''   # clear queue record before issue intake
```

Then delegate batches of disjoint issues (width at most configured
`concurrency`). Treat that number as a **global worker limit**, not a limit per
issue. Multi-repo issue queues remain sequential. If overlap or dependency is
uncertain, put the issues in different batches.

For a parallel single-repo batch, call `issues start <n> --worktree` for **all**
ready issues before waiting for one issue to finish. Set `GOAL_RUN_ID` and
`GOAL_ISSUE_BATCH` consistently; after each start, select it with
`GOAL_ISSUE=<n>` for every issue-specific command. Initialize each harness,
then launch independent ready workers in their assigned worktrees up to the
shared limit. MAIN directly coordinates the interleaved issue loops; do not
delegate an issue-level orchestrator. When one worker returns, advance only
that issue's gates and fill a free worker slot. Do not finish issue 1 before
starting issue 2 merely because issue 1 appears first in the plan. Keep one
branch and PR/MR per issue; never merge issue worktrees together.
If actual changed files overlap despite the plan, stop concurrent writes to
those files and run the affected issues sequentially.

If Cursor Agent/Task cannot run concurrent workers, fall back to sequential
execution in isolated worktrees. If Agent/Task itself is unavailable, save
those files and run the affected issues sequentially.

Run the root checkout's `goal-git.sh` for every state/git command. Its
`state.json` is the sole queue/harness authority; issue worktrees contain code,
not independent state copies. Builders receive their own worktree path and
issue number, and may not run goal-state commands there. Serialize
state-changing `harness`, `issues`, commit, push, PR, and merge commands in
MAIN, always with the correct `GOAL_ISSUE`; code edits and read-only checks in
different worktrees may overlap. Run analyze, verify, review, conditional
visual checks, and PR delivery separately per issue. Run `issues finish
<n>` only after that issue's `harness done` and delivery; it refuses to remove
a dirty worktree.

On `/goal --continue`, run `issues plan show` — if `status` is `planned`, skip
re-planning. Then read `issues queue` and the persisted plan, restore the run
ID, skip completed issues, reuse existing worktrees/PRs, and resume each
incomplete issue from its own phase. Start only missing issues in the current
batch; do not delegate another queue Planner or rebuild finished issue context.
Begin the next batch only when its dependencies are delivered. If Cursor's
Agent/Task tool cannot run concurrent workers, report the capability limit and
run the batch sequentially without sharing a checkout.
