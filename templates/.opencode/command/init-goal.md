---
description: >-
  Initialize goal configuration for this project. Asks about goal source,
  target branch, and git platform. Usage: /init-goal
agent: orchestrator
subtask: true
---

Read the project README and AGENTS.md to understand conventions first.

This command configures the goal workflow for this project. Ask the user the following questions one at a time and wait for each answer:

1. **Goal source** — Where will goals come from?
   - `jira` — Jira ticket key passed as argument (e.g. `/goal PROJ-123`)
   - `markdown` — Path to a `.md` file passed as argument (e.g. `/goal docs/feature.md`)
   - `prompt` — Free-text objective passed as argument (e.g. `/goal Add health check endpoint`)

2. **Target branch** — What is the base/target branch for this project? (e.g. `main`, `develop`, `master`)

3. **Git platform** — Which git forge does this project use?
   - `github` — uses `gh` CLI
   - `gitlab` — uses `glab` CLI

After collecting all three answers, persist the configuration by running:
```bash
.opencode/scripts/goal-git.sh config set <goal_source> <target_branch> <platform>
```

Confirm the saved config by running `.opencode/scripts/goal-git.sh config get` and display the result to the user.

Then run `.opencode/scripts/goal-git.sh selfcheck` to verify the platform CLI is available and authenticated.

Tell the user they can now run `/goal <objective>` to start a goal.

Only use `.opencode/scripts/goal-git.sh` for all git and state operations — never run `git`, `gh`, or `glab` directly.
