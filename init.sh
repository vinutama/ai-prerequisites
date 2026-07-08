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

# Make scripts executable
chmod +x "$TARGET/.opencode/scripts/goal-git.sh"

# --- Migrate .cursor assets if present ---

migrate_cursor_assets() {
  local target="$1"
  local cursor_skills="$target/.cursor/skills"
  local cursor_rules="$target/.cursor/rules"
  local agents_md="$target/AGENTS.md"

  # 1. Copy .cursor/skills → .opencode/skills
  if [ -d "$cursor_skills" ]; then
    for skill_dir in "$cursor_skills"/*/; do
      [ -d "$skill_dir" ] || continue
      [ -f "$skill_dir/SKILL.md" ] || continue
      local name
      name=$(basename "$skill_dir")
      local dest="$target/.opencode/skills/$name"
      if [ -d "$dest" ]; then
        log "Skill already exists, skipping: $name"
        continue
      fi
      mkdir -p "$dest"
      cp "$skill_dir/SKILL.md" "$dest/SKILL.md"
      log "Migrated skill: $name"
    done
  fi

  # 2. Append .cursor/rules/*.mdc → AGENTS.md
  if [ -d "$cursor_rules" ] && ls "$cursor_rules"/*.mdc >/dev/null 2>&1; then
    local marker="## Project conventions (migrated from .cursor/rules)"
    if grep -qF "$marker" "$agents_md" 2>/dev/null; then
      log "Cursor rules already migrated to AGENTS.md, skipping"
    else
      log "Migrating .cursor/rules to AGENTS.md"
      {
        echo ""
        echo "$marker"
        echo ""
        for rule_file in "$cursor_rules"/*.mdc; do
          [ -f "$rule_file" ] || continue
          local title
          title=$(basename "$rule_file" .mdc | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')
          echo "### $title"
          echo ""
          awk 'BEGIN{count=0} /^---$/{count++; next} count>=2{print}' "$rule_file"
          echo ""
        done
      } >> "$agents_md"
    fi
  fi

  # 3. Add available skills section to AGENTS.md
  if ls "$target/.opencode/skills/"/*/SKILL.md >/dev/null 2>&1; then
    local skills_marker="## Available skills"
    if grep -qF "$skills_marker" "$agents_md" 2>/dev/null; then
      log "Skills section already exists in AGENTS.md, skipping"
    else
      {
        echo ""
        echo "$skills_marker"
        echo ""
        for skill_file in "$target/.opencode/skills/"/*/SKILL.md; do
          [ -f "$skill_file" ] || continue
          local skill_name skill_desc
          skill_name=$(basename "$(dirname "$skill_file")")
          skill_desc=$(awk '
            /^description:/ {
              sub(/^description: */, "")
              if ($0 ~ /^[>|]/) { getline; sub(/^  */, ""); print; exit }
              else { print; exit }
            }
          ' "$skill_file")
          if [ -n "$skill_desc" ]; then
            echo "- \`$skill_name\` — $skill_desc"
          else
            echo "- \`$skill_name\`"
          fi
        done
        echo ""
      } >> "$agents_md"
    fi
  fi
}

migrate_cursor_assets "$TARGET"

echo ""
log "Setup complete!"
echo ""
echo "─── $TARGET"
echo "├── state.json"
echo "├── AGENTS.md"
echo "└── .opencode/"
echo "    ├── agent/"
echo "    │   ├── builder.md"
echo "    │   ├── builder-expert.md"
echo "    │   ├── orchestrator.md"
echo "    │   ├── planner.md"
echo "    │   ├── reviewer.md"
echo "    │   └── visual-reviewer.md"
echo "    ├── command/"
echo "    │   └── goal.md"
echo "    ├── scripts/"
echo "    │   └── goal-git.sh"
echo "    ├── skills/"
echo "    │   ├── goal-loop/"
echo "    │   │   └── SKILL.md"
for skill_dir in "$TARGET/.opencode/skills"/*/; do
  [ -d "$skill_dir" ] || continue
  skill_name=$(basename "$skill_dir")
  [ "$skill_name" = "goal-loop" ] && continue
  echo "    │   ├── $skill_name/"
  echo "    │   │   └── SKILL.md"
done
echo "    ├── goal-models.json"
echo "    └── package.json"
echo ""
log "Run 'opencode' and type '/goal <your objective>' to start."
log "View all goals with '/goal-list'. Resume a goal with '/goal-continue [id]'."
