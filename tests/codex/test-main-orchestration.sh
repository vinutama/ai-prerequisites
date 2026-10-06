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
rg -q 'You are the sole coordinator' "$PROJECT/.agents/skills/goal/SKILL.md"
rg -q 'Spawn workers directly' "$PROJECT/.agents/skills/goal/SKILL.md"
test -f "$PROJECT/.agents/skills/goal/references/commands.md"
rg -q 'spawn-confirm' "$PROJECT/.agents/skills/goal/references/commands.md"
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
for role in planner researcher builder builder-expert reviewer visual-reviewer; do
  if rg -qi 'orchestrator' "$PROJECT/.codex/agents/$role.toml"; then
    echo "$role still refers to the removed coordinator" >&2
    exit 1
  fi
done
test ! -e "$PROJECT/.codex/agents/qa.toml"
if GOAL_PLATFORM=github "$PROJECT/.codex/scripts/goal-git.sh" models qa --complexity NORMAL > "$TEST_ROOT/qa.out" 2>&1; then
  echo 'removed qa still resolves as a worker model' >&2
  exit 1
fi

# Reinstall must delete leftover QA agent files and strip qa_mode from config.
printf '%s\n' 'name = "qa"' > "$PROJECT/.codex/agents/qa.toml"
printf '%s\n' '{"platform":"github","qa_mode":"auto"}' > "$PROJECT/.codex/goal-config.json"
CODEX_HOME="$CODEX_TEST_HOME" bash "$ROOT/init.sh" --codex "$PROJECT" > "$TEST_ROOT/reinit-qa.log"
test ! -e "$PROJECT/.codex/agents/qa.toml"
jq -e 'has("qa_mode") | not' "$PROJECT/.codex/goal-config.json" >/dev/null

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
echo 'PASS: reinstall removes leftover qa.toml and strips qa_mode'

# Exercise MAIN's public dispatcher with real local child processes and actual
# Git commits. Analyzer/forge boundaries are local mocks; gates are never seeded
# to PASS. The analyzer mock checks shell syntax and the staged diff itself.
mkdir -p "$TEST_ROOT/bin"
export ORCHESTRATION_TRACE="$TEST_ROOT/lifecycle.trace"
cat > "$TEST_ROOT/bin/npx" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = '--yes gitnexus@latest analyze' ] || exit 97
printf '%s\n' analyze >> "$ORCHESTRATION_TRACE"
bash -n implementation.sh
bash -n verify-fixture.sh
git diff --cached --check
MOCK
cat > "$TEST_ROOT/bin/rtk" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = gain ] || exit 97
printf '%s\n' gain >> "$ORCHESTRATION_TRACE"
git diff --check
MOCK
for cli in gh glab; do
  printf '%s\n' '#!/usr/bin/env bash' 'echo "Unexpected forge access: $*" >&2' 'exit 97' > "$TEST_ROOT/bin/$cli"
done
chmod +x "$TEST_ROOT/bin/"*
export PATH="$TEST_ROOT/bin:$PATH" GOAL_PLATFORM=github
GOAL_GIT="$PROJECT/.codex/scripts/goal-git.sh"
# Scaffold must install every module required by the current main, including
# role definitions and routing. Do not replace missing modules with stubs.
for module in forge goal-context delivery-groups goal-delivery goal-delegation goal-evidence; do
  test -f "$PROJECT/.codex/scripts/$module.sh"
done
for role in planner builder reviewer visual-reviewer; do
  test -s "$PROJECT/.codex/agents/$role.toml"
done

git -C "$PROJECT" config user.name Fixture
git -C "$PROJECT" config user.email fixture@example.test
git -C "$PROJECT" config commit.gpgsign false
# Workflow metadata is runtime state; only implementation artifacts are tracked.
printf '%s\n' '.codex/' '.agents/' 'AGENTS.md' 'state.json' '.goal-review/' > "$PROJECT/.git/info/exclude"
printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' initial" > "$PROJECT/implementation.sh"
printf '%s\n' initial > "$PROJECT/expected.txt"
cat > "$PROJECT/verify-fixture.sh" <<'CHECK'
#!/usr/bin/env bash
set -euo pipefail
bash -n implementation.sh
test "$(bash implementation.sh)" = "$(cat expected.txt)"
printf '%s\n' verify >> "$ORCHESTRATION_TRACE"
CHECK
git -C "$PROJECT" add .gitignore implementation.sh expected.txt verify-fixture.sh
git -C "$PROJECT" commit -qm 'chore: local lifecycle fixture'
git -C "$PROJECT" checkout -qb fixture-lifecycle
cat > "$PROJECT/.codex/goal-config.json" <<'CONFIG'
{"platform":"github","concurrency":2,"review_mode":"local",
 "verify_commands":[{"name":"fixture-behavior","cmd":"bash verify-fixture.sh"}]}
CONFIG
cat > "$PROJECT/state.json" <<'STATE'
[{"id":"goal-lifecycle","goal":"Local delegation lifecycle","branch":"fixture-lifecycle",
  "base_branch":"main","status":"in_progress","repos":[],
  "source":{"type":"text","title":"Local delegation lifecycle","body":"Implement the fixture greeting","reference":"local"}}]
STATE
main_run() { "$GOAL_GIT" "$@"; }
main_check() {
  jq -e "$1" "$PROJECT/state.json" >/dev/null || { echo "Lifecycle assertion failed: $1" >&2; exit 1; }
}
main_reject() {
  local expected="$1"; shift
  if main_run "$@" > "$TEST_ROOT/reject.out" 2> "$TEST_ROOT/reject.err"; then
    echo "Unexpected lifecycle success: $*" >&2; exit 1
  fi
  rg -qi -- "$expected" "$TEST_ROOT/reject.err" || { cat "$TEST_ROOT/reject.err" >&2; exit 1; }
}
main_reserve() {
  local role="$1" task="${2:-}" model effort rest
  IFS=$'\t' read -r model effort rest < <(main_run models "$role" --complexity NORMAL)
  if [ -n "$task" ]; then
    main_run harness spawn "$role" "$model" "$effort" --task "$task"
  else
    main_run harness spawn "$role" "$model" "$effort"
  fi | jq -er .reservation.id
}
# Each child executes real local work. Confirm uses its actual process identity,
# wait observes its exit status, and finish records completion/closure separately.
cat > "$TEST_ROOT/worker.sh" <<'WORKER'
#!/usr/bin/env bash
set -euo pipefail
cd "$1"
case "$2" in
  planner) printf '%s\n' '{"route":"feature","plan":"Update the greeting, then verify its output"}' ;;
  builder)
    printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' delegated" > implementation.sh
    printf '%s\n' delegated > expected.txt ;;
  reviewer) bash verify-fixture.sh ;;
  *) exit 97 ;;
esac
WORKER
main_reject 'QA was removed' harness init --complexity NORMAL --route feature --qa true --visual false
main_run harness init --complexity NORMAL --route feature --qa false --visual false > /dev/null
planner_id="$(main_reserve planner)"
bash "$TEST_ROOT/worker.sh" "$PROJECT" planner > "$TEST_ROOT/discovery.json" & child=$!
main_run harness spawn-confirm "$planner_id" "local-$child" > /dev/null
wait "$child"
main_run harness spawn-finish "local-$child" completed --closed > /dev/null
main_run harness context put discovery_context "$TEST_ROOT/discovery.json" > /dev/null
main_run harness gate PLAN PASS > /dev/null
main_run harness phase BUILDING > /dev/null
task="$(main_run harness task add builder 'Update the fixture greeting')"
main_reject 'missing_agent|confirmed' harness task set "$task" RUNNING
main_reject 'missing_agent|confirmed' harness task set "$task" DONE
builder_id="$(main_reserve builder "$task")"
main_check '.[0].harness.metrics.builder_runs == 0 and .[0].harness.tasks[0].state == "SPAWNING"'
main_reject 'missing_agent|confirmed' harness task set "$task" RUNNING
bash "$TEST_ROOT/worker.sh" "$PROJECT" builder & child=$!
main_run harness spawn-confirm "$builder_id" "local-$child" > /dev/null
main_run harness spawn-confirm "$builder_id" "local-$child" > /dev/null
main_check '.[0].harness.metrics.builder_runs == 1 and .[0].harness.tasks[0].state == "RUNNING"'
main_reject 'missing_agent|confirmed' harness task set "$task" DONE
wait "$child"
main_run harness spawn-finish "local-$child" completed --closed > /dev/null
main_run harness task set "$task" DONE > /dev/null
main_run harness gate IMPLEMENTATION PASS > /dev/null
main_reject 'may only be set' harness gate ANALYSIS PASS
main_reject 'may only be set' harness gate VERIFICATION PASS
main_reject 'ANALYSIS is not PASS' harness phase VERIFYING
main_run stage implementation.sh expected.txt > /dev/null
main_reject 'dirty_checkout|Uncommitted' verify run
# Required order in the current MAIN contract: commit the reconciled staged
# tree, then analyze and formally verify that final committed clean HEAD.
main_run commit 'feat: implement delegated greeting' > /dev/null
printf '%s\n' commit >> "$ORCHESTRATION_TRACE"
implementation_sha="$(git -C "$PROJECT" rev-parse HEAD)"
main_check '.[0].harness.gates.ANALYSIS.status == "NOT_RUN"'
main_reject 'ANALYSIS is not PASS' harness phase VERIFYING
main_run analyze > /dev/null
main_check ".[0].harness.gates.ANALYSIS.status == \"PASS\" and .[0].harness.gates.ANALYSIS.sha == \"$implementation_sha\""
main_run harness phase VERIFYING > /dev/null
main_run verify run > "$TEST_ROOT/verified.json"
jq -e --arg sha "$implementation_sha" '.overall == "PASS" and .sha == $sha and .results[0].exit == 0' "$TEST_ROOT/verified.json" >/dev/null
main_check ".[0].harness.gates.VERIFICATION.sha == \"$implementation_sha\""
python3 - "$ORCHESTRATION_TRACE" <<'PY'
import pathlib, sys
trace = pathlib.Path(sys.argv[1]).read_text().splitlines()
assert trace.index("commit") < trace.index("analyze") < trace.index("gain") < trace.index("verify"), trace
PY
main_run harness phase REVIEWING > /dev/null
main_run review init > /dev/null
main_reject 'missing_agent|confirmed' harness gate REVIEW PASS
reviewer_id="$(main_reserve reviewer)"
bash "$TEST_ROOT/worker.sh" "$PROJECT" reviewer & child=$!
main_run harness spawn-confirm "$reviewer_id" "local-$child" > /dev/null
main_reject 'missing_agent|completed' harness gate REVIEW PASS
wait "$child"
main_run harness spawn-finish "local-$child" completed > /dev/null
main_reject 'missing_agent|closed' harness gate REVIEW PASS
main_run harness spawn-finish "local-$child" completed --closed > /dev/null
main_reject 'missing_review|LGTM' harness gate REVIEW PASS
printf '%s\n' '{"verdict":"LGTM","sha":"stale"}' > "$TEST_ROOT/verdict.json"
main_run harness context put review_verdict "$TEST_ROOT/verdict.json" > /dev/null
main_reject 'missing_review|LGTM' harness gate REVIEW PASS
jq -n --arg sha "$implementation_sha" '{verdict:"LGTM",sha:$sha}' > "$TEST_ROOT/verdict.json"
main_run harness context put review_verdict "$TEST_ROOT/verdict.json" > /dev/null
main_run harness gate REVIEW PASS > /dev/null
cp "$PROJECT/state.json" "$TEST_ROOT/review-checkpoint.json"
main_reject 'QA was removed' harness phase QA
main_reject 'QA was removed' harness qa add greeting PASS 'Actual fixture output equals the acceptance text'
main_reject 'QA was removed' harness gate QA PASS
main_run harness done > /dev/null
main_check '.[0].harness.phase == "DONE" and .[0].harness.metrics.agent_spawns == 3 and
 all(.[0].spawn_reservations[]; .state == "completed" and .closed == true and .agent_id != null)'
# An external commit must make previously valid evidence stale even when it
# bypassed helper invalidation. This is fixture setup, not another gate PASS.
printf '%s\n' '# subsequent external fixture change' >> "$PROJECT/implementation.sh"
git -C "$PROJECT" add implementation.sh
git -C "$PROJECT" commit -qm 'chore: simulate external commit'
main_reject 'stale_evidence|another commit' harness done
main_reject 'missing_agent|missing_review|LGTM' harness gate REVIEW PASS
# Resume a real checkpoint to exercise rework invalidation through public APIs.
cp "$TEST_ROOT/review-checkpoint.json" "$PROJECT/state.json"
main_run harness phase REWORK > /dev/null
main_check '.[0].harness.gates.ANALYSIS.status == "NOT_RUN" and
 .[0].harness.gates.VERIFICATION.status == "NOT_RUN" and .[0].harness.gates.REVIEW.status == "NOT_RUN" and
 .[0].harness.context.review_verdict == null and .[0].harness.context.verification_report == null'
echo 'PASS: confirmed local child lifecycle; RUNNING/DONE and evidence reject unconfirmed workers'
echo 'PASS: commit → analysis → verification; review evidence tied to the current SHA'
echo 'PASS: QA phase/gate/commands rejected; --qa true rejected and --qa false ignored'
echo 'PASS: completion/closure required, stale external commits rejected, rework invalidates evidence'
