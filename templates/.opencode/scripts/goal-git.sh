#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"
STATE_FILE="$PROJECT_ROOT/state.json"
CONFIG_FILE="$PROJECT_ROOT/.opencode/goal-config.json"
WORKTREES_DIR="$PROJECT_ROOT/.worktrees"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[goal]${NC} $*"; }
warn() { echo -e "${YELLOW}[goal]${NC} $*" >&2; }
err()  { echo -e "${RED}[goal]${NC} $*" >&2; }

usage() {
  cat <<EOF
Usage: goal-git.sh <command> [args]

Commands:
  start <goal>              Create branch and append goal to history
  continue [id]             Continue active goal (or switch to goal by branch/text)
  list                      List all goals with status and active marker
  stage <file>...           Stage specific files for commit
  commit [msg]              Commit staged changes (conventional commit)
  push                      Push branch to origin
  pr                        Create or update the PR (GitHub) / MR (GitLab)
  pending                   Check for unresolved review threads (exit 0 = clean)
  threads                   List review threads as JSON
  comment <path> <line> <body>  Post inline review comment
  resolve <thread-id>       Resolve a review thread/discussion
  analyze                   Run gitnexus analyze && rtk gain
  selfcheck                 Run platform detection self-check
  config set <source> <target> <platform> [concurrency]  Write goal-config.json
  config get                Print goal-config.json
  state                     Print active goal JSON from state.json
  status                    Show working tree status
  restore <file>...         Restore files to HEAD
  diff                      Show diff against base branch for active goal
  worktree add <task-slug>  Create isolated git worktree for parallel task
  worktree list             List active task worktrees
  worktree merge <task-slug>  Merge worktree branch into goal branch
  worktree remove <task-slug> Remove worktree without merging
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

require_active_goal() {
  require_cmd jq
  [ ! -f "$STATE_FILE" ] && { err "No state found — run 'start' first"; exit 1; }
  state_ensure_array
}

pr_number_active() {
  require_active_goal
  local pr_number
  pr_number=$(jq -r '.[-1].pr_number' "$STATE_FILE")
  if [ "$pr_number" = "null" ] || [ -z "$pr_number" ]; then
    err "No PR/MR yet — run 'goal-git.sh pr' first"
    exit 1
  fi
  echo "$pr_number"
}

github_owner_repo() {
  require_cmd gh
  local owner repo
  owner=$(gh repo view --json owner -q '.owner.login')
  repo=$(gh repo view --json name -q '.name')
  echo "$owner" "$repo"
}

gitlab_project_path() {
  require_cmd glab jq
  local project_path encoded_path
  project_path=$(glab repo view --output json 2>/dev/null | jq -r '.path_with_namespace // empty')
  [ -z "$project_path" ] && { err "Failed to get project path from glab repo view"; exit 1; }
  encoded_path=$(echo "$project_path" | jq -sRr @uri)
  echo "$project_path" "$encoded_path"
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

worktree_path() {
  echo "$WORKTREES_DIR/$(slugify "$1")"
}

task_branch_name() {
  local goal_branch slug
  goal_branch="$1"
  slug="$2"
  echo "${goal_branch}--${slug}"
}

sync_worktree_config() {
  local wt_path="$1"
  [ -f "$STATE_FILE" ] && cp "$STATE_FILE" "$wt_path/state.json"
  if [ -f "$CONFIG_FILE" ]; then
    mkdir -p "$wt_path/.opencode"
    cp "$CONFIG_FILE" "$wt_path/.opencode/goal-config.json"
  fi
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

fetch_threads_json() {
  require_cmd jq
  require_vcs_cli
  local pr_number="$1"

  case "$platform" in
    github)
      local owner repo query result
      read -r owner repo < <(github_owner_repo)
      query='query($owner:String!,$repo:String!,$pr:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$pr){reviewThreads(first:100){nodes{id isResolved isOutdated path line comments(first:1){nodes{body}}}}}}}}'
      result=$(gh api graphql -f query="$query" -F owner="$owner" -F repo="$repo" -F pr="$pr_number" 2>/dev/null || echo '{}')
      echo "$result" | jq '[.data.repository.pullRequest.reviewThreads.nodes[]? | {
        id: .id,
        path: (.path // ""),
        line: (.line // 0),
        body: (.comments.nodes[0].body // ""),
        resolved: (.isResolved or .isOutdated)
      }]'
      ;;
    gitlab)
      local encoded_path result
      read -r _ encoded_path < <(gitlab_project_path)
      result=$(glab api "projects/$encoded_path/merge_requests/$pr_number/discussions" 2>/dev/null || echo '[]')
      echo "$result" | jq '[.[]? | {
        id: .id,
        path: (.position.new_path // ""),
        line: (.position.new_line // 0),
        body: (.notes[0].body // ""),
        resolved: (.notes[0].resolved // false)
      }]'
      ;;
  esac
}

cmd_threads() {
  local pr_number
  pr_number="$(pr_number_active)"
  fetch_threads_json "$pr_number"
}

cmd_pending() {
  require_cmd jq
  local pr_number threads_json total unresolved
  pr_number="$(pr_number_active)"
  threads_json="$(fetch_threads_json "$pr_number")"
  total=$(echo "$threads_json" | jq 'length')
  unresolved=$(echo "$threads_json" | jq '[.[] | select(.resolved == false)] | length')

  echo "{\"total\": ${total:-0}, \"unresolved\": ${unresolved:-0}}"

  if [ "${unresolved:-0}" -gt 0 ]; then
    warn "$unresolved unresolved thread(s) remain — loop continues"
    exit 1
  fi

  log "No unresolved threads — PR/MR is clean"
  exit 0
}

cmd_comment() {
  require_cmd jq
  require_vcs_cli
  local path="${1:-}" line="${2:-}" body="${3:-}"
  [ -z "$path" ] || [ -z "$line" ] || [ -z "$body" ] && {
    err "comment requires: <path> <line> <body>"
    exit 1
  }

  local pr_number
  pr_number="$(pr_number_active)"

  case "$platform" in
    github)
      local owner repo head_sha
      read -r owner repo < <(github_owner_repo)
      head_sha=$(gh pr view "$pr_number" --json headRefOid -q '.headRefOid')
      gh api "repos/$owner/$repo/pulls/$pr_number/comments" \
        -f commit_id="$head_sha" \
        -f path="$path" \
        -F line="$line" \
        -f side="RIGHT" \
        -f body="$body" >/dev/null
      ;;
    gitlab)
      local encoded_path versions base_sha head_sha start_sha
      read -r _ encoded_path < <(gitlab_project_path)
      versions=$(glab api "projects/$encoded_path/merge_requests/$pr_number/versions" | jq '.[0]')
      base_sha=$(echo "$versions" | jq -r '.base_commit_sha')
      head_sha=$(echo "$versions" | jq -r '.head_commit_sha')
      start_sha=$(echo "$versions" | jq -r '.start_commit_sha // .base_commit_sha')
      glab api --method POST "projects/$encoded_path/merge_requests/$pr_number/discussions" \
        -f "body=$body" \
        -f "position[position_type]=text" \
        -f "position[base_sha]=$base_sha" \
        -f "position[head_sha]=$head_sha" \
        -f "position[start_sha]=$start_sha" \
        -f "position[new_path]=$path" \
        -f "position[new_line]=$line" >/dev/null
      ;;
  esac

  log "Posted inline comment on $path:$line"
}

cmd_resolve() {
  require_cmd jq
  require_vcs_cli
  local thread_id="${1:-}"
  [ -z "$thread_id" ] && { err "resolve requires <thread-id>"; exit 1; }

  local pr_number
  pr_number="$(pr_number_active)"

  case "$platform" in
    github)
      local mutation
      mutation="mutation { resolveReviewThread(input: {threadId: \"$thread_id\"}) { thread { isResolved } } }"
      gh api graphql -f query="$mutation" >/dev/null
      ;;
    gitlab)
      local encoded_path
      read -r _ encoded_path < <(gitlab_project_path)
      glab api --method PUT "projects/$encoded_path/merge_requests/$pr_number/discussions/$thread_id?resolved=true" >/dev/null
      ;;
  esac

  log "Resolved thread: $thread_id"
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
  local source="${1:-}" target="${2:-}" plat="${3:-}" concurrency="${4:-1}"

  [ -z "$source" ] || [ -z "$target" ] || [ -z "$plat" ] && {
    err "config set requires: <goal_source> <target_branch> <platform> [concurrency]"
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

  if ! [[ "$concurrency" =~ ^[0-9]+$ ]] || [ "$concurrency" -lt 1 ]; then
    err "concurrency must be a positive integer (1 = sequential only)"
    exit 1
  fi

  mkdir -p "$(dirname "$CONFIG_FILE")"
  jq -n \
    --arg source "$source" \
    --arg target "$target" \
    --arg platform "$plat" \
    --argjson concurrency "$concurrency" \
    '{goal_source: $source, target_branch: $target, platform: $platform, concurrency: $concurrency}' \
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

cmd_worktree_add() {
  require_cmd git jq
  local slug="${1:-}"
  [ -z "$slug" ] && { err "worktree add requires <task-slug>"; exit 1; }

  slug="$(slugify "$slug")"
  require_active_goal

  local goal_branch task_branch wt_path
  goal_branch=$(jq -r '.[-1].branch' "$STATE_FILE")
  task_branch="$(task_branch_name "$goal_branch" "$slug")"
  wt_path="$(worktree_path "$slug")"

  mkdir -p "$WORKTREES_DIR"
  if [ -d "$wt_path" ]; then
    err "Worktree already exists: $wt_path"
    exit 1
  fi

  git worktree add -b "$task_branch" "$wt_path" "$goal_branch"
  sync_worktree_config "$wt_path"

  echo "$wt_path"
  log "Worktree created: $wt_path (branch: $task_branch)"
}

cmd_worktree_list() {
  require_cmd git
  if [ -d "$WORKTREES_DIR" ]; then
    log "Task worktrees in $WORKTREES_DIR:"
    for d in "$WORKTREES_DIR"/*/; do
      [ -d "$d" ] || continue
      echo "  $(basename "$d") -> $d"
    done
  else
    log "No task worktrees yet"
  fi
  echo ""
  git worktree list
}

cmd_worktree_merge() {
  require_cmd git jq
  local slug="${1:-}"
  [ -z "$slug" ] && { err "worktree merge requires <task-slug>"; exit 1; }

  slug="$(slugify "$slug")"
  require_active_goal

  local goal_branch task_branch wt_path
  goal_branch=$(jq -r '.[-1].branch' "$STATE_FILE")
  task_branch="$(task_branch_name "$goal_branch" "$slug")"
  wt_path="$(worktree_path "$slug")"

  [ -d "$wt_path" ] || { err "Worktree not found: $wt_path"; exit 1; }

  (
    cd "$wt_path"
    git add -A
    if ! git diff --cached --quiet; then
      git commit -m "feat: $slug"
    fi
  )

  git checkout "$goal_branch"
  if ! git merge "$task_branch" -m "merge: $slug"; then
    err "Merge conflict merging $task_branch into $goal_branch"
    git diff --name-only --diff-filter=U
    exit 1
  fi

  git worktree remove "$wt_path" --force 2>/dev/null || git worktree remove "$wt_path"
  git branch -d "$task_branch" 2>/dev/null || true
  log "Merged $task_branch into $goal_branch"
}

cmd_worktree_remove() {
  require_cmd git jq
  local slug="${1:-}"
  [ -z "$slug" ] && { err "worktree remove requires <task-slug>"; exit 1; }

  slug="$(slugify "$slug")"
  require_active_goal

  local goal_branch task_branch wt_path
  goal_branch=$(jq -r '.[-1].branch' "$STATE_FILE")
  task_branch="$(task_branch_name "$goal_branch" "$slug")"
  wt_path="$(worktree_path "$slug")"

  [ -d "$wt_path" ] || { err "Worktree not found: $wt_path"; exit 1; }

  git worktree remove "$wt_path" --force 2>/dev/null || git worktree remove "$wt_path"
  git branch -D "$task_branch" 2>/dev/null || true
  log "Removed worktree: $wt_path"
}

cmd_selfcheck() {
  require_cmd git jq
  log "selfcheck: start"
  log "Project root: $PROJECT_ROOT"
  log "State file: $STATE_FILE"
  log "Config file: $CONFIG_FILE"
  log "Worktrees dir: $WORKTREES_DIR"

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
  threads)  cmd_threads ;;
  comment)  cmd_comment "${2:-}" "${3:-}" "${4:-}" ;;
  resolve)  cmd_resolve "${2:-}" ;;
  analyze)  cmd_analyze ;;
  config)
    case "${2:-}" in
      set) cmd_config_set "${3:-}" "${4:-}" "${5:-}" "${6:-1}" ;;
      get) cmd_config_get ;;
      *)   err "config subcommand must be 'set' or 'get'"; exit 1 ;;
    esac
    ;;
  state)    cmd_state ;;
  status)   cmd_status ;;
  restore)  shift; cmd_restore "$@" ;;
  diff)     cmd_diff ;;
  worktree)
    case "${2:-}" in
      add)    cmd_worktree_add "${3:-}" ;;
      list)   cmd_worktree_list ;;
      merge)  cmd_worktree_merge "${3:-}" ;;
      remove) cmd_worktree_remove "${3:-}" ;;
      *)      err "worktree subcommand must be add, list, merge, or remove"; exit 1 ;;
    esac
    ;;
  selfcheck) cmd_selfcheck ;;
  *)        usage ;;
esac
