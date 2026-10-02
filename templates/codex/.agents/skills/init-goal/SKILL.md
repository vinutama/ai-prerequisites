---
name: init-goal
description: >-
  Initialize goal configuration for this project. Asks about goal source,
  target branch, git platform, concurrency, optional Figma design lookup,
  and auto-merge. Usage: $init-goal
---

Read the project README and AGENTS.md to understand conventions first.
Use the installed absolute `GOAL_GIT` as the sole operational entry. Read
`goal-git.sh help` and `doctor --json` before setup. Set explicit empty
`GOAL_ID`, `GOAL_RUN_ID`, `GOAL_ISSUE`, `GOAL_GROUP`, `GOAL_TASK`, and `GOAL_REPO`
for setup without an assignment, carrying them in every shell invocation.
For an existing assignment, preserve its selectors and resolve `context --json`.
Use returned absolute paths. Setup does not start a goal or mutate branches.

On CLI failure, read structured helper diagnostics and `doctor --json`. The
helper probes installed CLI capabilities. Read-only help/version inspection
is allowed; actual Git/forge operations use the helper. Authentication or
permission blockers stop with the suggested local command; do not launch
browser login automatically. No web/browser/`--web`/ad hoc forge fallback,
CLI documentation lookup during active operations, or automatic upgrades.
CLI/helper repair belongs to maintenance outside this setup operation.

This command configures the goal workflow for this project. Ask the user the following questions one at a time and wait for each answer:

1. **Goal source** — Where will goals come from?
   - `jira` — Jira ticket key passed as argument (e.g. `$goal PROJ-123`)
   - `markdown` — Path to a `.md` file passed as argument (e.g. `$goal docs/feature.md`)
   - `prompt` — Free-text objective passed as argument (e.g. `$goal Add health check endpoint`)
   - `issues` — Open issues from a GitHub/GitLab issue list URL (e.g. `$goal --issues` or bare `$goal` when configured)

   **If the user selects `jira`:** before continuing, verify Atlassian MCP is connected:
   - Discover the actual connected Jira/Atlassian MCP tools at runtime, inspect their supported schemas, and use an available read-only connectivity call. Never prescribe a guessed tool name.
   - If unavailable, do NOT save `jira` yet. Guide the user to connect the Atlassian MCP server in their project-level `.codex/config.toml` under `[mcp_servers]`, then re-run `$init-goal`. Offer to use `prompt` or `markdown` instead for now.
   - If available, confirm Jira connectivity and proceed. At goal intake, read the full ticket and acceptance criteria into a `--source-file` JSON object with `type,title,body,reference,acceptance_criteria` before any branch mutation; a summary alone is insufficient.

   **If the user selects `issues`:** before continuing, verify the forge CLI can read the list:
   - Ask for the issue list URL (e.g. `https://github.com/org/repo/issues` or `https://gitlab.com/group/project/-/issues`)
   - Ask how many issues per run (default `3`) — store as `issue_limit`
   - Run: `.codex/scripts/goal-git.sh issues list "<url>" 1`
   - If it fails, do NOT save `issues` yet. Run `doctor --json` and report the structured diagnostic. Unsupported flags are maintenance blockers, not authentication failures. For auth/permission blockers, stop with the suggested local command; do not perform login or try a browser/web fallback.
   - If successful, remember `issue_list_url` and `issue_limit` for persistence after `config set` (step below). Every later start uses `issues start <n> --url <resolved-url> [--worktree]`, retaining run/repo identity and explicit URL overrides.
   - Note: concurrent issue worktrees are **single-repo only**. Multi-repo + issues runs one issue at a time across repos.

2. **Target branch** — What is the base/target branch for this project? (e.g. `main`, `develop`, `master`)

3. **Git platform** — Which git forge does this project use?
   - `github` — uses `gh` CLI
   - `gitlab` — uses `glab` CLI

4. **Repo selection** — (multi-repo only) Which repositories should this goal workflow cover?

   Detect mode:
   ```bash
   if [ -d .git ]; then
     echo "single-repo (no repo selection needed)"
   else
     echo "multi-repo"
     for d in */; do [ -d "$d.git" ] && echo "  $(echo $d | sed 's|/||')"; done
   fi
   ```

   - **Single-repo:** If `.git` exists in the current directory, skip this step. No `repos` field needed in config.
   - **Multi-repo:** Show the detected repos above. Ask the user:

     *"Which repos should goals cover? (all / comma-separated names)"*

     - `all` → include all detected repos
     - Specific names → e.g. `tije-smpob-api, tije-worker-v1`

     Store selected repos in config:
     ```bash
     jq --argjson repos '["repo1","repo2"]' '.repos = $repos' .codex/goal-config.json > .codex/goal-config.json.tmp && mv .codex/goal-config.json.tmp .codex/goal-config.json
     ```

     Confirm: `jq '.repos' .codex/goal-config.json`

5. **Concurrent subagents** — Should independent tasks or issues run concurrently using git worktrees?
   - `no` — sequential execution only (concurrency = 1)
   - `yes` — ask how many active workers max across the whole goal (e.g. 2, 3, 4). Store as `concurrency` integer.

6. **Figma design lookup** — Connect Figma to look up preferred designs during UI goals?
   - `no` — skip (default)
   - `yes` — continue to 6b and 6c below

   **6b (only if yes):** Figma Personal Access Token
   - Guide: Figma → Settings → Security → Personal access tokens
   - Warn: token is stored in `.codex/figma.env` (project-level, gitignored)
   - Run: `.codex/scripts/goal-git.sh figma setup "<token>"`
   - Optionally verify after sourcing env: `set -a && source .codex/figma.env && set +a && codex mcp`
   - If verification fails, warn but continue

   **6c (only if yes, after token saved):** Default Figma design link
   - Ask: *"Which Figma design should agents use as the preferred reference for this project?"*
   - Accept full Figma URL (design file, legacy file link, or frame via `node-id`)
   - Example: `https://www.figma.com/design/FILE_KEY/Project-Name?node-id=1-2`
   - Run: `.codex/scripts/goal-git.sh figma design set "<url>"`
   - Confirm parsed `figma_file_key` and optional `figma_node_id` from `figma status`

7. **Auto-merge** — After review is clean (zero unresolved threads or local findings), merge the PR/MR into the target branch automatically?
   - `no` — leave PR open; user merges manually (**default**)
   - `yes` — after LGTM + clean review gate, MAIN runs `goal-git.sh merge`
     - On merge conflict: **stop**, report conflict files; do **not** invent conflict resolutions. User or a follow-up `$goal --continue` with builders can fix.

8. **Review mode** — How should reviewers report findings?
   - `inline` (**default**) — MAIN publishes the committed verified diff before Reviewer, then records returned findings and evidenced resolution requests serially through helper commands.
   - `local` — MAIN runs idempotent `review init` before Reviewer, preserving findings on rework. Reviewers return findings/resolution evidence for MAIN to record, and MAIN delegates fixes. **No PR until `harness done` is clean**.
     Review loops until `review pending` exits 0. Do **not** ask for a max iteration cap.

9. **Markdown PR strategy** (only when goal source is `markdown`) — How should a Markdown goal be delivered?
   - `auto` (**default for new Markdown goals**) — planner groups tasks into small independently testable PRs/MRs. Each group gets `<task-type>/<group-id>-<slug>`, an isolated worktree, and its own PR. No final `goal/` aggregation PR.
   - `single` — preserve one branch + one PR (legacy).
   - `task` — one PR per independently mergeable planner task.
   After `config set`, persist:
   ```bash
   jq '.markdown_pr_strategy = "auto" | .max_tasks_per_pr = 3 | .max_files_per_pr = 25 | .max_parallel_prs = 2' \
     .codex/goal-config.json > .codex/goal-config.json.tmp && mv .codex/goal-config.json.tmp .codex/goal-config.json
   ```
   Limits are planning signals; do not force unsafe splits. Existing in-progress Markdown goals keep their original one-PR schema until they complete.

After collecting answers for questions 1–9 (including 6b/6c when Figma is enabled), persist core config:
```bash
.codex/scripts/goal-git.sh config set <goal_source> <target_branch> <platform> <concurrency> <auto_merge> <review_mode> 0
```
Use `1` for concurrency when the user chose sequential only.
Use `false` for `auto_merge` when the user chose manual merge (default).
Use `true` when the user chose auto-merge.
Use `inline` for `review_mode` when the user chose inline PR comments (default).
Use `local` when the user chose local review.
Always pass `0` for `review_max_iterations` (unlimited — loop until pending is clean).

If `issues` was selected, after `config set` persist issue settings:
```bash
jq --arg url "<issue_list_url>" --argjson limit <issue_limit> \
  '.issue_list_url = $url | .issue_limit = $limit' \
  .codex/goal-config.json > .codex/goal-config.json.tmp && mv .codex/goal-config.json.tmp .codex/goal-config.json
```

If Figma was enabled (question 6 = yes), run `figma setup` and `figma design set` **after** `config set` (and after issue jq when applicable).

Confirm the saved config:
```bash
.codex/scripts/goal-git.sh config get
.codex/scripts/goal-git.sh figma status
```

Then run `.codex/scripts/goal-git.sh doctor --json` for installed capabilities,
assignment/configuration diagnostics, and platform authentication. Stop on
blockers with the suggested local command.

Explain that source intake precedes branch/worktree mutations: prompt stores
the full objective, Markdown stores draft contents, and Jira stores the full
fetched ticket. Snapshot JSON is `{type,title,body,reference,acceptance_criteria}`.
MAIN commits implementation before ANALYSIS, formal verify, review, QA, and
visual checks; all evidence points to final committed clean HEAD. Workers
return all milestones/tasks/findings for MAIN to record. PR commands require
`--title <short-title> --body-file <path>` (also `groups pr <id>`), with a
single-line title ≤72 characters and a concise description (usually 100–200 words) of actual
changes/checks/reference; empty diff stops.

Tell the user they can now run `$goal <objective>` or `$goal --issues [count]` to start a goal (when `goal_source` is `issues`, bare `$goal` uses configured URL and limit).
If Figma was configured, remind them to launch Codex with secrets loaded:
```bash
.codex/scripts/run-codex.sh
```
or load `.codex/figma.env` in the shell before launching `codex`.

Use `goal-git.sh` for all workflow/Git/forge operations. Read-only CLI help/version is allowed; mutations always use the helper. Optional project configuration edits above are setup configuration, never direct workflow state writes.
