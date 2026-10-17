#!/usr/bin/env bash
# Fail if the Cursor or Claude scripts drift from the Codex source of truth.
# Shared by tests/cursor and tests/claude: all three platforms run the same
# harness modules, selected at runtime by the parent directory name.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CODEX="$ROOT/templates/codex/.codex/scripts"
failed=0
SHARED=(goal-git.sh goal-context.sh goal-delegation.sh goal-delivery.sh goal-evidence.sh forge.sh delivery-groups.sh)

for platform in cursor claude; do
  dir=".$platform"
  copy="$ROOT/templates/$platform/$dir/scripts"
  for f in "${SHARED[@]}"; do
    if ! cmp -s "$CODEX/$f" "$copy/$f"; then
      echo "DRIFT: $f differs between Codex and $platform" >&2
      echo "  Fix: cp templates/codex/.codex/scripts/$f templates/$platform/$dir/scripts/$f" >&2
      failed=1
    else
      echo "PASS: $platform/$f identical"
    fi
  done
  if [ ! -f "$copy/run-$platform.sh" ]; then
    echo "FAIL: missing $platform/run-$platform.sh" >&2
    failed=1
  fi
  # create-issues.sh picks its platform from the install path, so it is byte-identical too.
  skill_copy="$ROOT/templates/$platform/$dir/skills/create-issues/scripts/create-issues.sh"
  if ! cmp -s "$ROOT/templates/codex/.agents/skills/create-issues/scripts/create-issues.sh" "$skill_copy"; then
    echo "DRIFT: create-issues.sh differs between Codex and $platform" >&2
    echo "  Fix: cp templates/codex/.agents/skills/create-issues/scripts/create-issues.sh $skill_copy" >&2
    failed=1
  else
    echo "PASS: $platform/create-issues.sh identical"
  fi
done
[ -f "$CODEX/run-codex.sh" ] || { echo "FAIL: missing codex/run-codex.sh" >&2; failed=1; }

# Cursor and Claude catalogs need $routing, $capabilities and per-role entries (init.sh sync).
for platform in cursor claude; do
  models="$ROOT/templates/$platform/.$platform/goal-models.json"
  jq -e '."$routing" != null and ."$capabilities" != null and (.planner.model != null) and (."visual-reviewer".model != null)' "$models" >/dev/null || {
    echo "FAIL: $platform goal-models.json lacks \$routing/\$capabilities/per-role entries" >&2; failed=1; }
done
exit "$failed"
