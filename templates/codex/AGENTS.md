# Codex goal workflow

`$goal` runs on MAIN. MAIN coordinates Planner, Researcher, Builder, Builder Expert,
Reviewer, and Visual Reviewer directly. There is no orchestrator child.
MAIN never edits application source and never edits `.codex/scripts` during a run.

## Entry

After `init.sh --codex`, run `$init-goal`. Config: `.codex/goal-config.json`.
Routing: `goal-models.json`. Skills: `$goal`, `$goal --list|--status|--continue|--issues`,
`$create-issues`.

Source intake before branch/worktree mutations. Persist
`{type,title,body,reference,acceptance_criteria}` then
`start … --source-file`. Issues: `issues list` then
`issues start <n> --url <url> [--worktree]`.

## Helper

`.codex/scripts/goal-git.sh` is the sole operational entry. Always use the
**project-root** helper from `context --json` (`GOAL_GIT`). Carry
`GOAL_ID`, `GOAL_RUN_ID`, `GOAL_ISSUE`, `GOAL_GROUP`, `GOAL_TASK`, `GOAL_REPO`,
and for issues `GOAL_ISSUE_REPO` on every invocation.

Worktrees install shared `.git/info/exclude` rules so workflow files stay clean.
Do not copy `.codex` into worktrees. `worktree sync` refreshes excludes / cleans
old copies only. State lives only at `WORKFLOW_ROOT`.

Workers read their brief file (`harness brief`), edit only `TARGET_WORKTREE`,
and return milestones for MAIN to record. Workers never write harness/review state.

## Launch

```text
models → harness spawn → harness brief → spawn_agent({
  agent_type, model, reasoning_effort, fork_context:false,
  message: "Read and follow your brief: <abs path>"
}) → spawn-confirm → wait → close → spawn-finish
```

Missing delegation/model/vision capability is a saved blocker — never implement in MAIN.
Never fall back to web/browser/raw `gh`/`glab` for forge ops. `issues list` only.

## Gates and delivery

Commit → analyze → `verify run` → review/visual. Evidence is SHA-bound.
`harness context put` accepts any snake_case name; `review_verdict` needs
`{"verdict":"LGTM","sha":"…"}`.

`pr draft` then `pr --title <conventional ≤72> --body-file <edited>`.
Title form: `feat(scope): subject` (subject not Capitalized). Empty diff stops delivery.

## Roles

| Role | Responsibility |
|---|---|
| MAIN | State, launches, gates, commits, delivery |
| Planner | Discovery, tasks, routing, optional `pr_title` |
| Researcher | One unresolved question |
| Builder | Scoped implement/rework + stage |
| Builder Expert | Escalation after Builder + verify FAIL |
| Reviewer | Committed-diff review |
| Visual Reviewer | Conditional UI evidence |

Follow `$goal` and its references for recipes. Ponytail full mode: smallest useful diff.
