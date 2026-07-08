---
description: >-
  Set a goal and loop until the PR has zero unresolved review threads.
  Usage: /goal <your objective>
agent: orchestrator
subtask: true
---

Read the project README and AGENTS.md to understand conventions first.

Goal: $ARGUMENTS

Follow the orchestrator workflow:
1. Run `.opencode/scripts/goal-git.sh start "$ARGUMENTS"` to set up the branch.
2. Plan → Build → Analyze → Review → Loop until done.
3. Report the final PR URL.

Only use `.opencode/scripts/goal-git.sh` for all git operations.

Tip: use '/goal list' to see all goals, '/goal continue [id]' to resume a previous one.
