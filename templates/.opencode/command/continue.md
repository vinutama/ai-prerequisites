---
description: >-
  Continue the current /goal on the same branch/PR with an extended or refined
  objective. Usage: /goal continue <additional objective>
agent: orchestrator
subtask: true
---

Read the project README and AGENTS.md to understand conventions first.

Goal (continued): $ARGUMENTS

This is a continuation of the existing goal. The branch and PR/MR are already
set up — do NOT create a new one.

Follow the orchestrator workflow, but skip SETUP's `start`:
1. Run `.opencode/scripts/goal-git.sh continue "$ARGUMENTS"` to update the goal.
2. Skip branch creation — you are already on the goal branch.
3. Plan → Build → Analyze → Review → Loop until done.
4. Report the final PR URL.

Only use `.opencode/scripts/goal-git.sh` for all git operations.
