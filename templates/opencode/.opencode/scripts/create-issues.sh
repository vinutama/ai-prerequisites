#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/.opencode/goal-config.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[issues]${NC} $*"; }
warn() { echo -e "${YELLOW}[issues]${NC} $*" >&2; }
err()  { echo -e "${RED}[issues]${NC} $*" >&2; }

usage() {
  cat <<EOF
Usage: create-issues.sh <command> [args]

Commands:
  parse <file.md>              Parse markdown into JSON issue array
  create <file.md> [flags]     Create issues on GitHub or GitLab
  status [flags]               Show platform, repo, and CLI auth state

Create flags:
  --repo <owner/repo>          Override target repository
  --platform github|gitlab     Override platform detection
  --label <name>               Extra label on every issue (repeatable)
  --milestone <name>           Default milestone when a block omits one
  --dry-run                    Print commands without creating issues
  --allow-duplicates           Skip duplicate-title check

Status flags:
  --repo <owner/repo>
  --platform github|gitlab
EOF
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }
}

cd "$PROJECT_ROOT"

config_read() {
  local field="$1"
  if [ -f "$CONFIG_FILE" ]; then
    jq -r --arg f "$field" '.[$f] // empty' "$CONFIG_FILE" 2>/dev/null || true
  fi
}

detect_platform() {
  local remote_url
  remote_url=$(git remote get-url origin 2>/dev/null || true)
  case "$remote_url" in
    *gitlab* | *@gitlab.*) echo "gitlab" ;;
    *github* | *@github.*) echo "github" ;;
    *) echo "unknown" ;;
  esac
}

resolve_platform() {
  local override="${1:-}"
  local platform=""
  if [ -n "$override" ]; then
    platform="$override"
  elif [ -n "${GOAL_PLATFORM:-}" ]; then
    platform="$GOAL_PLATFORM"
  else
    platform="$(config_read platform)"
    [ -z "$platform" ] && platform="$(detect_platform)"
  fi
  case "$platform" in
    github|gitlab) echo "$platform" ;;
    unknown)
      err "Cannot detect platform. Pass --platform github|gitlab, set GOAL_PLATFORM, or run /init-goal"
      exit 1
      ;;
    *)
      err "Invalid platform: $platform (expected github or gitlab)"
      exit 1
      ;;
  esac
}

require_vcs_cli() {
  local platform="$1"
  case "$platform" in
    github) require_cmd gh ;;
    gitlab) require_cmd glab ;;
  esac
}

# Parse markdown ## blocks into normalized JSON via awk + jq.
parse_markdown_file() {
  local file="$1"
  [ -f "$file" ] || { err "File not found: $file"; exit 1; }

  local tmp_records
  tmp_records=$(mktemp)
  local issue_count=0

  awk '
    BEGIN {
      in_issue = 0
      in_meta = 0
      body = ""
      labels = ""
      assignees = ""
      milestone = ""
      title = ""
      count = 0
    }

    function trim(s) {
      sub(/^[ \t\r\n]+/, "", s)
      sub(/[ \t\r\n]+$/, "", s)
      return s
    }

    function flush_issue(   i, line) {
      if (title == "") return
      count++
      print "TITLE\t" title
      print "LABELS\t" labels
      print "ASSIGNEES\t" assignees
      print "MILESTONE\t" milestone
      n = split(body, lines, "\n")
      for (i = 1; i <= n; i++) {
        print "BODY\t" lines[i]
      }
      print "END"
      title = ""
      body = ""
      labels = ""
      assignees = ""
      milestone = ""
      in_meta = 0
    }

    function append_body(line) {
      if (body == "") body = line
      else body = body "\n" line
    }

    /^## / {
      flush_issue()
      title = trim(substr($0, 4))
      in_issue = 1
      in_meta = 1
      next
    }

    in_issue && in_meta {
      if ($0 ~ /^Labels?:[ \t]*/) {
        labels = trim(substr($0, index($0, ":") + 1))
        next
      }
      if ($0 ~ /^Assignees?:[ \t]*/) {
        assignees = trim(substr($0, index($0, ":") + 1))
        next
      }
      if ($0 ~ /^Milestone:[ \t]*/) {
        milestone = trim(substr($0, index($0, ":") + 1))
        next
      }
      in_meta = 0
    }

    in_issue {
      append_body($0)
    }

    END {
      flush_issue()
      if (count == 0) exit 2
    }
  ' "$file" > "$tmp_records" 2>/dev/null || {
    rm -f "$tmp_records"
    err "No ## headings found in $file"
    err "Expected one issue per ## heading. See .opencode/skills/create-issues/SKILL.md"
    exit 1
  }

  if ! grep -q '^TITLE' "$tmp_records" 2>/dev/null; then
    rm -f "$tmp_records"
    err "No ## headings found in $file"
    err "Expected one issue per ## heading. See .opencode/skills/create-issues/SKILL.md"
    exit 1
  fi

  local issues_json="[]"
  local cur_title="" cur_labels="" cur_assignees="" cur_milestone="" cur_body=""
  local line key val

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "END" ]; then
      cur_body="${cur_body%$'\n'}"
      issues_json=$(jq -n \
        --argjson arr "$issues_json" \
        --arg title "$cur_title" \
        --arg body "$cur_body" \
        --arg labels_raw "$cur_labels" \
        --arg assignees_raw "$cur_assignees" \
        --arg milestone "$cur_milestone" \
        '$arr + [{
          title: $title,
          body: $body,
          labels: (if $labels_raw == "" then [] else ($labels_raw | split(",") | map(gsub("^[ \t]+|[ \t]+$"; "")) | map(select(length > 0))) end),
          assignees: (if $assignees_raw == "" then [] else ($assignees_raw | split(",") | map(gsub("^[ \t]+|[ \t]+$"; "")) | map(select(length > 0))) end),
          milestone: (if $milestone == "" then null else $milestone end)
        }]')
      issue_count=$((issue_count + 1))
      cur_title="" cur_labels="" cur_assignees="" cur_milestone="" cur_body=""
      continue
    fi
    key="${line%%$'\t'*}"
    val="${line#*$'\t'}"
    case "$key" in
      TITLE) cur_title="$val" ;;
      LABELS) cur_labels="$val" ;;
      ASSIGNEES) cur_assignees="$val" ;;
      MILESTONE) cur_milestone="$val" ;;
      BODY)
        if [ -z "$cur_body" ]; then cur_body="$val"; else cur_body="${cur_body}"$'\n'"${val}"; fi
        ;;
    esac
  done < "$tmp_records"

  rm -f "$tmp_records"

  if [ "$issue_count" -eq 0 ]; then
    err "No ## headings found in $file"
    err "Expected one issue per ## heading. See .opencode/skills/create-issues/SKILL.md"
    exit 1
  fi

  echo "$issues_json"
}

cmd_parse() {
  local file="${1:-}"
  [ -z "$file" ] && { err "parse requires <file.md>"; usage; }
  require_cmd jq
  parse_markdown_file "$file"
}

fetch_existing_titles() {
  local platform="$1"
  local repo="${2:-}"
  case "$platform" in
    github)
      local args=(issue list --state all --limit 200 --json title)
      [ -n "$repo" ] && args+=(--repo "$repo")
      gh "${args[@]}" | jq -r '.[].title'
      ;;
    gitlab)
      local args=(issue list --all --per-page 100 --output json)
      [ -n "$repo" ] && args+=(--repo "$repo")
      glab "${args[@]}" | jq -r '.[].title'
      ;;
  esac
}

title_is_duplicate() {
  local title="$1"
  grep -Fxq "$title" "$EXISTING_TITLES_FILE" 2>/dev/null
}

shell_quote() {
  printf '%s' "$1" | jq -Rs .
}

build_create_cmd() {
  local platform="$1"
  local title="$2"
  local body="$3"
  local repo="${4:-}"
  shift 4
  local -a extra_labels=("$@")
  local labels_json="${LABELS_JSON:-[]}"
  local assignees_json="${ASSIGNEES_JSON:-[]}"
  local milestone="${MILESTONE_VAL:-}"

  local cmd=""
  local qtitle
  qtitle=$(shell_quote "$title")

  case "$platform" in
    github)
      cmd="gh issue create --title ${qtitle}"
      cmd+=" --body-file <body-file>"
      local label
      while IFS= read -r label; do
        [ -z "$label" ] && continue
        cmd+=" --label $(shell_quote "$label")"
      done < <(echo "$labels_json" | jq -r '.[]')
      local assignee
      while IFS= read -r assignee; do
        [ -z "$assignee" ] && continue
        cmd+=" --assignee $(shell_quote "$assignee")"
      done < <(echo "$assignees_json" | jq -r '.[]')
      if [ -n "$milestone" ]; then
        cmd+=" --milestone $(shell_quote "$milestone")"
      fi
      if [ -n "$repo" ]; then
        cmd+=" --repo $(shell_quote "$repo")"
      fi
      ;;
    gitlab)
      local qbody
      qbody=$(shell_quote "$body")
      cmd="glab issue create --title ${qtitle} --description ${qbody} --yes"
      while IFS= read -r label; do
        [ -z "$label" ] && continue
        cmd+=" --label $(shell_quote "$label")"
      done < <(echo "$labels_json" | jq -r '.[]')
      while IFS= read -r assignee; do
        [ -z "$assignee" ] && continue
        cmd+=" --assignee $(shell_quote "$assignee")"
      done < <(echo "$assignees_json" | jq -r '.[]')
      if [ -n "$milestone" ]; then
        cmd+=" --milestone $(shell_quote "$milestone")"
      fi
      if [ -n "$repo" ]; then
        cmd+=" --repo $(shell_quote "$repo")"
      fi
      ;;
  esac
  echo "$cmd"
}

create_one_issue() {
  local platform="$1"
  local title="$2"
  local body="$3"
  local repo="${4:-}"
  local labels_json="$5"
  local assignees_json="$6"
  local milestone="${7:-}"

  LABELS_JSON="$labels_json"
  ASSIGNEES_JSON="$assignees_json"
  MILESTONE_VAL="$milestone"

  if [ "$DRY_RUN" = true ]; then
    build_create_cmd "$platform" "$title" "$body" "$repo"
    return 0
  fi

  local -a gh_args=(issue create --title "$title")
  local -a gl_args=(issue create --title "$title" --yes)
  local label assignee

  case "$platform" in
    github)
      local body_file
      body_file=$(mktemp)
      printf '%s' "$body" > "$body_file"
      gh_args+=(--body-file "$body_file")
      while IFS= read -r label; do
        [ -z "$label" ] && continue
        gh_args+=(--label "$label")
      done < <(echo "$labels_json" | jq -r '.[]')
      while IFS= read -r assignee; do
        [ -z "$assignee" ] && continue
        gh_args+=(--assignee "$assignee")
      done < <(echo "$assignees_json" | jq -r '.[]')
      [ -n "$milestone" ] && gh_args+=(--milestone "$milestone")
      [ -n "$repo" ] && gh_args+=(--repo "$repo")
      local url
      if url=$(gh "${gh_args[@]}" 2>&1); then
        rm -f "$body_file"
        echo "$url"
        return 0
      else
        rm -f "$body_file"
        err "$url"
        return 1
      fi
      ;;
    gitlab)
      gl_args+=(--description "$body")
      while IFS= read -r label; do
        [ -z "$label" ] && continue
        gl_args+=(--label "$label")
      done < <(echo "$labels_json" | jq -r '.[]')
      while IFS= read -r assignee; do
        [ -z "$assignee" ] && continue
        gl_args+=(--assignee "$assignee")
      done < <(echo "$assignees_json" | jq -r '.[]')
      [ -n "$milestone" ] && gl_args+=(--milestone "$milestone")
      [ -n "$repo" ] && gl_args+=(--repo "$repo")
      local out
      if out=$(glab "${gl_args[@]}" 2>&1); then
        echo "$out" | grep -Eo 'https?://[^ ]+' | head -1 || echo "$out"
        return 0
      else
        err "$out"
        return 1
      fi
      ;;
  esac
}

cmd_create() {
  local file="${1:-}"
  shift || true
  [ -z "$file" ] && { err "create requires <file.md>"; usage; }

  local repo="" platform_override="" default_milestone=""
  DRY_RUN=false
  ALLOW_DUPLICATES=false
  local -a global_labels=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --platform) platform_override="${2:-}"; shift 2 ;;
      --label) global_labels+=("${2:-}"); shift 2 ;;
      --milestone) default_milestone="${2:-}"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      --allow-duplicates) ALLOW_DUPLICATES=true; shift ;;
      -h|--help) usage ;;
      *) err "Unknown flag: $1"; usage ;;
    esac
  done

  require_cmd jq
  local platform
  platform="$(resolve_platform "$platform_override")"
  require_vcs_cli "$platform"

  local issues_json
  issues_json=$(parse_markdown_file "$file")
  local count
  count=$(echo "$issues_json" | jq 'length')

  EXISTING_TITLES_FILE=""
  if [ "$ALLOW_DUPLICATES" = false ] && [ "$DRY_RUN" = false ]; then
    EXISTING_TITLES_FILE=$(mktemp)
    fetch_existing_titles "$platform" "$repo" > "$EXISTING_TITLES_FILE" || true
  fi

  local created=0 skipped=0 failed=0
  local i title body labels_json assignees_json milestone merged_labels extra_labels_json

  for ((i = 0; i < count; i++)); do
    title=$(echo "$issues_json" | jq -r ".[$i].title")
    body=$(echo "$issues_json" | jq -r ".[$i].body")
    labels_json=$(echo "$issues_json" | jq -c ".[$i].labels")
    assignees_json=$(echo "$issues_json" | jq -c ".[$i].assignees")
    milestone=$(echo "$issues_json" | jq -r ".[$i].milestone // empty")

    if [ ${#global_labels[@]} -gt 0 ]; then
      extra_labels_json=$(printf '%s\n' "${global_labels[@]}" | jq -R . | jq -s .)
    else
      extra_labels_json='[]'
    fi
    merged_labels=$(echo "$labels_json" | jq -c --argjson extra "$extra_labels_json" '$extra + . | unique')
    [ -z "$milestone" ] && milestone="$default_milestone"

    if [ "$ALLOW_DUPLICATES" = false ] && [ "$DRY_RUN" = false ] && [ -n "${EXISTING_TITLES_FILE:-}" ]; then
      if title_is_duplicate "$title"; then
        log "skipped (duplicate): $title"
        skipped=$((skipped + 1))
        continue
      fi
    fi

    if [ "$DRY_RUN" = true ]; then
      LABELS_JSON="$merged_labels"
      ASSIGNEES_JSON="$assignees_json"
      MILESTONE_VAL="$milestone"
      log "dry-run: $title"
      build_create_cmd "$platform" "$title" "$body" "$repo" | sed 's/<body-file>/<temp-body-file>/'
      created=$((created + 1))
      continue
    fi

    local url
    if url=$(create_one_issue "$platform" "$title" "$body" "$repo" "$merged_labels" "$assignees_json" "$milestone"); then
      log "created $url"
      created=$((created + 1))
    else
      warn "failed: $title"
      failed=$((failed + 1))
    fi
  done

  [ -n "${EXISTING_TITLES_FILE:-}" ] && rm -f "$EXISTING_TITLES_FILE"

  if [ "$DRY_RUN" = true ]; then
    log "dry-run complete: $count issue(s) — no issues created"
    return 0
  fi

  log "summary: created=$created skipped=$skipped failed=$failed"
  [ "$failed" -gt 0 ] && exit 1
}

cmd_status() {
  local repo="" platform_override=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --platform) platform_override="${2:-}"; shift 2 ;;
      *) err "Unknown flag: $1"; usage ;;
    esac
  done

  require_cmd jq
  local platform
  platform="$(resolve_platform "$platform_override")"

  log "platform: $platform"
  if [ -n "$repo" ]; then
    log "repo: $repo (override)"
  else
    log "repo: (default — inferred by gh/glab from cwd remote)"
  fi

  case "$platform" in
    github)
      if command -v gh >/dev/null 2>&1; then
        if gh auth status >/dev/null 2>&1; then
          log "gh auth: ok"
        else
          warn "gh auth: not authenticated (run: gh auth login)"
        fi
      else
        warn "gh: not installed"
      fi
      ;;
    gitlab)
      if command -v glab >/dev/null 2>&1; then
        if glab auth status >/dev/null 2>&1; then
          log "glab auth: ok"
        else
          warn "glab auth: not authenticated (run: glab auth login)"
        fi
      else
        warn "glab: not installed"
      fi
      ;;
  esac
}

# --- main ---

command="${1:-}"
shift || true

case "$command" in
  parse)  cmd_parse "$@" ;;
  create) cmd_create "$@" ;;
  status) cmd_status "$@" ;;
  -h|--help|"") usage ;;
  *) err "Unknown command: $command"; usage ;;
esac
