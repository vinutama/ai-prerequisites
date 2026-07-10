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

# --- Generate project-level opencode.json with model fallback ---

generate_opencode_json() {
  local target="$1"
  local models_file="$target/.opencode/goal-models.json"
  local opencode_json="$target/opencode.json"

  if [ ! -f "$models_file" ]; then
    warn "goal-models.json not found, skipping opencode.json generation"
    return
  fi

  command -v jq >/dev/null 2>&1 || { err "jq required for opencode.json generation"; return 1; }
  local generated
  generated=$(jq '
    . as $models |
    ($models
      | to_entries
      | map(.value.preferred_models + .value.fallback_models)
      | map(length)
      | max // 3) as $max_fallback |
    {
      runtime_fallback: {
        enabled: true,
        retry_on_errors: [429, 500, 502, 503, 504],
        max_fallback_attempts: $max_fallback,
        cooldown_seconds: 60,
        notify_on_fallback: true
      },
      agents: ($models
        | to_entries
        | map({
            key: .key,
            value: {
              model: .value.preferred_models[0],
              fallback_models: (.value.preferred_models[1:] + .value.fallback_models)
            }
          })
        | from_entries)
    }
  ' "$models_file")

  if [ -f "$opencode_json" ]; then
    if jq -e '.runtime_fallback' "$opencode_json" >/dev/null 2>&1; then
      log "opencode.json already has runtime_fallback — merging agent models"
      jq -s '.[0] * {agents: ((.[0].agents // {}) * .[1].agents)}' \
        "$opencode_json" <(echo "$generated" | jq '{agents: .agents}') \
        > "$opencode_json.tmp" && mv "$opencode_json.tmp" "$opencode_json"
    else
      log "Merging runtime_fallback into existing opencode.json"
      jq -s '.[0] * .[1]' "$opencode_json" <(echo "$generated") \
        > "$opencode_json.tmp" && mv "$opencode_json.tmp" "$opencode_json"
    fi
  else
    echo "$generated" > "$opencode_json"
  fi
  log "Generated/updated opencode.json with model fallback (project-level)"
}

ensure_gitignore_entries() {
  local target="$1"
  local gitignore="$target/.gitignore"
  local entries=("state.json" ".opencode/goal-config.json" ".worktrees/")

  touch "$gitignore"
  for entry in "${entries[@]}"; do
    if ! grep -qxF "$entry" "$gitignore" 2>/dev/null; then
      echo "$entry" >> "$gitignore"
      log "Added $entry to .gitignore"
    fi
  done
}

generate_opencode_json "$TARGET"
ensure_gitignore_entries "$TARGET"

echo ""
log "Setup complete!"
echo ""
echo "─── $TARGET"
echo "├── state.json          (gitignored, created at runtime)"
echo "├── opencode.json       (model fallback config, project-level)"
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
echo "    │   ├── goal.md"
echo "    │   ├── init-goal.md"
echo "    │   └── init-skills.md"
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
echo "    ├── goal-config.json  (created by /init-goal, gitignored)"
echo "    └── package.json"
echo ""
log "Run 'opencode' in the target project, then '/init-goal' to configure, then '/goal <objective>' to start."
log "Use '/goal --list' to see all goals. Resume with '/goal --continue [id]'."
log "Model fallback is enabled via project-level opencode.json (from goal-models.json)."
log "Optionally run '/init-skills' to inject curated skills from agentic-awesome-skills."
