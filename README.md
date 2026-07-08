# ai-prerequisites

Scaffold AI agent prerequisites for OpenCode with **Goal Architecture Loop
Engineering** — a persistent workflow that drives tasks from plan to merged
PR, looping until zero unresolved review threads remain.

## Quickstart

```bash
./init.sh /path/to/your/project
cd /path/to/your/project
opencode
/goal Add a health-check endpoint
```

## What it installs

| Path | Purpose |
|---|---|
| `AGENTS.md` | Project conventions and workflow instructions |
| `state.json` | Runtime state (goal, branch, PR number) — gitignored |
| `.opencode/agent/` | 6 specialized agents |
| `.opencode/command/goal.md` | `/goal` slash command |
| `.opencode/skills/goal-loop/` | Reusable goal-loop skill |
| `.opencode/goal-models.json` | Preferred and fallback model config per agent |
| `.opencode/scripts/goal-git.sh` | Git helper (branch, commit, push, PR, review loop) |

## Agent roles

| Agent | Role | Preferred Model |
|---|---|---|
| `planner` | Architecture & plans — tags tasks @builder or @builder-expert | `opencode-go/qwen3.7-max` |
| `builder` | Routine execution (CRUD, UI, refactors, config, tests) | `opencode-go/deepseek-v4-flash` |
| `builder-expert` | Complex execution (algorithms, concurrency, security, perf) | `opencode-go/qwen3.7-max` |
| `reviewer` | Code review | `opencode-go/kimi-k2.7-code` |
| `orchestrator` | Workflow manager | `opencode-go/deepseek-v4-flash` |
| `visual-reviewer` | UI/multimodal review | `opencode/mimo-v2.5-free` |

Every agent operates in `/ponytail full` mode.

### Delegation
The planner tags every task:
- `@builder` — routine frontend/backend tasks.
- `@builder-expert` — novel algorithms, concurrency, auth/security,
  performance hot paths, complex state machines, distributed coordination.

The orchestrator delegates automatically.

## Requirements

- [OpenCode](https://opencode.ai) with OpenCode Go and Zen credentials
- Git forge CLI — auto-detected from origin remote:
  - **GitHub**: [GitHub CLI](https://cli.github.com) (`gh auth login`)
  - **GitLab**: [GitLab CLI](https://gitlab.com/gitlab-org/cli) (`glab auth login`)
  - Override with `GOAL_PLATFORM=github|gitlab`
- [RTK](https://github.com/rtk-ai/rtk) (`cargo install rtk`)
- `jq`, `npx` (Node.js >= 22), `git`
