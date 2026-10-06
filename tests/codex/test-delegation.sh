#!/usr/bin/env bash
# Local integration fixtures for the sourced delegation module. No network.
# Usage: AGENT=codex|cursor bash tests/codex/test-delegation.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT="${AGENT:-${PLATFORM:-codex}}"
case "$AGENT" in
  codex)
    SRC_SCRIPTS="$ROOT/templates/codex/.codex/scripts"
    SRC_AGENTS="$ROOT/templates/codex/.codex/agents"
    SRC_MODELS="$ROOT/templates/codex/.codex/goal-models.json"
    AGENT_DIR=".codex"
    AGENTS_GLOB="*.toml"
    ;;
  cursor)
    SRC_SCRIPTS="$ROOT/templates/cursor/.cursor/scripts"
    SRC_AGENTS="$ROOT/templates/cursor/.cursor/agents"
    SRC_MODELS="$ROOT/templates/cursor/.cursor/goal-models.json"
    AGENT_DIR=".cursor"
    AGENTS_GLOB="*.md"
    ;;
  *)
    echo "Unknown AGENT=$AGENT (expected codex|cursor)" >&2
    exit 1
    ;;
esac
export TMPDIR="${TMPDIR:-$ROOT/.tmp-tests}"
mkdir -p "$TMPDIR"
TEST_ROOT="$(mktemp -d "$TMPDIR/codex-delegation.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
PROJECT="$TEST_ROOT/project"
mkdir -p "$PROJECT/$AGENT_DIR/scripts" "$PROJECT/$AGENT_DIR/agents" "$TEST_ROOT/bin"
git init -q "$PROJECT"
git -C "$PROJECT" -c user.name=Fixture -c user.email=fixture@example.test -c commit.gpgsign=false commit -qm fixture --allow-empty
git -C "$PROJECT" checkout -qb fixture
printf '%s\n' "$AGENT_DIR/" 'state.json' '.worktrees/' > "$PROJECT/.git/info/exclude"
mkdir -p "$PROJECT/.worktrees"
git -C "$PROJECT" worktree add -q -b issue-one "$PROJECT/.worktrees/issue-one"
git -C "$PROJECT" worktree add -q -b issue-two "$PROJECT/.worktrees/issue-two"
# Forge mocks deliberately fail: these commands should never contact a forge.
for cli in gh glab; do
  printf '%s\n' '#!/usr/bin/env bash' 'echo "Unexpected forge call: $*" >&2' 'exit 97' > "$TEST_ROOT/bin/$cli"
  chmod +x "$TEST_ROOT/bin/$cli"
done
export PATH="$TEST_ROOT/bin:$PATH" GOAL_PLATFORM=github
cp "$SRC_AGENTS/"$AGENTS_GLOB "$PROJECT/$AGENT_DIR/agents/"
cp "$SRC_MODELS" "$PROJECT/$AGENT_DIR/goal-models.json"
cp "$SRC_SCRIPTS/"*.sh "$PROJECT/$AGENT_DIR/scripts/"
# Load real main definitions without its dispatcher; override the four moving
# functions by sourcing the module. This also runs before main wires it in.
python3 - "$SRC_SCRIPTS/goal-git.sh" "$PROJECT/$AGENT_DIR/scripts/fixture.sh" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
marker = '\ncase "${1:-}" in\n'
if marker not in text:
    sys.exit("Cannot locate main dispatcher")
prefix = text.rsplit(marker, 1)[0]
pathlib.Path(sys.argv[2]).write_text(prefix + '''
. "$SCRIPTS_DIR/goal-delegation.sh"
if [ -n "${TEST_SHARED_FILE:-}" ]; then SHARED_STATE_FILE="$TEST_SHARED_FILE"; fi
case "${1:-}" in
  role-completed) shift; harness_role_completed "$@" ;;
  models) shift; cmd_models "$@" ;;
  harness)
    shift
    case "${1:-}" in
      spawn-confirm) shift; cmd_harness_spawn_confirm "$@" ;;
      spawn-fail) shift; cmd_harness_spawn_fail "$@" ;;
      spawn-finish) shift; cmd_harness_spawn_finish "$@" ;;
      *) cmd_harness "$@" ;;
    esac ;;
  *) exit 98 ;;
esac
''')
PY
RUNNER="$PROJECT/$AGENT_DIR/scripts/fixture.sh"
run() { bash "$RUNNER" "$@"; }
check() { jq -e "$1" "$PROJECT/state.json" >/dev/null || { echo "Assertion failed: $1" >&2; exit 1; }; }
reject() {
  local expected="$1"; shift
  if run "$@" > "$TEST_ROOT/rejected.out" 2> "$TEST_ROOT/rejected.err"; then
    echo "Unexpected success: $*" >&2; exit 1
  fi
  [ -n "$expected" ] || return 0
  rg -qi -- "$expected" "$TEST_ROOT/rejected.err" || {
    cat "$TEST_ROOT/rejected.err" >&2; echo "Missing diagnostic: $expected" >&2; exit 1;
  }
}
mutate_fixture() {
  jq "$1" "$PROJECT/state.json" > "$TEST_ROOT/state.tmp"
  mv "$TEST_ROOT/state.tmp" "$PROJECT/state.json"
}
reset_fixture() { cp "$TEST_ROOT/baseline.json" "$PROJECT/state.json"; }
id_of() { jq -er '.reservation.id' "$1"; }
reserve() { run harness spawn "$@" > "$TEST_ROOT/reserved.json"; id_of "$TEST_ROOT/reserved.json"; }

printf '%s\n' '{"concurrency":2,"platform":"github"}' > "$PROJECT/$AGENT_DIR/goal-config.json"
printf '%s\n' '[{"goal":"Delegation fixture","branch":"fixture","status":"active","issue":{"number":1}}]' > "$PROJECT/state.json"
run harness init --complexity NORMAL --route feature --qa false --visual false > "$TEST_ROOT/init.json"
# Only assignment/phase fixtures are seeded. No gate is ever forged to PASS.
mutate_fixture '.[0].harness.phase = "BUILDING" | .[0].harness.tasks = [
 {id:"t1",role:"builder",title:"one",state:"PENDING",attempts:0},
 {id:"t2",role:"builder",title:"two",state:"PENDING",attempts:0}]
 | .[0].harness.budget.max_total_spawns = 4'
cp "$PROJECT/state.json" "$TEST_ROOT/baseline.json"
# Cursor routing uses inherit; Codex uses catalog models from goal-models.json.
BUILDER="$(jq -r '."$routing".builder.NORMAL.model' "$PROJECT/$AGENT_DIR/goal-models.json")"

# Reservations do not count; definitive failure/recovery makes retries safe.
id="$(reserve builder "$BUILDER" medium --task t1)"
check '.[0].harness.metrics.agent_spawns == 0 and .[0].harness.metrics.builder_runs == 0 and
 .[0].harness.tasks[0].state == "SPAWNING" and .[0].spawn_reservations[0].state == "pending"'
jq -e '.reservation | .role == "builder" and .model != null and .effort == "medium" and .task == "t1" and .phase == "BUILDING"' "$TEST_ROOT/reserved.json" >/dev/null
reject 'already|Parallel builders' harness spawn builder "$BUILDER" medium --task t1
run harness spawn-fail "$id" unsupported 'launch schema unavailable' > /dev/null
check '.[0].harness.tasks[0].blocker_kind == "spawn" and .[0].harness.metrics.agent_spawns == 0'
run harness spawn-fail "$id" unsupported 'launch schema unavailable' > /dev/null
run harness recover-spawn > /dev/null
check '.[0].harness.tasks[0].state == "PENDING" and .[0].harness.phase == "BUILDING"'
id2="$(reserve builder "$BUILDER" high --task t1)"
reject '' role-completed builder
run harness spawn-confirm "$id2" agent-one > "$TEST_ROOT/confirmed.json"
reject '' role-completed builder
run harness spawn-confirm "$id2" agent-one > /dev/null
check '.[0].harness.metrics.agent_spawns == 1 and .[0].harness.metrics.builder_runs == 1 and
 .[0].harness.tasks[0].state == "RUNNING" and .[0].harness.tasks[0].attempts == 1 and
 .[0].harness.tasks[0].agent_id == "agent-one"'
reject 'another agent ID' harness spawn-confirm "$id2" agent-other
reject 'Confirmed agent' harness spawn-fail "$id2" rejected 'too late'
reject 'Parallel builders' harness spawn builder "$BUILDER" medium --task t2
run harness recover-spawn > /dev/null
check '.[0].harness.tasks[0].state == "RUNNING"'
run harness spawn-finish agent-one completed > /dev/null
reject '' role-completed builder
run harness spawn-finish agent-one completed --closed > /dev/null
run role-completed builder
run harness spawn-finish agent-one completed > /dev/null
run harness spawn-confirm "$id2" agent-one > /dev/null
check '.[0].harness.metrics.agent_spawns == 1 and .[0].harness.tasks[0].state == "DONE" and
 .[0].spawn_reservations[1].closed == true'
mutate_fixture '.[0].harness.counters.rework += 1'
reject '' role-completed builder
mutate_fixture '.[0].harness.counters.rework -= 1'
reject 'different status' harness spawn-finish agent-one failed
reject 'released' harness spawn-confirm "$id" ghost
reject 'Unknown reservation' harness spawn-confirm does-not-exist ghost
reject 'Unknown reservation' harness spawn-fail does-not-exist rejected nope
reject 'Unknown confirmed agent' harness spawn-finish ghost completed
printf '%s\n' 'PASS: reserve/fail/retry, confirmation idempotency, lifecycle and unknown IDs'

# An uncertain launch blocks all new launches and recovery, and holds budget.
reset_fixture
id="$(reserve builder "$BUILDER" medium --task t1)"
run harness spawn-fail "$id" uncertain 'tool timed out without an agent ID' > /dev/null 2> "$TEST_ROOT/uncertain.err"
rg -q 'stop and reconcile' "$TEST_ROOT/uncertain.err"
check '.[0].spawn_reservations[0].state == "uncertain" and .[0].spawn_reservations[0].closed == false and .[0].harness.metrics.agent_spawns == 0'
reject 'Uncertain launch' harness spawn builder "$BUILDER" medium --task t2
reject 'Uncertain launch' harness recover-spawn
run harness spawn-confirm "$id" late-agent > /dev/null
check '.[0].harness.tasks[0].state == "RUNNING" and .[0].harness.metrics.agent_spawns == 1'
run harness spawn-finish late-agent failed --closed > /dev/null
reject '' role-completed builder
run harness recover-spawn > /dev/null
check '.[0].harness.tasks[0].state == "FAILED" and .[0].harness.metrics.agent_spawns == 1'
reset_fixture
id="$(reserve builder "$BUILDER" medium --task t1)"
run harness spawn-fail "$id" uncertain 'unknown' > /dev/null 2>&1
run harness spawn-fail "$id" rejected 'verified no child launched' > /dev/null
run harness recover-spawn > /dev/null
check '.[0].harness.tasks[0].state == "PENDING" and .[0].spawn_reservations[0].closed == true'
printf '%s\n' 'PASS: uncertain outcomes stop duplicates and require explicit reconciliation'

# A recorded launch failure restores the actual pre-launch phase only.
reset_fixture
mutate_fixture '.[0].harness.phase = "REVIEWING"'
id="$(reserve reviewer "$BUILDER" medium)"
run harness spawn-fail "$id" unsupported 'reviewer launch rejected' > /dev/null
mutate_fixture '.[0].harness.phase = "FAILED" | .[0].harness.tasks += [
 {id:"t3",role:"builder",state:"BLOCKED",blocker_kind:"dependencies"},
 {id:"t4",role:"builder",state:"FAILED"},
 {id:"t5",role:"builder",state:"BLOCKED",blocker_kind:"spawn"},
 {id:"t6",role:"builder",state:"SPAWNING"}]'
run harness recover-spawn > /dev/null
check '.[0].harness.phase == "FAILED" and .[0].harness.tasks[2].state == "BLOCKED" and
 .[0].harness.tasks[3].state == "FAILED" and .[0].harness.tasks[4].state == "PENDING" and .[0].harness.tasks[5].state == "PENDING"'
mutate_fixture '.[0].harness.tasks = .[0].harness.tasks[0:2]'
run harness recover-spawn > /dev/null
check '.[0].harness.phase == "REVIEWING"'
reset_fixture
mutate_fixture '.[0].harness.phase = "FAILED"'
run harness recover-spawn > /dev/null
check '.[0].harness.phase == "FAILED"'
reset_fixture
id="$(reserve builder "$BUILDER" medium --task t1)"
run harness recover-spawn > /dev/null
check '.[0].harness.tasks[0].state == "SPAWNING" and .[0].spawn_reservations[0].state == "pending"'
printf '%s\n' 'PASS: recovery preserves real failures and pending launches, restores prior phase'

# Total, role, required-review and confirmed counters remain hard limits.
reset_fixture
mutate_fixture '.[0].harness.budget.max_total_spawns = 1'
id="$(reserve builder "$BUILDER" medium --task t1)"
run harness spawn-confirm "$id" budget-agent > /dev/null
run harness spawn-finish budget-agent completed --closed > /dev/null
reject 'Spawn budget exceeded' harness spawn builder "$BUILDER" medium --task t2
check '.[0].harness.budget.max_total_spawns == 1 and .[0].harness.metrics.agent_spawns == 1'
reset_fixture
mutate_fixture '.[0].harness.requirements.qa = true | .[0].harness.requirements.visual = true | .[0].harness.budget.max_total_spawns = 2'
reject 'required QA/Visual' harness spawn builder "$BUILDER" medium --task t1
check '.[0].harness.metrics.agent_spawns == 0 and (.[0].spawn_reservations // [] | length) == 0'
reset_fixture
mutate_fixture '.[0].harness.phase = "REVIEWING" | .[0].harness.budget.max_reviewer_runs = 1'
id="$(reserve reviewer "$BUILDER" medium)"
run harness spawn-confirm "$id" reviewer-once > /dev/null
run harness spawn-finish reviewer-once completed --closed > /dev/null
reject 'role budget exceeded' harness spawn reviewer "$BUILDER" medium
check '.[0].harness.budget.max_reviewer_runs == 1 and .[0].harness.metrics.reviewer_runs == 1'
reset_fixture
mutate_fixture '.[0].harness.phase = "VERIFYING"'
reject 'Spawn rejected' harness spawn builder "$BUILDER" medium --task t1
printf '%s\n' 'PASS: cumulative budgets, required QA/Visual slots and phase gates are enforced'

# Shared-state global concurrency covers issues and inactive group ledgers.
reset_fixture
mutate_fixture '.[0].harness.phase = "REVIEWING" | .[0].branch = "issue-one" | .[0].worktree = ".worktrees/issue-one" |
 . + [(.[0] | .id = "goal-issue-two" | .issue.number = 2 | .branch = "issue-two" | .worktree = ".worktrees/issue-two") ]'
export GOAL_ISSUE=1
id="$(reserve reviewer "$BUILDER" medium)"
run harness spawn-confirm "$id" shared-one > /dev/null
export GOAL_ISSUE=2
id2="$(reserve reviewer "$BUILDER" medium)"
reject 'already belongs' harness spawn-confirm "$id2" shared-one
reject 'Global concurrency' harness spawn reviewer "$BUILDER" medium
run harness spawn-fail "$id2" rejected 'second launch denied' > /dev/null
run harness recover-spawn > /dev/null
id2="$(reserve reviewer "$BUILDER" medium)"
run harness spawn-confirm "$id2" shared-two > /dev/null
run harness spawn-finish shared-two completed > /dev/null
reject 'Global concurrency' harness spawn reviewer "$BUILDER" medium
run harness spawn-finish shared-two completed --closed > /dev/null
# Select a local stale file but explicitly point delegation at shared state.
cp "$PROJECT/state.json" "$TEST_ROOT/shared-state.json"
export SHARED_STATE_FILE="$TEST_ROOT/shared-state.json" TEST_SHARED_FILE="$TEST_ROOT/shared-state.json"
id3="$(reserve reviewer "$BUILDER" medium)"
jq -e --arg id "$id3" '.[1].spawn_reservations | any(.id == $id)' "$SHARED_STATE_FILE" >/dev/null
check '.[1].spawn_reservations | length == 2'
run harness spawn-fail "$id3" rejected 'fixture done' > /dev/null
unset SHARED_STATE_FILE TEST_SHARED_FILE GOAL_ISSUE
reset_fixture
mutate_fixture '.[0].harness.phase = "REVIEWING" | .[0].active_group_id = "g1" |
 .[0].delivery_groups = [{id:"g1",harness:{}},{id:"g2",harness:{}}]'
id="$(reserve reviewer "$BUILDER" medium)"
check '.[0].delivery_groups[0].harness.spawn_reservations[0].state == "pending"'
run harness spawn-confirm "$id" group-agent > /dev/null
# Activate a distinct fixture harness to emulate MAIN switching groups.
mutate_fixture '.[0].active_group_id = "g2" | .[0].harness.spawn_reservations = [] | .[0].harness.metrics.reviewer_runs = 0 | .[0].harness.metrics.agent_spawns = 0'
id2="$(reserve reviewer "$BUILDER" medium)"
reject 'Global concurrency' harness spawn reviewer "$BUILDER" medium
reject 'another delivery group' harness spawn-confirm "$id" group-agent
check '.[0].delivery_groups[0].harness.metrics.agent_spawns == 1 and .[0].delivery_groups[1].harness.spawn_reservations[0].state == "pending"'
printf '%s\n' 'PASS: global concurrency, shared file selection, agent uniqueness and group mirrors'

# Explicit GOAL_GROUP projects an inactive group. Its view must never alias the
# shared input, and the locked merger must preserve the durable root ledger.
reset_fixture
mkdir -p "$PROJECT/.worktrees"
git -C "$PROJECT" worktree add -q -b fixture-g1 "$PROJECT/.worktrees/g1"
git -C "$PROJECT" worktree add -q -b fixture-g2 "$PROJECT/.worktrees/g2"
mutate_fixture '.[0] as $g | .[0] += {active_group_id:"g1",branch:"fixture-g1",worktree:".worktrees/g1"} |
 .[0].delivery_groups = [
  {id:"g1",branch:"fixture-g1",worktree:".worktrees/g1",harness:$g.harness},
  {id:"g2",branch:"fixture-g2",worktree:".worktrees/g2",harness:($g.harness | .phase = "REVIEWING")}]'
export GOAL_GROUP=g2 GOAL_ISSUE=1
id="$(reserve reviewer "$BUILDER" medium)"
check '.[0].active_group_id == "g1" and .[0].branch == "fixture-g1" and
 .[0].harness.metrics.agent_spawns == 0 and .[0].spawn_reservations[0].group_id == "g2" and
 .[0].delivery_groups[1].harness.spawn_reservations[0].state == "pending"'
run harness spawn-confirm "$id" projected-reviewer > /dev/null
check '.[0].spawn_reservations[0].agent_id == "projected-reviewer" and
 .[0].delivery_groups[1].harness.metrics.reviewer_runs == 1 and .[0].harness.metrics.reviewer_runs == 0'
run harness spawn-finish projected-reviewer completed --closed > /dev/null
run role-completed reviewer
mutate_fixture '.[0].delivery_groups[1].harness.phase = "BUILDING"'
id2="$(reserve builder "$BUILDER" medium --task t1)"
export GOAL_GROUP=g1
id3="$(reserve builder "$BUILDER" medium --task t1)"
reject 'Global concurrency' harness spawn builder "$BUILDER" medium --task t2
reject 'another delivery group' harness spawn-confirm "$id2" wrong-group
run harness spawn-confirm "$id3" projected-g1 > /dev/null
export GOAL_GROUP=g2
run harness spawn-confirm "$id2" projected-g2 > /dev/null
check '.[0].active_group_id == "g1" and .[0].harness.tasks[0].agent_id == "projected-g1" and
 .[0].delivery_groups[1].harness.tasks[0].agent_id == "projected-g2" and
 (.[0].spawn_reservations | length) == 3'
run harness spawn-finish projected-g2 completed --closed > /dev/null
export GOAL_GROUP=g1
run harness spawn-finish projected-g1 completed --closed > /dev/null
unset GOAL_GROUP GOAL_ISSUE
printf '%s\n' 'PASS: inactive group projection preserves shared state, root ledger and active overlay'

# Composable routing: routed/legacy chains, intrinsic vision and effort remain TSV.
cp "$PROJECT/$AGENT_DIR/goal-models.json" "$TEST_ROOT/original-models.json"
cat > "$PROJECT/$AGENT_DIR/goal-models.json" <<'JSON'
{
 "$capabilities":{"vision_models":["vision-one","vision-two"]},
 "$routing":{
  "builder":{"NORMAL":{"model":"text-one","effort":"high","fallback_models":["vision-one","text-two"]}},
  "visual-reviewer":{"NORMAL":{"model":"text-one","effort":"high","fallback_models":["vision-one"]}},
  "custom":{"NORMAL":{"model":"text-one","fallback_models":[{"model":"vision-one","effort":"low"}]}}
 },
 "builder":{"model":"legacy-text","effort":"low","fallback_models":["text-two","vision-two"]},
 "visual-reviewer":{"fallback_models":["vision-two"]},
 "custom":{"capabilities":{"multimodal":true}},
 "legacy":{"model":"text-one","effort":"low","fallback_models":["vision-one","vision-two"]}
}
JSON
expect_models() {
  local expected="$1"; shift
  run models "$@" > "$TEST_ROOT/model.out" 2> "$TEST_ROOT/model.err"
  [ "$(cat "$TEST_ROOT/model.out")" = "$expected" ] || {
    cat "$TEST_ROOT/model.out" >&2; echo "Wrong model tuple for $*" >&2; exit 1;
  }
  # Verify all three fields including an empty fallback field.
  awk -F '\t' 'NF != 3 {exit 1}' "$TEST_ROOT/model.out"
}
expect_models $'text-one\thigh\tvision-one,text-two,vision-two' builder --complexity NORMAL
expect_models $'vision-one\thigh\tvision-two' builder --complexity NORMAL --require-multimodal
rg -q 'configured fallback' "$TEST_ROOT/model.err"
expect_models $'vision-two\thigh\t' builder --require-multimodal --next vision-one --complexity NORMAL
expect_models $'vision-two\thigh\t' builder --next vision-one --complexity NORMAL --require-multimodal vision-one
expect_models $'vision-one\thigh\tvision-two' visual-reviewer --complexity NORMAL
expect_models $'vision-two\thigh\t' visual-reviewer --complexity NORMAL --next vision-one
expect_models $'vision-one\tlow\t' custom --complexity NORMAL
expect_models $'text-one\tlow\tvision-one,vision-two' legacy --complexity COMPLEX
expect_models $'vision-two\tlow\t' legacy --require-multimodal vision-one --next vision-one --complexity COMPLEX
reject 'outside the authorized' models builder --require-multimodal unauthorized
reject 'No eligible' models visual-reviewer --next vision-two
reject 'conflicts' models builder --require-multimodal vision-one --next text-one
reject 'requires' models builder --next
reject 'Invalid complexity' models builder --complexity HUGE
reject 'Unknown models argument' models builder --unknown
cp "$TEST_ROOT/original-models.json" "$PROJECT/$AGENT_DIR/goal-models.json"
if run models planner --complexity TRIVIAL > /dev/null 2>&1; then exit 1; else rc=$?; test "$rc" = 2; fi
expect_models "$(printf '%s\tmedium\t' "$BUILDER")" visual-reviewer --complexity NORMAL --require-multimodal
printf '%s\n' 'PASS: routing/legacy fallback chains, composable multimodal/next flags and consistent TSV'

# Role config is parsed; custom roles supported. Codex rejects TOML pins; Cursor
# allows frontmatter model pins (session/frontmatter owns the real model).
reset_fixture
if [ "$AGENT" = cursor ]; then
  cat > "$PROJECT/$AGENT_DIR/agents/custom.md" <<'MD'
---
name: custom
description: Fixture custom role
mode: subagent
model: inherit
---

Perform only the assigned fixture task.
MD
  jq --arg model "$BUILDER" '.custom = {model:$model,effort:"medium"}' "$PROJECT/$AGENT_DIR/goal-models.json" > "$TEST_ROOT/models.tmp"
  mv "$TEST_ROOT/models.tmp" "$PROJECT/$AGENT_DIR/goal-models.json"
  id="$(reserve custom "$BUILDER" medium)"
  run harness spawn-confirm "$id" custom-agent > /dev/null
  check '.[0].harness.metrics.custom_runs == 1'
  run harness spawn-finish custom-agent completed --closed > /dev/null
  printf '%s\n' '---' 'name: different' '---' 'ok' > "$PROJECT/$AGENT_DIR/agents/custom.md"
  reject 'name must match' harness spawn custom "$BUILDER" medium
  printf '%s\n' '---' 'name: custom' '---' > "$PROJECT/$AGENT_DIR/agents/custom.md"
  reject 'body after frontmatter must be nonempty' harness spawn custom "$BUILDER" medium
  printf '%s\n' 'name: custom' 'no delimiters' > "$PROJECT/$AGENT_DIR/agents/custom.md"
  reject 'Invalid role markdown' harness spawn custom "$BUILDER" medium
else
  cat > "$PROJECT/$AGENT_DIR/agents/custom.toml" <<'TOML'
name = "custom"
developer_instructions = "Perform only the assigned fixture task."
TOML
  jq --arg model "$BUILDER" '.custom = {model:$model,effort:"medium"}' "$PROJECT/$AGENT_DIR/goal-models.json" > "$TEST_ROOT/models.tmp"
  mv "$TEST_ROOT/models.tmp" "$PROJECT/$AGENT_DIR/goal-models.json"
  id="$(reserve custom "$BUILDER" medium)"
  run harness spawn-confirm "$id" custom-agent > /dev/null
  check '.[0].harness.metrics.custom_runs == 1'
  run harness spawn-finish custom-agent completed --closed > /dev/null
  printf '%s\n' 'model = "hidden-pin"' >> "$PROJECT/$AGENT_DIR/agents/custom.toml"
  reject 'conflicts with runtime routing' harness spawn custom "$BUILDER" medium
  printf '%s\n' 'name = "different"' 'developer_instructions = "ok"' > "$PROJECT/$AGENT_DIR/agents/custom.toml"
  reject 'name must match' harness spawn custom "$BUILDER" medium
  printf '%s\n' 'name = "custom"' > "$PROJECT/$AGENT_DIR/agents/custom.toml"
  reject 'developer_instructions' harness spawn custom "$BUILDER" medium
  printf '%s\n' 'name = "custom"' 'invalid [ TOML' > "$PROJECT/$AGENT_DIR/agents/custom.toml"
  reject 'Invalid role TOML' harness spawn custom "$BUILDER" medium
fi
reject 'Invalid role name' harness spawn ../builder "$BUILDER" medium
reject 'outside the authorized' harness spawn builder unapproved-model medium --task t1
reject 'Invalid effort' harness spawn builder "$BUILDER" nonsense --task t1
reset_fixture
mutate_fixture '.[0].harness.phase = "VISUAL_REVIEW"'
reject 'outside the authorized|vision-capable' harness spawn visual-reviewer gpt-5.6-sol medium
id="$(reserve visual-reviewer "$BUILDER" medium)"
check '.[0].harness.metrics.visual_runs == 0'
run harness spawn-confirm "$id" visual-agent > /dev/null
check '.[0].harness.metrics.visual_runs == 1'
printf '%s\n' 'PASS: custom role config, conflicting pins, explicit model/effort and intrinsic visual capability'

# Two simultaneous callers compete under the real main shared state lock.
reset_fixture
mutate_fixture '.[0].harness.phase = "REVIEWING" | .[0].harness.budget.max_total_spawns = 1'
set +e
run harness spawn reviewer "$BUILDER" medium > "$TEST_ROOT/race1.out" 2> "$TEST_ROOT/race1.err" & p1=$!
run harness spawn reviewer "$BUILDER" medium > "$TEST_ROOT/race2.out" 2> "$TEST_ROOT/race2.err" & p2=$!
wait "$p1"; r1=$?
wait "$p2"; r2=$?
set -e
if [ "$r1" -eq 0 ]; then test "$r2" -ne 0; else test "$r2" -eq 0; fi
check '.[0].spawn_reservations | length == 1'
check '.[0].harness.metrics.agent_spawns == 0'
printf '%s\n' 'PASS: concurrent reservation race accepts exactly one launch'

# Legal phase auto-advance on spawn (researcher from PLANNED → RESEARCHING).
reset_fixture
mutate_fixture '.[0].harness.phase = "PLANNED" | .[0].harness.budget.max_researcher_runs = 2'
RESEARCHER="$(jq -r '."$routing".researcher.NORMAL.model' "$PROJECT/$AGENT_DIR/goal-models.json")"
id="$(reserve researcher "$RESEARCHER" medium)"
check '.[0].harness.phase == "RESEARCHING"'
jq -e --arg id "$id" '.reservation.phase == "RESEARCHING"' "$TEST_ROOT/reserved.json" >/dev/null
printf '%s\n' 'PASS: spawn auto-advances legal phase for researcher'

# harness brief writes a readable file
reset_fixture
brief_path="$(run harness brief builder --task t1)"
test -f "$brief_path"
rg -q "GOAL_TASK='t1'" "$brief_path"
rg -q 'TARGET_WORKTREE' "$brief_path"
printf '%s\n' 'PASS: harness brief writes worker brief file'

printf '%s\n' "PASS: delegation fixture suite (AGENT=$AGENT)"
