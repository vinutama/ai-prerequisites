# Common goal execution

MAIN owns the state machine and every worker launch. Read config/state with
explicit selectors and follow [commands](commands.md) for context, launch,
forge diagnostics, and metadata. Preserve source snapshots, multi-repo scope,
review mode, auto-merge, concurrency, and retry limits on resume.

## Plan and route

Classify a short title, preserving the full source separately. TRIVIAL uses
`route detect` and `harness init --route <route> --qa false --visual false
--complexity TRIVIAL --planner-required false --reviewer-required false`.
Otherwise initialize provisionally, reserve/launch/confirm Planner, and wait.
Give Planner the persisted source body/acceptance criteria, continuation,
and repo scope. Markdown contents are a draft, not an accepted plan. Require
routing, research/QA/visual signals, risks, numbered Builder tasks, compact
`discovery_context`, and delivery groups when applicable.

MAIN records returned milestones. Initialize final requirements from Planner,
then `harness context put discovery_context -` and `harness gate PLAN PASS`.
Persist after final init. Research only a precise unresolved question; enter
RESEARCHING, launch Researcher, store returned `research_report`, record its
milestones, and enter BUILDING. MAIN does not repeat repository discovery.

## Build and escalation

Execute tasks in dependency order. Parallelize independent file sets only in
isolated worktrees and reconcile serially. A queue's concurrency is a global
worker cap across issues. Multi-repo tasks select `GOAL_REPO` explicitly and
retain per-repo checks and PRs. One Builder owns a checkout at a time.

MAIN `harness task add builder <title>`, sets SPAWNING, resolves model/effort,
reserves `harness spawn ... --task tN`, then launches and confirms the actual
child ID before RUNNING. Start other ready workers before waiting in a parallel
batch. Builders stage only scoped changes and return task IDs/results/checks;
MAIN records DONE/BLOCKED/FAILED and milestones. Builders do not commit/push or
write workflow state. Rework gets a fresh thread with findings, changed diff,
and verify summary; omit the full prior transcript.

Expert is escalation-only after Builder has attempted the task and `verify run`
truly FAILs or Reviewer identifies a serious architectural defect. Planner risk,
complexity, or a Builder blocker alone is insufficient. MAIN increments
`harness retry escalations`, enters ESCALATED, launches Expert for one problem,
then returns to BUILDING. Missing tooling/auth/permissions/network/locks or
UNKNOWN verification is a saved blocker, not Expert/model escalation.

## Commit, analyze, and verify

After every implementation task is DONE and results are reconciled/staged,
MAIN commits the reconciled staged source through `commit <message>` first.
Confirm final committed clean HEAD, capture its SHA from helper evidence, pass
IMPLEMENTATION, and run `analyze` once on that commit. Then enter VERIFYING
and run `verify run`. Order: commit → ANALYSIS → formal verification → review/QA/visual.
All gate SHA evidence must point to this final committed clean HEAD; never run
ANALYSIS or formal checks on staged-only source and attach them to a later commit.
Do not create tasks or spawn implementation workers in VERIFYING.

Only `verify run` can pass VERIFICATION; analysis is separate. On real FAIL,
escalate if eligible or increment `harness retry verify_retries` and enter
REWORK → BUILDING with a new Builder. Rework invalidates SHA-bound evidence;
repeat commit/analyze/verify and required review/checks. Hard retry exhaustion
stops with FAILED. UNKNOWN/NOT_RUN never means PASS.

## Review, QA, and visual

Inline: publish the committed verified diff with mandatory title/body metadata
before Reviewer. Local: MAIN runs idempotent `review init` before Reviewer,
preserving prior findings, and publishes only after clean `harness done`.
An empty diff stops publication. Launch Reviewer when required, on the initial
committed diff and after every rework commit. Pass the SHA and verification
report. Reviewer/Visual Reviewer return findings and evidenced resolution
requests; MAIN applies them serially through the helper. Workers never write
review or harness state themselves.

MAIN records actual Reviewer JSON `{"verdict":"LGTM","sha":"<commit>"}` via
`harness context put review_verdict <file|->`. REVIEW requires matching current
SHA/assignment and zero unresolved `pending` (inline) or `review pending`
(local). Empty pending state alone is not LGTM. Honor SKIPPED when TRIVIAL.

QA runs only for `requirements.qa=true`. MAIN records returned scenario evidence
with `harness qa add`; PASS requires a confirmed QA run, complete runtime
evidence for required scenarios, clean `harness qa pending`, and the current SHA.
Visual runs only for `requirements.visual=true`. Resolve
`models visual-reviewer --complexity <LEVEL> --require-multimodal`; preserve
both flags with `--next`. MAIN records returned viewport observations with
`harness visual add`. PASS needs a confirmed visual run and clean
`harness visual pending` bound to current SHA. Recheck using the same scenario/
viewport key; preserve historical failures. Partial/static-only limitations
must not be presented as completed runtime evidence.

On findings increment rework, enter REWORK → BUILDING, launch a fresh Builder,
then commit → analyze → VERIFYING → `verify run` → fresh Reviewer and required
QA/Visual. FIXES_COMPLETE is a handoff to continue the loop. Review iterations
and spawn caps cannot justify LGTM; explicit verify/escalation limits still stop.

## Finish and resume

Run `harness done` only after all required SHA-bound evidence is current. Inline
threads must be clean; local publication follows the clean harness. Deliver one
PR per repo/issue/group using `--title` and `--body-file`. Auto-merge is opt-in;
stop on conflict, otherwise report ready for manual merge. `state complete`
follows required delivery, and all groups must be completed/merged/cancelled.

On continue restore selectors and persisted source, tasks, gates, reservations,
and live child IDs. Wait/record/close existing workers before duplicating any
launch. Recover only launch blockers with `harness recover-spawn`, restoring
the original phase. Reuse accepted planning and current-SHA evidence; new source
edits/rework invalidate prior evidence. Reuse existing branch/PR/worktree IDs.
