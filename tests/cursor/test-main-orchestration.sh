#!/usr/bin/env bash
# Smoke test: Cursor goal scaffolds direct MAIN → worker orchestration.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/cursor-main-goal.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT
PROJECT="$TEST_ROOT/project"
mkdir -p "$PROJECT/.cursor/agents"
git init -q "$PROJECT"

# Re-install must disable, not delete, a previously generated coordinator.
printf '%s\n' 'custom legacy coordinator content' > "$PROJECT/.cursor/agents/orchestrator.md"
bash "$ROOT/init.sh" --cursor "$PROJECT" > "$TEST_ROOT/init.log"
bash "$ROOT/init.sh" --cursor "$PROJECT" > "$TEST_ROOT/reinit.log"

test -f "$PROJECT/.cursor/skills/goal/SKILL.md"
test -f "$PROJECT/.cursor/skills/goal/references/execution.md"
test -f "$PROJECT/.cursor/skills/goal/references/delivery-groups.md"
test -f "$PROJECT/.cursor/skills/goal/references/issue-queue.md"
rg -q 'MAIN and the only workflow' "$PROJECT/.cursor/skills/goal/SKILL.md"
rg -q 'Cursor.*Agent/Task|Agent/Task delegation' "$PROJECT/.cursor/skills/goal/SKILL.md"
test ! -e "$PROJECT/.cursor/agents/orchestrator.md"
test -f "$PROJECT/.cursor/agents/orchestrator.md.disabled"
rg -q 'custom legacy coordinator content' "$PROJECT/.cursor/agents/orchestrator.md.disabled"
test ! -e "$PROJECT/.cursor/agents/orchestrator.md.disabled.1"

if jq -e '.orchestrator // .["$routing"].orchestrator' "$PROJECT/.cursor/goal-models.json" >/dev/null; then
  echo 'orchestrator role still configured' >&2
  exit 1
fi
for role in planner researcher builder builder-expert reviewer qa visual-reviewer; do
  test -f "$PROJECT/.cursor/agents/$role.md"
  if rg -qi 'orchestrator' "$PROJECT/.cursor/agents/$role.md"; then
    echo "$role still refers to the removed coordinator" >&2
    exit 1
  fi
done

if GOAL_PLATFORM=github "$PROJECT/.cursor/scripts/goal-git.sh" models orchestrator --complexity NORMAL > "$TEST_ROOT/orchestrator.out" 2>&1; then
  echo 'removed orchestrator still resolves as a worker model' >&2
  exit 1
fi
GOAL_PLATFORM=github "$PROJECT/.cursor/scripts/goal-git.sh" models builder --complexity NORMAL >/dev/null

echo 'PASS: MAIN skill and conditional references installed'
echo 'PASS: orchestrator role/model removed; legacy agent backed up'
echo 'PASS: worker handoffs use MAIN; worker routing still resolves'
