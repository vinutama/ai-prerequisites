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

## Finish

1. `harness done` exit 0
2. Delivery with `--title` + `--body-file` (stop on empty diff)
3. `state complete` / `issues finish <n>` after validated delivery
4. Auto-merge only when configured; otherwise report ready for manual merge

## Resume

Restore selectors and source. Wait/close existing workers before duplicating launches.
`harness recover-spawn` only for launch blockers. Reuse branches/PRs/worktrees.
