#!/usr/bin/env bash
# Deterministic tests for Markdown multi-PR delivery groups.
# Usage: AGENT=codex|cursor bash tests/codex/test-delivery-groups.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT="${AGENT:-codex}"
case "$AGENT" in
  codex)
    SRC_SCRIPTS="$ROOT/templates/codex/.codex/scripts"
    AGENT_DIR=".codex"
    ;;
  cursor)
    SRC_SCRIPTS="$ROOT/templates/cursor/.cursor/scripts"
    AGENT_DIR=".cursor"
    ;;
  *)
    echo "Unknown AGENT=$AGENT (expected codex|cursor)" >&2
    exit 1
    ;;
esac
PASS=0
FAIL=0

echo "=== delivery-groups tests (AGENT=$AGENT) ==="
ok() { PASS=$((PASS + 1)); echo "  PASS  $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }

assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [ "$got" = "$want" ]; then
    ok "$msg"
  else
    fail "$msg (got '$got' want '$want')"
  fi
}

assert_contains() {
  local hay="$1" needle="$2" msg="$3"
  if echo "$hay" | grep -qF "$needle"; then
    ok "$msg"
  else
    fail "$msg (missing '$needle')"
  fi
}

assert_not_contains() {
  local hay="$1" needle="$2" msg="$3"
  if echo "$hay" | grep -qF "$needle"; then
    fail "$msg (unexpected '$needle')"
  else
    ok "$msg"
  fi
}

INDEP_JSON='{
  "delivery_groups": [
    {
      "id": "g1",
      "task_type": "fix",
      "title": "Correct schema and permission alignment",
      "branch_slug": "correct-schema-permissions",
      "task_ids": ["t1", "t2"],
      "depends_on": [],
      "files": ["src/api/**", "src/utils/public-permissions.ts", "scripts/check-public-api.mts"],
      "acceptance_checks": ["node scripts/check-public-api.mts", "npm run build"],
      "reason": "Cohesive schema correction that can be reviewed and deployed independently"
    },
    {
      "id": "g2",
      "task_type": "feat",
      "title": "Add course event delivery",
      "branch_slug": "add-course-event-delivery",
      "task_ids": ["t3"],
      "depends_on": [],
      "files": ["src/events/**"],
      "acceptance_checks": ["npm test"],
      "reason": "Independent event domain"
    },
    {
      "id": "g3",
      "task_type": "feat",
      "title": "Add LMS server plugin",
      "branch_slug": "add-lms-server-plugin",
      "task_ids": ["t4"],
      "depends_on": [],
      "files": ["src/lms/server/**"],
      "acceptance_checks": ["npm test"],
      "reason": "Server plugin"
    },
    {
      "id": "g4",
      "task_type": "feat",
      "title": "Add LMS operator UI",
      "branch_slug": "add-lms-operator-ui",
      "task_ids": ["t5"],
      "depends_on": ["g3"],
      "files": ["src/lms/ui/**"],
      "acceptance_checks": ["npm test"],
      "reason": "UI depends on plugin"
    },
    {
      "id": "g5",
      "task_type": "docs",
      "title": "Document integration workflow",
      "branch_slug": "document-integration-workflow",
      "task_ids": ["t6"],
      "depends_on": [],
      "files": ["docs/integration.md"],
      "acceptance_checks": [],
      "reason": "Docs-only change"
    }
  ]
}'

COUPLED_JSON='{
  "delivery_groups": [
    {
      "id": "g1",
      "task_type": "feat",
      "title": "Add widget with migration tests and docs",
      "branch_slug": "add-widget",
      "task_ids": ["t1", "t2", "t3", "t4"],
      "depends_on": [],
      "files": [
        "src/widget.ts",
        "src/widget.test.ts",
        "migrations/001_widget.sql",
        "docs/widget.md"
      ],
      "acceptance_checks": ["npm test", "npm run build"],
      "reason": "Implementation, tests, migration, and docs must ship together",
      "inseparable_reason": "Splitting would leave main unable to migrate or test the widget"
    }
  ]
}'

BUGFIX_JSON='{
  "delivery_groups": [
    {
      "id": "g1",
      "task_type": "bugfix",
      "title": "Correct public permissions",
      "branch_slug": "correct-public-permissions",
      "task_ids": ["t1"],
      "depends_on": [],
      "files": ["src/utils/public-permissions.ts"],
      "acceptance_checks": ["npm test"],
      "reason": "Isolated permission fix"
    }
  ]
}'

setup_proj() {
  local dir="$1" strategy="${2:-auto}"
  rm -rf "$dir"
  mkdir -p "$dir/$AGENT_DIR/scripts" "$dir/bin"
  cp "$SRC_SCRIPTS/goal-git.sh" "$SRC_SCRIPTS/delivery-groups.sh" "$dir/$AGENT_DIR/scripts/"
  chmod +x "$dir/$AGENT_DIR/scripts/goal-git.sh"

  cat > "$dir/$AGENT_DIR/goal-config.json" <<EOF
{
  "goal_source": "markdown",
  "target_branch": "main",
  "platform": "github",
  "concurrency": 1,
  "auto_merge": false,
  "review_mode": "inline",
  "review_max_iterations": 0,
  "max_rework": 3,
  "max_escalations": 2,
  "max_verify_retries": 3,
  "qa_mode": "auto",
  "visual_mode": "auto",
  "markdown_pr_strategy": "$strategy",
  "max_tasks_per_pr": 3,
  "max_files_per_pr": 25,
  "max_parallel_prs": 2
}
EOF

  cat > "$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
COUNTER="$(dirname "$0")/.gh-pr-counter"
[ -f "$COUNTER" ] || echo 100 > "$COUNTER"
case "${1:-} ${2:-}" in
  "pr create")
    n=$(cat "$COUNTER")
    n=$((n + 1))
    echo "$n" > "$COUNTER"
    echo "https://github.com/example/repo/pull/$n"
    ;;
  "pr view")
    n=$(cat "$COUNTER")
    echo "{\"url\":\"https://github.com/example/repo/pull/$n\",\"number\":$n}"
    ;;
  "pr merge")
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$dir/bin/gh"

  (
    cd "$dir"
    git init -b main >/dev/null 2>&1 || { git init >/dev/null && git checkout -b main >/dev/null; }
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "seed" > README.md
    git add README.md
    git commit -m "chore: seed" >/dev/null
  )
}

G() {
  # Run goal-git.sh inside $PROJ with stubs.
  env GOAL_PLATFORM=github PATH="$PROJ/bin:$PATH" \
    "$PROJ/$AGENT_DIR/scripts/goal-git.sh" "$@"
}

start_markdown() {
  env GOAL_SOURCE_OVERRIDE=markdown GOAL_PLATFORM=github PATH="$PROJ/bin:$PATH" \
    "$PROJ/$AGENT_DIR/scripts/goal-git.sh" start "$@"
}

echo "== bash syntax"
if bash -n "$SRC_SCRIPTS/goal-git.sh" && bash -n "$SRC_SCRIPTS/delivery-groups.sh"; then
  ok "bash -n scripts"
else
  fail "bash -n scripts"
fi

# --- Fixture project used by most cases ---
PROJ="$(mktemp -d /tmp/delivery-groups.XXXXXX)"
setup_proj "$PROJ" auto
trap 'rm -rf "$PROJ"' EXIT

echo "== 1 independent tasks create multiple groups"
start_markdown "Implement LMS markdown goal"
echo "$INDEP_JSON" | G groups init - >/dev/null
n=$(jq '.[-1].delivery_groups | length' "$PROJ/state.json")
assert_eq "$n" "5" "independent plan yields 5 groups"
mode=$(jq -r '.[-1].delivery_mode' "$PROJ/state.json")
assert_eq "$mode" "multi-pr" "delivery_mode=multi-pr"

echo "== 2 coupled impl/migration/tests/docs stay together"
PROJ2="$(mktemp -d /tmp/delivery-coupled.XXXXXX)"
setup_proj "$PROJ2" auto
(
  PROJ="$PROJ2"
  start_markdown "Add widget"
  echo "$COUPLED_JSON" | G groups init - >/dev/null
  n=$(jq '.[-1].delivery_groups | length' "$PROJ/state.json")
  ids=$(jq -r '.[-1].delivery_groups[0].task_ids | join(",")' "$PROJ/state.json")
  files=$(jq -r '.[-1].delivery_groups[0].files | join(" ")' "$PROJ/state.json")
  assert_eq "$n" "1" "coupled work is one group"
  assert_eq "$ids" "t1,t2,t3,t4" "coupled group keeps all task ids"
  assert_contains "$files" "migrations/001_widget.sql" "coupled group includes migration"
  assert_contains "$files" "src/widget.test.ts" "coupled group includes tests"
  assert_contains "$files" "docs/widget.md" "coupled group includes docs"
)
rm -rf "$PROJ2"

echo "== 3 planner task types on different groups"
types=$(jq -r '.[-1].delivery_groups | map(.task_type) | join(",")' "$PROJ/state.json")
assert_eq "$types" "fix,feat,feat,feat,docs" "mixed feat/fix/docs types"

echo "== 4 bugfix normalizes to fix"
PROJ3="$(mktemp -d /tmp/delivery-bugfix.XXXXXX)"
setup_proj "$PROJ3" auto
(
  PROJ="$PROJ3"
  start_markdown "Fix permissions" "" "bugfix"
  echo "$BUGFIX_JSON" | G groups init - >/dev/null
  tt=$(jq -r '.[-1].delivery_groups[0].task_type' "$PROJ/state.json")
  br=$(jq -r '.[-1].delivery_groups[0].branch' "$PROJ/state.json")
  ut=$(jq -r '.[-1].user_task_type' "$PROJ/state.json")
  assert_eq "$tt" "fix" "bugfix → fix"
  assert_eq "$ut" "fix" "user_task_type persisted as fix"
  assert_eq "$br" "fix/g1-correct-public-permissions" "bugfix branch uses fix/"
)
rm -rf "$PROJ3"

echo "== 5 branch format <task-type>/<group-id>-<slug>"
branches=$(jq -r '.[-1].delivery_groups[].branch' "$PROJ/state.json")
assert_contains "$branches" "fix/g1-correct-schema-permissions" "g1 branch"
assert_contains "$branches" "feat/g2-add-course-event-delivery" "g2 branch"
assert_contains "$branches" "feat/g3-add-lms-server-plugin" "g3 branch"
assert_contains "$branches" "feat/g4-add-lms-operator-ui" "g4 branch"
assert_contains "$branches" "docs/g5-document-integration-workflow" "g5 branch"

echo "== 6 no delivery branch uses goal/ prefix"
if echo "$branches" | grep -qE '^goal/'; then
  fail "delivery branch used goal/ prefix"
else
  ok "no goal/ delivery branches"
fi
root_branch=$(jq -r '.[-1].branch' "$PROJ/state.json")
assert_eq "$root_branch" "" "multi-pr start creates no aggregation branch"

echo "== 7 dependencies enforce merge order"
if G groups start g4 >/dev/null 2>"$PROJ/err.txt"; then
  fail "g4 started before g3 merged"
else
  assert_contains "$(cat "$PROJ/err.txt")" "blocked on g3" "g4 waits for g3"
fi

echo "== 8 independent groups get separate worktrees"
G groups start g1 >/dev/null
G groups persist >/dev/null 2>&1 || true
G groups start g2 >/dev/null
wt1=$(jq -r '.[-1].delivery_groups[] | select(.id=="g1") | .worktree' "$PROJ/state.json")
wt2=$(jq -r '.[-1].delivery_groups[] | select(.id=="g2") | .worktree' "$PROJ/state.json")
[ -d "$PROJ/$wt1" ] && ok "g1 worktree exists ($wt1)" || fail "g1 worktree missing"
[ -d "$PROJ/$wt2" ] && ok "g2 worktree exists ($wt2)" || fail "g2 worktree missing"
[ "$wt1" != "$wt2" ] && ok "g1 and g2 worktrees differ" || fail "g1 and g2 share a worktree"

echo "== 9 parallel builders never share a worktree"
G groups activate g1 >/dev/null
G harness init --route backend --qa false --visual false --complexity NORMAL >/dev/null
G harness phase BUILDING >/dev/null
G harness task add builder "one" >/dev/null
G harness task add builder "two" >/dev/null
# t1 SPAWNING, t2 SPAWNING — second spawn must fail
G harness task set t1 SPAWNING >/dev/null
G harness task set t2 SPAWNING >/dev/null
if G harness spawn builder dummy-model medium >/dev/null 2>"$PROJ/err-spawn.txt"; then
  fail "harness spawn allowed two SPAWNING builders in one group worktree"
else
  assert_contains "$(cat "$PROJ/err-spawn.txt")" "Parallel builders cannot share worktree" \
    "spawn rejects parallel builders in the same group worktree"
fi
# reset tasks so later steps are not stuck
python3 - <<PY
import json
p="$PROJ/state.json"
data=json.load(open(p))
g=data[-1]
h=g.get("harness") or {}
h["tasks"]=[]
g["harness"]=h
for dg in g.get("delivery_groups") or []:
    if dg.get("id")=="g1":
        dg["harness"]=h
json.dump(data, open(p,"w"))
PY

echo "== 10 each group creates its own PR/MR"
G groups persist >/dev/null 2>&1 || true
G groups pr g1 >/dev/null
G groups persist >/dev/null 2>&1 || true
G groups pr g2 >/dev/null
p1=$(jq -r '.[-1].delivery_groups[] | select(.id=="g1") | .pr_number' "$PROJ/state.json")
p2=$(jq -r '.[-1].delivery_groups[] | select(.id=="g2") | .pr_number' "$PROJ/state.json")
[ "$p1" != "null" ] && [ -n "$p1" ] && ok "g1 has PR #$p1" || fail "g1 missing PR"
[ "$p2" != "null" ] && [ -n "$p2" ] && ok "g2 has PR #$p2" || fail "g2 missing PR"
[ "$p1" != "$p2" ] && ok "g1 and g2 have distinct PRs" || fail "g1 and g2 share a PR"

echo "== 11 no final aggregation PR/MR"
G groups persist >/dev/null 2>&1 || true
# Clear active group to simulate root-level pr
python3 - <<PY
import json
p="$PROJ/state.json"
data=json.load(open(p))
data[-1]["active_group_id"]=None
json.dump(data, open(p,"w"))
PY
if G pr >/dev/null 2>"$PROJ/err-pr.txt"; then
  fail "root pr created an aggregation PR"
else
  assert_contains "$(cat "$PROJ/err-pr.txt")" "Refusing aggregation PR/MR" \
    "root pr refuses aggregation PR"
fi

echo "== 12 inseparable goal still creates one justified group"
reason=$(jq -r '.[-1].delivery_groups[0].inseparable_reason // empty' "$PROJ2/state.json" 2>/dev/null || true)
# Recreate coupled in a tiny project (PROJ2 already removed) — re-check from COUPLED via validate
if echo "$COUPLED_JSON" | G groups validate - >/dev/null; then
  ok "single inseparable group validates"
else
  fail "single inseparable group failed validation"
fi
insep=$(echo "$COUPLED_JSON" | jq -r '.delivery_groups[0].inseparable_reason')
assert_contains "$insep" "Splitting would leave main" "inseparable_reason is concrete"

echo "== 13 interrupted execution resumes without duplicate PRs or worktrees"
wt_before=$(ls -d "$PROJ/.worktrees/"* 2>/dev/null | wc -l | tr -d ' ')
G groups continue g1 >/dev/null
G groups pr g1 >/dev/null
p1b=$(jq -r '.[-1].delivery_groups[] | select(.id=="g1") | .pr_number' "$PROJ/state.json")
wt_after=$(ls -d "$PROJ/.worktrees/"* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$p1b" "$p1" "resume does not create a duplicate PR"
assert_eq "$wt_after" "$wt_before" "resume does not create a duplicate worktree"

echo "== 14 failed groups do not corrupt completed groups"
G groups merge g1 >/dev/null
# Simulate g2 failure without touching g1
python3 - <<PY
import json
p="$PROJ/state.json"
data=json.load(open(p))
g=data[-1]
for dg in g["delivery_groups"]:
    if dg["id"]=="g2":
        dg["status"]="in_progress"
        dg.setdefault("harness", {})["phase"]="FAILED"
json.dump(data, open(p,"w"))
PY
s1=$(jq -r '.[-1].delivery_groups[] | select(.id=="g1") | .status' "$PROJ/state.json")
s2=$(jq -r '.[-1].delivery_groups[] | select(.id=="g2") | .status' "$PROJ/state.json")
assert_eq "$s1" "merged" "g1 stays merged after g2 fails"
assert_eq "$s2" "in_progress" "g2 remains the failed/in-progress group"

echo "== 15 root completion requires every group"
if G state complete >/dev/null 2>"$PROJ/err-complete.txt"; then
  fail "root completed with unfinished groups"
else
  assert_contains "$(cat "$PROJ/err-complete.txt")" "unfinished groups" \
    "state complete blocked on unfinished groups"
fi

echo "== 16 existing state files migrate or continue safely"
PROJ4="$(mktemp -d /tmp/delivery-legacy.XXXXXX)"
setup_proj "$PROJ4" auto
(
  PROJ="$PROJ4"
  cat > "$PROJ/state.json" <<'EOF'
[
  {
    "goal": "legacy markdown",
    "branch": "goal/legacy-markdown",
    "base_branch": "main",
    "pr_number": 12,
    "pr_url": "https://github.com/example/repo/pull/12",
    "status": "in_progress",
    "goal_source": "markdown"
  }
]
EOF
  out=$(G continue 2>&1 || true)
  mode=$(jq -r '.[-1].delivery_mode // "single"' "$PROJ/state.json")
  assert_eq "$mode" "single" "legacy markdown without delivery_mode stays single"
  assert_not_contains "$out" "multi-PR" "continue does not rewrite legacy as multi-pr"
)
rm -rf "$PROJ4"

echo "== 17 markdown_pr_strategy=single preserves one-PR behavior"
PROJ5="$(mktemp -d /tmp/delivery-single.XXXXXX)"
setup_proj "$PROJ5" single
(
  PROJ="$PROJ5"
  start_markdown "One big markdown goal"
  br=$(jq -r '.[-1].branch' "$PROJ/state.json")
  mode=$(jq -r '.[-1].delivery_mode' "$PROJ/state.json")
  strat=$(jq -r '.[-1].markdown_pr_strategy' "$PROJ/state.json")
  assert_eq "$mode" "single" "strategy=single keeps delivery_mode=single"
  assert_eq "$strat" "single" "strategy persisted"
  assert_contains "$br" "goal/" "strategy=single still uses goal/ branch"
  if echo "$INDEP_JSON" | G groups init - >/dev/null 2>"$PROJ/err-single.txt"; then
    fail "strategy=single accepted multiple delivery groups"
  else
    assert_contains "$(cat "$PROJ/err-single.txt")" "exactly one delivery group" \
      "strategy=single rejects a multi-group plan"
  fi
)
rm -rf "$PROJ5"

echo "== 18 worktrees removed only after merge or explicit cancellation"
# g1 already merged — worktree should be gone
if [ -d "$PROJ/$wt1" ]; then
  fail "g1 worktree still present after merge"
else
  ok "g1 worktree removed after merge"
fi
[ -d "$PROJ/$wt2" ] && ok "g2 worktree still present before merge/cancel" \
  || fail "g2 worktree missing before cancel"
if G worktree remove g2-add-course-event-delivery >/dev/null 2>"$PROJ/err-wt.txt"; then
  fail "worktree remove allowed on multi-pr group"
else
  assert_contains "$(cat "$PROJ/err-wt.txt")" "groups cancel" \
    "worktree remove refused; cancel required"
fi
[ -d "$PROJ/$wt2" ] && ok "g2 worktree intact after refused remove" \
  || fail "g2 worktree deleted without merge/cancel"
G groups cancel g2 >/dev/null
if [ -d "$PROJ/$wt2" ]; then
  fail "g2 worktree still present after cancel"
else
  ok "g2 worktree removed after cancel"
fi

echo "== extra overlap sequential + unsupported type + task strategy"
OVERLAP='{
  "delivery_groups": [
    {"id":"g1","task_type":"feat","title":"A","branch_slug":"a","task_ids":["t1"],"depends_on":[],"files":["src/api/foo.ts"],"acceptance_checks":[],"reason":"a"},
    {"id":"g2","task_type":"fix","title":"B","branch_slug":"b","task_ids":["t2"],"depends_on":[],"files":["src/api/foo.ts"],"acceptance_checks":[],"reason":"b"}
  ]
}'
PROJ6="$(mktemp -d /tmp/delivery-overlap.XXXXXX)"
setup_proj "$PROJ6" auto
(
  PROJ="$PROJ6"
  start_markdown "overlap"
  echo "$OVERLAP" | G groups init - >/dev/null
  deps=$(jq -r '.[-1].delivery_groups[] | select(.id=="g2") | .depends_on | join(",")' "$PROJ/state.json")
  assert_eq "$deps" "g1" "overlapping files become sequential depends_on"
)
rm -rf "$PROJ6"

BAD='{"delivery_groups":[{"id":"g1","task_type":"hotfix","title":"x","branch_slug":"x","task_ids":["t1"],"depends_on":[],"files":[],"acceptance_checks":[],"reason":"x"}]}'
if echo "$BAD" | G groups validate - >/dev/null 2>"$PROJ/err-type.txt"; then
  fail "unsupported task type accepted"
else
  assert_contains "$(cat "$PROJ/err-type.txt")" "Unsupported task type" "unsupported type rejected"
fi

TASK_TWO='{"delivery_groups":[{"id":"g1","task_type":"feat","title":"x","branch_slug":"x","task_ids":["t1","t2"],"depends_on":[],"files":["a"],"acceptance_checks":[],"reason":"x"}]}'
PROJ7="$(mktemp -d /tmp/delivery-task.XXXXXX)"
setup_proj "$PROJ7" task
(
  PROJ="$PROJ7"
  start_markdown "task strategy"
  if echo "$TASK_TWO" | G groups init - >/dev/null 2>"$PROJ/err-task.txt"; then
    fail "strategy=task accepted a multi-task group"
  else
    assert_contains "$(cat "$PROJ/err-task.txt")" "exactly one task_id" \
      "strategy=task requires one task_id per group"
  fi
)
rm -rf "$PROJ7"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
