---
name: init-skills
description: >-
  Install only the agentic-awesome-skills attached to Codex goal-loop agents,
  then optionally install ui-ux-pro-max. Usage: $init-skills
---

Read the project README and AGENTS.md to understand conventions first.

This command installs an **exact skill list** from
[agentic-awesome-skills](https://github.com/sickn33/agentic-awesome-skills)
into `.codex/skills/` at the **project level** (not global `~/.codex/skills`),
then optionally installs
[ui-ux-pro-max](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill).

**Do not install by broad category.** Only install skills named in each agent's
`## Related skills` section (union for recommended; per selected agents for custom).
`ui-ux-pro-max` is never part of the `--skills` list — it is installed separately
in step 3 when the user opts in.

## Agent → skill map (source of truth)

Read each `.codex/agents/<role>.toml` `## Related skills` section if present.
Canonical map (exclude `ui-ux-pro-max` from the npx `--skills` install):

| Agent | Skills (awesome-skills `--skills`) |
|---|---|
| `orchestrator` | `parallel-agents`, `multi-agent-patterns`, `verification-before-completion` |
| `planner` | `brainstorming`, `concise-planning`, `writing-plans`, `architecture` |
| `researcher` | `deep-research`, `research-prompt`, `documentation`, `documentation-templates`, `architecture`, `api-security-best-practices` |
| `builder` | `test-driven-development`, `lint-and-validate`, `error-handling-patterns`, `api-endpoint-builder` |
| `builder-expert` | `systematic-debugging`, `test-driven-development`, `lint-and-validate`, `architecture`, `error-handling-patterns`, `api-endpoint-builder` |
| `reviewer` | `code-review-excellence`, `verification-before-completion`, `api-security-best-practices`, `systematic-debugging` |
| `qa` | `e2e-testing-patterns`, `webapp-testing`, `browser-automation`, `test-driven-development`, `verification-before-completion`, `systematic-debugging`, `api-security-testing` |
| `visual-reviewer` | `wcag-audit-patterns`, `frontend-design`, `webapp-testing` |

Ask the user the following questions one at a time and wait for each answer:

1. **Install mode** — Which install preset?
   - `recommended` — install the **union** of all agent-attached skills above (deduplicated). **Default.**
   - `custom` — pick one or more agents; install only those agents' attached skills.

   If `recommended`, compute the deduplicated union and install from the project root:
   ```bash
   npx agentic-awesome-skills --path .codex/skills --skills \
   parallel-agents,multi-agent-patterns,verification-before-completion,brainstorming,concise-planning,writing-plans,architecture,deep-research,research-prompt,documentation,documentation-templates,api-security-best-practices,test-driven-development,lint-and-validate,error-handling-patterns,api-endpoint-builder,systematic-debugging,code-review-excellence,e2e-testing-patterns,webapp-testing,browser-automation,api-security-testing,wcag-audit-patterns,frontend-design
   ```
   Do **not** pass `--category` or `--risk` for recommended — the skill list is exact.
   Then skip to **After agentic-awesome-skills install** below.

   If `custom`, continue with question 2.

2. **Agents** (custom only) — Which agents' skills to install? (multi-select)
   - `orchestrator`, `planner`, `researcher`, `builder`, `builder-expert`, `reviewer`, `qa`, `visual-reviewer`
   - Or `all` (same as recommended)

   Build a deduplicated comma-separated `--skills` list from the map for the selected agents only.
   Install from the project root:
   ```bash
   npx agentic-awesome-skills --path .codex/skills --skills <comma-separated-skill-names>
   ```
   Do **not** pass `--category`.

**After agentic-awesome-skills install:**
1. List installed skills: `ls .codex/skills/*/SKILL.md`
2. Update `AGENTS.md` — find or create the `## Available skills` section and append
   any new skills not already listed, using the format:
   `- \`<skill-name>\` — <description from SKILL.md frontmatter>`
   Skip `goal-loop` / `goal` / `init-goal` / `init-skills` (already present). Do not duplicate existing entries.
3. Report which skills were requested vs which actually landed (some names may be missing upstream).

3. **UI/UX Pro Max** — Install design intelligence skill for UI/UX/frontend tasks
   (used by planner, builder, builder-expert, visual-reviewer)?
   From [ui-ux-pro-max-skill](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill).
   - `no` — skip (default if the project has no frontend)
   - `yes` — continue:
     1. Check Python: `python3 --version`. If missing, **warn** the user to install
        Python 3 themselves (do **not** attempt to install it). Note that design-system
        generation (`search.py`) will not work until Python is available; static skill
        guidelines still function.
     2. Install from the project root:
        ```bash
        npx -y ui-ux-pro-max-cli init --ai codex
        ```
     3. Verify: `ls .codex/skills/ui-ux-pro-max/` (or `.agents/skills/ui-ux-pro-max/` if the CLI wrote there — prefer `.codex/skills/`)
     4. Append `ui-ux-pro-max` to `AGENTS.md` `## Available skills` if not already listed:
        `- \`ui-ux-pro-max\` — design intelligence for UI/UX (styles, palettes, design system generation)`

**Final summary:** Display agents covered, exact skill names requested, skill count installed,
whether ui-ux-pro-max was installed, and how to invoke (e.g. ``$deep-research``).

**Important:**
- Skills are loaded by invoking `$skill-name`; do NOT load all SKILL.md files into context
  at once, and do not rely on `@mentions`.
- Re-running `$init-skills` merges into `.codex/skills/` (exact `--skills` set is managed).
- Requires network access and `npx` (Node.js >= 22).
- `ui-ux-pro-max` design-system generation additionally requires `python3` (stdlib only).
- If agent TOMLs gain or drop related skills later, update this map to match before re-running.
