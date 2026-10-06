# Helper commands and failure handling

`goal-git.sh` is the sole operational entry. Other modules (`forge.sh`,
`goal-context.sh`, `goal-delegation.sh`, `goal-delivery.sh`, `goal-evidence.sh`,
`delivery-groups.sh`) are implementation details — do not invoke them directly.

## Context

```bash
export GOAL_ID GOAL_RUN_ID GOAL_ISSUE GOAL_GROUP GOAL_TASK GOAL_REPO GOAL_ISSUE_REPO
"$GOAL_GIT" context --json
# → WORKFLOW_ROOT, TARGET_WORKTREE, GOAL_GIT (root helper), selectors, branch
```

Carry all exports in **every** shell. Empty string only when the selector does
not apply. `GOAL_REPO` is a configured local key (`.` or a service path).
`GOAL_ISSUE_REPO` is the forge identity URL/path. `GOAL_TASK` is `tN` or empty.

Worktrees share `.git/info/exclude` (installed by `issues start --worktree`,
`worktree add`, `groups start`, `start`). Never copy `state.json` / locks /
progress / reviews into a worktree. `worktree sync [path]` installs excludes and
removes obsolete copied workflow files.

## Launch

```text
models <role> --complexity <LEVEL> [--require-multimodal]
harness spawn <role> <model> <effort> [--task tN]
harness brief <role> [--task tN]          # prints absolute brief path
# spawn_agent({agent_type, model, reasoning_effort, fork_context:false,
#              message:"Read and follow your brief: <path>"})
harness spawn-confirm <reservation-id> <agent-id>
# on failure:
harness spawn-fail <reservation-id> <category> <reason>
models <role> --complexity <LEVEL> --next <failed-model> [...]
# after closing the child thread:
harness spawn-finish <agent-id> completed|failed --closed
```

If the phase is wrong, spawn auto-advances when legal; otherwise the error names
`harness phase <EXPECTED>`. One targeted launch retry only.

## Review evidence and PR metadata

```text
harness context put review_verdict -   # {"verdict":"LGTM","sha":"<commit>"}
harness context put <snake_case_name> -  # any valid name; JSON required
review init                            # local mode; list/pending auto-init
pr draft [--group id]                  # → {title_suggestion, body_file}
pr --title "<conventional ≤72>" --body-file <edited-body>
groups pr <id> --title "..." --body-file <path>
```

Title must match `feat|fix|docs|refactor|perf|test|chore|build|ci(scope)?: subject`
(subject does not start with uppercase). Body must not contain
`REWRITE_THIS_SUMMARY`. Empty diff stops publication.

## Diagnostics

```text
doctor --json
"$GOAL_GIT" help
issues plan begin|done|show   # run-scoped queue Planner bootstrap (2+ issues)
```

Never complete a failed forge operation via web/browser/`--web`/ad hoc CLI.
Auth blockers stop with the suggested local command for the user.
