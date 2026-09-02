---
name: create-issues
description: >-
  Create GitHub or GitLab issues from a markdown epic file — one issue per task
  checkbox under ### Tasks. Standalone utility outside the /goal workflow.
---

# Create Issues from Markdown

Bulk-create GitHub or GitLab issues from a markdown epic file. **Unrelated to `/goal`** —
does not touch `state.json`, branches, or PRs.

## Markdown format

One `##` epic wraps many task issues. Each `- [ ]` under `### Tasks` becomes one issue.
`### Acceptance` checklists are context only (copied into every task body, not issues).

```markdown
## Set up dev and prod data infrastructure stack
Labels: infra, enhancement
Assignee: @me

Epic summary paragraph(s) describing scope and deviations...

### Acceptance
- [ ] `make dev-up` brings up Traefik, Postgres, Redis, MinIO, MailHog
- [ ] Cross-database isolation holds

### Tasks

**Phase 1 — Repo scaffolding**
- [ ] Remove the stray empty `Users/` directory; extend `.gitignore`
- [ ] Create tree: `traefik/{dev,prod}/`, `postgres/init/{dev,prod}/`

**Phase 2 — Postgres init**
- [ ] `postgres/init/dev/01-databases.sql`: roles and REVOKE lines
```

### Rules
- **Epic (`##`)** — title plus optional metadata immediately after the heading:
  - `Labels:` / `Label:` — comma-separated (inherited by every task issue)
  - `Assignee:` / `Assignees:` — comma-separated (`@me` on GitHub)
  - `Milestone:` — milestone name
- **Epic summary** — prose between metadata and the first `###`.
- **Acceptance** — `### Acceptance` section; checklist items are **not** issues; text is embedded in each task body.
- **Tasks** — `### Tasks` section; only `- [ ]` / `- [x]` lines here become issues.
- **Phase** — bold line `**Phase N — …**` before a task group; issue title becomes `[Phase N] <task text>`.
- **Issue title** — `[Phase N] <checkbox text>` (truncated at 200 chars); no phase prefix when no phase line yet.
- **Issue body** — Context (epic title + summary), Phase, Acceptance, Task sections.

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
3. Run `create-issues.sh parse <file>` and show a numbered preview (phase-prefixed title, labels, assignees, body excerpt).
4. Run `create-issues.sh create <file> --dry-run` and show the commands.
5. Ask the user to confirm (report total task count).
6. Run `create-issues.sh create <file>` (forward `--repo`, `--platform`, `--label`, `--milestone` from arguments when present).
7. Report created URLs and the summary line (`created` / `skipped` / `failed`).

Never invoke `git`, `gh`, or `glab` directly — always use `create-issues.sh`.
