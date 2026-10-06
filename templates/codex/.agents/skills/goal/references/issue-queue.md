# Issue goals and queues

## Recipe

```bash
export GOAL_RUN_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"   # or helper generate
# resolve URL/count from args or config
"$GOAL_GIT" issues list <url> <count>
# for each ready issue in a parallel batch:
export GOAL_ID='' GOAL_ISSUE=<n> GOAL_ISSUE_REPO=<forge-identity> GOAL_TASK='' GOAL_GROUP='' GOAL_REPO=.
"$GOAL_GIT" issues start <n> --url <url> --worktree
# then:
export GOAL_ID=<returned-or-from-state> GOAL_ISSUE=<n> …
"$GOAL_GIT" context --json   # TARGET_WORKTREE=.worktrees/issue-<n>; GOAL_GIT=root helper
# run common loop from execution.md for that issue
"$GOAL_GIT" issues finish <n>   # after harness done + validated PR
```

Exactly one issue: skip queue Planner; follow [execution](execution.md).

## 2+ issues

Queue planning must happen **before** any `issues start` (no branches yet):

```bash
export GOAL_RUN_ID=… GOAL_ID='' GOAL_ISSUE='' GOAL_GROUP='' GOAL_TASK=''
"$GOAL_GIT" issues plan begin --url <url> --count <n>
# → {goal_id:"queue-<run_id>", run_id, status:"planning", issues:[…]}

export GOAL_ID=queue-$GOAL_RUN_ID
# models planner → harness spawn planner → harness brief planner → spawn_agent
# after Planner returns ## Issue Execution Plan JSON:
"$GOAL_GIT" harness context put queue_plan -
"$GOAL_GIT" issues plan done
# → writes .codex/queue-plans/<run_id>.json (+ queue-plan.json mirror)

export GOAL_ID=''   # clear queue record before issue intake
```

Then execute batches from the plan:

1. Batches of disjoint issues, width ≤ `concurrency`
2. Multi-repo queues: one issue at a time
3. Parallel single-repo: `issues start … --worktree` for every ready issue **before** waiting on issue 1
4. Preserve `GOAL_RUN_ID` and `GOAL_ISSUE_BATCH`. Interleave on worker return; fill free slots
5. Each issue has its own PR; never merge issue worktrees together

Workers use root `GOAL_GIT` + selectors. Shared excludes keep worktrees clean.
Serialize state mutations in MAIN. Require PR metadata from [commands](commands.md).

On continue: `issues plan show` — if `status` is `planned`, skip re-planning.
Then `issues queue` + persisted plan; skip completed; reuse worktrees/PRs.
If parallel delegation is unavailable, run sequentially in isolated checkouts.
If delegation itself is unavailable, save/stop — never implement in MAIN.
