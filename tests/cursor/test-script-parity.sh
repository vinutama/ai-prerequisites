#!/usr/bin/env bash
# Fail if Cursor scripts drift from the Codex source of truth.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CODEX="$ROOT/templates/codex/.codex/scripts"
CURSOR="$ROOT/templates/cursor/.cursor/scripts"
failed=0
for f in goal-git.sh goal-context.sh goal-delegation.sh goal-delivery.sh goal-evidence.sh forge.sh delivery-groups.sh; do
  if ! cmp -s "$CODEX/$f" "$CURSOR/$f"; then
    echo "DRIFT: $f differs between Codex and Cursor" >&2
    echo "  Fix: cp templates/codex/.codex/scripts/$f templates/cursor/.cursor/scripts/$f" >&2
    failed=1
  else
    echo "PASS: $f identical"
  fi
done
if [ ! -f "$CURSOR/run-cursor.sh" ]; then
  echo "FAIL: missing run-cursor.sh" >&2
  failed=1
fi
exit "$failed"
