#!/usr/bin/env bash
# Per-platform fresh-runtime reset. Shared state.json keeps the other platform.
# Usage: AGENT=codex|cursor|claude bash tests/codex/test-reset.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT="${AGENT:-${PLATFORM:-codex}}"
# OTHER is the platform used to prove that its runtime and config survive.
case "$AGENT" in
  codex) OTHER=cursor; SELF_DIR=.codex; OTHER_DIR=.cursor; ROOT_DOC=AGENTS.md ;;
  cursor) OTHER=codex; SELF_DIR=.cursor; OTHER_DIR=.codex; ROOT_DOC=AGENTS.md ;;
  claude) OTHER=codex; SELF_DIR=.claude; OTHER_DIR=.codex; ROOT_DOC=CLAUDE.md ;;
  *) echo "Unknown AGENT=$AGENT (expected codex|cursor|claude)" >&2; exit 1 ;;
esac
export TMPDIR="${TMPDIR:-$ROOT/.tmp-tests}"
mkdir -p "$TMPDIR"
TEST_ROOT="$(mktemp -d "$TMPDIR/reset.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
PROJECT="$TEST_ROOT/project"
git init -q -b main "$PROJECT"
git -C "$PROJECT" config user.name Fixture
git -C "$PROJECT" config user.email fixture@example.test
echo seed > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit -qm seed
bash "$ROOT/init.sh" --cursor "$PROJECT" >/dev/null
bash "$ROOT/init.sh" --codex "$PROJECT" >/dev/null
bash "$ROOT/init.sh" --claude "$PROJECT" >/dev/null

if bash "$ROOT/init.sh" --reset --clean --cursor "$PROJECT" >/dev/null 2>&1; then
  echo "FAIL: --reset combined with --clean should be rejected" >&2
  exit 1
fi
echo "PASS: --reset rejects --clean"

git -C "$PROJECT" worktree add -q -b feat/self-goal "$PROJECT/.worktrees/feat-self-goal"
git -C "$PROJECT" worktree add -q -b feat/dirty-goal "$PROJECT/.worktrees/feat-dirty-goal"
echo dirty > "$PROJECT/.worktrees/feat-dirty-goal/DIRTY.txt"
git -C "$PROJECT" worktree add -q -b feat/other-goal "$PROJECT/.worktrees/feat-other-goal"

jq -n --arg self "$AGENT" --arg other "$OTHER" '{
  goals: [
    {id:"self-tagged", agent_platform:$self, branch:"feat/self-goal", worktree:".worktrees/feat-self-goal", status:"in_progress", spawn_reservations:[]},
    {id:"self-dirty", agent_platform:$self, branch:"feat/dirty-goal", worktree:".worktrees/feat-dirty-goal", status:"in_progress", spawn_reservations:[]},
    {id:"other-tagged", agent_platform:$other, branch:"feat/other-goal", worktree:".worktrees/feat-other-goal", status:"completed", spawn_reservations:[]},
    {id:"infer-inherit", branch:"feat/inherit", status:"completed", spawn_reservations:[{model:"inherit"}]},
    {id:"infer-named", branch:"feat/named", status:"completed", spawn_reservations:[{model:"gpt-test"}]},
    {id:"unknown-owner", branch:"feat/unknown", status:"planned", spawn_reservations:[]}
  ]
} | .goals' > "$PROJECT/state.json"

mkdir -p "$PROJECT/.goal-review" "$PROJECT/$SELF_DIR" "$PROJECT/$OTHER_DIR"
printf 'review-self\n' > "$PROJECT/.goal-review/feat-self-goal.json"
printf 'review-other\n' > "$PROJECT/.goal-review/feat-other-goal.json"
printf 'SECRET-%s\n' "$AGENT" > "$PROJECT/$SELF_DIR/goal-progress.log"
printf 'SECRET-%s\n' "$OTHER" > "$PROJECT/$OTHER_DIR/goal-progress.log"
printf 'plan\n' > "$PROJECT/$SELF_DIR/queue-plan.json"
printf 'KEEP-CONFIG\n' > "$PROJECT/$SELF_DIR/goal-config.json"
printf 'KEEP-OTHER\n' > "$PROJECT/$OTHER_DIR/goal-config.json"
mkdir -p "$PROJECT/$SELF_DIR/.state.lock"
HELPER="$PROJECT/$SELF_DIR/scripts/goal-git.sh"
if "$HELPER" reset runtime --yes >/dev/null 2>"$TEST_ROOT/lock.err"; then
  echo "FAIL: reset should refuse while the state lock exists" >&2
  exit 1
fi
rmdir "$PROJECT/$SELF_DIR/.state.lock"
echo "PASS: active state lock refuses reset"

if "$HELPER" reset runtime --yes >"$TEST_ROOT/dirty.out" 2>"$TEST_ROOT/dirty.err"; then
  echo "FAIL: dirty worktree should refuse reset without --force" >&2
  exit 1
fi
grep -q 'uncommitted changes' "$TEST_ROOT/dirty.err" || { echo "FAIL: dirty refusal lacked the expected error" >&2; cat "$TEST_ROOT/dirty.err" >&2; exit 1; }
echo "PASS: dirty worktree refuses reset without --force"
# Nothing was removed.
test -d "$PROJECT/.worktrees/feat-self-goal"
test -f "$PROJECT/$SELF_DIR/goal-progress.log"
jq -e 'map(.id) | index("self-tagged") != null' "$PROJECT/state.json" >/dev/null

other_before="$(cksum "$PROJECT/$OTHER_DIR/goal-progress.log" "$PROJECT/$OTHER_DIR/goal-config.json")"
"$HELPER" reset runtime --yes --force >"$TEST_ROOT/reset.json"
echo "PASS: --force reset exits 0"
jq -e --arg self "$AGENT" '.platform == $self and (.removed | index("self-tagged")) and (.removed | index("self-dirty"))' "$TEST_ROOT/reset.json" >/dev/null
jq -e '.kept | index("other-tagged")' "$TEST_ROOT/reset.json" >/dev/null
jq -e '.unknown | index("unknown-owner")' "$TEST_ROOT/reset.json" >/dev/null
if [ "$AGENT" = cursor ]; then
  jq -e '.removed | index("infer-inherit")' "$TEST_ROOT/reset.json" >/dev/null
  jq -e '.kept | index("infer-named")' "$TEST_ROOT/reset.json" >/dev/null
elif [ "$AGENT" = claude ]; then
  # Untagged goals with named models are inferred as Codex; inherit as Cursor.
  jq -e '.kept | index("infer-inherit")' "$TEST_ROOT/reset.json" >/dev/null
  jq -e '.kept | index("infer-named")' "$TEST_ROOT/reset.json" >/dev/null
else
  jq -e '.kept | index("infer-inherit")' "$TEST_ROOT/reset.json" >/dev/null
  jq -e '.removed | index("infer-named")' "$TEST_ROOT/reset.json" >/dev/null
fi
echo "PASS: only this platform's goals are removed"

test ! -d "$PROJECT/.worktrees/feat-self-goal"
test ! -d "$PROJECT/.worktrees/feat-dirty-goal"
test -d "$PROJECT/.worktrees/feat-other-goal"
test ! -f "$PROJECT/.goal-review/feat-self-goal.json"
test -f "$PROJECT/.goal-review/feat-other-goal.json"
test ! -f "$PROJECT/$SELF_DIR/goal-progress.log"
test ! -f "$PROJECT/$SELF_DIR/queue-plan.json"
grep -q 'KEEP-CONFIG' "$PROJECT/$SELF_DIR/goal-config.json"
compgen -G "$PROJECT/$SELF_DIR/backups/state-*.json" >/dev/null
other_after="$(cksum "$PROJECT/$OTHER_DIR/goal-progress.log" "$PROJECT/$OTHER_DIR/goal-config.json")"
[ "$other_before" = "$other_after" ]
echo "PASS: other platform runtime is unchanged and config is kept"

exclude="$(cat "$PROJECT/.git/info/exclude")"
printf '%s\n' "$exclude" | grep -qxF '.codex/'
printf '%s\n' "$exclude" | grep -qxF '.cursor/'
printf '%s\n' "$exclude" | grep -qxF '.claude/'
echo "PASS: exclude block lists every installed platform"

# init.sh --reset upgrades scripts and keeps the shared root doc while another
# platform that uses it is still installed (CLAUDE.md is never shared).
printf 'CUSTOM-DOC\n' > "$PROJECT/$ROOT_DOC"
bash "$ROOT/init.sh" --reset "--$AGENT" "$PROJECT" >"$TEST_ROOT/init-reset.log"
if [ "$AGENT" = claude ]; then
  grep -q 'Claude Code goal workflow' "$PROJECT/$ROOT_DOC"
else
  grep -q 'CUSTOM-DOC' "$PROJECT/$ROOT_DOC"
fi
grep -q 'Reset complete' "$TEST_ROOT/init-reset.log"
echo "PASS: init.sh --reset handles the root doc and completes"

echo "PASS: reset ($AGENT)"
