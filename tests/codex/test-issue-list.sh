#!/usr/bin/env bash
# Guard machine-readable issue lists against CLI deprecation banners and bad JSON.
# Usage: AGENT=codex|cursor bash tests/codex/test-issue-list.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT="${AGENT:-${PLATFORM:-codex}}"
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
export TMPDIR="${TMPDIR:-$ROOT/.tmp-tests}"
mkdir -p "$TMPDIR"
TEST_ROOT="$(mktemp -d "$TMPDIR/${AGENT}-issue-list.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/project/$AGENT_DIR/scripts" "$TEST_ROOT/bin"
cp "$SRC_SCRIPTS/"*.sh "$TEST_ROOT/project/$AGENT_DIR/scripts/"

cat > "$TEST_ROOT/bin/glab" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
if args == ['--version']:
    print('mock 1.0'); sys.exit(0)
assert args[:2] == ['issue', 'list'], args
scenario = os.environ['MOCK_SCENARIO']
if '--opened' in args or scenario == 'warning':
    print('Flag --opened has been deprecated, default if --closed is not used.')
if scenario == 'failure':
    print('Authentication failed', file=sys.stderr)
    sys.exit(2)
if scenario == 'empty':
    print('[]')
elif scenario == 'object':
    print('{"message":"Unauthorized"}')
elif scenario == 'multiple':
    print('[]\n[]')
elif scenario != 'no-output':
    print(json.dumps([{
        'iid': 90, 'number': 90, 'title': 'Issue 90',
        'description': 'First line\nLiteral \\n and "quotes"',
        'body': 'First line\nLiteral \\n and "quotes"',
        'labels': ['test'], 'web_url': 'https://gitlab.example/team/app/-/issues/90',
        'created_at': '2026-10-01T00:00:00Z'
    }]))
PY
chmod +x "$TEST_ROOT/bin/glab"
cp "$TEST_ROOT/bin/glab" "$TEST_ROOT/bin/gh"

for platform in gitlab github; do
  if [ "$platform" = gitlab ]; then
    url='https://gitlab.example/team/app/-/issues'
  else
    url='https://github.com/team/app/issues'
  fi
  jq -n --arg platform "$platform" --arg url "$url" \
    '{platform:$platform,issue_list_url:$url,issue_limit:3}' \
    > "$TEST_ROOT/project/$AGENT_DIR/goal-config.json"
  for scenario in valid empty warning object multiple no-output failure; do
    result=0
    PATH="$TEST_ROOT/bin:$PATH" MOCK_SCENARIO="$scenario" \
      bash "$TEST_ROOT/project/$AGENT_DIR/scripts/goal-git.sh" issues list \
      > "$TEST_ROOT/output" 2> "$TEST_ROOT/error" || result=$?
    case "$scenario" in
      valid)
        if [ "$result" -ne 0 ]; then cat "$TEST_ROOT/error"; exit 1; fi
        python3 - "$TEST_ROOT/output" <<'PY'
import json
import sys
from pathlib import Path
issues = json.loads(Path(sys.argv[1]).read_text())
assert len(issues) == 1
assert issues[0]['number'] == 90
assert issues[0]['body'] == 'First line\nLiteral \\n and "quotes"'
assert issues[0]['labels'] == ['test']
PY
        ;;
      empty)
        test "$result" -eq 0
        test "$(jq length "$TEST_ROOT/output")" = 0
        ;;
      failure)
        test "$result" -eq 2
        rg -q 'Authentication failed' "$TEST_ROOT/error"
        ;;
      *)
        test "$result" -eq 1
        test ! -s "$TEST_ROOT/output"
        rg -q 'Issue list command returned invalid JSON or a non-array response' "$TEST_ROOT/error"
        ;;
    esac
    echo "PASS: $AGENT/$platform/$scenario"
  done
done
