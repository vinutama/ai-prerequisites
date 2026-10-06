# Markdown delivery groups

For Markdown `delivery_mode=multi-pr` (`auto`/`task`). Legacy single-PR keeps one PR.

## Recipe

1. Intake persists full Markdown draft before mutations
2. Planner returns discovery + `delivery_groups` (+ optional conventional `pr_title` per group)
3. `groups validate -` then `groups init -`
4. `groups ready` / `max_parallel_prs` for independent groups
5. Per group:

```bash
export GOAL_GROUP=<id>   # with all other selectors
"$GOAL_GIT" groups start <id>    # typed branch + worktree; installs excludes
"$GOAL_GIT" context --json
# common loop: plan → build → commit → analyze → verify → review
# Inline: push; pr draft --group <id>; edit Summary; groups pr <id> --title … --body-file …
# Local: review init; harness done; then publish
"$GOAL_GIT" groups merge <id>    # if auto_merge; else report ready
```

No aggregation PR. Evidence is per-group SHA. Context mismatch stops before edits.
`worktree add` is not used for groups. One Builder per group checkout.

On continue: restore `GOAL_GROUP` + identities; reuse current-SHA evidence.
Root `state complete` waits for every required group merged/completed/cancelled.
