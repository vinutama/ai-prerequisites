---
name: goal-loop
description: >-
  Goal Architecture Loop Engineering for Cursor: MAIN coordinates specialized
  workers through evidence-backed plan, build, verification, review, and
  conditional visual gates until the PR is clean.
---

# Goal Architecture Loop Engineering

Use `/goal` and its relevant references. MAIN directly coordinates workers,
waits for results, records them serially, and closes completed threads. Builders
own application edits and staging. MAIN owns workflow state and delivery.

```text
intake snapshot → start → classify → plan? → research? → build
→ reconcile → commit → analyze → verify → review? → visual?
→ rework as needed → harness done → local PR/merge
```

Inline PR publication precedes Reviewer; local publication follows a clean
harness with idempotent review initialization before Reviewer. PR metadata is
mandatory: short descriptive single-line title ≤72 characters and body file
preferably with 100–200 words on actual changes/checks/reference. Empty diff stops.

`goal-git.sh` is the sole operational entry. `doctor --json`, `help`, and
`context --json` provide diagnostics and concrete paths. Carry explicit
`GOAL_ID`, `GOAL_RUN_ID`, `GOAL_ISSUE`, `GOAL_GROUP`, `GOAL_TASK`, and `GOAL_REPO`
in every invocation. One root state authority serves isolated worktrees;
shared `.git/info/exclude` keeps worktrees clean — do not copy `.cursor` into
worktrees. Never edit `.cursor/scripts` during a run. Workers return
milestones/tasks/findings instead of writing workflow state.

Reserve with `harness spawn`, print the brief with `harness brief`, launch via
Cursor Agent/Task with
`prompt="Read and follow your brief: <absolute-brief-path>"`, then
`spawn-confirm` with the task agent id or `cursor-<reservation>`; `spawn-fail`
releases failed launches. After close, `spawn-finish … --closed`. Counters count
confirmed launches only. Missing required Agent/Task capability is a saved
blocker. One targeted launch retry; `recover-spawn` restores the original phase
only for launch blockers. Never implement in MAIN.

IMPLEMENTATION/ANALYSIS/VERIFICATION are always required. PLAN/REVIEW are
required except TRIVIAL; VISUAL follows harness requirements. Only `verify run`
passes VERIFICATION. MAIN records returned Reviewer LGTM as
`{"verdict":"LGTM","sha":"<commit>"}` under `review_verdict`. All gate evidence
belongs to current committed SHA/assignment and is invalidated by rework.
Never complete before `harness done` exits 0. Only Reviewer/Visual Reviewer
supply evidence for resolving review findings; MAIN applies it serially.

Models/effort come from helper complexity routing for harness audit; Cursor
worker frontmatter owns the actual model (`inherit` by default). Vision
requirements stay combined with complexity and `--next` filtering. Expert
requires prior Builder plus real verify FAIL or serious architectural review
defect. New Markdown `auto`/`task` goals deliver one typed branch/worktree/
harness/PR per group; legacy/single retains one PR. Issues retain URL/run/repo
identity and one PR each. Multi-repo checks and delivery remain separate.
Auto-merge is opt-in.

CLI failures use helper structured diagnostics. Stop auth/permission blockers
with a suggested local command. No automatic browser login/upgrades, web or
`--web` fallback, or ad hoc forge operations. Read-only CLI help/version is
allowed; CLI docs lookup is maintenance outside active operations. Researcher
web for unrelated questions and application browser testing remain available.
