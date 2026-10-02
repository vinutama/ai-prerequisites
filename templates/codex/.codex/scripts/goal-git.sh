#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"
PROJECT_ROOT="$RUNTIME_ROOT"
if [ -f "$RUNTIME_ROOT/.codex/workflow-root" ]; then
  IFS= read -r PROJECT_ROOT < "$RUNTIME_ROOT/.codex/workflow-root"
  [ -d "$PROJECT_ROOT/.codex/scripts" ] || { printf '%s\n' 'Shared workflow root is missing' >&2; exit 1; }
  PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
fi
STATE_FILE="$PROJECT_ROOT/state.json"
STATE_LOCK_DIR="$PROJECT_ROOT/.codex/.state.lock"
PROGRESS_LOG="$PROJECT_ROOT/.codex/goal-progress.log"
CONFIG_FILE="$PROJECT_ROOT/.codex/goal-config.json"
FIGMA_ENV_FILE="$PROJECT_ROOT/.codex/figma.env"
MCP_JSON="$PROJECT_ROOT/.codex/mcp.json"
WORKTREES_DIR="$PROJECT_ROOT/.worktrees"
REVIEW_DIR="$PROJECT_ROOT/.goal-review"
AGENT_CONFIG_DIR=".codex"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[goal]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[goal]${NC} $*" >&2; }
err()  { echo -e "${RED}[goal]${NC} $*" >&2; }

usage() {
  cat <<EOF
Usage: goal-git.sh <command> [args]

Commands:
  start <goal> [ticket] [task_type] [--source-file JSON]  Create branch (jira: task_type/TICKET-slug)
  continue [id]             Continue active goal (or switch to goal by branch/text)
  list                      List all goals with status and active marker
  stage <file>...           Stage specific files for commit
  commit [msg]              Commit staged changes (conventional commit)
  push                      Push branch to origin
  pr [--title t] --body-file f  Create or update the PR (GitHub) / MR (GitLab)
  pending                   Check for unresolved review threads (exit 0 = clean)
  threads                   List review threads as JSON
  comment <path> <line> <body>  Post inline review comment
  resolve <thread-id>       Resolve a review thread/discussion
  analyze                   Run gitnexus analyze && rtk gain
  verify detect             Detect project verification commands (JSON)
  verify run [--only a,b]   Run deterministic verification checks
  route detect              Classify route: backend|feature|frontend
  harness init [--route r] [--qa true|false] [--visual true|false]
                            Seed harness object on active goal (qa/visual default from route)
  harness phase <STATE>     Transition harness phase (validated)
  harness task add <role> <title> [--parent tN]
  harness task set <id> <state>
                            state: PENDING|SPAWNING|RUNNING|DONE|BLOCKED|FAILED
  harness gate <NAME> <STATUS> [reason]
                            Evidence-backed PASS for IMPLEMENTATION/VERIFICATION/REVIEW/QA/VISUAL
  harness retry <counter>   Increment retry counter (exit 1 if limit exceeded)
  harness qa add <scenario> <PASS|FAIL> <note>
  harness qa pending        Exit 1 if any scenario's latest result is an unresolved FAIL
  harness qa resolve <id>
                            Mark a historical QA FAIL superseded (keeps the audit row)
  harness visual add <viewport> <PASS|FAIL> <note>
  harness visual pending    Exit 1 if any viewport's latest observation is an unresolved FAIL
  harness visual resolve <id>
                            Mark a historical visual FAIL superseded (keeps the audit row)
  harness event <agent> <event> [detail]
                            Append typed milestone to harness.events (best-effort)
  harness progress [-n N] [--json]
                            Render recent harness timeline (default last 20)
  harness hook              Read Codex hook JSON on stdin; emit START/END event
  harness spawn <role> <model> <effort> [--task tN]
                            Reserve a launch; returns reservation JSON
  harness spawn-confirm <reservation> <agent-id>
  harness spawn-fail <reservation> <category> <reason>
  harness spawn-finish <agent-id> completed|failed [--closed]
  harness budget set <key> <n>
                            Raise a live spawn cap (e.g. max_reviewer_runs) without re-init
  harness metrics           Print spawn/run metrics
  harness context put <name> [file|-]
                            Store compact handoff artifact (discovery_context, …)
  harness context get <name>
                            Print stored handoff artifact
  harness status            Print harness object
  harness done              Exit 0 only when required gates PASS (from requirements)
  harness recover-spawn     Unstick FAILED/SPAWNING/BLOCKED after spawn_agent was withheld
  codex ensure-user-config  Trust this project in ~/.codex/config.toml
  groups persist            Save active group harness/PR overlay back into delivery_groups
  groups list               List delivery groups on the active Markdown goal
  groups init [file|-]      Persist planner delivery_groups JSON (stdin or file)
  groups validate [file|-]  Validate delivery_groups JSON without writing state
  groups status [group-id]  Show one group or all groups
  groups activate <group-id>
                            Overlay group branch/worktree/harness onto the root goal
  groups start <group-id>   Create typed branch + isolated worktree; activate group
  groups continue <group-id>
                            Resume an existing group (idempotent)
  groups ready              Print groups whose dependencies are merged
  groups pr <group-id>      Create/reuse this group's PR/MR
  groups merge <group-id>   Merge the group PR and remove its worktree
  groups complete <group-id>
                            Mark a group completed without merge
  groups cancel <group-id>  Cancel a group and remove its worktree
  context                   Resolve checkout, shared state, and immutable assignment (JSON)
  doctor --json             Show local CLI versions, capabilities, auth, and role errors
  help                      Show commands without requiring setup
  selfcheck                 Run platform detection self-check
  models                    Print full goal-models.json
  models <role>             Print model, effort, and fallbacks for a role (TAB-separated)
  models <role> --next <m>  Print next fallback after model <m> (exit 1 if exhausted)
  models <role> --complexity <LEVEL>
                            Resolve model/effort from \$routing for TRIVIAL|NORMAL|COMPLEX|ARCHITECTURAL
  models <role> --require-multimodal [m]
                            Resolve a vision-capable model for multimodal roles
  complexity classify <text> [--files a,b]
                            Cheap heuristic complexity classification (JSON)
  config set <source> <target> <platform> [concurrency] [auto_merge] [review_mode] [review_max_iterations] [max_rework] [max_escalations] [max_verify_retries] [qa_mode] [visual_mode]
  config get                Print goal-config.json
  state                     Print active goal JSON from state.json
  state complete            Mark active goal status as completed
  merge                     Merge active PR/MR into target branch (after clean review)
  status                    Show working tree status
  restore <file>...         Restore files to HEAD
  diff                      Show diff against base branch for active goal
  worktree add <task-slug>  Create isolated git worktree for parallel task
  worktree list             List active task worktrees
  worktree sync [path]      Refresh managed runtime, skills and instructions into one or all linked worktrees
  worktree merge <task-slug>  Merge worktree branch into goal branch
  worktree remove <task-slug> Remove worktree without merging
  figma setup <token>       Store Figma PAT and enable figma MCP in .codex/mcp.json
  figma design set <url>    Set default Figma design link in goal-config.json
  figma disable             Disable Figma integration
  figma status              Show Figma integration status
  issues list [url] [limit]     List open issues from GitHub/GitLab issue list URL
  issues start <number> [--worktree] [--url URL]  Start goal for issue (branch off base)
  issues queue                  Print current issue run queue from state
  issues finish <number>        Mark issue goal complete and remove worktree
  review init [repo_path]       Initialize local review findings file
  review add <path> <line> <severity> <body> [repo_path]  Add local finding
  review list [repo_path]       List local findings as JSON
  review resolve <id> [repo_path]  Mark local finding resolved
  review pending [repo_path]    Check unresolved local findings (exit 0 = clean)
  review iterate [repo_path]      Increment review iteration counter (no cap; loop until clean)
EOF
  return 0
}

require_cmd() {
  local dependency
  for dependency in "$@"; do
    command -v "$dependency" >/dev/null 2>&1 || { err "Missing required command: $dependency"; return 1; }
  done
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


is_multi_repo() {
  local repos
  repos=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].repos // [] | length' "$STATE_FILE" 2>/dev/null || echo "0")
  [ "$repos" -gt 1 ] && return 0 || return 1
}

get_state_pr_number() {
  local repo_path="${1:-${GOAL_REPO:-.}}"
  if [ -z "$repo_path" ] || [ "$repo_path" = "." ]; then
    jq -r --argjson idx "$GOAL_IDX" '.[$idx].pr_number // null' "$STATE_FILE"
  else
    jq -r --argjson idx "$GOAL_IDX" --arg r "$repo_path" '.[$idx].repos[]? | select(.path == $r) | .pr_number' "$STATE_FILE"
  fi
}

get_state_pr_url() {
  local repo_path="${1:-${GOAL_REPO:-.}}"
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
  *)
    case "${1:-}" in
      help|--help|-h|doctor|models|config|context|selfcheck|codex|complexity|issues) ;;
      *) err "Cannot detect platform. Run '/init-goal' or set GOAL_PLATFORM=github|gitlab"; exit 1 ;;
    esac
    ;;
esac

require_vcs_cli() {
  case "$platform" in
    github) require_cmd gh ;;
    gitlab) require_cmd glab ;;
  esac
}

# --- Goal index (GOAL_ISSUE selects entry; default -1 = active goal) ---




# --- State Helpers ---

state_lock_acquire() {
  local max_attempts="${1:-100}"
  local stale_secs="${2:-30}"
  local attempt=0
  local lock_mtime now lock_age lock_pid
  mkdir -p "$(dirname "$STATE_LOCK_DIR")"
  while ! mkdir "$STATE_LOCK_DIR" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ -d "$STATE_LOCK_DIR" ]; then
      lock_mtime="$(stat -f %m "$STATE_LOCK_DIR" 2>/dev/null || true)"
      if [ -z "$lock_mtime" ]; then
        lock_mtime="$(stat -c %Y "$STATE_LOCK_DIR" 2>/dev/null || true)"
      fi
      now="$(date +%s)"
      if [ -n "$lock_mtime" ] && [ "$lock_mtime" -gt 0 ] 2>/dev/null; then
        lock_age=$((now - lock_mtime))
      else
        lock_age=0
      fi
      lock_pid="$(cat "$STATE_LOCK_DIR/pid" 2>/dev/null || true)"
      # Break only when lock is old AND holder is gone (or pid unknown)
      if [ "$lock_age" -ge "$stale_secs" ]; then
        if [ -z "$lock_pid" ] || ! kill -0 "$lock_pid" 2>/dev/null; then
          warn "Breaking stale state lock (age=${lock_age}s pid=${lock_pid:-none})"
          rm -rf "$STATE_LOCK_DIR"
          continue
        fi
      fi
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      err "Could not acquire state lock after $max_attempts attempts"
      return 1
    fi
    sleep 0.05
  done
  printf '%s\n' "$$" > "$STATE_LOCK_DIR/pid" 2>/dev/null || true
  return 0
}

state_lock_release() {
  rm -rf "$STATE_LOCK_DIR"
}

# Run jq write under lock: state_mutate [jq args...]  (STATE_FILE is the input)


GOAL_IDX="-1"

state_active() {
  state_ensure_array
  jq -r --argjson idx "$GOAL_IDX" '.[$idx]' "$STATE_FILE"
}

state_update() {
  local field="$1" value="$2"
  state_mutate --argjson idx "$GOAL_IDX" --arg v "$value" ".[\$idx].$field = \$v"
}

require_active_goal() {
  require_cmd jq
  [ ! -f "$STATE_FILE" ] && { err "No state found — run 'start' first"; exit 1; }
  state_ensure_array
  jq -e --argjson idx "$GOAL_IDX" 'type == "array" and (.[$idx] | type) == "object"' "$STATE_FILE" >/dev/null || { goal_error assignment "No active goal exists"; return 1; }
}

pr_number_active() {
  require_active_goal
  local repo_path="${1:-${GOAL_REPO:-.}}"
  local pr_number

  if [ -n "$repo_path" ] && { [ "$repo_path" != . ] || [ "$(jq -r --argjson idx "$GOAL_IDX" '(.[$idx].repos // []) | length' "$STATE_FILE")" -gt 0 ]; }; then
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

  [[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || { goal_error delivery "Recorded PR/MR number is invalid"; return 1; }
  echo "$pr_number"
}

github_owner_repo() {
  forge_target "${1:-$PROJECT_ROOT}" || return
  printf '%s %s\n' "${FORGE_TARGET_PATH%%/*}" "${FORGE_TARGET_PATH#*/}"
}

gitlab_project_path() {
  forge_target "${1:-$PROJECT_ROOT}" || return
  printf '%s %s\n' "$FORGE_TARGET_PATH" "$FORGE_TARGET_ENCODED"
}

# --- Commands ---

detect_base() {
  local configured base
  configured=$(config_read target_branch)
  if [ -n "$configured" ]; then printf '%s\n' "$configured"; return; fi
  base=$(git -C "$PROJECT_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD) || {
    goal_error configuration "Set target_branch explicitly; origin/HEAD is unavailable"; return 1;
  }
  printf '%s\n' "${base#origin/}"
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


cmd_worktree_sync() {
  if [ -n "${1:-}" ]; then
    sync_worktree_config "$1"
    return
  fi
  require_cmd git
  local line wt_path
  while IFS= read -r line; do
    case "$line" in
      'worktree '*)
        wt_path="${line#worktree }"
        [ "$wt_path" = "$PROJECT_ROOT" ] && continue
        sync_worktree_config "$wt_path" || return
        ;;
    esac
  done < <(git worktree list --porcelain)
}

cmd_start() {
  require_cmd git jq
  local goal="${1:-}" ticket="${2:-}" task_type="${3:-}"
  [ -z "$goal" ] && { err "start requires a goal description"; exit 1; }

  local source_file="" positional=0
  shift || true
  ticket=""; task_type=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --source-file) [ $# -ge 2 ] || return 1; source_file="$2"; shift 2 ;;
      --*) goal_error usage "Unknown start argument: $1"; return 1 ;;
      *)
        case "$positional" in
          0) ticket="$1" ;;
          1) task_type="$1" ;;
          *) goal_error usage "Too many start arguments"; return 1 ;;
        esac
        positional=$((positional + 1)); shift ;;
    esac
  done
  state_ensure_array

  if [ -f "$STATE_FILE" ]; then
    local old_status
    old_status=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].status // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
    if [ "${GOAL_SUPPRESS_IN_PROGRESS_WARN:-}" != "1" ] && [ "$old_status" = "in_progress" ]; then
      warn "A goal is already in progress. Starting a new goal will append to history. Use 'continue' to extend the existing goal instead."
    fi
  fi

  local base branch goal_source ticket_key type_slug delivery_mode strategy
  base=$(detect_base)
  goal_source="${GOAL_SOURCE_OVERRIDE:-$(config_read goal_source)}"
  strategy="$(markdown_pr_strategy_effective)"
  delivery_mode="single"

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
  elif [ "$goal_source" = "markdown" ] && { [ "$strategy" = "auto" ] || [ "$strategy" = "task" ]; }; then
    delivery_mode="multi-pr"
    branch=""
  else
    branch="goal/$(slugify "$goal")"
  fi

  log "Platform: $platform"
  log "Base: $base"
  if [ "$delivery_mode" = "multi-pr" ]; then
    log "Markdown multi-PR: no aggregation branch (strategy=$strategy)"
  else
    log "Branch: $branch"
  fi

  goal_source="${goal_source:-prompt}"
  local snapshot reference=""
  case "$goal_source" in
    markdown) reference="$(config_read goal_file)"; [ -n "$reference" ] || reference="$(config_read markdown_file)" ;;
    jira) reference="$ticket_key" ;;
    prompting|prompt) goal_source=prompt ;;
    *) goal_error source "Unsupported start source: $goal_source"; return 1 ;;
  esac
  snapshot=$(source_snapshot "$goal_source" "$goal" "$goal" "$reference" "$source_file") || return
  local repos_json="[]"
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    local rd
    rd="$PROJECT_ROOT"; [ "$repo" = . ] || rd="$PROJECT_ROOT/$repo"
    log "Preparing repo: $repo"
    delivery_clean "$rd" || return
    git -C "$rd" fetch origin "refs/heads/$base:refs/remotes/origin/$base" >&2 || return
    if [ "$delivery_mode" != "multi-pr" ]; then
      git -C "$rd" checkout -b "$branch" "origin/$base" >&2 || return
      context_assert_branch "$rd" "$branch" || return
    fi
    repos_json=$(echo "$repos_json" | jq --arg path "$repo" '. + [{"path": $path, "pr_number": null, "pr_url": ""}]')
  done < <(get_repos)

  local user_task_type=""
  if [ -n "$task_type" ] && [ "$goal_source" = "markdown" ]; then
    user_task_type="$(canonical_delivery_task_type "$task_type")" || exit 1
  fi

  local new_goal
  local repo_count
  repo_count=$(echo "$repos_json" | jq 'length')

  new_goal=$(jq -n \
    --arg id "goal-$(python3 -c 'import uuid; print(uuid.uuid4())')" \
    --argjson snapshot "$snapshot" \
    --arg goal "$goal" \
    --arg branch "$branch" \
    --arg base "$base" \
    --arg source "$goal_source" \
    --arg platform "$platform" \
    --arg mode "$delivery_mode" \
    --arg strategy "$strategy" \
    --arg user_tt "$user_task_type" \
    --argjson repos "$repos_json" \
    '{
      id: $id, platform:$platform, source: $snapshot, goal: $goal,
      branch: $branch,
      base_branch: $base,
      pr_number: null,
      pr_url: "",
      status: "in_progress",
      goal_source: $source,
      delivery_mode: $mode,
      markdown_pr_strategy: $strategy,
      user_task_type: (if $user_tt == "" then null else $user_tt end),
      delivery_groups: [],
      active_group_id: null,
      repos: $repos
    }')

  state_append_goal "$new_goal" || return
  log "Goal #$(jq 'length' "$STATE_FILE") started ($repo_count repos, delivery_mode=$delivery_mode)"
}

cmd_commit() {
  require_active_goal; refresh_goal_idx
  local msg="${1:-chore: automated changes}" wd
  wd=$(repo_dir "${GOAL_REPO:-.}") || return
  context_assert_branch "$wd" || return
  git -C "$wd" diff --cached --quiet && { goal_error empty_commit "Nothing staged; use stage <files>"; return 1; }
  git -C "$wd" commit -m "$msg" >&2 || return
  harness_invalidate "implementation commit changed"
  log "Committed: $msg"
}

cmd_push() {
  require_active_goal; refresh_goal_idx
  local wd branch sha remote_sha
  wd=$(repo_dir "${GOAL_REPO:-.}") || return
  context_assert_branch "$wd" || return
  delivery_clean "$wd" || return
  branch=$(git -C "$wd" branch --show-current); sha=$(git -C "$wd" rev-parse HEAD)
  git -C "$wd" push -u origin "HEAD:refs/heads/$branch" >&2 || return
  remote_sha=$(git -C "$wd" ls-remote --heads origin "refs/heads/$branch" | awk '{print $1}')
  [ "$remote_sha" = "$sha" ] || { goal_error unpublished "Remote branch SHA differs after push"; return 1; }
  log "Pushed: $branch from $wd"
}



fetch_threads_json() {
  local pr_number="$1" repo_path="${2:-.}" wd repo
  wd=$(repo_dir "${repo_path:-.}") || return
  repo=$(delivery_repo "$wd") || return
  delivery_current_pr "$wd" "$pr_number" >/dev/null || return
  forge_threads "$platform" "$repo" "$pr_number"
}

cmd_threads() {
  local repo_path="${1:-${GOAL_REPO:-.}}"
  local pr_number
  pr_number="$(pr_number_active "$repo_path")"
  fetch_threads_json "$pr_number" "$repo_path"
}

cmd_pending() {
  require_cmd jq
  local repo_path="${1:-${GOAL_REPO:-.}}"
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
  local path="${1:-}" line="${2:-}" body="${3:-}" repo_path="${4:-${GOAL_REPO:-.}}" wd pn payload result meta branch base
  [ -n "$path" ] && [[ "$line" =~ ^[1-9][0-9]*$ ]] && [ -n "$body" ] || { goal_error usage "comment requires path, positive line, body"; return 1; }
  wd=$(repo_dir "${repo_path:-.}") || return
  forge_target "$wd" || return
  pn=$(pr_number_active "$repo_path") || return
  delivery_current_pr "$wd" "$pn" >/dev/null || return
  branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch' "$STATE_FILE")
  base=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].base_branch' "$STATE_FILE")
  payload=$(mktemp)
  if [ "$platform" = github ]; then
    meta=$(forge_pr_metadata "$platform" "$FORGE_TARGET_REPO" "$branch" "$base") || { rm -f "$payload"; return 1; }
    jq -n --arg body "$body" --arg path "$path" --arg sha "$(printf '%s' "$meta" | jq -r .sha)" --argjson line "$line" \
      '{body:$body,path:$path,commit_id:$sha,line:$line,side:"RIGHT"}' > "$payload"
    forge_run write gh api "$FORGE_API_PATH/pulls/$pn/comments" --hostname "$FORGE_API_HOST" --method POST --input "$payload" || { rm -f "$payload"; return 1; }
  else
    meta=$(forge_run read glab api "$FORGE_API_PATH/merge_requests/$pn/versions" --hostname "$FORGE_API_HOST" --method GET) || { rm -f "$payload"; return 1; }
    printf '%s' "$meta" | jq -e '.[0] | .base_commit_sha != null and .head_commit_sha != null' >/dev/null || { rm -f "$payload"; return 1; }
    jq -n --arg body "$body" --arg path "$path" --argjson line "$line" --argjson version "$(printf '%s' "$meta" | jq '.[0]')" \
      '{body:$body,position:{position_type:"text",base_sha:$version.base_commit_sha,head_sha:$version.head_commit_sha,start_sha:($version.start_commit_sha // $version.base_commit_sha),new_path:$path,new_line:$line}}' > "$payload"
    forge_run write glab api "$FORGE_API_PATH/merge_requests/$pn/discussions" --hostname "$FORGE_API_HOST" --method POST --input "$payload" || { rm -f "$payload"; return 1; }
  fi
  rm -f "$payload"
}

cmd_resolve() {
  local id="${1:-}" repo_path="${2:-${GOAL_REPO:-.}}" wd pn payload data threads
  [ -n "$id" ] || return 1
  wd=$(repo_dir "${repo_path:-.}") || return
  forge_target "$wd" || return
  pn=$(pr_number_active "$repo_path") || return
  threads=$(fetch_threads_json "$pn" "$repo_path") || return
  printf '%s' "$threads" | jq -e --arg id "$id" 'any(.[]; .id == $id)' >/dev/null || {
    goal_error assignment "Review thread does not belong to this assignment"; return 1;
  }
  payload=$(mktemp)
  if [ "$platform" = github ]; then
    jq -n --arg id "$id" '{query:"mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}",variables:{id:$id}}' > "$payload"
    data=$(forge_run write gh api graphql --hostname "$FORGE_API_HOST" --method POST --input "$payload") || { rm -f "$payload"; return 1; }
    printf '%s' "$data" | jq -e '((.errors // []) | length) == 0 and .data.resolveReviewThread.thread.isResolved == true' >/dev/null || { rm -f "$payload"; return 1; }
  else
    printf '%s\n' '{"resolved":true}' > "$payload"
    forge_run write glab api "$FORGE_API_PATH/merge_requests/$pn/discussions/$id" --hostname "$FORGE_API_HOST" --method PUT --input "$payload" >/dev/null || { rm -f "$payload"; return 1; }
    data=$(forge_threads "$platform" "$FORGE_TARGET_REPO" "$pn") || { rm -f "$payload"; return 1; }
    printf '%s' "$data" | jq -e --arg id "$id" 'any(.[]; .id == $id and .resolved == true)' >/dev/null || { rm -f "$payload"; return 1; }
  fi
  rm -f "$payload"
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
    GOAL_ID=$(jq -r --argjson idx "$idx" '.[$idx].id' "$STATE_FILE")
    GOAL_ISSUE=""; GOAL_RUN_ID=""; GOAL_ISSUE_REPO=""
    refresh_goal_idx
    state_mutate --argjson idx "$idx" '.[:$idx] + .[($idx+1):] + [.[$idx]]'
    refresh_goal_idx
    branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch' "$STATE_FILE")
    log "Switched to goal on branch: $branch"
  fi

  state_mutate --argjson idx "$GOAL_IDX" '.[$idx].status = "in_progress"'

  local branch delivery_mode
  delivery_mode="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].delivery_mode // "single"' "$STATE_FILE")"
  branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch // empty' "$STATE_FILE")
  if [ "$delivery_mode" = "multi-pr" ]; then
    log "Continuing Markdown multi-PR goal (no aggregation checkout)"
    log "Goal: $(jq -r --argjson idx "$GOAL_IDX" '.[$idx].goal' "$STATE_FILE")"
    cmd_groups_list
    return 0
  fi
  if [ -n "$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].worktree // empty' "$STATE_FILE")" ]; then
    local wd
    wd="$(goal_workdir)"
    log "Continuing issue in its existing worktree: $wd"
    return 0
  fi
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    local rd
    rd=$(repo_dir "$repo")
    [ -z "$branch" ] || git -C "$rd" checkout "$branch" >&2 || return
    context_assert_branch "$rd" "$branch" || return
  done < <(get_repos)
  log "Continuing on branch: $branch"
  log "Goal: $(jq -r --argjson idx "$GOAL_IDX" '.[$idx].goal' "$STATE_FILE")"
}

cmd_stage() {
  require_active_goal; refresh_goal_idx
  [ $# -gt 0 ] || { goal_error usage "add requires file paths"; return 1; }
  local wd; wd=$(repo_dir "${GOAL_REPO:-.}") || return
  context_assert_branch "$wd" || return
  git -C "$wd" add -- "$@" >&2 || return
  harness_invalidate "working files changed"
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
  wd="$(repo_dir "${GOAL_REPO:-.}")"
  implementation_fingerprint >/dev/null || return
  cd "$wd" || { err "Cannot cd into goal workdir: $wd"; exit 1; }
  log "Running gitnexus analyze…"
  if ! npx --yes gitnexus@latest analyze; then
    if [ -f "$STATE_FILE" ] && jq -e --argjson idx "$GOAL_IDX" '.[$idx].harness' "$STATE_FILE" >/dev/null 2>&1; then
      cmd_harness_gate ANALYSIS FAIL "gitnexus analyze failed" || true
    fi
    err "gitnexus analyze failed"
    exit 1
  fi
  log "Running rtk gain…"
  if ! rtk gain; then
    if [ -f "$STATE_FILE" ] && jq -e --argjson idx "$GOAL_IDX" '.[$idx].harness' "$STATE_FILE" >/dev/null 2>&1; then
      cmd_harness_gate ANALYSIS FAIL "rtk gain failed" || true
    fi
    err "rtk gain failed"
    exit 1
  fi
  if [ -f "$STATE_FILE" ] && jq -e --argjson idx "$GOAL_IDX" '.[$idx].harness' "$STATE_FILE" >/dev/null 2>&1; then
    HARNESS_GATE_SOURCE=analyze cmd_harness_gate ANALYSIS PASS
  fi
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
  local config_toml="$PROJECT_ROOT/.codex/config.toml"
  local start="# >>> goal-loop figma >>>"
  local end="# <<< goal-loop figma <<<"
  mkdir -p "$(dirname "$config_toml")"
  if [ ! -f "$config_toml" ]; then
    cat > "$config_toml" <<'TOML'
[agents]
enabled = true
max_depth = 1
max_concurrent_threads_per_session = 8

[sandbox_workspace_write]
network_access = true
TOML
  fi

  local tmp_block
  tmp_block=$(mktemp)
  if [ "$enabled" = "true" ]; then
    cat > "$tmp_block" <<'TOML'
# >>> goal-loop figma >>>
[mcp_servers.figma]
command = "npx"
args = ["-y", "figma-developer-mcp", "--stdio"]

[mcp_servers.figma.env]
FIGMA_API_KEY = "${FIGMA_API_KEY}"
# <<< goal-loop figma <<<
TOML
  else
    cat > "$tmp_block" <<'TOML'
# >>> goal-loop figma >>>
# managed by goal-git.sh figma setup
# <<< goal-loop figma <<<
TOML
  fi

  if grep -qF "$start" "$config_toml"; then
    awk -v start="$start" -v end="$end" -v blockfile="$tmp_block" '
      BEGIN { skip=0 }
      $0 == start {
        while ((getline line < blockfile) > 0) print line
        close(blockfile)
        skip=1
        next
      }
      $0 == end { skip=0; next }
      skip==0 { print }
    ' "$config_toml" > "$config_toml.tmp" && mv "$config_toml.tmp" "$config_toml"
  else
    printf '
' >> "$config_toml"
    cat "$tmp_block" >> "$config_toml"
  fi
  rm -f "$tmp_block"
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
  log "Figma MCP enabled in $CODEX_TOML"
  warn "Load secrets before Codex: set -a && source .codex/figma.env && set +a && codex"
  warn "Or use: .codex/scripts/run-codex.sh"
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
  if [ -f "$CODEX_TOML" ] && grep -q '^\[mcp_servers.figma\]' "$CODEX_TOML"; then
    log "  .codex/config.toml [mcp_servers.figma]: configured"
  else
    warn "  .codex/config.toml [mcp_servers.figma]: not configured"
  fi
}

cmd_config_set() {
  require_cmd jq
  local source="${1:-}" target="${2:-}" plat="${3:-}" concurrency="${4:-1}" auto_merge="${5:-false}" review_mode="${6:-inline}" review_max_iterations="${7:-0}"
  local max_rework="${8:-3}" max_escalations="${9:-2}" max_verify_retries="${10:-3}" qa_mode="${11:-auto}" visual_mode="${12:-auto}"

  [ -z "$source" ] || [ -z "$target" ] || [ -z "$plat" ] && {
    err "config set requires: <goal_source> <target_branch> <platform> [concurrency] [auto_merge] [review_mode] [review_max_iterations] [max_rework] [max_escalations] [max_verify_retries] [qa_mode] [visual_mode]"
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

  if ! [[ "$review_max_iterations" =~ ^[0-9]+$ ]]; then
    err "review_max_iterations must be a non-negative integer (0 = unlimited, loop until pending is clean)"
    exit 1
  fi

  for pair in "max_rework:$max_rework" "max_escalations:$max_escalations" "max_verify_retries:$max_verify_retries"; do
    local k="${pair%%:*}" v="${pair#*:}"
    if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "$v" -lt 1 ]; then
      err "$k must be a positive integer"
      exit 1
    fi
  done

  case "$qa_mode" in
    auto|always|never) ;;
    *) err "qa_mode must be: auto, always, or never"; exit 1 ;;
  esac

  case "$visual_mode" in
    auto|always|never) ;;
    *) err "visual_mode must be: auto, always, or never"; exit 1 ;;
  esac

  local auto_merge_json
  auto_merge_json=$( [ "$auto_merge" = "true" ] && echo true || echo false )

  mkdir -p "$(dirname "$CONFIG_FILE")"
  if [ -f "$CONFIG_FILE" ]; then
    jq \
      --arg source "$source" \
      --arg target "$target" \
      --arg platform "$plat" \
      --arg review_mode "$review_mode" \
      --arg qa_mode "$qa_mode" \
      --arg visual_mode "$visual_mode" \
      --argjson concurrency "$concurrency" \
      --argjson auto_merge "$auto_merge_json" \
      --argjson review_max_iterations "$review_max_iterations" \
      --argjson max_rework "$max_rework" \
      --argjson max_escalations "$max_escalations" \
      --argjson max_verify_retries "$max_verify_retries" \
      '.goal_source = $source
       | .target_branch = $target
       | .platform = $platform
       | .concurrency = $concurrency
       | .auto_merge = $auto_merge
       | .review_mode = $review_mode
       | .review_max_iterations = $review_max_iterations
       | .max_rework = $max_rework
       | .max_escalations = $max_escalations
       | .max_verify_retries = $max_verify_retries
       | .qa_mode = $qa_mode
       | .visual_mode = $visual_mode' \
      "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  else
    jq -n \
      --arg source "$source" \
      --arg target "$target" \
      --arg platform "$plat" \
      --arg review_mode "$review_mode" \
      --arg qa_mode "$qa_mode" \
      --arg visual_mode "$visual_mode" \
      --argjson concurrency "$concurrency" \
      --argjson auto_merge "$auto_merge_json" \
      --argjson review_max_iterations "$review_max_iterations" \
      --argjson max_rework "$max_rework" \
      --argjson max_escalations "$max_escalations" \
      --argjson max_verify_retries "$max_verify_retries" \
      '{
        goal_source: $source,
        target_branch: $target,
        platform: $platform,
        concurrency: $concurrency,
        auto_merge: $auto_merge,
        review_mode: $review_mode,
        review_max_iterations: $review_max_iterations,
        max_rework: $max_rework,
        max_escalations: $max_escalations,
        max_verify_retries: $max_verify_retries,
        qa_mode: $qa_mode,
        visual_mode: $visual_mode,
        figma_enabled: false
      }' \
      > "$CONFIG_FILE"
  fi

  log "Config written to $CONFIG_FILE"
  jq '
    .markdown_pr_strategy = (.markdown_pr_strategy // (if .goal_source == "markdown" then "auto" else "single" end))
    | .max_tasks_per_pr = (.max_tasks_per_pr // 3)
    | .max_files_per_pr = (.max_files_per_pr // 25)
    | .max_parallel_prs = (.max_parallel_prs // 2)
  ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
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
  [ -z "${GOAL_GROUP:-}" ] || { goal_error assignment "Use groups complete for a group; clear GOAL_GROUP before completing the root"; return 1; }
  require_active_goal
  refresh_goal_idx
  groups_persist_active 2>/dev/null || true
  local mode incomplete
  mode="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].delivery_mode // "single"' "$STATE_FILE")"
  if [ "$mode" = "multi-pr" ]; then
    incomplete="$(jq -r --argjson idx "$GOAL_IDX" '
      [.[$idx].delivery_groups[]? | select(.status != "merged" and .status != "completed" and .status != "cancelled") | .id] | join(",")
    ' "$STATE_FILE")"
    if [ -n "$incomplete" ]; then
      err "Root Markdown goal is not complete — unfinished groups: $incomplete"
      exit 1
    fi
    harness_event "main" "root_goal_completed" "all delivery groups merged/completed"
  else
    cmd_harness_done >/dev/null || return
    delivery_require_complete || return
  fi
  state_update status completed
  log "Goal marked completed"
}

cmd_merge() {
  [ -z "${GOAL_TASK:-}" ] || { goal_error assignment "Clear GOAL_TASK before merging delivery"; return 1; }
  require_cmd jq
  refresh_goal_idx
  local delivery_mode active_gid
  delivery_mode="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].delivery_mode // "single"' "$STATE_FILE")"
  active_gid="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].active_group_id // empty' "$STATE_FILE")"
  if [ "$delivery_mode" = "multi-pr" ]; then
    if [ -z "$active_gid" ] || [ "$active_gid" = "null" ]; then
      err "Refusing aggregation merge for a Markdown multi-PR goal. Use: goal-git.sh groups merge <group-id>"
      exit 1
    fi
    cmd_groups_merge "$active_gid"
    return
  fi
  require_vcs_cli
  cmd_harness_done >/dev/null || return
  delivery_require_complete || return

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
    repos_dir=$(repo_dir "$repo_path") || return

    if [ "$repo_pr" = "null" ] || [ -z "$repo_pr" ]; then
      goal_error delivery "No validated PR for $repo_path"; return 1
    fi

    merge_pr_in_dir "$repos_dir" "$repo_pr" "$repo_url" || return
    repo_idx=$((repo_idx + 1))
  done
}

merge_pr() {
  local pr_number="$1" pr_url="$2"
  merge_pr_in_dir "$(goal_workdir)" "$pr_number" "$pr_url"
}

merge_pr_in_dir() {
  local wd="$1" pn="$2" url="$3" sha branch base repo meta key mode
  key="${wd#"$PROJECT_ROOT"/}"; [ "$wd" != "$PROJECT_ROOT" ] || key=.
  case "$key" in .worktrees/*) key=. ;; esac
  delivery_clean "$wd" || return
  context_assert_branch "$wd" || return
  sha=$(git -C "$wd" rev-parse HEAD)
  branch=$(git -C "$wd" branch --show-current)
  base=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].base_branch' "$STATE_FILE")
  repo=$(delivery_repo "$wd") || return
  meta=$(delivery_remote_request "$wd" "$pn") || return
  if ! delivery_merged_request_ok "$meta" "$pn" "$branch" "$base" "$sha"; then
  mode=$(config_read review_mode); mode="${mode:-inline}"
  if [ "$mode" = inline ]; then (cmd_pending "$key" >/dev/null) || return 1;
  elif [ "$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].harness.requirements.reviewer' "$STATE_FILE")" != false ]; then (cmd_review_pending "$key" >/dev/null) || return 1; fi
  meta=$(forge_pr_metadata "$platform" "$repo" "$branch" "$base") || return
  printf '%s' "$meta" | jq -e --argjson n "$pn" '.number == $n' >/dev/null || { goal_error stale_delivery "Recorded PR/MR identity differs from the current open request"; return 1; }
  delivery_validate_metadata "$meta" "$branch" "$base" "$sha" || return
  if [ "$platform" = github ]; then
    forge_require_flags gh 'pr merge' --repo --merge --match-head-commit || return
    forge_run write gh pr merge "$pn" --repo "$repo" --merge --match-head-commit "$sha" >&2 || return
  else
    forge_require_flags glab 'mr merge' --repo --sha --yes --auto-merge || return
    forge_run write glab mr merge "$pn" --repo "$repo" --sha "$sha" --yes --auto-merge=false >&2 || return
  fi
  meta=$(delivery_remote_request "$wd" "$pn") || return
  delivery_merged_request_ok "$meta" "$pn" "$branch" "$base" "$sha" || { goal_error merge_pending "PR/MR has not merged at the reviewed SHA; retain worktree"; return 1; }
  fi
  state_mutate --arg repo "$key" --argjson idx "$GOAL_IDX" --argjson n "$pn" '
    .[$idx].repos |= ((. // []) | map(if .path == $repo and .pr_number == $n then .delivery.merged = true else . end))
    | if $repo == "." and .[$idx].pr_number == $n then .[$idx].delivery.merged = true else . end
  ' || return
  log "Confirmed merged: $url"
}

cmd_status() {
  require_cmd git
  refresh_goal_idx
  local wd
  wd="$(goal_workdir)"
  (cd "$wd" && git status)
}

cmd_restore() {
  require_active_goal; refresh_goal_idx
  [ $# -gt 0 ] || { goal_error usage "restore requires file paths"; return 1; }
  local wd; wd=$(repo_dir "${GOAL_REPO:-.}") || return
  context_assert_branch "$wd" || return
  git -C "$wd" restore -- "$@" >&2 || return
  harness_invalidate "working files changed"
}

cmd_diff() {
  require_active_goal; refresh_goal_idx
  local wd base anchor
  wd=$(repo_dir "${1:-${GOAL_REPO:-.}}") || return
  context_assert_branch "$wd" || return
  base=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].base_branch' "$STATE_FILE")
  anchor=$(git -C "$wd" merge-base "origin/$base" HEAD) || return
  git -C "$wd" diff "$anchor" --
  git -C "$wd" ls-files --others --exclude-standard | sed 's/^/Untracked file: /' >&2
}

cmd_worktree_add() {
  require_cmd git jq
  local slug="${1:-}"
  [ -z "$slug" ] && { err "worktree add requires <task-slug>"; exit 1; }

  slug="$(slugify "$slug")"
  require_active_goal
  refresh_goal_idx

  local delivery_mode
  delivery_mode="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].delivery_mode // "single"' "$STATE_FILE")"
  if [ "$delivery_mode" = "multi-pr" ]; then
    err "Markdown multi-PR goals use isolated group worktrees via: goal-git.sh groups start <group-id>"
    err "Do not create nested task worktrees or a goal/ aggregation branch."
    exit 1
  fi

  local goal_branch task_branch wt_path
  goal_branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch' "$STATE_FILE")
  task_branch="$(task_branch_name "$goal_branch" "$slug")"
  wt_path="$(worktree_path "$slug")"

  mkdir -p "$WORKTREES_DIR"
  if [ -d "$wt_path" ]; then
    err "Worktree already exists: $wt_path"
    exit 1
  fi

  git -C "$PROJECT_ROOT" worktree add -b "$task_branch" "$wt_path" "$goal_branch" >&2 || return
  sync_worktree_config "$wt_path" || return
  state_mutate --argjson idx "$GOAL_IDX" --arg task "$slug" --arg branch "$task_branch" --arg wt "${wt_path#"$PROJECT_ROOT"/}"     '.[$idx].task_worktrees[$task] = {branch:$branch,worktree:$wt}' || return

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
  require_active_goal; refresh_goal_idx
  local slug="${1:-}" wd wt branch
  [ -n "$slug" ] || return 1
  slug=$(slugify "$slug")
  wt=$(worktree_path "$slug")
  wd=$(goal_workdir) || return
  context_assert_branch "$wd" || return
  delivery_clean "$wd" || return
  delivery_clean "$wt" || return
  branch=$(git -C "$wt" branch --show-current)
  [ "$branch" = "$(task_branch_name "$(git -C "$wd" branch --show-current)" "$slug")" ] || return 1
  git -C "$wd" merge "$branch" -m "merge: $slug" >&2 || return
  harness_invalidate "task branch integrated"
  git -C "$PROJECT_ROOT" worktree remove "$wt" >&2 || return
  # The root checkout may still be on main while the goal lives in a worktree.
  git -C "$wd" merge-base --is-ancestor "$branch" HEAD || return
  git -C "$PROJECT_ROOT" branch -D "$branch" >&2 || return
  state_mutate --argjson idx "$GOAL_IDX" --arg task "$slug" 'del(.[$idx].task_worktrees[$task])'
}

cmd_worktree_remove() {
  require_cmd git jq
  local slug="${1:-}"
  [ -z "$slug" ] && { err "worktree remove requires <task-slug>"; exit 1; }

  slug="$(slugify "$slug")"
  require_active_goal
  refresh_goal_idx

  local delivery_mode
  delivery_mode="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].delivery_mode // "single"' "$STATE_FILE")"
  if [ "$delivery_mode" = "multi-pr" ]; then
    err "Markdown multi-PR worktrees are removed only after merge or explicit cancellation."
    err "Use: goal-git.sh groups merge <group-id>  or  goal-git.sh groups cancel <group-id>"
    exit 1
  fi

  local goal_branch task_branch wt_path
  goal_branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch' "$STATE_FILE")
  task_branch="$(task_branch_name "$goal_branch" "$slug")"
  wt_path="$(worktree_path "$slug")"

  [ -d "$wt_path" ] || { err "Worktree not found: $wt_path"; exit 1; }

  delivery_clean "$wt_path" || return
  git -C "$PROJECT_ROOT" worktree remove "$wt_path" >&2 || return
  git -C "$PROJECT_ROOT" branch -d "$task_branch" >&2 || warn "Retained unmerged task branch $task_branch"
  state_mutate --argjson idx "$GOAL_IDX" --arg task "$slug" 'del(.[$idx].task_worktrees[$task])'
  log "Removed worktree: $wt_path"
}

# --- Issue list / queue helpers ---

generate_run_id() {
  echo "run-$(date +%s)-$$"
}

issue_worktree_rel() {
  echo ".worktrees/issue-${1}"
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
  if ! printf '%s\n' "$raw_json" | jq -se 'length == 1 and (.[0] | type) == "array"' >/dev/null 2>&1; then
    err "Issue list command returned invalid JSON or a non-array response; check CLI warnings and authentication"
    return 1
  fi
  printf '%s\n' "$raw_json" | jq '[.[]? | {
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
      forge_run read gh issue view "$number" --repo "$repo" --json number,title,body,labels,url,createdAt
      ;;
    gitlab)
      forge_run read glab issue view "$number" --repo "$repo" --output json
      ;;
  esac
}

cmd_issues_list() {
  require_cmd jq
  local url="${1:-$(config_read issue_list_url)}"
  local limit="${2:-$(config_read issue_limit)}"
  [ -z "$limit" ] || [ "$limit" = "null" ] && limit="3"
  [ -z "$url" ] && { err "issues list requires <url> or issue_list_url in config"; exit 1; }

  [[ "$limit" =~ ^[0-9]+$ ]] && [ "$limit" -gt 0 ] && [ "$limit" -le 100 ] || { goal_error usage "Issue limit must be 1..100"; return 1; }
  parse_issue_list_url "$url" || exit 1
  platform="$ISSUE_LIST_PLATFORM"; require_vcs_cli

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
      raw_json=$(forge_run read gh issue list --repo "$ISSUE_LIST_REPO" --state open --limit "$limit" \
        --search "$search" --json number,title,body,labels,url,createdAt)
      ;;
    gitlab)
      # Open issues are the default; deprecated --opened prints a warning on stdout.
      local glab_cmd=(forge_run read glab issue list --repo "$ISSUE_LIST_REPO" --per-page "$limit" --order created_at --sort asc --output json)
      if [ -n "$ISSUE_LIST_QUERY" ]; then
        glab_cmd+=(--label "$ISSUE_LIST_QUERY")
      fi
      local field value
      for field in search assignee_username author_username; do
        value=$(printf '%s' "$ISSUE_LIST_FILTERS" | jq -r --arg f "$field" '.[$f][0] // empty')
        [ -z "$value" ] || case "$field" in
          search) glab_cmd+=(--search "$value") ;;
          assignee_username) glab_cmd+=(--assignee "$value") ;;
          author_username) glab_cmd+=(--author "$value") ;;
        esac
      done
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
  jq --arg rid "$run_id" '[.[] | select(.run_id == $rid)]' "$STATE_FILE"
}

cmd_issues_start() {
  require_cmd git jq
  local number="${1:-}"
  local use_worktree=false override_url=""
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree) use_worktree=true; shift ;;
      --url) [ $# -ge 2 ] || return 1; override_url="$2"; shift 2 ;;
      *) goal_error usage "Unknown issues start argument: $1"; return 1 ;;
    esac
  done
  [ -z "$number" ] && { err "issues start requires <number>"; exit 1; }

  local url repo run_id batch wt_rel wt_path base branch goal title labels_json task_type
  url="${override_url:-$(config_read issue_list_url)}"
  [ -z "$url" ] && { err "issue_list_url not configured — run /init-goal"; exit 1; }
  parse_issue_list_url "$url" || exit 1
  platform="$ISSUE_LIST_PLATFORM"; require_vcs_cli
  repo="$ISSUE_LIST_REPO"
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || { goal_error usage "Issue number must be positive"; return 1; }
  [ -z "${GOAL_ISSUE:-}" ] || [ "$GOAL_ISSUE" = "$number" ] || {
    goal_error assignment "GOAL_ISSUE differs from the requested issue number"; return 1;
  }
  [ -z "${GOAL_GROUP:-}${GOAL_TASK:-}" ] || {
    goal_error assignment "Clear GOAL_GROUP and GOAL_TASK before issue intake"; return 1;
  }
  local requested_repo="${GOAL_ISSUE_REPO:-}" repo_path
  repo_path=$(python3 - "$url" <<'PY'
import sys
from urllib.parse import urlsplit
p=urlsplit(sys.argv[1]).path
print(p.split('/-/issues')[0].strip('/') if '/-/issues' in p else p.split('/issues')[0].strip('/'))
PY
  ) || return
  [ -z "$requested_repo" ] || [ "$requested_repo" = "$repo" ] || [ "$requested_repo" = "$repo_path" ] || {
    goal_error assignment "GOAL_ISSUE_REPO differs from the supplied issue URL"; return 1;
  }

  local issue_json
  issue_json="$(fetch_issue_by_number "$repo" "$number")"
  printf '%s' "$issue_json" | jq -e --argjson n "$number" '(.number // .iid) == $n and (.title | type == "string" and length > 0)' >/dev/null || return 1
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
  local existing=""
  if [ -f "$STATE_FILE" ]; then
    existing=$(jq -c --arg rid "$run_id" --argjson n "$number" \
      --arg repo "$repo" '[.[] | select(.run_id == $rid and .issue.number == $n and (.issue.repo // $repo) == $repo)]
      | if length > 1 then error("Ambiguous issue assignment in state") else .[0] // empty end' "$STATE_FILE") || return
  fi
  if [ -n "${REQUESTED_GOAL_ID:-}" ]; then
    [ -n "$existing" ] && [ "$(printf '%s' "$existing" | jq -r .id)" = "$REQUESTED_GOAL_ID" ] || {
      goal_error assignment "GOAL_ID does not identify the requested issue/run/repository"; return 1;
    }
  fi
  if [ -n "$existing" ]; then
    if [ "$(echo "$existing" | jq -r '.status')" = "completed" ]; then
      err "Issue #$number is already completed in run $run_id"
      exit 1
    fi
    log "Resuming existing issue #$number in run $run_id"
    GOAL_ID=$(printf '%s' "$existing" | jq -r .id)
    GOAL_ISSUE="$number"; GOAL_RUN_ID="$run_id"; GOAL_ISSUE_REPO="$repo"
    refresh_goal_idx || return
    local existing_wt existing_dir
    existing_dir=$(goal_workdir) || return
    context_assert_branch "$existing_dir" || return
    existing_wt="$(echo "$existing" | jq -r '.worktree // empty')"
    [ -z "$existing_wt" ] || sync_worktree_config "$PROJECT_ROOT/$existing_wt"
    echo "$existing" | jq -r '.worktree // empty'
    return 0
  fi
  if [ "$use_worktree" = true ] && [ "$(get_repos)" != "." ]; then
    err "Parallel issue worktrees require a single root repository"
    exit 1
  fi

  local repos_json="[]"
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    local rd
    rd="$PROJECT_ROOT"; [ "$r" = . ] || rd="$PROJECT_ROOT/$r"
    log "Preparing issue #$number branch in: $r"
    git -C "$rd" fetch origin "refs/heads/$base:refs/remotes/origin/$base" >&2 || return
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
    rd="$PROJECT_ROOT"
    (cd "$rd" && git worktree add -b "$branch" "$wt_path" "origin/$base")
    sync_worktree_config "$wt_path"
    log "Issue worktree: $wt_rel (branch: $branch)"
  else
    while IFS= read -r r; do
      [ -z "$r" ] && continue
      local rd
      rd="$PROJECT_ROOT"; [ "$r" = . ] || rd="$PROJECT_ROOT/$r"
      delivery_clean "$rd" || return
      git -C "$rd" checkout -b "$branch" "origin/$base" >&2 || return
      context_assert_branch "$rd" "$branch" || return
    done < <(get_repos)
  fi

  local issue_url
  issue_url=$(echo "$issue_json" | jq -r '.url // .web_url // ""')
  local new_goal
  local repo_count
  repo_count=$(echo "$repos_json" | jq 'length')

  new_goal=$(jq -n \
    --arg id "goal-$(python3 -c 'import uuid; print(uuid.uuid4())')" \
    --arg repo "$repo" \
    --arg host "$ISSUE_LIST_HOST" \
    --arg platform "$platform" \
    --arg body "$body" \
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
      id:$id, goal_source:"issues", source:{type:"issues",platform:$platform,repo:$repo,host:$host,title:$issue_title,body:$body,reference:$issue_url,acceptance_criteria:[]},
      goal: $goal,
      branch: $branch,
      base_branch: $base,
      pr_number: null,
      pr_url: "",
      status: "in_progress",
      run_id: $run_id,
      batch: $batch,
      worktree: (if ($wt | length) > 0 then $wt else null end),
      issue: {repo:$repo, host:$host, number: $issue_num, url: $issue_url, title: $issue_title},
      repos: $repos
    }')

  state_append_goal "$new_goal" || return

  GOAL_RUN_ID="$run_id"; GOAL_ISSUE_REPO="$repo"; GOAL_ID=""
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

  GOAL_ID="${REQUESTED_GOAL_ID:-}"
  GOAL_ISSUE="$number"
  refresh_goal_idx
  cmd_harness_done
  if ! jq -e --argjson idx "$GOAL_IDX" '
    .[$idx] | if (.repos // [] | length) > 0
      then all(.repos[]; (.pr_url // "") != "")
      else (.pr_url // "") != "" end
  ' "$STATE_FILE" >/dev/null; then
    err "Issue #$number has no completed PR/MR delivery"
    exit 1
  fi

  delivery_require_complete || return

  local wt_rel wt_path
  wt_rel=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].worktree // ""' "$STATE_FILE")
  if [ -n "$wt_rel" ] && [ "$wt_rel" != "null" ]; then
    wt_path="$PROJECT_ROOT/$wt_rel"
    if [ -d "$wt_path" ]; then
      git worktree remove "$wt_path" || { err "Issue #$number worktree is not clean; keep it for recovery"; exit 1; }
      log "Removed issue worktree: $wt_rel"
    fi
    state_mutate --argjson idx "$GOAL_IDX" 'del(.[$idx].worktree)'
  fi

  state_mutate --argjson idx "$GOAL_IDX" '.[$idx].status = "completed"'
  log "Issue #$number marked completed"
}

# --- Local review findings (.goal-review/) ---

review_file_key() {
  local repo_path="${1:-${GOAL_REPO:-.}}"
  repo_dir "${repo_path:-.}" >/dev/null || return
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
  local key; key=$(review_file_key "${1:-}") || return
  printf '%s/%s.json\n' "$REVIEW_DIR" "$key"
}

review_require_file() {
  local repo_path="${1:-${GOAL_REPO:-.}}"
  local rf
  rf="$(review_file_path "$repo_path")"
  [ -f "$rf" ] || { err "No local review file — run 'goal-git.sh review init' first"; exit 1; }
  echo "$rf"
}

cmd_review_init() {
  require_cmd jq
  require_active_goal
  refresh_goal_idx
  local repo_path="${1:-${GOAL_REPO:-.}}"
  local branch max_iter rf
  branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch' "$STATE_FILE")
  local max_iter="$(config_read review_max_iterations)"
  [ -z "$max_iter" ] || [ "$max_iter" = "null" ] && max_iter="0"
  mkdir -p "$REVIEW_DIR"
  rf="$(review_file_path "$repo_path")"
  [ ! -f "$rf" ] || { log "Preserving existing review: $rf"; return 0; }
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
  local path="${1:-}" line="${2:-}" severity="${3:-}" body="${4:-}" repo_path="${5:-${GOAL_REPO:-.}}"
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
  local repo_path="${1:-${GOAL_REPO:-.}}"
  local rf
  rf="$(review_require_file "$repo_path")"
  jq '.findings' "$rf"
}

cmd_review_resolve() {
  require_cmd jq
  local id="${1:-}" repo_path="${2:-${GOAL_REPO:-.}}"
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
  local repo_path="${1:-${GOAL_REPO:-.}}"
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
  local repo_path="${1:-${GOAL_REPO:-.}}"
  local rf iterations
  rf="$(review_require_file "$repo_path")"
  iterations=$(jq -r '.iterations // 0' "$rf")
  iterations=$((iterations + 1))
  jq --argjson n "$iterations" \
    '.iterations = $n | .max_iterations = 0' \
    "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"
  log "Review iteration $iterations — continue until review pending is clean (no cap)"
}

models_vision_list() {
  local models_file="$1"
  jq -r '."$capabilities".vision_models // [] | .[]' "$models_file" 2>/dev/null || true
}

models_is_vision() {
  local models_file="$1" model="$2"
  [ -z "$model" ] && return 1
  models_vision_list "$models_file" | grep -Fxq "$model"
}


cmd_complexity_classify() {
  require_cmd jq
  local text="" files=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --files)
        files="${2:-}"
        shift 2
        ;;
      *)
        if [ -z "$text" ]; then
          text="$1"
        else
          text="$text $1"
        fi
        shift
        ;;
    esac
  done
  [ -z "$text" ] && { err "complexity classify requires <text>"; exit 1; }

  local lower file_count=0
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  if [ -n "$files" ]; then
    file_count="$(printf '%s' "$files" | awk -F',' '{print NF}')"
  fi

  local complexity="NORMAL"
  local planner_required=true reviewer_required=true
  local reason_list=()

  if echo "$lower" | grep -qiE '\b(migration|migrate|redesign|re-architect|cross[- ]service|multi[- ]service|irreversible|security model|data model rewrite|sharding|rewrite architecture)\b'; then
    complexity="ARCHITECTURAL"
    reason_list+=("architectural_keywords")
  elif echo "$lower" | grep -qiE '\b(concurrency|race condition|deadlock|auth(entication|orization)?|oauth|rbac|permission|security|multi[- ]module|distributed|consistency|transaction|unfamiliar|integration|broad regression|performance critical)\b'; then
    complexity="COMPLEX"
    reason_list+=("complex_keywords")
  elif echo "$lower" | grep -qiE '\b(typo|spelling|copy[- ]?edit|rename|wording|one[- ]?liner|trivial|simple fix|config(uration)? (tweak|adjust|change)|test[- ]only|docs?[- ]only|readme)\b'; then
    if ! echo "$lower" | grep -qiE '\b(auth|migration|concurrency|security|redesign)\b'; then
      complexity="TRIVIAL"
      planner_required=false
      reviewer_required=false
      reason_list+=("trivial_keywords")
    fi
  elif [ "$file_count" -gt 0 ] && [ "$file_count" -le 2 ] && echo "$lower" | grep -qiE '\b(fix|update|adjust|tweak|change)\b'; then
    if ! echo "$lower" | grep -qiE '\b(auth|migration|concurrency|security|redesign)\b'; then
      complexity="TRIVIAL"
      planner_required=false
      reviewer_required=false
      reason_list+=("tiny_file_scope")
    fi
  else
    reason_list+=("default_normal")
  fi

  if [ "$file_count" -gt 5 ] && [ "$complexity" = "NORMAL" ]; then
    complexity="COMPLEX"
    reason_list+=("many_files")
  fi

  local reasons_json
  if [ ${#reason_list[@]} -eq 0 ]; then
    reasons_json='[]'
  else
    reasons_json="$(printf '%s\n' "${reason_list[@]}" | jq -R . | jq -s .)"
  fi

  jq -n \
    --arg complexity "$complexity" \
    --argjson planner "$planner_required" \
    --argjson reviewer "$reviewer_required" \
    --argjson reasons "$reasons_json" \
    '{
      complexity: $complexity,
      planner_required: $planner,
      reviewer_required: $reviewer,
      reasons: $reasons,
      baseline: true
    }'
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
      forge_run read gh auth status 2>&1 | head -1 || warn "  gh not logged in (run 'gh auth login')"
      log "  PR URL format: https://github.com/<owner>/<repo>/pull/<number>"
      ;;
    gitlab)
      command -v glab >/dev/null 2>&1 && log "  glab CLI: OK" || { err "  glab CLI: NOT FOUND — install with: brew install glab"; exit 1; }
      forge_run read glab auth status 2>&1 | head -1 || warn "  glab not logged in (run 'glab auth login')"
      log "  MR URL format: https://gitlab.com/<namespace>/<project>/-/merge_requests/<iid>"
      ;;
  esac

  log "selfcheck: complete"
}

# --- Harness / Verify / Route ---

harness_require() {
  require_active_goal
  require_cmd jq
  refresh_goal_idx
  if ! jq -e --argjson idx "$GOAL_IDX" '.[$idx].harness' "$STATE_FILE" >/dev/null 2>&1; then
    err "No harness on active goal — run 'harness init' first"
    exit 1
  fi
}

harness_get() {
  jq --argjson idx "$GOAL_IDX" '.[$idx].harness' "$STATE_FILE"
}

harness_put() {
  local harness_json="$1"
  state_mutate --argjson idx "$GOAL_IDX" --argjson h "$harness_json" \
    '.[$idx].harness = $h'
  groups_persist_active 2>/dev/null || true
}

harness_now() {
  # Local timestamp with colon in offset: 2026-09-13T20:12:00+07:00
  # Avoid bash 4+ ${var: -2} (macOS ships bash 3.2).
  local raw prefix suffix
  raw="$(date +"%Y-%m-%dT%H:%M:%S%z")"
  prefix="${raw%??}"
  suffix="${raw#"$prefix"}"
  printf '%s:%s\n' "$prefix" "$suffix"
}

harness_active_issue() {
  # Prints issue number or empty. GOAL_IDX=-1 means last/active goal (jq convention).
  if [ ! -f "$STATE_FILE" ]; then
    echo ""
    return 0
  fi
  jq -r --argjson idx "${GOAL_IDX:--1}" \
    '(.[$idx].issue.number // empty)' \
    "$STATE_FILE" 2>/dev/null || true
}

progress_mirror_line() {
  local at="$1" agent="$2" event="$3" detail="${4:-}"
  mkdir -p "$(dirname "$PROGRESS_LOG")"
  if [ -n "$detail" ]; then
    printf '%s  %-16s  %-12s  %s\n' "$at" "$agent" "$event" "$detail" >> "$PROGRESS_LOG"
  else
    printf '%s  %-16s  %-12s\n' "$at" "$agent" "$event" >> "$PROGRESS_LOG"
  fi
}

# Typed event append. agent + event required. Returns 0 always for agent-facing use.
harness_event() {
  local agent="${1:-}" event="${2:-}" detail="${3:-}"
  local at issue_num issue_json

  if [ -z "$agent" ] || [ -z "$event" ]; then
    return 0
  fi

  at="$(harness_now)"
  refresh_goal_idx 2>/dev/null || true
  issue_num="$(harness_active_issue)"
  if [ -n "$issue_num" ]; then
    issue_json="$issue_num"
  else
    issue_json="null"
  fi

  progress_mirror_line "$at" "$agent" "$event" "$detail"

  # Best-effort: no state / no harness / lock failure → still exit 0
  if [ ! -f "$STATE_FILE" ]; then
    return 0
  fi
  if ! jq -e --argjson idx "${GOAL_IDX:--1}" '.[$idx].harness' "$STATE_FILE" >/dev/null 2>&1; then
    return 0
  fi

  state_mutate --argjson idx "${GOAL_IDX:--1}" \
    --arg at "$at" \
    --arg agent "$agent" \
    --arg event "$event" \
    --arg detail "$detail" \
    --argjson issue "$issue_json" \
    '.[$idx].harness.events += [{
      at: $at,
      agent: $agent,
      event: $event,
      issue: $issue,
      detail: $detail
    }]' || true

  return 0
}

# Compatibility wrapper for internal call sites that previously passed a free-form string
harness_append_event() {
  local msg="$1"
  harness_event "harness" "internal" "$msg"
}

harness_phase_allowed() {
  local from="$1" to="$2"
  case "${from}->${to}" in
    "PLANNED->RESEARCHING"|"PLANNED->BUILDING") return 0 ;;
    "RESEARCHING->BUILDING") return 0 ;;
    "BUILDING->ESCALATED"|"BUILDING->VERIFYING") return 0 ;;
    "ESCALATED->BUILDING") return 0 ;;
    "VERIFYING->REWORK"|"VERIFYING->REVIEWING"|"VERIFYING->DONE"|"VERIFYING->QA"|"VERIFYING->VISUAL_REVIEW") return 0 ;;
    "REVIEWING->REWORK"|"REVIEWING->QA"|"REVIEWING->DONE"|"REVIEWING->VISUAL_REVIEW") return 0 ;;
    "QA->REWORK"|"QA->VISUAL_REVIEW"|"QA->DONE") return 0 ;;
    "VISUAL_REVIEW->REWORK"|"VISUAL_REVIEW->DONE") return 0 ;;
    "REWORK->BUILDING"|"REWORK->VERIFYING"|"REWORK->ESCALATED"|"REWORK->FAILED") return 0 ;;
    *)
      [ "$to" = "FAILED" ] && return 0
      return 1
      ;;
  esac
}

# A verification pass closes the implementation queue for this iteration.
# Do not let a late task registration turn a successful verification into an
# illegal VERIFYING -> BUILDING transition.
harness_tasks_reconciled() {
  local incomplete
  incomplete="$(jq -r --argjson idx "$GOAL_IDX" '
    .[$idx].harness.tasks
    | map(select(.state != "DONE"))
    | map("\(.id)=\(.state)")
    | join(", ")
  ' "$STATE_FILE")"
  if [ -n "$incomplete" ]; then
    err "VERIFYING rejected — task queue is not reconciled: $incomplete"
    err "Finish or explicitly fail/block the tasks, then start a new REWORK -> BUILDING iteration before verification."
    return 1
  fi
  return 0
}

harness_phase_allows_task_add() {
  local role="$1" phase="$2"
  case "$role:$phase" in
    builder:BUILDING|builder-expert:BUILDING) return 0 ;;
    *)
      err "Task registration rejected — role '$role' may not be added during $phase. Create work only in BUILDING; VERIFYING is frozen."
      return 1
      ;;
  esac
}

harness_phase_allows_spawn() {
  local role="$1" phase="$2"
  case "$role:$phase" in
    planner:PLANNED|researcher:RESEARCHING|builder:BUILDING|builder-expert:BUILDING|reviewer:REVIEWING|qa:QA|visual-reviewer:VISUAL_REVIEW) return 0 ;;
    *)
      err "Spawn rejected — role '$role' may not be spawned during $phase. VERIFYING is a no-spawn barrier; use REWORK -> BUILDING for a new iteration."
      return 1
      ;;
  esac
}

cmd_harness_init() {
  require_active_goal
  require_cmd jq
  refresh_goal_idx

  local route="feature"
  local qa_flag="" visual_flag=""
  local complexity="NORMAL"
  local planner_flag="" reviewer_flag=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --route)
        route="${2:-}"
        shift 2
        ;;
      --qa)
        qa_flag="${2:-}"
        shift 2
        ;;
      --visual)
        visual_flag="${2:-}"
        shift 2
        ;;
      --complexity)
        complexity="${2:-}"
        shift 2
        ;;
      --planner-required)
        planner_flag="${2:-}"
        shift 2
        ;;
      --reviewer-required)
        reviewer_flag="${2:-}"
        shift 2
        ;;
      *)
        err "Unknown harness init arg: $1"
        exit 1
        ;;
    esac
  done

  case "$route" in
    backend|feature|frontend) ;;
    *) err "route must be: backend, feature, or frontend"; exit 1 ;;
  esac

  case "$complexity" in
    TRIVIAL|NORMAL|COMPLEX|ARCHITECTURAL) ;;
    *) err "complexity must be: TRIVIAL, NORMAL, COMPLEX, or ARCHITECTURAL"; exit 1 ;;
  esac

  # Route-based defaults (backward compatible when --qa/--visual omitted)
  local qa_req=false visual_req=false req_source="route-default"
  case "$route" in
    backend)  qa_req=false; visual_req=false ;;
    feature)  qa_req=true;  visual_req=false ;;
    frontend) qa_req=true;  visual_req=true  ;;
  esac

  if [ -n "$qa_flag" ]; then
    case "$qa_flag" in
      true|false) qa_req="$qa_flag"; req_source="explicit" ;;
      *) err "--qa must be true or false"; exit 1 ;;
    esac
  fi
  if [ -n "$visual_flag" ]; then
    case "$visual_flag" in
      true|false) visual_req="$visual_flag"; req_source="explicit" ;;
      *) err "--visual must be true or false"; exit 1 ;;
    esac
  fi
  if [ -n "$qa_flag" ] || [ -n "$visual_flag" ]; then
    req_source="explicit"
  fi

  # Complexity defaults for planner/reviewer
  local planner_req=true reviewer_req=true
  if [ "$complexity" = "TRIVIAL" ]; then
    planner_req=false
    reviewer_req=false
  fi
  if [ -n "$planner_flag" ]; then
    case "$planner_flag" in
      true|false) planner_req="$planner_flag" ;;
      *) err "--planner-required must be true or false"; exit 1 ;;
    esac
  fi
  if [ "$complexity" != "TRIVIAL" ] && [ "$planner_req" = false ]; then
    err "harness init: --planner-required false is only allowed when --complexity TRIVIAL (got $complexity). Honor classify and spawn @planner. A markdown/plan file is planner input, not a skip."
    exit 1
  fi
  if [ -n "$reviewer_flag" ]; then
    case "$reviewer_flag" in
      true|false) reviewer_req="$reviewer_flag" ;;
      *) err "--reviewer-required must be true or false"; exit 1 ;;
    esac
  fi

  local max_rework max_escalations max_verify_retries
  max_rework="$(config_read max_rework)"; max_rework="${max_rework:-3}"
  max_escalations="$(config_read max_escalations)"; max_escalations="${max_escalations:-2}"
  max_verify_retries="$(config_read max_verify_retries)"; max_verify_retries="${max_verify_retries:-3}"

  local max_total max_planner max_researcher max_expert max_reviewer_runs max_qa max_visual
  max_planner="$(config_read max_planner_runs)"; max_planner="${max_planner:-1}"
  max_researcher="$(config_read max_researcher_runs)"; max_researcher="${max_researcher:-1}"
  max_expert="$(config_read max_builder_expert_runs)"; max_expert="${max_expert:-1}"
  max_reviewer_runs="$(config_read max_reviewer_runs)"
  if [ -z "$max_reviewer_runs" ]; then
    # Initial review + one re-review after each allowed rework (avoids 2-reviewer deadlock).
    max_reviewer_runs=$((max_rework + 1))
  fi
  max_qa="$(config_read max_qa_runs)"; max_qa="${max_qa:-1}"
  max_visual="$(config_read max_visual_runs)"; max_visual="${max_visual:-1}"
  max_total="$(config_read max_total_spawns)"
  if [ -z "$max_total" ]; then
    # planner + researcher + builders(1+rework) + reviewers + expert + qa + visual
    max_total=$((1 + 1 + 1 + max_rework + max_reviewer_runs + 1 + 1 + 1))
  fi

  # Re-init must not wipe handoffs/metrics already recorded (spawn/context put before final init).
  local prev_context='{}' prev_events='[]' prev_tasks='[]' prev_metrics=''
  if jq -e --argjson idx "$GOAL_IDX" '.[$idx].harness != null' "$STATE_FILE" >/dev/null 2>&1; then
    prev_context="$(jq -c --argjson idx "$GOAL_IDX" '.[$idx].harness.context // {}' "$STATE_FILE")"
    prev_events="$(jq -c --argjson idx "$GOAL_IDX" '.[$idx].harness.events // []' "$STATE_FILE")"
    prev_tasks="$(jq -c --argjson idx "$GOAL_IDX" '.[$idx].harness.tasks // []' "$STATE_FILE")"
    prev_metrics="$(jq -c --argjson idx "$GOAL_IDX" '.[$idx].harness.metrics // empty' "$STATE_FILE")"
  fi
  if [ -z "$prev_metrics" ] || [ "$prev_metrics" = "null" ]; then
    prev_metrics='{"agent_spawns":0,"planner_runs":0,"researcher_runs":0,"builder_runs":0,"expert_runs":0,"reviewer_runs":0,"qa_runs":0,"visual_runs":0,"rework_cycles":0}'
  fi

  local harness
  harness="$(jq -n \
    --arg route "$route" \
    --arg complexity "$complexity" \
    --argjson qa "$qa_req" \
    --argjson visual "$visual_req" \
    --argjson planner_req "$planner_req" \
    --argjson reviewer_req "$reviewer_req" \
    --arg req_source "$req_source" \
    --argjson max_rework "$max_rework" \
    --argjson max_escalations "$max_escalations" \
    --argjson max_verify_retries "$max_verify_retries" \
    --argjson max_total "$max_total" \
    --argjson max_planner "$max_planner" \
    --argjson max_researcher "$max_researcher" \
    --argjson max_expert "$max_expert" \
    --argjson max_reviewer_runs "$max_reviewer_runs" \
    --argjson max_qa "$max_qa" \
    --argjson max_visual "$max_visual" \
    --argjson prev_context "$prev_context" \
    --argjson prev_events "$prev_events" \
    --argjson prev_tasks "$prev_tasks" \
    --argjson prev_metrics "$prev_metrics" \
    '{
      phase: "PLANNED",
      route: $route,
      complexity: $complexity,
      requirements: {
        qa: $qa,
        visual: $visual,
        planner: $planner_req,
        reviewer: $reviewer_req,
        source: $req_source
      },
      tasks: $prev_tasks,
      gates: {
        PLAN: {status: "NOT_RUN"},
        IMPLEMENTATION: {status: "NOT_RUN"},
        ANALYSIS: {status: "NOT_RUN"},
        VERIFICATION: {status: "NOT_RUN"},
        REVIEW: {status: "NOT_RUN"},
        QA: {status: "NOT_RUN"},
        VISUAL: {status: "NOT_RUN"}
      },
      qa_findings: [],
      visual_findings: [],
      counters: {rework: 0, escalations: 0, verify_retries: 0},
      limits: {
        max_rework: $max_rework,
        max_escalations: $max_escalations,
        max_verify_retries: $max_verify_retries
      },
      budget: {
        max_total_spawns: $max_total,
        max_planner_runs: $max_planner,
        max_researcher_runs: $max_researcher,
        max_builder_expert_runs: $max_expert,
        max_reviewer_runs: $max_reviewer_runs,
        max_qa_runs: $max_qa,
        max_visual_runs: $max_visual
      },
      metrics: $prev_metrics,
      context: $prev_context,
      events: $prev_events
    }')"

  if [ "$qa_req" = false ]; then
    harness="$(echo "$harness" | jq '.gates.QA = {status:"SKIPPED",reason:"requirements.qa=false"}')"
  fi
  if [ "$visual_req" = false ]; then
    harness="$(echo "$harness" | jq '.gates.VISUAL = {status:"SKIPPED",reason:"requirements.visual=false"}')"
  fi
  if [ "$planner_req" = false ]; then
    harness="$(echo "$harness" | jq --arg c "$complexity" '.gates.PLAN = {status:"SKIPPED",reason:("complexity="+$c)}')"
  fi
  if [ "$reviewer_req" = false ]; then
    harness="$(echo "$harness" | jq --arg c "$complexity" '.gates.REVIEW = {status:"SKIPPED",reason:("complexity="+$c)}')"
  fi

  harness_put "$harness"
  harness_event "harness" "init" "route=$route complexity=$complexity qa=$qa_req visual=$visual_req planner=$planner_req reviewer=$reviewer_req"
  log "Harness initialized (route=$route, complexity=$complexity, qa=$qa_req, visual=$visual_req, phase=PLANNED)"
  harness_get
}

cmd_harness_phase() {
  harness_require
  local to="${1:-}"
  [ -z "$to" ] && { err "harness phase requires <STATE>"; exit 1; }

  case "$to" in
    PLANNED|RESEARCHING|BUILDING|ESCALATED|VERIFYING|REVIEWING|QA|VISUAL_REVIEW|REWORK|DONE|FAILED) ;;
    *) err "Invalid phase: $to"; exit 1 ;;
  esac

  local from
  from="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].harness.phase' "$STATE_FILE")"

  if [ "$from" = "$to" ]; then
    log "Harness already in phase $to"
    return 0
  fi

  if ! harness_phase_allowed "$from" "$to"; then
    err "Illegal phase transition: $from -> $to"
    exit 1
  fi

  if [ "$to" = "VERIFYING" ]; then
    harness_tasks_reconciled || exit 1
    if ! jq -e --argjson idx "$GOAL_IDX" \
      '.[$idx].harness.gates.ANALYSIS.status == "PASS"' "$STATE_FILE" >/dev/null; then
      err "VERIFYING rejected — ANALYSIS is not PASS. Run 'goal-git.sh analyze' once after the reconciled implementation batch."
      exit 1
    fi
  fi

  state_mutate --argjson idx "$GOAL_IDX" --arg to "$to" \
    '.[$idx].harness.phase = $to'
  [ "$to" != REWORK ] || harness_invalidate "rework entered"
  harness_event "harness" "phase" "$from -> $to"
  groups_persist_active 2>/dev/null || true
  log "Harness phase: $from -> $to"
}

cmd_harness_task_add() {
  harness_require
  local role="${1:-}" title="${2:-}" parent=""
  shift 2 || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --parent) parent="${2:-}"; shift 2 ;;
      *) err "Unknown harness task add arg: $1"; exit 1 ;;
    esac
  done

  [ -z "$role" ] || [ -z "$title" ] && { err "harness task add requires <role> <title>"; exit 1; }

  local phase
  phase="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].harness.phase' "$STATE_FILE")"
  harness_phase_allows_task_add "$role" "$phase" || exit 1

  local id
  id="$(jq -r --argjson idx "$GOAL_IDX" '
    .[$idx].harness.tasks | length as $n
    | "t" + (($n + 1) | tostring)
  ' "$STATE_FILE")"

  local parent_json="null"
  [ -n "$parent" ] && parent_json="$(jq -n --arg p "$parent" '$p')"

  state_mutate --argjson idx "$GOAL_IDX" \
    --arg id "$id" \
    --arg role "$role" \
    --arg title "$title" \
    --argjson parent "$parent_json" \
    '.[$idx].harness.tasks += [{
      id: $id,
      parent: $parent,
      role: $role,
      title: $title,
      state: "PENDING",
      attempts: 0
    }]'

  case "$role" in builder|builder-expert) harness_invalidate "new implementation task" ;; esac
  harness_event "harness" "task_add" "$id role=$role"
  groups_persist_active 2>/dev/null || true
  printf '%s\n' "$id"
}

cmd_harness_task_set() {
  harness_require
  local id="${1:-}" state="${2:-}"
  [ -z "$id" ] || [ -z "$state" ] && { err "harness task set requires <id> <state>"; exit 1; }

  case "$state" in
    PENDING|SPAWNING|RUNNING|DONE|BLOCKED|FAILED) ;;
    *) err "Task state must be: PENDING, SPAWNING, RUNNING, DONE, BLOCKED, or FAILED"; exit 1 ;;
  esac

  if ! jq -e --argjson idx "$GOAL_IDX" --arg id "$id" \
    '.[$idx].harness.tasks | any(.id == $id)' "$STATE_FILE" >/dev/null; then
    err "Unknown task id: $id"
    exit 1
  fi

  if [ "$state" = RUNNING ] || [ "$state" = DONE ]; then
    jq -e --argjson idx "$GOAL_IDX" --arg id "$id" --arg state "$state" '
      any((.[$idx].harness.spawn_reservations // [])[];
        .task == $id and .agent_id != null and
        (if $state == "DONE" then .state == "completed" else .state == "confirmed" end))
    ' "$STATE_FILE" >/dev/null || { goal_error missing_agent "Use spawn-confirm/spawn-finish for task $id"; return 1; }
  fi
  state_mutate --argjson idx "$GOAL_IDX" --arg id "$id" --arg state "$state" '
    .[$idx].harness.tasks |= map(
      if .id == $id then
        .state = $state
        | if $state == "RUNNING" then .attempts += 1 else . end
      else . end
    )
  '

  harness_event "harness" "task_set" "$id=$state"
  groups_persist_active 2>/dev/null || true
  log "Task $id -> $state"
}

harness_impl_tasks_ready() {
  # Returns 0 if at least one builder/builder-expert task exists and all are DONE.
  local info
  info="$(jq -r --argjson idx "$GOAL_IDX" '
    .[$idx].harness.tasks as $t
    | ($t | map(select(.role == "builder" or .role == "builder-expert"))) as $impl
    | {
        count: ($impl | length),
        not_done: ($impl | map(select(.state != "DONE")) | map("\(.id)=\(.state)") | join(", "))
      }
    | "\(.count)\t\(.not_done)"
  ' "$STATE_FILE")"
  local count not_done
  jq -e --argjson idx "$GOAL_IDX" '
    .[$idx].harness as $h | all($h.tasks[] | select(.role == "builder" or .role == "builder-expert");
      . as $t | any(($h.spawn_reservations // [])[]; .task == $t.id and .agent_id == $t.agent_id and .state == "completed"))
  ' "$STATE_FILE" >/dev/null || { goal_error missing_agent "Builder tasks require confirmed completed agents"; return 1; }
  count="$(echo "$info" | cut -f1)"
  not_done="$(echo "$info" | cut -f2-)"
  if [ "${count:-0}" -eq 0 ]; then
    err "IMPLEMENTATION PASS requires at least one builder/builder-expert task"
    return 1
  fi
  if [ -n "$not_done" ]; then
    err "IMPLEMENTATION PASS rejected — incomplete tasks: $not_done"
    return 1
  fi
  return 0
}

harness_review_evidence_ok() {
  local mode
  mode="$(config_read review_mode)"; mode="${mode:-inline}"
  harness_review_verdict_ok || return
  case "$mode" in
    local)
      if ! (cmd_review_pending >/dev/null 2>&1); then
        err "REVIEW PASS rejected — review pending reports unresolved findings (or no review file). Record UNKNOWN if evidence unavailable."
        return 1
      fi
      ;;
    *)
      if ! (cmd_pending >/dev/null 2>&1); then
        err "REVIEW PASS rejected — pending reports unresolved threads (or PR/gh unavailable). Record UNKNOWN if evidence unavailable."
        return 1
      fi
      ;;
  esac
  return 0
}

harness_discovery_context_ok() {
  # When Planner ran (or is required), discovery_context must be persisted.
  local planner_req
  planner_req="$(jq -r --argjson idx "$GOAL_IDX" \
    'if .[$idx].harness.requirements.planner == false then false else true end' "$STATE_FILE")"
  if [ "$planner_req" != "true" ]; then
    return 0
  fi
  if ! jq -e --argjson idx "$GOAL_IDX" \
    '.[$idx].harness.context.discovery_context
     | type == "object" or (type == "string" and length > 0)' \
    "$STATE_FILE" >/dev/null 2>&1; then
    err "Gate rejected — discovery_context missing (run: harness context put discovery_context)"
    return 1
  fi
  return 0
}

harness_qa_evidence_ok() {
  local req total failed qa_runs
  req="$(jq -r --arg repo "${GOAL_REPO:-.}" --argjson idx "$GOAL_IDX" '.[$idx].harness.requirements.qa // false' "$STATE_FILE")"
  if [ "$req" != "true" ]; then
    err "QA PASS rejected — requirements.qa is false"
    return 1
  fi
  harness_completed_role qa || return
  qa_runs="$(jq -r --arg repo "${GOAL_REPO:-.}" --argjson idx "$GOAL_IDX" '.[$idx].harness.metrics.qa_runs // 0' "$STATE_FILE")"
  if [ "${qa_runs:-0}" -lt 1 ]; then
    err "QA PASS rejected — QA agent was not spawned (harness spawn qa + @qa). Do not forge scenarios."
    return 1
  fi
  total="$(jq -r --arg repo "${GOAL_REPO:-.}" --argjson idx "$GOAL_IDX" '(.[$idx].harness.qa_findings // [] | map(select((.repo // ".") == $repo))) | length' "$STATE_FILE")"
  failed="$(jq -r --arg repo "${GOAL_REPO:-.}" --argjson idx "$GOAL_IDX" \
    '(.[$idx].harness.qa_findings // [] | map(select((.repo // ".") == $repo))) | group_by(.scenario) | map(.[-1]) | map(select(.result == "FAIL" and .resolved != true)) | length' \
    "$STATE_FILE")"
  if [ "${total:-0}" -eq 0 ]; then
    err "QA PASS rejected — no QA scenarios recorded (run harness qa add)"
    return 1
  fi
  if [ "${failed:-0}" -ne 0 ]; then
    err "QA PASS rejected — $failed open failing scenario(s) (harness qa pending; latest result per scenario, unresolved FAILs only)"
    return 1
  fi
  local sha; sha=$(implementation_fingerprint) || return
  jq -e --arg repo "${GOAL_REPO:-.}" --argjson idx "$GOAL_IDX" --arg sha "$sha" '
    (.[$idx].harness.qa_findings // [] | map(select((.repo // ".") == $repo))) | group_by(.scenario) | map(.[-1]) | all(.[]; .sha == $sha)
  ' "$STATE_FILE" >/dev/null || { goal_error stale_evidence "scenario observations belong to an older commit"; return 1; }
  return 0
}

harness_visual_evidence_ok() {
  local req total failed visual_runs
  req="$(jq -r --arg repo "${GOAL_REPO:-.}" --argjson idx "$GOAL_IDX" '.[$idx].harness.requirements.visual // false' "$STATE_FILE")"
  if [ "$req" != "true" ]; then
    err "VISUAL PASS rejected — requirements.visual is false"
    return 1
  fi
  harness_completed_role visual-reviewer || return
  visual_runs="$(jq -r --arg repo "${GOAL_REPO:-.}" --argjson idx "$GOAL_IDX" '.[$idx].harness.metrics.visual_runs // 0' "$STATE_FILE")"
  if [ "${visual_runs:-0}" -lt 1 ]; then
    err "VISUAL PASS rejected — Visual agent was not spawned (harness spawn visual-reviewer + @visual-reviewer)"
    return 1
  fi
  total="$(jq -r --arg repo "${GOAL_REPO:-.}" --argjson idx "$GOAL_IDX" '.[$idx].harness.visual_findings // [] | length' "$STATE_FILE")"
  failed="$(jq -r --arg repo "${GOAL_REPO:-.}" --argjson idx "$GOAL_IDX" \
    '((.[$idx].harness.visual_findings // [] | map(select((.repo // ".") == $repo))) | group_by(.viewport) | map(.[-1]) | map(select(.result == "FAIL" and .resolved != true)) | length)' \
    "$STATE_FILE")"
  if [ "${total:-0}" -eq 0 ]; then
    err "VISUAL PASS rejected — no visual observations recorded (run harness visual add)"
    return 1
  fi
  if [ "${failed:-0}" -ne 0 ]; then
    err "VISUAL PASS rejected — $failed open failing observation(s) (harness visual pending; latest result per viewport, unresolved FAILs only)"
    return 1
  fi
  local sha; sha=$(implementation_fingerprint) || return
  jq -e --arg repo "${GOAL_REPO:-.}" --argjson idx "$GOAL_IDX" --arg sha "$sha" '
    (.[$idx].harness.visual_findings // [] | map(select((.repo // ".") == $repo))) | group_by(.viewport) | map(.[-1]) | all(.[]; .sha == $sha)
  ' "$STATE_FILE" >/dev/null || { goal_error stale_evidence "viewport observations belong to an older commit"; return 1; }
  return 0
}

# Slots that must remain free for required agents not yet spawned.
# Excludes the role currently being spawned when it is itself reserved.
harness_spawn_reserved_remaining() {
  local spawning_role="${1:-}"
  jq -r --argjson idx "$GOAL_IDX" --arg role "$spawning_role" '
    .[$idx].harness as $h
    | ($h.requirements // {}) as $r
    | ($h.metrics // {}) as $m
    | 0
      + (if ($r.qa == true) and (($m.qa_runs // 0) == 0) and ($role != "qa") then 1 else 0 end)
      + (if ($r.visual == true) and (($m.visual_runs // 0) == 0) and ($role != "visual-reviewer") then 1 else 0 end)
  ' "$STATE_FILE"
}

cmd_harness_gate() {
  harness_require
  local name="${1:-}" status="${2:-}" reason="${3:-}"
  [ -z "$name" ] || [ -z "$status" ] && { err "harness gate requires <NAME> <STATUS> [reason]"; exit 1; }

  case "$name" in
    PLAN|IMPLEMENTATION|ANALYSIS|VERIFICATION|REVIEW|QA|VISUAL) ;;
    *) err "Unknown gate: $name"; exit 1 ;;
  esac

  case "$status" in
    NOT_RUN|PASS|FAIL|SKIPPED|UNKNOWN) ;;
    *) err "Gate status must be: NOT_RUN, PASS, FAIL, SKIPPED, UNKNOWN"; exit 1 ;;
  esac

  if [ "$status" = "FAIL" ] || [ "$status" = "SKIPPED" ]; then
    [ -z "$reason" ] && { err "FAIL and SKIPPED require a reason"; exit 1; }
  fi

  # Evidence-backed PASS checks
  if [ "$status" = "PASS" ]; then
    case "$name" in
      PLAN)
        harness_discovery_context_ok || exit 1
        ;;
      IMPLEMENTATION)
        harness_impl_tasks_ready || exit 1
        harness_discovery_context_ok || exit 1
        ;;
      ANALYSIS)
        if [ "${HARNESS_GATE_SOURCE:-}" != "analyze" ]; then
          err "ANALYSIS PASS may only be set by 'analyze' (gitnexus analyze + rtk gain), not manually"
          exit 1
        fi
        ;;
      VERIFICATION)
        if [ "${HARNESS_GATE_SOURCE:-}" != "verify" ]; then
          err "VERIFICATION PASS may only be set by 'verify run' (not manually)"
          exit 1
        fi
        ;;
      REVIEW)
        harness_review_evidence_ok || exit 1
        ;;
      QA)
        harness_qa_evidence_ok || exit 1
        ;;
      VISUAL)
        harness_visual_evidence_ok || exit 1
        ;;
    esac
  fi

  local sha=""
  if [ "$status" = PASS ] && [ "$name" != PLAN ] && [ "$name" != IMPLEMENTATION ]; then sha=$(implementation_fingerprint) || return; fi
  if [ -n "$reason" ]; then
    state_mutate --argjson idx "$GOAL_IDX" --arg name "$name" --arg status "$status" --arg sha "$sha" --arg reason "$reason" \
      '.[$idx].harness.gates[$name] = {status: $status, reason: $reason, sha:$sha}'
  else
    state_mutate --argjson idx "$GOAL_IDX" --arg name "$name" --arg status "$status" --arg sha "$sha" \
      '.[$idx].harness.gates[$name] = {status: $status, sha:$sha}'
  fi

  case "$name" in ANALYSIS|VERIFICATION|REVIEW|QA|VISUAL)
    state_mutate --argjson idx "$GOAL_IDX" --arg repo "${GOAL_REPO:-.}" --arg name "$name" '
      .[$idx].harness.repo_gates[$repo][$name] = .[$idx].harness.gates[$name]
    ' || return ;;
  esac
  harness_event "harness" "gate" "$name=$status${reason:+ ($reason)}"
  log "Gate $name -> $status"
}

cmd_harness_retry() {
  harness_require
  local counter="${1:-}"
  [ -z "$counter" ] && { err "harness retry requires <rework|escalations|verify_retries>"; exit 1; }

  local field limit_field
  case "$counter" in
    rework) field="rework"; limit_field="max_rework" ;;
    escalations) field="escalations"; limit_field="max_escalations" ;;
    verify_retries) field="verify_retries"; limit_field="max_verify_retries" ;;
    *) err "counter must be: rework, escalations, or verify_retries"; exit 1 ;;
  esac

  local next limit
  next="$(jq -r --argjson idx "$GOAL_IDX" --arg f "$field" \
    '.[$idx].harness.counters[$f] + 1' "$STATE_FILE")"
  limit="$(jq -r --argjson idx "$GOAL_IDX" --arg lf "$limit_field" \
    '.[$idx].harness.limits[$lf]' "$STATE_FILE")"

  state_mutate --argjson idx "$GOAL_IDX" --arg f "$field" --argjson n "$next" \
    '.[$idx].harness.counters[$f] = $n'

  harness_event "harness" "retry" "$field=$next (limit=$limit)"

  if [ "$next" -gt "$limit" ]; then
    state_mutate --argjson idx "$GOAL_IDX" --arg counter "$field" --argjson next "$next" --argjson limit "$limit" '
      .[$idx].harness.phase = "FAILED"
      | .[$idx].harness.blocker = {kind:"retry_budget",counter:$counter,attempt:$next,limit:$limit}
    ' || return
    err "Retry limit exceeded for $field: $next > $limit; state saved, stop and adjust the plan explicitly"
    return 1
  fi

  log "Retry $field: $next / $limit"
}

cmd_harness_qa_add() {
  harness_require
  local scenario="${1:-}" result="${2:-}" note="${3:-}"
  [ -z "$scenario" ] || [ -z "$result" ] && { err "harness qa add requires <scenario> <PASS|FAIL> <note>"; exit 1; }
  case "$result" in
    PASS|FAIL) ;;
    *) err "QA result must be PASS or FAIL"; exit 1 ;;
  esac
  [ -z "$note" ] && note=""

  local observed_sha
  observed_sha=$(implementation_fingerprint) || return
  local id
  id="$(jq -r --argjson idx "$GOAL_IDX" '
    .[$idx].harness.qa_findings | length as $n
    | "q" + (($n + 1) | tostring)
  ' "$STATE_FILE")"

  state_mutate --argjson idx "$GOAL_IDX" \
    --arg repo "${GOAL_REPO:-.}" --arg sha "$observed_sha" \
    --arg id "$id" \
    --arg scenario "$scenario" \
    --arg result "$result" \
    --arg note "$note" \
    '
    .[$idx].harness.qa_findings = (
      (.[$idx].harness.qa_findings // [])
      | map(
          if $result == "PASS" and .scenario == $scenario and (.repo // ".") == $repo and .result == "FAIL" and .resolved != true
          then . + {resolved: true, superseded_by: $id}
          else .
          end
        )
      + [{id: $id, scenario: $scenario, result: $result, note: $note, sha:$sha, repo:$repo}]
    )'

  harness_event "harness" "qa" "$id $result $scenario"
  printf '%s\n' "$id"
}

cmd_harness_qa_pending() {
  harness_require
  local failed
  failed="$(jq -r --arg repo "${GOAL_REPO:-.}" --argjson idx "$GOAL_IDX" \
    '(.[$idx].harness.qa_findings // [] | map(select((.repo // ".") == $repo))) | group_by(.scenario) | map(.[-1]) | map(select(.result == "FAIL" and .resolved != true)) | length' \
    "$STATE_FILE")"
  jq --arg repo "${GOAL_REPO:-.}" --argjson idx "$GOAL_IDX" '
    ((.[$idx].harness.qa_findings // [] | map(select((.repo // ".") == $repo))) | group_by(.scenario) | map(.[-1])) as $latest
    | {
        total: ((.[$idx].harness.qa_findings // [] | map(select((.repo // ".") == $repo))) | length),
        failed: ($latest | map(select(.result == "FAIL" and .resolved != true)) | length),
        latest: $latest
      }
  ' "$STATE_FILE"
  [ "$failed" -eq 0 ] || exit 1
}

cmd_harness_qa_resolve() {
  harness_require
  local id="${1:-}"
  [ -z "$id" ] && { err "harness qa resolve requires <id>"; exit 1; }
  local found
  found="$(jq -r --argjson idx "$GOAL_IDX" --arg id "$id" \
    '[.[$idx].harness.qa_findings[]? | select(.id == $id)] | length' "$STATE_FILE")"
  if [ "${found:-0}" -eq 0 ]; then
    err "QA finding not found: $id"
    exit 1
  fi
  state_mutate --argjson idx "$GOAL_IDX" --arg id "$id" \
    '.[$idx].harness.qa_findings = [.[$idx].harness.qa_findings[] | if .id == $id then . + {resolved: true} else . end]'
  harness_event "harness" "qa_resolve" "$id"
  log "Resolved QA finding $id (historical row kept)"
}

cmd_harness_visual_add() {
  harness_require
  local viewport="${1:-}" result="${2:-}" note="${3:-}"
  [ -z "$viewport" ] || [ -z "$result" ] && { err "harness visual add requires <viewport> <PASS|FAIL> <note>"; exit 1; }
  case "$result" in
    PASS|FAIL) ;;
    *) err "Visual result must be PASS or FAIL"; exit 1 ;;
  esac
  [ -z "$note" ] && note=""

  local observed_sha
  observed_sha=$(implementation_fingerprint) || return
  local id
  id="$(jq -r --argjson idx "$GOAL_IDX" '
    (.[$idx].harness.visual_findings // []) | length as $n
    | "v" + (($n + 1) | tostring)
  ' "$STATE_FILE")"

  state_mutate --argjson idx "$GOAL_IDX" \
    --arg repo "${GOAL_REPO:-.}" --arg sha "$observed_sha" \
    --arg id "$id" \
    --arg viewport "$viewport" \
    --arg result "$result" \
    --arg note "$note" \
    '
    .[$idx].harness.visual_findings = (
      (.[$idx].harness.visual_findings // [])
      | map(
          if $result == "PASS" and .viewport == $viewport and (.repo // ".") == $repo and .result == "FAIL" and .resolved != true
          then . + {resolved: true, superseded_by: $id}
          else .
          end
        )
      + [{id: $id, viewport: $viewport, result: $result, note: $note, sha:$sha, repo:$repo}]
    )'

  harness_event "harness" "visual" "$id $result $viewport"
  printf '%s\n' "$id"
}

cmd_harness_visual_pending() {
  harness_require
  local failed
  failed="$(jq -r --arg repo "${GOAL_REPO:-.}" --argjson idx "$GOAL_IDX" \
    '((.[$idx].harness.visual_findings // [] | map(select((.repo // ".") == $repo))) | group_by(.viewport) | map(.[-1]) | map(select(.result == "FAIL" and .resolved != true)) | length)' \
    "$STATE_FILE")"
  jq --arg repo "${GOAL_REPO:-.}" --argjson idx "$GOAL_IDX" '
    ((.[$idx].harness.visual_findings // [] | map(select((.repo // ".") == $repo))) | group_by(.viewport) | map(.[-1])) as $latest
    | {
        total: ((.[$idx].harness.visual_findings // [] | map(select((.repo // ".") == $repo))) | length),
        failed: ($latest | map(select(.result == "FAIL" and .resolved != true)) | length),
        latest: $latest
      }
  ' "$STATE_FILE"
  [ "$failed" -eq 0 ] || exit 1
}

cmd_harness_visual_resolve() {
  harness_require
  local id="${1:-}"
  [ -z "$id" ] && { err "harness visual resolve requires <id>"; exit 1; }
  local found
  found="$(jq -r --argjson idx "$GOAL_IDX" --arg id "$id" \
    '[(.[$idx].harness.visual_findings // [])[] | select(.id == $id)] | length' "$STATE_FILE")"
  if [ "${found:-0}" -eq 0 ]; then
    err "Visual finding not found: $id"
    exit 1
  fi
  state_mutate --argjson idx "$GOAL_IDX" --arg id "$id" \
    '.[$idx].harness.visual_findings = [((.[$idx].harness.visual_findings // [])[]) | if .id == $id then . + {resolved: true} else . end]'
  harness_event "harness" "visual_resolve" "$id"
  log "Resolved visual finding $id (historical row kept)"
}

cmd_harness_status() {
  harness_require
  harness_get
}

cmd_harness_event() {
  # Agent-facing: never fails the caller
  local agent="${1:-}" event="${2:-}" detail="${3:-}"
  if [ -z "$agent" ] || [ -z "$event" ]; then
    # Still exit 0 — malformed milestone must not break an agent turn
    return 0
  fi
  shift 2 || true
  if [ $# -gt 0 ]; then
    detail="$*"
  fi
  harness_event "$agent" "$event" "$detail"
  return 0
}

harness_humanize_event() {
  # stdin: snake_case event → "Title case with spaces"
  local e="$1"
  echo "$e" | sed 's/_/ /g' | awk '{
    for (i = 1; i <= NF; i++) {
      $i = toupper(substr($i,1,1)) tolower(substr($i,2))
    }
    print
  }'
}

harness_humanize_agent() {
  local a="$1"
  case "$a" in
    main) echo "MAIN" ;;
    orchestrator) echo "Orchestrator" ;;
    planner) echo "Planner" ;;
    researcher) echo "Researcher" ;;
    builder) echo "Builder" ;;
    builder-expert) echo "Builder Expert" ;;
    reviewer) echo "Reviewer" ;;
    qa) echo "QA" ;;
    visual-reviewer) echo "Visual Reviewer" ;;
    harness) echo "Harness" ;;
    *) echo "$a" | awk '{print toupper(substr($0,1,1)) substr($0,2)}' ;;
  esac
}

cmd_harness_progress() {
  local limit=20 json=false
  while [ $# -gt 0 ]; do
    case "$1" in
      -n)
        limit="${2:-20}"
        shift 2
        ;;
      --json)
        json=true
        shift
        ;;
      *)
        err "Unknown harness progress arg: $1"
        exit 1
        ;;
    esac
  done

  if [ ! -f "$STATE_FILE" ]; then
    err "No state found"
    exit 1
  fi
  require_cmd jq
  refresh_goal_idx

  if [ "$json" = true ]; then
    if jq -e --argjson idx "$GOAL_IDX" '.[$idx].harness' "$STATE_FILE" >/dev/null 2>&1; then
      jq --argjson idx "$GOAL_IDX" --argjson n "$limit" \
        '.[$idx].harness.events[-$n:]' "$STATE_FILE"
    else
      echo '[]'
    fi
    return 0
  fi

  local issue phase branch
  issue="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].issue.number // empty' "$STATE_FILE")"
  branch="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch // empty' "$STATE_FILE")"
  phase="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].harness.phase // "—"' "$STATE_FILE" 2>/dev/null || echo "—")"

  if [ -n "$issue" ]; then
    echo "Issue #$issue"
  elif [ -n "$branch" ]; then
    echo "Goal: $branch"
  else
    echo "Goal: (active)"
  fi
  echo "Phase: $phase"
  echo ""

  local mode
  mode="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].delivery_mode // empty' "$STATE_FILE")"
  if [ "$mode" = "multi-pr" ]; then
    echo "Delivery groups:"
    jq -r --argjson idx "$GOAL_IDX" '
      .[$idx].delivery_groups // [] | .[] |
      "  \(.id) [\(.status // "planned")] \(.task_type // "?") \(.branch // "")  deps=[\((.depends_on // []) | join(","))]  phase=\(.harness.phase // "—")"
    ' "$STATE_FILE"
    echo ""
  fi

  # Normalize legacy {ts,event} and typed {at,agent,event,issue,detail}
  local events
  events="$(jq -c --argjson idx "$GOAL_IDX" --argjson n "$limit" '
    (.[$idx].harness.events // []) as $ev
    | ($ev | length) as $len
    | ($ev[([0, $len - $n] | max):])
    | map(
        if has("agent") then
          {
            at: (.at // .ts // ""),
            agent: .agent,
            event: .event,
            detail: (.detail // "")
          }
        else
          {
            at: (.ts // .at // ""),
            agent: "harness",
            event: "legacy",
            detail: (.event // "")
          }
        end
      )
  ' "$STATE_FILE" 2>/dev/null || echo '[]')"

  if [ "$(echo "$events" | jq 'length')" -eq 0 ]; then
    echo "(no events yet)"
    return 0
  fi

  echo "$events" | jq -r '.[] | [.at, .agent, .event, .detail] | @tsv' | while IFS=$'\t' read -r at agent event detail; do
    clock="$(echo "$at" | sed -E 's/.*T([0-9]{2}:[0-9]{2}:[0-9]{2}).*/\1/')"
    [ "$clock" = "$at" ] && clock="--:--:--"
    label="$(harness_humanize_agent "$agent")"
    if [ "$event" = "legacy" ]; then
      human="$detail"
      detail=""
    else
      human="$(harness_humanize_event "$event")"
    fi
    if [ -n "$detail" ]; then
      printf '%-8s  %-14s  %s — %s\n' "$clock" "$label" "$human" "$detail"
    else
      printf '%-8s  %-14s  %s\n' "$clock" "$label" "$human"
    fi
  done
}

cmd_harness_hook() {
  # Read Codex hook JSON from stdin. Emit START/END event. Print JSON for SubagentStop.
  require_cmd jq
  local payload
  payload="$(cat)"
  if [ -z "$payload" ]; then
    # SubagentStop requires valid JSON on exit 0
    echo '{"continue":true}'
    return 0
  fi

  local hook_event agent_type agent_id last_msg first_line
  hook_event="$(echo "$payload" | jq -r '.hook_event_name // empty')"
  agent_type="$(echo "$payload" | jq -r '.agent_type // "unknown"')"
  agent_id="$(echo "$payload" | jq -r '.agent_id // empty')"
  last_msg="$(echo "$payload" | jq -r '.last_assistant_message // empty')"
  first_line="$(echo "$last_msg" | head -n 1 | tr '\n' ' ' | cut -c1-120)"

  case "$hook_event" in
    SubagentStart)
      harness_event "$agent_type" "started" "${agent_id:+id=$agent_id}"
      # async Start may ignore stdout; still emit valid JSON
      echo '{"continue":true}'
      ;;
    SubagentStop)
      harness_event "$agent_type" "completed" "${first_line:-id=$agent_id}"
      jq -n --arg msg "${agent_type} completed${first_line:+: $first_line}" \
        '{continue: true, systemMessage: $msg}'
      ;;
    *)
      harness_event "${agent_type:-hook}" "hook" "$hook_event"
      echo '{"continue":true}'
      ;;
  esac
  return 0
}

cmd_harness_done() {
  harness_require

  harness_require_current_evidence || return
  jq -e --argjson idx "$GOAL_IDX" '.[$idx] |
    .harness.phase != "FAILED" and
    all(.harness.tasks[]?; .state == "DONE") and
    all((.harness.spawn_reservations // [])[]; .state == "failed" or (.state == "completed" and .closed == true))' "$STATE_FILE" >/dev/null || {
    goal_error incomplete "Harness is failed, tasks remain, or agents/reservations are still active"; return 1;
  }
  local required
  required="$(jq -c --argjson idx "$GOAL_IDX" '
    .[$idx].harness.requirements as $r
    | (if ($r.planner == false) then [] else ["PLAN"] end)
      + ["IMPLEMENTATION","ANALYSIS","VERIFICATION"]
      + (if ($r.reviewer == false) then [] else ["REVIEW"] end)
      + (if ($r.qa == true) then ["QA"] else [] end)
      + (if ($r.visual == true) then ["VISUAL"] else [] end)
  ' "$STATE_FILE")"

  local blockers
  blockers="$(jq -c --argjson idx "$GOAL_IDX" --argjson req "$required" '
    .[$idx].harness.gates as $g
    | $req
    | map(
        . as $name
        | $g[$name] as $gate
        | if ($gate.status == "PASS") then empty
          elif ($gate.status == "SKIPPED" and ($name == "PLAN" or $name == "REVIEW")) then empty
          else {gate: $name, status: ($gate.status // "NOT_RUN"), reason: ($gate.reason // "")}
          end
      )
  ' "$STATE_FILE")"

  local count
  count="$(echo "$blockers" | jq 'length')"
  if [ "$count" -gt 0 ]; then
    err "Definition of DONE not met — blocking gates:"
    echo "$blockers" | jq .
    exit 1
  fi

  local phase
  phase="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].harness.phase' "$STATE_FILE")"
  if [ "$phase" != "DONE" ]; then
    if harness_phase_allowed "$phase" "DONE"; then
      state_mutate --argjson idx "$GOAL_IDX" '.[$idx].harness.phase = "DONE"'
      harness_event "harness" "phase" "$phase -> DONE (harness done)"
    else
      err "Cannot mark DONE from phase $phase — transition to DONE first or fix gates"
      exit 1
    fi
  fi

  log "Harness DONE — all required gates passed"
  harness_get
}



# Reviewer and QA must keep spawning until findings are clean. Grow the
# role cap and total spawn cap instead of stopping with findings still open.


cmd_harness_budget_set() {
  harness_require
  local key="${1:-}" val="${2:-}"
  [ -z "$key" ] || [ -z "$val" ] && { err "harness budget set requires <key> <n>"; exit 1; }
  case "$key" in
    max_total_spawns|max_planner_runs|max_researcher_runs|max_builder_expert_runs|max_reviewer_runs|max_qa_runs|max_visual_runs) ;;
    *) err "Unknown budget key: $key"; exit 1 ;;
  esac
  if ! [[ "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 1 ]; then
    err "budget value must be a positive integer"
    exit 1
  fi
  state_mutate --argjson idx "$GOAL_IDX" --arg k "$key" --argjson v "$val" \
    '.[$idx].harness.budget[$k] = $v'
  harness_event "harness" "budget_set" "$key=$val"
  log "Budget $key -> $val"
  jq --argjson idx "$GOAL_IDX" '.[$idx].harness.budget' "$STATE_FILE"
}

cmd_harness_metrics() {
  harness_require
  jq --argjson idx "$GOAL_IDX" '{metrics: .[$idx].harness.metrics, budget: .[$idx].harness.budget, complexity: .[$idx].harness.complexity}' "$STATE_FILE"
}

cmd_harness_context_put() {
  harness_require
  local name="${1:-}" src="${2:--}"
  [ -z "$name" ] && { err "harness context put requires <name> [file|-]"; exit 1; }
  case "$name" in
    discovery_context|implementation_plan|research_report|repo_context|queue_plan|review_verdict) ;;
    *) err "Unknown context name: $name (allowed: discovery_context, implementation_plan, research_report, repo_context, queue_plan, review_verdict)"; exit 1 ;;
  esac

  local payload
  if [ "$src" = "-" ] || [ -z "$src" ]; then
    payload="$(cat)"
  else
    [ -f "$src" ] || { err "Context file not found: $src"; exit 1; }
    payload="$(cat "$src")"
  fi
  echo "$payload" | jq -e . >/dev/null || { err "Context payload must be valid JSON"; exit 1; }

  # Also mirror discovery_context / repo_context to .codex/ for reuse
  mkdir -p "$PROJECT_ROOT/.codex"
  case "$name" in
    discovery_context) printf '%s\n' "$payload" > "$PROJECT_ROOT/.codex/discovery-context.json" ;;
    repo_context) printf '%s\n' "$payload" > "$PROJECT_ROOT/.codex/repo-context.json" ;;
    queue_plan) printf '%s\n' "$payload" > "$PROJECT_ROOT/.codex/queue-plan.json" ;;
  esac

  state_mutate --argjson idx "$GOAL_IDX" --arg repo "${GOAL_REPO:-.}" --arg name "$name" --argjson payload "$payload" \
    '.[$idx].harness.context[$name] = $payload
      | if $name == "review_verdict" then .[$idx].harness.context.repo_review_verdict[$repo] = $payload else . end'
  harness_event "harness" "context_put" "$name"
  log "Stored harness context: $name"
}

cmd_harness_context_get() {
  harness_require
  local name="${1:-}"
  [ -z "$name" ] && { err "harness context get requires <name>"; exit 1; }
  jq --argjson idx "$GOAL_IDX" --arg name "$name" \
    '.[$idx].harness.context[$name] // empty' "$STATE_FILE"
}

cmd_harness() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    init) cmd_harness_init "$@" ;;
    phase) cmd_harness_phase "$@" ;;
    task)
      case "${1:-}" in
        add) shift; cmd_harness_task_add "$@" ;;
        set) shift; cmd_harness_task_set "$@" ;;
        *) err "harness task subcommand must be add or set"; exit 1 ;;
      esac
      ;;
    gate) cmd_harness_gate "$@" ;;
    retry) cmd_harness_retry "$@" ;;
    qa)
      case "${1:-}" in
        add) shift; cmd_harness_qa_add "$@" ;;
        pending) cmd_harness_qa_pending ;;
        resolve) shift; cmd_harness_qa_resolve "$@" ;;
        *) err "harness qa subcommand must be add, pending, or resolve"; exit 1 ;;
      esac
      ;;
    visual)
      case "${1:-}" in
        add) shift; cmd_harness_visual_add "$@" ;;
        pending) cmd_harness_visual_pending ;;
        resolve) shift; cmd_harness_visual_resolve "$@" ;;
        *) err "harness visual subcommand must be add, pending, or resolve"; exit 1 ;;
      esac
      ;;
    status) cmd_harness_status ;;
    event) cmd_harness_event "$@" ;;
    progress) cmd_harness_progress "$@" ;;
    hook) cmd_harness_hook "$@" ;;
    spawn) cmd_harness_spawn "$@" ;;
    spawn-confirm) cmd_harness_spawn_confirm "$@" ;;
    spawn-fail) cmd_harness_spawn_fail "$@" ;;
    spawn-finish) cmd_harness_spawn_finish "$@" ;;
    metrics) cmd_harness_metrics ;;
    budget)
      case "${1:-}" in
        set) shift; cmd_harness_budget_set "$@" ;;
        *) err "harness budget subcommand must be set"; exit 1 ;;
      esac
      ;;
    context)
      case "${1:-}" in
        put) shift; cmd_harness_context_put "$@" ;;
        get) shift; cmd_harness_context_get "$@" ;;
        *) err "harness context subcommand must be put or get"; exit 1 ;;
      esac
      ;;
    done) cmd_harness_done ;;
    recover-spawn) cmd_harness_recover_spawn ;;
    *) err "harness subcommand must be: init, phase, task, gate, retry, qa, visual, event, progress, hook, spawn, metrics, budget, context, status, done, recover-spawn"; exit 1 ;;
  esac
}

# --- Verify ---

verify_detect_checks() {
  local wd="$1"
  local checks='[]'

  if [ -f "$CONFIG_FILE" ]; then
    local override
    override="$(jq -c '.verify_commands // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    if [ -n "$override" ] && [ "$override" != "null" ] && [ "$override" != "[]" ]; then
      echo "$override"
      return 0
    fi
  fi

  add_check() {
    local name="$1" cmd="$2"
    checks="$(echo "$checks" | jq -c --arg n "$name" --arg c "$cmd" '. + [{name: $n, cmd: $c}]')"
  }

  if [ -f "$wd/package.json" ]; then
    local pkg_mgr="npm run"
    [ -f "$wd/pnpm-lock.yaml" ] && pkg_mgr="pnpm run"
    [ -f "$wd/yarn.lock" ] && pkg_mgr="yarn"
    if [ -f "$wd/bun.lockb" ] || [ -f "$wd/bun.lock" ]; then
      pkg_mgr="bun run"
    fi
    for script in build test lint typecheck "format:check"; do
      if jq -e --arg s "$script" '.scripts[$s]' "$wd/package.json" >/dev/null 2>&1; then
        if [ "$pkg_mgr" = "yarn" ]; then
          add_check "$script" "yarn $script"
        else
          add_check "$script" "$pkg_mgr $script"
        fi
      fi
    done
  fi

  if [ -f "$wd/go.mod" ]; then
    if command -v go >/dev/null 2>&1; then
      add_check "go-build" "go build ./..."
      add_check "go-test" "go test ./..."
      add_check "go-vet" "go vet ./..."
    fi
  fi

  if [ -f "$wd/Cargo.toml" ]; then
    if command -v cargo >/dev/null 2>&1; then
      add_check "cargo-build" "cargo build"
      add_check "cargo-test" "cargo test"
      add_check "cargo-clippy" "cargo clippy -- -D warnings"
      add_check "cargo-fmt" "cargo fmt --check"
    fi
  fi

  if [ -f "$wd/pyproject.toml" ] || [ -f "$wd/pytest.ini" ] || [ -d "$wd/tests" ]; then
    command -v pytest >/dev/null 2>&1 && add_check "pytest" "pytest"
    command -v ruff >/dev/null 2>&1 && add_check "ruff" "ruff check"
    command -v mypy >/dev/null 2>&1 && add_check "mypy" "mypy ."
  fi

  if [ -f "$wd/pom.xml" ]; then
    command -v mvn >/dev/null 2>&1 && add_check "maven-verify" "mvn -q -B verify"
  fi

  if [ -f "$wd/gradlew" ]; then
    add_check "gradle-build" "./gradlew build test"
  elif [ -f "$wd/build.gradle" ] || [ -f "$wd/build.gradle.kts" ]; then
    command -v gradle >/dev/null 2>&1 && add_check "gradle-build" "gradle build test"
  fi

  if [ -f "$wd/Makefile" ]; then
    for t in build test lint; do
      if grep -qE "^${t}:" "$wd/Makefile" 2>/dev/null; then
        add_check "make-$t" "make $t"
      fi
    done
  fi

  if [ -f "$wd/composer.json" ]; then
    for script in test lint; do
      if jq -e --arg s "$script" '.scripts[$s]' "$wd/composer.json" >/dev/null 2>&1; then
        add_check "composer-$script" "composer $script"
      fi
    done
  fi

  echo "$checks"
}

cmd_verify_detect() {
  require_cmd jq
  refresh_goal_idx
  local wd
  wd="$(goal_workdir)"
  verify_detect_checks "$wd" | jq .
}

cmd_verify_run() {
  require_cmd jq
  refresh_goal_idx
  local wd only=""
  wd="$(repo_dir "${GOAL_REPO:-.}")"
  local verified_sha
  verified_sha=$(implementation_fingerprint) || return

  while [ $# -gt 0 ]; do
    case "$1" in
      --only)
        only="${2:-}"
        shift 2
        ;;
      *)
        err "Unknown verify run arg: $1"
        exit 1
        ;;
    esac
  done

  local checks full_count
  checks="$(verify_detect_checks "$wd")"
  full_count=$(printf '%s' "$checks" | jq length)

  if [ -n "$only" ]; then
    checks="$(echo "$checks" | jq -c --arg only "$only" '
      ($only | split(",")) as $want
      | map(select(.name as $n | $want | index($n)))
    ')"
  fi

  local count
  count="$(echo "$checks" | jq "length")"
  if [ "$count" -eq 0 ]; then
    warn "No verification checks detected"
    if [ -f "$STATE_FILE" ] && jq -e --argjson idx "$GOAL_IDX" '.[$idx].harness' "$STATE_FILE" >/dev/null 2>&1; then
      cmd_harness_gate VERIFICATION UNKNOWN "no checks detected"
    fi
    echo '{"overall":"UNKNOWN","results":[]}'
    exit 1
  fi

  local results='[]'
  local overall="PASS"
  [ "$count" -eq "$full_count" ] || overall="UNKNOWN"
  local i=0
  while [ "$i" -lt "$count" ]; do
    local name cmd
    name="$(echo "$checks" | jq -r --argjson i "$i" '.[$i].name')"
    cmd="$(echo "$checks" | jq -r --argjson i "$i" '.[$i].cmd')"

    log "verify: $name → $cmd"
    local outfile exit_code status suggested
    outfile="$(mktemp)"
    set +e
    (cd "$wd" && bash -c "$cmd") >"$outfile" 2>&1
    exit_code=$?
    set -e

    if [ "$exit_code" -eq 0 ]; then
      status="PASS"
      suggested="none"
    elif [ "$exit_code" -eq 127 ]; then
      status="UNKNOWN"
      suggested="install missing tooling or set verify_commands in goal-config.json"
      [ "$overall" = "PASS" ] && overall="UNKNOWN"
    else
      status="FAIL"
      overall="FAIL"
      suggested="fix failing check then re-run verify"
    fi

    local tail_out
    tail_out="$(tail -n 40 "$outfile" | tr "\n" " " | cut -c1-500)"
    rm -f "$outfile"

    printf "%s | %s | exit=%s | %s | %s | %s\n" \
      "$name" "$cmd" "$exit_code" "$status" "$name" "$suggested" >&2

    results="$(echo "$results" | jq -c \
      --arg name "$name" \
      --arg cmd "$cmd" \
      --argjson code "$exit_code" \
      --arg status "$status" \
      --arg affected "$name" \
      --arg suggested "$suggested" \
      --arg output "$tail_out" \
      '. + [{name:$name,command:$cmd,exit:$code,status:$status,affected:$affected,suggested:$suggested,output:$output}]')"

    i=$((i + 1))
  done

  local report
  report="$(jq -n --arg sha "$verified_sha" --arg overall "$overall" --argjson results "$results" \
    '{sha:$sha,overall: $overall, results: $results}')"
  echo "$report" | jq .

  if [ -f "$STATE_FILE" ] && jq -e --argjson idx "$GOAL_IDX" '.[$idx].harness' "$STATE_FILE" >/dev/null 2>&1; then
    state_mutate --arg repo "${GOAL_REPO:-.}" --argjson idx "$GOAL_IDX" --argjson report "$report" '.[$idx].harness.context.verification_report = $report | .[$idx].harness.context.verification_reports[$repo] = $report'
    case "$overall" in
      PASS) HARNESS_GATE_SOURCE=verify cmd_harness_gate VERIFICATION PASS ;;
      FAIL) HARNESS_GATE_SOURCE=verify cmd_harness_gate VERIFICATION FAIL "one or more checks failed" ;;
      UNKNOWN) HARNESS_GATE_SOURCE=verify cmd_harness_gate VERIFICATION UNKNOWN "one or more checks unknown" ;;
    esac
  fi

  [ "$overall" = "PASS" ] || exit 1
}

cmd_verify() {
  case "${1:-}" in
    detect) cmd_verify_detect ;;
    run) shift; cmd_verify_run "$@" ;;
    *) err "verify subcommand must be detect or run"; exit 1 ;;
  esac
}

# --- Route ---

cmd_route_detect() {
  require_cmd git jq
  [ ! -f "$STATE_FILE" ] && { err "No state found — run 'start' first"; exit 1; }
  state_ensure_array
  refresh_goal_idx

  local base files figma_enabled qa_mode visual_mode
  base="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].base_branch // "main"' "$STATE_FILE")"
  figma_enabled="$(config_read figma_enabled)"; figma_enabled="${figma_enabled:-false}"
  qa_mode="$(config_read qa_mode)"; qa_mode="${qa_mode:-auto}"
  visual_mode="$(config_read visual_mode)"; visual_mode="${visual_mode:-auto}"

  local wd
  wd="$(goal_workdir)"
  files="$(cd "$wd" && (git diff --name-only "origin/$base...HEAD" 2>/dev/null || git diff --name-only "$base...HEAD" 2>/dev/null || true))"

  local ui=0 business=0
  local evidence=""
  local biz_re='/(api|routes|controllers|handlers|resolvers|graphql|services|usecases|domain|features|workflows|migrations)/|(openapi|swagger)|schema\.prisma|\.proto$'
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if echo "$f" | grep -qiE '\.(tsx|jsx|vue|svelte|css|scss|sass|less|html)$|/(components|pages|views|ui|app)/'; then
      ui=1
      if [ -z "$evidence" ]; then
        evidence="$f"
      else
        evidence="$evidence, $f"
      fi
    elif echo "$f" | grep -qiE "$biz_re"; then
      business=1
      if [ -z "$evidence" ]; then
        evidence="$f"
      else
        evidence="$evidence, $f"
      fi
    fi
  done <<< "$files"

  local route="backend"
  local reasons=""

  add_reason() {
    if [ -z "$reasons" ]; then
      reasons="$1"
    else
      reasons="$reasons,$1"
    fi
  }

  if [ "$visual_mode" = "always" ] || [ "$figma_enabled" = "true" ] || [ "$ui" -eq 1 ]; then
    if [ "$visual_mode" != "never" ]; then
      route="frontend"
      [ "$ui" -eq 1 ] && add_reason "ui_files"
      [ "$figma_enabled" = "true" ] && add_reason "figma_enabled"
      [ "$visual_mode" = "always" ] && add_reason "visual_mode=always"
    fi
  fi

  if [ "$route" != "frontend" ]; then
    if [ "$qa_mode" = "always" ]; then
      route="feature"
      add_reason "qa_mode=always"
    elif [ "$qa_mode" = "never" ]; then
      route="backend"
      add_reason "qa_mode=never"
    elif [ "$business" -eq 1 ]; then
      route="feature"
      add_reason "business_paths"
    elif [ -n "$files" ]; then
      route="backend"
      add_reason "internal_non_ui"
    else
      route="backend"
      add_reason "no_diff_default_backend"
    fi
  fi

  local figma_json
  figma_json="$([ "$figma_enabled" = "true" ] && echo true || echo false)"

  jq -n \
    --arg route "$route" \
    --arg evidence "${evidence:-none}" \
    --arg reasons "$reasons" \
    --arg qa_mode "$qa_mode" \
    --arg visual_mode "$visual_mode" \
    --argjson figma_enabled "$figma_json" \
    '{
      route: $route,
      baseline: true,
      evidence: $evidence,
      reasons: $reasons,
      qa_mode: $qa_mode,
      visual_mode: $visual_mode,
      figma_enabled: $figma_enabled
    }'
}

cmd_route() {
  case "${1:-}" in
    detect) cmd_route_detect ;;
    *) err "route subcommand must be detect"; exit 1 ;;
  esac
}

cmd_codex_ensure_user_config() {
  local codex_home="${CODEX_HOME:-$HOME/.codex}"
  local cfg="$codex_home/config.toml"
  mkdir -p "$codex_home"

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found — appending Codex trust to $cfg"
    if ! grep -qF "[projects.\"$PROJECT_ROOT\"]" "$cfg"; then
      printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$PROJECT_ROOT" >> "$cfg"
    fi
    log "Wrote $cfg (fallback). Start a NEW Codex session so it loads."
    return 0
  fi

  GOAL_PROJECT_ROOT="$PROJECT_ROOT" python3 - "$cfg" <<'PY'
import os, pathlib, re, sys

cfg_path = pathlib.Path(sys.argv[1])
project = os.environ["GOAL_PROJECT_ROOT"]
text = cfg_path.read_text() if cfg_path.exists() else ""

escaped = project.replace("\\", "\\\\").replace('"', '\\"')
header = f'[projects."{escaped}"]'
block_re = re.compile(r"(?ms)^" + re.escape(header) + r"[^\[]*")
m = block_re.search(text)
if m:
    block = m.group(0)
    if re.search(r"(?m)^trust_level\s*=", block):
        new_block = re.sub(r'(?m)^trust_level\s*=\s*.*$', 'trust_level = "trusted"', block, count=1)
    else:
        new_block = block.rstrip() + '\ntrust_level = "trusted"\n'
    text = text[: m.start()] + new_block + text[m.end() :]
else:
    if text and not text.endswith("\n"):
        text += "\n"
    text += f'\n{header}\ntrust_level = "trusted"\n'

cfg_path.write_text(text)
print(str(cfg_path))
PY

  log "Ensured $cfg has trust_level=trusted for $PROJECT_ROOT (existing max_depth preserved)"
}

# shellcheck source=delivery-groups.sh
for module in forge goal-context delivery-groups goal-delivery goal-delegation goal-evidence; do
  [ -f "$SCRIPTS_DIR/$module.sh" ] || { err "Missing workflow module: $module.sh; reinstall the Codex template"; exit 1; }
  . "$SCRIPTS_DIR/$module.sh"
done
context_init "${1:-help}" "${2:-}"


case "${1:-}" in
  help|--help|-h) usage ;;
  context) cmd_context ;;
  doctor) cmd_doctor ;;
  start)    shift; cmd_start "$@" ;;
  continue) cmd_continue "${2:-}" ;;
  list)     cmd_list ;;
  stage)    shift; cmd_stage "$@" ;;
  commit)   cmd_commit "${2:-}" ;;
  push)     cmd_push ;;
  pr)       shift; cmd_pr "$@" ;;
  pending)  cmd_pending "${2:-}" ;;
  threads)  cmd_threads "${2:-}" ;;
  comment)  cmd_comment "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
  resolve)  cmd_resolve "${2:-}" "${3:-}" ;;
  analyze)  cmd_analyze ;;
  verify)   shift; cmd_verify "$@" ;;
  route)    shift; cmd_route "$@" ;;
  harness)  shift; cmd_harness "$@" ;;
  groups)   shift; cmd_groups "$@" ;;
  codex)
    case "${2:-}" in
      ensure-user-config) cmd_codex_ensure_user_config ;;
      *) err "codex subcommand must be ensure-user-config"; exit 1 ;;
    esac
    ;;
  config)
    case "${2:-}" in
      set) cmd_config_set "${3:-}" "${4:-}" "${5:-}" "${6:-1}" "${7:-false}" "${8:-inline}" "${9:-2}" "${10:-3}" "${11:-2}" "${12:-3}" "${13:-auto}" "${14:-auto}" ;;
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
      sync)   cmd_worktree_sync "${3:-}" ;;
      merge)  cmd_worktree_merge "${3:-}" ;;
      remove) cmd_worktree_remove "${3:-}" ;;
      *)      err "worktree subcommand must be add, list, sync, merge, or remove"; exit 1 ;;
    esac
    ;;
  selfcheck) cmd_selfcheck ;;
  models)   shift; cmd_models "$@" ;;
  complexity)
    case "${2:-}" in
      classify) shift 2; cmd_complexity_classify "$@" ;;
      *) err "complexity subcommand must be classify"; exit 1 ;;
    esac
    ;;
  issues)
    case "${2:-}" in
      list)   cmd_issues_list "${3:-}" "${4:-}" ;;
      start)  shift 2; cmd_issues_start "$@" ;;
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
