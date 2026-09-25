---
name: goal
description: >-
  Run a goal on MAIN from an objective, issue queue, status request, or continuation.
disable-model-invocation: true
---

# Goal loop on MAIN

Read AGENTS.md and only the relevant README sections. Arguments are the text
the user typed after `/goal`; Cursor does not expand a placeholder. You are
MAIN and the only workflow coordinator. Do not spawn an orchestrator. Stay in
this thread through every worker handoff, verification, review, conditional
QA/visual check, delivery group, and issue. Spawn project workers directly
with Cursor's Agent/Task delegation tool; do not invent a `spawn_agent` API.
Do not edit application source yourself; delegate implementation and rework.

Use `.cursor/scripts/goal-git.sh` for every git and goal-state operation;
never invoke raw `git`, `gh`, or `glab`. `state.json` and its harness decide
phase, tasks, evidence, budgets, and completion. Never claim success before
`harness done` exits 0. Resolve worker roles through
`.cursor/goal-models.json` via `models <role> --complexity <LEVEL>` for the
`harness spawn` audit. Cursor worker frontmatter owns the actual model; do not
invent a per-spawn model override. MAIN's session model is user-selected.

## Dispatch

- `--list`: run `goal-git.sh list`; for multi-repo goals show `.repos` from
  `state`. Return without starting a worker.
- `--status`: run `harness progress` and `harness status`, showing phase,
  requirements, gates, and tasks. Mention `.cursor/goal-progress.log` for
  live milestones. Return.
- `--continue [id] [instruction]`: compare the first token to `goal-git.sh
  list`. If it matches, it is the ID and the rest is the new instruction;
  otherwise the full remainder instructs the active goal. Run `continue`.
  If phase is FAILED or a task is SPAWNING/BLOCKED, run
  `harness recover-spawn`. Resume an incomplete issue queue if `issues queue`
  has entries; otherwise resume the active goal from persisted phase. Never
  recreate an existing branch, worktree, PR, or completed task. For a queue,
  select each issue with `GOAL_ISSUE` and follow the persisted batch plan.
- `--issues [url] [count]`, or bare `/goal` when `goal_source=issues`: use the
  explicit URL/count or config's `issue_list_url`/`issue_limit` (default 3).
  Require a URL. Set `GOAL_RUN_ID`, run `issues list`, and read
  `references/issue-queue.md`. One issue uses `issues start <n>` and the
  normal loop; 2+ issues use one queue plan and one PR per issue. Independent
  single-repo issues in the same batch start together in separate worktrees.
- New goal: resolve `--source <prompt|markdown|jira|issues>` or configured
  `goal_source` (default `prompt`). Prompt requires a nonempty objective.
  If the source is `issues`, use the issue dispatch above. Markdown reads the
  explicit path or `markdown_path` from config and gives the path to Planner
  as draft input. Jira requires Atlassian MCP: fetch the ticket, then run
  `GOAL_SOURCE_OVERRIDE=jira .cursor/scripts/goal-git.sh start <summary> <ticket> <task-type>`.
  For prompt/markdown, run
  `GOAL_SOURCE_OVERRIDE=<source> .cursor/scripts/goal-git.sh start <resolved-goal>`;
  preserve the optional Markdown task-type override (`bugfix` → `fix`) when
  there is a single delivery group. Then enter the loop below.

## Core loop

Read `references/execution.md` before a new or resumed goal. For an active
Markdown `delivery_mode=multi-pr` goal, also read
`references/delivery-groups.md`. Read `references/issue-queue.md` only for an
issue invocation or resumed queue. Do not load unrelated workflow branches.

1. Classify a short goal title with `complexity classify`; honor its
   `planner_required` and `reviewer_required`. `route detect` is a baseline;
   Planner's route and QA/visual signals take precedence.
2. For TRIVIAL, initialize the harness with planner/reviewer not required and
   skip their workers. Otherwise provisionally initialize the harness, spawn
   Planner once, then initialize with Planner's final signals. Persist
   `discovery_context` after final init and pass PLAN. A Markdown draft does
   not skip Planner.
3. Run Researcher only for a concrete unresolved question. Builders implement
   scoped tasks and stage structured handoffs. Independent tasks may use
   isolated worktrees; serialize state changes and shared-file edits.
4. After each reconciled implementation batch, pass IMPLEMENTATION, run
   `analyze` once, then `verify run`. This command alone may pass
   VERIFICATION. A real verify failure or serious architectural review
   finding may trigger Builder Expert only after Builder has attempted it.
5. Run Reviewer when required. Run QA and Visual Reviewer only when harness
   requirements say so. Rework through a new Builder, analyze, verify, and
   re-review until findings are clean. Only Reviewer/Visual Reviewer resolve
   review threads. Never let an iteration cap substitute for clean review.
6. Run `harness done`; only then complete goal state. For single-PR goals,
   report ready for manual merge unless `auto_merge=true`, in which case run
   `merge` and stop on conflict. For Markdown multi-PR, report one PR per
   group and never create an aggregation PR.

## Worker handoff and waiting

Before each worker, resolve `models <role> --complexity <LEVEL>`, record
`harness spawn <role> <MODEL> <EFFORT>` and a
`harness event main <role>_started`. For builder tasks, set PENDING →
SPAWNING before delegation; set RUNNING only after Cursor accepts the Task.
Give the project `@<role>` a bounded brief: task, relevant discovery context
or findings, target repo/worktree, and expected handoff. Do not pass full
transcripts. For a parallel issue batch, delegate each ready issue's worker
up to the shared limit before waiting; then handle whichever result is ready
and refill a free slot. Otherwise wait for the result, record completion, and
continue the loop on MAIN. Do not generate repeated waiting commentary or poll a queue with model
turns; intervene on timeout, stall, or interruption.

If Cursor's Agent/Task tool is unavailable, keep the task PENDING, report the
capability blocker, and use `/goal --continue` once resolved. Never invent a
worker result or PASS gate. On provider/rate-limit failure, use the next
configured model only if Cursor can actually honor it; on missing tools,
lock, network, or UNKNOWN verification, report the blocker instead of
escalating the model.

Use typed `harness event main ...` at goal/issue pickup, before and after
worker spawns, verification, PR creation, and completion. Read progress from
`harness progress` rather than producing duplicate status turns.
