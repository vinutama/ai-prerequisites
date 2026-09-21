#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT=cursor exec bash "$ROOT/tests/codex/test-create-issues.sh"
