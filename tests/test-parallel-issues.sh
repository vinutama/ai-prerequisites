#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/parallel-issues.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"

printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = issue ] && [ "$2" = view ]; then' \
  '  printf '\''{"number":%s,"title":"Issue %s","body":"Independent task","labels":[],"url":"https://github.com/acme/demo/issues/%s"}\n'\'' "$3" "$3" "$3"' \
  'else exit 1; fi' > "$TEST_ROOT/bin/gh"
chmod +x "$TEST_ROOT/bin/gh"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = issue ] && [ "$2" = view ]; then' \
  '  printf '\''{"iid":%s,"title":"Issue %s","description":"Independent task","labels":[],"web_url":"https://gitlab.com/acme/demo/-/issues/%s"}\n'\'' "$3" "$3" "$3"' \
  'else exit 1; fi' > "$TEST_ROOT/bin/glab"
chmod +x "$TEST_ROOT/bin/glab"

for agent in codex cursor; do
  for platform in github gitlab; do
  PROJECT="$TEST_ROOT/$agent-$platform"
  REMOTE="$TEST_ROOT/$agent-$platform-origin.git"
  mkdir -p "$PROJECT/.$agent/scripts"
  cp "$ROOT/templates/$agent/.$agent/scripts/goal-git.sh" "$PROJECT/.$agent/scripts/goal-git.sh"
  cp "$ROOT/templates/$agent/.$agent/scripts/delivery-groups.sh" "$PROJECT/.$agent/scripts/delivery-groups.sh"
  git init -q -b main "$PROJECT"
  git init -q --bare "$REMOTE"
  git -C "$PROJECT" config user.name Test
  git -C "$PROJECT" config user.email test@example.com
  git -C "$PROJECT" remote add origin "$REMOTE"
  printf 'base\n' > "$PROJECT/README.md"
  git -C "$PROJECT" add README.md ".$agent/scripts/goal-git.sh" ".$agent/scripts/delivery-groups.sh"
  git -C "$PROJECT" commit -qm base
  git -C "$PROJECT" push -q -u origin main
  if [ "$platform" = github ]; then
    ISSUE_LIST_URL=https://github.com/acme/demo/issues
  else
    ISSUE_LIST_URL=https://gitlab.com/acme/demo/-/issues
  fi
  jq -n --arg url "$ISSUE_LIST_URL" --arg platform "$platform" \
    '{issue_list_url:$url,target_branch:"main",platform:$platform,concurrency:3}' > "$PROJECT/.$agent/goal-config.json"
  SCRIPT="$PROJECT/.$agent/scripts/goal-git.sh"

  PATH="$TEST_ROOT/bin:$PATH" GOAL_RUN_ID=run-test "$SCRIPT" issues start 1 --worktree >/dev/null
  PATH="$TEST_ROOT/bin:$PATH" GOAL_RUN_ID=run-test "$SCRIPT" issues start 2 --worktree >/dev/null
  test -d "$PROJECT/.worktrees/issue-1"
  test -d "$PROJECT/.worktrees/issue-2"
  test ! -e "$PROJECT/.worktrees/issue-1/state.json"
  test ! -e "$PROJECT/.worktrees/issue-2/state.json"
  test "$(jq 'length' "$PROJECT/state.json")" = 2
  test "$(git -C "$PROJECT" branch --show-current)" = main
  test "$(git -C "$PROJECT/.worktrees/issue-1" branch --show-current)" != "$(git -C "$PROJECT/.worktrees/issue-2" branch --show-current)"
  printf 'first\n' > "$PROJECT/.worktrees/issue-1/issue-1.txt"
  printf 'second\n' > "$PROJECT/.worktrees/issue-2/issue-2.txt"
  PATH="$TEST_ROOT/bin:$PATH" GOAL_ISSUE=1 "$SCRIPT" stage issue-1.txt >/dev/null
  PATH="$TEST_ROOT/bin:$PATH" GOAL_ISSUE=2 "$SCRIPT" stage issue-2.txt >/dev/null
  test "$(git -C "$PROJECT/.worktrees/issue-1" diff --cached --name-only)" = issue-1.txt
  test "$(git -C "$PROJECT/.worktrees/issue-2" diff --cached --name-only)" = issue-2.txt
  test -z "$(git -C "$PROJECT" diff --cached --name-only)"

  PATH="$TEST_ROOT/bin:$PATH" GOAL_RUN_ID=run-test "$SCRIPT" issues start 1 --worktree >/dev/null
  test "$(jq 'length' "$PROJECT/state.json")" = 2
  PATH="$TEST_ROOT/bin:$PATH" GOAL_ISSUE=1 "$SCRIPT" continue >/dev/null
  test "$(git -C "$PROJECT" branch --show-current)" = main
  test "$(PATH="$TEST_ROOT/bin:$PATH" GOAL_ISSUE=1 "$SCRIPT" state | jq -r '.issue.number')" = 1
  test "$(PATH="$TEST_ROOT/bin:$PATH" GOAL_ISSUE=2 "$SCRIPT" state | jq -r '.issue.number')" = 2
  if PATH="$TEST_ROOT/bin:$PATH" GOAL_ISSUE=99 "$SCRIPT" state >/dev/null 2>&1; then
    echo "$agent silently selected a different issue" >&2
    exit 1
  fi
  mv "$PROJECT/.worktrees/issue-1" "$PROJECT/.worktrees/issue-1-hidden"
  if PATH="$TEST_ROOT/bin:$PATH" GOAL_ISSUE=1 "$SCRIPT" stage README.md >/dev/null 2>&1; then
    echo "$agent staged in the root checkout when an issue worktree was missing" >&2
    exit 1
  fi
  mv "$PROJECT/.worktrees/issue-1-hidden" "$PROJECT/.worktrees/issue-1"
  test -z "$(git -C "$PROJECT" diff --cached --name-only)"

  if PATH="$TEST_ROOT/bin:$PATH" "$SCRIPT" issues finish 1 >/dev/null 2>&1; then
    echo "$agent finished an issue without harness evidence" >&2
    exit 1
  fi
  test -d "$PROJECT/.worktrees/issue-1"
  jq '.[0].harness = {
    phase:"DONE", requirements:{planner:false,reviewer:false,qa:false,visual:false},
    gates:{IMPLEMENTATION:{status:"PASS"},ANALYSIS:{status:"PASS"},VERIFICATION:{status:"PASS"}}
  } | .[0].pr_url = "https://example.test/pr/1" | .[0].repos[0].pr_url = "https://example.test/pr/1"' \
    "$PROJECT/state.json" > "$PROJECT/state-test.tmp"
  mv "$PROJECT/state-test.tmp" "$PROJECT/state.json"
  if PATH="$TEST_ROOT/bin:$PATH" "$SCRIPT" issues finish 1 >/dev/null 2>&1; then
    echo "$agent removed a dirty issue worktree" >&2
    exit 1
  fi
  test "$(jq -r '.[0].status' "$PROJECT/state.json")" = in_progress
  PATH="$TEST_ROOT/bin:$PATH" GOAL_ISSUE=1 "$SCRIPT" commit "test: issue one" >/dev/null
  PATH="$TEST_ROOT/bin:$PATH" "$SCRIPT" issues finish 1 >/dev/null
  test ! -d "$PROJECT/.worktrees/issue-1"
  test -d "$PROJECT/.worktrees/issue-2"
  test "$(jq -r '.[0].status' "$PROJECT/state.json")" = completed
  test "$(jq -r '.[1].status' "$PROJECT/state.json")" = in_progress
  echo "PASS: $agent/$platform starts two isolated issues, reuses state on resume, and guards finish"
  done
done
