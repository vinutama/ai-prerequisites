# ai-prerequisites

Scaffold AI agent prerequisites for OpenCode with **Goal Architecture Loop
Engineering** — a persistent workflow that drives tasks from plan to merged
PR, looping until zero unresolved review threads remain.

## Quickstart

```bash
./init.sh /path/to/your/project
cd /path/to/your/project
opencode
/init-goal          # configure goal source, target branch, platform, concurrency
/goal Add a health-check endpoint
```

## What it installs

| Path | Purpose |
|---|---|
| `AGENTS.md` | Project conventions and workflow instructions |
| `state.json` | Runtime state (goal, branch, PR number) — gitignored, project-level |
| `opencode.json` | Model fallback config — project-level, generated from goal-models.json |
| `.opencode/goal-config.json` | Goal source, target branch, platform, concurrency — gitignored |
| `.opencode/agent/` | 6 specialized agents |
| `.opencode/command/goal.md` | `/goal` slash command (with `--list`, `--continue` flags) |
| `.opencode/command/init-goal.md` | `/init-goal` setup command |
| `.opencode/skills/goal-loop/` | Reusable goal-loop skill |
| `.opencode/goal-models.json` | Preferred and fallback model config per agent |
| `.opencode/scripts/goal-git.sh` | Git helper (branch, commit, push, PR, review loop, worktrees) |

## Commands

| Command | Description |
|---|---|
| `/init-goal` | One-time setup: goal source, target branch, git platform, concurrency |
| `/goal <objective>` | Start a new goal |
| `/goal --list` | List all goals |
| `/goal --continue [id] [instruction]` | Resume a goal; optional new instruction for this pass |

## Features

### Concurrent subagents (opt-in)
When `concurrency` > 1 (set via `/init-goal`), independent tasks run in
parallel using isolated git worktrees. The planner groups tasks into
concurrency batches; the orchestrator merges results back into the goal branch.

### Inline PR/MR review
Reviewers post inline comments on GitHub/GitLab and auto-resolve threads when
issues are fixed by builders.

### Model fallback
`init.sh` generates project-level `opencode.json` with `runtime_fallback`
enabled. On rate limit or API error, agents automatically try fallback models
in order (configured in `goal-models.json`).

### Jira goal source
When configured, `/goal PROJ-123` fetches ticket content via Atlassian MCP.
`/init-goal` verifies MCP connectivity before saving.

## Agent roles

| Agent | Role | Preferred Model |
|---|---|---|
| `planner` | Architecture & plans — tags tasks @builder or @builder-expert | `opencode-go/qwen3.7-max` |
| `builder` | Routine execution (CRUD, UI, refactors, config, tests) | `opencode-go/deepseek-v4-flash` |
| `builder-expert` | Complex execution (algorithms, concurrency, security, perf) | `opencode-go/kimi-k2.7-code` |
| `reviewer` | Code review + inline PR comments | `opencode-go/deepseek-v4-pro` |
| `orchestrator` | Workflow manager | `opencode-go/deepseek-v4-flash` |
| `visual-reviewer` | UI/multimodal review + inline PR comments | `opencode/mimo-v2.5-free` |

Every agent operates in `/ponytail full` mode.

### Delegation
The planner tags every task:
- `@builder` — routine frontend/backend tasks.
- `@builder-expert` — novel algorithms, concurrency, auth/security,
  performance hot paths, complex state machines, distributed coordination.

The orchestrator delegates automatically.

## Requirements

- [OpenCode](https://opencode.ai) with OpenCode Go and Zen credentials
- Git forge CLI — configured via `/init-goal` or auto-detected from origin remote:
  - **GitHub**: [GitHub CLI](https://cli.github.com) (`gh auth login`)
  - **GitLab**: [GitLab CLI](https://gitlab.com/gitlab-org/cli) (`glab auth login`)
  - Override with `GOAL_PLATFORM=github|gitlab`
- [Atlassian MCP](https://github.com/sooperset/mcp-atlassian) — required only for Jira goal source
- [RTK](https://github.com/rtk-ai/rtk) (`cargo install rtk`)
- `jq`, `npx` (Node.js >= 22), `git`
