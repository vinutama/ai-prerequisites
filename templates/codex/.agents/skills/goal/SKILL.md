---
name: goal
description: >-
  Run a goal in MAIN from an objective, issue queue, status request, or continuation.
---

# Goal loop on MAIN

You are the sole coordinator. Spawn workers directly; do not spawn an orchestrator.
Do not edit application source in MAIN. Do not edit `.codex/scripts` during a run.

Before the first worker: `codex ensure-user-config` via the helper. Use only the
absolute `GOAL_GIT` returned by `context --json` (always the project-root helper).
Carry every selector on every invocation:

```bash
export GOAL_ID=... GOAL_RUN_ID=... GOAL_ISSUE=... GOAL_GROUP=... GOAL_TASK=... GOAL_REPO=...
export GOAL_ISSUE_REPO=...   # issues only
"$GOAL_GIT" context --json
```

`GOAL_TASK` is a harness task id (`t1`) or empty. It is not a worktree path.
Never use web search, browser, `--web`, or raw `gh`/`glab` for forge operations.
`issues list` is the only way to list issues. On failure: read the helper error
and run `doctor --json` with the same selectors.

## Dispatch

Parse text after `$goal` before mutations.

| Invocation | Action |
|---|---|
| `--list` | `list` then return |
| `--status` | `harness progress` + `harness status` then return |
| `--continue [id] [instruction]` | `continue`; restore selectors; reuse branches/PRs |
| `--issues [url] [count]` | see [issue-queue](references/issue-queue.md) |
| new goal | resolve `--source` / config; snapshot source; see below |

### Source intake (before any branch/worktree)

1. Capture full source JSON `{type,title,body,reference,acceptance_criteria}`.
2. Prompt: body = full objective. Markdown: body = file contents; path = reference.
3. Jira: discover Atlassian MCP tools at runtime; fetch full ticket; stop if missing access.
4. Persist: `GOAL_SOURCE_OVERRIDE=<source> "$GOAL_GIT" start <title> [ticket] [task-type] --source-file <snapshot.json>`

Then follow [execution](references/execution.md). For Markdown multi-PR also read
[delivery-groups](references/delivery-groups.md).

## Worker launch (exact recipe)

1. `models <role> --complexity <LEVEL> [--require-multimodal]`
2. `harness spawn <role> <model> <effort> [--task tN]` → reservation id
3. `harness brief <role> [--task tN]` → absolute brief path
4. Inspect live `spawn_agent` schema. Launch with:

```text
spawn_agent({
  agent_type: "<role>",
  model: "<model>",
  reasoning_effort: "<effort>",
  fork_context: false,
  message: "Read and follow your brief: <absolute-brief-path>"
})
```

Never put backticks or multi-line text in `message`. One retry only after reading
the error. Confirm with `harness spawn-confirm <reservation> <agent-id>`.
On failure: `harness spawn-fail <reservation> <category> <reason>`.
After close: `harness spawn-finish <agent-id> completed|failed --closed`.

Workers use the root `GOAL_GIT`. Worktrees install shared `.git/info/exclude`
rules; do not copy `.codex` into worktrees. Refresh with `worktree sync <path>`
only to install excludes / clean old copies.

Details: [commands](references/commands.md).
