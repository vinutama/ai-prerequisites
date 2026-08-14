---
name: init-skills
description: >-
  Install curated agentic-awesome-skills into this project, then optionally
  install ui-ux-pro-max for UI/UX/frontend design intelligence. Usage: /init-skills
---

Read the project README and AGENTS.md to understand conventions first.

This command installs a filtered subset of skills from
[agentic-awesome-skills](https://github.com/sickn33/agentic-awesome-skills)
into `.agents/skills/` at the **project level** (not global `~/.agents/skills`),
then optionally installs
[ui-ux-pro-max](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill).

Ask the user the following questions one at a time and wait for each answer:

1. **Install mode** — Which install preset?
   - `recommended` — installs skills for all goal-loop agents (orchestrator,
     planner, builder, builder-expert, reviewer, visual-reviewer). **Default.**
   - `custom` — pick categories, risk, and optional tags yourself.

   If `recommended`, install from the project root:
   ```bash
   npx agentic-awesome-skills --path .codex/skills \
     --category general,workflow,development,testing,architecture,security \
     --risk safe,none
   ```
   Then skip to **After agentic-awesome-skills install** below. This installs the
   categories that contain every skill the agents look for (slightly broader
   than the exact list).

   If `custom`, continue with questions 2–4.

2. **Categories** — Which skill categories to install? (multi-select, comma-separated)
   - `architecture` — system design, patterns, ADRs
   - `business` — product, PM, growth
   - `data-ai` — ML, data pipelines, AI integrations
   - `development` — coding, frameworks, languages
   - `general` — utilities, debugging, planning
   - `infrastructure` — DevOps, cloud, CI/CD
   - `security` — audits, hardening, auth
   - `testing` — QA, test automation, browser testing
   - `workflow` — agent orchestration, handoffs, loops

   Default if unsure: `development,general`

3. **Risk filter** — Which risk levels to include?
   - `safe,none` — recommended (default)
   - Other values may exist; run `npx agentic-awesome-skills --help` to see options.

   Default: `safe,none`

4. **Tags** (optional) — Any tag refinement? (e.g. `typescript`, `react`)
   - Skip if unsure.

After collecting answers (custom mode only), install from the project root:
```bash
npx agentic-awesome-skills --path .codex/skills --category <categories> --risk <risk>
```
Add `--tags <tags>` only if the user provided tags.

**After agentic-awesome-skills install:**
1. List installed skills: `ls .agents/skills/*/SKILL.md`
2. Update `AGENTS.md` — find or create the `## Available skills` section and append
   any new skills not already listed, using the format:
   `- \`<skill-name>\` — <description from SKILL.md frontmatter>`
   Skip `goal-loop` (already present). Do not duplicate existing entries.

5. **UI/UX Pro Max** — Install design intelligence skill for UI/UX/frontend tasks
   (84 styles, 192 color palettes, industry-specific design system generation)?
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
     3. Verify: `ls .agents/skills/ui-ux-pro-max/`
     4. Append `ui-ux-pro-max` to `AGENTS.md` `## Available skills` if not already listed:
        `- \`ui-ux-pro-max\` — design intelligence for UI/UX (styles, palettes, design system generation)`

**Final summary:** Display categories installed, skill count, whether ui-ux-pro-max was
installed, and how to invoke (e.g. ``$ui-ux-pro-max``).

**Important:**
- Skills are loaded by invoking `$skill-name`; do NOT load all SKILL.md files into context
  at once, and do not rely on `@mentions`.
- Re-running `$init-skills` with different categories adds more skills (installer
  merges into `.agents/skills/`).
- Requires network access and `npx` (Node.js >= 22).
- `ui-ux-pro-max` design-system generation additionally requires `python3` (stdlib only).
