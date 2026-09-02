# ai-prerequisites

Scaffold AI agent prerequisites for **Goal Architecture Loop Engineering** — a
persistent workflow that drives tasks from plan to merged PR, looping until
zero unresolved review threads remain.

Supports **OpenCode**, **Cursor**, **Claude Code**, **Codex**, and **Qoder**. The loop is
the same on every target; only the native config layout and invocation syntax
differ.

## Quickstart

A target flag is required.

### OpenCode
```bash
./init.sh --opencode /path/to/your/project
cd /path/to/your/project
opencode
/init-goal          # configure goal source, target branch, platform, concurrency
/goal Add a health-check endpoint
```

### Cursor
```bash
./init.sh --cursor /path/to/your/project
cd /path/to/your/project
cursor-agent
/init-goal
/goal Add a health-check endpoint
```

### Claude Code
```bash
./init.sh --claude /path/to/your/project
cd /path/to/your/project
claude
/init-goal
/goal Add a health-check endpoint
```

### Codex
```bash
./init.sh --codex /path/to/your/project
cd /path/to/your/project
codex                 # CLI >= 0.138.0; trust the project so .codex/config.toml loads
$init-goal
$goal Add a health-check endpoint
```

Codex removed custom prompts in 0.117.0. Entry points are skills invoked with
`$goal`, `$init-goal`, `$init-skills` — not slash commands.

### Qoder
```bash
./init.sh --qoder /path/to/your/project
cd /path/to/your/project
qoder
/init-goal
/goal Add a health-check endpoint
```

### Multiple agents in one repo
```bash
./init.sh --cursor --claude /path/to/your/project
./init.sh --all /path/to/parent
```

### Multi-repo (coordinating multiple services)
```bash
./init.sh --opencode /path/to/parent
cd /path/to/parent
opencode
/init-goal          # select repos, configure goal source, platform, etc.
/goal Add health check across API and Worker
```

Auto-detection: target with `.git` → single-repo mode. Target without `.git`
but subdirectories have `.git` → multi-repo mode.

## What it installs

Shared across every target: `state.json` (gitignored, project root),
`.worktrees/` and `.goal-review/` (gitignored). Runtime config lives per-target.

| Target | Paths | Invoke |
|---|---|---|
| OpenCode | `AGENTS.md`, `.opencode/` (agents, commands, skills, scripts), `opencode.json`, `create-issues.sh` | `/goal`, `/create-issues` |
| Cursor | `AGENTS.md`, `.cursor/` (agents, skills, scripts) | `/goal` (skills with `disable-model-invocation`) |
| Claude Code | `CLAUDE.md`, `.claude/` (agents, commands, skills, scripts) | `/goal` |
| Codex | `AGENTS.md`, `.codex/` (TOML agents, scripts, `config.toml`), `.agents/skills/` | `$goal` |
| Qoder | `AGENTS.md`, `.qoder/` (agents, commands, skills, scripts), `.qoder/settings.json` (Figma MCP) | `/goal` |

Each tree includes the same 6 agents (`planner`, `builder`, `builder-expert`,
`reviewer`, `visual-reviewer`, `orchestrator`), `goal-git.sh`, `goal-models.json`,
and the `goal-loop` skill.

## Commands

| Command | Description |
|---|---|
| `./init.sh --<agent> <path>` | Scaffold the selected agent(s) into a project (single-repo) or parent directory (multi-repo) |
| `./init.sh --all <path>` | Scaffold all five agents |
| `./init.sh --clean --<agent> <path>` | Remove that agent's scaffold |
| `/init-goal` or `$init-goal` | One-time setup: goal source, target branch, git platform, concurrency, auto_merge, review_mode, repos (multi-repo), optional Figma |
| `/init-skills` or `$init-skills` | Optional: inject curated skills from agentic-awesome-skills |
| `/goal <objective>` or `$goal <objective>` | Start a new goal. Use `--source <type>` to override goal_source per invocation |
| `/goal --issues [url] [count]` or `$goal --issues [url] [count]` | Fetch open issues from a list URL and drive each to its own PR |
| `/goal --list` or `$goal --list` | List all goals |
| `/goal --continue [id] [instruction]` | Resume a goal; optional new instruction for this pass |
| `/create-issues <path.md>` | **OpenCode only** — create GitHub/GitLab issues from a markdown file (one `##` heading per issue) |

## Usage patterns

### Single-repo (one project)
```bash
./init.sh --opencode /path/to/your/project
cd /path/to/your/project
opencode
/init-goal
/goal Add a health-check endpoint
```

**When to use:** Working on a single repository. Agent config and `state.json`
live with the code. Branches and PRs are scoped to one repo.

### Multi-repo (coordinating multiple services)
```bash
./init.sh --opencode /path/to/parent
cd /path/to/parent
opencode
/init-goal          # select which repos to include (auto-detected)
/goal Add health check across API and Worker
```

**When to use:** Coordinating changes across multiple repositories (e.g. API +
worker + frontend). Agent config lives at parent level. One `/goal` creates
branches in all selected repos, builds in parallel (within dependency batches),
and creates PRs per repo.

**Auto-detection:** Target has `.git` → single-repo mode. Target has no `.git`
but subdirectories have `.git` → multi-repo mode. During `/init-goal`, you
select which repos to include from the detected list.

## Multi-repo workflow

When initialized at a parent directory with multiple git repos:

1. **`/init-goal`** — auto-detects git repos in subdirectories, prompts you to select which to include. Stores in `goal-config.json` as `repos` array.
2. **`/goal <objective>`** — creates branches with the same name in all selected repos. State tracks per-repo PR info.
3. **Planner** — sees all repos. Produces a unified plan with repo-tagged tasks (`[repo-name]`). Groups into dependency batches.
4. **Builders** — work in parallel within each batch, across repos. Each builder works in one repo at a time.
5. **Reviewers** — review each repo's PR independently. Cross-repo consistency checks are part of the review.
6. **Orchestrator** — coordinates the loop across repos, tracks per-repo state, reports all PR URLs at the end.

**Example:**
```
/goal Add health check across API and Worker

Planner output:
  Batch 1 (parallel — no dependencies):
    1. [tije-smpob-api] Add /health endpoint          @builder
    2. [tije-worker-v1] Add health check config        @builder

  Batch 2 (depends on batch 1):
    3. [tije-worker-v1] Implement health check consumer  @builder

Result: 2 PRs created (one per repo), both reviewed, ready to merge.
```

**Per-repo state in `state.json`:**
```json
{
  "goal": "Add health check",
  "branch": "goal/add-health-check",
  "base_branch": "main",
  "status": "in_progress",
  "repos": [
    {"path": "tije-smpob-api", "pr_number": 42, "pr_url": "https://..."},
    {"path": "tije-worker-v1", "pr_number": 18, "pr_url": "https://..."}
  ]
}
```

## Migration: single-repo → multi-repo

If you started in single-repo mode and later need to coordinate multiple repos:

```bash
# 1. Clean up existing single-repo template
./init.sh --clean --opencode /path/to/your/project

# 2. Init at parent level
./init.sh --opencode /path/to/parent

# 3. Run the agent and configure
cd /path/to/parent
opencode
/init-goal          # select repos, configure source, platform, etc.
```

Auto-cleanup: `init.sh` detects existing `.opencode/`, `.cursor/`, `.claude/`,
or `.codex/` in subdirectories during multi-repo init and offers to clean them
up automatically.

`--source` override: Prepend `--source <type>` to any `/goal` (or `$goal`)
call to override the configured `goal_source` for that single invocation. No
re-init needed.

```
/goal --source prompt Add health check
/goal --source markdown docs/feature.md
/goal --source jira PROJ-123
/goal --source issues
/goal --issues https://github.com/org/repo/issues 5
```

## Features

### Concurrent subagents (opt-in)
When `concurrency` > 1 (set via `/init-goal`), independent tasks run in
parallel using isolated git worktrees. The planner groups tasks into
concurrency batches; the orchestrator merges results back into the goal branch.

### Issue-driven goals (GitHub/GitLab)
When `goal_source` is `issues` (set via `/init-goal`), `/goal --issues` fetches
open issues from a configured or passed issue list URL, takes the first N
(`issue_limit`), and drives **each issue to its own branch and PR**. The planner
reorders by dependency and groups independent issues into concurrency batches;
the orchestrator runs parallel builders in isolated worktrees (single-repo only).
Multi-repo + issues processes one issue at a time across repos. Resume a partial
run with `/goal --continue`. Requires `gh` or `glab` authenticated for the repo
in the list URL.

```
/init-goal          # goal_source: issues, paste list URL, set issue_limit
/goal --issues 5    # or bare /goal when configured
```

Branch format: `{task_type}/{number}-{slug}` (e.g. `bug/42-health-check`).
PR bodies include `Closes #N` so merging closes the forge issue.

### Inline PR/MR review (`review_mode: inline`, default)
Reviewers post inline comments on GitHub/GitLab and **must** resolve threads when
issues are fixed (`goal-git.sh resolve`). The orchestrator never fixes code itself —
it re-delegates to builders until `pending` returns exit 0.

### Local review (`review_mode: local`)
Reviewers read `goal-git.sh diff` and record findings in gitignored `.goal-review/`
via `review add` / `review resolve`. No PR is created until review is clean; the
orchestrator commits locally during the fix loop, then `push` + `pr` in DONE.
Gate: `review pending` exit 0. Cap: `review_max_iterations` (default 5) via `review iterate`.

### Auto-merge (opt-in)
When `auto_merge` is `true` (set via `/init-goal`), the orchestrator runs
`goal-git.sh merge` after a clean review. Default is `false` — PR stays open for
manual merge. On merge conflict, agents stop and report; they do not invent resolutions.

### Model fallback (OpenCode only)
`init.sh --opencode` generates project-level `opencode.json` with the
`@razroo/opencode-model-fallback` plugin and per-agent `fallback_models`
(from `goal-models.json`). Plugin settings live in
`.opencode/opencode-model-fallback.json`. On rate limit or API error, agents
automatically try fallback models in order. Cursor, Claude Code, Codex, and Qoder have
no equivalent plugin.

### Multimodal review
Only `visual-reviewer` is multimodal. It accepts text and image input for
UI/screenshot review. All other agents are text-only. Capabilities are declared
in `goal-models.json`; `init.sh` syncs models from that file into agent
definitions.

### Figma design lookup (optional)
During `/init-goal`, connect Figma with a Personal Access Token and default design link.
PAT is stored in `<agent-dir>/figma.env` (gitignored); design URL and parsed file key
live in `goal-config.json`. Figma MCP is written to `opencode.json` (OpenCode),
`.mcp.json` (Claude Code), `.codex/config.toml` (Codex), or `.qoder/settings.json`
(Qoder). Launch with secrets via the per-target wrapper:
`.opencode/scripts/run-opencode.sh`, `.cursor/scripts/run-cursor.sh`,
`.claude/scripts/run-claude.sh`, `.codex/scripts/run-codex.sh`, or
`.qoder/scripts/run-qoder.sh`.

### Jira goal source
When configured, `/goal PROJ-123` fetches ticket content via Atlassian MCP.
`/init-goal` verifies MCP connectivity before saving.

### GitHub/GitLab issues goal source
When configured, `/goal --issues` or bare `/goal` fetches open issues from
`issue_list_url` via `gh` or `glab`, limited by `issue_limit`. `/init-goal`
verifies list access with `goal-git.sh issues list <url> 1` before saving.

### Skill injection (optional)
Run `/init-skills` to install a filtered subset of
[agentic-awesome-skills](https://github.com/sickn33/agentic-awesome-skills)
into the target's skills directory (project-level, not global). Choose the
**recommended** preset to install skills that all goal-loop agents look for, or
pick custom categories. Optionally also install
[ui-ux-pro-max](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill)
(`npx -y ui-ux-pro-max-cli init --ai opencode|cursor|claude|codex`) for UI/UX
design intelligence. Each agent loads related skills when present; if absent,
it proceeds normally. Requires `python3` for design-system generation.

Custom mode categories: `architecture`, `business`, `data-ai`, `development`,
`general`, `infrastructure`, `security`, `testing`, `workflow`. Default risk
filter: `safe,none`.

## Agent roles

| Agent | Role | OpenCode | Claude | Cursor | Codex | Qoder |
|---|---|---|---|---|---|---|
| `planner` | Architecture & plans — tags tasks @builder or @builder-expert | `opencode-go/qwen3.7-max` | `opus` | inherit | inherit, high effort, read-only sandbox | performance |
| `builder` | Routine execution (CRUD, UI, refactors, config, tests) | `opencode-go/deepseek-v4-flash` | `sonnet` | inherit | inherit, medium effort | efficient |
| `builder-expert` | Complex execution (algorithms, concurrency, security, perf) | `opencode-go/kimi-k2.7-code` | `opus` | inherit | inherit, high effort | performance |
| `reviewer` | Code review + inline PR comments | `opencode-go/deepseek-v4-pro` | `opus` | inherit | inherit, high effort | performance |
| `orchestrator` | Workflow manager | `opencode-go/deepseek-v4-flash` | `sonnet` | inherit | inherit, medium effort | efficient |
| `visual-reviewer` | UI/multimodal review + inline PR comments | `opencode-go/mimo-v2.5-pro` | `sonnet` | inherit | inherit, medium effort | inherit |

Every agent operates in `/ponytail full` mode.

### Delegation
The planner tags every task:
- `@builder` — routine frontend/backend tasks.
- `@builder-expert` — novel algorithms, concurrency, auth/security,
  performance hot paths, complex state machines, distributed coordination.

The orchestrator delegates automatically (OpenCode `@mentions`, Cursor/Claude/Qoder
subagent launch, Codex `spawn_agent` with `agent_type`).

## Fidelity gaps

The loop is the same. These are the harness limits:

- **Codex has no slash commands.** Custom prompts were removed in CLI 0.117.0. Use `$goal`.
- **Codex CLI 0.138.0+** is required. 0.137.0 hid `agent_type` from `spawn_agent`, which blocks custom-agent delegation.
- **Codex `.codex/config.toml` loads only for trusted projects.** Without trust, `max_depth`, network access, and the Figma MCP block are ignored. Confirm with `/status` after first launch.
- **Codex and Cursor cannot machine-enforce `edit: deny`** on `orchestrator`, `reviewer`, or `visual-reviewer`. That rule is prompt-enforced. (Claude Code uses a `tools` allowlist; OpenCode uses `permission.edit: deny`.)
- **Cursor allows two levels of subagent nesting.** `/goal` (main) → `orchestrator` → `builder` fits; builders must never spawn subagents.
- **Model fallback is OpenCode-only.**
- **Cursor and Codex have no `$ARGUMENTS` expansion.** Command skills read the text typed after `/goal` or `$goal` from the user message.
- **Installing `--cursor` and `--codex` together** surfaces the four goal skills twice in Cursor, because Cursor also scans `.agents/skills/`.

## Requirements

Shared:
- Git forge CLI — configured via `/init-goal` or auto-detected from origin remote:
  - **GitHub**: [GitHub CLI](https://cli.github.com) (`gh auth login`)
  - **GitLab**: [GitLab CLI](https://gitlab.com/gitlab-org/cli) (`glab auth login`)
  - Override with `GOAL_PLATFORM=github|gitlab`
- [Atlassian MCP](https://github.com/sooperset/mcp-atlassian) — required only for Jira goal source
- [RTK](https://github.com/rtk-ai/rtk) (`cargo install rtk`)
- `jq`, `npx` (Node.js >= 22), `git`
- [agentic-awesome-skills](https://github.com/sickn33/agentic-awesome-skills) — optional, via `/init-skills`

Per target:
- **OpenCode**: [OpenCode](https://opencode.ai) with OpenCode Go and Zen credentials; `@razroo/opencode-model-fallback`
- **Cursor**: Cursor IDE or `cursor-agent` CLI
- **Claude Code**: `claude` CLI
- **Codex**: `codex` CLI >= 0.138.0; project must be trusted so `.codex/config.toml` loads
- **Qoder**: `qoder` CLI
