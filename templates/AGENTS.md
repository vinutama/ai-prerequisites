# AGENTS.md

## /goal workflow

This project uses **Goal Architecture Loop Engineering** — a persistent
workflow where AI agents drive a task from plan to merged PR, looping until
zero unresolved review threads remain.

### How to use
```
/goal <your objective>
```

### Agent roles
| Agent | Role | Model |
|---|---|---|
| `orchestrator` | Manages the full loop | opencode-go/deepseek-v4-flash |
| `planner` | Architecture & plans — tags tasks @builder or @builder-expert | opencode-go/qwen3.7-max |
| `builder` | Routine execution (CRUD, UI, refactors, config, tests) | opencode-go/deepseek-v4-flash |
| `builder-expert` | Complex execution (algorithms, concurrency, security, perf) | opencode-go/qwen3.7-max |
| `reviewer` | Code review | opencode-go/kimi-k2.7-code |
| `visual-reviewer` | UI/multimodal review | opencode/mimo-v2.5-free |

Model fallbacks are configured in `.opencode/goal-models.json`.

### Delegation
The planner tags every task:
- `@builder` — routine frontend/backend tasks.
- `@builder-expert` — novel algorithms, concurrency, auth/security,
  performance hot paths, complex state machines, distributed coordination.

The orchestrator delegates tasks to the tagged agent automatically.

### All agents operate in /ponytail full mode
- YAGNI first: question whether code needs to exist at all.
- Reuse existing code → stdlib/native → installed deps → then write.
- Shortest working diff; deletion over addition.
- No speculative abstractions, no future-proofing.
- Mark deliberate simplifications with `ponytail:` comments.
- Non-trivial logic leaves one runnable check behind.

### Platform detection
Platform is auto-detected from the origin remote URL. GitHub uses `gh` CLI,
GitLab uses `glab` CLI. Override with `GOAL_PLATFORM=github|gitlab`.

### Git workflow
All git operations MUST go through `.opencode/scripts/goal-git.sh`:
```bash
.opencode/scripts/goal-git.sh start <goal>     # create branch
.opencode/scripts/goal-git.sh commit [msg]     # conventional commit
.opencode/scripts/goal-git.sh push             # push to origin
.opencode/scripts/goal-git.sh pr               # create/update PR
.opencode/scripts/goal-git.sh pending          # check unresolved PR threads
.opencode/scripts/goal-git.sh analyze          # npx gitnexus analyze && rtk gain
```

### Review loop
- After code changes, run `.opencode/scripts/goal-git.sh analyze` (gitnexus + rtk gain).
  If it fails, STOP.
- Run `.opencode/scripts/goal-git.sh pending` to check PR threads.
- Loop until exit 0 (zero unresolved threads).

### State
Project state lives in `state.json` (gitignored). The orchestrator reads
and writes it.
