---
description: >-
  Create GitHub/GitLab issues from a markdown epic file (one issue per task under ### Tasks). Usage: /create-issues <path.md> [--dry-run] [--repo owner/repo] [--platform github|gitlab]
subtask: true
---

Read the project README and AGENTS.md to understand conventions first.

Load the create-issues skill before doing anything else:
```
skill({ name: "create-issues" })
```

Arguments: $ARGUMENTS

## Resolve path and flags

1. Parse `$ARGUMENTS` for optional flags:
   - `--dry-run` — preview commands only, do not create issues
   - `--repo <owner/repo>` — target repository override
   - `--platform github|gitlab` — platform override
   - `--label <name>` — extra label on every issue (may repeat)
   - `--milestone <name>` — default milestone when a block omits one
   - `--allow-duplicates` — skip duplicate-title check

2. The first non-flag token is the markdown file path. If absent, stop with an error:
   ```
   Usage: /create-issues <path.md> [--dry-run] [--repo owner/repo] [--platform github|gitlab]
   ```

3. Resolve the path relative to the project root if not absolute. Verify the file exists.

## Workflow

1. Run `.opencode/scripts/create-issues.sh status` (with `--repo` / `--platform` when provided) and note platform/auth.

2. Run `.opencode/scripts/create-issues.sh parse "<path>"` and display a numbered preview:
   - phase-prefixed title (e.g. `[Phase 1] Remove the stray empty Users/ directory`)
   - inherited labels, assignees, milestone (from the parent `##` epic)
   - first ~3 lines of body (Context / Phase / Acceptance excerpt)

3. State the total task count (number of `- [ ]` items under `### Tasks`, not Acceptance items).

4. Build the create command with the same flags the user passed. Always run dry-run first unless the user passed `--dry-run` and explicitly asked to skip preview:
   ```bash
   .opencode/scripts/create-issues.sh create "<path>" [flags] --dry-run
   ```
   Show each printed command.

5. If the user included `--dry-run` in `$ARGUMENTS`, stop after the dry-run output.

6. Otherwise ask: **Create N task issue(s) on {platform}?** Wait for confirmation.

7. On confirm, run create without `--dry-run`:
   ```bash
   .opencode/scripts/create-issues.sh create "<path>" [flags]
   ```

8. Report each `created <url>` line and the final summary. If any failed, list them and suggest `--allow-duplicates` or fixing auth/repo.

Only use `.opencode/scripts/create-issues.sh` for issue creation — never run `gh`, `glab`, or `git` directly.
