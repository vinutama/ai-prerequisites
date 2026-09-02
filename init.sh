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
warn() { echo -e "${CYAN}[init]${NC} Warning: $*" >&2; }

ALL_AGENTS=(opencode cursor claude codex)

usage() {
  cat <<EOF
Usage: init.sh --opencode|--cursor|--claude|--codex|--all [--clean] <target-project-path>

Scaffold Goal Architecture Loop Engineering into an existing project.
A target flag is required.

  --opencode   OpenCode  (.opencode/ + AGENTS.md). Invoke /goal
  --cursor     Cursor    (.cursor/ + AGENTS.md). Invoke /goal
  --claude     Claude Code (.claude/ + CLAUDE.md). Invoke /goal
  --codex      Codex     (.codex/ + .agents/skills/ + AGENTS.md). Invoke \$goal
  --all        All four targets
  --clean      Remove the selected target(s) from a project

Examples:
  ./init.sh --opencode /path/to/project
  ./init.sh --cursor --claude /path/to/project
  ./init.sh --all /path/to/parent
  ./init.sh --clean --cursor /path/to/project
EOF
  exit 1
}

# --- arg parse ---

TARGETS=()
CLEAN_MODE=false
TARGET_PATH=""
WROTE_AGENTS_MD=false

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --opencode) TARGETS+=("opencode") ;;
      --cursor)   TARGETS+=("cursor") ;;
      --claude)   TARGETS+=("claude") ;;
      --codex)    TARGETS+=("codex") ;;
      --all)      TARGETS=(opencode cursor claude codex) ;;
      --clean)    CLEAN_MODE=true ;;
      -h|--help)  usage ;;
      --*)        err "Unknown flag: $1"; usage ;;
      *)
        if [ -n "$TARGET_PATH" ]; then
          err "Unexpected argument: $1"
          usage
        fi
        TARGET_PATH="$1"
        ;;
    esac
    shift
  done

  if [ ${#TARGETS[@]} -eq 0 ]; then
    err "Specify at least one agent: --opencode, --cursor, --claude, --codex, or --all"
    usage
  fi

  # Dedupe while preserving order
  local seen="" deduped=()
  local t
  for t in "${TARGETS[@]}"; do
    case " $seen " in
      *" $t "*) continue ;;
    esac
    seen="$seen $t"
    deduped+=("$t")
  done
  TARGETS=("${deduped[@]}")

  if [ -z "$TARGET_PATH" ]; then
    err "Missing target project path."
    usage
  fi
}

agent_dir() {
  case "$1" in
    opencode) echo ".opencode" ;;
    cursor)   echo ".cursor" ;;
    claude)   echo ".claude" ;;
    codex)    echo ".codex" ;;
  esac
}

agent_root_doc() {
  case "$1" in
    claude) echo "CLAUDE.md" ;;
    *)      echo "AGENTS.md" ;;
  esac
}

agent_run_hint() {
  case "$1" in
    opencode) echo "opencode  then  /init-goal  then  /goal <objective>" ;;
    cursor)   echo "cursor-agent  then  /init-goal  then  /goal <objective>" ;;
    claude)   echo "claude  then  /init-goal  then  /goal <objective>" ;;
    codex)    echo "codex  then  \$init-goal  then  \$goal <objective>  (CLI >= 0.138.0; trust the project)" ;;
  esac
}

# --- copy / install ---

write_root_doc() {
  local src="$1" dest="$2" label="$3"
  if [ "$(basename "$dest")" = "AGENTS.md" ] && [ "$WROTE_AGENTS_MD" = true ]; then
    {
      echo ""
      echo "---"
      echo ""
      echo "## $label goal-loop"
      echo ""
      tail -n +2 "$src"
    } >> "$dest"
    log "Appended $label section to AGENTS.md"
    return
  fi
  cp "$src" "$dest"
  if [ "$(basename "$dest")" = "AGENTS.md" ]; then
    WROTE_AGENTS_MD=true
  fi
}

install_target() {
  local name="$1"
  local dest="$2"
  local tree="$TEMPLATES_DIR/$name"
  local dir root_doc
  dir="$(agent_dir "$name")"
  root_doc="$(agent_root_doc "$name")"

  if [ ! -d "$tree" ]; then
    err "Template tree missing: $tree"
    exit 1
  fi

  log "Installing $name into: $dest"

  cp -R "$tree/$dir" "$dest/"
  if [ -d "$tree/.agents" ]; then
    mkdir -p "$dest/.agents/skills"
    cp -R "$tree/.agents/skills/." "$dest/.agents/skills/"
  fi

  write_root_doc "$tree/$root_doc" "$dest/$root_doc" "$name"

  local script
  for script in "$dest/$dir/scripts/"*.sh; do
    [ -f "$script" ] || continue
    chmod +x "$script"
  done
}

# --- migrate .cursor assets ---

migrate_cursor_assets() {
  local dest="$1"
  local name="$2"
  local cursor_skills="$dest/.cursor/skills"
  local cursor_rules="$dest/.cursor/rules"
  local dir root_doc agents_md skills_dest
  dir="$(agent_dir "$name")"
  root_doc="$(agent_root_doc "$name")"
  agents_md="$dest/$root_doc"

  if [ "$name" = "cursor" ]; then
    return
  fi

  if [ "$name" = "codex" ]; then
    skills_dest="$dest/.agents/skills"
  else
    skills_dest="$dest/$dir/skills"
  fi

  if [ -d "$cursor_skills" ]; then
    mkdir -p "$skills_dest"
    local skill_dir
    for skill_dir in "$cursor_skills"/*/; do
      [ -d "$skill_dir" ] || continue
      [ -f "$skill_dir/SKILL.md" ] || continue
      local skill_name dest_skill
      skill_name=$(basename "$skill_dir")
      dest_skill="$skills_dest/$skill_name"
      if [ -d "$dest_skill" ]; then
        log "Skill already exists, skipping: $skill_name"
        continue
      fi
      mkdir -p "$dest_skill"
      cp "$skill_dir/SKILL.md" "$dest_skill/SKILL.md"
      log "Migrated skill: $skill_name → $skills_dest"
    done
  fi

  if [ -d "$cursor_rules" ] && ls "$cursor_rules"/*.mdc >/dev/null 2>&1; then
    local marker="## Project conventions (migrated from .cursor/rules)"
    if grep -qF "$marker" "$agents_md" 2>/dev/null; then
      log "Cursor rules already migrated to $root_doc, skipping"
    else
      log "Migrating .cursor/rules to $root_doc"
      {
        echo ""
        echo "$marker"
        echo ""
        local rule_file
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

  if ls "$skills_dest"/*/SKILL.md >/dev/null 2>&1; then
    local skills_marker="## Available skills"
    if grep -qF "$skills_marker" "$agents_md" 2>/dev/null; then
      log "Skills section already exists in $root_doc, skipping"
    else
      {
        echo ""
        echo "$skills_marker"
        echo ""
        local skill_file
        for skill_file in "$skills_dest"/*/SKILL.md; do
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

# --- model sync ---

is_vision_model() {
  local model="$1"
  echo "$model" | grep -qiE 'mimo|gpt-4o|gpt-4\.1|claude.*sonnet|sonnet|gemini.*(pro|flash|vision)|llava|qwen.*vl|inherit'
}

validate_multimodal_models() {
  local models_file="$1"
  jq -r '
    to_entries[]
    | select(.value.capabilities.multimodal == true)
    | "\(.key)\t\(.value.preferred_models[0] // .value.model // "inherit")"
  ' "$models_file" | while IFS=$'\t' read -r name model; do
    [ -n "$name" ] || continue
    if ! is_vision_model "$model"; then
      warn "$name is multimodal but preferred model '$model' may not support vision"
    fi
  done
}

sync_agent_frontmatter_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  awk -v key="$key" -v value="$value" '
    BEGIN { fm = 0 }
    /^---$/ {
      fm++
      print
      next
    }
    fm == 1 && $0 ~ ("^" key ":") {
      print key ": " value
      next
    }
    { print }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

sync_agent_toml_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  awk -v key="$key" -v value="$value" '
    BEGIN { done = 0 }
    !done && $0 ~ ("^" key " = ") {
      print key " = \"" value "\""
      done = 1
      next
    }
    { print }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

sync_agent_models() {
  local dest="$1"
  local name="$2"
  local dir models_file agents_dir
  dir="$(agent_dir "$name")"
  models_file="$dest/$dir/goal-models.json"

  if [ "$name" = "codex" ]; then
    agents_dir="$dest/$dir/agents"
  elif [ "$name" = "cursor" ] || [ "$name" = "claude" ]; then
    agents_dir="$dest/$dir/agents"
  else
    agents_dir="$dest/$dir/agent"
  fi

  if [ ! -f "$models_file" ]; then
    warn "goal-models.json not found for $name, skipping agent model sync"
    return
  fi

  command -v jq >/dev/null 2>&1 || { warn "jq required for agent model sync"; return; }

  validate_multimodal_models "$models_file"

  if [ "$name" = "opencode" ]; then
    jq -r 'to_entries[] | "\(.key)\t\(.value.preferred_models[0])"' "$models_file" | while IFS=$'\t' read -r agent_name model; do
      [ -n "$agent_name" ] || continue
      [ -n "$model" ] || continue
      local agent_file="$agents_dir/$agent_name.md"
      if [ ! -f "$agent_file" ]; then
        warn "Agent file not found for $agent_name: $agent_file"
        continue
      fi
      sync_agent_frontmatter_key "$agent_file" model "$model"
      log "Synced model for $name agent: $agent_name → $model"
    done
  elif [ "$name" = "codex" ]; then
    jq -r 'to_entries[] | "\(.key)\t\(.value.model_reasoning_effort // "")\t\(.value.sandbox_mode // "")\t\(.value.model // "")"' "$models_file" | while IFS=$'\t' read -r agent_name effort sandbox model; do
      [ -n "$agent_name" ] || continue
      local agent_file="$agents_dir/$agent_name.toml"
      if [ ! -f "$agent_file" ]; then
        warn "Agent file not found for $agent_name: $agent_file"
        continue
      fi
      [ -n "$effort" ] && sync_agent_toml_key "$agent_file" model_reasoning_effort "$effort"
      [ -n "$sandbox" ] && sync_agent_toml_key "$agent_file" sandbox_mode "$sandbox"
      [ -n "$model" ] && sync_agent_toml_key "$agent_file" model "$model"
      log "Synced model for $name agent: $agent_name"
    done
  else
    jq -r 'to_entries[] | "\(.key)\t\(.value.model // "inherit")\t\(.value.readonly // "")"' "$models_file" | while IFS=$'\t' read -r agent_name model readonly; do
      [ -n "$agent_name" ] || continue
      local agent_file="$agents_dir/$agent_name.md"
      if [ ! -f "$agent_file" ]; then
        warn "Agent file not found for $agent_name: $agent_file"
        continue
      fi
      sync_agent_frontmatter_key "$agent_file" model "$model"
      if [ -n "$readonly" ]; then
        local readonly_bool
        readonly_bool=$( [ "$readonly" = "true" ] && echo true || echo false )
        sync_agent_frontmatter_key "$agent_file" readonly "$readonly_bool"
      fi
      log "Synced model for $name agent: $agent_name → $model"
    done
  fi
}

generate_opencode_json() {
  local dest="$1"
  local models_file="$dest/.opencode/goal-models.json"
  local opencode_json="$dest/opencode.json"
  local fallback_config="$dest/.opencode/opencode-model-fallback.json"

  if [ ! -f "$models_file" ]; then
    warn "goal-models.json not found, skipping opencode.json generation"
    return
  fi

  command -v jq >/dev/null 2>&1 || { err "jq required for opencode.json generation"; return 1; }

  local generated fallback_settings
  generated=$(jq '
    . as $models |
    {
      "$schema": "https://opencode.ai/config.json",
      plugin: ["@razroo/opencode-model-fallback"],
      agent: ($models
        | to_entries
        | map({
            key: .key,
            value: ({
              model: .value.preferred_models[0],
              fallback_models: (.value.preferred_models[1:] + .value.fallback_models)
            }
            + if (.value.capabilities.multimodal // false) then
                {description: "Multimodal UI reviewer — vision model required"}
              else {} end)
          })
        | from_entries)
    }
  ' "$models_file")

  fallback_settings=$(jq '
    . as $models |
    ($models
      | to_entries
      | map(.value.preferred_models + .value.fallback_models)
      | map(length)
      | max // 3) as $max_fallback |
    {
      enabled: true,
      retry_on_errors: [429, 500, 502, 503, 504],
      max_fallback_attempts: $max_fallback,
      cooldown_seconds: 60,
      notify_on_fallback: true
    }
  ' "$models_file")

  if [ -f "$opencode_json" ]; then
    log "Merging model fallback into existing opencode.json"
    jq -s '
      .[0] as $existing |
      .[1] as $generated |
      ($existing | del(.runtime_fallback, .agents)) as $clean |
      $clean
      | .plugin = ((.plugin // []) + ($generated.plugin // []) | unique)
      | .agent = ((.agent // {}) * ($generated.agent // {}))
      | ."$schema" = ($generated["$schema"] // ."$schema")
    ' "$opencode_json" <(echo "$generated") \
      > "$opencode_json.tmp" && mv "$opencode_json.tmp" "$opencode_json"
  else
    echo "$generated" > "$opencode_json"
  fi

  echo "$fallback_settings" > "$fallback_config"
  log "Generated/updated opencode.json and .opencode/opencode-model-fallback.json"
}

gitignore_entries_for() {
  local name="$1"
  case "$name" in
    opencode)
      echo ".opencode/"
      echo "AGENTS.md"
      ;;
    cursor)
      echo ".cursor/"
      echo "AGENTS.md"
      ;;
    claude)
      echo ".claude/"
      echo "CLAUDE.md"
      echo ".mcp.json"
      ;;
    codex)
      echo ".codex/"
      echo ".agents/skills/goal/"
      echo ".agents/skills/init-goal/"
      echo ".agents/skills/init-skills/"
      echo ".agents/skills/goal-loop/"
      echo "AGENTS.md"
      ;;
  esac
  echo ".worktrees/"
  echo ".goal-review/"
  echo "state.json"
}

ensure_gitignore_entries() {
  local dest="$1"
  shift
  local gitignore="$dest/.gitignore"
  local entries=()
  local name entry

  for name in "$@"; do
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      entries+=("$entry")
    done < <(gitignore_entries_for "$name")
  done

  if [ -f "$gitignore" ]; then
    local stale_patterns=(
      "\.opencode/goal-config\.json"
      "\.opencode/figma\.env"
      "state\.\*json"
      "state\.json\.opencode/"
    )
    local pattern
    for pattern in "${stale_patterns[@]}"; do
      sed -i '' "/^${pattern}$/d" "$gitignore" 2>/dev/null || true
    done
  fi

  touch "$gitignore"
  if [ -s "$gitignore" ] && [ "$(tail -c1 "$gitignore" | wc -l)" -eq 0 ]; then
    printf '\n' >> "$gitignore"
  fi

  # unique
  local seen=""
  for entry in "${entries[@]}"; do
    case " $seen " in
      *" $entry "*) continue ;;
    esac
    seen="$seen $entry"
    if ! grep -qxF "$entry" "$gitignore" 2>/dev/null; then
      echo "$entry" >> "$gitignore"
      log "Added $entry to .gitignore"
    fi
  done
}

cmd_clean() {
  local dest="$1"
  shift
  [ -z "$dest" ] && { err "clean requires <target-path>"; exit 1; }
  dest="$(cd "$dest" 2>/dev/null && pwd || echo "")"
  [ -z "$dest" ] || [ ! -d "$dest" ] && { err "Target does not exist"; exit 1; }

  log "Cleaning selected targets from: $dest"

  local name dir
  for name in "$@"; do
    dir="$(agent_dir "$name")"
    if [ -d "$dest/$dir" ]; then
      rm -rf "$dest/$dir"
      log "Removed $dir/"
    fi
    if [ "$name" = "codex" ]; then
      local skill
      for skill in goal init-goal init-skills goal-loop; do
        if [ -d "$dest/.agents/skills/$skill" ]; then
          rm -rf "$dest/.agents/skills/$skill"
          log "Removed .agents/skills/$skill/"
        fi
      done
    fi
  done

  still_has_agents_md=false
  still_has_claude=false
  still_has_any=false
  for name in opencode cursor claude codex; do
    dir="$(agent_dir "$name")"
    [ -d "$dest/$dir" ] || continue
    still_has_any=true
    if [ "$(agent_root_doc "$name")" = "AGENTS.md" ]; then
      still_has_agents_md=true
    else
      still_has_claude=true
    fi
  done

  if [ "$still_has_agents_md" = false ] && [ -f "$dest/AGENTS.md" ]; then
    rm -f "$dest/AGENTS.md"
    log "Removed AGENTS.md"
  fi
  if [ "$still_has_claude" = false ] && [ -f "$dest/CLAUDE.md" ]; then
    rm -f "$dest/CLAUDE.md"
    log "Removed CLAUDE.md"
  fi

  if [ "$still_has_any" = false ] && [ -f "$dest/state.json" ]; then
    rm -f "$dest/state.json"
    log "Removed state.json"
  fi

  if [ -f "$dest/opencode.json" ]; then
    warn "opencode.json exists — review and remove manually if needed"
  fi
  if [ -f "$dest/.mcp.json" ]; then
    warn ".mcp.json exists — review and remove manually if needed"
  fi

  if [ -f "$dest/.gitignore" ]; then
    local entry
    for name in "$@"; do
      while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        case "$entry" in
          AGENTS.md|.worktrees/|state.json)
            [ "$still_has_any" = true ] && continue
            ;;
        esac
        # Use # as sed delimiter so paths containing / match
        sed -i '' "\#^$(printf '%s' "$entry" | sed 's/[.[\*^$]/\\&/g')\$#d" "$dest/.gitignore" 2>/dev/null || true
      done < <(gitignore_entries_for "$name")
    done
    log "Cleaned .gitignore"
  fi

  log "Clean complete"
}

auto_detect_and_cleanup() {
  local dest="$1"

  if [ -d "$dest/.git" ]; then
    log "Mode: single-repo"
    return
  fi

  local git_repos=()
  local existing=()
  local dir repo marker
  for dir in "$dest"/*/; do
    [ -d "$dir" ] || continue
    if [ -d "$dir.git" ]; then
      repo="$(basename "$dir")"
      git_repos+=("$repo")
      for marker in .opencode .cursor .claude .codex; do
        if [ -d "$dir$marker" ]; then
          existing+=("$repo/$marker")
        fi
      done
    fi
  done

  if [ ${#git_repos[@]} -eq 0 ]; then
    warn "No git repos detected. Init at a git repo or a directory containing git repos."
    return
  fi

  log "Mode: multi-repo (detected ${#git_repos[@]} git repos)"

  if [ ${#existing[@]} -gt 0 ]; then
    warn "Found existing goal-loop installs in these repos (from previous single-repo inits):"
    local item
    for item in "${existing[@]}"; do
      warn "  - $item"
    done
    warn ""
    warn "These should be removed for multi-repo mode to work correctly."
    warn "Remove them now?"
    read -r -p "[y/N] " response
    if [ "$response" = "y" ] || [ "$response" = "Y" ]; then
      local prev=""
      for item in "${existing[@]}"; do
        repo="${item%%/*}"
        if [ "$repo" != "$prev" ]; then
          cmd_clean "$dest/$repo" "${TARGETS[@]}"
          prev="$repo"
        fi
      done
      log "Cleaned nested installs"
    else
      warn "Skipped cleanup — you may need to run './init.sh --clean --<agent> <repo>' manually later"
    fi
  fi
}

print_tree() {
  local dest="$1"
  local name="$2"
  local dir
  dir="$(agent_dir "$name")"

  echo ""
  echo "─── $name  $dest"
  case "$name" in
    opencode)
      echo "├── state.json          (gitignored, created at runtime)"
      echo "├── opencode.json       (model fallback config, project-level)"
      echo "├── AGENTS.md           (gitignored)"
      echo "└── .opencode/          (gitignored)"
      echo "    ├── agent/          (6 specialized agents)"
      echo "    ├── command/        (/goal, /init-goal, /init-skills)"
      echo "    ├── scripts/        (goal-git.sh, run-opencode.sh)"
      echo "    ├── skills/goal-loop/"
      echo "    └── goal-models.json"
      ;;
    cursor)
      echo "├── state.json          (gitignored, created at runtime)"
      echo "├── AGENTS.md           (gitignored)"
      echo "└── .cursor/            (gitignored)"
      echo "    ├── agents/         (6 specialized agents)"
      echo "    ├── skills/         (/goal, /init-goal, /init-skills, goal-loop)"
      echo "    ├── scripts/        (goal-git.sh, run-cursor.sh)"
      echo "    └── goal-models.json"
      ;;
    claude)
      echo "├── state.json          (gitignored, created at runtime)"
      echo "├── CLAUDE.md           (gitignored)"
      echo "├── .mcp.json           (Figma MCP, created by /init-goal)"
      echo "└── .claude/            (gitignored)"
      echo "    ├── agents/         (6 specialized agents)"
      echo "    ├── commands/       (/goal, /init-goal, /init-skills)"
      echo "    ├── scripts/        (goal-git.sh, run-claude.sh)"
      echo "    ├── skills/goal-loop/"
      echo "    └── goal-models.json"
      ;;
    codex)
      echo "├── state.json          (gitignored, created at runtime)"
      echo "├── AGENTS.md           (gitignored)"
      echo "├── .agents/skills/     (\$goal, \$init-goal, \$init-skills, goal-loop)"
      echo "└── .codex/             (gitignored)"
      echo "    ├── agents/         (6 specialized agents, TOML)"
      echo "    ├── scripts/        (goal-git.sh, run-codex.sh)"
      echo "    ├── config.toml     (max_depth=2, network_access, Figma MCP)"
      echo "    └── goal-models.json"
      ;;
  esac
  echo ""
  log "Next: $(agent_run_hint "$name")"
}

# --- main ---

parse_args "$@"

TARGET="$(cd "$TARGET_PATH" 2>/dev/null && pwd || echo "")"
if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
  err "Target directory does not exist: $TARGET_PATH"
  exit 1
fi

if [ "$CLEAN_MODE" = true ]; then
  cmd_clean "$TARGET" "${TARGETS[@]}"
  exit 0
fi

log "Installing goal-loop (${TARGETS[*]}) into: $TARGET"

auto_detect_and_cleanup "$TARGET"

local_name=""
for local_name in "${TARGETS[@]}"; do
  install_target "$local_name" "$TARGET"
  migrate_cursor_assets "$TARGET" "$local_name"
  if [ "$local_name" = "opencode" ]; then
    generate_opencode_json "$TARGET"
  fi
  sync_agent_models "$TARGET" "$local_name"
done

ensure_gitignore_entries "$TARGET" "${TARGETS[@]}"

for local_name in "${TARGETS[@]}"; do
  print_tree "$TARGET" "$local_name"
done

log "Setup complete."
log "Use '/goal --list' (or '\$goal --list' on Codex) to see all goals. Resume with --continue."
log "Optionally run /init-skills (or \$init-skills) to inject curated skills from agentic-awesome-skills."
