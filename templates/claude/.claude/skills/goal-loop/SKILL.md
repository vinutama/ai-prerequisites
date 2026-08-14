---
name: goal-loop
description: >-
  Goal Architecture Loop Engineering — a persistent workflow pattern where an
  orchestrator agent drives a task through plan → build → analyze → review
  cycles, looping until the resulting PR has zero unresolved review threads.
---

# Goal Architecture Loop Engineering

## Core Pattern
```
/GOAL → PLAN → BUILD → ANALYZE → REVIEW → LOOP (until PR clean)
```

Extra domain skills can be injected project-level via `/init-skills` (from
[agentic-awesome-skills](https://github.com/sickn33/agentic-awesome-skills)).
Optionally also install
[ui-ux-pro-max](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill) for
UI/UX/frontend design intelligence (`uipro init --ai claude`).

## Rules
1. **Single source of truth**: `state.json` in the project root (project-level only).
2. **One tool for git**: all agents route git and state operations through
   `.claude/scripts/goal-git.sh`. NEVER invoke `git`, `gh`, or `glab` directly.
3. **Orchestrator never fixes code**: review findings are delegated to `@builder` /
   `@builder-expert` only; orchestrator has `edit: deny`.
4. **Analyze before review**: after every code change, run
   `npx gitnexus analyze && rtk gain`. If either fails, STOP.
5. **Consensus gate**: PR must have zero unresolved review threads before
   the loop exits. Reviewers must run `goal-git.sh resolve` (exit 0) for fixed threads before LGTM.
6. **Skills via Skill tool**: agents load installed skills with the Skill tool — not `@mentions` or Read on SKILL.md paths.
7. **Ponytail full**: every agent operates in ponytail full mode — YAGNI
   first, reuse over rewrite, shortest working diff wins.
8. **Conventional commits**: all commits use the Conventional Commits format.
9. **Inline review**: reviewers post comments on the PR/MR and resolve threads
   when issues are fixed (use GraphQL thread `id` from `threads`; require resolve exit 0);
   each pass outputs a structured **Review report**.
10. **Builder handoff**: builders stage changes, pass `analyze`, then emit **Handoff**
   (`FIXES_COMPLETE` or `BLOCKED`). Orchestrator resumes immediately — no idle wait.
11. **Visual review for UI**: planner marks `@visual-reviewer` required for UI goals;
   orchestrator always delegates when plan, Figma, or UI file changes require it.
12. **UI/UX Pro Max (optional)**: when installed, UI/frontend goals use Figma as visual
    source of truth if enabled; otherwise persist/reuse `design-system/MASTER.md` via the
    skill's design-system generator. Builders and visual-reviewer apply the pre-delivery checklist.
13. **Auto-merge opt-in**: when `auto_merge` is true, orchestrator runs `merge` after
    clean review; default is manual merge.

## Agent Roles
| Agent | Role | Access |
|---|---|---|
| `orchestrator` | Manages workflow, delegates, runs scripts | Full + task |
| `planner` | Architecture and implementation plans — tags tasks @builder or @builder-expert | Read-only |
| `builder` | Routine execution (CRUD, UI, refactors, config, tests) across frontend and backend | Full |
| `builder-expert` | Complex execution (algorithms, concurrency, security, perf, state machines, distributed coordination) | Full |
| `reviewer` | Code correctness, security, tests — posts inline PR comments | Bash (goal-git.sh only) |
| `visual-reviewer` | UI quality, accessibility, visuals — posts inline PR comments | Bash (goal-git.sh only) |

## Delegation logic
The planner analyzes task complexity and tags each planned item:
- `@builder` — standard CRUD, UI, refactors, config, glue code, routine tests.
- `@builder-expert` — novel algorithms, concurrency, auth/security, perf
  hot paths, complex state machines, distributed coordination, DB migrations.

The orchestrator reads these tags and delegates to the correct agent.

When `concurrency` > 1, the planner groups independent tasks into concurrency
batches. The orchestrator creates git worktrees per task, runs builders in
parallel (capped at `concurrency`), then merges back sequentially.

## State (`state.json`)
Project-level only — pinned to the project root, never global.
```json
[
  {
    "goal": "the task objective",
    "branch": "goal/<slug> | feat/del-4123-<slug>",
    "base_branch": "main",
    "pr_number": null,
    "pr_url": "",
    "status": "in_progress|completed|failed",
    "repos": [
      {"path": "repo-name", "pr_number": null, "pr_url": ""}
    ]
  }
]
```
The last entry is the active goal. Read via `goal-git.sh state`.
Branch format: `goal/<slug>` for prompt/markdown; `{task_type}/{ticket}-{slug}` for jira
(e.g. `feat/del-4123-add-health-check`).

**Single-repo:** `repos` field absent or `[{path: ".", ...}]`. Top-level `pr_number`/`pr_url` still present for backward compat.

**Multi-repo:** `repos` array contains {path, pr_number, pr_url} per repo. Top-level `pr_number`/`pr_url` may be absent.

## Config (`.claude/goal-config.json`)
Project-level only — set via `/init-goal`.
```json
{
  "goal_source": "prompt|markdown|jira",
  "target_branch": "main",
  "platform": "github|gitlab",
  "concurrency": 1,
  "auto_merge": false,
  "repos": ["repo1", "repo2"],
  "figma_enabled": false,
  "figma_design_url": "https://www.figma.com/design/...",
  "figma_file_key": "AbCdEf",
  "figma_node_id": "1:2"
}
```
`concurrency` = 1 means sequential only. Values > 1 enable parallel builders
via git worktrees.

`repos` — array of repository paths (relative to PROJECT_ROOT). Absent in single-repo mode (defaults to `["."]`). Set by `/init-goal` repo selection step. Used by `goal-git.sh` to create branches/PRs in all selected repos.

Figma PAT is stored separately in `.claude/figma.env` (gitignored). MCP config
is in `.mcp.json`. Commands:
```bash
.claude/scripts/goal-git.sh figma setup <token>
.claude/scripts/goal-git.sh figma design set <url>
.claude/scripts/goal-git.sh figma status
.claude/scripts/run-claude.sh   # launch Claude Code with FIGMA_API_KEY loaded
```

## Model capabilities (`goal-models.json`)
Single source of truth for per-agent models and input modalities:

```json
{
  "visual-reviewer": {
    "model": "sonnet",
    "capabilities": {
      "multimodal": true,
      "modalities": { "input": ["text", "image"], "output": ["text"] }
    }
  }
}
```

Text-only agents set `"multimodal": false` and `"input": ["text"]`.
`init.sh` syncs `model` into agent `.md` frontmatter. Only `visual-reviewer` handles image input.

## Git Helper (`.claude/scripts/goal-git.sh`)
```bash
.claude/scripts/goal-git.sh start <goal> [ticket] [task_type]  # create branch (jira: task_type/ticket-slug)
.claude/scripts/goal-git.sh continue [id]    # resume active or switch goal (/goal --continue [id] [instruction])
.claude/scripts/goal-git.sh list             # list all goals
.claude/scripts/goal-git.sh state            # print active goal JSON
.claude/scripts/goal-git.sh stage <file>...   # stage specific files
.claude/scripts/goal-git.sh commit [msg]     # commit staged changes
.claude/scripts/goal-git.sh push             # push branch to origin
.claude/scripts/goal-git.sh pr               # create or update PR
.claude/scripts/goal-git.sh pending          # exit 0 if no unresolved threads
.claude/scripts/goal-git.sh threads          # list review threads as JSON
.claude/scripts/goal-git.sh comment <path> <line> <body>  # post inline comment
.claude/scripts/goal-git.sh resolve <thread-id>  # resolve thread
.claude/scripts/goal-git.sh merge            # merge PR/MR (when auto_merge enabled)
.claude/scripts/goal-git.sh state complete   # mark goal completed
.claude/scripts/goal-git.sh analyze          # npx gitnexus analyze && rtk gain
.claude/scripts/goal-git.sh status           # working tree status
.claude/scripts/goal-git.sh restore <file>   # restore files to HEAD
.claude/scripts/goal-git.sh diff             # diff against base branch
.claude/scripts/goal-git.sh config get       # print goal config
.claude/scripts/goal-git.sh worktree add <slug>    # create isolated worktree
.claude/scripts/goal-git.sh worktree merge <slug>  # merge into goal branch
.claude/scripts/goal-git.sh worktree list          # list worktrees
.claude/scripts/goal-git.sh worktree remove <slug>  # discard worktree
```
