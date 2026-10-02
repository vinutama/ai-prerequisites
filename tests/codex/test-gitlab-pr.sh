#!/usr/bin/env bash
# Public-helper GitLab delivery with real commits and a local bare transport.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/codex-gitlab-pr.XXXXXX)"
trap 'rc=$?; if [ "$rc" -ne 0 ] && [ -n "${CASE_DIR:-}" ]; then cat "$CASE_DIR/output" 2>/dev/null || true; cat "$CASE_DIR/calls" 2>/dev/null || true; fi; rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"

cat > "$TEST_ROOT/bin/glab" <<'PY_MOCK'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
root = Path(os.environ['MOCK_DIR'])
scenario = os.environ['MOCK_SCENARIO']
created = root / 'created'
with (root / 'calls').open('a') as log:
    log.write(json.dumps(args) + '\n')
assert '--web' not in args and '-w' not in args
assert args[:2] != ['auth', 'login']
if args == ['--version']:
    print('glab version 1.99.0 (test)')
    sys.exit()
if '--help' in args:
    flags = ['--source-branch', '--target-branch', '--output', '--page',
             '--per-page', '--repo', '--title', '--yes', '--description-file',
             '--hostname', '--method']
    print('\n'.join('  ' + flag + ' value  Supported' for flag in flags))
    sys.exit()
if args[:2] == ['auth', 'status']:
    sys.exit()
# Forge identity is explicit; the helper dispatches from WORKFLOW_ROOT.
assert Path.cwd() == Path(os.environ['MOCK_WORKTREE']).resolve().parents[1], Path.cwd()
obj = {'iid': 24, 'web_url': 'https://gitlab.com/team/repo/-/merge_requests/24',
       'source_branch': 'feat/issue-90', 'target_branch': 'development',
       'sha': os.environ['MOCK_SHA'], 'state': 'opened',
       'source_project_id': 42, 'target_project_id': 42}
if args[0] == 'mr':
    assert args[args.index('--repo') + 1] == 'https://gitlab.com/team/repo', args
if args[:2] == ['mr', 'list']:
    assert args[args.index('--source-branch') + 1] == 'feat/issue-90'
    assert args[args.index('--target-branch') + 1] == 'development'
    if scenario == 'read-uncertain':
        print('HTTP 403 forbidden', file=sys.stderr)
        sys.exit(7)
    if scenario == 'malformed':
        print('{}')
    else:
        print(json.dumps([obj] if created.exists() or scenario == 'existing' else []))
elif args[:2] == ['mr', 'view']:
    assert args[2] == '24', args
    countfile = root / 'views'
    count = int(countfile.read_text()) + 1 if countfile.exists() else 1
    countfile.write_text(str(count))
    if scenario == 'stale-sha' or (scenario == 'read-reconciliation' and count == 1):
        obj['sha'] = '0' * 40
    if scenario == 'wrong-base':
        obj['target_branch'] = 'wrong-base'
    print(json.dumps(obj))
elif args[0] == 'api':
    assert args[args.index('--hostname') + 1] == 'gitlab.com', args
    assert 'projects/team%2Frepo/merge_requests/24/diffs' in args[1], args
    assert args[args.index('--method') + 1] == 'GET', args
    print(json.dumps([{'new_path': path} for path in json.loads(os.environ['MOCK_FILES'])]))
elif args[:2] in (['mr', 'create'], ['mr', 'update']):
    assert '--output' not in args, args
    assert args[args.index('--title') + 1] == os.environ['MOCK_TITLE'], args
    body = Path(args[args.index('--description-file') + 1]).read_text()
    assert body.rstrip() == (root / 'body.md').read_text().rstrip() + '\n\nCloses #90', repr(body)
    (root / 'sent-body').write_text(body)
    if args[1] == 'create':
        assert not created.exists(), 'duplicate creation'
        assert args[args.index('--source-branch') + 1] == 'feat/issue-90'
        assert args[args.index('--target-branch') + 1] == 'development'
        assert '--yes' in args
    else:
        assert args[2] == '24'
    created.touch()
    if scenario == 'accepted-failure' and args[1] == 'create':
        print('connection reset after accepted mutation', file=sys.stderr)
        sys.exit(7)
    # Unstructured create output cannot supply completion evidence.
    print('Submitted request; read it back for metadata')
else:
    raise AssertionError(args)
PY_MOCK
chmod +x "$TEST_ROOT/bin/glab"

for scenario in new existing read-reconciliation accepted-failure read-uncertain \
  malformed stale-sha empty-files wrong-base empty-diff unpublished stale-remote \
  dirty wrong-branch missing-body long-title multiline-title; do
  CASE_DIR="$TEST_ROOT/$scenario"
  PROJECT="$CASE_DIR/workflow root"
  REMOTE="$CASE_DIR/remote.git"
  WORKTREE="$PROJECT/.worktrees/issue-90"
  mkdir -p "$PROJECT/.codex/scripts"
  cp "$ROOT/templates/codex/.codex/scripts/"*.sh "$PROJECT/.codex/scripts/"
  git init --bare -q "$REMOTE"
  git init -q -b development "$PROJECT"
  git -C "$PROJECT" config user.name 'Delivery Test'
  git -C "$PROJECT" config user.email 'delivery-test@example.invalid'
  git -C "$PROJECT" config commit.gpgsign false
  git -C "$PROJECT" config core.hooksPath /dev/null
  printf '.codex/\n.agents/\nstate.json\n.worktrees/\n.goal-review/\n' > "$PROJECT/.gitignore"
  printf 'base\n' > "$PROJECT/base.txt"
  git -C "$PROJECT" add .gitignore base.txt
  git -C "$PROJECT" commit -qm 'chore: seed development'
  git -C "$PROJECT" remote add origin "$REMOTE"
  git -C "$PROJECT" push -q origin development
  git -C "$PROJECT" worktree add -q -b feat/issue-90 "$WORKTREE"
  if [ "$scenario" != empty-diff ]; then
    printf 'health response\n' > "$WORKTREE/feature.txt"
    git -C "$WORKTREE" add feature.txt
    git -C "$WORKTREE" commit -qm 'feat: add health response'
  fi
  if [ "$scenario" != unpublished ]; then
    git -C "$WORKTREE" push -q origin feat/issue-90
  fi
  case "$scenario" in
    stale-remote)
      printf 'additional behavior\n' >> "$WORKTREE/feature.txt"
      git -C "$WORKTREE" add feature.txt
      git -C "$WORKTREE" commit -qm 'fix: handle additional behavior'
      ;;
    dirty) printf 'uncommitted\n' >> "$WORKTREE/feature.txt" ;;
    wrong-branch) git -C "$WORKTREE" checkout -qb unrelated ;;
  esac
  # The fixture mirrors managed sync without invoking internal modules.
  mkdir -p "$WORKTREE/.codex/scripts"
  cp "$PROJECT/.codex/scripts/"*.sh "$WORKTREE/.codex/scripts/"
  printf '%s\n' "$PROJECT" > "$WORKTREE/.codex/workflow-root"
  printf '%s\n' '{"platform":"gitlab","forge_repo":"https://gitlab.com/team/repo","repos":[]}' > "$PROJECT/.codex/goal-config.json"
  jq -n '[
    {id:"goal-88",run_id:"prior-run",issue:{number:88,repo:"https://gitlab.com/team/repo"},
     branch:"feat/issue-88",pr_number:null,status:"in_progress"},
    {id:"goal-90",run_id:"test-run",issue:{number:90,repo:"https://gitlab.com/team/repo"},
     branch:"feat/issue-90",base_branch:"development",status:"in_progress",
     goal:"Full original objective\nAcceptance details stay in the source, not the title",
     worktree:".worktrees/issue-90",repos:[{path:".",pr_number:null,pr_url:""}]}
  ]' > "$PROJECT/state.json"
  cat > "$CASE_DIR/body.md" <<'BODY'
Implement a focused health response for issue #90 while preserving the existing development branch behavior. The change adds a small tracked feature file in the assigned issue worktree and keeps workflow configuration outside the application diff. The original full objective and its acceptance details remain available as source context; the merge request uses a concise descriptive title and this implementation summary.

Checks use a real temporary Git repository and a local bare remote. The source commit is pushed before publication, and the helper confirms that the checkout is clean and the target comparison contains changes. Mock GitLab metadata reports the same committed SHA, source branch, target branch, and changed files. Delivery must reject incomplete or inconsistent metadata instead of claiming a successful merge request. Reference: team/repo issue #90.
BODY
  export MOCK_DIR="$CASE_DIR" MOCK_WORKTREE="$WORKTREE" MOCK_SCENARIO="$scenario"
  export MOCK_SHA="$(git -C "$WORKTREE" rev-parse HEAD)" MOCK_FILES='["feature.txt"]'
  export MOCK_TITLE='feat: add health response'
  [ "$scenario" != empty-files ] || MOCK_FILES='[]'
  title="$MOCK_TITLE"
  case "$scenario" in
    long-title) title="$(printf '%080d' 0)" ;;
    multiline-title) title=$'feat: health response\nlegacy objective' ;;
  esac
  result=0
  (
    cd "$WORKTREE"
    export PATH="$TEST_ROOT/bin:$PATH" FORGE_CACHE_DIR="$CASE_DIR/cache"
    export FORGE_RETRY_WAIT_OVERRIDE=0 GOAL_METADATA_RETRY_DELAY=0
    export GOAL_ID=goal-90 GOAL_RUN_ID=test-run GOAL_ISSUE=90
    export GOAL_ISSUE_REPO=https://gitlab.com/team/repo GOAL_GROUP='' GOAL_TASK='' GOAL_REPO=.
    if [ "$scenario" = missing-body ]; then
      bash "$WORKTREE/.codex/scripts/goal-git.sh" pr --title "$title"
    else
      bash "$WORKTREE/.codex/scripts/goal-git.sh" pr --title "$title" --body-file "$CASE_DIR/body.md"
    fi
  ) > "$CASE_DIR/output" 2>&1 || result=$?

  expected=fail
  case "$scenario" in new|existing|read-reconciliation|accepted-failure) expected=pass ;; esac
  if [ "$expected" = pass ]; then
    test "$result" -eq 0
    jq -e --arg sha "$MOCK_SHA" '.[1] | .repos[0].pr_number==24 and
      .repos[0].pr_url=="https://gitlab.com/team/repo/-/merge_requests/24" and
      .repos[0].delivery.validated==true and .repos[0].delivery.verified_sha==$sha and
      .repos[0].delivery.files==["feature.txt"]' "$PROJECT/state.json" >/dev/null
  else
    test "$result" -ne 0
    jq -e '.[1] | .repos[0].pr_number==null and .repos[0].pr_url=="" and
      (.repos[0].delivery.validated // false)==false and .status=="in_progress"' "$PROJECT/state.json" >/dev/null
  fi
  jq -e '.[0] | .pr_number==null and .run_id=="prior-run"' "$PROJECT/state.json" >/dev/null
  expected_create=0
  expected_update=0
  case "$scenario" in
    new|read-reconciliation|accepted-failure|stale-sha|empty-files|wrong-base) expected_create=1 ;;
    existing) expected_update=1 ;;
  esac
  python3 - "$CASE_DIR" "$expected_create" "$expected_update" "$scenario" <<'PY_ASSERT'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
calls = [json.loads(line) for line in (root / 'calls').read_text().splitlines()] if (root / 'calls').exists() else []
operations = [a for a in calls if '--help' not in a and a != ['--version']]
assert sum(a[:2] == ['mr', 'create'] for a in operations) == int(sys.argv[2]), operations
assert sum(a[:2] == ['mr', 'update'] for a in operations) == int(sys.argv[3]), operations
if sys.argv[4] == 'read-reconciliation':
    assert sum(a[:2] == ['mr', 'view'] for a in operations) >= 2, operations
if sys.argv[4] in ('empty-diff', 'unpublished', 'stale-remote', 'dirty', 'wrong-branch',
                   'missing-body', 'long-title', 'multiline-title'):
    assert not operations, operations
if sys.argv[4] in ('new', 'existing', 'read-reconciliation', 'accepted-failure'):
    assert sum(a[:2] == ['mr', 'list'] for a in operations) >= 2, operations
PY_ASSERT

  case "$scenario" in
    read-uncertain) rg -q 'permission' "$CASE_DIR/output" ;;
    malformed) rg -q 'invalid_json' "$CASE_DIR/output" ;;
    accepted-failure) rg -q 'transient' "$CASE_DIR/output" ;;
    stale-sha|empty-files) rg -q 'delivery_metadata' "$CASE_DIR/output" ;;
    wrong-base) rg -q 'uncertain' "$CASE_DIR/output" ;;
    empty-diff) rg -q 'empty_diff' "$CASE_DIR/output" ;;
    unpublished) rg -q 'unpublished' "$CASE_DIR/output" ;;
    stale-remote) rg -q 'stale_remote' "$CASE_DIR/output" ;;
    dirty) rg -q 'dirty_checkout' "$CASE_DIR/output" ;;
    wrong-branch) rg -q 'assignment' "$CASE_DIR/output" ;;
    missing-body) rg -q 'pr_body' "$CASE_DIR/output" ;;
    long-title|multiline-title) rg -q 'pr_title' "$CASE_DIR/output" ;;
  esac

  if [ "$scenario" = accepted-failure ]; then
    # A later explicit update reuses the reconciled request, never recreates it.
    (
      cd "$WORKTREE"
      export PATH="$TEST_ROOT/bin:$PATH" FORGE_CACHE_DIR="$CASE_DIR/cache"
      export FORGE_RETRY_WAIT_OVERRIDE=0 GOAL_METADATA_RETRY_DELAY=0
      export GOAL_ID=goal-90 GOAL_RUN_ID=test-run GOAL_ISSUE=90
      export GOAL_ISSUE_REPO=https://gitlab.com/team/repo GOAL_GROUP='' GOAL_TASK='' GOAL_REPO=.
      bash "$WORKTREE/.codex/scripts/goal-git.sh" pr --title "$MOCK_TITLE" --body-file "$CASE_DIR/body.md"
    ) >> "$CASE_DIR/output" 2>&1
    jq -e --arg sha "$MOCK_SHA" '.[1].repos[0].delivery |
      .validated==true and .verified_sha==$sha' "$PROJECT/state.json" >/dev/null
    python3 - "$CASE_DIR/calls" <<'PY_RETRY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
calls = [a for a in calls if '--help' not in a]
assert sum(a[:2] == ['mr', 'create'] for a in calls) == 1
assert sum(a[:2] == ['mr', 'update'] for a in calls) == 1
PY_RETRY
  fi
  printf 'PASS: %s (real Git, selected issue, fail-closed delivery)\n' "$scenario"
done
