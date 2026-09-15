---
name: goal
description: >-
  Set, list, continue, status, or run issue queue. Usage: $goal <objective> | $goal --list | $goal --status | $goal --issues [url] [count] | $goal --continue [id] [new instruction]
---

Read the project README and AGENTS.md to understand conventions first.

## Role split (non-negotiable)

You are the **MAIN** agent loading `$goal`. Stay thin.

| You (MAIN) | `@orchestrator` |
|---|---|
| Parse `$goal` args | Own the full goal loop |
| `list` / `status` / resolve goal text | `harness *`, `models *`, `verify` |
| `start` / `continue` / `issues list` + `issues start` (setup only) | Spawn **all** workers (`@planner`, `@builder`, …) |
| Spawn **one** `@orchestrator`, wait, report | Phases, gates, QA/Visual, PR, `harness done` |

**Never** from MAIN: spawn `@planner` / `@researcher` / `@builder` / `@builder-expert` / `@reviewer` / `@qa` / `@visual-reviewer`; drive harness gates; edit application source; run the plan→build→review loop yourself.

```
User → MAIN ($goal) → @orchestrator → workers
```

### Handoff (after setup)

```bash
LEVEL=$(.codex/scripts/goal-git.sh complexity classify "<goal or issue text>" | jq -r .complexity)
if ! read -r MODEL EFFORT _ <<< "$(.codex/scripts/goal-git.sh models orchestrator --complexity "$LEVEL")"; then
  # Failed lookup is a catalog/script problem — NOT max_depth / spawn capability.
  STOP. Show the command error. Tell the user to copy the latest
  `.codex/scripts/goal-git.sh` (or re-run `./init.sh --codex`) so `models`
  accepts `$routing.orchestrator`. Do **not** ask for `/status` or a new
  session for this error.
fi
# TAB from models: model · reasoning_effort · fallbacks (from .codex/goal-models.json)
```

Spawn `@orchestrator` once with that `model` + `reasoning_effort`. Pass a short brief:

* mode: `single` | `continue` | `issue` | `issue-queue`
* active goal text (and continuation instruction if any)
* multi-repo: yes/no (from `state.json` `repos`)
* for issues: `GOAL_RUN_ID`, issue number(s), queue vs single
* complexity: `$LEVEL`
* reminder: orchestrator owns harness + **all** worker `spawn_agent` calls

```text
spawn_agent({
  agent_type: "orchestrator",
  model: "<MODEL from models orchestrator --complexity>",
  reasoning_effort: "<EFFORT from models>",
  fork_turns: "none"
})
```

If `models orchestrator --complexity` prints `Unknown role`:
the project's `goal-git.sh` is stale (it only treats **top-level** JSON keys as
roles, and ignores `$routing.orchestrator`). Copy
`templates/codex/.codex/scripts/goal-git.sh` into the project (or
`./init.sh --codex`), then `$goal --continue`. **Do not** treat this as
`max_depth` / `/status`.

`.codex/config.toml` must have `[agents] max_depth = 3` **and the project must be
trusted** so Codex loads that file. Untrusted projects keep the default
`max_depth = 1`: MAIN can spawn `@orchestrator`, then Codex V1 **hides**
`spawn_agent` on that child. **Do not spawn workers yourself.**

If `@orchestrator` returns `SPAWN_CAPABILITY_MISSING`:
1. `grep -n max_depth .codex/config.toml` — if it is already `3`, do **not**
   edit the file and do **not** say “start a new session” as the only fix.
   That is the stuck loop.
2. STOP. Tell the user to run `/status` in this Codex session and confirm
   **effective** `agents.max_depth` is 3. If it is not 3, **trust this
   project** (approve project config when Codex prompts), then a **new**
   session, then `$goal --continue`.
3. Spawn `@orchestrator` only after they confirm `/status` shows 3.

Model IDs come only from `.codex/goal-models.json` — never hardcode them in this skill.

Wait until `@orchestrator` finishes. Then report PR URL(s) / blockers from its result (or `harness status` / `harness done`). Do **not** call `harness spawn orchestrator` (worker budget is for child agents only).

Only use `.codex/scripts/goal-git.sh` for git/state — never raw `git` / `gh` / `glab`.

## Dispatch

Inspect the text after `$goal` and follow the matching path:

### `$goal --list`
Run `.codex/scripts/goal-git.sh list` and display the output.
If `repos` has more than one entry, also show each repo path and branch
(`.codex/scripts/goal-git.sh state | jq '.repos'`). **Stop** (no orchestrator).

### `$goal --status`
```bash
.codex/scripts/goal-git.sh harness progress
.codex/scripts/goal-git.sh harness status | jq '{phase, route, requirements, gates, tasks}'
```
Mention `.codex/goal-progress.log` and Codex `/agent` for live children. **Stop**.

### `$goal --issues [url] [count]`
1. Parse remainder: optional `url`, optional `count`.
   - Missing `url` → `issue_list_url` from config.
   - Missing `count` → `issue_limit` from config (default `3`).
   - Still no URL → STOP; tell user to run `$init-goal` or pass a URL.
2. `export GOAL_RUN_ID="run-$(date +%s)-$$"`
3. `.codex/scripts/goal-git.sh issues list "<url>" <count>`
4. Dispatch:
   - **Exactly 1 issue:** `issues start <number>`, then **Handoff** with mode `issue`.
   - **2+ issues:** **Handoff** with mode `issue-queue` (orchestrator: queue plan, batches, one PR per issue; multi-repo = one issue at a time).
5. When orchestrator returns, report **one PR URL per issue**.

Also use this path when `goal_source` is `issues` and the user runs bare `$goal` / `$goal <count>`.

### `$goal --continue [id] [new instruction]`
Examples:
```
$goal --continue
$goal --continue add-health
$goal --continue add-health fix the healthcheck API
$goal --continue fix the healthcheck API
```

Parse remainder after `--continue`:
1. Empty → active goal, no instruction.
2. Else first token vs `.codex/scripts/goal-git.sh list` (branch/goal match).
   - Match → identifier = token, instruction = rest.
   - No match → identifier empty (active), instruction = whole remainder.
3. `.codex/scripts/goal-git.sh continue "<identifier>"`
4. If `issues queue` has incomplete entries → `export GOAL_RUN_ID=<run_id>`, **Handoff** mode `issue-queue` (resume). Do not run the loop yourself.
5. Else **Handoff** mode `continue`, include any continuation instruction for Planner.
6. Report PR URL(s) when orchestrator finishes.

### `$goal <objective>` (new goal)
1. `goal_source`: optional leading `--source <jira|markdown|prompt|issues>`; else config; else `prompt`.
   If source is `issues` and remainder empty/integer → **`$goal --issues`**.
   Prefix starts with `GOAL_SOURCE_OVERRIDE=<effective_source>`.
2. Resolve goal text:
   - `prompt` — remainder (empty → ask user and STOP).
   - `markdown` — path from remainder or `markdown_path`; read file (missing → STOP).
   - `jira` — optional task_type token, then ticket (or `jira_ticket`); require Atlassian MCP; `jira_get_issue`; map type; then:
     ```bash
     GOAL_SOURCE_OVERRIDE=<effective_source> .codex/scripts/goal-git.sh start "<goal>" "<ticket>" "<task_type>"
     ```
3. For `prompt` / `markdown`: `GOAL_SOURCE_OVERRIDE=… .codex/scripts/goal-git.sh start "<resolved goal>"`.
4. **Handoff** mode `single` (orchestrator classifies, plans, builds, verifies, reviews, QA/Visual, DONE).
5. Report the final PR URL(s).
