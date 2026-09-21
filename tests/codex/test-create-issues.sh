#!/usr/bin/env bash
# Deterministic tests for create-issues helper (no real forge calls).
# Usage: AGENT=codex|cursor bash tests/codex/test-create-issues.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT="${AGENT:-codex}"
case "$AGENT" in
  codex)
    SCRIPT="$ROOT/templates/codex/.agents/skills/create-issues/scripts/create-issues.sh"
    ;;
  cursor)
    SCRIPT="$ROOT/templates/cursor/.cursor/skills/create-issues/scripts/create-issues.sh"
    ;;
  *)
    echo "Unknown AGENT=$AGENT (expected codex|cursor)" >&2
    exit 1
    ;;
esac
PASS=0
FAIL=0

echo "=== create-issues tests (AGENT=$AGENT) ==="
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

WORKDIR="$(mktemp -d /tmp/create-issues.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

chmod +x "$SCRIPT"

EXAMPLE="$WORKDIR/plan.md"
cat > "$EXAMPLE" <<'EOF'
## Set up dev and prod data infrastructure stack
Labels: infra, enhancement
Assignee: @me
Milestone: v1

Epic summary paragraph(s) describing scope and deviations...

### Acceptance
- [ ] `make dev-up` brings up Traefik, Postgres, Redis, MinIO, MailHog
- [ ] Cross-database isolation holds

### Tasks

**Phase 1 — Repo scaffolding**
- [ ] Remove the stray empty `Users/` directory; extend `.gitignore`
- [ ] Create tree: `traefik/{dev,prod}/`, `postgres/init/{dev,prod}/`

**Phase 2 — Postgres init**
- [ ] `postgres/init/dev/01-databases.sql`: roles and REVOKE lines
EOF

echo "== bash -n"
if bash -n "$SCRIPT"; then
  ok "bash -n create-issues.sh"
else
  fail "bash -n create-issues.sh"
fi

echo "== example plan produces three issues, not five"
JSON=$("$SCRIPT" parse "$EXAMPLE")
n=$(echo "$JSON" | jq 'length')
assert_eq "$n" "3" "example yields 3 task issues"

echo "== labels, assignees, milestone, summary, acceptance inherited"
t0=$(echo "$JSON" | jq -r '.[0]')
assert_eq "$(echo "$t0" | jq -c '.labels')" '["infra","enhancement"]' "inherited labels"
assert_eq "$(echo "$t0" | jq -c '.assignees')" '["@me"]' "inherited @me assignee"
assert_eq "$(echo "$t0" | jq -r '.milestone')" "v1" "inherited milestone"
assert_contains "$(echo "$t0" | jq -r '.body')" "Epic summary paragraph" "epic summary in body"
assert_contains "$(echo "$t0" | jq -r '.body')" "make dev-up" "acceptance copied into body"
assert_contains "$(echo "$t0" | jq -r '.body')" "## Task" "body has Task section"

echo "== phase prefixes and phase resets across epics"
assert_contains "$(echo "$JSON" | jq -r '.[0].title')" "[Phase 1]" "phase 1 prefix on first task"
assert_contains "$(echo "$JSON" | jq -r '.[0].title')" "Users/" "phase 1 task text"
assert_contains "$(echo "$JSON" | jq -r '.[2].title')" "Phase 2" "phase 2 prefix on third task"
assert_contains "$(echo "$JSON" | jq -r '.[2].title')" "01-databases.sql" "phase 2 task text"

MULTI="$WORKDIR/multi.md"
cat > "$MULTI" <<'EOF'
## Epic A
Labels: a

### Tasks
**Phase 1 — A**
- [ ] Task A1

## Epic B
Labels: b

### Tasks
- [ ] Task B1
EOF
MJSON=$("$SCRIPT" parse "$MULTI")
assert_eq "$(echo "$MJSON" | jq -r '.[0].title')" "[Phase 1] Task A1" "epic A keeps phase"
assert_eq "$(echo "$MJSON" | jq -r '.[1].title')" "Task B1" "epic B resets phase"
assert_eq "$(echo "$MJSON" | jq -c '.[1].labels')" '["b"]' "epic B resets labels"

echo "== tasks outside ### Tasks are ignored"
OUTSIDE="$WORKDIR/outside.md"
cat > "$OUTSIDE" <<'EOF'
## Epic
### Notes
- [ ] Do not create this
### Tasks
- [ ] Real task
### Follow-up
- [ ] Also ignore this
EOF
OJSON=$("$SCRIPT" parse "$OUTSIDE")
assert_eq "$(echo "$OJSON" | jq 'length')" "1" "only ### Tasks checkboxes become issues"
assert_eq "$(echo "$OJSON" | jq -r '.[0].title')" "Real task" "kept the Tasks checkbox"

echo "== - [ ] and - [x] are both parsed"
CHECKED="$WORKDIR/checked.md"
cat > "$CHECKED" <<'EOF'
## Epic
### Tasks
- [ ] Open
- [x] Done
- [X] Also done
EOF
CJSON=$("$SCRIPT" parse "$CHECKED")
assert_eq "$(echo "$CJSON" | jq 'length')" "3" "unchecked and checked tasks parse"

echo "== title capped at 200 characters"
LONG="$WORKDIR/long.md"
long_task=$(printf 'A%.0s' {1..250})
cat > "$LONG" <<EOF
## Epic
### Tasks
- [ ] ${long_task}
EOF
LJSON=$("$SCRIPT" parse "$LONG")
ltitle=$(echo "$LJSON" | jq -r '.[0].title')
llen=${#ltitle}
if [ "$llen" -eq 200 ] && echo "$ltitle" | grep -q '\.\.\.$'; then
  ok "title truncated to 200 with ..."
else
  fail "title length $llen (want 200 ending with ...)"
fi

echo "== JSON stays valid with quotes, backticks, unicode, newlines, spaces"
WEIRD="$WORKDIR/weird.md"
cat > "$WEIRD" <<'EOF'
## Epic "quotes" and café
Labels: spaced label, other

Summary with `code` and “smart quotes”
and a newline paragraph.

### Tasks
- [ ] Handle "quotes", `backticks`, café, and spaces
EOF
WJSON=$("$SCRIPT" parse "$WEIRD")
if echo "$WJSON" | jq -e . >/dev/null; then
  ok "weird markdown produces valid JSON"
else
  fail "weird markdown was not valid JSON"
fi
assert_contains "$(echo "$WJSON" | jq -r '.[0].title')" 'café' "unicode preserved in title"
assert_contains "$(echo "$WJSON" | jq -r '.[0].title')" '`backticks`' "backticks preserved"
assert_contains "$(echo "$WJSON" | jq -r '.[0].body')" 'smart quotes' "summary newlines/unicode in body"

echo "== missing file and empty plan fail clearly"
if "$SCRIPT" parse "$WORKDIR/nope.md" >/dev/null 2>"$WORKDIR/err-missing.txt"; then
  fail "missing file did not fail"
else
  assert_contains "$(cat "$WORKDIR/err-missing.txt")" "File not found" "missing file error"
fi
EMPTY="$WORKDIR/empty.md"
echo "# No epics here" > "$EMPTY"
if "$SCRIPT" parse "$EMPTY" >/dev/null 2>"$WORKDIR/err-empty.txt"; then
  fail "empty plan did not fail"
else
  assert_contains "$(cat "$WORKDIR/err-empty.txt")" "No task checkboxes" "no-tasks error"
fi

echo "== create --dry-run performs no external mutation"
DRY_LOG="$WORKDIR/dry.log"
"$SCRIPT" create "$EXAMPLE" --platform github --repo owner/repo --dry-run >"$DRY_LOG" 2>&1
assert_contains "$(cat "$DRY_LOG")" "no issues created" "dry-run reports no creation"
assert_contains "$(cat "$DRY_LOG")" "does not call gh/glab" "dry-run skips forge CLIs"
assert_contains "$(cat "$DRY_LOG")" "platform=github" "dry-run shows platform"
assert_contains "$(cat "$DRY_LOG")" "repo: owner/repo" "dry-run shows repo"
assert_contains "$(cat "$DRY_LOG")" "title: [Phase 1]" "dry-run shows titles"
assert_contains "$(cat "$DRY_LOG")" "infra" "dry-run shows inherited labels"
assert_contains "$(cat "$DRY_LOG")" "body-file" "dry-run shows body-file intent"
if grep -Eiq 'created https?://' "$DRY_LOG"; then
  fail "dry-run looked like it created a real issue URL"
else
  ok "dry-run did not emit a created issue URL"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
