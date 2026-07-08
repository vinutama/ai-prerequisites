---
description: >-
  Continue a goal on its existing branch/PR. Usage: /goal continue [goal-or-branch]
agent: orchestrator
subtask: true
---

Read the project README and AGENTS.md to understand conventions first.

Goal (continued): $ARGUMENTS

This continues an existing goal. If an identifier is provided (branch name or
goal text), the goal is switched first. If no identifier, the active (last) goal
is continued. The branch/PR are NOT re-created.

Follow the orchestrator workflow, but skip SETUP's `start`:
1. Run `.opencode/scripts/goal-git.sh continue "$ARGUMENTS"` to switch/activate the goal.
2. Skip branch creation — you are on the goal's branch.
3. Plan → Build → Analyze → Review → Loop until done.
4. Report the final PR URL.

Only use `.opencode/scripts/goal-git.sh` for all git operations.
