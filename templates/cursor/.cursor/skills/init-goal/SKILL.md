---
name: init-goal
description: >-
  Initialize goal configuration for this project. Asks about goal source,
  target branch, git platform, concurrency, optional Figma design lookup,
  and auto-merge. Usage: /init-goal
disable-model-invocation: true
---

Read the project README and AGENTS.md to understand conventions first.

This command configures the goal workflow for this project. Ask the user the following questions one at a time and wait for each answer:

1. **Goal source** — Where will goals come from?
   - `jira` — Jira ticket key passed as argument (e.g. `/goal PROJ-123`)
   - `markdown` — Path to a `.md` file passed as argument (e.g. `/goal docs/feature.md`)
   - `prompt` — Free-text objective passed as argument (e.g. `/goal Add health check endpoint`)
   - `issues` — Open issues from a GitHub/GitLab issue list URL (e.g. `/goal --issues` or bare `/goal` when configured)

   **If the user selects `jira`:** before continuing, verify Atlassian MCP is connected:
   - Attempt a lightweight Jira MCP call (e.g. `jira_get_user_profile` or list available MCP tools for Atlassian).
   - If unavailable, do NOT save `jira` yet. Guide the user to connect the Atlassian MCP server in their project-level `.cursor/mcp.json` under `mcpServers`, then re-run `/init-goal`. Offer to use `prompt` or `markdown` instead for now.
   - If available, confirm Jira connectivity and proceed.

   **If the user selects `issues`:** before continuing, verify the forge CLI can read the list:
   - Ask for the issue list URL (e.g. `https://github.com/org/repo/issues` or `https://gitlab.com/group/project/-/issues`)
   - Ask how many issues per run (default `3`) — store as `issue_limit`
   - Run: `.cursor/scripts/goal-git.sh issues list "<url>" 1`
   - If the command fails, do NOT save `issues` yet. Guide the user to authenticate `gh` or `glab`, confirm the URL, then re-run `/init-goal`. Offer `prompt` or `markdown` instead for now.
   - If successful, remember `issue_list_url` and `issue_limit` for persistence after `config set` (step below).
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
     jq --argjson repos '["repo1","repo2"]' '.repos = $repos' .cursor/goal-config.json > .cursor/goal-config.json.tmp && mv .cursor/goal-config.json.tmp .cursor/goal-config.json
     ```

     Confirm: `jq '.repos' .cursor/goal-config.json`

5. **Concurrent subagents** — Should independent tasks run concurrently using git worktrees?
   - `no` — sequential execution only (concurrency = 1)
   - `yes` — ask how many subagents max (e.g. 2, 3, 4). Store as `concurrency` integer.

6. **Figma design lookup** — Connect Figma to look up preferred designs during UI goals?
   - `no` — skip (default)
   - `yes` — continue to 6b and 6c below

   **6b (only if yes):** Figma Personal Access Token
   - Guide: Figma → Settings → Security → Personal access tokens
   - Warn: token is stored in `.cursor/figma.env` (project-level, gitignored)
   - Run: `.cursor/scripts/goal-git.sh figma setup "<token>"`
   - Optionally verify after sourcing env: `set -a && source .cursor/figma.env && set +a && cursor-agent mcp list`
   - If verification fails, warn but continue

   **6c (only if yes, after token saved):** Default Figma design link
   - Ask: *"Which Figma design should agents use as the preferred reference for this project?"*
   - Accept full Figma URL (design file, legacy file link, or frame via `node-id`)
   - Example: `https://www.figma.com/design/FILE_KEY/Project-Name?node-id=1-2`
   - Run: `.cursor/scripts/goal-git.sh figma design set "<url>"`
   - Confirm parsed `figma_file_key` and optional `figma_node_id` from `figma status`

7. **Auto-merge** — After review is clean (zero unresolved threads or local findings), merge the PR/MR into the target branch automatically?
   - `no` — leave PR open; user merges manually (**default**)
   - `yes` — after LGTM + clean review gate, orchestrator runs `goal-git.sh merge`
     - On merge conflict: **stop**, report conflict files; do **not** invent conflict resolutions. User or a follow-up `/goal --continue` with builders can fix.

8. **Review mode** — How should reviewers report findings?
   - `inline` (**default**) — create PR first; reviewers post inline comments on GitHub/GitLab and resolve threads (`goal-git.sh pending` gates the loop).
   - `local` — reviewers read the diff locally, record findings via `goal-git.sh review add`, orchestrator delegates builders immediately. **No PR until review is clean** (push + `pr` happen only in DONE).
     - If `local`: ask max review iterations before stopping (default `5`) — store as `review_max_iterations`.

After collecting answers for questions 1–8 (including 6b/6c when Figma is enabled), persist core config:
```bash
.cursor/scripts/goal-git.sh config set <goal_source> <target_branch> <platform> <concurrency> <auto_merge> <review_mode> <review_max_iterations>
```
Use `1` for concurrency when the user chose sequential only.
Use `false` for `auto_merge` when the user chose manual merge (default).
Use `true` when the user chose auto-merge.
Use `inline` for `review_mode` when the user chose inline PR comments (default).
Use `local` when the user chose local review.
Use `5` for `review_max_iterations` when local mode and the user did not specify a cap.

If `issues` was selected, after `config set` persist issue settings:
```bash
jq --arg url "<issue_list_url>" --argjson limit <issue_limit> \
  '.issue_list_url = $url | .issue_limit = $limit' \
  .cursor/goal-config.json > .cursor/goal-config.json.tmp && mv .cursor/goal-config.json.tmp .cursor/goal-config.json
```

If Figma was enabled (question 6 = yes), run `figma setup` and `figma design set` **after** `config set` (and after issue jq when applicable).

Confirm the saved config:
```bash
.cursor/scripts/goal-git.sh config get
.cursor/scripts/goal-git.sh figma status
```

Then run `.cursor/scripts/goal-git.sh selfcheck` to verify the platform CLI is available and authenticated.

Tell the user they can now run `/goal <objective>` or `/goal --issues [count]` to start a goal (when `goal_source` is `issues`, bare `/goal` uses configured URL and limit).
If Figma was configured, remind them to launch Cursor with secrets loaded:
```bash
.cursor/scripts/run-cursor.sh
```
or `set -a && source .cursor/figma.env && set +a && opencode`

Only use `.cursor/scripts/goal-git.sh` for all git and state operations — never run `git`, `gh`, or `glab` directly.
