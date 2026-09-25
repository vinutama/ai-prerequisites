# Common goal execution

MAIN owns this state machine and every worker spawn. The harness, not an
agent's claim, decides completion. Use only `.codex/scripts/goal-git.sh` for
git/state. Read `state` and `config get` at start and after a resumed phase.
Preserve `goal_source`, multi-repo paths, `review_mode`, `auto_merge`,
concurrency, and retry limits. Keep each child brief focused on the relevant
handoff: `discovery_context`, `implementation_plan`, `research_report`, staged
diff, review findings, QA findings, or visual findings.

## Plan and route

Classify a short title (not a full Markdown spec). For TRIVIAL, run `route
detect`, then `harness init --route <route> --qa false --visual false
--complexity TRIVIAL --planner-required false --reviewer-required false`, and
enter BUILDING. For other levels, provisionally `harness init --route feature
--qa false --visual false --complexity <LEVEL> --planner-required true
--reviewer-required true`; resolve/spawn Planner and wait. Give Planner goal,
source, Markdown path if applicable, continuation instruction, and repo scope.
Require route, research/QA/visual signals, risks, acceptance criteria, task
plan, `discovery_context`, and delivery groups for Markdown multi-PR. Replay
Planner's read-only `## Milestones` into `harness event planner ...`.

Initialize the final harness from Planner routing signals, then put the compact
`discovery_context` via `harness context put discovery_context -` and run
`harness gate PLAN PASS`. Init preserves prior metrics/events/tasks but context
must be persisted after final init. Research only if Planner gives a concrete
unresolved question: phase RESEARCHING, spawn Researcher once, save
`research_report`, replay milestones, then enter BUILDING. Do not repeat repo
discovery in MAIN.

## Build and escalation

Execute planner tasks in dependency order. With `concurrency>1`, parallelize
only independent file sets in isolated worktrees and merge them sequentially.
In an issue queue, count workers across all active issues against this one
limit; do not grant each issue its own pool of `concurrency` workers.
Multi-repo tasks carry an explicit repo path and retain per-repo verification.
For each task: `harness task add builder <title>`, set SPAWNING, resolve worker
model/effort, `harness spawn`, `spawn_agent`, then set RUNNING. In a parallel
issue batch, start other ready issue workers before waiting; otherwise wait
now. On success mark DONE; on failure mark BLOCKED/FAILED. Builders stage changes and
return a compact handoff; they do not commit or push. A rework Builder is a
fresh thread with findings + diff + verify summary, not the previous transcript.

Builder Expert is escalation-only after Builder has attempted the task and
`verify run` truly FAILs or Reviewer identifies a serious architectural
defect. Complexity or Planner risk labels alone are not triggers. Use
`harness retry escalations`, phase ESCALATED, spawn Expert with one focused
problem, then return to BUILDING. Missing tooling, environment, lock, network,
or UNKNOWN verification is a blocker, not an expert/model escalation.

## Analyze and verify

After all implementation tasks are DONE and no tasks are pending/running,
`harness gate IMPLEMENTATION PASS`, run `goal-git.sh analyze` once for the
reconciled batch, then enter VERIFYING and run `verify run`. Do not create tasks
or spawn workers in VERIFYING. ANALYSIS must pass first; `analyze` does not
replace application verification. Only `verify run` may set VERIFICATION PASS.
On a real FAIL, use Expert if eligible; otherwise increment
`harness retry verify_retries`, enter REWORK → BUILDING, and spawn Builder.
After any code change, analyze and verify again. Stop with FAILED when a hard
retry limit is exhausted; never mark UNKNOWN/NOT_RUN as PASS.

## Review, QA, and visual

Use `review_mode` from config. In inline mode, commit/push/create or update
the PR before review; Reviewer records inline findings and resolves threads
after confirming fixes. In local mode, `review init` and review the diff
locally; push/create the PR only after the review gate is clean. Only Reviewer
or Visual Reviewer may comment on or resolve review threads. When Reviewer is
required, spawn it for the initial diff and after every rework push; a verdict
of LGTM plus `pending` or `review pending` exit 0 is needed for REVIEW PASS.
When reviewer is not required, honor the harness's SKIPPED gate.

Spawn QA only when `requirements.qa=true`; require a QA run, recorded
acceptance scenarios, `harness qa pending` exit 0, and QA PASS. Spawn Visual
Reviewer only when `requirements.visual=true`; first resolve a vision-capable
model with `models visual-reviewer --require-multimodal`, then require a visual
run, viewport observations, `harness visual pending` exit 0, and VISUAL PASS.
Use the same viewport key when closing a visual failure. Never forge findings
or gate evidence after a failed spawn.

On review/QA/visual findings: collect the unresolved items, increment rework,
enter REWORK → BUILDING, spawn a new Builder with findings and changed diff,
then analyze → VERIFYING → `verify run` → fresh Reviewer and applicable
QA/Visual. Review/rework continues until clean; verify-retry and escalation
limits still hard-stop. A Builder returning FIXES_COMPLETE is a handoff, not
permission to idle or skip re-review.

## Finish and resume

Before completion, run `harness done` (required PLAN unless trivial,
IMPLEMENTATION, ANALYSIS, VERIFICATION, REVIEW unless trivial, conditional
QA/VISUAL). In inline mode confirm pending PR threads are clean. In local mode
push/create the PR after a clean harness. If `auto_merge=true`, merge only
after clean review and stop on conflict; otherwise report ready for manual
merge. Run `state complete` after all required delivery work is done.

On `$goal --continue`, read the persisted phase/tasks/gates and continue from
there. `harness recover-spawn` only when FAILED or SPAWNING/BLOCKED state
needs recovery. Do not rerun accepted planning, completed tasks, or a passed
verify gate unless new code changed. Reuse existing branch/PR/worktree IDs.
