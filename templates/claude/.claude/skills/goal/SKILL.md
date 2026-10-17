---
name: goal
description: >-
  Run a goal in MAIN from an objective, issue queue, status request, or continuation.
  Usage: /goal <objective> | --list | --status | --continue [id] | --issues [url] [count]
argument-hint: "<objective> | --list | --status | --continue [id] | --issues [url] [count]"
disable-model-invocation: true
---

# Goal loop on MAIN

You are the sole coordinator, running in the main Claude Code session. Subagents
cannot spawn subagents, so launch workers directly with the Agent tool; there is
no orchestrator child. Do not edit application source in MAIN. Do not edit
`.claude/scripts` during a run.

User arguments: $ARGUMENTS

Use only the absolute `GOAL_GIT` returned by `context --json` (always the
project-root helper; first call it as `.claude/scripts/goal-git.sh`). Carry every
selector on every invocation (each Bash call is a fresh shell):

```bash
export GOAL_ID=... GOAL_RUN_ID=... GOAL_ISSUE=... GOAL_GROUP=... GOAL_TASK=... GOAL_REPO=...
export GOAL_ISSUE_REPO=...   # issues only
"$GOAL_GIT" context --json
```

`GOAL_TASK` is a harness task id (`t1`) or empty. It is not a worktree path.
Never use web search, browser, `--web`, or raw `gh`/`glab` for forge operations.
`issues list` is the only way to list issues. On failure: read the helper error
and run `doctor --json` with the same selectors.

## Run until terminal

Do not end the turn until `harness done` exits 0 and delivery is recorded
(`state complete` / `issues finish`), or a blocker is saved with
`"$GOAL_GIT" harness event blocker "<reason>"`. After every worker returns:
`spawn-finish`, record its result, then run `harness status` and take its
`next_action`. Every helper error carries a `corrective_action`: run it. Stop only
for authentication/permission errors or a missing delegation capability.
On resume run `harness reap` first, then `harness status`. An interrupted Agent call
(closed window, killed session) leaves its reservation held: `harness reap` releases it
and returns its task to PENDING for a fresh launch.

A Stop hook (`harness stop-check`) enforces this: while this platform's goal is
unfinished it blocks the stop and returns the `next_action`. It allows the stop
after a saved blocker, `harness done`, a forge auth error, or three blocks in a
row without any state change.

## Dispatch

Parse the arguments above before mutations.

| Invocation | Action |
|---|---|
| `--list` | `list` then return |
| `--status` | `harness progress` + `harness status` then return |
| `--continue [id] [instruction]` | `continue`; restore selectors; `harness reap`; reuse branches/PRs |
| `--issues [url] [count]` | see [issue-queue](references/issue-queue.md) (`issues plan begin` before branches when 2+) |
| new goal | resolve `--source` / config; snapshot source; see below |

### Source intake (before any branch/worktree)

1. Capture full source JSON `{type,title,body,reference,acceptance_criteria}`.
2. Prompt: body = full objective. Markdown: body = file contents; path = reference.
3. Jira: discover Atlassian MCP tools at runtime; fetch full ticket; stop if missing access.
4. Persist: `GOAL_SOURCE_OVERRIDE=<source> "$GOAL_GIT" start <title> [ticket] [task-type] --source-file <snapshot.json>`

Then follow [execution](references/execution.md). For Markdown multi-PR also read
[delivery-groups](references/delivery-groups.md).

## Worker launch (exact recipe)

1. `models <role> --complexity <LEVEL> [--require-multimodal]` (prints model alias + effort)
2. `harness spawn <role> <model> <effort> [--task tN]` → reservation id
   (`<model>` is `sonnet`, `opus`, `haiku` or `inherit`; effort is recorded for audit —
   a Claude subagent has no per-launch effort setting)
3. `harness brief <role> [--task tN]` → absolute brief path
4. Launch with the Agent tool (independent tasks: several Agent calls in one message):

```text
Agent({
  subagent_type: "<role>",          // planner|researcher|builder|builder-expert|reviewer|visual-reviewer
  model: "<model>",                 // the alias reserved in step 2
  description: "<role> <task>",
  prompt: "Read and follow your brief: <absolute-brief-path>"
})
```

Never put backticks or multi-line text in `prompt`. One retry only after reading
the error. Confirm with `harness spawn-confirm <reservation> <agentId>` using the
`agentId` in the Agent tool result. On failure:
`harness spawn-fail <reservation> <category> <reason>`. When the Agent call
returns, record its result and run `harness spawn-finish <agentId> completed|failed --closed`.
`SubagentStart`/`SubagentStop` hooks add started/completed events automatically.

Workers use the root `GOAL_GIT`. Worktrees install shared `.git/info/exclude`
rules; do not copy `.claude` into worktrees. Refresh with `worktree sync <path>`
only to install excludes / clean old copies.

Details: [commands](references/commands.md).
