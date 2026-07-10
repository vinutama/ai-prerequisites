---
description: >-
  Install curated agentic-awesome-skills into this project. Asks for categories
  and risk filter, then installs into .opencode/skills (project-level).
  Usage: /init-skills
agent: orchestrator
subtask: true
---

Read the project README and AGENTS.md to understand conventions first.

This command installs a filtered subset of skills from
[agentic-awesome-skills](https://github.com/sickn33/agentic-awesome-skills)
into `.opencode/skills/` at the **project level** (not global `~/.agents/skills`).

Ask the user the following questions one at a time and wait for each answer:

1. **Install mode** — Which install preset?
   - `recommended` — installs skills for all goal-loop agents (orchestrator,
     planner, builder, builder-expert, reviewer, visual-reviewer). **Default.**
   - `custom` — pick categories, risk, and optional tags yourself.

   If `recommended`, install from the project root:
   ```bash
   npx agentic-awesome-skills --path .opencode/skills \
     --category general,workflow,development,testing,architecture,security \
     --risk safe,none
   ```
   Then skip to **After install** below. This installs the categories that
   contain every skill the agents look for (slightly broader than the exact list).

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
   - `safe,none` — recommended for OpenCode (default)
   - Other values may exist; run `npx agentic-awesome-skills --help` to see options.

   Default: `safe,none`

4. **Tags** (optional) — Any tag refinement? (e.g. `typescript`, `react`)
   - Skip if unsure.

After collecting answers (custom mode only), install from the project root:
```bash
npx agentic-awesome-skills --path .opencode/skills --category <categories> --risk <risk>
```
Add `--tags <tags>` only if the user provided tags.

**After install:**
1. List installed skills: `ls .opencode/skills/*/SKILL.md`
2. Update `AGENTS.md` — find or create the `## Available skills` section and append
   any new skills not already listed, using the format:
   `- \`<skill-name>\` — <description from SKILL.md frontmatter>`
   Skip `goal-loop` (already present). Do not duplicate existing entries.
3. Display a summary: categories installed, skill count, and how to invoke
   (e.g. "use @brainstorming to plan a feature").

**Important:**
- Skills are invoked by name in prompts (e.g. `@brainstorming`); do NOT load all
  SKILL.md files into context at once.
- Re-running `/init-skills` with different categories adds more skills (installer
  merges into `.opencode/skills/`).
- Requires network access and `npx` (Node.js >= 22).
