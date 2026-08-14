---
description: >-
  Initialize goal configuration for this project. Asks about goal source,
  target branch, git platform, concurrency, optional Figma design lookup,
  and auto-merge. Usage: /init-goal
agent: orchestrator
context: fork
---

Read the project README and CLAUDE.md to understand conventions first.

This command configures the goal workflow for this project. Ask the user the following questions one at a time and wait for each answer:

1. **Goal source** — Where will goals come from?
   - `jira` — Jira ticket key passed as argument (e.g. `/goal PROJ-123`)
   - `markdown` — Path to a `.md` file passed as argument (e.g. `/goal docs/feature.md`)
   - `prompt` — Free-text objective passed as argument (e.g. `/goal Add health check endpoint`)

   **If the user selects `jira`:** before continuing, verify Atlassian MCP is connected:
   - Attempt a lightweight Jira MCP call (e.g. `jira_get_user_profile` or list available MCP tools for Atlassian).
   - If unavailable, do NOT save `jira` yet. Guide the user to connect the Atlassian MCP server in their project-level `.mcp.json` under `mcpServers`, then re-run `/init-goal`. Offer to use `prompt` or `markdown` instead for now.
   - If available, confirm Jira connectivity and proceed.

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
     jq --argjson repos '["repo1","repo2"]' '.repos = $repos' .claude/goal-config.json > .claude/goal-config.json.tmp && mv .claude/goal-config.json.tmp .claude/goal-config.json
     ```

     Confirm: `jq '.repos' .claude/goal-config.json`

5. **Concurrent subagents** — Should independent tasks run concurrently using git worktrees?
   - `no` — sequential execution only (concurrency = 1)
   - `yes` — ask how many subagents max (e.g. 2, 3, 4). Store as `concurrency` integer.

6. **Figma design lookup** — Connect Figma to look up preferred designs during UI goals?
   - `no` — skip (default)
   - `yes` — continue to 6b and 6c below

   **6b (only if yes):** Figma Personal Access Token
   - Guide: Figma → Settings → Security → Personal access tokens
   - Warn: token is stored in `.claude/figma.env` (project-level, gitignored)
   - Run: `.claude/scripts/goal-git.sh figma setup "<token>"`
   - Optionally verify after sourcing env: `set -a && source .claude/figma.env && set +a && claude mcp list`
   - If verification fails, warn but continue

   **6c (only if yes, after token saved):** Default Figma design link
   - Ask: *"Which Figma design should agents use as the preferred reference for this project?"*
   - Accept full Figma URL (design file, legacy file link, or frame via `node-id`)
   - Example: `https://www.figma.com/design/FILE_KEY/Project-Name?node-id=1-2`
   - Run: `.claude/scripts/goal-git.sh figma design set "<url>"`
   - Confirm parsed `figma_file_key` and optional `figma_node_id` from `figma status`

7. **Auto-merge** — After review is clean (zero unresolved threads), merge the PR/MR into the target branch automatically?
   - `no` — leave PR open; user merges manually (**default**)
   - `yes` — after LGTM + `pending` exit 0, orchestrator runs `goal-git.sh merge`
     - On merge conflict: **stop**, report conflict files; do **not** invent conflict resolutions. User or a follow-up `/goal --continue` with builders can fix.

After collecting answers for questions 1–7 (including 6b/6c when Figma is enabled), persist core config:
```bash
.claude/scripts/goal-git.sh config set <goal_source> <target_branch> <platform> <concurrency> <auto_merge>
```
Use `1` for concurrency when the user chose sequential only.
Use `false` for `auto_merge` when the user chose manual merge (default).
Use `true` when the user chose auto-merge.

If Figma was enabled (question 5 = yes), run `figma setup` and `figma design set` **after** `config set` (order: config set → figma setup → figma design set).

Confirm the saved config:
```bash
.claude/scripts/goal-git.sh config get
.claude/scripts/goal-git.sh figma status
```

Then run `.claude/scripts/goal-git.sh selfcheck` to verify the platform CLI is available and authenticated.

Tell the user they can now run `/goal <objective>` to start a goal.
If Figma was configured, remind them to launch Claude Code with secrets loaded:
```bash
.claude/scripts/run-claude.sh
```
or `set -a && source .claude/figma.env && set +a && opencode`

Only use `.claude/scripts/goal-git.sh` for all git and state operations — never run `git`, `gh`, or `glab` directly.
