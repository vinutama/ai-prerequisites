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
   `.codex/scripts/goal-git.sh`. NEVER invoke `git`, `gh`, or `glab` directly.
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
7. **Skills via native tool**: agents load installed skills with `$skill-name`.
8. **Ponytail full**: every agent operates in ponytail full mode.
9. **Conventional commits**: all commits use the Conventional Commits format.
10. **Inline / local review**: same as before (`review_mode` + `.goal-review/`).
11. **Builder handoff**: builders stage changes, emit **Handoff**; orchestrator runs verify.
12. **Token efficiency**: Researcher / Builder Expert / QA / Visual are conditional.
    Builder Expert is escalation-only — never a default parallel worker.
13. **Retry limits**: `harness retry` hard-stops loops when caps are exceeded.
14. **Auto-merge opt-in**: when `auto_merge` is true, orchestrator runs `merge` after
    clean review; default is manual merge.

## Agent Roles
| Agent | Role | Access |
|---|---|---|
| `orchestrator` | Manages workflow, harness, delegates | Full + task |
| `planner` | Architecture plans — route/research/risk signals | Read-only |
| `researcher` | On-demand research (docs, APIs, unfamiliar tech) | Read-only |
| `builder` | Routine execution across frontend and backend | Full |
| `builder-expert` | Escalation-only complex execution | Full |
| `reviewer` | Code correctness, security, tests | Bash (goal-git.sh only) |
| `qa` | Behavior/business acceptance (conditional) | Bash (goal-git.sh only) |
| `visual-reviewer` | UI quality, accessibility, visuals (conditional) | Bash (goal-git.sh only) |

## Delegation logic
Planner tags every implementation task `@builder` and emits:
- `route`: backend | feature | frontend
- `research_required`, `qa_required`, `visual_required`
- `high_risk_areas` (orchestrator may escalate to `@builder-expert`)

Orchestrator:
- Initializes harness with Planner signals:
  `harness init --route <r> --qa <bool> --visual <bool>`
- Spawns `@researcher` only when research is required
- Spawns `@builder-expert` only on escalation triggers (never parallel default)
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

## State (`state.json`)
Project-level only — pinned to the project root, never global.
```json
[
  {
    "goal": "the task objective",
    "branch": "goal/<slug> | feat/DEL-4123-<slug>",
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
      "events": []
    },
    "repos": [
      {"path": "repo-name", "pr_number": null, "pr_url": ""}
    ]
  }
]
```
The last entry is the active goal. Read via `goal-git.sh state`.

## Config (`.codex/goal-config.json`)
Project-level only — set via `/init-goal`.
```json
{
  "goal_source": "prompt|markdown|jira|issues",
  "target_branch": "main",
  "platform": "github|gitlab",
  "concurrency": 1,
  "auto_merge": false,
  "review_mode": "inline",
  "review_max_iterations": 5,
  "max_rework": 3,
  "max_escalations": 2,
  "max_verify_retries": 3,
  "qa_mode": "auto",
  "visual_mode": "auto",
  "verify_commands": [],
  "figma_enabled": false
}
```
`verify_commands` (optional array of `{name, cmd}`) overrides auto-detection entirely.
`qa_mode` / `visual_mode`: `auto|always|never`.

## Model routing (`goal-models.json` + orchestrator)
Per-agent models are pinned in agent `.toml` files and resolved at spawn time:

1. `init.sh` syncs `model` / `model_reasoning_effort` from `goal-models.json`
   into `.codex/agents/<role>.toml` and registers roles in `config.toml`.
2. Orchestrator runs `.codex/scripts/goal-git.sh models <role>` before each
   `spawn_agent`, always passing `agent_type` + `model` + `reasoning_effort`.
3. On failure, `models <role> --next <model>` picks the next
   `fallback_models` entry (vision-filtered for multimodal roles).
   Exhausted fallbacks → STOP and report.
4. Before spawning `visual-reviewer`, run
   `models visual-reviewer --require-multimodal`. Never downgrade to text-only.
   Allowlist: `$capabilities.vision_models` in `goal-models.json`.

Default map: planner=`gpt-6-astra`, orchestrator/researcher/visual=`gpt-5.6-terra`,
builder/builder-expert/reviewer/qa=`gpt-5.6-sol`.

## Git Helper (`.codex/scripts/goal-git.sh`)
```bash
.codex/scripts/goal-git.sh start <goal> [ticket] [task_type]
.codex/scripts/goal-git.sh continue [id]
.codex/scripts/goal-git.sh list
.codex/scripts/goal-git.sh state
.codex/scripts/goal-git.sh harness init --route <r> [--qa true|false] [--visual true|false]
.codex/scripts/goal-git.sh harness phase <STATE>
.codex/scripts/goal-git.sh harness task add <role> <title> [--parent tN]
.codex/scripts/goal-git.sh harness task set <id> <PENDING|RUNNING|DONE|BLOCKED|FAILED>
.codex/scripts/goal-git.sh harness gate <NAME> <STATUS> [reason]
.codex/scripts/goal-git.sh harness retry <rework|escalations|verify_retries>
.codex/scripts/goal-git.sh harness qa add <scenario> <PASS|FAIL> <note>
.codex/scripts/goal-git.sh harness qa pending
.codex/scripts/goal-git.sh harness visual add <viewport> <PASS|FAIL> <note>
.codex/scripts/goal-git.sh harness visual pending
.codex/scripts/goal-git.sh harness status
.codex/scripts/goal-git.sh harness done
.codex/scripts/goal-git.sh verify detect
.codex/scripts/goal-git.sh verify run [--only a,b]
.codex/scripts/goal-git.sh route detect
.codex/scripts/goal-git.sh analyze
.codex/scripts/goal-git.sh models [<role>] [--next <m>] [--require-multimodal [m]]
# … plus existing stage/commit/push/pr/pending/threads/review/worktree/issues/figma …
```
