#!/usr/bin/env bash
# Cursor queue Planner bootstrap: plan before any issue goal/branch exists.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export TMPDIR="${TMPDIR:-$ROOT/.tmp-tests}"
mkdir -p "$TMPDIR"
TEST_ROOT="$(mktemp -d "$TMPDIR/cursor-queue-plan.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
PROJECT="$TEST_ROOT/project"
mkdir -p "$PROJECT/.cursor/scripts" "$PROJECT/.cursor/agents" "$TEST_ROOT/bin"
git init -q -b main "$PROJECT"
rm -rf "$PROJECT/.git/hooks"
mkdir -p "$PROJECT/.git/hooks"
git -C "$PROJECT" -c user.name=Fixture -c user.email=fixture@example.test -c commit.gpgsign=false commit -qm seed --allow-empty
git -C "$PROJECT" remote add origin "https://github.com/team/app.git"
printf '%s\n' '.cursor/' 'state.json' '.worktrees/' > "$PROJECT/.git/info/exclude"

cp "$ROOT/templates/cursor/.cursor/scripts/"*.sh "$PROJECT/.cursor/scripts/" 2>/dev/null || true
# Cursor may keep scripts only under scripts/; copy tree if needed
if [ ! -f "$PROJECT/.cursor/scripts/goal-git.sh" ]; then
  cp -R "$ROOT/templates/cursor/.cursor/." "$PROJECT/.cursor/"
fi
cp "$ROOT/templates/cursor/.cursor/scripts/goal-git.sh" "$PROJECT/.cursor/scripts/"
# Copy any sibling script modules referenced by goal-git.sh
for f in "$ROOT/templates/cursor/.cursor/scripts/"*.sh; do
  cp "$f" "$PROJECT/.cursor/scripts/"
done
if [ -f "$ROOT/templates/cursor/.cursor/goal-models.json" ]; then
  cp "$ROOT/templates/cursor/.cursor/goal-models.json" "$PROJECT/.cursor/"
fi
jq -n '{
  platform:"github",
  goal_source:"issues",
  target_branch:"main",
  issue_list_url:"https://github.com/team/app/issues",
  issue_limit:2,
  concurrency:2,
  forge_repo:"team/app"
}' > "$PROJECT/.cursor/goal-config.json"

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

G() { bash "$PROJECT/.cursor/scripts/goal-git.sh" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ ! -f "$PROJECT/state.json" ] || fail "state.json must not exist yet"

export GOAL_RUN_ID=run-queue-fixture GOAL_ID='' GOAL_ISSUE='' GOAL_GROUP='' GOAL_TASK='' GOAL_REPO=.
BEGIN=$(G issues plan begin --count 2)
echo "$BEGIN" | jq -e '.goal_id == "queue-run-queue-fixture" and .status == "planning" and (.issues|length)==2' >/dev/null \
  || { echo "$BEGIN"; fail "issues plan begin"; }
pass "issues plan begin on empty project"

export GOAL_ID=queue-run-queue-fixture
PLANNER="$(jq -r '."$routing".planner.NORMAL.model // .planner.NORMAL.model // empty' "$PROJECT/.cursor/goal-models.json" 2>/dev/null || true)"
if [ -z "$PLANNER" ] || [ "$PLANNER" = "null" ]; then
  PLANNER="$(G models planner --complexity NORMAL | cut -f1)"
fi
BUILDER="$(G models builder --complexity NORMAL | cut -f1)"

G harness spawn planner "$PLANNER" medium >/dev/null
pass "planner spawn on queue record"

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
pass "work-goal guard rejects commit on queue record"

printf '%s\n' '{"batches":[{"issues":[91,92],"parallel":true}],"concurrency":2}' \
  | G harness context put queue_plan -
DONE=$(G issues plan done)
echo "$DONE" | jq -e '.status == "planned"' >/dev/null || { echo "$DONE"; fail "issues plan done"; }
[ -f "$PROJECT/.cursor/queue-plans/run-queue-fixture.json" ] || fail "per-run plan file"
QUEUE=$(GOAL_ID='' G issues queue)
echo "$QUEUE" | jq -e 'type == "array" and length == 0' >/dev/null \
  || { echo "$QUEUE"; fail "issues queue must exclude queue record"; }
pass "plan done + issues queue excludes queue record"

echo "All Cursor queue planner bootstrap checks passed."
