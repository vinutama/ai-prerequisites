#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"

if [ -f "$PROJECT_ROOT/.qoder/figma.env" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/.qoder/figma.env"
  set +a
fi

exec "${QODER_CLI:-qoder}" "$@"
