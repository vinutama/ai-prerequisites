---
name: goal-loop
description: >-
  Goal Architecture Loop Engineering — a persistent workflow pattern where an
  orchestrator agent drives a task through plan → research? → build → verify →
  review → qa? → visual? cycles under a deterministic harness, looping until
  applicable gates pass and the PR has zero unresolved review threads.
  Uses ponytail full mode for all agents.
---

# Goal Architecture Loop Engineering

## Core Pattern
```
/GOAL → PLAN → RESEARCH? → BUILD → ESCALATE? → VERIFY → REVIEW → QA? → VISUAL? → LOOP → DONE
```

Extra domain skills can be injected project-level via `/init-skills` (from
[agentic-awesome-skills](https://github.com/sickn33/agentic-awesome-skills)).
Optionally also install
[ui-ux-pro-max](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill) for
UI/UX/frontend design intelligence.

## Rules
1. **Single source of truth**: `state.json` in the project root (includes `harness`).
2. **One tool for git**: all agents route git and state operations through
   `.cursor/scripts/goal-git.sh`. NEVER invoke `git`, `gh`, or `glab` directly.
3. **Orchestrator never fixes code**: review findings are delegated to `@builder` /
   `@builder-expert` (escalation only); orchestrator has `edit: deny`.
4. **Verify before review**: after implementation, run `goal-git.sh verify run`.
   Actual tooling is the authority for the VERIFICATION gate — never an LLM claim.
   `analyze` (gitnexus + rtk) is separate and is **not** a verify check.
5. **Harness gates Definition of DONE**: `harness done` must exit 0 before success.
   Required gates come from `requirements` (not hardcoded route). Always:
   PLAN, IMPLEMENTATION, VERIFICATION, REVIEW. Plus QA/VISUAL only when
   `requirements.qa` / `requirements.visual` are true. Required gates clear
   only on `PASS`.
6. **Consensus gate**: PR must have zero unresolved review threads before
   the loop exits. Reviewers must run `goal-git.sh resolve` (exit 0) for fixed threads before LGTM.
7. **Skills via native tool**: agents load installed skills with `/skill-name`.
8. **Ponytail full**: every agent operates in ponytail full mode.
9. **Conventional commits**: all commits use the Conventional Commits format.
10. **Inline / local review**: same as before (`review_mode` + `.goal-review/`).
11. **Builder handoff**: builders stage changes, emit **Handoff**; orchestrator runs verify.
12. **Token efficiency**: Researcher / Builder Expert / QA / Visual are conditional.
    Builder Expert is escalation-only — **after** `@builder` has attempted the
    task **and** `verify run` FAILs (or reviewer records a serious architectural
    defect). Never a default or first implementer.
13. **Retry limits**: `harness retry` hard-stops **escalations** and **verify_retries**.
    Review/rework continues until `pending` / `review pending` is clean (`review_max_iterations` is 0).
14. **Auto-merge opt-in**: when `auto_merge` is true, orchestrator runs `merge` (or `groups merge` per Markdown delivery group) after
    clean review; default is manual merge.
15. **Markdown multi-PR**: new Markdown goals default to multiple typed branches and PRs (`feat/` `fix/` `docs/` …), never a `goal/` aggregation PR. Each group has its own worktree, harness, and gates. Root completion requires every group.

## Agent Roles
| Agent | Role | Access |
|---|---|---|
| MAIN (`/goal`) | Thin: parse args, start/continue/list/status, spawn one `@orchestrator` | Setup only |
| `orchestrator` | Owns workflow, harness, all worker spawns | Full + task |
| `planner` | Architecture plans — route/research/risk signals | Read-only |
| `researcher` | On-demand research (docs, APIs, unfamiliar tech) | Read-only |
| `builder` | Routine execution across frontend and backend | Full |
| `builder-expert` | Escalation-only complex execution | Full |
| `reviewer` | Code correctness, security, tests | Bash (goal-git.sh only) |
| `qa` | Behavior/business acceptance (conditional) | Bash (goal-git.sh only) |
| `visual-reviewer` | UI quality, accessibility, visuals (conditional) | Bash (goal-git.sh only) |

## Delegation logic
```
User → MAIN (/goal) → @orchestrator → @planner / @builder / …
```
MAIN never spawns workers except as spawn-proxy when orchestrator nesting is withheld.
Orchestrator owns the loop.

Planner tags every implementation task `@builder` and emits:
- `route`: backend | feature | frontend
- `research_required`, `qa_required`, `visual_required`
- `high_risk_areas` (orchestrator may escalate to `@builder-expert` **after** builder + verify FAIL)
- `delivery_groups` when the goal is Markdown `auto`/`task` (typed branches, deps, file ownership)

Orchestrator:
- Initializes harness with Planner signals:
  `harness init --route <r> --qa <bool> --visual <bool>`
- For Markdown multi-PR: `groups init` then per-group `groups start`, builder(s) in that worktree only, verify/review/QA/visual, `groups pr`, merge in dependency order. No aggregation PR.
- Spawns `@researcher` only when research is required
- Spawns `@builder-expert` only on escalation triggers (never parallel default; only after builder + `verify run` FAIL)
- Runs `@qa` / `@visual-reviewer` only when harness `requirements` say so
- Always runs deterministic `verify run` before treating VERIFICATION as PASS
- Resolves visual model via `models visual-reviewer --require-multimodal`

## Routes and gates
`route detect` is a **baseline** only. Planner `route` / `qa_required` /
`visual_required` override it via `harness init --qa/--visual`.

Always required: PLAN, IMPLEMENTATION, VERIFICATION, REVIEW.
Conditional: QA iff `requirements.qa`; VISUAL iff `requirements.visual`.

PASS evidence: IMPLEMENTATION ← builder tasks DONE; VERIFICATION ← `verify run`
only; REVIEW ← pending/review pending; QA ← qa pending; VISUAL ← visual pending.

**analyze ≠ verify**
- `analyze` — gitnexus + rtk gain (tooling/analysis); ANALYSIS gate after implementation batches
- `verify run` — application correctness only (build/test/lint/typecheck/…)

## State (`state.json`)
Project-level only — pinned to the project root, never global.
```json
[
  {
    "goal": "the task objective",
    "branch": "goal/<slug> | feat/DEL-4123-<slug> | feat/g1-<slug>",
    "delivery_mode": "single | multi-pr",
    "markdown_pr_strategy": "auto | single | task",
    "delivery_groups": [
      {
        "id": "g1",
        "task_type": "fix",
        "title": "Correct schema and permission alignment",
        "branch": "fix/g1-correct-schema-permissions",
        "worktree": ".worktrees/g1-correct-schema-permissions",
        "depends_on": [],
        "status": "in_progress",
        "pr_number": null,
        "pr_url": "",
        "harness": {}
      }
    ],
    "base_branch": "main",
    "pr_number": null,
    "pr_url": "",
    "status": "in_progress|completed|failed",
    "harness": {
      "phase": "BUILDING",
      "route": "feature",
      "requirements": {"qa": true, "visual": false, "source": "explicit"},
      "tasks": [],
      "gates": {
        "PLAN": {"status": "PASS"},
        "IMPLEMENTATION": {"status": "PASS"},
        "VERIFICATION": {"status": "NOT_RUN"},
        "REVIEW": {"status": "NOT_RUN"},
        "QA": {"status": "NOT_RUN"},
        "VISUAL": {"status": "SKIPPED", "reason": "requirements.visual=false"}
      },
      "qa_findings": [],
      "visual_findings": [],
      "counters": {"rework": 0, "escalations": 0, "verify_retries": 0},
      "limits": {"max_rework": 3, "max_escalations": 2, "max_verify_retries": 3},
      "events": [
        {"at": "2026-09-13T20:12:00+07:00", "agent": "orchestrator", "event": "planner_started", "issue": 25, "detail": ""}
      ]
    },
    "repos": [
      {"path": "repo-name", "pr_number": null, "pr_url": ""}
    ]
  }
]
```
The last entry is the active goal. Read via `goal-git.sh state`.

## Config (`.cursor/goal-config.json`)
Project-level only — set via `/init-goal`.
```json
{
  "goal_source": "prompt|markdown|jira|issues",
  "target_branch": "main",
  "platform": "github|gitlab",
  "concurrency": 1,
  "auto_merge": false,
  "review_mode": "inline",
  "review_max_iterations": 0,
  "max_rework": 3,
  "max_escalations": 2,
  "max_verify_retries": 3,
  "qa_mode": "auto",
  "visual_mode": "auto",
  "markdown_pr_strategy": "auto",
  "max_tasks_per_pr": 3,
  "max_files_per_pr": 25,
  "max_parallel_prs": 2,
  "verify_commands": [],
  "figma_enabled": false
}
```
`verify_commands` (optional array of `{name, cmd}`) overrides auto-detection entirely.
`qa_mode` / `visual_mode`: `auto|always|never`.
`review_max_iterations`: `0` = unlimited. Review loops until `pending` / `review pending` is clean.
`markdown_pr_strategy`: `auto` (default for new Markdown goals) groups planner tasks into cohesive PRs; `single` keeps one PR; `task` is one PR per independently mergeable task. Limits are planning signals — never force unsafe splits. Existing in-progress Markdown goals without `delivery_mode=multi-pr` keep one-PR behavior.

## Model routing (`goal-models.json` + orchestrator)
Catalog = `.cursor/goal-models.json` only (edit per project). Cursor role agents pin
`model` in frontmatter (synced by `init.sh`); `models <role> --complexity` still
drives harness spawn audit and effort/role display:

1. Orchestrator runs `.cursor/scripts/goal-git.sh models <role> --complexity <LEVEL>`
   before each worker spawn.
2. On failure, `models <role> --next <model>` picks the next
   `fallback_models` entry (vision-filtered for multimodal roles).
   Exhausted fallbacks → STOP and report.
3. Before spawning `visual-reviewer`, run
   `models visual-reviewer --require-multimodal`. Never downgrade to text-only.
   Allowlist: `$capabilities.vision_models` in `goal-models.json`.

Do not document concrete model IDs here — read `$routing` / role defaults in JSON.

## Git Helper (`.cursor/scripts/goal-git.sh`)
```bash
.cursor/scripts/goal-git.sh start <goal> [ticket] [task_type]
.cursor/scripts/goal-git.sh continue [id]
.cursor/scripts/goal-git.sh list
.cursor/scripts/goal-git.sh state
.cursor/scripts/goal-git.sh complexity classify "<text>" [--files a,b]
.cursor/scripts/goal-git.sh harness init --route <r> [--qa true|false] [--visual true|false] [--complexity LEVEL] [--planner-required bool] [--reviewer-required bool]
.cursor/scripts/goal-git.sh harness phase <STATE>
.cursor/scripts/goal-git.sh harness task add <role> <title> [--parent tN]
.cursor/scripts/goal-git.sh harness task set <id> <PENDING|RUNNING|DONE|BLOCKED|FAILED>
.cursor/scripts/goal-git.sh harness gate <NAME> <STATUS> [reason]
.cursor/scripts/goal-git.sh harness retry <rework|escalations|verify_retries>
.cursor/scripts/goal-git.sh harness qa add <scenario> <PASS|FAIL> <note>
.cursor/scripts/goal-git.sh harness qa pending
.cursor/scripts/goal-git.sh harness qa resolve <id>
.cursor/scripts/goal-git.sh harness visual add <viewport> <PASS|FAIL> <note>
.cursor/scripts/goal-git.sh harness visual pending
.cursor/scripts/goal-git.sh harness visual resolve <id>
.cursor/scripts/goal-git.sh harness event <agent> <event> [detail]
.cursor/scripts/goal-git.sh harness progress [-n N] [--json]
.cursor/scripts/goal-git.sh harness spawn <role>
.cursor/scripts/goal-git.sh harness metrics
.cursor/scripts/goal-git.sh harness context put|get <name>
.cursor/scripts/goal-git.sh harness status
.cursor/scripts/goal-git.sh harness done
.cursor/scripts/goal-git.sh groups list
.cursor/scripts/goal-git.sh groups init [file|-]
.cursor/scripts/goal-git.sh groups start <group-id>
.cursor/scripts/goal-git.sh groups continue <group-id>
.cursor/scripts/goal-git.sh groups pr <group-id>
.cursor/scripts/goal-git.sh groups merge <group-id>
.cursor/scripts/goal-git.sh groups cancel <group-id>
.cursor/scripts/goal-git.sh verify detect
.cursor/scripts/goal-git.sh verify run [--only a,b]
.cursor/scripts/goal-git.sh route detect
.cursor/scripts/goal-git.sh analyze
.cursor/scripts/goal-git.sh models [<role>] [--complexity LEVEL] [--next <m>] [--require-multimodal [m]]
# … plus existing stage/commit/push/pr/pending/threads/review/worktree/issues/figma …
```
