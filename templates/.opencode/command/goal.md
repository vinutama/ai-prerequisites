---
description: >-
  Set, list, or continue goals. Usage: /goal <objective> | /goal --list | /goal --continue [id]
agent: orchestrator
subtask: true
---

Read the project README and AGENTS.md to understand conventions first.

Arguments: $ARGUMENTS

## Dispatch

Inspect `$ARGUMENTS` and follow the matching path:

### `/goal --list`
Run `.opencode/scripts/goal-git.sh list` and display the output. Stop.

### `/goal --continue [id]`
This continues an existing goal. Strip the `--continue` flag; the remainder is the optional identifier (branch name or goal text).
1. Run `.opencode/scripts/goal-git.sh continue "<remainder>"` to switch/activate the goal.
2. Skip branch creation — you are on the goal's branch.
3. Plan → Build → Analyze → Review → Loop until done.
4. Report the final PR URL.

### `/goal <objective>` (new goal)
1. Read goal source from `.opencode/scripts/goal-git.sh config get` (field `goal_source`). If no config exists, treat as `prompt`.
2. Resolve the goal text based on source:
   - `prompt` — use `$ARGUMENTS` directly as the goal.
   - `markdown` — treat `$ARGUMENTS` as a path to a `.md` file; read its contents as the goal.
   - `jira` — treat `$ARGUMENTS` as a Jira ticket key (e.g. `PROJ-123`); fetch via the Atlassian MCP `jira_get_issue` and use summary + description as the goal.
3. Run `.opencode/scripts/goal-git.sh start "<resolved goal>"` to set up the branch.
4. Plan → Build → Analyze → Review → Loop until done.
5. Report the final PR URL.

Only use `.opencode/scripts/goal-git.sh` for all git and state operations — never run `git`, `gh`, or `glab` directly.
