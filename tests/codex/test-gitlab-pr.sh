#!/usr/bin/env bash
# Exercise GitLab MR creation through the public helper with a local CLI stub.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/codex-gitlab-pr.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

cat > "$TEST_ROOT/glab" <<'PY'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
fixture = Path(os.environ['MOCK_DIR']).resolve()
scenario = os.environ['MOCK_SCENARIO']
created = fixture / 'created'
url = 'https://gitlab.internal.example/team/service/-/merge_requests/24'
with (fixture / 'calls').open('a') as log:
    log.write(json.dumps(args) + '\n')
assert Path.cwd() == fixture / '.worktrees/issue-90', Path.cwd()
if args[:2] == ['mr', 'view']:
    assert args[2:] == ['feat/issue-90', '--output', 'json'], args
    if scenario == 'existing' or (created.exists() and scenario in ('new', 'race')):
        print(json.dumps({'iid': 24, 'web_url': url}))
    elif scenario == 'malformed':
        print('{}')
    else:
        print('No merge request found', file=sys.stderr)
        sys.exit(1)
elif args[:2] == ['mr', 'create']:
    assert '--output' not in args, args
    assert args[args.index('--source-branch') + 1] == 'feat/issue-90', args
    assert args[args.index('--target-branch') + 1] == 'development', args
    assert args[args.index('--description') + 1] == 'First line\nSecond line\n\nCloses #90', args
    created.touch()
    if scenario in ('failure', 'race'):
        print('403: merge request creation denied', file=sys.stderr)
        sys.exit(2)
    if scenario == 'malformed':
        print('Submitted without metadata')
    else:
        print('Created merge request: ' + url)
else:
    raise AssertionError(args)
PY
chmod +x "$TEST_ROOT/glab"

for scenario in new existing fallback failure race malformed; do
  PROJECT="$TEST_ROOT/$scenario workflow root"
  mkdir -p "$PROJECT/.codex/scripts" "$PROJECT/.worktrees/issue-90" "$PROJECT/bin"
  cp "$ROOT/templates/codex/.codex/scripts/"*.sh "$PROJECT/.codex/scripts/"
  cp "$TEST_ROOT/glab" "$PROJECT/bin/glab"
  printf '%s\n' '{"platform":"gitlab"}' > "$PROJECT/.codex/goal-config.json"
  jq -n '[
    {issue: {number: 88}, branch: "feat/issue-88", pr_number: null},
    {issue: {number: 90}, branch: "feat/issue-90", base_branch: "development",
     goal: "First line\nSecond line", worktree: ".worktrees/issue-90",
     repos: [{path: ".", pr_number: null, pr_url: ""}]}
  ]' > "$PROJECT/state.json"
  result=0
  (
    cd "$PROJECT/.worktrees/issue-90"
    PATH="$PROJECT/bin:$PATH" MOCK_DIR="$PROJECT" MOCK_SCENARIO="$scenario" \
      GOAL_ISSUE=90 bash "$PROJECT/.codex/scripts/goal-git.sh" pr
  ) > "$PROJECT/output" 2>&1 || result=$?

  case "$scenario" in
    failure|malformed)
      test "$result" -ne 0
      test "$(jq -r '.[1].repos[0].pr_number' "$PROJECT/state.json")" = null
      if [ "$scenario" = failure ]; then
        rg -q '403: merge request creation denied' "$PROJECT/output"
        rg -q 'exit 2' "$PROJECT/output"
      else
        rg -q 'Failed to resolve GitLab MR metadata' "$PROJECT/output"
      fi
      ;;
    *)
      if [ "$result" -ne 0 ]; then cat "$PROJECT/output"; exit 1; fi
      test "$(jq -r '.[1].repos[0].pr_number' "$PROJECT/state.json")" = 24
      test "$(jq -r '.[1].repos[0].pr_url' "$PROJECT/state.json")" = \
        'https://gitlab.internal.example/team/service/-/merge_requests/24'
      ;;
  esac
  test "$(jq -r '.[0].pr_number' "$PROJECT/state.json")" = null
  if [ "$scenario" = existing ]; then
    test "$(wc -l < "$PROJECT/calls" | tr -d ' ')" = 1
  else
    test "$(rg -c '"create"' "$PROJECT/calls")" = 1
  fi
  echo "PASS: $scenario (issue selection, worktree, MR metadata, CLI calls)"
done
