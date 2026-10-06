#!/usr/bin/env bash
# Queue Planner bootstrap: plan before any issue goal/branch exists.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export TMPDIR="${TMPDIR:-$ROOT/.tmp-tests}"
mkdir -p "$TMPDIR"
TEST_ROOT="$(mktemp -d "$TMPDIR/codex-queue-plan.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
PROJECT="$TEST_ROOT/project"
REMOTE="$TEST_ROOT/remote.git"
mkdir -p "$PROJECT/.codex/scripts" "$PROJECT/.codex/agents" "$TEST_ROOT/bin"
git init -q -b main "$PROJECT"
# Avoid sandbox hook permission issues
rm -rf "$PROJECT/.git/hooks"
mkdir -p "$PROJECT/.git/hooks"
git -C "$PROJECT" -c user.name=Fixture -c user.email=fixture@example.test -c commit.gpgsign=false commit -qm seed --allow-empty
git init -q --bare "$REMOTE"
rm -rf "$REMOTE/hooks"
mkdir -p "$REMOTE/hooks"
git -C "$PROJECT" remote add origin "$REMOTE"
git -C "$PROJECT" push -qu origin main
printf '%s\n' '.codex/' 'state.json' '.worktrees/' > "$PROJECT/.git/info/exclude"

cp "$ROOT/templates/codex/.codex/scripts/"*.sh "$PROJECT/.codex/scripts/"
cp "$ROOT/templates/codex/.codex/agents/"*.toml "$PROJECT/.codex/agents/"
cp "$ROOT/templates/codex/.codex/goal-models.json" "$PROJECT/.codex/goal-models.json"
jq -n '{
  platform:"github",
  goal_source:"issues",
  target_branch:"main",
  issue_list_url:"https://github.com/team/app/issues",
  issue_limit:2,
  concurrency:2,
  forge_repo:"team/app"
}' > "$PROJECT/.codex/goal-config.json"

cat > "$TEST_ROOT/bin/gh" <<'PY'
#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
if args == ['--version']:
    print('gh fixture 1.0'); sys.exit(0)
if args[:2] == ['issue', 'list']:
    print(json.dumps([
        {"number":91,"title":"Rate limit","body":"PDD","labels":[],"url":"https://github.com/team/app/issues/91","createdAt":"2026-09-24T00:00:00Z"},
        {"number":92,"title":"Make run","body":"README","labels":[],"url":"https://github.com/team/app/issues/92","createdAt":"2026-09-24T00:00:01Z"},
    ]))
    sys.exit(0)
if args[:2] == ['issue', 'view']:
    n = int(args[2])
    print(json.dumps({
        "number": n, "title": f"Issue {n}", "body": f"Body {n}", "labels": [],
        "url": f"https://github.com/team/app/issues/{n}"
    }))
    sys.exit(0)
print('Unexpected gh:', args, file=sys.stderr); sys.exit(97)
PY
chmod +x "$TEST_ROOT/bin/gh"
cp "$TEST_ROOT/bin/gh" "$TEST_ROOT/bin/glab"
export PATH="$TEST_ROOT/bin:$PATH" GOAL_PLATFORM=github

G() { bash "$PROJECT/.codex/scripts/goal-git.sh" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# Fresh project: no state.json
[ ! -f "$PROJECT/state.json" ] || fail "state.json must not exist yet"

export GOAL_RUN_ID=run-queue-fixture GOAL_ID='' GOAL_ISSUE='' GOAL_GROUP='' GOAL_TASK='' GOAL_REPO=.
BEGIN=$(G issues plan begin --count 2)
echo "$BEGIN" | jq -e '.goal_id == "queue-run-queue-fixture" and .status == "planning" and (.issues|length)==2' >/dev/null \
  || { echo "$BEGIN"; fail "issues plan begin"; }
[ -f "$PROJECT/state.json" ] || fail "state.json created"
jq -e '.[0].kind == "queue" and .[0].harness.phase == "PLANNED"' "$PROJECT/state.json" >/dev/null \
  || fail "queue record shape"
# Idempotent reuse
BEGIN2=$(G issues plan begin --count 2)
echo "$BEGIN2" | jq -e '.goal_id == "queue-run-queue-fixture"' >/dev/null || fail "reuse begin"
pass "issues plan begin on empty project"

export GOAL_ID=queue-run-queue-fixture
PLANNER="$(jq -r '."$routing".planner.NORMAL.model' "$PROJECT/.codex/goal-models.json")"
BUILDER="$(jq -r '."$routing".builder.NORMAL.model' "$PROJECT/.codex/goal-models.json")"

SPAWN=$(G harness spawn planner "$PLANNER" medium)
echo "$SPAWN" | jq -e '.reservation.role == "planner"' >/dev/null || { echo "$SPAWN"; fail "planner spawn"; }
BRIEF=$(G harness brief planner)
[ -f "$BRIEF" ] || fail "brief path missing"
rg -q 'Queue planning|Queue issues|Issue Execution Plan' "$BRIEF" || fail "queue brief content"
pass "planner spawn + brief on queue record"

if G harness spawn builder "$BUILDER" medium >"$TEST_ROOT/builder.out" 2>"$TEST_ROOT/builder.err"; then
  fail "builder spawn should be rejected on queue record"
fi
rg -qi 'Queue record allows only planner/researcher|planner/researcher' "$TEST_ROOT/builder.err" \
  || { cat "$TEST_ROOT/builder.err"; fail "builder rejection message"; }
pass "builder spawn rejected on queue record"

if G commit 'feat: should fail' >"$TEST_ROOT/commit.out" 2>"$TEST_ROOT/commit.err"; then
  fail "commit should be rejected on queue record"
fi
rg -qi 'Queue record selected|issue/work goal' "$TEST_ROOT/commit.err" \
  || { cat "$TEST_ROOT/commit.err"; fail "commit rejection"; }
if G pr --title 'feat(app): x' --body-file /dev/null >"$TEST_ROOT/pr.out" 2>"$TEST_ROOT/pr.err"; then
  fail "pr should be rejected on queue record"
fi
rg -qi 'Queue record selected|issue/work goal' "$TEST_ROOT/pr.err" \
  || { cat "$TEST_ROOT/pr.err"; fail "pr rejection"; }
pass "work-goal guards reject commit/pr on queue record"

printf '%s\n' '{"batches":[{"issues":[91,92],"parallel":true}],"concurrency":2}' \
  | G harness context put queue_plan -
DONE=$(G issues plan done)
echo "$DONE" | jq -e '.status == "planned" and .queue_plan.concurrency == 2' >/dev/null \
  || { echo "$DONE"; fail "issues plan done"; }
[ -f "$PROJECT/.codex/queue-plans/run-queue-fixture.json" ] || fail "per-run plan file"
[ -f "$PROJECT/.codex/queue-plan.json" ] || fail "plan mirror"
SHOW=$(G issues plan show)
echo "$SHOW" | jq -e '.status == "planned"' >/dev/null || fail "plan show"
pass "context put queue_plan + plan done"

QUEUE=$(GOAL_ID='' G issues queue)
echo "$QUEUE" | jq -e 'type == "array" and length == 0' >/dev/null \
  || { echo "$QUEUE"; fail "issues queue must exclude queue record"; }
pass "issues queue excludes queue record"

# Clear queue selection; start a real issue (no worktree for simpler git fixture)
export GOAL_ID='' GOAL_ISSUE=''
G issues start 91 >/dev/null
jq -e '[.[] | select((.kind // "") != "queue" and .issue.number == 91)] | length == 1' "$PROJECT/state.json" >/dev/null \
  || fail "issue goal after plan"
pass "issues start creates normal issue goal after plan"

echo "All queue planner bootstrap checks passed."
