---
name: goal
description: >-
  Run a goal in MAIN from an objective, issue queue, status request, or continuation.
---

# Goal loop on MAIN

Read AGENTS.md and relevant README sections. You are the sole coordinator.
Spawn specialized workers directly, wait for results, and remain active through
delivery. Delegate application source edits and rework to builders.

Before the first worker launch run `codex ensure-user-config` through the helper;
a newly trusted project may require a fresh session to load role definitions.
Use only the absolute `GOAL_GIT` for workflow/Git/forge operations. Read
[commands](references/commands.md) for context selectors, launch lifecycle,
metadata, and diagnostics. After a goal exists, resolve `context --json` with explicit `GOAL_ID`,
`GOAL_RUN_ID`, `GOAL_ISSUE`, `GOAL_GROUP`, `GOAL_TASK`, and `GOAL_REPO`;
carry all selectors on every invocation. For issues also carry `GOAL_ISSUE_REPO`
(forge identity); `GOAL_REPO` is the configured local repo key. MAIN serializes state writes. Every
worker returns milestones/tasks/findings for MAIN to record, including review
resolutions. Never depend on shared active group state.

## Dispatch and source intake

Parse the text after `$goal` before mutations.

- `--list`: `list`; show multi-repo scope from state and return.
- `--status`: `harness progress` and `harness status`; report phase, tasks,
  gates and blockers, then return. `/agent` opens live child threads.
- `--continue [id] [instruction]`: compare the optional ID against `list`,
  select the persisted identity, then `continue`. Restore source, run/repo/
  issue/group identities, phases, live agents, and reservations. Recover only
  diagnosed launch blockers with `harness recover-spawn`; it restores the
  original phase. Read the appropriate execution/queue/group reference.
  Reuse branches/worktrees/PRs and accepted artifacts.
- `--issues [url] [count]`, or source `issues`: resolve explicit URL/count or
  configured `issue_list_url`/`issue_limit` (default 3). Require a URL. Establish
  `GOAL_RUN_ID` and explicit repo scope, `issues list <url> <count>`, then read
  [issue queue](references/issue-queue.md). Carry the resolved URL into every
  `issues start <n> --url <url> [--worktree]`. One issue bypasses queue planning.
- New goal: resolve `--source <prompt|markdown|jira|issues>` or configured
  `goal_source` (default prompt). Before any branch/worktree mutation, capture
  full source JSON `{type,title,body,reference,acceptance_criteria}`. Prompt
  body is the full objective. Markdown body is the full draft file contents,
  with its path as reference; Planner must produce a fresh plan. For Jira,
  discover connected MCP tools at runtime, inspect their schemas, and read the
  full ticket and acceptance criteria. Stop on missing access rather than
  starting from a summary. `GOAL_SOURCE_OVERRIDE=<source> "$GOAL_GIT" start
  <title> [ticket] [task-type] --source-file <snapshot.json>` persists it.
  Preserve a single Markdown group task-type override (`bugfix` → `fix`).

## Core loop

Read [execution](references/execution.md) for new or resumed work; also read
[delivery groups](references/delivery-groups.md) only for Markdown multi-PR.
`goal-git.sh` is the sole operational entry; use its help and `doctor --json`
for failures. No browser/web/`--web`/ad hoc forge fallback or automatic upgrade.

1. Classify a short title with `complexity classify`. Honor planner/reviewer
   requirements. `route detect` is baseline; Planner signals are authoritative.
2. Initialize provisionally, launch Planner unless TRIVIAL, initialize final
   requirements, then persist discovery context and PLAN evidence. Researcher
   runs only for a concrete unresolved question.
3. Execute scoped Builder tasks in dependency order. Independent tasks use
   isolated worktrees; one Builder per checkout. MAIN records all returned
   milestones/task states and reconciles staged source serially.
4. Commit the reconciled staged batch through the helper, pass IMPLEMENTATION,
   run `analyze`, then `verify run` on the final committed clean HEAD. Expert
   requires a prior Builder attempt plus real verify FAIL or a serious architectural review defect. Infrastructure/UNKNOWN is a blocker.
5. Review the committed SHA and run required QA/visual checks. MAIN persists
   Reviewer JSON `{"verdict":"LGTM","sha":"<commit>"}` as `review_verdict`;
   all evidence must match the assignment and current SHA. Rework invalidates
   evidence and repeats commit → analysis → verify → fresh review/checks.
6. `harness done` must exit 0. Local PR publication follows a clean harness;
   inline publication precedes Reviewer. Require PR title/body metadata and
   stop on empty diff. Complete only after delivery; auto-merge is opt-in.

## Worker launch and handoff

Follow the reservation/confirm/fail protocol in [commands](references/commands.md).
Resolve `models <role> --complexity <LEVEL>` (plus `--require-multimodal` for
Visual Reviewer), then reserve `harness spawn <role> <model> <effort>
[--task tN]`. Inspect the live launch schema before passing role/model/effort;
never assume `agent_type` or `fork_turns`. Confirm only an actual successful
launch with its agent ID; release failed reservations. Missing required
capability is a saved blocker, never permission to implement in MAIN. Allow
one targeted launch retry; fallback keeps complexity and vision requirements.

Before dispatch, resolve context with all explicit selectors and validate its
identity and paths. Worktree creation/resume automatically copies managed
scripts/agents/config, workflow skills, and ignored AGENTS instructions; use
`worktree sync <path>` to refresh when needed, never copy state. Pass absolute
`WORKFLOW_ROOT`, `TARGET_WORKTREE`, local `GOAL_GIT`, every selector (empty only
when inapplicable), scoped task/source/context/findings, and expected output.
Workers must set these in each shell invocation. Wait for launched agents,
record results serially, and close completed threads using supported tools.
For parallel issue batches fill available slots before waiting and advance
only the returning worker's issue. Do not create duplicate polling turns.
