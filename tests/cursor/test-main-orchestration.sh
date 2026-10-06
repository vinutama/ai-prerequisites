#!/usr/bin/env bash
# Smoke test: Cursor goal scaffolds direct MAIN → worker orchestration.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export TMPDIR="${TMPDIR:-$ROOT/.tmp-tests}"
mkdir -p "$TMPDIR"
TEST_ROOT="$(mktemp -d "$TMPDIR/cursor-main-goal.XXXXXX")"
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
test -f "$PROJECT/.cursor/skills/goal/references/commands.md"
test -f "$PROJECT/AGENTS.md"

rg -q 'sole coordinator|You are the sole coordinator' "$PROJECT/.cursor/skills/goal/SKILL.md"
rg -q 'Agent/Task' "$PROJECT/.cursor/skills/goal/SKILL.md" "$PROJECT/AGENTS.md"
rg -q 'harness brief' "$PROJECT/.cursor/skills/goal/SKILL.md" "$PROJECT/.cursor/skills/goal/references/commands.md" "$PROJECT/AGENTS.md"
rg -q 'spawn-confirm' "$PROJECT/.cursor/skills/goal/SKILL.md" "$PROJECT/.cursor/skills/goal/references/commands.md" "$PROJECT/AGENTS.md"
rg -q 'harness brief' "$PROJECT/.cursor/skills/goal/references/commands.md"
rg -q 'spawn-confirm' "$PROJECT/.cursor/skills/goal/references/commands.md"

for script in goal-context.sh goal-delegation.sh forge.sh goal-delivery.sh goal-evidence.sh; do
  test -f "$PROJECT/.cursor/scripts/$script"
done

test ! -e "$PROJECT/.cursor/agents/orchestrator.md"
test -f "$PROJECT/.cursor/agents/orchestrator.md.disabled"
rg -q 'custom legacy coordinator content' "$PROJECT/.cursor/agents/orchestrator.md.disabled"
test ! -e "$PROJECT/.cursor/agents/orchestrator.md.disabled.1"

if jq -e '.orchestrator // .["$routing"].orchestrator' "$PROJECT/.cursor/goal-models.json" >/dev/null; then
  echo 'orchestrator role still configured' >&2
  exit 1
fi
for role in planner researcher builder builder-expert reviewer visual-reviewer; do
  test -f "$PROJECT/.cursor/agents/$role.md"
  if rg -qi 'orchestrator' "$PROJECT/.cursor/agents/$role.md"; then
    echo "$role still refers to the removed coordinator" >&2
    exit 1
  fi
done
test ! -e "$PROJECT/.cursor/agents/qa.md"
if GOAL_PLATFORM=github "$PROJECT/.cursor/scripts/goal-git.sh" models qa --complexity NORMAL > "$TEST_ROOT/qa.out" 2>&1; then
  echo 'removed qa still resolves as a worker model' >&2
  exit 1
fi

# Reinstall must delete leftover QA agent files and strip qa_mode from config.
printf '%s\n' 'stale' > "$PROJECT/.cursor/agents/qa.md"
printf '%s\n' '{"platform":"github","qa_mode":"auto"}' > "$PROJECT/.cursor/goal-config.json"
bash "$ROOT/init.sh" --cursor "$PROJECT" > "$TEST_ROOT/reinit-qa.log"
test ! -e "$PROJECT/.cursor/agents/qa.md"
jq -e 'has("qa_mode") | not' "$PROJECT/.cursor/goal-config.json" >/dev/null

if GOAL_PLATFORM=github "$PROJECT/.cursor/scripts/goal-git.sh" models orchestrator --complexity NORMAL > "$TEST_ROOT/orchestrator.out" 2>&1; then
  echo 'removed orchestrator still resolves as a worker model' >&2
  exit 1
fi
GOAL_PLATFORM=github "$PROJECT/.cursor/scripts/goal-git.sh" models builder --complexity NORMAL >/dev/null
builder_model="$(GOAL_PLATFORM=github "$PROJECT/.cursor/scripts/goal-git.sh" models builder --complexity NORMAL | cut -f1)"
test "$builder_model" = "inherit"

echo 'PASS: MAIN skill and conditional references installed'
echo 'PASS: brief / spawn-confirm / Agent/Task launch recipe present'
echo 'PASS: shared scripts and commands.md installed'
echo 'PASS: orchestrator role/model removed; legacy agent backed up'
echo 'PASS: worker handoffs use MAIN; worker routing resolves to inherit'
echo 'PASS: qa.md absent; reinstall removes leftover qa.md and strips qa_mode'
