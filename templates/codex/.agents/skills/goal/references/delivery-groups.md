# Markdown delivery groups

Read for Markdown `delivery_mode=multi-pr` (new `auto`/`task` strategy). Legacy
in-progress single-PR goals keep one PR. Intake persists the full Markdown draft
before mutations. Planner produces fresh discovery/tasks/groups unless TRIVIAL,
which uses one inseparable group with a reason.

Validate returned JSON with `groups validate -`, then MAIN `groups init -` and
records the grouping milestone. No aggregation PR. Use `groups list`,
`groups ready`, and `max_parallel_prs` for independent groups. Dependencies must
be merged or available on the intended base before dependent work starts.
`groups start <id>` creates typed branch/worktree; `groups continue <id>` is
idempotent on resume. Never use `worktree add` for a group or assign two Builders
to its checkout. Preserve separate repos and per-repo delivery.

Select `GOAL_GROUP=<id>` explicitly with goal/run/repo/task/issue selectors on
**every** invocation. `context --json` must resolve that group's worktree and
harness; never depend on a shared active-group overlay. MAIN serializes group
state mutations and `groups persist`. Creation/resume automatically syncs
managed scripts/agents/config, workflow skills, and ignored AGENTS instructions;
refresh existing copies when needed, never sync state. Workers receive concrete
paths/identities and return milestones/tasks/findings for MAIN to record.

Initialize each group's harness from Planner signals, persist its discovery
context after final init, pass PLAN, and enter BUILDING. Execute only its tasks/
files using the common commit → analyze → verify → review/QA/visual loop.
Evidence is bound to its committed SHA; one group's gates never clear another's.
Context mismatch is a blocker before any edit or mutation.

Inline: push and `groups pr <id> --title <short-title> --body-file <path>` before
Reviewer. Local: idempotent `review init` before Reviewer; publish only after
clean `harness done`. Metadata follows [commands](commands.md): ≤72 character
single-line title, a concise description (usually 100–200 words) of actual changes/checks/reference.
Stop on empty diff. Report a PR URL per group. With auto-merge,
`groups merge <id>` then start newly unblocked groups from the updated base;
stop on conflict. Otherwise report ready for manual merge and wait for the
prerequisite base before dependent groups.

On continue restore explicit group/repo identities, phases, reservations,
workers, worktrees, and PRs; reuse accepted current-SHA evidence and resume
incomplete work without recreation. Root `state complete` waits for every
required group to be merged/completed/cancelled. No final combined PR.
