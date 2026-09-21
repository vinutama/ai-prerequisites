# Create a Codex Skill for Markdown-to-Issue Publishing

Create a reusable Codex skill named `create-issues` that reads a Markdown plan
(for example, `plan.md`) and creates one GitHub or GitLab issue for every task
checkbox under a `### Tasks` section.

Implement the skill in the current project by default. Use this layout:

```text
.agents/skills/create-issues/
├── SKILL.md
├── agents/
│   └── openai.yaml
└── scripts/
    └── create-issues.sh
```

If the user explicitly asks for a personal/global skill, install the same tree at
`$HOME/.agents/skills/create-issues/` instead. Do not modify any unrelated
workflow, state file, branch, pull request, or merge request.

Before implementing, inspect `AGENTS.md`, the repository conventions, and any
existing issue-creation implementation that can be safely reused. If this project
contains the OpenCode reference files below, port their tested behavior rather
than maintaining two divergent parsers:

```text
templates/opencode/.opencode/skills/create-issues/SKILL.md
templates/opencode/.opencode/scripts/create-issues.sh
```

## Required Markdown format

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

## Shell helper requirements

Put deterministic parsing and forge CLI calls in
`.agents/skills/create-issues/scripts/create-issues.sh`. The skill must use this
helper instead of constructing ad hoc `gh`, `glab`, or `git` commands.

Support these commands:

```bash
.agents/skills/create-issues/scripts/create-issues.sh parse <file.md>
.agents/skills/create-issues/scripts/create-issues.sh create <file.md> [flags]
.agents/skills/create-issues/scripts/create-issues.sh status [flags]
```

`parse` must print a JSON array. Every item must contain `title`, `body`,
`labels` (array), `assignees` (array), and `milestone` (string or `null`). Use
`jq` for JSON construction so Markdown, quotes, backticks, Unicode, and newlines
remain valid.

`create` flags:

```text
--repo <owner/repo>          Override the repository inferred from the cwd
--platform github|gitlab     Override platform detection
--label <name>               Add a label to every issue; repeatable
--milestone <name>           Default when an epic has no milestone
--dry-run                    Print intended operations without creating issues
--allow-duplicates           Disable duplicate-title protection
```

`status` accepts `--repo` and `--platform` and reports the resolved platform,
repository mode, required CLI availability, and authentication state.

Resolve the platform in this order:

1. `--platform`.
2. `GOAL_PLATFORM` environment variable.
3. A project configuration value if the current repository already has a
   clearly established goal config; do not introduce a new config format.
4. The `origin` remote hostname.

Use `gh issue create` for GitHub and `glab issue create` for GitLab. Use argument
arrays and temporary body files where supported; do not use `eval`. Require
`jq` and the selected forge CLI. Temporary files must be cleaned up on success,
failure, and interruption.

Before a real create operation, fetch existing open and closed issue titles.
Skip exact title matches by default and report them as duplicates. With
`--allow-duplicates`, create them normally. A failure for one issue should be
reported and counted without hiding the results of the other issues. Finish
with `created`, `skipped`, and `failed` counts and return nonzero when any issue
failed.

Dry-run output must be safe to inspect and must not expose secrets. It must show
the target platform/repository, issue titles, labels, assignees, milestone, and
body or body-file intent. It must never create, update, or close an issue.

## `SKILL.md` behavior

Give `SKILL.md` concise YAML frontmatter:

```yaml
---
name: create-issues
description: >-
  Create GitHub or GitLab issues from Markdown epic/task plans such as plan.md,
  with one issue per checkbox under ### Tasks.
---
```

The workflow used by Codex must be:

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

The skill must never infer that a request to preview, parse, validate, or explain
the plan authorizes external issue creation. It must not edit the source
Markdown after publishing. It must not create labels or milestones silently;
if the forge rejects missing metadata, report the failure and the corrective
action.

## `agents/openai.yaml`

Create UI metadata consistent with the skill. Use explicit invocation because
this skill can cause external mutations:

```yaml
interface:
  display_name: "Create Issues"
  short_description: "Publish Markdown tasks as GitHub or GitLab issues"
  default_prompt: "Use $create-issues to preview and publish tasks from plan.md."
policy:
  allow_implicit_invocation: false
```

## Validation

Make the shell helper executable and test it without creating real issues.
At minimum, cover these observable behaviors with temporary fixtures:

- the example above produces three issues, not five acceptance/task issues;
- labels, assignees, milestone, summary, and acceptance text are inherited;
- phase prefixes and phase resets across epics are correct;
- tasks outside `### Tasks` are ignored;
- `- [ ]` and `- [x]` tasks are both parsed;
- a title is capped at 200 characters;
- Markdown containing spaces, quotes, backticks, Unicode, and newlines produces
  valid JSON;
- missing files and plans with no task issues fail with useful messages;
- `create --dry-run` performs no external mutation.

Run the standard Codex skill validator if it is available:

```bash
python3 "${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/scripts/quick_validate.py" \
  .agents/skills/create-issues
```

If that exact validator path does not exist, locate the installed
`skill-creator/scripts/quick_validate.py`; do not skip validation silently.
Also run `bash -n` on the helper and exercise `parse` against a temporary sample.

Finish by listing the files created, validation results, and the exact invocation
example:

```text
$create-issues plan.md --dry-run
$create-issues plan.md --platform github --repo owner/repo
```
