---
name: goal
description: >-
  Run a goal in MAIN from an objective, issue queue, status request, or continuation.
---

# Goal loop on MAIN

Read AGENTS.md and only the relevant README sections. You are MAIN and the only workflow
coordinator. Do not spawn an orchestrator. Remain in this thread through every
builder handoff, verification, review, conditional QA/visual check, and delivery
group or issue. Spawn planner, researcher, builder, builder-expert, reviewer,
qa, and visual-reviewer directly when required. Do not edit application
source yourself; delegate implementation and rework.

Use `.codex/scripts/goal-git.sh` for every git and goal-state operation; never
invoke raw `git`, `gh`, or `glab`. `state.json` and its harness are the authority
for phase, tasks, evidence, budgets, and completion. Never claim success before
`harness done` exits 0. Model IDs and effort for workers come only from
`.codex/goal-models.json` via `models <role> --complexity <LEVEL>`; pass both
to `harness spawn` and `spawn_agent`. MAIN's session model is user-selected.

## Dispatch

Parse the text after `$goal` before running the execution loop.

- `--list`: run `goal-git.sh list`; for multi-repo goals show `.repos` from
  `state`. Return without starting a worker.
- `--status`: run `harness progress` and `harness status`, showing phase,
  requirements, gates, and tasks. Mention `.codex/goal-progress.log` and
  `/agent` for live worker threads. Return.
- `--continue [id] [instruction]`: compare the first token to `goal-git.sh
  list`. If it matches, it is the ID and the rest is the new instruction;
  otherwise the full remainder is an instruction for the active goal. Run
  `continue`. If phase is FAILED or a task is SPAWNING/BLOCKED, run
  `harness recover-spawn`. Resume an incomplete issue queue if `issues queue`
  has entries, otherwise resume the active goal from its persisted phase.
  For a queue, select each issue with `GOAL_ISSUE` and follow the persisted
  batch plan. Never recreate an existing branch, worktree, PR, or completed task.
- `--issues [url] [count]`, or bare `$goal` when `goal_source=issues`: use the
  explicit URL/count or config's `issue_list_url`/`issue_limit` (default 3).
  Require a URL. Set `GOAL_RUN_ID`, run `issues list`, and read
  `references/issue-queue.md`. One issue uses `issues start <n>` and the normal
  loop; 2+ issues use one queue plan and one PR per issue. Independent
  single-repo issues in the same batch start together in separate worktrees.
- New goal: resolve `--source <prompt|markdown|jira|issues>` or configured
  `goal_source` (default `prompt`). Prompt requires nonempty objective.
  If the resolved source is `issues`, use the issue dispatch above.
  Markdown reads the explicit path or `markdown_path` from config and passes
  the path as draft input to Planner. Jira requires the Atlassian MCP; fetch
  the ticket, then run `GOAL_SOURCE_OVERRIDE=jira .codex/scripts/goal-git.sh
  start <summary> <ticket> <task-type>`. For prompt/markdown, run
  `GOAL_SOURCE_OVERRIDE=<source> .codex/scripts/goal-git.sh start <resolved-goal>`;
  preserve the optional Markdown task-type override (`bugfix` → `fix`) for a
  single delivery group. Then run the loop below.

## Core loop

Run `.codex/scripts/goal-git.sh codex ensure-user-config` before the first
worker spawn. This only sets project trust; it preserves the user's global
Codex settings. A newly trusted project may require a new Codex session to
load agent definitions.

Read `references/execution.md` before running a new or resumed goal. If the
active goal is Markdown `delivery_mode=multi-pr`, also read
`references/delivery-groups.md`. Read `references/issue-queue.md` only for an
issue invocation or resumed queue. These references are instructions, not
subagents. Do not load unrelated branches of the workflow into context.

1. Classify a short goal title with `complexity classify`; honor its
   `planner_required` and `reviewer_required` values. `route detect` is a
   baseline; Planner's routing and QA/visual signals take precedence.
2. For TRIVIAL, initialize the harness with planner/reviewer not required and
   skip their spawns. Otherwise provisionally initialize the harness, spawn
   Planner once, then initialize it with Planner's final route and requirements.
   Persist `discovery_context` after final init and pass PLAN. A Markdown
   document is draft input, not a reason to skip Planner.
3. Run Researcher only for a concrete unresolved question. Builders implement
   scoped tasks and stage a structured handoff. Independent tasks may use
   isolated worktrees; serialize state changes and shared-file edits.
4. After each reconciled implementation batch, pass IMPLEMENTATION, run
   `analyze` once, then `verify run`. This command alone can pass VERIFICATION.
   A real verify failure or serious architectural review finding can trigger
   Builder Expert only after Builder has attempted the task.
5. Run Reviewer when required. Run QA and Visual Reviewer only when harness
   requirements say so. Rework through a new Builder, analyze, verify, and
   re-review until findings are clear. Only Reviewer/Visual Reviewer resolve
   review threads. Never let an iteration cap substitute for a clean review.
6. Run `harness done`; only then complete goal state. For single-PR goals,
   report ready for manual merge unless `auto_merge=true`, in which case run
   `merge` and stop on conflict. For Markdown multi-PR, report one PR per group
   and never create an aggregation PR.

## Worker handoff and waiting

Before each spawn, resolve `models <role> --complexity <LEVEL>`, record
`harness spawn <role> <MODEL> <EFFORT>` and a `harness event main <role>_started`.
For builder tasks, set PENDING → SPAWNING before the spawn; set RUNNING only
after `spawn_agent` succeeds. Call `spawn_agent` with `agent_type=<role>`, the
resolved model and effort, and `fork_turns="none"` when supported. Pass a
bounded brief: task, relevant discovery
context or findings, target repo/worktree, and expected handoff. Do not pass
full transcripts. For a parallel issue batch, spawn each ready issue's worker
up to the shared limit before waiting; then handle whichever result is ready
and refill a free slot. Otherwise wait for the worker result, record its
completion, and continue the loop in MAIN. Do not generate repeated waiting commentary or
poll a queue with model turns; intervene on timeout, stall, or interruption.
If `spawn_agent` is unavailable, keep the task PENDING, report the capability
blocker, and use `$goal --continue` after it is resolved. Never invent a
worker result or a PASS gate. On provider/rate-limit failure, resolve the next
configured model; on missing tools, lock, network, or UNKNOWN verification,
report the blocker instead of escalating the model.

Use typed `harness event main ...` at goal/issue pickup, before and after
worker spawns, verification, PR creation, and completion. Read progress from
`harness progress` rather than producing duplicate status turns.
