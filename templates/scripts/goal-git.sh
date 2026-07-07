#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="${STATE_FILE:-state.json}"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[goal]${NC} $*"; }
warn() { echo -e "${YELLOW}[goal]${NC} $*" >&2; }
err()  { echo -e "${RED}[goal]${NC} $*" >&2; }

usage() {
  cat <<EOF
Usage: goal-git.sh {start|commit|push|pr|pending|analyze} [args]

Commands:
  start <goal>     Create branch and write state.json
  commit [msg]     Stage all and conventional-commit
  push             Push branch to origin
  pr               Create or update the PR
  pending          Check for unresolved review threads (exit 0 = clean)
  analyze          Run gitnexus analyze && rtk gain
EOF
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }
}

cd "$PROJECT_ROOT"

detect_base() {
  gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || \
    git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}' || \
    echo "main"
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | head -c 50
}

cmd_start() {
  require_cmd gh git jq
  local goal="${1:-}"
  [ -z "$goal" ] && { err "start requires a goal description"; exit 1; }

  local base branch
  base=$(detect_base)
  branch="goal/$(slugify "$goal")"

  log "Base: $base"
  log "Branch: $branch"

  git fetch origin "$base" 2>/dev/null || true
  git checkout -b "$branch" "origin/$base" 2>/dev/null || git checkout "$branch" 2>/dev/null || true

  jq -n --arg goal "$goal" --arg branch "$branch" --arg base "$base" \
    '{goal: $goal, branch: $branch, base_branch: $base, pr_number: null, pr_url: "", status: "in_progress"}' \
    > "$STATE_FILE"
  log "state.json written"
}

cmd_commit() {
  require_cmd git
  local msg="${1:-chore: automated changes}"
  git add -A
  git diff --cached --quiet && { log "Nothing to commit"; return; }
  git commit -m "$msg"
  log "Committed: $msg"
}

cmd_push() {
  require_cmd git jq
  local branch
  branch=$(jq -r '.branch' "$STATE_FILE")
  git push -u origin "$branch" --force-with-lease 2>/dev/null || git push -u origin "$branch"
  log "Pushed: $branch"
}

cmd_pr() {
  require_cmd gh jq
  local branch base goal pr_number title owner repo
  branch=$(jq -r '.branch' "$STATE_FILE")
  base=$(jq -r '.base_branch' "$STATE_FILE")
  goal=$(jq -r '.goal' "$STATE_FILE")
  pr_number=$(jq -r '.pr_number' "$STATE_FILE")

  if [ "$pr_number" != "null" ] && [ -n "$pr_number" ]; then
    log "PR already exists: #$pr_number"
    return
  fi

  title="${goal:0:72}"
  pr_number=$(gh pr create --base "$base" --head "$branch" --title "$title" --body "Automated by /goal" --json number -q '.number')
  owner=$(gh repo view --json nameWithOwner -q '.nameWithOwner')

  jq --argjson pn "$pr_number" --arg url "https://github.com/$owner/pull/$pr_number" \
    '.pr_number = $pn | .pr_url = $url' \
    "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

  log "PR created: #$pr_number"
}

cmd_pending() {
  require_cmd gh jq
  local pr_number owner repo query result total unresolved
  pr_number=$(jq -r '.pr_number' "$STATE_FILE")

  if [ "$pr_number" = "null" ] || [ -z "$pr_number" ]; then
    err "No PR yet — run 'goal-git.sh pr' first"
    exit 1
  fi

  owner=$(gh repo view --json owner -q '.owner.login')
  repo=$(gh repo view --json name -q '.name')
  query='query($owner:String!,$repo:String!,$pr:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$pr){reviewThreads(first:100){nodes{id isResolved isOutdated comments(first:1){nodes{body}}}totalCount}}}}'

  result=$(gh api graphql -f query="$query" -F owner="$owner" -F repo="$repo" -F pr="$pr_number" 2>/dev/null || echo '{}')
  total=$(echo "$result" | jq -r '.data.repository.pullRequest.reviewThreads.totalCount // 0')
  unresolved=$(echo "$result" | jq '[.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved == false and .isOutdated == false)] | length')

  echo "{\"total\": $total, \"unresolved\": ${unresolved:-0}}"

  if [ "${unresolved:-0}" -gt 0 ]; then
    warn "$unresolved unresolved thread(s) remain — loop continues"
    exit 1
  fi

  log "No unresolved threads — PR is clean"
  exit 0
}

cmd_analyze() {
  require_cmd npx
  log "Running gitnexus analyze…"
  npx --yes gitnexus@latest analyze || { err "gitnexus analyze failed"; exit 1; }
  log "Running rtk gain…"
  rtk gain || { err "rtk gain failed"; exit 1; }
  log "Analyze complete"
}

case "${1:-}" in
  start)   cmd_start "${2:-}" ;;
  commit)  cmd_commit "${2:-}" ;;
  push)    cmd_push ;;
  pr)      cmd_pr ;;
  pending) cmd_pending ;;
  analyze) cmd_analyze ;;
  *)       usage ;;
esac
