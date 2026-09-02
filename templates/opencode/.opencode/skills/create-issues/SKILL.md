---
name: create-issues
description: >-
  Create GitHub or GitLab issues from a markdown file — one issue per ## heading.
  Standalone utility outside the /goal workflow; uses create-issues.sh, not goal-git.sh.
---

# Create Issues from Markdown

Bulk-create GitHub or GitLab issues from a markdown file. **Unrelated to `/goal`** —
does not touch `state.json`, branches, or PRs.

## Markdown format

Preamble before the first `##` is ignored. Each `##` heading starts one issue.

```markdown
## Add health-check endpoint
Labels: enhancement, backend
Assignee: @me
Milestone: v1.2

Expose `GET /healthz` returning 200 with build SHA.

### Acceptance
- [ ] Returns 200

## Fix flaky auth test
Labels: bug
```

### Rules
- **Title** — text after `##` on the heading line.
- **Body** — everything below the heading until the next `##`. `###` and deeper headings stay in the body.
- **Metadata** — consecutive lines immediately after the heading (before any body line):
  - `Labels:` or `Label:` — comma-separated label names
  - `Assignee:` or `Assignees:` — comma-separated logins (`@me` works on GitHub)
  - `Milestone:` — milestone name
- Empty body is allowed.

## Script

All operations go through `.opencode/scripts/create-issues.sh`:

```bash
.opencode/scripts/create-issues.sh parse <file.md>
.opencode/scripts/create-issues.sh create <file.md> [--dry-run] [--repo owner/repo] [--platform github|gitlab]
.opencode/scripts/create-issues.sh create <file.md> --label extra --milestone v1.0
.opencode/scripts/create-issues.sh status
```

### Platform detection
Order: `--platform` flag → `GOAL_PLATFORM` env → `platform` in `.opencode/goal-config.json` → `origin` remote.

Requires `gh` (GitHub) or `glab` (GitLab), authenticated for the target repo.

### Duplicate guard
By default, issues whose title exactly matches an existing issue title are skipped.
Pass `--allow-duplicates` to disable.

## Workflow (for `/create-issues` command)

1. Load this skill: `skill({ name: "create-issues" })`
2. Resolve the markdown path from user arguments (error if missing).
3. Run `create-issues.sh parse <file>` and show a numbered preview (title, labels, milestone, body excerpt).
4. Run `create-issues.sh create <file> --dry-run` and show the commands.
5. Ask the user to confirm.
6. Run `create-issues.sh create <file>` (forward `--repo`, `--platform`, `--label`, `--milestone` from arguments when present).
7. Report created URLs and the summary line (`created` / `skipped` / `failed`).

Never invoke `git`, `gh`, or `glab` directly — always use `create-issues.sh`.
