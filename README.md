# ai-prerequisites

Scaffold AI agent prerequisites for OpenCode with **Goal Architecture Loop
Engineering** — a persistent workflow that drives tasks from plan to merged
PR, looping until zero unresolved review threads remain.

## Quickstart

```bash
./init.sh /path/to/your/project
cd /path/to/your/project
opencode
/init-goal          # configure goal source, target branch, platform, concurrency, Figma
/goal Add a health-check endpoint
```

## What it installs

| Path | Purpose |
|---|---|
| `AGENTS.md` | Project conventions and workflow instructions |
| `state.json` | Runtime state (goal, branch, PR number) — gitignored, project-level |
| `opencode.json` | Model fallback config — project-level, generated from goal-models.json |
| `.opencode/goal-config.json` | Goal source, target branch, platform, concurrency, auto_merge, Figma design — gitignored |
| `.opencode/figma.env` | Figma PAT for MCP — gitignored |
| `.opencode/agent/` | 6 specialized agents |
| `.opencode/command/goal.md` | `/goal` slash command (with `--list`, `--continue` flags) |
| `.opencode/command/init-goal.md` | `/init-goal` setup command |
| `.opencode/command/init-skills.md` | `/init-skills` skill injection command |
| `.opencode/skills/goal-loop/` | Reusable goal-loop skill |
| `.opencode/goal-models.json` | Preferred, fallback, and capability config per agent |
| `.opencode/scripts/goal-git.sh` | Git helper (branch, commit, push, PR, review loop, worktrees) |

## Commands

| Command | Description |
|---|---|
| `/init-goal` | One-time setup: goal source, target branch, git platform, concurrency, auto_merge, optional Figma |
| `/init-skills` | Optional: inject curated skills from agentic-awesome-skills |
| `/goal <objective>` | Start a new goal |
| `/goal --list` | List all goals |
| `/goal --continue [id] [instruction]` | Resume a goal; optional new instruction for this pass |

## Features

### Concurrent subagents (opt-in)
When `concurrency` > 1 (set via `/init-goal`), independent tasks run in
parallel using isolated git worktrees. The planner groups tasks into
concurrency batches; the orchestrator merges results back into the goal branch.

### Inline PR/MR review
Reviewers post inline comments on GitHub/GitLab and **must** resolve threads when
issues are fixed (`goal-git.sh resolve`). The orchestrator never fixes code itself —
it re-delegates to builders until `pending` returns exit 0.

### Auto-merge (opt-in)
When `auto_merge` is `true` (set via `/init-goal`), the orchestrator runs
`goal-git.sh merge` after a clean review. Default is `false` — PR stays open for
manual merge. On merge conflict, agents stop and report; they do not invent resolutions.

### Model fallback
`init.sh` generates project-level `opencode.json` with the
`@razroo/opencode-model-fallback` plugin and per-agent `fallback_models`
(from `goal-models.json`). Plugin settings live in
`.opencode/opencode-model-fallback.json`. On rate limit or API error, agents
automatically try fallback models in order.

### Multimodal review
Only `visual-reviewer` is multimodal (`opencode-go/mimo-v2.5-pro`). It accepts
text and image input for UI/screenshot review. All other agents are text-only.
Capabilities are declared in `goal-models.json`; `init.sh` syncs models from
that file into agent `.md` frontmatter and `opencode.json`.

### Figma design lookup (optional)
During `/init-goal`, connect Figma with a Personal Access Token and default design link.
PAT is stored in `.opencode/figma.env` (gitignored); design URL and parsed file key
live in `goal-config.json`. `init-goal` runs `figma setup` then `figma design set`.
Launch OpenCode with secrets: `.opencode/scripts/run-opencode.sh`.

### Jira goal source
When configured, `/goal PROJ-123` fetches ticket content via Atlassian MCP.
`/init-goal` verifies MCP connectivity before saving.

### Skill injection (optional)
Run `/init-skills` to install a filtered subset of
[agentic-awesome-skills](https://github.com/sickn33/agentic-awesome-skills)
into `.opencode/skills/` (project-level, not global). Choose the **recommended**
preset to install skills that all goal-loop agents look for, or pick custom
categories. Each agent opportunistically reads and follows its related skills
when present under `.opencode/skills/<name>/SKILL.md`; if absent, it proceeds
normally.

Custom mode categories: `architecture`, `business`, `data-ai`, `development`,
`general`, `infrastructure`, `security`, `testing`, `workflow`. Default risk
filter: `safe,none`. Invoke installed skills by name in prompts (e.g. `@brainstorming`).

## Agent roles

| Agent | Role | Preferred Model |
|---|---|---|
| `planner` | Architecture & plans — tags tasks @builder or @builder-expert | `opencode-go/qwen3.7-max` |
| `builder` | Routine execution (CRUD, UI, refactors, config, tests) | `opencode-go/deepseek-v4-flash` |
| `builder-expert` | Complex execution (algorithms, concurrency, security, perf) | `opencode-go/kimi-k2.7-code` |
| `reviewer` | Code review + inline PR comments | `opencode-go/deepseek-v4-pro` |
| `orchestrator` | Workflow manager | `opencode-go/deepseek-v4-flash` |
| `visual-reviewer` | UI/multimodal review + inline PR comments | `opencode-go/mimo-v2.5-pro` |

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
- `@razroo/opencode-model-fallback` — loaded via `opencode.json` plugin (model fallback)
- [agentic-awesome-skills](https://github.com/sickn33/agentic-awesome-skills) — optional, via `/init-skills`
