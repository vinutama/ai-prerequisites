---
name: goal
description: >-
  Set, list, continue, or run issue queue. Usage: /goal <objective> | /goal --list | /goal --issues [url] [count] | /goal --continue [id] [new instruction]
disable-model-invocation: true
---

Read the project README and AGENTS.md to understand conventions first.

Arguments are the text the user typed after `/goal` in this message. Read them from the surrounding user message — there is no placeholder expansion.

## Dispatch

Inspect `the arguments from the user message` and follow the matching path:

### `/goal --list`
Run `.cursor/scripts/goal-git.sh list` and display the output.
If the state has `repos` with more than one entry, also show each repo path and its active branch from `state.json` (run `.cursor/scripts/goal-git.sh state | jq '.repos'`). Stop.

### `/goal --issues [url] [count]`
Fetch open issues from a GitHub/GitLab issue list URL and drive each to its own branch and PR.

1. Parse remainder after `--issues`: optional `url`, optional `count` (integer).
   - If `url` omitted → read `issue_list_url` from config.
   - If `count` omitted → read `issue_limit` from config (default `3`).
   - If `url` still missing, STOP and tell the user to run `/init-goal` or pass a URL.
2. Export a run id for this invocation:
   ```bash
   export GOAL_RUN_ID="run-$(date +%s)-$$"
   ```
3. Fetch issues:
   ```bash
   .cursor/scripts/goal-git.sh issues list "<url>" <count>
   ```
4. Delegate `@orchestrator` in **ISSUE QUEUE** mode (see orchestrator agent): planner queue pass → per-issue batches → one PR per issue.
   - Multi-repo: process **one issue at a time** (no concurrent issue worktrees).
   - Single-repo with `concurrency` > 1: planner may batch independent issues; orchestrator uses `issues start <n> --worktree` per issue in a batch.
5. Report **one PR URL per issue** when the run completes.

Also run this path when `goal_source` is `issues` and the user invokes bare `/goal` with no args (use configured `issue_list_url` and `issue_limit`), or `/goal <count>` where `<count>` is only a number.

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
   existing goals via `.cursor/scripts/goal-git.sh list` (branch or goal text match).
   - If it matches an existing goal → identifier = first token, instruction = remaining words (may be empty).
   - If it does NOT match → identifier = empty (active goal), instruction = whole remainder.
3. Run `.cursor/scripts/goal-git.sh continue "<identifier>"` (empty identifier = active goal).
4. **Issue run resume:** If `.cursor/scripts/goal-git.sh issues queue` returns a non-empty array with any entry where `status` is not `completed`, resume the **issue queue** for that `run_id`:
   - Set `export GOAL_RUN_ID=<run_id from queue entries>`.
   - For each incomplete entry in the queue (in batch order), set `GOAL_ISSUE=<issue.number>` on every `goal-git.sh` call and run PLAN → BUILD → ANALYZE → COMMIT → PR → REVIEW LOOP until `issues finish <n>`.
   - Skip branch creation for entries that already have a branch in state.
5. Otherwise skip branch creation — you are on the goal's branch.
6. If an instruction was parsed, pass it to `@planner` as the primary objective for
   this pass (does NOT overwrite the stored goal in `state.json`).
7. **Plan → Build → Analyze → Review → Loop until done**:
   - Check if state.json has `repos` with more than one entry.
   - **Multi-repo mode (repos > 1)**:
     - For each repo in `state.json` repos: cd into the repo and checkout the branch listed in state.
     - Read full `state.json` (`.cursor/scripts/goal-git.sh state`).
     - Delegate `@planner` ONCE with the full state (all repos, active goal) — planner produces repo-tagged tasks in dependency batches.
     - For each batch: for each task with a `[repo-name]` tag, `cd <repo-path> && delegate @builder` (or `@builder-expert`) scoped to that repo. Builders in same batch can run in parallel.
     - After batch: for each repo that had changes, cd into repo, commit, push, create/update PR, delegate `@reviewer` scoped to that repo, run review loop.
   - **Single-repo mode (repos ≤ 1 or no repos field)**: follow existing Plan → Build → Analyze → Review → Loop flow unchanged.
8. Report ALL PR URLs across all repos (multi-repo) or the single PR URL.

### `/goal <objective>` (new goal)
1. Determine `goal_source`: check if `the arguments from the user message` begins with `--source <type>`. If so, pop both tokens and validate `<type>` is one of `jira|markdown|prompt|issues`. Use it as the effective `goal_source` for this invocation (overrides config). Otherwise read from `.cursor/scripts/goal-git.sh config get` (field `goal_source`). If no config exists, treat as `prompt`.
   If `effective_source` is `issues` and `the arguments from the user message` is empty or a single integer, follow **`/goal --issues`** above (optional count token only).
   Prefix all `goal-git.sh start` calls with `GOAL_SOURCE_OVERRIDE=<effective_source>` (e.g. `GOAL_SOURCE_OVERRIDE=prompt .cursor/scripts/goal-git.sh start ...`).
2. Resolve the goal text based on source:
   - `prompt` — use `the arguments from the user message` directly as the goal. If empty, STOP and ask the user for an objective.
   - `markdown` — resolve the file path:
     - If `the arguments from the user message` is non-empty → use it as the path.
     - If `the arguments from the user message` is empty → read `markdown_path` from config; if missing, STOP and tell the user to run `/init-goal` or pass a path (e.g. `/goal docs/feature.md`).
     - Read the file contents as the goal. If the file does not exist, STOP and report the path.
   - `jira` — resolve ticket + task_type, then fetch the issue:
     1. Parse `the arguments from the user message` tokens:
        - Optional leading `task_type` override if the first token is one of:
          `feat`, `bug`, `chore`, `refactor`, `docs`, `test`, `perf`
          (`bugfix` and `fix` alias to `bug`; e.g. `/goal bugfix DEL-4123`).
        - Next token (or first token if no type override) is the ticket key.
        - If no ticket token → read `jira_ticket` from config.
        - If still missing, STOP and tell the user to run `/init-goal` or pass a ticket (e.g. `/goal PROJ-123`).
     2. Verify Atlassian MCP is available (attempt `jira_get_issue` or check MCP tools).
        - If unavailable, STOP and guide the user to connect the Atlassian MCP server in `.cursor/mcp.json`, then retry.
     3. Fetch via `jira_get_issue` and use summary + description as the goal text.
     4. If `task_type` was not overridden from args, map Jira issue type (case-insensitive):
        - Bug, Defect → `bug`
        - Story, Task, Feature, New Feature, Epic, Improvement, Enhancement → `feat`
        - Documentation → `docs`
        - Test → `test`
        - Spike, Tech Debt, Chore → `chore`
        - Performance → `perf`
        - anything else / missing → `feat`
     5. Call start with ticket and type:
        ```bash
        GOAL_SOURCE_OVERRIDE=<effective_source> .cursor/scripts/goal-git.sh start "<resolved goal>" "<ticket-key>" "<task_type>"
        ```
        Branch becomes `{task_type}/{TICKET}-{slug}` (e.g. `feat/DEL-4123-add-health-check`).
3. For `prompt` and `markdown` only: run `GOAL_SOURCE_OVERRIDE=<effective_source> .cursor/scripts/goal-git.sh start "<resolved goal>"` (branch `goal/<slug>`).
   For `jira`, start was already called in step 2.
4. **Multi-repo orchestration (when repos > 1 in config)**:
   - Read repos from `state.json` (`.cursor/scripts/goal-git.sh state | jq '.repos'`).
   - Delegate `@planner` ONCE (planner sees ALL repos, produces repo-tagged tasks in dependency batches).
     - Pass the full `state.json` active goal and all repo paths to the planner.
     - Tell planner to suffix each task with the target repo path, e.g. `[tije-smpob-api]`.
   - For each batch in the plan:
     - For each task in the batch:
       - If the task has a repo tag `[repo-name]`, cd into that repo before delegating builder.
       - Run: `cd <repo-path> && delegate @builder` (or `@builder-expert`) scoped to that repo.
       - Builders in the same batch can run in parallel across repos (if concurrency allows).
     - After the batch completes:
       - For each repo that had changes in this batch:
         - cd into repo, commit, push, create/update PR.
         - Delegate `@reviewer` scoped to that repo (pass repo_path).
         - Run review loop on that repo until clean.
   - DONE: report ALL PR URLs across all repos.
5. **Single-repo mode**: If state.json has `repos` with 1 entry or no `repos` field, follow existing single-repo flow (Plan → Build → Analyze → Review → Loop) unchanged.
6. Report the final PR URL.

Only use `.cursor/scripts/goal-git.sh` for all git and state operations — never run `git`, `gh`, or `glab` directly.
