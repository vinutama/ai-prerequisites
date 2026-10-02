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
# optional: /create-issues plan.md
```

Cursor `/goal` runs the full loop on MAIN and delegates to project worker
subagents directly. There is no Cursor orchestrator subagent. Re-running
`init.sh --cursor` moves an old `.cursor/agents/orchestrator.md` to a
recoverable `.disabled` backup so Cursor no longer discovers it.

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
codex                 # trusted project; supported live delegation tools required
$init-goal
$goal Add a health-check endpoint
```

Codex entry points are skills: `$goal`, `$init-goal`, and `$init-skills`.
`$goal` runs on MAIN, which directly launches specialized workers and stays
active through delivery. Builders own application edits/staging; MAIN owns
workflow state, reconciliation, commits, gates, and PRs. There is no Codex
orchestrator child. Inspect the live launch schema for role/model/effort support;
do not blindly prescribe `agent_type` or `fork_turns`. Missing required capability
is a saved blocker; resume with `$goal --continue` after it is available.

#### Codex helper architecture

`goal-git.sh` is the sole operational entry for Git/forge, context, worktrees,
models, harness, delivery groups, and issue queues. Its sourceable modules are
internal implementation boundaries; agents do not invoke them directly.

| Module in `.codex/scripts/` | Responsibility |
|---|---|
| `goal-git.sh` | Public command dispatch and workflow/harness operations |
| `goal-context.sh` | Explicit assignment selectors, checkout/branch resolution, source snapshots, managed worktree sync and single state authority |
| `goal-delegation.sh` | Complexity/vision model routing, launch reservations, confirmation/failure/recovery and run accounting |
| `goal-evidence.sh` | Committed-SHA evidence invalidation, confirmed worker evidence and review verdict guards |
| `goal-delivery.sh` | Clean committed HEAD, nonempty diff, PR metadata/identity and current-SHA delivery/gate guards |
| `forge.sh` | Installed CLI capability probes, explicit forge identity, structured diagnostics and PR/MR reconciliation |
| `delivery-groups.sh` | Markdown group planning validation, dependencies and per-group lifecycle |

Helpers capability-probe installed CLI help/version and use supported flags.
Operational failures use structured diagnostics and `doctor --json`; do not
fall back to web search, browser, `--web`, or ad hoc `gh`/`glab`. Auth/permission
blockers stop with a suggested local command, without automatic browser login.
No automatic upgrades. Read-only Git/forge help/version inspection is allowed;
actual mutations use the helper. CLI docs lookup is maintenance outside active
operations. Unrelated implementation Researcher web and application browser
QA/visual checks remain available.

#### Codex context and source commands

Complete source intake before branch/worktree mutations. Prompt snapshots retain
the full objective, Markdown snapshots retain draft contents/path, and Jira
snapshots retain the full ticket fetched through actual MCP tools discovered at
runtime. `start ... --source-file <snapshot.json>` persists a JSON object with
`type`, `title`, `body`, `reference`, and `acceptance_criteria`. Planner treats Markdown
as draft input and produces a fresh plan. Issues retain the full issue body,
list URL override, run ID, and repository identity.

Every helper invocation carries explicit `GOAL_ID`, `GOAL_RUN_ID`, `GOAL_ISSUE`,
`GOAL_GROUP`, `GOAL_TASK`, and `GOAL_REPO`; empty means inapplicable, not shared
active selection. `context --json` resolves absolute `WORKFLOW_ROOT`, assigned
`TARGET_WORKTREE`, and local `GOAL_GIT`. Validate the returned assignment before
mutations and include all values in worker briefs and shell invocations.

```bash
# Carry this selector block in every shell invocation, including diagnostics.
export GOAL_ID="<id>" GOAL_RUN_ID="<run-id>"
export GOAL_ISSUE="<number-or-empty>" GOAL_GROUP="<group-id-or-empty>"
export GOAL_TASK="<task-id-or-empty>" GOAL_REPO="<repo-key-or-empty>"
export GOAL_ISSUE_REPO="<forge-repository-identity-or-empty>"
GOAL_GIT="<absolute installed helper>"
"$GOAL_GIT" help
"$GOAL_GIT" doctor --json
"$GOAL_GIT" context --json
```

Before a new goal exists, use empty assignment selectors for intake/help/doctor;
after start, use the persisted identity. `GOAL_REPO` is a configured repository
key, not the worktree path or forge identity. For issue assignments also carry
`GOAL_ISSUE_REPO` (forge URL/host/path), which disambiguates the issue identity
across repositories. Separate repositories retain per-repo checks and PRs;
groups use explicit `GOAL_GROUP`, never a shared active-group overlay.

| Command through `GOAL_GIT` | Contract |
|---|---|
| `start <title> [ticket] [task-type] --source-file <snapshot.json>` | Persist full source before branch/worktree mutation |
| `issues list <url> <count>` | Resolve selected forge list without losing explicit URL override |
| `issues start <n> --url <url> --worktree` | Start isolated issue with carried run/repo identity; one PR per issue |
| `worktree sync <absolute-path>` | Refresh managed instructions/configuration for an existing worktree |
| `models <role> --complexity <LEVEL> [--require-multimodal]` | Resolve model and effort from `.codex/goal-models.json` |
| `models <role> --complexity <LEVEL> --next <failed-model> [--require-multimodal]` | Preserve complexity and vision filtering on fallback |
| `harness spawn <role> <model> <effort> [--task tN]` | Reserve budget; return `reservation.id`, count no run yet |
| `harness spawn-confirm <reservation-id> <agent-id>` | Store actual launched child and count the run |
| `harness spawn-fail <reservation-id> <category> <reason>` | Release a definitively failed launch; preserve uncertain outcomes for reconciliation |
| `harness spawn-finish <agent-id> completed\|failed --closed` | Record returned result and confirmed thread closure, freeing its live slot |
| `harness recover-spawn` | Recover launch blockers only, restoring original phase |
| `pr --title <short-title> --body-file <path>` | Create/update single PR with mandatory metadata |
| `groups pr <id> --title <short-title> --body-file <path>` | Same metadata contract for a group PR |

Creation/resume automatically copies managed `.codex` scripts/agents/config,
`.agents` workflow skills, and ignored `AGENTS.md` into isolated worktrees.
`worktree sync` refreshes when needed; tracked/user-owned files are preserved.
State, locks, progress/review files, and worker artifacts are never copied.
The local helper resolves one root `state.json` authority. One Builder owns a
checkout at a time. Issue concurrency is one global worker cap; multi-repo issue
queues remain sequential. New Markdown auto/task goals have one typed branch,
worktree, harness, and PR per group; no aggregation PR. Legacy/single keeps one PR.

#### Codex harness gates

After workers finish, MAIN reconciles and commits staged implementation first,
then runs ANALYSIS and formal verification/review/QA/visual checks. All gate SHA
evidence points to the final committed clean HEAD. Rework invalidates evidence
and repeats commit → analysis → verify → fresh review/checks.

```text
intake → start → classify → plan? → research? → build → reconcile → commit
→ analyze → verify run → review? → QA? → visual? → harness done → delivery
```

| Gate | PASS evidence |
|---|---|
| PLAN | Accepted Planner plan unless TRIVIAL |
| IMPLEMENTATION | All assigned Builder/Expert tasks DONE and reconciled source committed |
| ANALYSIS | One `analyze` on the final committed clean HEAD |
| VERIFICATION | `verify run` only, bound to that SHA |
| REVIEW | Actual Reviewer LGTM for that SHA plus zero unresolved inline/local findings |
| QA | Confirmed QA run, complete recorded required scenarios and clean `harness qa pending` |
| VISUAL | Confirmed vision worker run, recorded viewport evidence and clean `harness visual pending` |

MAIN records returned Reviewer evidence with `harness context put review_verdict
<file|->`, JSON `{"verdict":"LGTM","sha":"<commit>"}`. Empty pending state alone
does not prove review occurred. `harness done` must exit 0 before completion.
IMPLEMENTATION/ANALYSIS/VERIFICATION always pass; PLAN/REVIEW are skipped only
on TRIVIAL, QA/VISUAL follow requirements. Planner routing is authoritative.
Unknown/NOT_RUN/PARTIAL checks never pass required gates. Expert requires a
prior Builder attempt plus real verify FAIL or serious architectural review defect.

Inline review publishes the committed verified diff before Reviewer. Local
review initializes idempotently before Reviewer, preserving findings, and
publishes after clean `harness done`. Both PR commands require a descriptive
single-line title ≤72 characters and body file containing a concise summary, usually 100–200 words, of
actual changes, checks/results, and source reference. Do not paste the full
requirements. The usual 100–200 word length is writing guidance, not a
helper-enforced minimum. Empty diff stops. Auto-merge is opt-in; stop on merge conflict.

#### Codex progress and worker lifecycle

MAIN inspects supported launch fields, reserves, launches, and confirms with
the actual agent ID. A failed launch is released through `spawn-fail`; an
uncertain outcome stays held until reconciled. Permit one targeted launch
retry, otherwise save/stop. Missing tools/auth/permissions/network/locks are
blockers, not permission to implement in MAIN or escalate to Expert.

Wait for every launched worker, record its result, close the thread with a
supported tool, then record closure through the helper's spawn lifecycle.
All workers return milestones/tasks/findings; MAIN records them serially.
Reviewer/Visual Reviewer supply evidence for resolution and MAIN applies the
requested actions. Workers never write harness or review state themselves.
Hooks may bracket lifecycle events, but cannot substitute for confirmed
launches or worker evidence. Watch recorded progress with `harness progress`,
`$goal --status`, or `.codex/goal-progress.log`; `/agent` opens a live child.
Avoid repeated status polling turns.

### Qoder
```bash
./init.sh --qoder /path/to/your/project
cd /path/to/your/project
qoder
/init-goal
/goal-arch Add a health-check endpoint
```

Qoder has a **built-in** `/goal` for session goal tracking. This scaffolding
uses **`/goal-arch`** for Goal Architecture Loop Engineering (avoids `/goal1`
rename conflicts).

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
| Cursor | `AGENTS.md`, `.cursor/` (agents, skills, scripts, harness) | `/goal`, `/create-issues` (skills with `disable-model-invocation`) |
| Claude Code | `CLAUDE.md`, `.claude/` (agents, commands, skills, scripts) | `/goal` |
| Codex | `AGENTS.md`, `.codex/` (TOML agents, scripts, `config.toml`), `.agents/skills/` | `$goal`, `$create-issues` |
| Qoder | `AGENTS.md`, `.qoder/` (agents, commands, skills, scripts), `.qoder/settings.json` (Figma MCP) | `/goal-arch` (not built-in `/goal`) |

Each tree includes core worker agents (`planner`, `builder`, `builder-expert`,
`reviewer`, `visual-reviewer`), `goal-git.sh`, `goal-models.json`, and the
`goal-loop` skill. OpenCode, Claude, and Qoder retain an `orchestrator`
agent; Cursor and Codex use MAIN.
**Codex** and **Cursor** also ship `researcher` and
`qa`, plus `harness` / `verify` / `route` / `groups` on their `goal-git.sh`.
The harness (not the coordinator's judgment) is the completion authority for
those targets.

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
| `/create-issues <path.md>` or `$create-issues <path.md>` | Create GitHub/GitLab issues from a markdown epic (one task checkbox under `### Tasks` per issue). OpenCode/Cursor: `/create-issues`. Codex: `$create-issues`. |

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
6. **Coordinator** — MAIN on Cursor/Codex (the orchestrator subagent on other targets) coordinates the loop across repos, tracks per-repo state, and reports all PR URLs at the end.

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
concurrency batches; the coordinator (MAIN on Cursor/Codex) merges results back into the goal branch.

Markdown goals default to **multi-PR delivery** (`markdown_pr_strategy=auto`):
the planner emits `delivery_groups`, and each group gets its own
`<task-type>/<group-id>-<slug>` branch, isolated worktree, harness, and PR/MR.
There is no final `goal/` aggregation PR. Use `single` to keep the legacy
one-PR Markdown behavior. Jira, issue-queue, and prompt goals are unchanged.

### Issue-driven goals (GitHub/GitLab)
When `goal_source` is `issues` (set via `/init-goal`), `/goal --issues` fetches
open issues from a configured or passed issue list URL, takes the first N
(`issue_limit`), and drives **each issue to its own branch and PR**. The planner
reorders by dependency and groups independent issues into concurrency batches;
the coordinator (MAIN on Cursor/Codex) starts every ready issue in the batch in
its own worktree, then runs its workers and verification separately. The
configured concurrency is a global worker cap, not a cap per issue. Each
issue keeps its own branch and PR/MR; issue branches are not merged together.
Parallel issue state lives in the root checkout, so `--continue` reuses the
existing worktrees and per-issue harnesses.
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
issues are fixed (`goal-git.sh resolve`). The coordinator (MAIN on Cursor/Codex)
delegates fixes to builders until `pending` returns exit 0. For Codex, workers
return findings/resolution evidence and MAIN applies review actions serially;
Reviewer LGTM must also match the committed SHA.

### Local review (`review_mode: local`)
Reviewers read `goal-git.sh diff` and record findings in gitignored `.goal-review/`
via `review add` / `review resolve`. No PR is created until review is clean; the
coordinator (MAIN on Cursor/Codex) commits locally during the fix loop, then `push` + `pr` in DONE.
Gate: `review pending` exit 0. On Codex/Cursor, `review iterate` is a counter only;
required re-review continues until findings are clean. Codex MAIN initializes
local review idempotently, records returned worker findings, and commits before
analysis/verify/review so all evidence uses the final clean committed HEAD.

### Auto-merge (opt-in)
When `auto_merge` is `true` (set via `/init-goal`), the coordinator runs
`goal-git.sh merge` after a clean review. Default is `false` — PR stays open for
manual merge. On merge conflict, agents stop and report; they do not invent resolutions.

### Model fallback (OpenCode only)
`init.sh --opencode` generates project-level `opencode.json` with the
`@razroo/opencode-model-fallback` plugin and per-agent `fallback_models`
(from `goal-models.json`). Plugin settings live in
`.opencode/opencode-model-fallback.json` (HTTP retries, `MessageAbortedError`
patterns, 30s TTFT). On rate limit, API error, or provider hang, agents
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
| `planner` | Architecture & plans | `opencode-go/qwen3.7-max` | `opus` | inherit | see `.codex/goal-models.json` `$routing` (read-only) | performance |
| `researcher` | On-demand research (Codex + Cursor) | — | — | inherit | see `goal-models.json` (read-only) | — |
| `builder` | Routine execution (CRUD, UI, refactors, config, tests) | `opencode-go/deepseek-v4-flash` | `sonnet` | inherit | see `goal-models.json` `$routing` | efficient |
| `builder-expert` | Complex execution (escalation-only on Codex/Cursor) | `opencode-go/kimi-k2.7-code` | `opus` | inherit | see `goal-models.json` | performance |
| `reviewer` | Code review + inline PR comments | `opencode-go/deepseek-v4-pro` | `opus` | inherit | see `goal-models.json` `$routing` | performance |
| `qa` | Behavior/business QA (Codex + Cursor, conditional) | — | — | inherit | see `goal-models.json` | — |
| Workflow coordinator | Goal-loop manager | `orchestrator` | `orchestrator` | MAIN (`/goal`) | MAIN (`$goal`) | `orchestrator` |
| `visual-reviewer` | UI/multimodal review + inline PR comments | `opencode-go/mimo-v2.5-pro` | `sonnet` | inherit | see `goal-models.json` + vision allowlist | inherit |

Every agent operates in `/ponytail full` mode.

### Delegation
On most platforms the planner tags every task `@builder` or `@builder-expert`.
**Codex** and **Cursor** tag implementation tasks `@builder` only; `@builder-expert`
is an escalation path, and `@researcher` / `@qa` are conditional. Verification
is deterministic (`goal-git.sh verify run`). `route detect` is only a baseline
classifier; after planning, the Planner's `### Routing` block (`route`,
`qa_required`, `visual_required`) is authoritative — QA is not implied by
"feature" and Visual is not implied by "frontend".

The coordinator delegates automatically (OpenCode `@mentions`, Claude/Qoder
orchestrator subagent, Cursor MAIN Agent/Task, Codex MAIN delegation using the supported live tool schema). Cursor models default to
`inherit`; optional per-role pins live in `.cursor/goal-models.json` (no spawn-time
model pick).

## Fidelity gaps

The loop is the same. These are the harness limits:

- **Codex has no slash commands.** Custom prompts were removed in CLI 0.117.0. Use `$goal`.
- **Codex delegation requires supported live tools.** Inspect role/model/effort capability in the actual launch schema; a version number alone does not prove support. Save/stop if required capability is missing and resume with `$goal --continue`. Never prescribe unsupported `agent_type`/`fork_turns` or implement in MAIN.
- **Codex `.codex/config.toml` loads only for trusted projects.** `goal-git.sh codex ensure-user-config` writes `trust_level = "trusted"` into `~/.codex/config.toml` without changing an existing global `max_depth`. The project config uses depth 1 because MAIN spawns workers directly. A newly trusted project may need a new Codex session before its config loads; resume with `$goal --continue`.
- **Codex and Cursor harness** (`harness` / `verify` / `route` / `complexity` / `groups` on `goal-git.sh`) plus `researcher` / `qa` ship on those targets; Claude/OpenCode/Qoder keep the prior six-agent loop. Gates are evidence-backed; `analyze` is not part of `verify`. Models: Codex uses `.codex/goal-models.json` `$routing` at spawn; Cursor defaults to `inherit` with optional per-role frontmatter pins (no spawn-time model override). TRIVIAL skips Planner; spawn budgets cap runaway loops.
- **Cursor delegation is one level.** `/goal` (MAIN) delegates directly to planner/builder/reviewer/etc. MAIN stays active through all gates. If Cursor withholds the Agent/Task tool, stop with a capability blocker and resume with `/goal --continue`; builders must never spawn subagents.
- **Codex visual-reviewer** hard-fails rather than downgrading to a text-only model. Vision allowlist is `$capabilities.vision_models` in `goal-models.json` (edit per project).
- **Codex and Cursor cannot machine-enforce `edit: deny`** on MAIN coordination, `reviewer`, or `visual-reviewer`. MAIN's no-source-edit rule is instruction-enforced. (Claude Code uses a `tools` allowlist; OpenCode uses `permission.edit: deny`.)
- **Goal-loop installs auto-approve tool prompts** (paths, bash, MCP) on all five targets so agents are not interrupted for permission dialogs. MAIN/planner/reviewer do not edit application source during Cursor/Codex goals.
- **Model fallback is OpenCode-only** for automatic plugin fallbacks; Codex uses `goal-git.sh models <role> --complexity <LEVEL> --next <failed-model>` at spawn time (vision-filtered for multimodal roles via `$capabilities.vision_models`).
- **Cursor and Codex have no `$ARGUMENTS` expansion.** Command skills read the text typed after `/goal` or `$goal` from the user message.
- **Installing `--cursor` and `--codex` together** surfaces the goal skills twice in Cursor, because Cursor also scans `.agents/skills/`.
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
- **Codex**: trusted project config, Python 3.11+ (or Python with `tomli`), and live delegation support for the required role/model/effort; inspect actual tool capabilities
- **Qoder**: `qoder` CLI
