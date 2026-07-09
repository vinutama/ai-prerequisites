# AGENTS.md

## /goal workflow

This project uses **Goal Architecture Loop Engineering** — a persistent
workflow where AI agents drive a task from plan to merged PR, looping until
zero unresolved review threads remain.

### Setup
Run `/init-goal` once after `init.sh` to configure goal source, target branch,
and git platform for this project. Settings are stored in
`.opencode/goal-config.json` (project-level, gitignored).

### How to use
```
/init-goal                              # one-time project setup
/goal <your objective>                  # start a new goal
/goal --list                            # list all goals
/goal --continue [branch-or-goal-text]  # resume a previous goal
```

Goal source (configured via `/init-goal`):
- `prompt` — free-text objective (e.g. `/goal Add health check endpoint`)
- `markdown` — path to a `.md` file (e.g. `/goal docs/feature.md`)
- `jira` — Jira ticket key (e.g. `/goal PROJ-123`)

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
Platform is read from `.opencode/goal-config.json` (set via `/init-goal`).
Fallback: auto-detect from origin remote URL. Override with
`GOAL_PLATFORM=github|gitlab`.

### State and config (project-level only)
- `state.json` — goal history, branch, PR number (gitignored, project root only).
- `.opencode/goal-config.json` — goal source, target branch, platform (gitignored).

Both files are pinned to the project root. Agents read state via
`.opencode/scripts/goal-git.sh state` — never from a global or cwd-relative path.

### Git workflow
NEVER invoke `git`, `gh`, or `glab` directly. ALL git and state operations
MUST go through `.opencode/scripts/goal-git.sh`:
```bash
.opencode/scripts/goal-git.sh start <goal>     # create branch
.opencode/scripts/goal-git.sh continue [id]     # resume goal by branch/text
.opencode/scripts/goal-git.sh list              # list all goals
.opencode/scripts/goal-git.sh state            # print active goal JSON
.opencode/scripts/goal-git.sh stage <file>...  # stage specific files
.opencode/scripts/goal-git.sh commit [msg]       # commit staged changes
.opencode/scripts/goal-git.sh push               # push to origin
.opencode/scripts/goal-git.sh pr                 # create/update PR
.opencode/scripts/goal-git.sh pending            # check unresolved PR threads
.opencode/scripts/goal-git.sh analyze            # npx gitnexus analyze && rtk gain
.opencode/scripts/goal-git.sh status             # working tree status
.opencode/scripts/goal-git.sh restore <file>...  # restore files to HEAD
.opencode/scripts/goal-git.sh diff               # diff against base branch
.opencode/scripts/goal-git.sh config get         # print goal config
```

### Review loop
- After code changes, run `.opencode/scripts/goal-git.sh analyze` (gitnexus + rtk gain).
  If it fails, STOP.
- Run `.opencode/scripts/goal-git.sh pending` to check PR threads.
- Loop until exit 0 (zero unresolved threads).
