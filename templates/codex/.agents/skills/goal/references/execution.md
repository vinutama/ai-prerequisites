# Common goal execution

MAIN owns the state machine and every worker launch. Carry explicit selectors.

## Plan and route

1. `complexity classify <short-title>`
2. TRIVIAL: `route detect` then `harness init --route … --visual false --complexity TRIVIAL --planner-required false --reviewer-required false`
3. Otherwise: provisional init → launch Planner (`brief` + `spawn_agent`) → wait
4. Record milestones; `harness init` final requirements from Planner
5. `harness context put discovery_context -` then `harness gate PLAN PASS`
6. Research only a precise unresolved question → RESEARCHING → Researcher → store `research_report`

Markdown drafts are not accepted plans. Planner must emit routing, tasks,
`discovery_context`, risks, and `pr_title` (conventional ≤72) when known.

## Build

1. Dependency order. Independent file sets → `worktree add tN` (namespaced path).
2. Per task: `harness task add builder <title>` → SPAWNING → `models` → `spawn` → `brief` → launch → confirm → RUNNING
3. Builder stages only; MAIN records DONE/BLOCKED/FAILED
4. Expert only after Builder attempt + real `verify run` FAIL (or serious architectural review defect)

## Reconcile task worktrees

Builders only stage; MAIN commits and reconciles. For `worktree add tN` tasks: commit
the task's staged work in its worktree, then from the goal checkout
`worktree merge tN`. On conflict resolve + `stage` + `commit` and re-run, or
`worktree merge tN --abort` and rework the overlap. Then continue below.

## Commit → analyze → verify

1. Reconcile/stage → `commit <message>` (invalidates SHA evidence)
2. `harness gate IMPLEMENTATION PASS` on clean HEAD
3. `analyze` once → ANALYSIS PASS
4. `harness phase VERIFYING` → `verify run`
5. Only `verify run` can PASS VERIFICATION. Missing tools → UNKNOWN (blocker, not Expert).

## Review / visual

- Inline: `push` + `pr draft` + edit Summary + `pr --title … --body-file …` before Reviewer
- Local: `review init` (idempotent; list auto-inits) before Reviewer; publish after `harness done`
- Reviewer JSON → `harness context put review_verdict -`
- Visual when requirements say so; record with `harness visual add`
- Findings → rework → fresh Builder → commit → analyze → verify → fresh review

## Rework

1. `harness retry rework` (fails past `max_rework`: ask the user, then `harness limit set max_rework <n>`)
2. `harness phase REWORK` — legal from VERIFYING, REVIEWING, VISUAL_REVIEW, DONE (late finding) and FAILED
3. `harness phase BUILDING`, then `harness task add builder <fix title>` or `harness task retry tN`
4. Launch → confirm → finish → commit → analyze → verify → fresh review
5. Builder/reviewer spawn caps grow automatically within `max_rework`; other caps: `harness budget set <key> <n>`.
   Drop an obsolete task with `harness task cancel tN`.

## Finish

1. `harness done` exit 0
2. Delivery with `--title` + `--body-file` (stop on empty diff)
3. `state complete` / `issues finish <n>` after validated delivery
4. Auto-merge only when configured; otherwise report ready for manual merge

## Resume

Restore selectors and source. `harness reap` first (releases reservations left by a
dead session; their tasks become PENDING), then `harness status` and follow
`next_action`. Wait/close live workers before duplicating launches.
`harness recover-spawn` only for launch blockers. Reuse branches/PRs/worktrees.
