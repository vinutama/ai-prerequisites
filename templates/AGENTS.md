# AGENTS.md

## /goal workflow

This project uses **Goal Architecture Loop Engineering** — a persistent
workflow where AI agents drive a task from plan to merged PR, looping until
zero unresolved review threads remain.

### Setup
Run `/init-goal` once after `init.sh` to configure goal source, target branch,
git platform, concurrency, and optional Figma design lookup. Settings are stored in
`.opencode/goal-config.json` (project-level, gitignored as part of `.opencode/`).
Figma PAT is stored in `.opencode/figma.env` (gitignored as part of `.opencode/`).

Optionally run `/init-skills` to inject curated skills from
[agentic-awesome-skills](https://github.com/sickn33/agentic-awesome-skills)
into `.opencode/skills/` (project-level, filtered by category and risk), and
optionally install [ui-ux-pro-max](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill)
for UI/UX/frontend design intelligence.
Use the **recommended** preset to install skills that goal-loop agents look for.
Each agent loads related skills via OpenCode's native `skill` tool
(`skill({ name: "<skill-name>" })`) when they appear in `available_skills`.
Do not use `@mentions` or manually read `.opencode/skills/*/SKILL.md`.
If a skill is absent, the agent proceeds normally. Re-run `/init-skills` with
**recommended** (includes `development`) to install skills like `api-endpoint-builder`.

| Agent | Related skills (when installed) |
|---|---|
| `orchestrator` | `parallel-agents`, `multi-agent-patterns`, `verification-before-completion` |
| `planner` | `brainstorming`, `concise-planning`, `writing-plans`, `architecture`, `ui-ux-pro-max` |
| `builder` | `test-driven-development`, `lint-and-validate`, `error-handling-patterns`, `api-endpoint-builder`, `ui-ux-pro-max` |
| `builder-expert` | `systematic-debugging`, `test-driven-development`, `lint-and-validate`, `architecture`, `error-handling-patterns`, `api-endpoint-builder`, `ui-ux-pro-max` |
| `reviewer` | `code-review-excellence`, `verification-before-completion`, `api-security-best-practices`, `systematic-debugging` |
| `visual-reviewer` | `wcag-audit-patterns`, `frontend-design`, `webapp-testing`, `ui-ux-pro-max` |

### How to use
```
/init-goal                              # one-time project setup
/init-skills                            # optional: inject domain skills
/goal <your objective>                  # start a new goal
/goal --list                            # list all goals
/goal --continue [id] [new instruction]  # resume a goal; optional new instruction
```

Continue parsing (no quotes): first token is checked against existing goals via
`goal-git.sh list` — if it matches, that token is the goal id and the rest is
the new instruction; if not, the whole remainder is the instruction for the
active goal.

Goal source (configured via `/init-goal`):
- `prompt` — free-text objective (e.g. `/goal Add health check endpoint`); branch `goal/<slug>`
- `markdown` — reads a `.md` file as the goal (`/goal` uses `markdown_path` from config; `/goal docs/other.md` overrides); branch `goal/<slug>`
- `jira` — fetches a Jira ticket as the goal (`/goal` uses `jira_ticket` from config; `/goal OTHER-123` or `/goal bugfix DEL-4123` overrides) — requires Atlassian MCP; branch `{task_type}/{ticket}-{slug}` (e.g. `feat/del-4123-add-health-check`)

### Agent roles
| Agent | Role | Model |
|---|---|---|
| `orchestrator` | Manages the full loop | opencode-go/deepseek-v4-flash |
| `planner` | Architecture & plans — tags tasks @builder or @builder-expert | opencode-go/qwen3.7-max |
| `builder` | Routine execution (CRUD, UI, refactors, config, tests) | opencode-go/deepseek-v4-flash |
| `builder-expert` | Complex execution (algorithms, concurrency, security, perf) | opencode-go/kimi-k2.7-code |
| `reviewer` | Code review + inline PR comments | opencode-go/deepseek-v4-pro |
| `visual-reviewer` | UI/multimodal review + inline PR comments | opencode-go/mimo-v2.5-pro |

`goal-models.json` is the single source of truth for models and capabilities.
`init.sh` syncs `model` into each agent `.md` and generates `opencode.json`.

| Agent | Multimodal | Input modalities |
|---|---|---|
| `orchestrator` | no | text |
| `planner` | no | text |
| `builder` | no | text |
| `builder-expert` | no | text |
| `reviewer` | no | text |
| `visual-reviewer` | **yes** | text, image |

Only `visual-reviewer` handles screenshots and image attachments. The
orchestrator routes UI/visual review exclusively to that agent.

Model fallbacks are configured in project-level `opencode.json` (plugin +
per-agent `fallback_models`, generated from `.opencode/goal-models.json` by
`init.sh`) and `.opencode/opencode-model-fallback.json`. On rate limit or API
error, the `@razroo/opencode-model-fallback` plugin tries `fallback_models`
in order.

### Delegation
The planner tags every task:
- `@builder` — routine frontend/backend tasks.
- `@builder-expert` — novel algorithms, concurrency, auth/security,
  performance hot paths, complex state machines, distributed coordination.

The orchestrator delegates tasks to the tagged agent automatically.

When `concurrency` > 1 (set via `/init-goal`), the planner groups independent
tasks into concurrency batches. The orchestrator spawns parallel builders in
isolated git worktrees, then merges back into the goal branch.

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
- `.opencode/` — entire directory (agents, commands, skills, scripts, config, secrets). Gitignored — generated by `init.sh`, never committed.
- `AGENTS.md` — project conventions. Gitignored — generated by `init.sh`, never committed.
- `state.json` — goal history, branch, PR number. Gitignored, project root only.
- `opencode.json` — model fallback config + Figma MCP block. Project-level, generated by init.sh / init-goal.
- `.worktrees/` — isolated git worktrees for concurrent tasks (gitignored).
- `design-system/` — durable UI design reference from `ui-ux-pro-max` (`MASTER.md` + optional page overrides). **Not** gitignored — commit it with the project.

Both state and config files are pinned to the project root. Agents read state via
`.opencode/scripts/goal-git.sh state` — never from a global or cwd-relative path.

### Git workflow
NEVER invoke `git`, `gh`, or `glab` directly. ALL git and state operations
MUST go through `.opencode/scripts/goal-git.sh`:
```bash
.opencode/scripts/goal-git.sh start <goal> [ticket] [task_type]  # create branch (jira: task_type/ticket-slug)
.opencode/scripts/goal-git.sh continue [id]     # resume goal by branch/text
.opencode/scripts/goal-git.sh list              # list all goals
.opencode/scripts/goal-git.sh state            # print active goal JSON
.opencode/scripts/goal-git.sh stage <file>...  # stage specific files
.opencode/scripts/goal-git.sh commit [msg]       # commit staged changes
.opencode/scripts/goal-git.sh push               # push to origin
.opencode/scripts/goal-git.sh pr                 # create/update PR
.opencode/scripts/goal-git.sh pending            # check unresolved PR threads
.opencode/scripts/goal-git.sh threads            # list review threads as JSON
.opencode/scripts/goal-git.sh comment <path> <line> <body>  # post inline comment
.opencode/scripts/goal-git.sh resolve <thread-id>  # resolve a thread
.opencode/scripts/goal-git.sh merge              # merge PR/MR (when auto_merge enabled)
.opencode/scripts/goal-git.sh state complete     # mark goal completed
.opencode/scripts/goal-git.sh analyze            # npx gitnexus analyze && rtk gain
.opencode/scripts/goal-git.sh status             # working tree status
.opencode/scripts/goal-git.sh restore <file>...  # restore files to HEAD
.opencode/scripts/goal-git.sh diff               # diff against base branch
.opencode/scripts/goal-git.sh config get         # print goal config
.opencode/scripts/goal-git.sh worktree add <slug>    # create isolated worktree
.opencode/scripts/goal-git.sh worktree merge <slug>  # merge worktree into goal branch
.opencode/scripts/goal-git.sh worktree list          # list worktrees
.opencode/scripts/goal-git.sh worktree remove <slug> # discard worktree
.opencode/scripts/goal-git.sh figma setup <token>   # store PAT + enable Figma MCP
.opencode/scripts/goal-git.sh figma design set <url>  # set default design link
.opencode/scripts/goal-git.sh figma status          # show Figma integration status
.opencode/scripts/goal-git.sh figma disable         # disable Figma integration
```

Launch OpenCode with Figma secrets loaded:
```bash
.opencode/scripts/run-opencode.sh
```

### Review loop
- The **orchestrator never edits application source** — it only delegates `@builder` /
  `@builder-expert` to fix review findings.
- Builders must finish with a structured **Handoff** (`status`, `files_staged`, `analyze`, `notes`)
  after staging changes and passing `goal-git.sh analyze`. They do not commit or push.
- After a builder returns `FIXES_COMPLETE`, the orchestrator **immediately** resumes —
  no user input — with ANALYZE → commit → push → **mandatory re-delegate reviewers**.
  Never idle in REVIEW LOOP. Never skip re-review because `pending` is already 0.
- **Only reviewers resolve threads** — the orchestrator must never run
  `goal-git.sh resolve` or `goal-git.sh comment`. Reviewers resolve after confirming fixes.
- After code changes, run `.opencode/scripts/goal-git.sh analyze` (gitnexus + rtk gain).
  If it fails, STOP.
- Reviewers post inline comments on the PR/MR and **must** resolve fixed threads via
  `goal-git.sh resolve <thread-id>` (GraphQL id from `threads`, e.g. `PRRT_...`) with
  **exit 0** before claiming LGTM. **`outdated: true` is not resolved** — only `resolved: true`
  after a successful `resolve` call counts as clean. `goal-git.sh resolve` fails loudly on GraphQL/API errors.
  Each pass ends with a structured **Review report** (`threads_resolved`, `comments_posted`, `remaining_unresolved`, `verdict`).
- For UI/visual goals, the planner requires `@visual-reviewer`; the orchestrator always
  delegates visual review when the plan says so, Figma is enabled, or UI files changed.
- Run `.opencode/scripts/goal-git.sh pending` to check PR threads.
- Loop until exit 0 (zero unresolved threads).
- When `auto_merge` is `false` (default), report "Ready for manual merge" — never claim merged.
- When `auto_merge` is `true`, orchestrator runs `.opencode/scripts/goal-git.sh merge` after
  `pending` exit 0; on conflict, stop and report (do not auto-resolve conflicts).

### Jira goal source
When `goal_source` is `jira`, the Atlassian MCP must be connected in `opencode.json`.
`/init-goal` verifies connectivity before saving. `/goal` re-checks before fetching tickets.
Jira branches use `{task_type}/{lowercase-ticket}-{slug}` (task_type from issue type or
`/goal bugfix DEL-4123` override). Prompt/markdown branches use `goal/<slug>`.

### Figma design lookup (optional)
When enabled via `/init-goal`, agents use Figma MCP (`figma-developer-mcp`) with a PAT in
`.opencode/figma.env` and a default design link in `goal-config.json`:
`figma_design_url`, `figma_file_key`, `figma_node_id`. Planner, builder, and
visual-reviewer consult Figma for UI work. Use `run-opencode.sh` to load secrets.

### UI/UX Pro Max (optional)
Install via `/init-skills` question **UI/UX Pro Max**
(`npx -y ui-ux-pro-max-cli init --ai opencode` → `.opencode/skills/ui-ux-pro-max/`).
Requires `python3` for design-system generation (stdlib only; agents never install Python).

For UI/frontend goals when the skill is installed:
- **Figma enabled** — Figma is the visual source of truth. `ui-ux-pro-max` supplies
  stack guidelines, accessibility, and the pre-delivery checklist only.
- **No Figma** — planner generates/reuses `design-system/MASTER.md` via
  `python3 .opencode/skills/ui-ux-pro-max/scripts/search.py ... --design-system --persist`.
  Builders implement against that file (page overrides under `design-system/pages/` win).
- **visual-reviewer** always checks the skill's pre-delivery checklist / anti-patterns,
  and compares to Figma or `design-system/MASTER.md` as appropriate.
