#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[init]${NC} $*"; }
err()  { echo -e "${RED}[init]${NC} $*" >&2; }
info() { echo -e "${CYAN}[init]${NC} $*"; }

usage() {
  cat <<EOF
Usage: init.sh <target-project-path>

Scaffold the /goal AI-prerequisites into an existing project.
Creates .opencode/ agents, commands, skills, scripts, and AGENTS.md.
EOF
  exit 1
}

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  err "Missing target project path."
  usage
fi

TARGET="$(cd "$TARGET" 2>/dev/null && pwd || echo "")"
if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
  err "Target directory does not exist: $1"
  exit 1
fi

log "Installing /goal prerequisites into: $TARGET"

# Copy templates
cp -r "$TEMPLATES_DIR/.opencode" "$TARGET/"
cp "$TEMPLATES_DIR/AGENTS.md" "$TARGET/"
cp -r "$TEMPLATES_DIR/scripts" "$TARGET/"

# Make scripts executable
chmod +x "$TARGET/scripts/goal-git.sh"

# Update root .gitignore
GITIGNORE="$TARGET/.gitignore"
touch "$GITIGNORE"
for entry in "state.json" ".gitnexus/"; do
  if ! grep -qxF "$entry" "$GITIGNORE" 2>/dev/null; then
    echo "$entry" >> "$GITIGNORE"
    log "Added $entry to .gitignore"
  fi
done

echo ""
log "Setup complete!"
echo ""
echo "─── $TARGET"
echo "├── state.json"
echo "├── AGENTS.md"
echo "├── scripts/"
echo "│   └── goal-git.sh"
echo "└── .opencode/"
echo "    ├── agent/"
echo "    │   ├── builder-backend.md"
echo "    │   ├── builder-frontend.md"
echo "    │   ├── orchestrator.md"
echo "    │   ├── planner.md"
echo "    │   ├── reviewer.md"
echo "    │   └── visual-reviewer.md"
echo "    ├── command/"
echo "    │   └── goal.md"
echo "    ├── skills/goal-loop/"
echo "    │   └── SKILL.md"
echo "    ├── goal-models.json"
echo "    ├── .gitignore"
echo "    └── package.json"
echo ""
log "Run 'opencode' and type '/goal <your objective>' to start."
