---
description: >-
  Set, list, or continue goals. Usage: /goal <objective> | /goal --list | /goal --continue [id] [new instruction]
agent: orchestrator
subtask: true
---

Read the project README and AGENTS.md to understand conventions first.

Arguments: $ARGUMENTS

## Dispatch

Inspect `$ARGUMENTS` and follow the matching path:

### `/goal --list`
Run `.opencode/scripts/goal-git.sh list` and display the output. Stop.

### `/goal --continue [id] [new instruction]`
This continues an existing goal. No quotes required.

**Examples:**
```
/goal --continue                                    # resume active goal, no new instruction
/goal --continue add-health                         # switch to goal "add-health", no new instruction
/goal --continue add-health fix the healthcheck API # switch to "add-health" AND apply new instruction
/goal --continue fix the healthcheck API            # active goal + new instruction
```

**Parse the remainder** (after stripping `--continue`):
1. If remainder is empty → identifier = active goal, instruction = none.
2. Otherwise take the first token as a candidate identifier. Check it against
   existing goals via `.opencode/scripts/goal-git.sh list` (branch or goal text match).
   - If it matches an existing goal → identifier = first token, instruction = remaining words (may be empty).
   - If it does NOT match → identifier = empty (active goal), instruction = whole remainder.
3. Run `.opencode/scripts/goal-git.sh continue "<identifier>"` (empty identifier = active goal).
4. Skip branch creation — you are on the goal's branch.
5. If an instruction was parsed, pass it to `@planner` as the primary objective for
   this pass (does NOT overwrite the stored goal in `state.json`).
6. Plan → Build → Analyze → Review → Loop until done.
7. Report the final PR URL.

### `/goal <objective>` (new goal)
1. Read goal source from `.opencode/scripts/goal-git.sh config get` (field `goal_source`). If no config exists, treat as `prompt`.
2. Resolve the goal text based on source:
   - `prompt` — use `$ARGUMENTS` directly as the goal. If empty, STOP and ask the user for an objective.
   - `markdown` — resolve the file path:
     - If `$ARGUMENTS` is non-empty → use it as the path.
     - If `$ARGUMENTS` is empty → read `markdown_path` from config; if missing, STOP and tell the user to run `/init-goal` or pass a path (e.g. `/goal docs/feature.md`).
     - Read the file contents as the goal. If the file does not exist, STOP and report the path.
   - `jira` — resolve ticket + task_type, then fetch the issue:
     1. Parse `$ARGUMENTS` tokens:
        - Optional leading `task_type` override if the first token is one of:
          `feat`, `bugfix`, `chore`, `refactor`, `docs`, `test`, `perf`
          (e.g. `/goal bugfix DEL-4123`).
        - Next token (or first token if no type override) is the ticket key.
        - If no ticket token → read `jira_ticket` from config.
        - If still missing, STOP and tell the user to run `/init-goal` or pass a ticket (e.g. `/goal PROJ-123`).
     2. Verify Atlassian MCP is available (attempt `jira_get_issue` or check MCP tools).
        - If unavailable, STOP and guide the user to connect the Atlassian MCP server in `opencode.json`, then retry.
     3. Fetch via `jira_get_issue` and use summary + description as the goal text.
     4. If `task_type` was not overridden from args, map Jira issue type (case-insensitive):
        - Bug, Defect → `bugfix`
        - Story, Task, Feature, New Feature, Epic, Improvement, Enhancement → `feat`
        - Documentation → `docs`
        - Test → `test`
        - Spike, Tech Debt, Chore → `chore`
        - Performance → `perf`
        - anything else / missing → `feat`
     5. Call start with ticket and type:
        ```bash
        .opencode/scripts/goal-git.sh start "<resolved goal>" "<ticket-key>" "<task_type>"
        ```
        Branch becomes `{task_type}/{lowercase-ticket}-{slug}` (e.g. `feat/del-4123-add-health-check`).
3. For `prompt` and `markdown` only: run `.opencode/scripts/goal-git.sh start "<resolved goal>"` (branch `goal/<slug>`).
   For `jira`, start was already called in step 2.
4. Plan → Build → Analyze → Review → Loop until done.
5. Report the final PR URL.

Only use `.opencode/scripts/goal-git.sh` for all git and state operations — never run `git`, `gh`, or `glab` directly.
