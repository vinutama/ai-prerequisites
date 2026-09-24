# Cursor goal workflow

This project uses Goal Architecture Loop Engineering. `/goal` runs on MAIN;
MAIN coordinates the full goal and directly delegates to specialized Cursor
subagents. There is no orchestrator subagent. MAIN stays active through
planning, implementation, deterministic verification, review, conditional
QA/visual checks, and delivery. MAIN does not edit application source;
builders do.

## Setup and entry points

Run `/init-goal` once after `init.sh --cursor` to choose goal source, target
branch, git platform, concurrency, review mode, and auto-merge. Configuration
lives in `.cursor/goal-config.json`. `/init-skills` optionally installs
curated domain skills. Cursor uses these goal skills:

```text
/goal <objective>
/goal --list
/goal --status
/goal --continue [id] [new instruction]
/goal --issues [url] [count]
/create-issues <path.md>  # standalone; outside the goal loop
```

Sources: `prompt` (free text), `markdown` (draft plan input), `jira` (requires
Atlassian MCP), and `issues` (one branch and PR per issue). New Markdown
`auto`/`task` goals use Planner delivery groups: typed branches, isolated
worktrees, one PR per group, and no aggregation PR. `single` keeps one PR;
existing in-progress single-PR Markdown goals stay single-PR.

`/goal` is the execution contract. Its main skill stays compact and reads
only the relevant `references/` for normal execution, Markdown groups, or
issue queues. Do not load unrelated branches of the workflow.

## Agent responsibilities and routing

| Role | Responsibility |
|---|---|
| MAIN (`/goal`) | Sequence phases, own harness/git/state, delegate and wait for workers, enforce gates, report result |
| `planner` | Architecture plan and route/QA/visual/research signals; skipped only when classify says TRIVIAL |
| `researcher` | One concrete unresolved research question; conditional |
| `builder` | Implement and stage scoped changes; also handles rework |
| `builder-expert` | Escalation after Builder plus real verify failure or serious architectural review finding |
| `reviewer` | Diff-first correctness review and thread resolution; skipped when TRIVIAL |
| `qa` | Acceptance scenarios when `requirements.qa=true` |
| `visual-reviewer` | Multimodal UI check when `requirements.visual=true` |

MAIN resolves `models <role> --complexity <LEVEL>` from
`.cursor/goal-models.json` and records `harness spawn <role> <model> <effort>`
before each Cursor Agent/Task delegation. Cursor worker frontmatter controls
actual model selection; the catalog route is an audit value, not a per-spawn
override. MAIN's session model is user-selected. Visual Reviewer requires a
vision-capable configured model; never downgrade to text-only.

Keep worker briefs small: relevant task/context, diff or findings, target
repo/worktree, and expected handoff. Avoid repeated status polling. Read
milestones via `goal-git.sh harness progress`, `/goal --status`, or
`.cursor/goal-progress.log`.

All agents follow ponytail full mode: question unnecessary code, reuse
existing/native code before dependencies, prefer the smallest working diff,
mark deliberate simplifications with `ponytail:` comments, and leave a
runnable check for nontrivial logic. Optional domain skills are installed
through `/init-skills`; workers load only relevant installed skills.

## Harness and definition of DONE

The project-root `state.json` carries goal history and the active `harness`.
MAIN manages phases, tasks, retries, evidence, and compact context artifacts
through `.cursor/scripts/goal-git.sh`. `complexity classify` returns TRIVIAL,
NORMAL, COMPLEX, or ARCHITECTURAL. `route detect` is only a baseline;
Planner's routing is authoritative when Planner runs.

Always required: IMPLEMENTATION, ANALYSIS, VERIFICATION. PLAN and REVIEW are
required unless classify says TRIVIAL; QA and VISUAL only when their harness
requirement is true. IMPLEMENTATION needs all builder/expert tasks DONE;
ANALYSIS runs after each reconciled implementation batch; only `verify run`
may pass VERIFICATION. REVIEW needs reviewer verdict and zero unresolved
inline/local findings. QA needs a spawned QA run and clean `harness qa
pending`; VISUAL needs a spawned visual run and clean `harness visual pending`.
`harness done` must exit 0 before `state complete`.

On review/QA/visual or real verification failure, MAIN delegates a new
Builder, re-analyzes the batch, re-runs `verify run`, and delegates fresh
Reviewer/QA/Visual passes as required. Rework continues until review is
clean; escalation and verify-retry limits still stop failures. Only
Reviewers/Visual Reviewers resolve review threads. `analyze` (GitNexus +
tooling) is separate from application verification. Builders run targeted
checks; MAIN runs repository-wide analysis once per batch.

Concurrent independent tasks use isolated worktrees. One Markdown delivery
group owns one typed branch, worktree, harness, and PR; never put two
builders in its worktree. Multi-repo work preserves repo boundaries and
per-repo PRs.

## Git and state boundary

Never invoke `git`, `gh`, or `glab` directly during a goal. Use
`.cursor/scripts/goal-git.sh` for start/continue, worktrees, stage/commit,
push/PR, pending threads, review findings, merge, harness, groups, issues,
models, and state. MAIN may commit/publish after Builder stages; builders
never push. In local review mode, create the PR after clean local review.
In inline mode, create/update it before Reviewer. Auto-merge is opt-in; when
off, report "Ready for manual merge." Stop on merge conflict.

Project runtime files `.cursor/`, `state.json`, `.worktrees/`, and
`.goal-review/` are gitignored. `design-system/` is durable and tracked when
UI design guidance is generated. Figma is optional and, when configured, is
the visual source for Planner, Builder, and Visual Reviewer. Use
`.cursor/scripts/run-cursor.sh` if Figma secrets need to be loaded.

`/create-issues` is separate from `/goal`: it publishes one forge issue per
task checkbox under a Markdown `### Tasks` heading. It does not use the
goal harness, branches, or PRs. See `.cursor/skills/create-issues/SKILL.md`.
