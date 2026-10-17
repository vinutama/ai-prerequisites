#!/usr/bin/env bash
# Claude Stop hook (harness stop-check) block/allow matrix, the consecutive-block
# guard, and the SubagentStart/Stop hook handler. Local only.
# Usage: AGENT=claude|codex|cursor bash tests/codex/test-stop-check.sh  (default claude)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT="${AGENT:-${PLATFORM:-claude}}"
case "$AGENT" in
  codex)  AGENT_DIR=.codex;  AGENTS_GLOB='*.toml' ;;
  cursor) AGENT_DIR=.cursor; AGENTS_GLOB='*.md' ;;
  claude) AGENT_DIR=.claude; AGENTS_GLOB='*.md' ;;
  *) echo "Unknown AGENT=$AGENT (expected codex|cursor|claude)" >&2; exit 1 ;;
esac
SRC="$ROOT/templates/$AGENT/$AGENT_DIR"
export TMPDIR="${TMPDIR:-$ROOT/.tmp-tests}"
mkdir -p "$TMPDIR"
TEST_ROOT="$(mktemp -d "$TMPDIR/stop-check.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
PROJECT="$TEST_ROOT/project"
mkdir -p "$PROJECT/$AGENT_DIR/scripts" "$PROJECT/$AGENT_DIR/agents"
git init -q -b fixture "$PROJECT"
git -C "$PROJECT" config user.name Fixture
git -C "$PROJECT" config user.email fixture@example.test
printf 'seed\n' > "$PROJECT/README.md"
printf '%s/\nstate.json\n' "$AGENT_DIR" > "$PROJECT/.gitignore"
git -C "$PROJECT" add README.md .gitignore
git -C "$PROJECT" commit -qm seed
cp "$SRC/scripts/"*.sh "$PROJECT/$AGENT_DIR/scripts/"
cp "$SRC/agents/"$AGENTS_GLOB "$PROJECT/$AGENT_DIR/agents/"
cp "$SRC/goal-models.json" "$PROJECT/$AGENT_DIR/goal-models.json"
printf '%s\n' '{"platform":"github","concurrency":2}' > "$PROJECT/$AGENT_DIR/goal-config.json"
G="$PROJECT/$AGENT_DIR/scripts/goal-git.sh"
STATE="$PROJECT/state.json"
GUARD="$PROJECT/$AGENT_DIR/stop-guard.json"
CACHE="$PROJECT/$AGENT_DIR/cache/forge"
export GOAL_PLATFORM=github
unset GOAL_ID GOAL_RUN_ID GOAL_ISSUE GOAL_GROUP GOAL_TASK GOAL_REPO GOAL_ISSUE_REPO

pass() { printf 'PASS: %s\n' "$*"; }
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mutate() { jq "$1" "$STATE" > "$TEST_ROOT/state.tmp" && mv "$TEST_ROOT/state.tmp" "$STATE"; }
fresh() {
  rm -f "$GUARD"; rm -rf "$CACHE"
  jq -n --arg platform "$AGENT" '[{id:"goal-fixture",agent_platform:$platform,goal:"Ship the thing",branch:"fixture",
    base_branch:"main",status:"in_progress",platform:"github",repos:[{path:".",pr_number:null,pr_url:""}],
    source:{type:"prompt",title:"t",body:"b",reference:"",acceptance_criteria:[]}}]' > "$STATE"
  "$G" harness init --route backend --complexity NORMAL --visual false >/dev/null 2>&1
  mutate '.[0].harness.phase = "BUILDING"'
}
# stop <stdin-json>: prints the hook output; the exit code must always be 0.
stop() {
  local payload="${1:-{\}}" rc=0
  printf '%s' "$payload" | "$G" harness stop-check > "$TEST_ROOT/stop.out" 2> "$TEST_ROOT/stop.err" || rc=$?
  [ "$rc" = 0 ] || die "stop-check must exit 0 (got $rc)"
  cat "$TEST_ROOT/stop.out"
}
expect_block() {
  local out; out="$(stop "${2:-{\}}")"
  printf '%s' "$out" | jq -e '.decision == "block" and (.reason | length > 20)' >/dev/null || die "expected block: $1 (got: ${out:-<empty>})"
}
expect_allow() {
  local out; out="$(stop "${2:-{\}}")"
  [ -z "$out" ] || die "expected allow: $1 (got: $out)"
}

# --- no state / no goal / other platform / no harness: always allow -------------------
rm -f "$STATE"
expect_allow "no state file"
echo '[]' > "$STATE"; expect_allow "empty state"
jq -n '[{id:"o",agent_platform:"nobody",goal:"x",status:"in_progress",harness:{phase:"BUILDING",events:[]}}]' > "$STATE"
expect_allow "goal of another platform"
fresh; mutate 'del(.[0].harness)'; expect_allow "goal without harness"
echo 'not json {' > "$STATE"; expect_allow "corrupt state"
(unset GOAL_PLATFORM; cd "$PROJECT" && git remote remove origin 2>/dev/null || true; printf '' | "$G" harness stop-check >/dev/null 2>&1) || die "unconfigured platform must exit 0"
pass "no goal, other platform, no harness, corrupt state: allowed"

# --- block while unfinished, with the next action -----------------------------------------
fresh
out="$(stop '{"hook_event_name":"Stop","stop_hook_active":false}')"
printf '%s' "$out" | jq -e '.decision == "block" and (.reason | test("Ship the thing")) and (.reason | test("BUILDING")) and (.reason | test("Next:")) and (.reason | test("harness event blocker"))' >/dev/null || die "block payload: $out"
rm -f "$GUARD"
pass "unfinished goal blocks stopping and names the next action"

# --- allow: DONE, saved blocker, FAILED with blocker, auth error, inactivity ------------------
fresh; mutate '.[0].harness.phase = "DONE"'; expect_allow "harness DONE"
fresh; "$G" harness event blocker "needs a human decision" >/dev/null 2>&1; expect_allow "saved blocker"
"$G" harness event builder note "more work" >/dev/null 2>&1 # still last event is not a blocker
expect_block "work continued after the blocker"
fresh; mutate '.[0].harness.phase = "FAILED" | .[0].harness.blocker = {kind:"retry_budget"}'; expect_allow "FAILED with blocker"
fresh; mutate '.[0].harness.phase = "FAILED"'; expect_block "FAILED without a blocker is recoverable"
fresh; mkdir -p "$CACHE"; printf '{"category":"auth","cli":"gh","at":%s}\n' "$(date +%s)" > "$CACHE/auth-error.json"
expect_allow "pending forge auth error"
printf '{"category":"auth","cli":"gh","at":%s}\n' "$(( $(date +%s) - 200000 ))" > "$CACHE/auth-error.json"
expect_block "old auth error no longer excuses stopping"
fresh; mutate '.[0].harness.events |= map(.at = "2020-01-01T00:00:00+00:00")'; expect_allow "long inactivity"
printf '%s\n' '{"platform":"github","stop_check_window":100000000}' > "$PROJECT/$AGENT_DIR/goal-config.json"
expect_block "window raised through config"
printf '%s\n' '{"platform":"github","concurrency":2}' > "$PROJECT/$AGENT_DIR/goal-config.json"
pass "DONE, blocker, FAILED+blocker, auth error and inactivity allow stopping"

# --- consecutive-block guard ---------------------------------------------------------------------
fresh
expect_block "first"; expect_block "second"
expect_block "third" '{"stop_hook_active":true}'
expect_allow "fourth, no state change" '{"stop_hook_active":true}'
expect_allow "fifth, still unchanged"
mutate '.[0].harness.tasks += [{id:"t1",role:"builder",title:"x",state:"PENDING",attempts:0}]'
expect_block "any state change resets the counter"
pass "three blocks without progress release the stop; state change re-arms it"

# --- never breaks the session ---------------------------------------------------------------------
fresh; chmod 000 "$STATE" 2>/dev/null || true
out="$(stop)"; chmod 644 "$STATE"
[ -z "$out" ] || die "unreadable state must allow"
fresh; printf 'garbage' | "$G" harness stop-check >/dev/null 2>&1 || die "garbage stdin must not fail"
fresh; mkdir -p "$GUARD"; expect_allow "unwritable guard path degrades to allow"; rmdir "$GUARD"
pass "internal errors never produce output or a failing exit"

# --- SubagentStart / SubagentStop hook handler ------------------------------------------------------
fresh
if [ "$AGENT" = cursor ]; then
  echo '{"hook_event_name":"SubagentStart","agent_type":"builder"}' | "$G" harness hook | jq -e '.continue == true' >/dev/null
  pass "harness hook is a no-op on cursor"
else
  echo '{"hook_event_name":"SubagentStart","agent_type":"builder","agent_id":"agent-9"}' | "$G" harness hook | jq -e '.continue == true' >/dev/null
  echo '{"hook_event_name":"SubagentStop","agent_type":"builder","agent_id":"agent-9","last_assistant_message":"all done\nmore"}' | "$G" harness hook | jq -e '.continue == true and (.systemMessage | test("builder completed: all done"))' >/dev/null
  jq -e '[.[0].harness.events[] | select(.agent == "builder") | .event] == ["started","completed"]' "$STATE" >/dev/null || die "hook events recorded on the platform goal"
  echo '' | "$G" harness hook | jq -e '.continue == true' >/dev/null
  rm -f "$STATE"
  echo '{"hook_event_name":"SubagentStart","agent_type":"builder"}' | "$G" harness hook | jq -e '.continue == true' >/dev/null
  [ ! -e "$STATE" ] || die "hook must not create state"
  pass "harness hook records start/stop on this platform's goal without selectors"

fi

# --- launch line in worker briefs ----------------------------------------------------------------------
fresh
mutate '.[0].harness.tasks = [{id:"t1",role:"builder",title:"x",state:"PENDING",attempts:0}]'
brief="$("$G" harness brief builder --task t1 2>/dev/null)"
case "$AGENT" in
  claude) grep -q 'Agent(subagent_type="builder"' "$brief" && grep -q 'agentId' "$brief" || die "claude brief launch line" ;;
  cursor) grep -q 'Agent/Task tool' "$brief" || die "cursor brief launch line" ;;
  codex)  grep -q 'spawn_agent' "$brief" || die "codex brief launch line" ;;
esac
pass "worker brief carries the $AGENT launch recipe"

echo "PASS: stop-check ($AGENT)"
