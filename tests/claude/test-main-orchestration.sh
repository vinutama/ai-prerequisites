#!/usr/bin/env bash
# Smoke test: Claude Code goal scaffold (skills, agents, hooks, MAIN coordination).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export TMPDIR="${TMPDIR:-$ROOT/.tmp-tests}"
mkdir -p "$TMPDIR"
TEST_ROOT="$(mktemp -d "$TMPDIR/claude-main-goal.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
PROJECT="$TEST_ROOT/project"
mkdir -p "$PROJECT/.claude/commands" "$PROJECT/.claude/agents"
git init -q "$PROJECT"

# A project with its own settings plus the legacy OpenCode-derived Claude pieces.
printf '%s\n' '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo user-stop-hook"}]}]}}' > "$PROJECT/.claude/settings.json"
printf '%s\n' '---' 'description: legacy' 'agent: orchestrator' '---' > "$PROJECT/.claude/commands/goal.md"
printf '%s\n' '---' 'description: Goal-loop orchestrator. legacy' '---' > "$PROJECT/.claude/agents/orchestrator.md"
printf '%s\n' '---' 'description: user command' '---' > "$PROJECT/.claude/commands/mine.md"

bash "$ROOT/init.sh" --claude "$PROJECT" > "$TEST_ROOT/init.log"
bash "$ROOT/init.sh" --claude "$PROJECT" > "$TEST_ROOT/reinit.log"

for skill in goal init-goal init-skills create-issues goal-loop; do
  test -f "$PROJECT/.claude/skills/$skill/SKILL.md"
done
for ref in execution delivery-groups issue-queue commands; do
  test -f "$PROJECT/.claude/skills/goal/references/$ref.md"
done
test -x "$PROJECT/.claude/skills/create-issues/scripts/create-issues.sh"
test -f "$PROJECT/CLAUDE.md"
test ! -e "$PROJECT/AGENTS.md"
rg -q '^disable-model-invocation: true' "$PROJECT/.claude/skills/goal/SKILL.md"
rg -q '^name: goal$' "$PROJECT/.claude/skills/goal/SKILL.md"
rg -q 'ARGUMENTS' "$PROJECT/.claude/skills/goal/SKILL.md"
rg -q 'sole coordinator' "$PROJECT/.claude/skills/goal/SKILL.md"
rg -q 'Agent\(\{' "$PROJECT/.claude/skills/goal/SKILL.md"
rg -q 'spawn-confirm' "$PROJECT/.claude/skills/goal/SKILL.md" "$PROJECT/.claude/skills/goal/references/commands.md"
rg -q 'Run until terminal' "$PROJECT/.claude/skills/goal/SKILL.md" "$PROJECT/CLAUDE.md"
if rg -q 'spawn_agent|ensure-user-config|\$goal|opencode' "$PROJECT/.claude/skills" "$PROJECT/CLAUDE.md"; then
  echo 'Claude docs still contain Codex/OpenCode text' >&2; exit 1
fi
for script in goal-git.sh goal-context.sh goal-delegation.sh forge.sh goal-delivery.sh goal-evidence.sh delivery-groups.sh run-claude.sh; do
  test -f "$PROJECT/.claude/scripts/$script"
done

# Legacy coordinator pieces are disabled (recoverable); user files are untouched.
test ! -e "$PROJECT/.claude/commands/goal.md"
test -f "$PROJECT/.claude/commands/goal.md.disabled"
test ! -e "$PROJECT/.claude/agents/orchestrator.md"
test -f "$PROJECT/.claude/agents/orchestrator.md.disabled"
test -f "$PROJECT/.claude/commands/mine.md"

# settings.json keeps user keys and carries each hook exactly once.
jq -e '.model == "opus"' "$PROJECT/.claude/settings.json" >/dev/null
jq -e '[.hooks.Stop[].hooks[].command] | (any(. == "echo user-stop-hook")) and (map(select(test("harness stop-check"))) | length == 1)' "$PROJECT/.claude/settings.json" >/dev/null
jq -e '[.hooks.SubagentStart[].hooks[].command] | length == 1 and (.[0] | test("harness hook"))' "$PROJECT/.claude/settings.json" >/dev/null
jq -e '[.hooks.SubagentStop[].hooks[].command] | length == 1' "$PROJECT/.claude/settings.json" >/dev/null
jq -e '.hooks.SubagentStart[0].hooks[0].command | startswith("\"$CLAUDE_PROJECT_DIR\"/.claude/scripts/goal-git.sh")' "$PROJECT/.claude/settings.json" >/dev/null

# Agents: Claude frontmatter, least-privilege tools, no coordinator.
for role in planner researcher builder builder-expert reviewer visual-reviewer; do
  f="$PROJECT/.claude/agents/$role.md"
  test -f "$f"
  rg -q "^name: $role\$" "$f"
  rg -q '^tools: ' "$f"
  rg -q '^model: (sonnet|opus|haiku|inherit)$' "$f"
  if rg -q '^(mode|permission|temperature):' "$f"; then echo "$role has OpenCode frontmatter" >&2; exit 1; fi
  if rg -qi 'orchestrator' "$f"; then echo "$role refers to the removed coordinator" >&2; exit 1; fi
done
for role in planner researcher reviewer visual-reviewer; do
  if rg '^tools: ' "$PROJECT/.claude/agents/$role.md" | rg -q 'Write|Edit'; then echo "$role must be read-only" >&2; exit 1; fi
done
for role in builder builder-expert; do rg '^tools: ' "$PROJECT/.claude/agents/$role.md" | rg -q 'Write, Edit'; done
test ! -e "$PROJECT/.claude/agents/qa.md"

# Routing resolves Claude aliases and the shared sync does not write readonly.
if jq -e '.orchestrator // .["$routing"].orchestrator' "$PROJECT/.claude/goal-models.json" >/dev/null; then
  echo 'orchestrator role still configured' >&2; exit 1
fi
if rg -q '^readonly:' "$PROJECT/.claude/agents"; then echo 'readonly written for claude agents' >&2; exit 1; fi
G="$PROJECT/.claude/scripts/goal-git.sh"
test "$(GOAL_PLATFORM=github "$G" models builder --complexity NORMAL)" = "$(printf 'sonnet\tmedium\t')"
test "$(GOAL_PLATFORM=github "$G" models reviewer --complexity COMPLEX | cut -f1,2)" = "$(printf 'opus\thigh')"
if GOAL_PLATFORM=github "$G" models planner --complexity TRIVIAL >/dev/null 2>&1; then echo 'planner must be skipped on TRIVIAL' >&2; exit 1; fi
GOAL_PLATFORM=github "$G" models visual-reviewer --require-multimodal >/dev/null
if GOAL_PLATFORM=github "$G" models orchestrator --complexity NORMAL >/dev/null 2>&1; then
  echo 'removed orchestrator still resolves as a worker model' >&2; exit 1
fi

# Figma MCP lives in the project-root .mcp.json for Claude Code.
printf '%s\n' '{"platform":"github"}' > "$PROJECT/.claude/goal-config.json"
printf '%s\n' '{"mcpServers":{"other":{"command":"x"}}}' > "$PROJECT/.mcp.json"
GOAL_PLATFORM=github "$G" figma setup tok >/dev/null 2>&1
jq -e '.mcpServers.figma.command == "npx" and .mcpServers.other.command == "x"' "$PROJECT/.mcp.json" >/dev/null
test ! -e "$PROJECT/.claude/mcp.json"
GOAL_PLATFORM=github "$G" figma disable >/dev/null 2>&1
jq -e '(.mcpServers | has("figma") | not) and .mcpServers.other.command == "x"' "$PROJECT/.mcp.json" >/dev/null

rg -qx '\.claude/' "$PROJECT/.gitignore"
rg -qx 'CLAUDE.md' "$PROJECT/.gitignore"

echo 'PASS: skills, references and shared scripts installed; docs are Claude-specific'
echo 'PASS: legacy commands/orchestrator disabled; user files kept; settings hooks merged once'
echo 'PASS: agents use Claude frontmatter with least-privilege tools'
echo 'PASS: routing resolves Claude aliases; Figma MCP uses root .mcp.json'
