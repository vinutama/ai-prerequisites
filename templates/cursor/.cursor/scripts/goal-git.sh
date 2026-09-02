#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"
STATE_FILE="$PROJECT_ROOT/state.json"
CONFIG_FILE="$PROJECT_ROOT/.cursor/goal-config.json"
FIGMA_ENV_FILE="$PROJECT_ROOT/.cursor/figma.env"
MCP_JSON="$PROJECT_ROOT/.cursor/mcp.json"
WORKTREES_DIR="$PROJECT_ROOT/.worktrees"
REVIEW_DIR="$PROJECT_ROOT/.goal-review"
AGENT_CONFIG_DIR=".cursor"

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
  start <goal> [ticket] [task_type]  Create branch (jira: task_type/TICKET-slug)
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
  config set <source> <target> <platform> [concurrency] [auto_merge] [review_mode] [review_max_iterations]  Write goal-config.json
  config get                Print goal-config.json
  state                     Print active goal JSON from state.json
  state complete            Mark active goal status as completed
  merge                     Merge active PR/MR into target branch (after clean review)
  status                    Show working tree status
  restore <file>...         Restore files to HEAD
  diff                      Show diff against base branch for active goal
  worktree add <task-slug>  Create isolated git worktree for parallel task
  worktree list             List active task worktrees
  worktree merge <task-slug>  Merge worktree branch into goal branch
  worktree remove <task-slug> Remove worktree without merging
  figma setup <token>       Store Figma PAT and enable figma MCP in .cursor/mcp.json
  figma design set <url>    Set default Figma design link in goal-config.json
  figma disable             Disable Figma integration
  figma status              Show Figma integration status
  issues list [url] [limit]     List open issues from GitHub/GitLab issue list URL
  issues start <number> [--worktree]  Start goal for issue (branch off base)
  issues queue                  Print current issue run queue from state
  issues finish <number>        Mark issue goal complete and remove worktree
  review init [repo_path]       Initialize local review findings file
  review add <path> <line> <severity> <body> [repo_path]  Add local finding
  review list [repo_path]       List local findings as JSON
  review resolve <id> [repo_path]  Mark local finding resolved
  review pending [repo_path]    Check unresolved local findings (exit 0 = clean)
  review iterate [repo_path]      Increment review iteration (exit 1 if cap exceeded)
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

get_repos() {
  local repos
  repos=$(config_read repos 2>/dev/null || true)
  if [ -z "$repos" ] || [ "$repos" = "null" ]; then
    echo "."
  else
    echo "$repos" | jq -r '.[]'
  fi
}

repo_dir() {
  local repo="$1"
  if [ "$repo" = "." ]; then
    echo "$PROJECT_ROOT"
  else
    echo "$PROJECT_ROOT/$repo"
  fi
}

is_multi_repo() {
  local repos
  repos=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].repos // [] | length' "$STATE_FILE" 2>/dev/null || echo "0")
  [ "$repos" -gt 1 ] && return 0 || return 1
}

get_state_pr_number() {
  local repo_path="${1:-}"
  if [ -z "$repo_path" ] || [ "$repo_path" = "." ]; then
    jq -r --argjson idx "$GOAL_IDX" '.[$idx].pr_number // null' "$STATE_FILE"
  else
    jq -r --argjson idx "$GOAL_IDX" --arg r "$repo_path" '.[$idx].repos[]? | select(.path == $r) | .pr_number' "$STATE_FILE"
  fi
}

get_state_pr_url() {
  local repo_path="${1:-}"
  if [ -z "$repo_path" ] || [ "$repo_path" = "." ]; then
    jq -r --argjson idx "$GOAL_IDX" '.[$idx].pr_url // ""' "$STATE_FILE"
  else
    jq -r --argjson idx "$GOAL_IDX" --arg r "$repo_path" '.[$idx].repos[]? | select(.path == $r) | .pr_url // ""' "$STATE_FILE"
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

# --- Goal index (GOAL_ISSUE selects entry; default -1 = active goal) ---

resolve_goal_idx() {
  if [ -n "${GOAL_ISSUE:-}" ] && [ -f "$STATE_FILE" ]; then
    state_ensure_array
    jq --argjson n "$GOAL_ISSUE" \
      '(map(.issue.number? == $n) | index(true)) // (length - 1)' "$STATE_FILE"
  else
    echo "-1"
  fi
}

refresh_goal_idx() {
  GOAL_IDX="$(resolve_goal_idx)"
}

goal_workdir() {
  if [ ! -f "$STATE_FILE" ]; then
    echo "$PROJECT_ROOT"
    return
  fi
  local wt
  wt=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].worktree // ""' "$STATE_FILE" 2>/dev/null || echo "")
  if [ -n "$wt" ] && [ -d "$PROJECT_ROOT/$wt" ]; then
    echo "$PROJECT_ROOT/$wt"
  else
    echo "$PROJECT_ROOT"
  fi
}

GOAL_IDX="-1"
refresh_goal_idx

# --- State Helpers ---

state_ensure_array() {
  if [ -f "$STATE_FILE" ] && jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
    jq '[.]' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  fi
}

state_active() {
  state_ensure_array
  jq -r --argjson idx "$GOAL_IDX" '.[$idx]' "$STATE_FILE"
}

state_update() {
  local field="$1" value="$2"
  jq --argjson idx "$GOAL_IDX" --arg v "$value" ".[\$idx].$field = \$v" "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

require_active_goal() {
  require_cmd jq
  [ ! -f "$STATE_FILE" ] && { err "No state found — run 'start' first"; exit 1; }
  state_ensure_array
}

pr_number_active() {
  require_active_goal
  local repo_path="${1:-}"
  local pr_number

  if [ -n "$repo_path" ]; then
    pr_number=$(jq -r --argjson idx "$GOAL_IDX" --arg r "$repo_path" '.[$idx].repos[]? | select(.path == $r) | .pr_number' "$STATE_FILE")
    if [ "$pr_number" = "null" ] || [ -z "$pr_number" ]; then
      err "No PR/MR yet for $repo_path — run 'goal-git.sh pr' first"
      exit 1
    fi
  else
    pr_number=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].pr_number' "$STATE_FILE")
    if [ "$pr_number" = "null" ] || [ -z "$pr_number" ]; then
      err "No PR/MR yet — run 'goal-git.sh pr' first"
      exit 1
    fi
  fi

  echo "$pr_number"
}

github_owner_repo() {
  require_cmd gh
  local workdir="${1:-$PROJECT_ROOT}"
  local owner repo
  owner=$(cd "$workdir" && gh repo view --json owner -q '.owner.login')
  repo=$(cd "$workdir" && gh repo view --json name -q '.name')
  echo "$owner" "$repo"
}

gitlab_project_path() {
  require_cmd glab jq
  local workdir="${1:-$PROJECT_ROOT}"
  local project_path encoded_path
  project_path=$(cd "$workdir" && glab repo view --output json 2>/dev/null | jq -r '.path_with_namespace // empty')
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
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' \
    | sed 's/^-//;s/-$//' | head -c 50 | sed 's/-$//'
}

normalize_ticket() {
  echo "$1" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
}

normalize_task_type() {
  local raw
  raw=$(echo "${1:-feat}" | tr '[:upper:]' '[:lower:]')
  case "$raw" in
    bug|bugfix|fix|defect) echo bug ;;
    feat|feature) echo feat ;;
    chore|refactor|docs|test|perf) echo "$raw" ;;
    *) echo feat ;;
  esac
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
    mkdir -p "$wt_path/$AGENT_CONFIG_DIR"
    cp "$CONFIG_FILE" "$wt_path/$AGENT_CONFIG_DIR/goal-config.json"
  fi
}

cmd_start() {
  require_cmd git jq
  require_vcs_cli
  local goal="${1:-}" ticket="${2:-}" task_type="${3:-}"
  [ -z "$goal" ] && { err "start requires a goal description"; exit 1; }

  state_ensure_array

  if [ -f "$STATE_FILE" ]; then
    local old_status
    old_status=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].status // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
    if [ "${GOAL_SUPPRESS_IN_PROGRESS_WARN:-}" != "1" ] && [ "$old_status" = "in_progress" ]; then
      warn "A goal is already in progress. Starting a new goal will append to history. Use 'continue' to extend the existing goal instead."
    fi
  fi

  local base branch goal_source ticket_key type_slug
  base=$(detect_base)
  goal_source="${GOAL_SOURCE_OVERRIDE:-$(config_read goal_source)}"

  if [ "$goal_source" = "jira" ]; then
    if [ -z "$ticket" ]; then
      ticket="$(config_read jira_ticket)"
    fi
    if [ -z "$ticket" ]; then
      err "jira goal_source requires a ticket key — pass start <goal> <ticket> [task_type] or set jira_ticket via /init-goal"
      exit 1
    fi
    ticket_key="$(normalize_ticket "$ticket")"
    type_slug="$(normalize_task_type "$task_type")"
    branch="${type_slug}/${ticket_key}-$(slugify "$goal")"
  else
    branch="goal/$(slugify "$goal")"
  fi

  log "Platform: $platform"
  log "Base: $base"
  log "Branch: $branch"

  local repos_json="[]"
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    local rd
    rd=$(repo_dir "$repo")
    log "Creating branch in: $repo"
    (cd "$rd" && git fetch origin "$base" 2>/dev/null || true)
    (cd "$rd" && git checkout -b "$branch" "origin/$base" 2>/dev/null || git checkout "$branch" 2>/dev/null || true)
    repos_json=$(echo "$repos_json" | jq --arg path "$repo" '. + [{"path": $path, "pr_number": null, "pr_url": ""}]')
  done < <(get_repos)

  local new_goal
  local repo_count
  repo_count=$(echo "$repos_json" | jq 'length')

  if [ "$repo_count" -eq 1 ]; then
    new_goal=$(jq -n --arg goal "$goal" --arg branch "$branch" --arg base "$base" \
      '{goal: $goal, branch: $branch, base_branch: $base, pr_number: null, pr_url: "", status: "in_progress", repos: []}')
    new_goal=$(echo "$new_goal" | jq --argjson r "$repos_json" '.repos = $r')
  else
    new_goal=$(jq -n --arg goal "$goal" --arg branch "$branch" --arg base "$base" --argjson repos "$repos_json" \
      '{goal: $goal, branch: $branch, base_branch: $base, status: "in_progress", repos: $repos}')
  fi

  if [ -f "$STATE_FILE" ]; then
    jq --argjson entry "$new_goal" '. + [$entry]' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  else
    echo "[$new_goal]" > "$STATE_FILE"
  fi
  log "Goal #$(jq 'length' "$STATE_FILE") started ($repo_count repos)"
}

cmd_commit() {
  require_cmd git
  refresh_goal_idx
  local msg="${1:-chore: automated changes}" wd
  wd="$(goal_workdir)"
  (cd "$wd" && git diff --cached --quiet) && { log "Nothing staged to commit. Use 'stage <file>...' to add files."; return; }
  (cd "$wd" && git commit -m "$msg")
  log "Committed: $msg"
}

cmd_push() {
  require_cmd git jq
  refresh_goal_idx
  state_ensure_array
  local branch
  branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch' "$STATE_FILE")
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    local rd
    rd=$(repo_dir "$repo")
    (cd "$rd" && git push -u origin "$branch" --force-with-lease 2>/dev/null) || (cd "$rd" && git push -u origin "$branch")
    log "Pushed: $repo/$branch"
  done < <(get_repos)
}

cmd_pr() {
  require_cmd jq
  require_vcs_cli
  refresh_goal_idx
  state_ensure_array
  local branch base goal title
  branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch' "$STATE_FILE")
  base=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].base_branch' "$STATE_FILE")
  goal=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].goal' "$STATE_FILE")
  title="${goal:0:250}"

  local repos
  repos=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].repos // []' "$STATE_FILE")

  if [ "$repos" = "[]" ] || [ "$repos" = "null" ]; then
    local pr_number
    pr_number=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].pr_number' "$STATE_FILE")
    if [ "$pr_number" != "null" ] && [ -n "$pr_number" ]; then
      log "PR/MR already exists: #$pr_number"
      return
    fi
    create_pr "" "$branch" "$base" "$title" "$goal"
    local result_pr_number="${PR_RESULT_NUMBER:-}"
    local result_pr_url="${PR_RESULT_URL:-}"
    jq --argjson idx "$GOAL_IDX" --argjson pn "$result_pr_number" --arg url "$result_pr_url" \
      '.[$idx].pr_number = $pn | .[$idx].pr_url = $url' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    log "Created: $result_pr_url"
    return
  fi

  local repo_count repo_idx updated_repos
  repo_count=$(echo "$repos" | jq 'length')
  repo_idx=0
  updated_repos="$repos"

  while [ "$repo_idx" -lt "$repo_count" ]; do
    local repo_path repo_pr
    repo_path=$(echo "$updated_repos" | jq -r ".[$repo_idx].path")
    repo_pr=$(echo "$updated_repos" | jq -r ".[$repo_idx].pr_number")

    if [ "$repo_pr" != "null" ] && [ -n "$repo_pr" ]; then
      log "PR/MR already exists for $repo_path: #$repo_pr"
      repo_idx=$((repo_idx + 1))
      continue
    fi

    create_pr "$repo_path" "$branch" "$base" "$title" "$goal"
    local result_pr_number="${PR_RESULT_NUMBER:-}"
    local result_pr_url="${PR_RESULT_URL:-}"

    updated_repos=$(echo "$updated_repos" | jq --argjson idx "$repo_idx" --argjson pn "$result_pr_number" --arg url "$result_pr_url" \
      ".[$repo_idx].pr_number = \$pn | .[$repo_idx].pr_url = \$url")
    log "Created PR in $repo_path: $result_pr_url"
    repo_idx=$((repo_idx + 1))
  done

  jq --argjson idx "$GOAL_IDX" --argjson repos "$updated_repos" '.[$idx].repos = $repos' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

create_pr() {
  local repo_path="$1" branch="$2" base="$3" title="$4" body="$5"
  local workdir issue_num issue_body
  refresh_goal_idx
  issue_num=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].issue.number // empty' "$STATE_FILE" 2>/dev/null || echo "")
  issue_body="$body"
  if [ -n "$issue_num" ]; then
    issue_body="${body}

Closes #${issue_num}"
  fi
  if [ -z "$repo_path" ] || [ "$repo_path" = "." ]; then
    workdir="$(goal_workdir)"
  else
    workdir="$PROJECT_ROOT/$repo_path"
  fi

  local pr_number pr_url
  case "$platform" in
    github)
      pr_number=$(cd "$workdir" && gh pr create --base "$base" --head "$branch" --title "$title" --body "$issue_body" --json number -q '.number')
      local gh_owner
      gh_owner=$(cd "$workdir" && gh repo view --json nameWithOwner -q '.nameWithOwner')
      pr_url="https://github.com/$gh_owner/pull/$pr_number"
      ;;
    gitlab)
      log "Creating MR: $title"
      local mr_output mr_number
      mr_output=$(cd "$workdir" && glab mr create --yes --source-branch "$branch" --target-branch "$base" --title "$title" --description "$issue_body" --output json 2>/dev/null || true)
      if echo "$mr_output" | jq -e '.iid' >/dev/null 2>&1; then
        mr_number=$(echo "$mr_output" | jq -r '.iid')
        pr_url=$(echo "$mr_output" | jq -r '.web_url // empty')
      else
        mr_output=$(cd "$workdir" && glab mr create --yes --source-branch "$branch" --target-branch "$base" --title "$title" --description "$issue_body" 2>&1)
        mr_number=$(echo "$mr_output" | grep -oE '\!([0-9]+)' | head -1 | tr -d '!')
      fi
      [ -z "$mr_number" ] && { err "Failed to extract MR number from glab output"; err "Output: $mr_output"; exit 1; }
      pr_number="$mr_number"
      if [ -z "$pr_url" ]; then
        local project_path remote_url
        project_path=$(cd "$workdir" && glab repo view --output json 2>/dev/null | jq -r '.path_with_namespace // empty' || echo "")
        if [ -n "$project_path" ]; then
          pr_url="https://gitlab.com/$project_path/-/merge_requests/$pr_number"
        else
          remote_url=$(cd "$workdir" && git remote get-url origin 2>/dev/null | sed 's/\.git$//' | sed 's|^git@gitlab.com:|https://gitlab.com/|')
          pr_url="${remote_url}/-/merge_requests/$pr_number"
        fi
      fi
      ;;
  esac

  PR_RESULT_NUMBER="$pr_number"
  PR_RESULT_URL="$pr_url"
}

fetch_threads_json() {
  require_cmd jq
  require_vcs_cli
  local pr_number="$1"
  local repo_path="${2:-}"
  local workdir
  workdir="$(repo_dir "${repo_path:-.}")"

  case "$platform" in
    github)
      local owner repo query result errors
      read -r owner repo < <(github_owner_repo "$workdir")
      query='query($owner:String!,$repo:String!,$pr:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$pr){reviewThreads(first:100){nodes{id isResolved isOutdated path line comments(first:1){nodes{body}}}}}}}}'
      result=$(cd "$workdir" && gh api graphql -f query="$query" -F owner="$owner" -F repo="$repo" -F pr="$pr_number" 2>&1) || {
        err "Failed to fetch GitHub review threads for PR #$pr_number"
        echo "$result" >&2
        exit 1
      }
      errors=$(echo "$result" | jq -r '.errors // [] | length')
      if [ "${errors:-0}" -gt 0 ]; then
        err "GraphQL errors fetching review threads:"
        echo "$result" | jq -r '.errors[]?.message // .errors[]?' >&2
        exit 1
      fi
      if ! echo "$result" | jq -e '.data.repository.pullRequest' >/dev/null 2>&1; then
        err "GraphQL returned no pullRequest for PR #$pr_number"
        echo "$result" >&2
        exit 1
      fi
      echo "$result" | jq '[.data.repository.pullRequest.reviewThreads.nodes[]? | {
        id: .id,
        path: (.path // ""),
        line: (.line // 0),
        body: (.comments.nodes[0].body // ""),
        resolved: .isResolved,
        outdated: .isOutdated
      }]'
      ;;
    gitlab)
      local encoded_path result
      read -r _ encoded_path < <(gitlab_project_path "$workdir")
      result=$(cd "$workdir" && glab api "projects/$encoded_path/merge_requests/$pr_number/discussions" 2>&1) || {
        err "Failed to fetch GitLab discussions for MR #$pr_number"
        echo "$result" >&2
        exit 1
      }
      echo "$result" | jq '[.[]? | {
        id: .id,
        path: (.position.new_path // ""),
        line: (.position.new_line // 0),
        body: (.notes[0].body // ""),
        resolved: (.notes[0].resolved // false),
        outdated: false
      }]'
      ;;
  esac
}

cmd_threads() {
  local repo_path="${1:-}"
  local pr_number
  pr_number="$(pr_number_active "$repo_path")"
  fetch_threads_json "$pr_number" "$repo_path"
}

cmd_pending() {
  require_cmd jq
  local repo_path="${1:-}"
  local pr_number
  pr_number="$(pr_number_active "$repo_path")"
  local threads_json total unresolved
  threads_json="$(fetch_threads_json "$pr_number" "$repo_path")"
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
  local path="${1:-}" line="${2:-}" body="${3:-}" repo_path="${4:-}"
  [ -z "$path" ] || [ -z "$line" ] || [ -z "$body" ] && {
    err "comment requires: <path> <line> <body> [repo_path]"
    exit 1
  }

  local workdir pr_number
  workdir="$(repo_dir "${repo_path:-.}")"
  pr_number="$(pr_number_active "$repo_path")"

  case "$platform" in
    github)
      local owner repo head_sha
      read -r owner repo < <(github_owner_repo "$workdir")
      head_sha=$(cd "$workdir" && gh pr view "$pr_number" --json headRefOid -q '.headRefOid')
      (cd "$workdir" && gh api "repos/$owner/$repo/pulls/$pr_number/comments" \
        -f commit_id="$head_sha" \
        -f path="$path" \
        -F line="$line" \
        -f side="RIGHT" \
        -f body="$body" >/dev/null)
      ;;
    gitlab)
      local encoded_path versions base_sha head_sha start_sha
      read -r _ encoded_path < <(gitlab_project_path "$workdir")
      versions=$(cd "$workdir" && glab api "projects/$encoded_path/merge_requests/$pr_number/versions" | jq '.[0]')
      base_sha=$(echo "$versions" | jq -r '.base_commit_sha')
      head_sha=$(echo "$versions" | jq -r '.head_commit_sha')
      start_sha=$(echo "$versions" | jq -r '.start_commit_sha // .base_commit_sha')
      (cd "$workdir" && glab api --method POST "projects/$encoded_path/merge_requests/$pr_number/discussions" \
        -f "body=$body" \
        -f "position[position_type]=text" \
        -f "position[base_sha]=$base_sha" \
        -f "position[head_sha]=$head_sha" \
        -f "position[start_sha]=$start_sha" \
        -f "position[new_path]=$path" \
        -f "position[new_line]=$line" >/dev/null)
      ;;
  esac

  log "Posted inline comment on $path:$line${repo_path:+ in $repo_path}"
}

cmd_resolve() {
  require_cmd jq
  require_vcs_cli
  local thread_id="${1:-}" repo_path="${2:-}"
  [ -z "$thread_id" ] && { err "resolve requires <thread-id> [repo_path]"; exit 1; }

  local workdir pr_number
  workdir="$(repo_dir "${repo_path:-.}")"
  pr_number="$(pr_number_active "$repo_path")"

  case "$platform" in
    github)
      local mutation result errors is_resolved
      mutation="mutation { resolveReviewThread(input: {threadId: \"$thread_id\"}) { thread { isResolved } } }"
      result=$(cd "$workdir" && gh api graphql -f query="$mutation" 2>&1) || {
        err "GraphQL resolve failed for thread $thread_id"
        echo "$result" >&2
        exit 1
      }
      errors=$(echo "$result" | jq -r '.errors // [] | length')
      if [ "${errors:-0}" -gt 0 ]; then
        err "GraphQL errors resolving thread $thread_id:"
        echo "$result" | jq -r '.errors[]?.message // .errors[]?' >&2
        exit 1
      fi
      is_resolved=$(echo "$result" | jq -r '.data.resolveReviewThread.thread.isResolved // false')
      if [ "$is_resolved" != "true" ]; then
        err "Thread $thread_id was not marked resolved (isResolved=$is_resolved)"
        exit 1
      fi
      ;;
    gitlab)
      local encoded_path result
      read -r _ encoded_path < <(gitlab_project_path "$workdir")
      result=$(cd "$workdir" && glab api --method PUT "projects/$encoded_path/merge_requests/$pr_number/discussions/$thread_id?resolved=true" 2>&1) || {
        err "Failed to resolve GitLab discussion $thread_id"
        echo "$result" >&2
        exit 1
      }
      if echo "$result" | jq -e '.message? // .error? // empty' >/dev/null 2>&1; then
        local api_err
        api_err=$(echo "$result" | jq -r '.message // .error // empty')
        if [ -n "$api_err" ]; then
          err "GitLab API error resolving $thread_id: $api_err"
          exit 1
        fi
      fi
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
    branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch' "$STATE_FILE")
    log "Switched to goal on branch: $branch"
  fi

  jq --argjson idx "$GOAL_IDX" '.[$idx].status = "in_progress"' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

  local branch
  branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch' "$STATE_FILE")
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    local rd
    rd=$(repo_dir "$repo")
    (cd "$rd" && git checkout "$branch" 2>/dev/null || true)
  done < <(get_repos)
  log "Continuing on branch: $branch"
  log "Goal: $(jq -r --argjson idx "$GOAL_IDX" '.[$idx].goal' "$STATE_FILE")"
}

cmd_stage() {
  require_cmd git
  refresh_goal_idx
  local wd
  wd="$(goal_workdir)"
  [ $# -eq 0 ] && { err "stage requires at least one file path"; exit 1; }
  (cd "$wd" && git add "$@")
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
  refresh_goal_idx
  local wd
  wd="$(goal_workdir)"
  (cd "$wd" || true)
  log "Running gitnexus analyze…"
  npx --yes gitnexus@latest analyze || { err "gitnexus analyze failed"; exit 1; }
  log "Running rtk gain…"
  rtk gain || { err "rtk gain failed"; exit 1; }
  log "Analyze complete"
}

# --- Figma Helpers ---

config_ensure_exists() {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  if [ ! -f "$CONFIG_FILE" ]; then
    echo '{}' > "$CONFIG_FILE"
  fi
}

parse_figma_url() {
  local url="$1"
  if ! echo "$url" | grep -qE 'figma\.com/(design|file|board)/'; then
    err "Invalid Figma URL — must contain figma.com/design/, file/, or board/"
    return 1
  fi
  FIGMA_FILE_KEY="$(echo "$url" | grep -oE 'figma\.com/(design|file|board)/[^/?]+' | sed -E 's|.*/||' | head -1)"
  [ -z "$FIGMA_FILE_KEY" ] && { err "Could not parse file key from Figma URL"; return 1; }
  FIGMA_NODE_ID="$(echo "$url" | sed -nE 's/.*[?&]node-id=([^&]+).*/\1/p' | head -1)"
  if [ -n "$FIGMA_NODE_ID" ]; then
    FIGMA_NODE_ID="${FIGMA_NODE_ID//-/:}"
  fi
}

merge_figma_mcp() {
  local enabled="${1:-true}"
  require_cmd jq
  local mcp_json="$PROJECT_ROOT/.cursor/mcp.json"
  local figma_block
  figma_block=$(jq -n --arg key '${FIGMA_API_KEY}' '{
    command: "npx",
    args: ["-y", "figma-developer-mcp", "--stdio"],
    env: {FIGMA_API_KEY: $key}
  }')
  if [ "$enabled" != "true" ]; then
    if [ -f "$mcp_json" ]; then
      jq 'if .mcpServers.figma then del(.mcpServers.figma) else . end' \
        "$mcp_json" > "$mcp_json.tmp" && mv "$mcp_json.tmp" "$mcp_json"
    fi
    return
  fi
  mkdir -p "$(dirname "$mcp_json")"
  if [ -f "$mcp_json" ]; then
    jq --argjson figma "$figma_block" \
      '.mcpServers = ((.mcpServers // {}) * {figma: $figma})' \
      "$mcp_json" > "$mcp_json.tmp" && mv "$mcp_json.tmp" "$mcp_json"
  else
    jq -n --argjson figma "$figma_block" \
      '{mcpServers: {figma: $figma}}' \
      > "$mcp_json"
  fi
}

cmd_figma_setup() {
  require_cmd jq
  local token="${1:-}"
  [ -z "$token" ] && { err "figma setup requires <token>"; exit 1; }

  mkdir -p "$(dirname "$FIGMA_ENV_FILE")"
  printf 'FIGMA_API_KEY=%s\n' "$token" > "$FIGMA_ENV_FILE"
  chmod 600 "$FIGMA_ENV_FILE"

  merge_figma_mcp true
  config_ensure_exists
  jq '.figma_enabled = true' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

  log "Figma PAT saved to $FIGMA_ENV_FILE"
  log "Figma MCP enabled in $MCP_JSON"
  warn "Load secrets before Cursor: set -a && source .cursor/figma.env && set +a && cursor-agent"
  warn "Or use: .cursor/scripts/run-cursor.sh"
}

cmd_figma_design_set() {
  require_cmd jq
  local url="${1:-}"
  [ -z "$url" ] && { err "figma design set requires <url>"; exit 1; }

  config_ensure_exists
  local figma_enabled
  figma_enabled=$(jq -r '.figma_enabled // false' "$CONFIG_FILE")
  if [ "$figma_enabled" != "true" ]; then
    err "Figma not enabled — run 'figma setup <token>' first"
    exit 1
  fi

  parse_figma_url "$url" || exit 1

  jq \
    --arg url "$url" \
    --arg file_key "$FIGMA_FILE_KEY" \
    --arg node_id "${FIGMA_NODE_ID:-}" \
    '.figma_design_url = $url
     | .figma_file_key = $file_key
     | if ($node_id | length) > 0 then .figma_node_id = $node_id else del(.figma_node_id) end' \
    "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

  log "Figma design link saved"
  log "  URL: $url"
  log "  file_key: $FIGMA_FILE_KEY"
  [ -n "${FIGMA_NODE_ID:-}" ] && log "  node_id: $FIGMA_NODE_ID"
}

cmd_figma_disable() {
  require_cmd jq
  config_ensure_exists
  jq '.figma_enabled = false
      | del(.figma_design_url, .figma_file_key, .figma_node_id)' \
    "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

  merge_figma_mcp false

  if [ -f "$FIGMA_ENV_FILE" ]; then
    rm -f "$FIGMA_ENV_FILE"
    log "Removed $FIGMA_ENV_FILE"
  fi

  log "Figma integration disabled"
}

cmd_figma_status() {
  require_cmd jq
  log "Figma status:"
  if [ -f "$CONFIG_FILE" ]; then
    jq '{
      figma_enabled: (.figma_enabled // false),
      figma_design_url: (.figma_design_url // null),
      figma_file_key: (.figma_file_key // null),
      figma_node_id: (.figma_node_id // null)
    }' "$CONFIG_FILE"
  else
    warn "  No goal-config.json"
  fi
  if [ -f "$FIGMA_ENV_FILE" ]; then
    log "  figma.env: present ($FIGMA_ENV_FILE)"
  else
    warn "  figma.env: missing"
  fi
  if [ -f "$MCP_JSON" ] && jq -e '.mcpServers.figma' "$MCP_JSON" >/dev/null 2>&1; then
    log "  .cursor/mcp.json mcpServers.figma: configured"
  else
    warn "  .cursor/mcp.json mcpServers.figma: not configured"
  fi
}

cmd_config_set() {
  require_cmd jq
  local source="${1:-}" target="${2:-}" plat="${3:-}" concurrency="${4:-1}" auto_merge="${5:-false}" review_mode="${6:-inline}" review_max_iterations="${7:-5}"

  [ -z "$source" ] || [ -z "$target" ] || [ -z "$plat" ] && {
    err "config set requires: <goal_source> <target_branch> <platform> [concurrency] [auto_merge] [review_mode] [review_max_iterations]"
    exit 1
  }

  case "$source" in
    jira|markdown|prompt|issues) ;;
    *) err "goal_source must be: jira, markdown, prompt, or issues"; exit 1 ;;
  esac

  case "$plat" in
    github|gitlab) ;;
    *) err "platform must be: github or gitlab"; exit 1 ;;
  esac

  if ! [[ "$concurrency" =~ ^[0-9]+$ ]] || [ "$concurrency" -lt 1 ]; then
    err "concurrency must be a positive integer (1 = sequential only)"
    exit 1
  fi

  case "$auto_merge" in
    true|false) ;;
    *) err "auto_merge must be true or false"; exit 1 ;;
  esac

  case "$review_mode" in
    inline|local) ;;
    *) err "review_mode must be: inline or local"; exit 1 ;;
  esac

  if ! [[ "$review_max_iterations" =~ ^[0-9]+$ ]] || [ "$review_max_iterations" -lt 1 ]; then
    err "review_max_iterations must be a positive integer"
    exit 1
  fi

  local auto_merge_json
  auto_merge_json=$( [ "$auto_merge" = "true" ] && echo true || echo false )

  mkdir -p "$(dirname "$CONFIG_FILE")"
  if [ -f "$CONFIG_FILE" ]; then
    jq \
      --arg source "$source" \
      --arg target "$target" \
      --arg platform "$plat" \
      --arg review_mode "$review_mode" \
      --argjson concurrency "$concurrency" \
      --argjson auto_merge "$auto_merge_json" \
      --argjson review_max_iterations "$review_max_iterations" \
      '.goal_source = $source
       | .target_branch = $target
       | .platform = $platform
       | .concurrency = $concurrency
       | .auto_merge = $auto_merge
       | .review_mode = $review_mode
       | .review_max_iterations = $review_max_iterations' \
      "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  else
    jq -n \
      --arg source "$source" \
      --arg target "$target" \
      --arg platform "$plat" \
      --arg review_mode "$review_mode" \
      --argjson concurrency "$concurrency" \
      --argjson auto_merge "$auto_merge_json" \
      --argjson review_max_iterations "$review_max_iterations" \
      '{
        goal_source: $source,
        target_branch: $target,
        platform: $platform,
        concurrency: $concurrency,
        auto_merge: $auto_merge,
        review_mode: $review_mode,
        review_max_iterations: $review_max_iterations,
        figma_enabled: false
      }' \
      > "$CONFIG_FILE"
  fi

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

cmd_state_complete() {
  require_active_goal
  state_update status completed
  log "Goal marked completed"
}

cmd_merge() {
  require_vcs_cli
  require_cmd jq
  refresh_goal_idx

  local repos
  repos=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].repos // []' "$STATE_FILE")

  if [ "$repos" = "[]" ] || [ "$repos" = "null" ]; then
    local pr_number pr_url
    pr_number="$(pr_number_active)"
    pr_url=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].pr_url // ""' "$STATE_FILE")
    merge_pr "$pr_number" "$pr_url"
    return
  fi

  local repo_count repo_idx
  repo_count=$(echo "$repos" | jq 'length')
  repo_idx=0

  while [ "$repo_idx" -lt "$repo_count" ]; do
    local repo_path repo_pr repo_url repos_dir
    repo_path=$(echo "$repos" | jq -r ".[$repo_idx].path")
    repo_pr=$(echo "$repos" | jq -r ".[$repo_idx].pr_number")
    repo_url=$(echo "$repos" | jq -r ".[$repo_idx].pr_url // \"\"")
    repos_dir=$(repo_dir "$repo_path")

    if [ "$repo_pr" = "null" ] || [ -z "$repo_pr" ]; then
      log "No PR for $repo_path — skipping merge"
      repo_idx=$((repo_idx + 1))
      continue
    fi

    merge_pr_in_dir "$repos_dir" "$repo_pr" "$repo_url"
    repo_idx=$((repo_idx + 1))
  done
}

merge_pr() {
  local pr_number="$1" pr_url="$2"
  merge_pr_in_dir "$PROJECT_ROOT" "$pr_number" "$pr_url"
}

merge_pr_in_dir() {
  local workdir="$1" pr_number="$2" pr_url="$3"
  case "$platform" in
    github)
      if ! (cd "$workdir" && gh pr merge "$pr_number" --merge); then
        err "PR merge failed for #$pr_number — check for conflicts or branch protection"
        exit 1
      fi
      ;;
    gitlab)
      if ! (cd "$workdir" && glab mr merge "$pr_number"); then
        err "MR merge failed for #$pr_number — check for conflicts or branch protection"
        exit 1
      fi
      ;;
  esac

  log "Merged PR/MR #$pr_number"
  if [ -n "$pr_url" ] && [ "$pr_url" != "null" ]; then
    log "URL: $pr_url"
  fi
}

cmd_status() {
  require_cmd git
  refresh_goal_idx
  local wd
  wd="$(goal_workdir)"
  (cd "$wd" && git status)
}

cmd_restore() {
  require_cmd git
  refresh_goal_idx
  local wd
  wd="$(goal_workdir)"
  [ $# -eq 0 ] && { err "restore requires at least one file path"; exit 1; }
  (cd "$wd" && git restore "$@")
  log "Restored: $*"
}

cmd_diff() {
  require_cmd git jq
  [ ! -f "$STATE_FILE" ] && { err "No state found — run 'start' first"; exit 1; }
  state_ensure_array
  refresh_goal_idx
  local repo_path="${1:-}"
  local base
  base=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].base_branch' "$STATE_FILE")
  local rd
  rd=$(repo_dir "${repo_path:-.}")
  (cd "$rd" && git diff "origin/$base..HEAD")
}

cmd_worktree_add() {
  require_cmd git jq
  local slug="${1:-}"
  [ -z "$slug" ] && { err "worktree add requires <task-slug>"; exit 1; }

  slug="$(slugify "$slug")"
  require_active_goal
  refresh_goal_idx

  local goal_branch task_branch wt_path
  goal_branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch' "$STATE_FILE")
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
  refresh_goal_idx

  local goal_branch task_branch wt_path
  goal_branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch' "$STATE_FILE")
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
  refresh_goal_idx

  local goal_branch task_branch wt_path
  goal_branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch' "$STATE_FILE")
  task_branch="$(task_branch_name "$goal_branch" "$slug")"
  wt_path="$(worktree_path "$slug")"

  [ -d "$wt_path" ] || { err "Worktree not found: $wt_path"; exit 1; }

  git worktree remove "$wt_path" --force 2>/dev/null || git worktree remove "$wt_path"
  git branch -D "$task_branch" 2>/dev/null || true
  log "Removed worktree: $wt_path"
}

# --- Issue list / queue helpers ---

generate_run_id() {
  echo "run-$(date +%s)-$$"
}

issue_worktree_rel() {
  echo ".worktrees/issue-${1}"
}

parse_issue_list_url() {
  local url="$1"
  ISSUE_LIST_REPO=""
  ISSUE_LIST_QUERY=""
  ISSUE_LIST_PLATFORM=""

  if echo "$url" | grep -qE 'github\.com/[^/]+/[^/]+/issues'; then
    ISSUE_LIST_PLATFORM="github"
    ISSUE_LIST_REPO="$(echo "$url" | sed -nE 's|.*github\.com/([^/]+/[^/]+)/issues.*|\1|p' | head -1)"
    ISSUE_LIST_QUERY="$(echo "$url" | sed -nE 's/.*[?&]q=([^&]+).*/\1/p' | head -1)"
    if [ -n "$ISSUE_LIST_QUERY" ]; then
      ISSUE_LIST_QUERY="$(printf '%b' "${ISSUE_LIST_QUERY//+/ }")"
    fi
    return 0
  fi

  if echo "$url" | grep -q '/-/issues'; then
    ISSUE_LIST_PLATFORM="gitlab"
    ISSUE_LIST_REPO="$(echo "$url" | sed -nE 's|(.*)/-/issues.*|\1|p' | head -1)"
    ISSUE_LIST_REPO="${ISSUE_LIST_REPO#https://}"
    ISSUE_LIST_REPO="${ISSUE_LIST_REPO#http://}"
    ISSUE_LIST_REPO="$(echo "$ISSUE_LIST_REPO" | sed -E 's|^[^/]+/||')"
    ISSUE_LIST_QUERY="$(echo "$url" | sed -nE 's/.*[?&]label_name=([^&]+).*/\1/p' | head -1)"
    return 0
  fi

  err "Cannot parse issue list URL — expected github.com/<owner>/<repo>/issues or <host>/<group>/<project>/-/issues"
  return 1
}

task_type_from_issue_labels() {
  local labels_json="${1:-[]}"
  local label
  while IFS= read -r label; do
    [ -z "$label" ] && continue
    label=$(echo "$label" | tr '[:upper:]' '[:lower:]')
    case "$label" in
      bug|defect) echo bug; return ;;
      documentation|docs) echo docs; return ;;
      enhancement|feature|new-feature) echo feat; return ;;
      performance|perf) echo perf; return ;;
      chore|tech-debt|spike) echo chore; return ;;
      test) echo test; return ;;
      refactor) echo refactor; return ;;
    esac
  done < <(echo "$labels_json" | jq -r '.[]? | if type == "string" then . else .name // empty end')
  echo feat
}

normalize_issue_list() {
  local raw_json="$1"
  echo "$raw_json" | jq '[.[]? | {
    number: (.number // .iid),
    title: (.title // ""),
    body: (.body // .description // ""),
    labels: (.labels // []),
    url: (.url // .web_url // ""),
    created_at: (.createdAt // .created_at // "")
  }]'
}

fetch_issue_by_number() {
  local repo="$1" number="$2"
  case "$platform" in
    github)
      gh issue view "$number" --repo "$repo" --json number,title,body,labels,url,createdAt
      ;;
    gitlab)
      glab issue view "$number" --repo "$repo" --output json
      ;;
  esac
}

cmd_issues_list() {
  require_cmd jq
  require_vcs_cli
  local url="${1:-$(config_read issue_list_url)}"
  local limit="${2:-$(config_read issue_limit)}"
  [ -z "$limit" ] || [ "$limit" = "null" ] && limit="3"
  [ -z "$url" ] && { err "issues list requires <url> or issue_list_url in config"; exit 1; }

  parse_issue_list_url "$url" || exit 1

  local raw_json
  case "$ISSUE_LIST_PLATFORM" in
    github)
      local search="$ISSUE_LIST_QUERY"
      if [ -z "$search" ]; then
        search="is:issue is:open"
      fi
      if ! echo "$search" | grep -q 'sort:'; then
        search="${search} sort:created-asc"
      fi
      raw_json=$(gh issue list --repo "$ISSUE_LIST_REPO" --state open --limit "$limit" \
        --search "$search" --json number,title,body,labels,url,createdAt)
      ;;
    gitlab)
      local glab_cmd=(glab issue list --repo "$ISSUE_LIST_REPO" --opened --per-page "$limit" --sort created --order asc --output json)
      if [ -n "$ISSUE_LIST_QUERY" ]; then
        glab_cmd+=(--label "$ISSUE_LIST_QUERY")
      fi
      raw_json=$("${glab_cmd[@]}")
      ;;
  esac

  normalize_issue_list "$raw_json"
}

cmd_issues_queue() {
  require_cmd jq
  [ ! -f "$STATE_FILE" ] && { echo "[]"; return; }
  state_ensure_array
  local run_id="${GOAL_RUN_ID:-}"
  if [ -z "$run_id" ]; then
    run_id=$(jq -r '[.[] | select(.run_id != null) | .run_id] | last // empty' "$STATE_FILE")
  fi
  if [ -z "$run_id" ]; then
    echo "[]"
    return
  fi
  jq --arg rid "$run_id" '[.[] | select(.run_id == $rid)]'
}

cmd_issues_start() {
  require_cmd git jq
  require_vcs_cli
  local number="${1:-}"
  local use_worktree=false
  shift || true
  while [ $# -gt 0 ]; do
    [ "$1" = "--worktree" ] && use_worktree=true
    shift
  done
  [ -z "$number" ] && { err "issues start requires <number>"; exit 1; }

  local url repo run_id batch wt_rel wt_path base branch goal title labels_json task_type
  url="$(config_read issue_list_url)"
  [ -z "$url" ] && { err "issue_list_url not configured — run /init-goal"; exit 1; }
  parse_issue_list_url "$url" || exit 1
  repo="$ISSUE_LIST_REPO"

  local issue_json
  issue_json="$(fetch_issue_by_number "$repo" "$number")"
  title=$(echo "$issue_json" | jq -r '.title // ""')
  goal="${title}"
  local body
  body=$(echo "$issue_json" | jq -r '.body // .description // ""')
  if [ -n "$body" ]; then
    goal="${title}

${body}"
  fi
  labels_json=$(echo "$issue_json" | jq -c '.labels // []')
  task_type="$(task_type_from_issue_labels "$labels_json")"
  branch="${task_type}/${number}-$(slugify "$title")"
  base=$(detect_base)
  run_id="${GOAL_RUN_ID:-$(generate_run_id)}"
  batch="${GOAL_ISSUE_BATCH:-0}"

  state_ensure_array

  local repos_json="[]"
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    local rd
    rd=$(repo_dir "$r")
    log "Preparing issue #$number branch in: $r"
    (cd "$rd" && git fetch origin "$base" 2>/dev/null || true)
    repos_json=$(echo "$repos_json" | jq --arg path "$r" '. + [{"path": $path, "pr_number": null, "pr_url": ""}]')
  done < <(get_repos)

  wt_rel=""
  wt_path=""
  if [ "$use_worktree" = true ]; then
    wt_rel="$(issue_worktree_rel "$number")"
    wt_path="$PROJECT_ROOT/$wt_rel"
    mkdir -p "$WORKTREES_DIR"
    [ -d "$wt_path" ] && { err "Issue worktree already exists: $wt_path"; exit 1; }
    local rd
    rd=$(repo_dir ".")
    (cd "$rd" && git worktree add -b "$branch" "$wt_path" "origin/$base")
    sync_worktree_config "$wt_path"
    log "Issue worktree: $wt_rel (branch: $branch)"
  else
    while IFS= read -r r; do
      [ -z "$r" ] && continue
      local rd
      rd=$(repo_dir "$r")
      (cd "$rd" && git checkout -b "$branch" "origin/$base" 2>/dev/null || git checkout "$branch" 2>/dev/null || true)
    done < <(get_repos)
  fi

  local issue_url
  issue_url=$(echo "$issue_json" | jq -r '.url // .web_url // ""')
  local new_goal
  local repo_count
  repo_count=$(echo "$repos_json" | jq 'length')

  new_goal=$(jq -n \
    --arg goal "$goal" \
    --arg branch "$branch" \
    --arg base "$base" \
    --arg run_id "$run_id" \
    --argjson batch "$batch" \
    --arg wt "$wt_rel" \
    --argjson issue_num "$number" \
    --arg issue_url "$issue_url" \
    --arg issue_title "$title" \
    --argjson repos "$repos_json" \
    '{
      goal: $goal,
      branch: $branch,
      base_branch: $base,
      pr_number: null,
      pr_url: "",
      status: "in_progress",
      run_id: $run_id,
      batch: $batch,
      worktree: (if ($wt | length) > 0 then $wt else null end),
      issue: {number: $issue_num, url: $issue_url, title: $issue_title},
      repos: $repos
    }')

  if [ -f "$STATE_FILE" ]; then
    jq --argjson entry "$new_goal" '. + [$entry]' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  else
    echo "[$new_goal]" > "$STATE_FILE"
  fi

  GOAL_ISSUE="$number"
  refresh_goal_idx
  log "Issue #$number started on branch $branch (run_id=$run_id)"
  if [ -n "$wt_rel" ]; then
    echo "$wt_rel"
  fi
}

cmd_issues_finish() {
  require_cmd git jq
  local number="${1:-}"
  [ -z "$number" ] && { err "issues finish requires <number>"; exit 1; }

  GOAL_ISSUE="$number"
  refresh_goal_idx

  local wt_rel wt_path
  wt_rel=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].worktree // ""' "$STATE_FILE")
  if [ -n "$wt_rel" ] && [ "$wt_rel" != "null" ]; then
    wt_path="$PROJECT_ROOT/$wt_rel"
    if [ -d "$wt_path" ]; then
      git worktree remove "$wt_path" --force 2>/dev/null || git worktree remove "$wt_path" 2>/dev/null || true
      log "Removed issue worktree: $wt_rel"
    fi
    jq --argjson idx "$GOAL_IDX" 'del(.[$idx].worktree)' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  fi

  jq --argjson idx "$GOAL_IDX" '.[$idx].status = "completed"' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  log "Issue #$number marked completed"
}

# --- Local review findings (.goal-review/) ---

review_file_key() {
  local repo_path="${1:-}"
  local branch
  branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch' "$STATE_FILE")
  local key
  key="$(slugify "$branch")"
  if [ -n "$repo_path" ] && [ "$repo_path" != "." ]; then
    key="${key}__$(slugify "$repo_path")"
  fi
  echo "$key"
}

review_file_path() {
  echo "$REVIEW_DIR/$(review_file_key "$1").json"
}

review_require_file() {
  local repo_path="${1:-}"
  local rf
  rf="$(review_file_path "$repo_path")"
  [ -f "$rf" ] || { err "No local review file — run 'goal-git.sh review init' first"; exit 1; }
  echo "$rf"
}

cmd_review_init() {
  require_cmd jq
  require_active_goal
  refresh_goal_idx
  local repo_path="${1:-}"
  local branch max_iter rf
  branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch' "$STATE_FILE")
  max_iter="$(config_read review_max_iterations)"
  [ -z "$max_iter" ] || [ "$max_iter" = "null" ] && max_iter="5"
  mkdir -p "$REVIEW_DIR"
  rf="$(review_file_path "$repo_path")"
  jq -n \
    --arg branch "$branch" \
    --argjson max_iterations "$max_iter" \
    '{
      branch: $branch,
      iterations: 0,
      max_iterations: $max_iterations,
      findings: []
    }' > "$rf"
  log "Local review initialized: $rf"
}

cmd_review_add() {
  require_cmd jq
  local path="${1:-}" line="${2:-}" severity="${3:-}" body="${4:-}" repo_path="${5:-}"
  [ -z "$path" ] || [ -z "$line" ] || [ -z "$severity" ] || [ -z "$body" ] && {
    err "review add requires: <path> <line> <severity> <body> [repo_path]"
    exit 1
  }
  refresh_goal_idx
  local rf new_id
  rf="$(review_require_file "$repo_path")"
  new_id=$(jq -r '.findings | length + 1 | "f\(.)"' "$rf")
  jq \
    --arg id "$new_id" \
    --arg path "$path" \
    --argjson line "$line" \
    --arg severity "$severity" \
    --arg body "$body" \
    '.findings += [{
      id: $id,
      path: $path,
      line: $line,
      severity: $severity,
      body: $body,
      resolved: false
    }]' \
    "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"
  log "Added finding $new_id on $path:$line"
}

cmd_review_list() {
  require_cmd jq
  refresh_goal_idx
  local repo_path="${1:-}"
  local rf
  rf="$(review_require_file "$repo_path")"
  jq '.findings' "$rf"
}

cmd_review_resolve() {
  require_cmd jq
  local id="${1:-}" repo_path="${2:-}"
  [ -z "$id" ] && { err "review resolve requires <id> [repo_path]"; exit 1; }
  refresh_goal_idx
  local rf found
  rf="$(review_require_file "$repo_path")"
  found=$(jq --arg id "$id" '[.findings[]? | select(.id == $id)] | length' "$rf")
  if [ "${found:-0}" -eq 0 ]; then
    err "Finding not found: $id"
    exit 1
  fi
  jq --arg id "$id" \
    '.findings = [.findings[] | if .id == $id then . + {resolved: true} else . end]' \
    "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"
  log "Resolved finding: $id"
}

cmd_review_pending() {
  require_cmd jq
  refresh_goal_idx
  local repo_path="${1:-}"
  local rf total unresolved
  rf="$(review_require_file "$repo_path")"
  total=$(jq '.findings | length' "$rf")
  unresolved=$(jq '[.findings[] | select(.resolved == false)] | length' "$rf")

  echo "{\"total\": ${total:-0}, \"unresolved\": ${unresolved:-0}}"

  if [ "${unresolved:-0}" -gt 0 ]; then
    warn "$unresolved unresolved finding(s) remain — loop continues"
    exit 1
  fi

  log "No unresolved findings — local review is clean"
  exit 0
}

cmd_review_iterate() {
  require_cmd jq
  refresh_goal_idx
  local repo_path="${1:-}"
  local rf iterations max_iter
  rf="$(review_require_file "$repo_path")"
  iterations=$(jq -r '.iterations // 0' "$rf")
  max_iter=$(jq -r '.max_iterations // 5' "$rf")
  iterations=$((iterations + 1))
  jq --argjson n "$iterations" '.iterations = $n' "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"
  log "Review iteration $iterations / $max_iter"
  if [ "$iterations" -gt "$max_iter" ]; then
    err "Review iteration cap exceeded ($max_iter)"
    exit 1
  fi
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
    log "Goals in state.json: $(jq 'length' "$STATE_FILE") ($(jq -r --argjson idx "$GOAL_IDX" '.[$idx].status' "$STATE_FILE"))"
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
  start)    cmd_start "${2:-}" "${3:-}" "${4:-}" ;;
  continue) cmd_continue "${2:-}" ;;
  list)     cmd_list ;;
  stage)    shift; cmd_stage "$@" ;;
  commit)   cmd_commit "${2:-}" ;;
  push)     cmd_push ;;
  pr)       cmd_pr ;;
  pending)  cmd_pending "${2:-}" ;;
  threads)  cmd_threads "${2:-}" ;;
  comment)  cmd_comment "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
  resolve)  cmd_resolve "${2:-}" "${3:-}" ;;
  analyze)  cmd_analyze ;;
  config)
    case "${2:-}" in
      set) cmd_config_set "${3:-}" "${4:-}" "${5:-}" "${6:-1}" "${7:-false}" "${8:-inline}" "${9:-5}" ;;
      get) cmd_config_get ;;
      *)   err "config subcommand must be 'set' or 'get'"; exit 1 ;;
    esac
    ;;
  state)
    case "${2:-}" in
      complete) cmd_state_complete ;;
      *) cmd_state ;;
    esac
    ;;
  merge)    cmd_merge ;;
  status)   cmd_status ;;
  restore)  shift; cmd_restore "$@" ;;
  diff)     cmd_diff "${2:-}" ;;
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
  issues)
    case "${2:-}" in
      list)   cmd_issues_list "${3:-}" "${4:-}" ;;
      start)  cmd_issues_start "${3:-}" "${4:-}" "${5:-}" ;;
      queue)  cmd_issues_queue ;;
      finish) cmd_issues_finish "${3:-}" ;;
      *)      err "issues subcommand must be list, start, queue, or finish"; exit 1 ;;
    esac
    ;;
  review)
    case "${2:-}" in
      init)    cmd_review_init "${3:-}" ;;
      add)     cmd_review_add "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" ;;
      list)    cmd_review_list "${3:-}" ;;
      resolve) cmd_review_resolve "${3:-}" "${4:-}" ;;
      pending) cmd_review_pending "${3:-}" ;;
      iterate) cmd_review_iterate "${3:-}" ;;
      *)       err "review subcommand must be init, add, list, resolve, pending, or iterate"; exit 1 ;;
    esac
    ;;
  figma)
    case "${2:-}" in
      setup)  cmd_figma_setup "${3:-}" ;;
      disable) cmd_figma_disable ;;
      status) cmd_figma_status ;;
      design)
        case "${3:-}" in
          set) cmd_figma_design_set "${4:-}" ;;
          *) err "figma design subcommand must be 'set'"; exit 1 ;;
        esac
        ;;
      *) err "figma subcommand must be setup, design set, disable, or status"; exit 1 ;;
    esac
    ;;
  *)        usage ;;
esac
