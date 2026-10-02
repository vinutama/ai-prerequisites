# Codex goal workflow

`$goal` runs Goal Architecture Loop Engineering on MAIN. MAIN coordinates
Planner, Researcher, Builder, Builder Expert, Reviewer, QA, and Visual Reviewer
directly, waits for their results, and owns delivery. MAIN delegates all
application source edits and rework to builders. There is no orchestrator child.

## Entry and source intake

After `init.sh --codex`, run `$init-goal` to configure source, target branch,
forge, concurrency, review mode, optional Figma, and auto-merge. Configuration
lives in `.codex/goal-config.json`; worker routing lives in `goal-models.json`.
Use skills: `$goal <objective>`, `$goal --list`, `$goal --status`,
`$goal --continue [id] [instruction]`, or `$goal --issues [url] [count]`.
`$create-issues <path.md>` is a separate publishing skill outside the goal loop.

Complete source intake before branch/worktree mutations. Persist the full
prompt objective, Markdown draft contents, or Jira ticket as a source snapshot
with `type`, `title`, `body`, `reference`, and `acceptance_criteria`, then use
`start ... --source-file <snapshot.json>`. Discover actual Jira MCP tools at
runtime and read the full ticket; never invent tool names or start from its
summary alone. Issues retain the selected list URL, run and repository identity
through `issues start <n> --url <url> [--worktree]`.

New Markdown `auto`/`task` goals use Planner delivery groups: one typed branch,
isolated worktree, harness, and PR per group. No aggregation PR. `single` and
legacy in-progress single-PR goals retain one PR. Multi-repo goals preserve
repository boundaries, explicit repo selectors, separate checks, and per-repo PRs.

## Helper and execution context

`.codex/scripts/goal-git.sh` is the sole operational entry for Git, forge,
worktrees, configuration, models, harness, groups, issues, and workflow state.
Use `help`, `doctor --json`, and `context --json`. Resolve absolute
`WORKFLOW_ROOT`, `TARGET_WORKTREE`, and local `GOAL_GIT` from context with
explicit `GOAL_ID`, `GOAL_RUN_ID`, `GOAL_ISSUE`, `GOAL_GROUP`, `GOAL_TASK`, and
`GOAL_REPO` selectors. Carry every selector in every invocation; use explicit
empty values only for inapplicable selectors. For issues also carry
`GOAL_ISSUE_REPO`, the forge repository identity; `GOAL_REPO` is the configured
local repo key. These selectors serve different purposes. Never inherit a shared active
goal/group implicitly. Validate the returned identity before edits or mutations.

Worktree creation/resume automatically syncs managed `.codex` scripts, agents,
and config, `.agents` workflow skills, and ignored `AGENTS.md` instructions.
`worktree sync <absolute path>` refreshes existing worktrees when needed. It
copies instructions/configuration, never workflow state, locks, progress,
review files, or another worker's artifacts. The local helper resolves the
single state authority at `WORKFLOW_ROOT`; a worktree has no independent state.

Workers read/edit/check code only in their assigned `TARGET_WORKTREE`. MAIN
passes concrete paths, all selectors, task scope, source/acceptance criteria,
relevant context or findings, and expected handoff. Brief values are not shell
environment exports. Stop and return a context mismatch to MAIN.

## Roles and launch lifecycle

| Role | Responsibility |
|---|---|
| MAIN | Serial workflow/state writes, launch lifecycle, gates, commits and delivery |
| Planner | Discovery, tasks, routing and QA/visual/research signals; skipped on TRIVIAL |
| Researcher | One unresolved technical question; conditional |
| Builder | Scoped implementation/rework, targeted checks, staging |
| Builder Expert | Focused escalation after Builder plus real verify FAIL or serious architectural review defect |
| Reviewer | Independent committed-diff review and evidence for findings/resolutions |
| QA | Acceptance scenarios when `requirements.qa=true` |
| Visual Reviewer | Rendered UI evidence when `requirements.visual=true`; vision model required |

MAIN resolves model/effort with `models <role> --complexity <LEVEL>`; add
`--require-multimodal` for Visual Reviewer, including `--next <failed-model>`
on fallback. Inspect the live launch tool schema and use supported fields to
supply role instructions, model, and effort. Do not prescribe `agent_type` or
`fork_turns` blindly. Missing required delegation/model/vision capability is a
saved blocker; never implement in MAIN or substitute a text model.

`harness spawn <role> <model> <effort> [--task tN]` reserves budget and returns
`reservation.id` without counting a run. After launch succeeds, MAIN calls
`harness spawn-confirm <reservation-id> <agent-id>` to store the child and count
it. On launch failure, `harness spawn-fail <reservation-id> <category> <reason>`
releases a definitively failed reservation; uncertain outcomes remain held for
reconciliation. Retry a diagnosed launch blocker once; otherwise
save/stop. `recover-spawn` handles only launch blockers and restores the
original phase. Wait for every launched worker, record its result, then close
its thread using the available supported tool, then `harness spawn-finish
<agent-id> completed|failed --closed`. Resume existing live agents
without duplicating launches.

All workers return milestones, task results, and findings for MAIN to record
serially. Workers never write harness events/tasks/gates/context or review
state. Reviewer/Visual Reviewer alone supply evidence that a finding is fixed;
MAIN executes their requested review actions through the helper.
`harness progress`, `$goal --status`, and `.codex/goal-progress.log` show recorded
milestones; `/agent` opens the child thread. Avoid repeated polling turns.

## Gates and delivery

IMPLEMENTATION, ANALYSIS, and VERIFICATION are always required. PLAN/REVIEW
are required unless TRIVIAL; QA/VISUAL follow harness requirements. After each
reconciled staged implementation batch: MAIN commit, analysis, then formal
`verify run`, review, and required QA/visual checks. Only `verify run` passes
VERIFICATION. Evidence is bound to the committed SHA and assignment; rework
invalidates it and repeats commit → analysis → verify → fresh review/checks.

MAIN records actual Reviewer evidence with `harness context put review_verdict`
as JSON `{"verdict":"LGTM","sha":"<commit>"}` before passing REVIEW. Zero
pending findings alone is insufficient. QA/visual need confirmed worker runs,
recorded scenarios/observations, and clean pending checks. `harness done` must
exit 0 before completion. Unknown/not-run checks and blocked workers never pass.

Inline mode publishes before Reviewer. Local mode runs idempotent `review init`
before Reviewer, preserving existing findings; publish only after a clean
harness. Every `pr` or `groups pr <id>` requires `--title <short title>
--body-file <path>`: descriptive single line at most 72 characters, description, preferably 100–200 words, of actual changes, checks, and source reference. Do not paste full
requirements. Empty diff stops delivery. Merge only with `auto_merge=true`;
otherwise report ready for manual merge. Stop on merge conflict.

## CLI boundary

All operational failures use helper structured diagnostics and `doctor --json`.
The helper capability-probes installed CLIs and uses supported flags. Read-only
`git`/`gh`/`glab` help/version inspection is allowed; actual mutations and forge
operations use the helper. Never fall back to web search, browser, `--web`, or
ad hoc `gh`/`glab` operations to complete a failed command. Authentication or
permission blockers stop with the suggested local command; never launch browser
login automatically. No automatic upgrades. CLI documentation lookup belongs
to maintenance outside active operations. Researcher may browse for unrelated
implementation questions; UI browser checks remain available for application QA.

All roles follow ponytail full mode: reuse existing/native code, keep the
smallest useful diff, mark deliberate simplifications with `ponytail:` where
useful, and provide meaningful targeted checks for nontrivial logic.
Runtime `.codex/`, `state.json`, `.worktrees/`, and `.goal-review/` are ignored;
`design-system/` is durable tracked UI guidance. Figma is optional.
Follow `$goal` and its relevant references for detailed commands.
