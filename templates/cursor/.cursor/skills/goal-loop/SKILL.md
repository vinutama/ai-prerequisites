---
name: goal-loop
description: >-
  Goal Architecture Loop Engineering for Cursor: MAIN coordinates specialized
  workers through evidence-backed plan, build, verification, review, and
  conditional QA/visual gates until delivery is clean.
---

# Goal Architecture Loop Engineering

The executable entry point is `/goal`; follow its `SKILL.md` and relevant
`references/` for commands and recovery. MAIN owns orchestration, delegates
workers directly via Cursor Agent/Task, waits for their results, and
continues the same goal thread. No orchestrator subagent is involved.

```text
/goal → classify → plan? → research? → build → analyze → verify
      → review? → QA? → visual? → rework as needed → harness done → PR/merge
```

`state.json` is the source of truth. Use `.cursor/scripts/goal-git.sh` for
all git, state, model, and harness operations; never raw `git`, `gh`, or
`glab`. MAIN does not edit application source. Builder stages changes and
returns a structured handoff; MAIN runs `verify run` and owns commit/push/PR.
The harness, not an agent's judgment, decides whether required gates pass.

Always require IMPLEMENTATION, ANALYSIS, and VERIFICATION. PLAN and REVIEW
are required except when classify says TRIVIAL. Require QA/VISUAL only when
the harness says so. `verify run` alone can pass VERIFICATION; `analyze` runs
once per reconciled batch and does not replace it. Never finish before
`harness done` exits 0 or while a required finding is open. Rework uses a
fresh Builder, then analysis, verification, and review. Only Reviewer/Visual
Reviewer resolve review threads. Escalation and verify retry limits hard-stop;
clean review is not skipped due to a numeric cap.

Worker models come from Cursor agent frontmatter, synced from
`.cursor/goal-models.json` role entries by `init.sh`; the `$routing` lookup is
for harness audit. Researcher, Builder Expert, QA, and Visual Reviewer are
conditional. Expert follows Builder and a real verification failure or
serious architectural review finding. Visual Reviewer needs a vision-capable
model. Briefs carry only needed context, findings, and evidence, not full
transcripts. Waiting does not justify repeated polling turns.

New Markdown goals default to planner delivery groups (`auto`/`task`): one
typed branch, worktree, harness, and PR per group; no aggregation PR.
Legacy/single strategy keeps one PR. Issues have one branch and PR each.
Auto-merge is opt-in; otherwise report ready for manual merge. Track and
verify each repository independently for multi-repo goals.
