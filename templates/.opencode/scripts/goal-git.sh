#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"
STATE_FILE="$PROJECT_ROOT/state.json"
CONFIG_FILE="$PROJECT_ROOT/.opencode/goal-config.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[goal]${NC} $*"; }
warn() { echo -e "${YELLOW}[goal]${NC} $*" >&2; }
err()  { echo -e "${RED}[goal]${NC} $*" >&2; }

usage() {
  cat <<EOF
Usage: goal-git.sh {start|continue|list|stage|commit|push|pr|pending|analyze|selfcheck|config|state|status|restore|diff} [args]

Commands:
  start <goal>       Create branch and append goal to history
  continue [id]      Continue active goal (or switch to goal by branch/text)
  list               List all goals with status and active marker
  stage <file>...    Stage specific files for commit (use for new files)
  commit [msg]       Commit staged changes (conventional commit)
  push               Push branch to origin
  pr                 Create or update the PR (GitHub) / MR (GitLab)
  pending            Check for unresolved review threads (exit 0 = clean)
  analyze            Run gitnexus analyze && rtk gain
  selfcheck          Run platform detection self-check
  config set <source> <target-branch> <platform>  Write goal-config.json
  config get         Print goal-config.json
  state              Print active goal JSON from state.json
  status             Show working tree status
  restore <file>...  Restore files to HEAD
  diff               Show diff against base branch for active goal
EOF
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }
}

cd "$PROJECT_ROOT"

# --- Config Helpers ---

config_read() {
  local field="$1"
  if [ -f "$CONFIG_FILE" ]; then
    jq -r --arg f "$field" '.[$f] // empty' "$CONFIG_FILE" 2>/dev/null || true
  fi
}

# --- Platform Detection ---

detect_platform() {
  local remote_url
  remote_url=$(git remote get-url origin 2>/dev/null || true)
  case "$remote_url" in
    *gitlab* | *@gitlab.*) echo "gitlab" ;;
    *github* | *@github.*) echo "github" ;;
    *) echo "unknown" ;;
  esac
}

platform="${GOAL_PLATFORM:-$(config_read platform)}"
[ -z "$platform" ] && platform="$(detect_platform)"
case "$platform" in
  github|gitlab) ;;
  *) err "Cannot detect platform. Run '/init-goal' or set GOAL_PLATFORM=github|gitlab"; exit 1 ;;
esac

require_vcs_cli() {
  case "$platform" in
    github) require_cmd gh ;;
    gitlab) require_cmd glab ;;
  esac
}

# --- State Helpers ---

state_ensure_array() {
  if [ -f "$STATE_FILE" ] && jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
    jq '[.]' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  fi
}

state_active() {
  state_ensure_array
  jq -r '.[-1]' "$STATE_FILE"
}

state_update() {
  local field="$1" value="$2"
  jq --arg v "$value" ".[-1].$field = \$v" "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# --- Commands ---

detect_base() {
  local configured
  configured="$(config_read target_branch)"
  if [ -n "$configured" ]; then
    echo "$configured"
    return
  fi

  case "$platform" in
    github)
      require_cmd gh
      gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || \
        git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}' || \
        echo "main"
      ;;
    gitlab)
      require_cmd glab
      glab repo view --output json 2>/dev/null | jq -r '.default_branch // .defaultBranch // empty' || \
        git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}' || \
        echo "main"
      ;;
    *)
      git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}' || echo "main"
      ;;
  esac
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | head -c 50
}

cmd_start() {
  require_cmd git jq
  require_vcs_cli
  local goal="${1:-}"
  [ -z "$goal" ] && { err "start requires a goal description"; exit 1; }

  state_ensure_array

  if [ -f "$STATE_FILE" ]; then
    local old_status
    old_status=$(jq -r '.[-1].status // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
    if [ "$old_status" = "in_progress" ]; then
      warn "A goal is already in progress. Starting a new goal will append to history. Use 'continue' to extend the existing goal instead."
    fi
  fi

  local base branch
  base=$(detect_base)
  branch="goal/$(slugify "$goal")"

  log "Platform: $platform"
  log "Base: $base"
  log "Branch: $branch"

  git fetch origin "$base" 2>/dev/null || true
  git checkout -b "$branch" "origin/$base" 2>/dev/null || git checkout "$branch" 2>/dev/null || true

  local new_goal
  new_goal=$(jq -n --arg goal "$goal" --arg branch "$branch" --arg base "$base" \
    '{goal: $goal, branch: $branch, base_branch: $base, pr_number: null, pr_url: "", status: "in_progress"}')

  if [ -f "$STATE_FILE" ]; then
    jq --argjson entry "$new_goal" '. + [$entry]' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  else
    echo "[$new_goal]" > "$STATE_FILE"
  fi
  log "Goal #$(jq 'length' "$STATE_FILE") started"
}

cmd_commit() {
  require_cmd git
  local msg="${1:-chore: automated changes}"
  git diff --cached --quiet && { log "Nothing staged to commit. Use 'stage <file>...' to add files."; return; }
  git commit -m "$msg"
  log "Committed: $msg"
}

cmd_push() {
  require_cmd git jq
  state_ensure_array
  local branch
  branch=$(jq -r '.[-1].branch' "$STATE_FILE")
  git push -u origin "$branch" --force-with-lease 2>/dev/null || git push -u origin "$branch"
  log "Pushed: $branch"
}

cmd_pr() {
  require_cmd jq
  require_vcs_cli
  state_ensure_array
  local branch base goal pr_number title pr_url
  branch=$(jq -r '.[-1].branch' "$STATE_FILE")
  base=$(jq -r '.[-1].base_branch' "$STATE_FILE")
  goal=$(jq -r '.[-1].goal' "$STATE_FILE")
  pr_number=$(jq -r '.[-1].pr_number' "$STATE_FILE")

  if [ "$pr_number" != "null" ] && [ -n "$pr_number" ]; then
    log "PR/MR already exists: #$pr_number"
    return
  fi

  title="${goal:0:250}"

  case "$platform" in
    github)
      pr_number=$(gh pr create --base "$base" --head "$branch" --title "$title" --body "$goal" --json number -q '.number')
      local gh_owner
      gh_owner=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
      pr_url="https://github.com/$gh_owner/pull/$pr_number"
      ;;
    gitlab)
      log "Creating MR: $title"
      local mr_output mr_number
      mr_output=$(glab mr create --yes --source-branch "$branch" --target-branch "$base" --title "$title" --description "$goal" --output json 2>/dev/null || true)
      if echo "$mr_output" | jq -e '.iid' >/dev/null 2>&1; then
        mr_number=$(echo "$mr_output" | jq -r '.iid')
        pr_url=$(echo "$mr_output" | jq -r '.web_url // empty')
      else
        mr_output=$(glab mr create --yes --source-branch "$branch" --target-branch "$base" --title "$title" --description "$goal" 2>&1)
        mr_number=$(echo "$mr_output" | grep -oE '\!([0-9]+)' | head -1 | tr -d '!')
      fi
      [ -z "$mr_number" ] && { err "Failed to extract MR number from glab output"; err "Output: $mr_output"; exit 1; }
      pr_number="$mr_number"
      if [ -z "$pr_url" ]; then
        local project_path remote_url
        project_path=$(glab repo view --output json 2>/dev/null | jq -r '.path_with_namespace // empty' || echo "")
        if [ -n "$project_path" ]; then
          pr_url="https://gitlab.com/$project_path/-/merge_requests/$pr_number"
        else
          remote_url=$(git remote get-url origin 2>/dev/null | sed 's/\.git$//' | sed 's|^git@gitlab.com:|https://gitlab.com/|')
          pr_url="${remote_url}/-/merge_requests/$pr_number"
        fi
      fi
      ;;
  esac

  jq --argjson pn "$pr_number" --arg url "$pr_url" \
    '.[-1].pr_number = $pn | .[-1].pr_url = $url' \
    "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

  log "Created: $pr_url"
}

cmd_pending() {
  require_cmd jq
  require_vcs_cli
  state_ensure_array
  local pr_number unresolved result total
  pr_number=$(jq -r '.[-1].pr_number' "$STATE_FILE")

  if [ "$pr_number" = "null" ] || [ -z "$pr_number" ]; then
    err "No PR/MR yet — run 'goal-git.sh pr' first"
    exit 1
  fi

  case "$platform" in
    github)
      local owner repo query
      owner=$(gh repo view --json owner -q '.owner.login')
      repo=$(gh repo view --json name -q '.name')
      query='query($owner:String!,$repo:String!,$pr:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$pr){reviewThreads(first:100){nodes{id isResolved isOutdated comments(first:1){nodes{body}}}totalCount}}}}'

      result=$(gh api graphql -f query="$query" -F owner="$owner" -F repo="$repo" -F pr="$pr_number" 2>/dev/null || echo '{}')
      total=$(echo "$result" | jq -r '.data.repository.pullRequest.reviewThreads.totalCount // 0')
      unresolved=$(echo "$result" | jq '[.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved == false and .isOutdated == false)] | length')
      ;;
    gitlab)
      local project_path encoded_path
      project_path=$(glab repo view --output json 2>/dev/null | jq -r '.path_with_namespace // empty')
      [ -z "$project_path" ] && { err "Failed to get project path from glab repo view"; exit 1; }
      encoded_path=$(echo "$project_path" | jq -sRr @uri)
      result=$(glab api "projects/$encoded_path/merge_requests/$pr_number/discussions" 2>/dev/null || echo '[]')
      total=$(echo "$result" | jq 'if type == "array" then length else 0 end')
      unresolved=$(echo "$result" | jq '[.[] | select(.notes[0].resolved == false or (.notes | length > 1 and any(.resolved == false)))] | length')
      ;;
  esac

  echo "{\"total\": ${total:-0}, \"unresolved\": ${unresolved:-0}}"

  if [ "${unresolved:-0}" -gt 0 ]; then
    warn "$unresolved unresolved thread(s) remain — loop continues"
    exit 1
  fi

  log "No unresolved threads — PR/MR is clean"
  exit 0
}

cmd_continue() {
  require_cmd git jq
  [ ! -f "$STATE_FILE" ] && { err "No existing goal to continue — run 'start' first"; exit 1; }

  state_ensure_array
  local identifier="${1:-}"

  if [ -n "$identifier" ]; then
    local idx branch
    idx=$(jq --arg id "$identifier" 'map(.branch == $id) | index(true)' "$STATE_FILE")
    if [ "$idx" = "null" ]; then
      idx=$(jq --arg id "$identifier" 'map(.branch | contains($id)) | index(true)' "$STATE_FILE")
    fi
    if [ "$idx" = "null" ]; then
      err "Goal not found: $identifier (use 'list' to see all goals)"
      exit 1
    fi
    jq --argjson idx "$idx" '.[:$idx] + .[($idx+1):] + [.[$idx]]' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    branch=$(jq -r '.[-1].branch' "$STATE_FILE")
    log "Switched to goal on branch: $branch"
  fi

  jq '.[-1].status = "in_progress"' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

  local branch
  branch=$(jq -r '.[-1].branch' "$STATE_FILE")
  git checkout "$branch" 2>/dev/null || true
  log "Continuing on branch: $branch"
  log "Goal: $(jq -r '.[-1].goal' "$STATE_FILE")"
}

cmd_stage() {
  require_cmd git
  [ $# -eq 0 ] && { err "stage requires at least one file path"; exit 1; }
  git add "$@"
  log "Staged: $*"
}

cmd_list() {
  require_cmd jq
  if [ ! -f "$STATE_FILE" ]; then
    log "No goals yet. Run 'start' to create one."
    return
  fi
  state_ensure_array
  local count
  count=$(jq 'length' "$STATE_FILE")
  log "$count goal(s):"
  jq -r '
    length as $total |
    to_entries | .[] |
    "  \(.key + 1) [\(.value.status)] " +
    (if .key + 1 == $total then "* " else "  " end) +
    "\(.value.branch) — \(.value.goal)"
  ' "$STATE_FILE"
  echo ""
  log "* = active goal"
}

cmd_analyze() {
  require_cmd npx
  log "Running gitnexus analyze…"
  npx --yes gitnexus@latest analyze || { err "gitnexus analyze failed"; exit 1; }
  log "Running rtk gain…"
  rtk gain || { err "rtk gain failed"; exit 1; }
  log "Analyze complete"
}

cmd_config_set() {
  require_cmd jq
  local source="${1:-}" target="${2:-}" plat="${3:-}"

  [ -z "$source" ] || [ -z "$target" ] || [ -z "$plat" ] && {
    err "config set requires: <goal_source> <target_branch> <platform>"
    exit 1
  }

  case "$source" in
    jira|markdown|prompt) ;;
    *) err "goal_source must be: jira, markdown, or prompt"; exit 1 ;;
  esac

  case "$plat" in
    github|gitlab) ;;
    *) err "platform must be: github or gitlab"; exit 1 ;;
  esac

  mkdir -p "$(dirname "$CONFIG_FILE")"
  jq -n \
    --arg source "$source" \
    --arg target "$target" \
    --arg platform "$plat" \
    '{goal_source: $source, target_branch: $target, platform: $platform}' \
    > "$CONFIG_FILE"

  log "Config written to $CONFIG_FILE"
  jq . "$CONFIG_FILE"
}

cmd_config_get() {
  require_cmd jq
  if [ ! -f "$CONFIG_FILE" ]; then
    err "No goal config found — run '/init-goal' first"
    exit 1
  fi
  jq . "$CONFIG_FILE"
}

cmd_state() {
  require_cmd jq
  [ ! -f "$STATE_FILE" ] && { err "No state found — run 'start' first"; exit 1; }
  state_ensure_array
  state_active
}

cmd_status() {
  require_cmd git
  git status
}

cmd_restore() {
  require_cmd git
  [ $# -eq 0 ] && { err "restore requires at least one file path"; exit 1; }
  git restore "$@"
  log "Restored: $*"
}

cmd_diff() {
  require_cmd git jq
  [ ! -f "$STATE_FILE" ] && { err "No state found — run 'start' first"; exit 1; }
  state_ensure_array
  local base
  base=$(jq -r '.[-1].base_branch' "$STATE_FILE")
  git diff "origin/$base..HEAD"
}

cmd_selfcheck() {
  require_cmd git jq
  log "selfcheck: start"
  log "Project root: $PROJECT_ROOT"
  log "State file: $STATE_FILE"
  log "Config file: $CONFIG_FILE"

  if [ -f "$STATE_FILE" ]; then
    state_ensure_array
    log "Goals in state.json: $(jq 'length' "$STATE_FILE") ($(jq -r '.[-1].status' "$STATE_FILE"))"
  else
    log "No state.json yet"
  fi

  if [ -f "$CONFIG_FILE" ]; then
    log "Goal config:"
    jq . "$CONFIG_FILE"
  else
    warn "No goal-config.json — run '/init-goal' to configure"
  fi

  local url
  url="$(git remote get-url origin 2>/dev/null || echo '<no origin remote>')"
  log "Origin URL: $url"
  log "Platform (GOAL_PLATFORM override=${GOAL_PLATFORM:-<unset>}): $platform"

  case "$platform" in
    github)
      command -v gh >/dev/null 2>&1 && log "  gh CLI: OK" || { err "  gh CLI: NOT FOUND — install with: brew install gh"; exit 1; }
      gh auth status 2>&1 | head -1 || warn "  gh not logged in (run 'gh auth login')"
      log "  PR URL format: https://github.com/<owner>/<repo>/pull/<number>"
      ;;
    gitlab)
      command -v glab >/dev/null 2>&1 && log "  glab CLI: OK" || { err "  glab CLI: NOT FOUND — install with: brew install glab"; exit 1; }
      glab auth status 2>&1 | head -1 || warn "  glab not logged in (run 'glab auth login')"
      log "  MR URL format: https://gitlab.com/<namespace>/<project>/-/merge_requests/<iid>"
      ;;
  esac

  log "selfcheck: complete"
}

case "${1:-}" in
  start)    cmd_start "${2:-}" ;;
  continue) cmd_continue "${2:-}" ;;
  list)     cmd_list ;;
  stage)    shift; cmd_stage "$@" ;;
  commit)   cmd_commit "${2:-}" ;;
  push)     cmd_push ;;
  pr)       cmd_pr ;;
  pending)  cmd_pending ;;
  analyze)  cmd_analyze ;;
  config)
    case "${2:-}" in
      set) cmd_config_set "${3:-}" "${4:-}" "${5:-}" ;;
      get) cmd_config_get ;;
      *)   err "config subcommand must be 'set' or 'get'"; exit 1 ;;
    esac
    ;;
  state)    cmd_state ;;
  status)   cmd_status ;;
  restore)  shift; cmd_restore "$@" ;;
  diff)     cmd_diff ;;
  selfcheck) cmd_selfcheck ;;
  *)        usage ;;
esac
