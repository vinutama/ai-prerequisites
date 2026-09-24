#!/usr/bin/env bash
# Smoke test: Codex goal scaffolds direct MAIN → worker orchestration.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/codex-main-goal.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT
PROJECT="$TEST_ROOT/project"
CODEX_TEST_HOME="$TEST_ROOT/codex-home"
mkdir -p "$PROJECT/.codex/agents" "$CODEX_TEST_HOME"
git init -q "$PROJECT"

# Simulate a prior scaffold and a user-owned global depth preference.
printf '%s\n' 'name = "orchestrator"' > "$PROJECT/.codex/agents/orchestrator.toml"
printf '%s\n' '[agents]' 'max_depth = 4' > "$CODEX_TEST_HOME/config.toml"

CODEX_HOME="$CODEX_TEST_HOME" bash "$ROOT/init.sh" --codex "$PROJECT" > "$TEST_ROOT/init.log"

test -f "$PROJECT/.agents/skills/goal/SKILL.md"
test -f "$PROJECT/.agents/skills/goal/references/execution.md"
test -f "$PROJECT/.agents/skills/goal/references/delivery-groups.md"
test -f "$PROJECT/.agents/skills/goal/references/issue-queue.md"
rg -q 'MAIN and the only workflow' "$PROJECT/.agents/skills/goal/SKILL.md"
rg -q 'spawn_agent' "$PROJECT/.agents/skills/goal/SKILL.md"
if rg -q '^\[agents\.orchestrator\]' "$PROJECT/.codex/config.toml"; then
  echo 'orchestrator role still registered' >&2
  exit 1
fi
if jq -e '.["$routing"].orchestrator' "$PROJECT/.codex/goal-models.json" >/dev/null; then
  echo 'orchestrator route still configured' >&2
  exit 1
fi
test "$(sed -n 's/^max_depth = //p' "$CODEX_TEST_HOME/config.toml")" = 4
test "$(sed -n 's/^max_depth = //p' "$PROJECT/.codex/config.toml")" = 1
rg -q 'trust_level = "trusted"' "$CODEX_TEST_HOME/config.toml"
test -f "$PROJECT/.codex/agents/orchestrator.toml" # legacy file is preserved but inert
for role in planner researcher builder builder-expert reviewer qa visual-reviewer; do
  if rg -qi 'orchestrator' "$PROJECT/.codex/agents/$role.toml"; then
    echo "$role still refers to the removed coordinator" >&2
    exit 1
  fi
done

builder_default="$(jq -r '.["$routing"].builder.NORMAL.model' "$PROJECT/.codex/goal-models.json")"
rg -q "^default_subagent_model = \"$builder_default\"$" "$PROJECT/.codex/config.toml"
if GOAL_PLATFORM=github "$PROJECT/.codex/scripts/goal-git.sh" models orchestrator --complexity NORMAL > "$TEST_ROOT/orchestrator.out" 2>&1; then
  echo 'removed orchestrator still resolves as a worker model' >&2
  exit 1
fi
GOAL_PLATFORM=github "$PROJECT/.codex/scripts/goal-git.sh" models builder --complexity NORMAL >/dev/null

echo 'PASS: MAIN skill and conditional references installed'
echo 'PASS: orchestrator role/model removed; worker handoffs use MAIN; legacy file inert'
echo 'PASS: worker routing works; user global depth preserved'
