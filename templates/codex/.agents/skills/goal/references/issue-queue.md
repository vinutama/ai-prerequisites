# Issue goals and queues

Set `GOAL_RUN_ID` for a new invocation; on continue restore the persisted run
ID. Resolve list URL and count from arguments or config, run `issues list`,
and retain one branch and one PR per issue. For exactly one issue, run
`issues start <n>` and the normal goal loop without a queue-level Planner.

For 2+ issues, spawn one queue-level Planner to order dependencies and batches.
Persist its compact plan using `harness context put queue_plan -`. For each
ready issue, set `GOAL_ISSUE=<n>`, run `issues start <n>`, emit pickup event,
execute the common loop with that issue's own harness, and `issues finish <n>`
only after `harness done`. Emit completion event and report its PR URL.
Multi-repo mode processes one issue at a time. Independent single-repo issue
work may use isolated worktrees where supported.

Serialize every state-changing `harness`, `issues`, commit, push, PR, and merge
operation. On continue, read `issues queue`, reuse the queue plan, skip
completed issues, and resume each incomplete issue from its persisted phase.
Do not create another queue planner or rebuild finished issue context.
