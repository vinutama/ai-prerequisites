---
description: >-
  Initialize goal configuration for this project. Asks about goal source,
  target branch, git platform, and concurrency. Usage: /init-goal
agent: orchestrator
subtask: true
---

Read the project README and AGENTS.md to understand conventions first.

This command configures the goal workflow for this project. Ask the user the following questions one at a time and wait for each answer:

1. **Goal source** — Where will goals come from?
   - `jira` — Jira ticket key passed as argument (e.g. `/goal PROJ-123`)
   - `markdown` — Path to a `.md` file passed as argument (e.g. `/goal docs/feature.md`)
   - `prompt` — Free-text objective passed as argument (e.g. `/goal Add health check endpoint`)

   **If the user selects `jira`:** before continuing, verify Atlassian MCP is connected:
   - Attempt a lightweight Jira MCP call (e.g. `jira_get_user_profile` or list available MCP tools for Atlassian).
   - If unavailable, do NOT save `jira` yet. Guide the user to connect the Atlassian MCP server in their project-level `opencode.json` under `mcp`, then re-run `/init-goal`. Offer to use `prompt` or `markdown` instead for now.
   - If available, confirm Jira connectivity and proceed.

2. **Target branch** — What is the base/target branch for this project? (e.g. `main`, `develop`, `master`)

3. **Git platform** — Which git forge does this project use?
   - `github` — uses `gh` CLI
   - `gitlab` — uses `glab` CLI

4. **Concurrent subagents** — Should independent tasks run concurrently using git worktrees?
   - `no` — sequential execution only (concurrency = 1)
   - `yes` — ask how many subagents max (e.g. 2, 3, 4). Store as `concurrency` integer.

After collecting all answers, persist the configuration by running:
```bash
.opencode/scripts/goal-git.sh config set <goal_source> <target_branch> <platform> <concurrency>
```
Use `1` for concurrency when the user chose sequential only.

Confirm the saved config by running `.opencode/scripts/goal-git.sh config get` and display the result to the user.

Then run `.opencode/scripts/goal-git.sh selfcheck` to verify the platform CLI is available and authenticated.

Tell the user they can now run `/goal <objective>` to start a goal.

Only use `.opencode/scripts/goal-git.sh` for all git and state operations — never run `git`, `gh`, or `glab` directly.
