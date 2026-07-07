---
name: goal-loop
description: >-
  Goal Architecture Loop Engineering — a persistent workflow pattern where an
  orchestrator agent drives a task through plan → build → analyze → review
  cycles, looping until the resulting PR has zero unresolved review threads.
  Uses ponytail full mode for all agents.
---

# Goal Architecture Loop Engineering

## Core Pattern
```
/GOAL → PLAN → BUILD → ANALYZE → REVIEW → LOOP (until PR clean)
```

## Rules
1. **Single source of truth**: `state.json` in the project root.
2. **One tool for git**: all agents route git operations through
   `scripts/goal-git.sh`.
3. **Analyze before review**: after every code change, run
   `npx gitnexus analyze && rtk gain`. If either fails, STOP.
4. **Consensus gate**: PR must have zero unresolved review threads before
   the loop exits.
5. **Ponytail full**: every agent operates in ponytail full mode — YAGNI
   first, reuse over rewrite, shortest working diff wins.
6. **Conventional commits**: all commits use the Conventional Commits format.

## Agent Roles
| Agent | Role | Access |
|---|---|---|
| `orchestrator` | Manages workflow, delegates, runs scripts | Full + task |
| `planner` | Architecture and implementation plans | Read-only |
| `builder-backend` | Server-side implementation | Full |
| `builder-frontend` | Client-side implementation | Full |
| `reviewer` | Code correctness, security, tests | Read-only |
| `visual-reviewer` | UI quality, accessibility, visuals | Read-only |

## State (`state.json`)
```json
{
  "goal": "the task objective",
  "branch": "goal/<slug>",
  "base_branch": "main",
  "pr_number": null,
  "pr_url": "",
  "status": "in_progress|completed|failed"
}
```

## Git Helper (`scripts/goal-git.sh`)
```bash
scripts/goal-git.sh start <goal>     # create branch, write state.json
scripts/goal-git.sh commit [msg]     # stage all, conventional commit
scripts/goal-git.sh push             # push branch to origin
scripts/goal-git.sh pr               # create or update PR
scripts/goal-git.sh pending          # exit 0 if no unresolved threads
scripts/goal-git.sh analyze          # npx gitnexus analyze && rtk gain
```
