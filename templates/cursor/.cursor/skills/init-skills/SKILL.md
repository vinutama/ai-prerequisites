---
name: init-skills
description: >-
  Install the addyosmani/agent-skills matched to each Cursor goal-loop role,
  then optionally install ui-ux-pro-max. Usage: /init-skills
disable-model-invocation: true
---

Read the project README and AGENTS.md to understand conventions first.

This command installs an **exact skill list** from
[addyosmani/agent-skills](https://github.com/addyosmani/agent-skills)
into `.cursor/skills/` at the **project level** (not a global skills directory),
then optionally installs
[ui-ux-pro-max](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill).

**Do not install the whole pack.** Only install skills named for a role below
(union for recommended; per selected agents for custom). `ui-ux-pro-max` is not
part of this pack; it is installed separately in step 3 when the user opts in.

## Agent → skill map (source of truth)

Each `.cursor/agents/<role>.md` lists the same skills in its `## Related skills` section.

| Agent | Skills (agent-skills) |
|---|---|
| `planner` | `spec-driven-development`, `planning-and-task-breakdown`, `api-and-interface-design`, `documentation-and-adrs` |
| `researcher` | `source-driven-development`, `documentation-and-adrs`, `security-and-hardening`, `performance-optimization` |
| `builder` | `incremental-implementation`, `test-driven-development`, `api-and-interface-design`, `frontend-ui-engineering`, `code-simplification` |
| `builder-expert` | `debugging-and-error-recovery`, `test-driven-development`, `security-and-hardening`, `performance-optimization`, `deprecation-and-migration` |
| `reviewer` | `code-review-and-quality`, `security-and-hardening`, `performance-optimization`, `code-simplification` |
| `visual-reviewer` | `browser-testing-with-devtools`, `frontend-ui-engineering` |

Left out on purpose, because the goal harness already owns this or the skill does
not suit an autonomous loop: `git-workflow-and-versioning`, `ci-cd-and-automation`,
`shipping-and-launch`, `interview-me`, `idea-refine`, `doubt-driven-development`,
`constraint-driven-development`, `context-engineering`,
`observability-and-instrumentation`, `using-agent-skills`.

Ask the user the following questions one at a time and wait for each answer:

1. **Install mode** — Which install preset?
   - `recommended` — install the **union** of all role skills above (deduplicated). **Default.**
   - `custom` — pick one or more agents; install only those agents' skills.

   If `recommended`, install from the project root:
   ```bash
   SKILLS="spec-driven-development planning-and-task-breakdown api-and-interface-design documentation-and-adrs source-driven-development security-and-hardening performance-optimization incremental-implementation test-driven-development frontend-ui-engineering code-simplification debugging-and-error-recovery deprecation-and-migration code-review-and-quality browser-testing-with-devtools"
   tmp="$(mktemp -d)"
   git clone --depth 1 https://github.com/addyosmani/agent-skills "$tmp/agent-skills"
   git -C "$tmp/agent-skills" rev-parse HEAD   # report this commit in the summary
   mkdir -p .cursor/skills .cursor/references
   for s in $SKILLS; do
     if [ -f "$tmp/agent-skills/skills/$s/SKILL.md" ]; then
       rm -rf ".cursor/skills/$s"
       cp -R "$tmp/agent-skills/skills/$s" ".cursor/skills/$s"
     else
       echo "missing upstream: $s"
     fi
   done
   # Skills link to ../../references/*.md, which resolves to .cursor/references/.
   cp -R "$tmp/agent-skills/references/." .cursor/references/
   rm -rf "$tmp"
   ```
   Then skip to **After agent-skills install** below.

   If `custom`, continue with question 2.

2. **Agents** (custom only) — Which agents' skills to install? (multi-select)
   - `planner`, `researcher`, `builder`, `builder-expert`, `reviewer`, `visual-reviewer`
   - Or `all` (same as recommended)

   Build a deduplicated space-separated `SKILLS` list from the map for the selected
   agents only, then run the same install block with that list.

**After agent-skills install:**
1. List installed skills: `ls .cursor/skills/*/SKILL.md`
2. Update `AGENTS.md` — find or create the `## Available skills` section and append
   any new skills not already listed, using the format:
   `- \`<skill-name>\` — <description from SKILL.md frontmatter>`
   Skip `goal-loop` / `goal` / `init-goal` / `init-skills` / `create-issues` (already present). Do not duplicate existing entries.
3. Report which skills were requested vs which actually landed (names can change upstream).

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
        npx -y ui-ux-pro-max-cli init --ai cursor
        ```
     3. Verify: `ls .cursor/skills/ui-ux-pro-max/`
     4. Append `ui-ux-pro-max` to `AGENTS.md` `## Available skills` if not already listed:
        `- \`ui-ux-pro-max\` — design intelligence for UI/UX (styles, palettes, design system generation)`

**Final summary:** Display agents covered, exact skill names requested, skill count installed,
the agent-skills commit installed, whether ui-ux-pro-max was installed, and how to invoke
(e.g. ``/code-review-and-quality``).

**Important:**
- Do NOT load all SKILL.md files into context at once, and do not rely on `@mentions`.
- Re-running `/init-skills` refreshes the listed skills in `.cursor/skills/` to upstream's latest.
  It replaces a same-named skill and leaves every other skill untouched.
- Requires network access and `git`. `ui-ux-pro-max` additionally requires `npx` (Node.js >= 22),
  and its design-system generation requires `python3` (stdlib only).
- If an agent's `## Related skills` changes later, update this map to match before re-running.
