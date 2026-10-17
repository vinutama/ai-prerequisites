#!/usr/bin/env bash
# Regression fixtures for goal-workflow stalls: spawn budgets that grow in rework,
# actionable errors, recoverable phases/tasks, stale reservations, hung checks,
# resume edge cases and forge ledgers. Local only: no network, no real forge.
# Usage: AGENT=codex|cursor|claude bash tests/codex/test-stall-recovery.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT="${AGENT:-${PLATFORM:-codex}}"
case "$AGENT" in
  codex)  AGENT_DIR=.codex;  AGENTS_GLOB='*.toml' ;;
  cursor) AGENT_DIR=.cursor; AGENTS_GLOB='*.md' ;;
  claude) AGENT_DIR=.claude; AGENTS_GLOB='*.md' ;;
  *) echo "Unknown AGENT=$AGENT (expected codex|cursor|claude)" >&2; exit 1 ;;
esac
SRC="$ROOT/templates/$AGENT/$AGENT_DIR"
export TMPDIR="${TMPDIR:-$ROOT/.tmp-tests}"
mkdir -p "$TMPDIR"
TEST_ROOT="$(mktemp -d "$TMPDIR/stall-recovery.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
PROJECT="$TEST_ROOT/project"
mkdir -p "$PROJECT/$AGENT_DIR/scripts" "$PROJECT/$AGENT_DIR/agents" "$TEST_ROOT/bin"
git init -q -b fixture "$PROJECT"
git -C "$PROJECT" config user.name Fixture
git -C "$PROJECT" config user.email fixture@example.test
printf 'seed\n' > "$PROJECT/README.md"
printf '%s/\nstate.json\n.worktrees/\n' "$AGENT_DIR" > "$PROJECT/.gitignore"
git -C "$PROJECT" add README.md .gitignore
git -C "$PROJECT" commit -qm seed
cp "$SRC/scripts/"*.sh "$PROJECT/$AGENT_DIR/scripts/"
cp "$SRC/agents/"$AGENTS_GLOB "$PROJECT/$AGENT_DIR/agents/"
cp "$SRC/goal-models.json" "$PROJECT/$AGENT_DIR/goal-models.json"
for cli in gh glab; do
  printf '%s\n' '#!/usr/bin/env bash' 'echo "Unexpected forge call: $*" >&2' 'exit 97' > "$TEST_ROOT/bin/$cli"
  chmod +x "$TEST_ROOT/bin/$cli"
done
export PATH="$TEST_ROOT/bin:$PATH" GOAL_PLATFORM=github
unset GOAL_ID GOAL_RUN_ID GOAL_ISSUE GOAL_GROUP GOAL_TASK GOAL_REPO GOAL_ISSUE_REPO
G="$PROJECT/$AGENT_DIR/scripts/goal-git.sh"
STATE="$PROJECT/state.json"
CONFIG="$PROJECT/$AGENT_DIR/goal-config.json"
BUILDER="$(jq -r '."$routing".builder.NORMAL.model' "$PROJECT/$AGENT_DIR/goal-models.json")"
REVIEWER="$(jq -r '."$routing".reviewer.NORMAL.model' "$PROJECT/$AGENT_DIR/goal-models.json")"

pass() { printf 'PASS: %s\n' "$*"; }
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
g() { "$G" "$@"; }
check() { jq -e "$1" "$STATE" >/dev/null || { echo "Assertion failed: $1" >&2; jq . "$STATE" >&2; exit 1; }; }
mutate() { jq "$1" "$STATE" > "$TEST_ROOT/state.tmp" && mv "$TEST_ROOT/state.tmp" "$STATE"; }
# reject <regex> <cmd...>: command must fail and its stderr must match.
reject() {
  local expected="$1"; shift
  if "$@" > "$TEST_ROOT/rej.out" 2> "$TEST_ROOT/rej.err"; then
    echo "Unexpected success: $*" >&2; exit 1
  fi
  grep -Eqi -- "$expected" "$TEST_ROOT/rej.err" || { cat "$TEST_ROOT/rej.err" >&2; die "missing diagnostic /$expected/ for: $*"; }
}
fresh_goal() {
  jq -n --arg platform "$AGENT" '[{id:"goal-fixture",agent_platform:$platform,goal:"Stall fixture",branch:"fixture",
    base_branch:"main",status:"in_progress",platform:"github",repos:[{path:".",pr_number:null,pr_url:""}],
    source:{type:"prompt",title:"t",body:"b",reference:"",acceptance_criteria:[]}}]' > "$STATE"
  printf '%s\n' '{"platform":"github","concurrency":4}' > "$CONFIG"
  g harness init --route backend --complexity NORMAL --visual false >/dev/null 2>&1
}
reserve() { g harness spawn "$@" 2>/dev/null | jq -r .reservation.id; }

# --- unknown commands fail loudly; run-id exists; config put works ------------
reject 'Unknown command' g definitely-not-a-command
set +e; g definitely-not-a-command >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 2 ] || die "unknown command must exit 2 (got $rc)"
g help | grep -q 'harness reap' || die "help lists harness reap"
[ -n "$(g run-id)" ] || die "run-id prints an id"
fresh_goal
g config put verify_timeout 7
g config put verify_cmd 'echo ok'
jq -e '.verify_timeout == 7 and .verify_cmd == "echo ok"' "$CONFIG" >/dev/null
pass "unknown command exits 2; run-id and config put exist"

# --- default error text no longer tells the model to stop ---------------------
GOAL_TASK=nope reject 'fix the named cause' g context
if grep -q 'preserve state and stop' "$TEST_ROOT/rej.err"; then die "default corrective action still says stop"; fi
mutate '.[0].harness.tasks = [{id:"t1",role:"builder",title:"one",state:"DONE",attempts:1}]'
reject 'spawn-confirm.*spawn-finish|task retry' g harness gate IMPLEMENTATION PASS
pass "errors carry concrete corrective actions"

# --- spawn budgets grow within max_rework; the cap error names the command ----
fresh_goal
mutate '.[0].harness.phase = "BUILDING" | .[0].harness.counters.rework = 1
  | .[0].harness.budget.max_total_spawns = 2 | .[0].harness.metrics.agent_spawns = 2
  | .[0].harness.tasks = [{id:"t1",role:"builder",title:"fix",state:"PENDING",attempts:0}]'
id="$(reserve builder "$BUILDER" medium --task t1)"
[ -n "$id" ] || die "builder reservation in rework should have been granted"
check '.[0].harness.budget.max_total_spawns == 3 and any(.[0].harness.events[]; .event == "budget_grow")'
mutate '.[0].harness.phase = "REVIEWING" | .[0].harness.budget.max_reviewer_runs = 1 | .[0].harness.metrics.reviewer_runs = 1
  | .[0].harness.spawn_reservations = [] | .[0].spawn_reservations = [] | .[0].harness.budget.max_total_spawns = 9'
git -C "$PROJECT" commit -q --allow-empty -m "impl"
id="$(reserve reviewer "$REVIEWER" medium)"
[ -n "$id" ] || die "reviewer re-review should grow its cap"
check '.[0].harness.budget.max_reviewer_runs == 2'
# Beyond max_rework the loop is over: hard cap, with the exact command to raise it.
mutate '.[0].harness.phase = "BUILDING" | .[0].harness.counters.rework = 9 | .[0].harness.limits.max_rework = 3
  | .[0].harness.spawn_reservations = [] | .[0].spawn_reservations = []
  | .[0].harness.budget.max_total_spawns = 2 | .[0].harness.metrics.agent_spawns = 2
  | .[0].harness.tasks = [{id:"t1",role:"builder",title:"fix",state:"PENDING",attempts:0}]'
reject 'harness budget set max_total_spawns 3' g harness spawn builder "$BUILDER" medium --task t1
pass "builder/reviewer caps grow in rework; hard cap names harness budget set"

# --- wrong-phase spawn names the rework path ------------------------------------
fresh_goal
mutate '.[0].harness.phase = "VERIFYING"'
reject 'harness phase REWORK' g harness spawn builder "$BUILDER" medium --task t1
pass "spawn from VERIFYING points at harness phase REWORK"

# --- FAILED and DONE are recoverable ---------------------------------------------
fresh_goal
mutate '.[0].harness.phase = "FAILED" | .[0].harness.blocker = {kind:"retry_budget"}'
g harness phase REWORK >/dev/null 2>&1
check '.[0].harness.phase == "REWORK" and (.[0].harness.blocker == null)'
mutate '.[0].harness.phase = "DONE"'
g harness phase REWORK >/dev/null 2>&1
check '.[0].harness.phase == "REWORK"'
mutate '.[0].harness.phase = "RESEARCHING"'
g harness phase PLANNED >/dev/null 2>&1
check '.[0].harness.phase == "PLANNED"'
reject 'legal next phases' g harness phase VERIFYING
mutate '.[0].harness.limits.max_rework = 1 | .[0].harness.counters.rework = 1'
reject 'harness limit set max_rework' g harness retry rework
check '.[0].harness.phase == "FAILED"'
g harness limit set max_rework 5 >/dev/null 2>&1
check '.[0].harness.limits.max_rework == 5'
pass "FAILED/DONE -> REWORK, RESEARCHING -> PLANNED, retry limit has a way out"

# --- task retry / cancel ----------------------------------------------------------
fresh_goal
mutate '.[0].harness.phase = "BUILDING"
  | .[0].harness.tasks = [{id:"t1",role:"builder",title:"one",state:"PENDING",attempts:0},
                          {id:"t2",role:"builder",title:"two",state:"PENDING",attempts:0}]'
id="$(reserve builder "$BUILDER" medium --task t1)"
g harness spawn-confirm "$id" agent-lost >/dev/null 2>&1
mutate '.[0].harness.tasks[0].state = "FAILED"'
reject 'harness task retry t1' g harness spawn builder "$BUILDER" medium --task t1
g harness task retry t1 "agent crashed" >/dev/null 2>&1
check '.[0].harness.tasks[0].state == "PENDING" and (.[0].harness.tasks[0] | has("agent_id") | not)
  and (.[0].spawn_reservations[0].closed == true)'
id="$(reserve builder "$BUILDER" medium --task t1)"
[ -n "$id" ] || die "re-spawn after task retry"
g harness spawn-confirm "$id" agent-two >/dev/null 2>&1
g harness spawn-finish agent-two completed --closed >/dev/null 2>&1
g harness task set t1 DONE >/dev/null 2>&1
g harness task cancel t2 "superseded" >/dev/null 2>&1
check '.[0].harness.tasks[1].state == "CANCELLED"'
reject 'already CANCELLED' g harness task cancel t2
reject 'already DONE' g harness task retry t1
mutate '.[0].harness.gates.ANALYSIS = {status:"PASS"}'
g harness phase VERIFYING >/dev/null 2>&1
check '.[0].harness.phase == "VERIFYING"'
mutate '.[0].harness.phase = "REVIEWING" | .[0].harness.requirements.reviewer = false | .[0].harness.requirements.planner = false
  | .[0].harness.spawn_reservations = (.[0].harness.spawn_reservations // [])'
pass "task retry releases the dead agent; cancelled tasks do not block VERIFYING"

# --- harness reap: reservations of a dead session ----------------------------------
fresh_goal
mutate '.[0].harness.phase = "BUILDING"
  | .[0].harness.tasks = [{id:"t1",role:"builder",title:"one",state:"PENDING",attempts:0}]'
id="$(reserve builder "$BUILDER" medium --task t1)"
g harness spawn-confirm "$id" dead-session-agent >/dev/null 2>&1
# Another platform's leftover uncertain launch must not block this platform.
OTHER=codex; [ "$AGENT" != codex ] || OTHER=cursor
mutate --arg other "$OTHER" '.' 2>/dev/null || true
jq --arg other "$OTHER" '. + [{id:"other-goal",agent_platform:$other,status:"in_progress",
  spawn_reservations:[{id:"spawn-other",state:"uncertain",role:"builder",group_id:null,created_at:"2020-01-01T00:00:00+00:00",closed:false}]}]' "$STATE" > "$TEST_ROOT/state.tmp"
mv "$TEST_ROOT/state.tmp" "$STATE"
export GOAL_ID=goal-fixture
mutate '.[0].harness.tasks[0].state = "RUNNING"'
reject 'harness reap' g harness spawn builder "$BUILDER" medium --task t1
g harness reap > "$TEST_ROOT/reap.json"
jq -e --arg id "$id" '.reaped | index($id) != null' "$TEST_ROOT/reap.json" >/dev/null
check '.[0].harness.tasks[0].state == "PENDING" and .[0].spawn_reservations[0].state == "failed"
  and .[0].spawn_reservations[0].closed == true and (.[1].spawn_reservations[0].state == "uncertain")'
id2="$(reserve builder "$BUILDER" medium --task t1)"
[ -n "$id2" ] || die "spawn after reap (and with another platform's uncertain leftover)"
g harness reap >/dev/null 2>&1
check '.[0].spawn_reservations[1].state == "failed"'
unset GOAL_ID
pass "reap frees the dead session's reservations; other platforms do not block"

# --- continue: stale summary, null branch, no-selector choice ---------------------
fresh_goal
export GOAL_ID=goal-fixture
mutate '.[0].harness.phase = "BUILDING"
  | .[0].harness.tasks = [{id:"t1",role:"builder",title:"one",state:"PENDING",attempts:0}]'
id="$(reserve builder "$BUILDER" medium --task t1)"
unset GOAL_ID
g continue > /dev/null 2> "$TEST_ROOT/continue.err" || { cat "$TEST_ROOT/continue.err" >&2; die "continue with a held reservation"; }
grep -q 'harness reap' "$TEST_ROOT/continue.err" || die "continue suggests harness reap"
jq -n --arg p "$AGENT" '[
  {id:"goal-done",agent_platform:$p,goal:"old",branch:"fixture",base_branch:"main",status:"completed",repos:[{path:".",pr_number:null}]},
  {id:"goal-multi",agent_platform:$p,goal:"multi",branch:null,status:"in_progress",delivery_mode:"multi-pr",delivery_groups:[]},
  {id:"goal-open",agent_platform:$p,goal:"open",branch:"fixture",base_branch:"main",status:"in_progress",repos:[{path:".",pr_number:null}]},
  {id:"goal-queue",kind:"queue",agent_platform:$p,status:"in_progress",branch:null},
  {id:"goal-done2",agent_platform:$p,goal:"newest done",branch:"newest",status:"completed"}]' > "$STATE"
reject 'Goal not found' g continue no-such-branch
if grep -q 'containment' "$TEST_ROOT/rej.err"; then die "null branch crashed the lookup"; fi
g continue > /dev/null 2>&1
check '.[-1].id == "goal-open" and .[-1].status == "in_progress"'
g continue goal-done > /dev/null 2>&1
check '.[-1].id == "goal-done" and .[-1].status == "in_progress"'
mutate 'map(if .id == "goal-done" then .status = "completed" else . end)'
jq -n --arg p "$AGENT" '[{id:"only-done",agent_platform:$p,goal:"x",branch:"x",status:"completed"}]' > "$STATE"
reject 'No in-progress' g continue
pass "continue survives null branches and skips finished/queue/other-platform goals"

# --- verify run: timeout, none-detected ---------------------------------------------
fresh_goal
printf '%s\n' '{"platform":"github","verify_timeout":1,"verify_commands":[{"name":"sleepy","cmd":"sleep 30"}]}' > "$CONFIG"
start=$(date +%s)
set +e; g verify run > "$TEST_ROOT/verify.out" 2>/dev/null; rc=$?; set -e
elapsed=$(( $(date +%s) - start ))
[ "$rc" != 0 ] || die "a hung check must fail verify run"
[ "$elapsed" -lt 20 ] || die "verify run did not time out (took ${elapsed}s)"
jq -e '.overall == "FAIL" and (.results[0].suggested | test("verify_timeout"))' "$TEST_ROOT/verify.out" >/dev/null
printf '%s\n' '{"platform":"github","verify_commands":[{"name":"stdin","cmd":"read -r x; echo got-$x"}]}' > "$CONFIG"
g verify run > "$TEST_ROOT/verify.out" 2>/dev/null </dev/null || true
jq -e '.results[0].status == "PASS" or .results[0].status == "FAIL"' "$TEST_ROOT/verify.out" >/dev/null
fresh_goal
printf '%s\n' '{"platform":"github"}' > "$CONFIG"
reject 'config put verify_cmd' g verify run
reject 'config put verify_cmd' g verify run --none-detected-ok
mutate '.[0].harness.complexity = "TRIVIAL"'
g verify run --none-detected-ok >/dev/null 2>&1
check '.[0].harness.gates.VERIFICATION.status == "PASS"'
pass "verify run times out hung checks and handles no detected checks explicitly"

# --- forge pending ledgers ------------------------------------------------------------
CACHE="$PROJECT/$AGENT_DIR/cache/forge"
mkdir -p "$CACHE/create-abc.pending" "$CACHE/create-def.pending"
printf '%s\n' '{"operation":"create","head":"feat/x","state":"pending"}' > "$CACHE/create-abc.pending/operation.json"
g forge pending > "$TEST_ROOT/pending.out" 2>/dev/null
[ "$(wc -l < "$TEST_ROOT/pending.out" | tr -d ' ')" = 2 ] || die "forge pending lists ledgers"
g forge pending clear --reconcile > "$TEST_ROOT/clear.out" 2>/dev/null
[ -z "$(ls -d "$CACHE"/create-*.pending 2>/dev/null)" ] || die "forge pending clear removes ledgers"
jq -e -s 'last.cleared == 2 and last.kept == 0' "$TEST_ROOT/clear.out" >/dev/null
pass "forge pending clear removes unresolved create ledgers"

# --- harness status next_action ---------------------------------------------------------
fresh_goal
g harness status 2>/dev/null | jq -e '.next_action | type == "string" and length > 10' >/dev/null
mutate '.[0].harness.phase = "FAILED"'
g harness status 2>/dev/null | jq -e '.next_action | test("REWORK")' >/dev/null
pass "harness status computes next_action"

# --- stale state lock does not wedge reset -------------------------------------------------
fresh_goal
mkdir -p "$PROJECT/$AGENT_DIR/.state.lock"
printf '99999999\n' > "$PROJECT/$AGENT_DIR/.state.lock/pid"
g reset runtime --yes >/dev/null 2>&1 || die "reset must ignore a lock whose process is gone"
[ ! -d "$PROJECT/$AGENT_DIR/.state.lock" ] || die "stale lock removed"
pass "reset ignores stale locks"

# --- GOAL_ISSUE_REPO has one identity form -------------------------------------------------
fresh_goal
mutate '.[0].issue = {number:7,repo:"https://github.com/Acme/Demo.git"} | .[0].run_id = "r1"'
for form in acme/demo https://github.com/acme/demo github.com/acme/demo.git; do
  GOAL_ISSUE=7 GOAL_RUN_ID=r1 GOAL_ISSUE_REPO="$form" g state 2>/dev/null | jq -e '.issue.number == 7' >/dev/null || die "GOAL_ISSUE_REPO form $form did not match"
done
GOAL_ISSUE=7 GOAL_RUN_ID=r1 GOAL_ISSUE_REPO=other/project g state >/dev/null 2>&1 && die "different repository must not match"
pass "GOAL_ISSUE_REPO matches regardless of scheme, case, .git or github.com prefix"

echo "PASS: stall recovery ($AGENT)"
