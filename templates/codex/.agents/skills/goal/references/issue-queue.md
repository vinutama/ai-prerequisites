# Issue goals and queues

Establish `GOAL_RUN_ID` for a new invocation and restore it on continue. Resolve
the list URL/count from arguments or config; explicit overrides persist through
start/resume. Use `issues list <url> <count>` and retain full issue body and
acceptance criteria before branch mutation. Run `issues start <n> --url <url>
[--worktree]`, carrying run and repo identity. Do not let configured repository
or URL silently replace the list override. Exactly one issue bypasses queue-level
Planner and follows the common execution loop.

For 2+ issues, one queue Planner predicts file ownership, orders dependencies,
and forms batches of disjoint issues. Width is at most configured `concurrency`,
a global worker limit across all active issues. Multi-repo queues run one issue
at a time across selected repos. Unknown overlap/dependencies require different
batches. Issue worktrees are never merged together; each issue has its own PR.

For a parallel single-repo batch, start every ready issue with
`issues start <n> --url <url> --worktree` before waiting for issue 1 to finish.
Preserve `GOAL_RUN_ID` and `GOAL_ISSUE_BATCH`. Explicitly select each goal with
all context selectors, including `GOAL_ISSUE`, local configured `GOAL_REPO`,
and forge identity `GOAL_ISSUE_REPO`; resolve
`context --json` to obtain paths/identity. Initialize that issue's harness and
reserve/launch/confirm ready workers up to the shared limit. MAIN interleaves
loops directly. On a worker result, advance that issue alone, record its
milestones/results/findings serially, close the child thread, and fill a free
slot. Actual overlapping edits stop concurrency for the affected issues.

Creation/resume automatically syncs managed scripts/agents/config, workflow
skills, and ignored AGENTS instructions. Refresh with `worktree sync <path>`
when needed. The local helper resolves one `WORKFLOW_ROOT/state.json` queue
and harness authority. Never copy state/locks/progress/reviews into worktrees.
Workers use their local absolute `GOAL_GIT`, carry every selector each invocation,
and edit/check only assigned `TARGET_WORKTREE`. No worker writes workflow state.

Serialize harness/issues/review mutations, reconciliation/commit, analysis,
push/PR/merge in MAIN with the correct identity. Use commit → analyze → verify
and SHA-bound review/QA/visual evidence separately per issue/repo. Require PR
metadata from [commands](commands.md). `issues finish <n>` follows that issue's
clean `harness done` and delivery; it must refuse dirty worktree removal.

Persist the compact queue plan once after the first issue harness init via
`harness context put queue_plan -`. Any `.codex/queue-plan.json` mirror is a
resume artifact, never a second authority. On continue read `issues queue` and
persisted plan; restore run ID, URL, repo, and issue selectors, skip completed
issues, and reuse worktrees/PRs/child IDs. Start only missing issues in the
current batch. Do not recreate queue planning or finished context. Begin the
next batch after dependencies are delivered. If parallel delegation is unavailable,
report the limit and run sequentially in isolated checkouts. If delegation itself
is unavailable, save/stop; never implement in MAIN.
