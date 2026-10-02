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

1. One queue Planner → batches of disjoint issues, width ≤ `concurrency`
2. `harness context put queue_plan -` once after first issue harness init
3. Multi-repo queues: one issue at a time
4. Parallel single-repo: `issues start … --worktree` for every ready issue **before** waiting on issue 1
5. Preserve `GOAL_RUN_ID` and `GOAL_ISSUE_BATCH`. Interleave on worker return; fill free slots
6. Each issue has its own PR; never merge issue worktrees together

Workers use root `GOAL_GIT` + selectors. Shared excludes keep worktrees clean.
Serialize state mutations in MAIN. Require PR metadata from [commands](commands.md).

On continue: `issues queue` + persisted plan; skip completed; reuse worktrees/PRs.
If parallel delegation is unavailable, run sequentially in isolated checkouts.
If delegation itself is unavailable, save/stop — never implement in MAIN.
