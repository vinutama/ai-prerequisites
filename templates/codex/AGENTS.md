# AGENTS.md

## /goal workflow

This project uses **Goal Architecture Loop Engineering** — a persistent
workflow where AI agents drive a task from plan to merged PR, looping until
zero unresolved review threads remain.

### Setup
Run `/init-goal` once after `init.sh` to configure goal source, target branch,
git platform, concurrency, and optional Figma design lookup. Settings are stored in
`.codex/goal-config.json` (project-level, gitignored as part of `.codex/`).
Figma PAT is stored in `.codex/figma.env` (gitignored as part of `.codex/`).

Optionally run `/init-skills` to inject curated skills from
[agentic-awesome-skills](https://github.com/sickn33/agentic-awesome-skills)
into `.codex/skills/` (project-level, **exact list per agent** — not whole
categories), and optionally install
[ui-ux-pro-max](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill)
for UI/UX/frontend design intelligence.
Use the **recommended** preset to install only the skills each goal-loop agent
lists under Related skills (deduplicated union). Custom mode installs skills for
selected agents only.
Each agent loads related skills via `$skill-name` when installed.
Do not use `@mentions` or manually read `.codex/skills/*/SKILL.md`.
If a skill is absent, the agent proceeds normally. Re-run `/init-skills` with
**recommended** after updating agent Related skills lists.

| Agent | Related skills (when installed) |
|---|---|
| `orchestrator` | `parallel-agents`, `multi-agent-patterns`, `verification-before-completion` |
| `planner` | `brainstorming`, `concise-planning`, `writing-plans`, `architecture`, `ui-ux-pro-max` |
| `researcher` | `deep-research`, `research-prompt`, `documentation`, `documentation-templates`, `architecture`, `api-security-best-practices` |
| `builder` | `test-driven-development`, `lint-and-validate`, `error-handling-patterns`, `api-endpoint-builder`, `ui-ux-pro-max` |
| `builder-expert` | `systematic-debugging`, `test-driven-development`, `lint-and-validate`, `architecture`, `error-handling-patterns`, `api-endpoint-builder`, `ui-ux-pro-max` |
| `reviewer` | `code-review-excellence`, `verification-before-completion`, `api-security-best-practices`, `systematic-debugging` |
| `qa` | `e2e-testing-patterns`, `webapp-testing`, `browser-automation`, `test-driven-development`, `verification-before-completion`, `systematic-debugging`, `api-security-testing` |
| `visual-reviewer` | `wcag-audit-patterns`, `frontend-design`, `webapp-testing`, `ui-ux-pro-max` |

### How to use
```
/init-goal                              # one-time project setup
/init-skills                            # optional: inject domain skills
/goal <your objective>                  # start a new goal
/goal --list                            # list all goals
/goal --continue [id] [new instruction]  # resume a goal; optional new instruction
```

**Delegation:** `$goal` runs on MAIN (thin). After setup, MAIN spawns **one**
`@orchestrator` and waits. `.codex/config.toml` `[agents] max_depth` must be **3**
**and the project must be trusted** (`/status` shows effective `max_depth = 3`).
Without trust Codex ignores project config (default `max_depth = 1`): MAIN can
spawn the orchestrator, then V1 hides `spawn_agent` on that child. MAIN never
spawns `@planner` / `@builder` / `@reviewer` / `@qa`.

Continue parsing (no quotes): first token is checked against existing goals via
`goal-git.sh list` — if it matches, that token is the goal id and the rest is
the new instruction; if not, the whole remainder is the instruction for the
active goal.

Goal source (configured via `/init-goal`):
- `prompt` — free-text objective (e.g. `/goal Add health check endpoint`); branch `goal/<slug>`
- `markdown` — reads a `.md` file as the **goal draft** (`/goal` uses `markdown_path` from config; `/goal docs/other.md` overrides); branch `goal/<slug>`. `@planner` still runs unless classify is TRIVIAL.
- `jira` — fetches a Jira ticket as the goal (`/goal` uses `jira_ticket` from config; `/goal OTHER-123` or `/goal bugfix DEL-4123` overrides) — requires Atlassian MCP; branch `{task_type}/{TICKET}-{slug}` (e.g. `feat/DEL-4123-add-health-check`)
- `issues` — fetches open issues from a GitHub/GitLab issue list URL (`/goal --issues [url] [count]` or bare `/goal` when configured); **one branch + one PR per issue**; branch `{task_type}/{number}-{slug}`; planner orders by dependency and batches concurrent work (single-repo only; multi-repo processes one issue at a time)

### Agent roles
| Agent | Role |
|---|---|
| `orchestrator` | Thin state machine + harness; owns all worker spawns |
| `planner` | Plans — skipped on TRIVIAL |
| `researcher` | On-demand research (conditional) |
| `builder` | Routine execution |
| `builder-expert` | Escalation-only complex execution |
| `reviewer` | Diff-first code review (skippable TRIVIAL) |
| `qa` | Behavior QA (conditional) |
| `visual-reviewer` | UI/multimodal review (conditional) |

**Model catalog:** `.codex/goal-models.json` is the **only** place model IDs live
(`$routing` by complexity + role defaults + `$capabilities.vision_models`).
Edit that file per project to customize; do not hardcode models in AGENTS.md
or agent `.toml` files. Role tomls omit `model` so `spawn_agent` `$routing`
applies (Codex would lock a toml pin over the spawn override).

| Agent | Multimodal | Input modalities |
|---|---|---|
| `orchestrator` | no | text |
| `planner` | no | text |
| `researcher` | no | text |
| `builder` | no | text |
| `builder-expert` | no | text |
| `reviewer` | no | text |
| `qa` | no | text |
| `visual-reviewer` | **yes** | text, image |

Only `visual-reviewer` handles screenshots and image attachments. The
orchestrator routes UI/visual review exclusively to that agent.

### Harness, routes, and Definition of DONE
Active goals carry a `harness` object on `state.json` (phase, route,
`complexity`, `requirements` `{qa, visual, planner, reviewer, source}`, tasks,
gates, budget, metrics, retries, findings). Orchestrator drives it via
`goal-git.sh harness …`.

**Complexity (cheap, deterministic):**

```bash
.codex/scripts/goal-git.sh complexity classify "<goal text>"
# TRIVIAL | NORMAL | COMPLEX | ARCHITECTURAL
```

| Level | Planner | Flow |
|---|---|---|
| TRIVIAL | skipped | Builder → Verify → optional Review |
| NORMAL | yes | Plan → Build → Verify → Review |
| COMPLEX | yes (stronger `$routing`) | Plan → Research? → Build → Verify → Review |
| ARCHITECTURAL | yes (strongest `$routing`) | Plan → Research? → Build → Expert? → Verify → Review |

Models for each cell come from `.codex/goal-models.json` `$routing` — not this file.

**Spawn budgets** (defaults): `max_reviewer_runs = 1 + max_rework` (4 when
rework=3), `max_total_spawns` sized to match (~13). planner=1, researcher=1,
expert=1, qa=1, visual=1. Use `harness spawn <role>` before each spawn.
If a verified rework cannot start the closing re-review, raise the live cap:
`harness budget set max_reviewer_runs 4`. Do not mark REVIEW PASS without a
reviewer spawn. `review_max_iterations` defaults to **2** (local-mode finding cap).

Phases: `PLANNED` → `RESEARCHING?` → `BUILDING` → `ESCALATED?` → `VERIFYING` →
`REVIEWING?` → `QA?` → `VISUAL_REVIEW?` → `REWORK?` → `BUILDING` | `VERIFYING` →
`DONE` | `FAILED`.

`REWORK` may go to `BUILDING` (spawn the fix) or `VERIFYING` (fix builder already
done). Never `REWORK` → `REVIEWING` / `QA` / `DONE`.

Task states: `PENDING | RUNNING | DONE | BLOCKED | FAILED`.

**Routing**
- Classify first, then optionally `route detect` (baseline only).
- Planner `### Routing` is authoritative when Planner runs.
- Initialize:

```bash
.codex/scripts/goal-git.sh harness init \
  --route <route> --qa <bool> --visual <bool> \
  --complexity <LEVEL> --planner-required <bool> --reviewer-required <bool>
```

**Gates & evidence**
Always required: `IMPLEMENTATION`, `VERIFICATION`.
`PLAN` required unless `requirements.planner=false` (SKIPPED clears it).
`REVIEW` required unless `requirements.reviewer=false` (SKIPPED clears it).
Conditional: `QA` / `VISUAL` from requirements.

| Gate | PASS evidence |
|---|---|
| PLAN | Planner accepted + `discovery_context` persisted (`harness context put`) when planner required |
| IMPLEMENTATION | All `builder`/`builder-expert` tasks `DONE` (at least one); `discovery_context` when planner required |
| VERIFICATION | Only via `verify run` (manual PASS rejected) |
| REVIEW | `pending` (inline) or `review pending` (local) exit 0 |
| QA | `requirements.qa` + `qa_runs>=1` (`harness spawn qa`) + scenarios + `harness qa pending` exit 0 |
| VISUAL | `requirements.visual` + `visual_runs>=1` + observations + `harness visual pending` exit 0 |

Gate status: `NOT_RUN | PASS | FAIL | SKIPPED | UNKNOWN`.
`harness done` exits 0 only when every **required** gate is `PASS`
(SKIPPED does not clear a required gate). Retries hard-stop at limits.

**Progress timeline**
Agents emit typed milestones into `harness.events`:

```json
{"at":"2026-09-13T20:12:00+07:00","agent":"orchestrator","event":"planner_started","issue":25,"detail":""}
```

```bash
.codex/scripts/goal-git.sh harness event <agent> <event> [detail]   # append (best-effort)
.codex/scripts/goal-git.sh harness progress [-n 20] [--json]        # human timeline
```

Example `harness progress` output:

```
Issue #25
Phase: BUILDING

20:12:00  Orchestrator  Planner started
20:12:18  Planner       Completed
20:12:20  Builder       Started
20:14:03  Builder       Running targeted tests
```

Write-capable agents (`builder`, `builder-expert`, `reviewer`, `qa`,
`visual-reviewer`, `orchestrator`) call `harness event` themselves.
`planner` / `researcher` are read-only — they emit a `## Milestones` block
that the Orchestrator replays. Codex `SubagentStart`/`SubagentStop` hooks
also bracket every agent automatically (requires project `.codex/` trust and
`features.hooks = true`). A plain-text mirror lives at
`.codex/goal-progress.log` for `tail -f`.

While waiting in the parent UI, use Codex `/agent` to switch into a live
child thread — child reasoning is filtered from the parent stream by design.

**analyze ≠ verify**
- `analyze` — gitnexus + rtk gain (tooling/analysis)
- `verify run` — application correctness only (build/test/lint/typecheck/…)

**Context handoffs** (compact structured artifacts, not full transcripts):
`discovery_context`, `implementation_plan`, `research_report`, `staged_diff` /
builder `handoff`, `escalation_solution`, `review_report`, `qa_findings`,
`visual_review_report`.

**Visual reviewer**
Requires a vision-capable model. Resolve with
`models visual-reviewer --require-multimodal` (allowlist:
`$capabilities.vision_models` in `goal-models.json`). Never silently downgrade
to text-only. Prefer Playwright screenshots at 375 / 768 / 1024 / 1440 when the
app can start.

### Model routing
Codex does not use the OpenCode fallback plugin. Catalog = `.codex/goal-models.json`.

1. **Durable** — `init.sh` **strips** `model` / `model_reasoning_effort` from
   every Codex role `.toml` (including orchestrator). Codex **locks** a
   role-toml `model` over `spawn_agent` overrides, so pins would ignore JSON.
2. **Spawn-time (authoritative)** — resolve
   `models <role> --complexity <LEVEL>` (reads `$routing`) and pass
   `model` + `reasoning_effort` to `harness spawn` and `spawn_agent`.
   Confirm the child spawn label shows the JSON model — not MAIN's session model.

Customize per project by editing `.codex/goal-models.json` only.

On model-unavailable / rate-limit, call `models <role> --next <model>` and
re-spawn. For multimodal roles, `--next` only returns models in
`$capabilities.vision_models`. Before spawning `visual-reviewer`, run
`models visual-reviewer --require-multimodal` — never downgrade to text-only.

### Delegation
The planner tags every implementation task `@builder` and emits routing signals
(`route`, `research_required`, `qa_required`, `visual_required`, `high_risk_areas`).
`@builder-expert` is escalation-only — **after** `@builder` has attempted the
task **and** `verify run` FAILs (or reviewer records a serious architectural
defect). Do not wait for Builder to say BLOCKED. Domain labels and
`high_risk_areas` are not enough. Never a default or first implementer.

`@researcher` and `@qa` are on-demand / conditional. Verification is deterministic
via `goal-git.sh verify run` (not an LLM claim).

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
Platform is read from `.codex/goal-config.json` (set via `/init-goal`).
Fallback: auto-detect from origin remote URL. Override with
`GOAL_PLATFORM=github|gitlab`.

### State and config (project-level only)
- `.codex/` — entire directory (agents, commands, skills, scripts, config, secrets). Gitignored — generated by `init.sh`, never committed.
- `AGENTS.md` — project conventions. Gitignored — generated by `init.sh`, never committed.
- `state.json` — goal history, branch, PR number. Gitignored, project root only.
- `.codex/mcp.json` — model fallback config + Figma MCP block. Project-level, generated by init.sh / init-goal.
- `.worktrees/` — isolated git worktrees for concurrent tasks (gitignored).
- `.goal-review/` — local review findings per goal branch (gitignored; `review_mode: local`).
- `design-system/` — durable UI design reference from `ui-ux-pro-max` (`MASTER.md` + optional page overrides). **Not** gitignored — commit it with the project.

Both state and config files are pinned to the project root. Agents read state via
`.codex/scripts/goal-git.sh state` — never from a global or cwd-relative path.

### Git workflow
NEVER invoke `git`, `gh`, or `glab` directly. ALL git and state operations
MUST go through `.codex/scripts/goal-git.sh`:
```bash
.codex/scripts/goal-git.sh start <goal> [ticket] [task_type]  # create branch (jira: task_type/TICKET-slug)
.codex/scripts/goal-git.sh continue [id]     # resume goal by branch/text
.codex/scripts/goal-git.sh list              # list all goals
.codex/scripts/goal-git.sh state            # print active goal JSON
.codex/scripts/goal-git.sh stage <file>...  # stage specific files
.codex/scripts/goal-git.sh commit [msg]       # commit staged changes
.codex/scripts/goal-git.sh push               # push to origin
.codex/scripts/goal-git.sh pr                 # create/update PR
.codex/scripts/goal-git.sh pending            # check unresolved PR threads
.codex/scripts/goal-git.sh threads            # list review threads as JSON
.codex/scripts/goal-git.sh comment <path> <line> <body>  # post inline comment
.codex/scripts/goal-git.sh resolve <thread-id>  # resolve a thread
.codex/scripts/goal-git.sh review init [repo_path]  # init local findings file
.codex/scripts/goal-git.sh review add <path> <line> <severity> <body> [repo_path]
.codex/scripts/goal-git.sh review list [repo_path]
.codex/scripts/goal-git.sh review resolve <id> [repo_path]
.codex/scripts/goal-git.sh review pending [repo_path]  # local review gate
.codex/scripts/goal-git.sh review iterate [repo_path]
.codex/scripts/goal-git.sh merge              # merge PR/MR (when auto_merge enabled)
.codex/scripts/goal-git.sh state complete     # mark goal completed
.codex/scripts/goal-git.sh analyze            # npx gitnexus analyze && rtk gain (NOT a verify check)
.codex/scripts/goal-git.sh verify detect      # detect application verification commands
.codex/scripts/goal-git.sh verify run [--only a,b]  # deterministic verification (only writer of VERIFICATION PASS)
.codex/scripts/goal-git.sh route detect       # baseline classify backend|feature|frontend
.codex/scripts/goal-git.sh complexity classify "<text>" [--files a,b]
.codex/scripts/goal-git.sh harness init --route <r> [--qa true|false] [--visual true|false] \
  [--complexity LEVEL] [--planner-required bool] [--reviewer-required bool]
.codex/scripts/goal-git.sh harness phase <STATE>
.codex/scripts/goal-git.sh harness task add|set …   # states: PENDING|RUNNING|DONE|BLOCKED|FAILED
.codex/scripts/goal-git.sh harness gate <NAME> <STATUS> [reason]
.codex/scripts/goal-git.sh harness retry <rework|escalations|verify_retries>
.codex/scripts/goal-git.sh harness qa add|pending
.codex/scripts/goal-git.sh harness visual add|pending
.codex/scripts/goal-git.sh harness event <agent> <event> [detail]
.codex/scripts/goal-git.sh harness progress [-n N] [--json]
.codex/scripts/goal-git.sh harness spawn <role>    # budget gate
.codex/scripts/goal-git.sh harness metrics
.codex/scripts/goal-git.sh harness context put|get <name>
.codex/scripts/goal-git.sh harness status|done
.codex/scripts/goal-git.sh models                # print goal-models.json
.codex/scripts/goal-git.sh models <role>         # model + effort + fallbacks
.codex/scripts/goal-git.sh models <role> --complexity <LEVEL>
.codex/scripts/goal-git.sh models <role> --next <m>  # next fallback after <m>
.codex/scripts/goal-git.sh models <role> --require-multimodal [m]  # vision-capable resolve
.codex/scripts/goal-git.sh status             # working tree status
.codex/scripts/goal-git.sh restore <file>...  # restore files to HEAD
.codex/scripts/goal-git.sh diff               # diff against base branch
.codex/scripts/goal-git.sh config get         # print goal config
.codex/scripts/goal-git.sh worktree add <slug>    # create isolated worktree
.codex/scripts/goal-git.sh worktree merge <slug>  # merge worktree into goal branch
.codex/scripts/goal-git.sh worktree list          # list worktrees
.codex/scripts/goal-git.sh worktree remove <slug> # discard worktree
.codex/scripts/goal-git.sh issues list [url] [limit]  # list open issues from forge URL
.codex/scripts/goal-git.sh issues start <n> [--worktree]  # start issue goal (branch off base)
.codex/scripts/goal-git.sh issues queue  # current run's issue entries
.codex/scripts/goal-git.sh issues finish <n>  # complete issue + remove worktree
.codex/scripts/goal-git.sh figma setup <token>   # store PAT + enable Figma MCP
.codex/scripts/goal-git.sh figma design set <url>  # set default design link
.codex/scripts/goal-git.sh figma status          # show Figma integration status
.codex/scripts/goal-git.sh figma disable         # disable Figma integration
```

Launch Codex with Figma secrets loaded:
```bash
.codex/scripts/run-codex.sh
```

### Review loop
- The **orchestrator never edits application source** — it only delegates `@builder` /
  `@builder-expert` (escalation) to fix review findings.
- **Rework still spawns new agents** — each builder/reviewer leg is a fresh
  `harness spawn` (new Codex thread). Token savings come from **thin briefs**:
  `INITIAL` passes get discovery context; `REWORK` / `RE-REVIEW` passes get
  findings + diff + verify summary only.
- Builders must finish with a structured **Handoff** after staging changes.
  They do not commit or push. Orchestrator runs `verify run` as the authority
  for the VERIFICATION gate (not an LLM claim).
- After a builder returns `FIXES_COMPLETE`, the orchestrator **immediately** resumes —
  no user input — with VERIFY → commit → push → **mandatory re-delegate reviewers**.
  Never idle in REVIEW LOOP. Never skip re-review because `pending` or `review pending` is already 0.
- Rework / escalation / verify retries go through `harness retry`; exceeding limits
  fails the harness cleanly (`FAILED`).
- **Only reviewers resolve threads** — the orchestrator must never run
  `goal-git.sh resolve` or `goal-git.sh comment`.
- Conditional `@qa` and `@visual-reviewer` run only when harness
  `requirements.qa` / `requirements.visual` are true (Planner signals), not
  merely because the baseline route is `feature`/`frontend`.
- DONE requires `harness done` exit 0 before `state complete`.
- When `auto_merge` is `false` (default), report "Ready for manual merge" — never claim merged.
- When `auto_merge` is `true`, orchestrator runs `.codex/scripts/goal-git.sh merge` after
  clean review; on conflict, stop and report (do not auto-resolve conflicts).

### Jira goal source
When `goal_source` is `jira`, the Atlassian MCP must be connected in `.codex/mcp.json`.
`/init-goal` verifies connectivity before saving. `/goal` re-checks before fetching tickets.
Jira branches use `{task_type}/{TICKET}-{slug}` (task_type from issue type or
`/goal bugfix DEL-4123` override — `bugfix` aliases to `bug`). Prompt/markdown branches use `goal/<slug>`.

### Figma design lookup (optional)
When enabled via `/init-goal`, agents use Figma MCP (`figma-developer-mcp`) with a PAT in
`.codex/figma.env` and a default design link in `goal-config.json`:
`figma_design_url`, `figma_file_key`, `figma_node_id`. Planner, builder, and
visual-reviewer consult Figma for UI work. Use `run-codex.sh` to load secrets.

### UI/UX Pro Max (optional)
Install via `/init-skills` question **UI/UX Pro Max**
(`npx -y ui-ux-pro-max-cli init --ai opencode` → `.codex/skills/ui-ux-pro-max/`).
Requires `python3` for design-system generation (stdlib only; agents never install Python).

For UI/frontend goals when the skill is installed:
- **Figma enabled** — Figma is the visual source of truth. `ui-ux-pro-max` supplies
  stack guidelines, accessibility, and the pre-delivery checklist only.
- **No Figma** — planner generates/reuses `design-system/MASTER.md` via
  `python3 .codex/skills/ui-ux-pro-max/scripts/search.py ... --design-system --persist`.
  Builders implement against that file (page overrides under `design-system/pages/` win).
- **visual-reviewer** always checks the skill's pre-delivery checklist / anti-patterns,
  and compares to Figma or `design-system/MASTER.md` as appropriate.
