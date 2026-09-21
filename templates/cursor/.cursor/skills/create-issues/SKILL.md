---
name: create-issues
description: >-
  Create GitHub or GitLab issues from Markdown epic/task plans such as plan.md,
  with one issue per checkbox under ### Tasks. Usage: /create-issues
disable-model-invocation: true
---

# Create Issues from Markdown

Bulk-create GitHub or GitLab issues from a Markdown epic file. **Unrelated to
`/goal`** — does not touch `state.json`, branches, pull requests, or merge
requests.

## Markdown format

One `##` epic wraps many task issues. Each `- [ ]` or `- [x]` item under that
epic's `### Tasks` section becomes one issue. Checklist items under
`### Acceptance` are context only: copy them into every task issue body, but do
not create issues for them.

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

### Parsing rules

- An epic starts at a level-two heading: `## <epic title>`.
- Optional metadata must be read immediately after the epic heading:
  - `Labels:` or `Label:` — comma-separated labels inherited by every task.
  - `Assignee:` or `Assignees:` — comma-separated assignees inherited by every
    task. Preserve GitHub's special `@me` value.
  - `Milestone:` — milestone name inherited by every task.
- Epic summary is the prose between metadata and the first level-three heading.
- `### Acceptance` belongs to the current epic. Preserve its Markdown in every
  generated task body, but never turn its checkboxes into separate issues.
- Only checkbox lines inside `### Tasks` become issues. Ignore checkboxes in all
  other sections.
- A bold phase line in the form `**Phase N — description**` applies to following
  tasks until the next phase or epic.
- The issue title is `[Phase N] <checkbox text>` when a phase is active, or just
  `<checkbox text>` when there is no phase. Truncate titles longer than 200
  characters, using `...` within that limit.
- Reset phase and all inherited metadata when a new epic starts.
- Support multiple epics in one source file.
- Fail clearly when the file does not exist or no task checkboxes are found.

Each issue body must have these sections:

```markdown
## Context
<epic title>

<epic summary, when present>

## Phase
<full phase text, or `(none)`>

## Acceptance
<acceptance Markdown, or `(none)`>

## Task
<task checkbox text without the checkbox marker>
```

## Script

All parse/create/status work goes through this helper. Never construct ad hoc
`gh`, `glab`, or `git` commands.

```bash
.cursor/skills/create-issues/scripts/create-issues.sh parse <file.md>
.cursor/skills/create-issues/scripts/create-issues.sh create <file.md> [flags]
.cursor/skills/create-issues/scripts/create-issues.sh status [flags]
```

`create` flags:

```text
--repo <owner/repo>          Override the repository inferred from the cwd
--platform github|gitlab     Override platform detection
--label <name>               Add a label to every issue; repeatable
--milestone <name>           Default when an epic has no milestone
--dry-run                    Print intended operations without creating issues
--allow-duplicates           Disable duplicate-title protection
```

`status` accepts `--repo` and `--platform`.

Platform order: `--platform` → `GOAL_PLATFORM` → `.cursor/goal-config.json`
`platform` → `origin` remote hostname.

Do not create labels or milestones silently. If the forge rejects missing
metadata, report the failure and the corrective action (create the label or
milestone in the forge UI, then retry).

## Workflow

1. Resolve the source Markdown path and optional flags from the user's request.
2. Run the helper's `status` command and report missing CLI/authentication
   requirements without attempting creation.
3. Run `parse` and show a numbered preview with the total issue count, title,
   metadata, and a short body excerpt.
4. Run `create ... --dry-run` and summarize the exact intended changes.
5. If the user requested only a dry run, stop.
6. Otherwise, ask for explicit confirmation immediately before creating issues.
7. After confirmation, run `create` without `--dry-run` and report every created
   URL plus the final counts.

Never infer that a request to preview, parse, validate, or explain the plan
authorizes external issue creation. Do not edit the source Markdown after
publishing.

If platform detection fails, tell the user to pass `--platform`, set
`GOAL_PLATFORM`, or run `/init-goal` so `.cursor/goal-config.json` has
`platform`.
