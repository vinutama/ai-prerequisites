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
| `planner` | Architecture and plans | opencode-go/qwen3.7-max |
| `builder-backend` | Server-side implementation | opencode-go/deepseek-v4-flash |
| `builder-frontend` | Client-side implementation | opencode-go/deepseek-v4-flash |
| `reviewer` | Code review | opencode-go/kimi-k2.7-code |
| `visual-reviewer` | UI/multimodal review | opencode/mimo-v2.5-free |

Model fallbacks are configured in `.opencode/goal-models.json`.

### All agents operate in /ponytail full mode
- YAGNI first: question whether code needs to exist at all.
- Reuse existing code → stdlib/native → installed deps → then write.
- Shortest working diff; deletion over addition.
- No speculative abstractions, no future-proofing.
- Mark deliberate simplifications with `ponytail:` comments.
- Non-trivial logic leaves one runnable check behind.

### Git workflow
All git operations MUST go through `scripts/goal-git.sh`:
```bash
scripts/goal-git.sh start <goal>     # create branch
scripts/goal-git.sh commit [msg]     # conventional commit
scripts/goal-git.sh push             # push to origin
scripts/goal-git.sh pr               # create/update PR
scripts/goal-git.sh pending          # check unresolved PR threads
scripts/goal-git.sh analyze          # npx gitnexus analyze && rtk gain
```

### Review loop
- After code changes, run `scripts/goal-git.sh analyze` (gitnexus + rtk gain).
  If it fails, STOP.
- Run `scripts/goal-git.sh pending` to check PR threads.
- Loop until exit 0 (zero unresolved threads).

### State
Project state lives in `state.json` (gitignored). The orchestrator reads
and writes it.
