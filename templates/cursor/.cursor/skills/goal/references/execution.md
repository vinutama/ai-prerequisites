# Common goal execution

MAIN owns this state machine and every Cursor Agent/Task worker delegation.
The harness, not an agent's claim, decides completion. Use only
`.cursor/scripts/goal-git.sh` for git/state. Read `state` and `config get` at
start and after a resumed phase. Preserve `goal_source`, multi-repo paths,
`review_mode`, `auto_merge`, concurrency, and retry limits. Give each worker
only the relevant handoff: `discovery_context`, `implementation_plan`,
`research_report`, staged diff, review findings, QA findings, or visual
findings. Workers load installed domain skills as needed.

## Plan and route

Classify a short title, not a full Markdown spec. For TRIVIAL, run `route
detect`, then `harness init --route <route> --qa false --visual false
--complexity TRIVIAL --planner-required false --reviewer-required false`, and
enter BUILDING. Otherwise provisionally `harness init --route feature --qa
false --visual false --complexity <LEVEL> --planner-required true
--reviewer-required true`; resolve the Planner catalog role, record
`harness spawn`, delegate to `@planner`, and wait. Give Planner the goal,
source, Markdown path if applicable, continuation instruction, and repo scope.
Require route, research/QA/visual signals, risks, acceptance criteria, task
plan, `discovery_context`, and delivery groups for Markdown multi-PR. Replay
Planner's read-only `## Milestones` into `harness event planner ...`.

Initialize the final harness from Planner signals, then put the compact
`discovery_context` via `harness context put discovery_context -` and run
`harness gate PLAN PASS`. Init preserves prior metrics/events/tasks but context
must be persisted after final init. Research only for a concrete unresolved
question: phase RESEARCHING, delegate `@researcher` once, save
`research_report`, replay milestones, then enter BUILDING. Do not repeat
codebase discovery in MAIN.

## Build and escalation

Execute Planner tasks in dependency order. With `concurrency>1`, parallelize
only independent file sets in isolated worktrees and merge sequentially.
Multi-repo tasks carry an explicit repo path and keep per-repo verification.
For each task: `harness task add builder <title>`, set SPAWNING, resolve the
catalog model/effort, `harness spawn`, delegate to `@builder`, then set RUNNING
and wait. On success mark DONE; on failure mark BLOCKED/FAILED. Builders
stage changes and return a compact handoff; they do not commit or push. A
rework Builder is a fresh Task with findings + diff + verify summary, not a
previous transcript.

Builder Expert is escalation-only after Builder has attempted the task and
`verify run` truly FAILs or Reviewer identifies a serious architectural
defect. Complexity or Planner risk labels alone are not triggers. Use
`harness retry escalations`, phase ESCALATED, delegate Expert with one focused
problem, then return to BUILDING. Missing tooling, environment, lock,
network, or UNKNOWN verification is a blocker, not an expert/model escalation.

## Analyze and verify

After implementation tasks are DONE with none pending/running, run
`harness gate IMPLEMENTATION PASS`, `analyze` once for the reconciled batch,
then enter VERIFYING and run `verify run`. No tasks or worker spawns in
VERIFYING. ANALYSIS must pass first; `analyze` does not replace application
verification. Only `verify run` may set VERIFICATION PASS. On a real FAIL,
use Expert if eligible; otherwise increment `harness retry verify_retries`,
enter REWORK → BUILDING, and delegate Builder. After code changes, analyze
and verify again. Stop with FAILED when a hard retry limit is exhausted;
never mark UNKNOWN/NOT_RUN as PASS.

## Review, QA, and visual

Use `review_mode` from config. In inline mode, commit/push/create or update
the PR before review; Reviewer records inline findings and resolves threads
after confirming fixes. In local mode, `review init` and review the diff
locally; push/create the PR only after clean review. Only Reviewer or Visual
Reviewer may comment on or resolve review threads. When Reviewer is required,
delegate an initial review and a fresh review after every rework push. A
verdict of LGTM plus `pending` or `review pending` exit 0 is needed for
REVIEW PASS. When Reviewer is not required, honor the harness's SKIPPED gate.

Delegate QA only when `requirements.qa=true`; require a QA run, recorded
acceptance scenarios, `harness qa pending` exit 0, and QA PASS. Delegate
Visual Reviewer only when `requirements.visual=true`; first resolve a
vision-capable catalog model with `models visual-reviewer
--require-multimodal`, then require a visual run, viewport observations,
`harness visual pending` exit 0, and VISUAL PASS. Cursor's agent frontmatter
must actually use a vision-capable model; a catalog audit alone cannot force
a runtime model. Never forge findings or gate evidence after failed spawn.

On review/QA/visual findings: collect unresolved items, increment rework,
enter REWORK → BUILDING, delegate a new Builder with findings and changed
diff, then analyze → VERIFYING → `verify run` → fresh Reviewer and applicable
QA/Visual. Continue until clean; verify-retry and escalation limits still
hard-stop. A Builder returning FIXES_COMPLETE is a handoff, not permission
to idle or skip re-review. Review and QA loops are not iteration-capped.

## Finish and resume

Before completion, run `harness done` (required PLAN unless trivial,
IMPLEMENTATION, ANALYSIS, VERIFICATION, REVIEW unless trivial, and
conditional QA/VISUAL). In inline mode confirm pending PR threads are clean.
In local mode push/create the PR after a clean harness. If `auto_merge=true`,
merge only after clean review and stop on conflict; otherwise report ready
for manual merge. Run `state complete` after required delivery work.

On `/goal --continue`, read persisted phase/tasks/gates and continue from
there. Use `harness recover-spawn` only when FAILED or SPAWNING/BLOCKED state
needs recovery. Do not rerun accepted planning, completed tasks, or a passed
verify gate unless new code changed. Reuse branch/PR/worktree IDs.
