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
   `.opencode/scripts/goal-git.sh`.
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
| `planner` | Architecture and implementation plans — tags tasks @builder or @builder-expert | Read-only |
| `builder` | Routine execution (CRUD, UI, refactors, config, tests) across frontend and backend | Full |
| `builder-expert` | Complex execution (algorithms, concurrency, security, perf, state machines, distributed coordination) | Full |
| `reviewer` | Code correctness, security, tests | Read-only |
| `visual-reviewer` | UI quality, accessibility, visuals | Read-only |

## Delegation logic
The planner analyzes task complexity and tags each planned item:
- `@builder` — standard CRUD, UI, refactors, config, glue code, routine tests.
- `@builder-expert` — novel algorithms, concurrency, auth/security, perf
  hot paths, complex state machines, distributed coordination, DB migrations.

The orchestrator reads these tags and delegates to the correct agent.

## State (`state.json`)
```json
[
  {
    "goal": "the task objective",
    "branch": "goal/<slug>",
    "base_branch": "main",
    "pr_number": null,
    "pr_url": "",
    "status": "in_progress|completed|failed"
  }
]
```
The last entry is the active goal. All commands read/write it.

## Git Helper (`.opencode/scripts/goal-git.sh`)
```bash
.opencode/scripts/goal-git.sh start <goal>     # create branch, append to history
.opencode/scripts/goal-git.sh continue [id]    # resume active or switch goal
.opencode/scripts/goal-git.sh list             # list all goals
.opencode/scripts/goal-git.sh stage <file>...   # stage specific files (new files only)
.opencode/scripts/goal-git.sh commit [msg]     # commit staged changes (conventional)
.opencode/scripts/goal-git.sh push             # push branch to origin
.opencode/scripts/goal-git.sh pr               # create or update PR
.opencode/scripts/goal-git.sh pending          # exit 0 if no unresolved threads
.opencode/scripts/goal-git.sh analyze          # npx gitnexus analyze && rtk gain
```
