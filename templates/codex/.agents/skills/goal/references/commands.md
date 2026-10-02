# Helper commands and failure handling

`goal-git.sh` is the sole operational entry. All examples below require the
resolved absolute `GOAL_GIT` and assignment selectors in the same shell
invocation. Other script modules are implementation details, not entry points:
forge.sh handles CLI capabilities, retries, pagination and typed API payloads;
goal-context.sh resolves shared state and checkouts; goal-delegation.sh owns
launch reservations; goal-delivery.sh guards publication; goal-evidence.sh
tracks current commit evidence; delivery-groups.sh manages Markdown groups.

## Context and isolation

Before intake, use the installed checkout helper's `help` and `doctor --json`.
For a new goal use explicit empty selectors where identity does not exist yet;
retain returned identities after start. On resume restore identities from state.
Resolve `context --json`, validate the selected assignment, and use its absolute
`WORKFLOW_ROOT`, `TARGET_WORKTREE`, and local `GOAL_GIT` for subsequent commands.
Use the returned GOAL_GIT; configured service repositories can share the controller helper.
Never guess another helper path from a worker checkout.

```bash
export GOAL_ID="<goal-id>" GOAL_RUN_ID="<run-id>"
export GOAL_ISSUE="<number-or-empty>" GOAL_GROUP="<group-id-or-empty>"
export GOAL_TASK="<task-id-or-empty>" GOAL_REPO="<configured-repo-key-or-empty>"
export GOAL_ISSUE_REPO="<forge-repository-identity-or-empty>"
GOAL_GIT="<absolute installed helper path>"
"$GOAL_GIT" context --json
```

Carry all assignment exports in **every shell invocation**, including helper help,
models, status, stage, review, and failure diagnostics. Briefs do not export
environment variables. Explicit `GOAL_GROUP` chooses the group's harness;
`GOAL_REPO` is a configured local repository key, not a forge URL.
`GOAL_ISSUE_REPO` is the issue forge repository identity; carry it through
list/start/resume and every issue-specific invocation to disambiguate equal
issue numbers across repositories. It does not replace `GOAL_REPO`. Shared active selection is not a substitute.
Before a new issue/group/task operation, select its identity explicitly and
resolve context again. Stop on any returned path/identity mismatch.

Creation/resume automatically syncs managed `.codex` scripts/agents/config,
`.agents` workflow skills, and ignored `AGENTS.md`. Refresh existing instructions
with `worktree sync <absolute path>` when needed. Never copy `state.json`, locks,
progress logs, review state, or worker artifacts; `WORKFLOW_ROOT` owns state.

## Launch reservations

MAIN performs these steps serially per assignment; code work can overlap in
independent worktrees within the global worker limit.

```text
models <role> --complexity <LEVEL> [--require-multimodal]
harness spawn <role> <model> <effort> [--task tN]
# returns reservation.id; reserves budget, does not increment run counters
# inspect live launch schema, launch child with supported role/model/effort fields
harness spawn-confirm <reservation-id> <agent-id>
# stores actual child ID and increments counters only after launch success
```

Builder tasks become SPAWNING before launch and RUNNING only after successful
launch/confirmation. Keep reservation and actual agent IDs distinct. MAIN emits
pickup/start events, waits with the supported tool, records the worker's result,
then closes the completed thread. After supported tool closure succeeds, MAIN
records `harness spawn-finish <agent-id> completed|failed --closed`; record the
actual task result before finishing so BLOCKED is not converted into DONE.
Do not claim closure while its tool outcome is unknown. All workers return `## Milestones`, task IDs,
results, and findings; MAIN replays/persists them serially. Workers do not write
harness/context/review state or switch goals/groups.

Inspect the actual live delegation schema. Use `agent_type`, `fork_turns`, model,
or effort fields only when supported, and use the supported role-instruction
mechanism. If a required role/model/effort/vision capability is absent, save the
blocker and stop; never count a run or perform application implementation in MAIN.

On launch failure:

```text
harness spawn-fail <reservation-id> <category> <reason>
# releases reservation; no fabricated worker evidence
models <role> --complexity <LEVEL> --next <failed-model> [--require-multimodal]
```

If launch outcome is unknown, use category `uncertain`, stop, and reconcile the
actual child before release/retry; held capacity prevents duplicate launches.
Only a definitive failed launch releases its reservation.

Retain complexity and multimodal filtering on fallback. Permit one targeted
retry for a diagnosed launch blocker; provider/rate-limit retry uses a configured
fallback. Missing tools/auth/permissions/network/locks are operational blockers,
not architectural escalations. Save/stop if the retry fails or a required
capability remains absent. `harness recover-spawn` is only for recorded launch
blockers and restores their original phase; it must not clear real implementation,
verification, review, QA, or visual failures. On resume reconcile reservations
and existing live child IDs before any fresh launch.

## Review evidence and PR metadata

MAIN commits reconciled staged source before ANALYSIS and formal verification,
review, QA, or visual checks. All gate SHA evidence uses the final committed clean HEAD.
Capture the commit SHA from helper evidence and pass it to Reviewer,
QA, and Visual Reviewer. Gate evidence belongs to that SHA and assignment;
rework invalidates it. For configured service repositories, carry GOAL_REPO
and run analysis, full verification, and required review/checks for every repo;
completion rejects missing or stale repo evidence. Set appropriate explicit
spawn budgets before allocating workers across repositories. Integrate task
branches and clear GOAL_TASK before goal verification, publication, or merge.
MAIN records only a returned Reviewer verdict:

```text
harness context put review_verdict <review-verdict.json>
# JSON: {"verdict":"LGTM","sha":"<commit>"}
```

An empty pending list does not create Reviewer evidence. MAIN applies returned
review findings/resolution requests via helper `comment`/`resolve` in inline
mode or `review add`/`review resolve` locally. Only Reviewer/Visual Reviewer may
supply evidence that a review item is fixed. Record QA/visual results with their
scenario/viewport keys, preserving FAIL audit rows and using the same key on
recheck. Blocked/NOT_RUN/PARTIAL evidence cannot pass a required gate.

```text
pr --title <short-title> --body-file <path>
groups pr <group-id> --title <short-title> --body-file <path>
```

Always supply both flags on creation/update. Body length is style guidance;
the helper does not impose a 100-word minimum. Title: descriptive, one line,
≤72 characters. Body: preferably 100–200 words explaining actual changes, checks/results,
and issue/ticket/Markdown reference. Write actual newlines into a file; do not
paste full requirements or invent checks. Stop on empty diff. Preserve existing
PR identity on retries/resume. An uncertain creation is saved in the shared
forge cache. If no matching request is observable, preserve that ledger and
stop; a repeated invocation cannot create again until the outcome is reconciled.
Authentication/validation rejection permits a later corrected invocation.
Inline publication precedes Reviewer; local
`review init` is idempotent and precedes Reviewer, preserving findings across
rework, with publication only after `harness done` is clean.

## Diagnostics and forge boundary

For any CLI operation failure read the helper's structured diagnostic and run
`doctor --json` with the same selectors. Report the failing operation, category,
and suggested local command. The helper capability-probes the installed CLI;
help/version inspection with read-only `git`/`gh`/`glab` is allowed. Actual
mutations and forge operations always use the helper.

Never complete a failed operation through web search, browser, `--web`, or ad hoc
`gh`/`glab`. Authentication/permission blockers stop; show the suggested local
command for the user to run and resume later. Do not launch browser login or
upgrade/install tools automatically. Unsupported flags/helper contracts are
maintenance blockers, not proof of failed authentication. Lookup of CLI docs
and helper repairs happen in maintenance outside an active operation. Researcher
may use the web for unrelated implementation questions, and application browser
QA/visual evidence is allowed.
