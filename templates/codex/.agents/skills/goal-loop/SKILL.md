---
name: goal-loop
description: >-
  Goal Architecture Loop Engineering for Codex: MAIN coordinates specialized
  workers through evidence-backed plan, build, verification, review, and
  conditional QA/visual gates until the PR is clean.
---

# Goal Architecture Loop Engineering

The executable entry point is `$goal`; follow its `SKILL.md` and relevant
`references/` for commands and recovery details. MAIN owns orchestration,
spawns workers directly, waits for their results, and continues the same goal
thread. No orchestrator subagent or second coordinator is involved.

```text
$goal → classify → plan? → research? → build → analyze → verify
      → review? → QA? → visual? → rework as needed → harness done → PR/merge
```

`state.json` in the project root is the source of truth for the active goal
and its harness. Use `.codex/scripts/goal-git.sh` for all git, state, model,
and harness operations; never raw `git`, `gh`, or `glab`. MAIN does not edit
application source. Builder stages changes and returns a structured handoff;
MAIN runs `verify run` and owns commit/push/PR. The harness, not an agent's
judgment, decides whether required gates pass.

Always require IMPLEMENTATION, ANALYSIS, and VERIFICATION. PLAN and REVIEW
are required except when classify says TRIVIAL. Require QA/VISUAL only when
the harness says so. `verify run` is the only authority for VERIFICATION
PASS; `analyze` runs once per reconciled batch and does not replace it.
Never finish before `harness done` exits 0 or while a required finding is
open. Rework uses a fresh Builder, then analysis, verification, and review.
Only Reviewer/Visual Reviewer resolve review threads. Escalation and verify
retry limits hard-stop; clean review is not skipped due to a numeric cap.

Worker models and effort come from `.codex/goal-models.json` `$routing` at
spawn time. Researcher, Builder Expert, QA, and Visual Reviewer are
conditional. Expert follows Builder and a real verification failure or
serious architectural review finding. Visual Reviewer must use a
vision-capable model. Briefs carry only needed task context, findings, and
evidence, not full transcripts. Waiting does not justify repeated polling
turns; `harness progress` is the human timeline.

New Markdown goals default to planner delivery groups (`auto`/`task`): one
typed branch, isolated worktree, harness, and PR per group; no aggregation
PR. Legacy/single strategy keeps one PR. Issues have one branch and PR each.
Auto-merge is opt-in; otherwise report ready for manual merge. For multi-repo
goals, track and verify each repository independently.
