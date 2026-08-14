#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"

if [ -f "$PROJECT_ROOT/.opencode/figma.env" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/.opencode/figma.env"
  set +a
fi

exec opencode "$@"
