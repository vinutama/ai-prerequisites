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

## Recovery

Every error is JSON with `corrective_action`: run it and retry. "Stop" is only for
authentication/permission errors.

```text
harness status                      # includes computed next_action
harness reap [--older-than <min>]   # release reservations of a dead session (tasks -> PENDING)
harness task retry tN [why]         # FAILED/BLOCKED/stuck -> PENDING; re-spawn with --task tN
harness task cancel tN [why]        # CANCELLED: VERIFYING and harness done accept it
harness budget set <key> <n>        # builder/reviewer caps already grow within max_rework
harness limit set <max_rework|max_escalations|max_verify_retries> <n>   # after user approval
harness phase REWORK                # legal from VERIFYING/REVIEWING/VISUAL_REVIEW/DONE/FAILED
worktree merge tN [--abort]
forge pending clear [--reconcile]   # unresolved PR/MR create ledger (adopts an existing PR/MR)
config put <key> <value>            # verify_cmd, verify_timeout, fingerprint_ignore, forge_max_wait,
                                    # gitnexus_version, analyze_timeout, stop_check_window
verify run --none-detected-ok       # only TRIVIAL goals (or config verify_allow_none)
run-id                              # fresh GOAL_RUN_ID
```

Rework sequence: `harness retry rework` → `harness phase REWORK` → `harness phase BUILDING` →
`harness task add builder <fix>` (or `task retry tN`) → launch/confirm/finish → `commit` →
`analyze` → `verify run` → fresh review. Details in [execution](execution.md).

`verify run` has no stdin, `CI=1` and a timeout (`verify_timeout`, default 900s); git
runs non-interactively; forge waits above `forge_max_wait` (120s) return `rate_limited`.

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

## Reset

`reset runtime [--force] [--yes]` clears this platform's goals, review files,
worktrees, and runtime logs. It does not touch other platforms, config, or
branches. Older untagged goals are inferred from spawn models (`inherit` is
Cursor). A goal with no reservations is kept. `--yes` skips the confirmation
prompt. `--force` discards uncommitted worktree changes.

## Diagnostics

```text
doctor --json
"$GOAL_GIT" help
issues plan begin|done|show   # run-scoped queue Planner bootstrap (2+ issues)
```

Never complete a failed forge operation via web/browser/`--web`/ad hoc CLI.
Auth blockers stop with the suggested local command for the user.
