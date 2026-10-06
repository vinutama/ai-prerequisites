#!/usr/bin/env bash
# Sourceable Bash 3.2+ forge adapter. No caller globals, traps or shell options.
# Metadata: null means proven absence; nonzero means uncertainty. Upsert emits
# fresh metadata only, and never retries a write. Callers must check its status.

forge_error() {
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg category "$1" --arg message "$2" \
      '{forge_error:{category:$category,message:$message}}' >&2
  else
    printf '%s\n' '{"forge_error":{"category":"dependency","message":"jq required"}}' >&2
  fi
  return 1
}

forge_cache_dir() {
  if [ -z "${FORGE_CACHE_DIR:-}" ]; then
    if [ -n "${PROJECT_ROOT:-}" ]; then
      FORGE_CACHE_DIR="$PROJECT_ROOT/${AGENT_CONFIG_DIR:-.codex}/cache/forge"
    else
      # Stable even when the first call happens inside command substitution.
      FORGE_CACHE_DIR="${TMPDIR:-/tmp}/codex-forge-${UID}"
    fi
  fi
  (umask 077; mkdir -p "$FORGE_CACHE_DIR") || return 1
}

forge_identity() {
  local executable version
  executable=$(type -P "$1") || { forge_error dependency "Missing executable: $1"; return 1; }
  version=$(command "$1" --version 2>/dev/null) || return 1
  printf '%s\n%s\n' "$executable" "$version" | cksum | awk '{print $1 "-" $2}'
}

# Accept either (cli, "mr create", flag) or (cli, mr, create, flag).
# Help is cached by executable path + version + command, including in subshells.
forge_supports() {
  local cli="${1:-}" sub="${2:-}" flag="${3:-}" key cache tmp
  [ "$#" -eq 4 ] && { sub="$2 $3"; flag="$4"; }
  case "$cli" in gh|glab) ;; *) return 1 ;; esac
  case "$sub" in *[!a-zA-Z0-9\ ]*|'') return 1 ;; esac
  case "$flag" in --[a-zA-Z]*) ;; *) return 1 ;; esac
  forge_cache_dir || return 1
  key=$(forge_identity "$cli") || return 1
  cache="$FORGE_CACHE_DIR/help-$key-${sub// /-}"
  if [ ! -f "$cache" ]; then
    tmp=$(mktemp "$FORGE_CACHE_DIR/help.XXXXXX") || return 1
    local -a words=()
    read -r -a words <<< "$sub"
    if command "$cli" "${words[@]}" --help >"$tmp" 2>/dev/null; then
      mv "$tmp" "$cache" || return 1
    else
      rm -f "$tmp"
      return 1
    fi
  fi
  # Match a flag token on a flag definition line, never prose or a longer flag.
  awk -v flag="$flag" '
    /^[[:space:]]+-/ {
      for (i=1;i<=NF;i++) { token=$i; sub(/[,=].*$/, "", token); if(token==flag) found=1 }
    }
    END { exit !found }
  ' "$cache"
}

forge_require_flags() {
  local cli="$1" sub="$2" flag
  shift 2
  for flag in "$@"; do
    forge_supports "$cli" "$sub" "$flag" || {
      forge_error capability "$cli $sub lacks $flag"; return 1;
    }
  done
}

# GraphQL uses POST even for queries. Inspect the supplied query before allowing
# a read retry; never retry a mutation mislabeled as read.
forge_graphql_read_guard() {
  local arg previous='' query='' input='' fields=false count=0
  for arg in "$@"; do
    case "$previous" in
      --input) input="$arg" ;;
      -f|-F|--field|--raw-field)
        fields=true
        case "$arg" in query=*) query="${arg#*=}"; count=$((count + 1)) ;; esac ;;
    esac
    case "$arg" in
      --input=*) input="${arg#*=}" ;;
      --field=query=*|--raw-field=query=*) fields=true; query="${arg#*query=}"; count=$((count + 1)) ;;
      -fquery=*|-Fquery=*) fields=true; query="${arg#*query=}"; count=$((count + 1)) ;;
    esac
    previous="$arg"
  done
  if [ -n "$input" ]; then
    [ "$fields" = false ] && [ "$input" != - ] && [ -r "$input" ] || return 1
    query=$(jq -er '.query | select(type=="string")' "$input") || return 1
    count=1
  fi
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$query" | grep -Eq '^[[:space:]]*(query([[:space:](]|$)|\{)' || return 1
  ! printf '%s\n' "$query" | grep -Eq '(^|[^[:alnum:]_])(mutation|subscription)([^[:alnum:]_]|$)'
}

# Passes stdout through and reproduces every attempt's stderr, followed by a
# JSON diagnostic without argv/token contents. Read transient failures retry
# twice (2s/5s); FORGE_RETRY_WAIT_OVERRIDE=0 is for deterministic tests.
# Retry-After seconds/HTTP dates are saved per executable/version + host and
# honored by subsequent calls. Writes are never retried, including rate limits.
forge_run() {
  local mode="${1:-}" cli="${2:-}" arg method=GET previous='' key blocker executable
  [ "$#" -ge 3 ] || { forge_error usage 'forge_run mode cli argv...'; return 1; }
  shift 2
  case "$mode:$cli" in read:gh|write:gh|read:glab|write:glab) ;; *) forge_error usage 'Invalid mode or CLI'; return 1 ;; esac
  command -v jq >/dev/null 2>&1 || { forge_error dependency 'jq required'; return 1; }
  local host="${GH_HOST:-github.com}"
  [ "$cli" = glab ] && host="${GITLAB_HOST:-${GLAB_HOST:-gitlab.com}}"
  for arg in "$@"; do
    case "$arg" in --web|--web=*|--browser|--show-token) forge_error policy 'Interactive/browser/token flags are forbidden'; return 1 ;; esac
    [ "$arg" != -w ] || { forge_error policy 'Short browser flag forbidden'; return 1; }
    case "$previous" in
      --method|-X) method="$arg" ;;
      --hostname) host="$arg" ;;
      --repo|-R)
        case "$arg" in
          https://*|http://*) host="${arg#*://}"; host="${host%%/*}" ;;
          *) if [ "$cli" = gh ] && [ "${arg#*/}" != "${arg##*/}" ]; then host="${arg%%/*}"; fi ;;
        esac ;;
    esac
    case "$arg" in --method=*) method="${arg#*=}" ;; -X?*) method="${arg#-X}" ;; --hostname=*) host="${arg#*=}" ;; esac
    previous="$arg"
  done
  case "$1 ${2:-}" in 'auth login'|'auth token'|'auth refresh'|'browse '*) forge_error policy 'Interactive/token command forbidden'; return 1 ;; esac
  if [ "$mode" = read ]; then
    case "$1 ${2:-}" in
      'auth status'|'pr list'|'pr view'|'mr list'|'mr view'|'issue list'|'issue view'|'repo view') ;;
      'api '*)
        if [ "$cli" = gh ] && [ "${2:-}" = graphql ]; then
          case "$method" in GET|POST) ;; *) forge_error policy 'Read GraphQL must use GET or POST'; return 1 ;; esac
          forge_graphql_read_guard "$@" || { forge_error policy 'Read GraphQL requires one query without mutations'; return 1; }
        else
          [ "$method" = GET ] || { forge_error policy 'Read API must use GET'; return 1; }
          for arg in "$@"; do
            case "$arg" in --input|--input=*|--field|--field=*|--raw-field|--raw-field=*|-f*|-F*) forge_error policy 'Read API payload forbidden'; return 1 ;; esac
          done
        fi
        ;;
      *) forge_error policy 'Unsupported read command'; return 1 ;;
    esac
  fi
  forge_cache_dir || return 1
  executable=$(type -P "$cli") || { forge_error dependency "Missing executable: $cli"; return 1; }
  key=$(forge_identity "$cli") || return 1
  key="$key-$(printf '%s' "$host" | cksum | awk '{print $1}')"
  blocker="$FORGE_CACHE_DIR/blocker-$key.json"
  FORGE_LAST_ERROR_CATEGORY=""
  local attempt=0 rc=0 category retry_after wait_seconds now until_epoch stderr blocker_tmp
  while :; do
    now=$(date +%s)
    if [ -f "$blocker" ]; then
      until_epoch=$(jq -r '.until // 0' "$blocker") || return 1
      if [ "$until_epoch" -gt "$now" ]; then
        wait_seconds=$((until_epoch - now))
        sleep "${FORGE_RETRY_WAIT_OVERRIDE:-$wait_seconds}" || return 1
      fi
    fi
    stderr=$(mktemp) || return 1
    rc=0
    # env + the executable path bypasses shell wrappers and Bash 3.2's errexit
    # bug with environment assignments on the `command` special builtin.
    env GH_PROMPT_DISABLED=1 GH_BROWSER=false BROWSER=false GLAB_BROWSER=false \
      GLAB_CHECK_UPDATE=false CI=true "$executable" "$@" </dev/null 2>"$stderr" || rc=$?
    cat "$stderr" >&2
    if [ "$rc" -eq 0 ]; then rm -f "$stderr"; return 0; fi
    category=unknown
    if grep -Eiq 'rate.?limit|HTTP 429|status.?429|retry-after' "$stderr"; then category=rate_limit
    elif grep -Eiq 'HTTP 401|status.?401|authentication|not logged|auth login|invalid.*token' "$stderr"; then category=auth
    elif grep -Eiq 'HTTP 403|status.?403|forbidden|permission denied|access denied' "$stderr"; then category=permission
    elif grep -Eiq 'HTTP 404|status.?404|not found' "$stderr"; then category=not_found
    elif grep -Eiq 'unknown flag|unknown command|unrecognized|unsupported' "$stderr"; then category=capability
    elif grep -Eiq 'HTTP 409|status.?409|already exists|conflict' "$stderr"; then category=conflict
    elif grep -Eiq 'HTTP 422|status.?422|validation|invalid argument' "$stderr"; then category=validation
    elif grep -Eiq 'timed? out|timeout|deadline exceeded' "$stderr"; then category=timeout
    elif grep -Eiq 'HTTP 5[0-9][0-9]|status.?5[0-9][0-9]|connection|network|TLS|resolve host|no such host|EOF' "$stderr"; then category=transient
    fi
    retry_after=0
    if [ "$category" = rate_limit ]; then
      arg=$(sed -nE 's/.*[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:[[:space:]]*(.*)/\1/p' "$stderr" | head -n 1 | tr -d '\r')
      case "$arg" in
        ''|*[!0-9]*)
          if [ -n "$arg" ]; then
            until_epoch=$(LC_ALL=C date -j -u -f '%a, %d %b %Y %H:%M:%S GMT' "$arg" +%s 2>/dev/null || LC_ALL=C date -u -d "$arg" +%s 2>/dev/null || printf 0)
            [ "$until_epoch" -le "$now" ] || retry_after=$((until_epoch - now))
          fi ;;
        *) retry_after=$((10#$arg)) ;;
      esac
      wait_seconds=2; [ "$attempt" -eq 0 ] || wait_seconds=5
      [ "$retry_after" -le "$wait_seconds" ] || wait_seconds="$retry_after"
      blocker_tmp=$(mktemp "$FORGE_CACHE_DIR/blocker.XXXXXX") || return 1
      jq -cn --argjson until "$((now + wait_seconds))" --argjson retry_after "$retry_after" \
        '{category:"rate_limit",until:$until,retry_after:$retry_after}' > "$blocker_tmp" || { rm -f "$blocker_tmp"; return 1; }
      mv "$blocker_tmp" "$blocker" || return 1
    fi
    FORGE_LAST_ERROR_CATEGORY="$category"
    jq -cn --arg category "$category" --arg mode "$mode" --arg cli "$cli" \
      --argjson exit_code "$rc" --argjson attempt "$((attempt + 1))" --argjson retry_after "$retry_after" \
      '{forge_error:{category:$category,mode:$mode,cli:$cli,exit_code:$exit_code,attempt:$attempt,retry_after:$retry_after,
        retryable:($mode=="read" and ($category=="transient" or $category=="timeout" or $category=="rate_limit")),
        corrective_action:(if $category=="auth" then ($cli+" auth status; ask the user to authenticate locally")
          elif $category=="permission" then "Check repository membership and token scopes; preserve state and stop"
          elif $category=="capability" then ($cli+" <command> --help; update the helper for installed capabilities")
          elif $category=="rate_limit" then "Resume after Retry-After; the blocker is saved"
          elif $mode=="write" then "Reconcile the exact remote object before any retry; never use browser fallback"
          else "Run goal-git.sh doctor --json with the same assignment" end)}}'  >&2
    rm -f "$stderr"
    [ "$mode" = read ] && [ "$attempt" -lt 2 ] || return "$rc"
    case "$category" in transient|timeout|rate_limit) ;; *) return "$rc" ;; esac
    wait_seconds=2; [ "$attempt" -eq 0 ] || wait_seconds=5
    [ "$category" = rate_limit ] || sleep "${FORGE_RETRY_WAIT_OVERRIDE:-$wait_seconds}" || return 1
    attempt=$((attempt + 1))
  done
}

# Validate one JSON document from stdin; output unchanged JSON in compact form.
# Optional jq predicate defaults to true. Reject empty/multiple documents.
forge_json() {
  local data
  data=$(jq -cs 'if length == 1 then .[0] else error("Expected one JSON document") end') || {
    forge_error invalid_json 'Invalid JSON response'; return 1;
  }
  printf '%s\n' "$data" | jq -e "${1:-true}" >/dev/null || {
    forge_error invalid_json 'Unexpected JSON response shape'; return 1;
  }
  printf '%s\n' "$data"
}

forge_description_args() {
  FORGE_DESCRIPTION_ARGS=()
  [ -f "${3:-}" ] && [ -r "$3" ] || { forge_error usage 'Readable body file required'; return 1; }
  case "$1" in
    gh) forge_require_flags gh "$2" --body-file || return 1; FORGE_DESCRIPTION_ARGS=(--body-file "$3") ;;
    glab)
      if forge_supports glab "$2" --description-file; then
        FORGE_DESCRIPTION_ARGS=(--description-file "$3")
      else
        forge_require_flags glab "$2" --description || return 1
        local content
        content=$(cat "$3"; printf '.') || return 1
        content="${content%.}"
        [ "$content" != - ] || { forge_error policy 'Description dash opens an editor'; return 1; }
        FORGE_DESCRIPTION_ARGS=(--description "$content")
      fi ;;
    *) forge_error usage 'Unknown CLI'; return 1 ;;
  esac
}

forge_repo_args() {
  FORGE_REPO_ARGS=()
  case "$1" in gh|glab) ;; *) forge_error usage 'Unknown CLI'; return 1 ;; esac
  [ -n "${2:-}" ] || return 0
  case "$2" in -*|*$'\n'*) forge_error usage 'Invalid repository'; return 1 ;; esac
  FORGE_REPO_ARGS=(--repo "$2")
}

# API host + path, preserving self hosted repositories and nested namespaces.
forge_api_repo() {
  local cli="$1" repo="$2" path
  FORGE_API_HOST=''; FORGE_API_PATH=''
  case "$repo" in
    https://*|http://*)
      path="${repo#*://}"; FORGE_API_HOST="${path%%/*}"; path="${path#*/}" ;;
    *)
      path="$repo"
      if [ "$cli" = gh ]; then
        FORGE_API_HOST="${GH_HOST:-github.com}"
        if [ "${path#*/}" != "${path##*/}" ]; then FORGE_API_HOST="${path%%/*}"; path="${path#*/}"; fi
      else
        FORGE_API_HOST="${GITLAB_HOST:-${GLAB_HOST:-gitlab.com}}"
      fi ;;
  esac
  path="${path%/}"; path="${path%.git}"
  case "$path" in */*) ;; *) forge_error usage 'Explicit repository namespace required'; return 1 ;; esac
  if [ "$cli" = glab ]; then
    FORGE_API_PATH="projects/$(jq -nr --arg path "$path" '$path|@uri')"
  else FORGE_API_PATH="repos/$path"; fi
}

# Exhaustive page aggregation, with validation before emitting any results.
forge_api_pages() {
  local cli="$1" endpoint="$2" host="$3" page=1 data all='[]' separator='?'
  case "$endpoint" in *\?*) separator='&' ;; esac
  forge_require_flags "$cli" api --hostname --method || return 1
  while :; do
    data=$(forge_run read "$cli" api "$endpoint${separator}per_page=100&page=$page" --hostname "$host" --method GET) || return 1
    data=$(printf '%s\n' "$data" | forge_json 'type == "array"') || return 1
    all=$(jq -cn --argjson all "$all" --argjson data "$data" '$all+$data') || return 1
    [ "$(jq length <<< "$data")" -eq 100 ] || break
    page=$((page + 1))
    [ "$page" -le 10000 ] || { forge_error pagination 'Pagination did not terminate'; return 1; }
  done
  printf '%s\n' "$all"
}

forge_pr_metadata() {
  local platform="${1:-}" repo="${2:-}" branch="${3:-}" base="${4:-}" cli data matches number files
  [ -n "$repo" ] && [ -n "$branch" ] && [ -n "$base" ] || { forge_error usage 'Repository, head and base required'; return 1; }
  case "$platform" in github) cli=gh ;; gitlab) cli=glab ;; *) forge_error usage 'Unknown platform'; return 1 ;; esac
  forge_repo_args "$cli" "$repo" || return 1
  forge_api_repo "$cli" "$repo" || return 1
  if [ "$cli" = gh ]; then
    forge_require_flags gh 'pr list' --head --base --state --limit --json --repo || return 1
    data=$(forge_run read gh pr list "${FORGE_REPO_ARGS[@]}" --head "$branch" --base "$base" --state open --limit 2 --json number,url,headRefName,baseRefName,state,isCrossRepository) || return 1
    data=$(printf '%s\n' "$data" | forge_json 'type=="array" and all(.[]; (.number|type)=="number" and (.headRefName|type)=="string" and (.baseRefName|type)=="string" and (.state|type)=="string" and (.isCrossRepository|type)=="boolean")') || return 1
    matches=$(jq -c --arg h "$branch" --arg b "$base" '[.[]|select(.headRefName==$h and .baseRefName==$b and .state=="OPEN")]' <<< "$data") || return 1
    if jq -e 'any(.[]; .isCrossRepository)' <<< "$matches" >/dev/null; then forge_error ambiguous 'Cross repository head requires explicit identity'; return 1; fi
  else
    forge_require_flags glab 'mr list' --source-branch --target-branch --output --page --per-page --repo || return 1
    local page=1 batch all='[]'
    while :; do
      batch=$(forge_run read glab mr list "${FORGE_REPO_ARGS[@]}" --source-branch "$branch" --target-branch "$base" --output json --per-page 100 --page "$page") || return 1
      batch=$(printf '%s\n' "$batch" | forge_json 'type=="array" and all(.[]; (.iid|type)=="number" and (.source_branch|type)=="string" and (.target_branch|type)=="string" and (.state|type)=="string" and (.source_project_id|type)=="number" and (.target_project_id|type)=="number")') || return 1
      all=$(jq -cn --argjson a "$all" --argjson b "$batch" '$a+$b') || return 1
      [ "$(jq length <<< "$batch")" -eq 100 ] || break
      page=$((page + 1))
      [ "$page" -le 10000 ] || { forge_error pagination 'Pagination did not terminate'; return 1; }
    done
    matches=$(jq -c --arg h "$branch" --arg b "$base" '[.[]|select(.source_branch==$h and .target_branch==$b and .state=="opened")]' <<< "$all") || return 1
    if jq -e 'any(.[]; .source_project_id != .target_project_id)' <<< "$matches" >/dev/null; then forge_error ambiguous 'Cross project head requires explicit identity'; return 1; fi
  fi
  case "$(jq length <<< "$matches")" in
    0) printf 'null\n'; return 0 ;;
    1) number=$(jq -r '.[0] | .number // .iid' <<< "$matches") ;;
    *) forge_error ambiguous 'Multiple open requests match head and base'; return 1 ;;
  esac
  if [ "$cli" = gh ]; then
    forge_require_flags gh 'pr view' --json --repo || return 1
    data=$(forge_run read gh pr view "$number" "${FORGE_REPO_ARGS[@]}" --json number,url,headRefName,baseRefName,headRefOid,state,isCrossRepository) || return 1
    data=$(printf '%s\n' "$data" | forge_json 'type=="object" and .isCrossRepository==false') || return 1
    files=$(forge_api_pages gh "$FORGE_API_PATH/pulls/$number/files" "$FORGE_API_HOST") || return 1
    data=$(jq -c --argjson files "$files" '{number,url,head:.headRefName,base:.baseRefName,sha:.headRefOid,state:(.state|ascii_downcase),files:[$files[].filename]}' <<< "$data") || return 1
  else
    forge_require_flags glab 'mr view' --output --repo || return 1
    data=$(forge_run read glab mr view "$number" "${FORGE_REPO_ARGS[@]}" --output json) || return 1
    data=$(printf '%s\n' "$data" | forge_json 'type=="object" and (.source_project_id|type)=="number" and .source_project_id==.target_project_id') || return 1
    files=$(forge_api_pages glab "$FORGE_API_PATH/merge_requests/$number/diffs" "$FORGE_API_HOST") || return 1
    data=$(jq -c --argjson files "$files" '{number:.iid,url:.web_url,head:.source_branch,base:.target_branch,sha:(.sha // .diff_refs.head_sha),state:(if .state=="opened" then "open" else .state end),files:[$files[]|.new_path]}' <<< "$data") || return 1
  fi
  data=$(printf '%s\n' "$data" | forge_json 'type=="object" and (.number|type)=="number" and .number>0 and (.url|type)=="string" and (.url|test("^https?://")) and (.head|type)=="string" and (.base|type)=="string" and (.sha|type)=="string" and (.sha|length)>0 and .state=="open" and (.files|type)=="array" and all(.files[]; type=="string")') || return 1
  if ! jq -e --arg h "$branch" --arg b "$base" --argjson n "$number" '.head==$h and .base==$b and .number==$n' <<< "$data" >/dev/null; then
    forge_error uncertain 'Request changed head, base or state during lookup'; return 1
  fi
  printf '%s\n' "$data"
}

forge_pr_upsert() {
  local platform="${1:-}" repo="${2:-}" branch="${3:-}" base="${4:-}" title="${5:-}" file="${6:-}"
  local before after cli sub number rc=0 pending key
  [ -n "$title" ] && [ -r "$file" ] || { forge_error usage 'Title and readable body file required'; return 1; }
  before=$(forge_pr_metadata "$platform" "$repo" "$branch" "$base") || return 1
  case "$platform" in github) cli=gh ;; gitlab) cli=glab ;; *) return 1 ;; esac
  forge_repo_args "$cli" "$repo" || return 1
  local -a args=()
  if [ "$before" = null ]; then
    if [ "$cli" = gh ]; then
      sub='pr create'
      forge_require_flags gh "$sub" --head --base --title --repo || return 1
      args=(pr create --head "$branch" --base "$base" --title "$title")
    else
      sub='mr create'
      forge_require_flags glab "$sub" --source-branch --target-branch --title --yes --repo || return 1
      args=(mr create --source-branch "$branch" --target-branch "$base" --title "$title" --yes)
    fi
  else
    number=$(jq -r .number <<< "$before") || return 1
    if [ "$cli" = gh ]; then sub='pr edit'; args=(pr edit "$number" --title "$title")
    else sub='mr update'; args=(mr update "$number" --title "$title"); fi
    forge_require_flags "$cli" "$sub" --title --repo || return 1
  fi
  forge_description_args "$cli" "$sub" "$file" || return 1
  args+=("${FORGE_DESCRIPTION_ARGS[@]}" "${FORGE_REPO_ARGS[@]}")
  forge_cache_dir || return 1
  key=$(printf '%s\n' "$platform" "$repo" "$branch" "$base" | git hash-object --stdin) || return 1
  pending="$FORGE_CACHE_DIR/create-$key.pending"
  if [ "$before" = null ]; then
    mkdir "$pending" 2>/dev/null || {
      forge_error uncertain "A previous create for this repository/head/base is unresolved; preserve its ledger and reconcile before retrying"; return 1;
    }
    jq -cn --arg repo "$repo" --arg head "$branch" --arg base "$base" --arg title "$title"       '{operation:"create",repo:$repo,head:$head,base:$base,title:$title,state:"pending"}' > "$pending/operation.json" || return 1
  fi
  # Creation output is unstructured; metadata is always re-read, even on error.
  forge_run write "$cli" "${args[@]}" >/dev/null || rc=$?
  if [ "$before" = null ] && [ "$rc" -ne 0 ]; then
    case "${FORGE_LAST_ERROR_CATEGORY:-unknown}" in
      auth|permission|validation|capability|not_found) rm -rf "$pending" ;;
    esac
  fi
  after=$(forge_pr_metadata "$platform" "$repo" "$branch" "$base") || return 1
  [ "$after" != null ] || { forge_error uncertain 'Mutation has no observable matching open request; do not repeat blindly'; return 1; }
  if [ "$before" != null ] && [ "$(jq -r .number <<< "$before")" != "$(jq -r .number <<< "$after")" ]; then
    forge_error uncertain 'Request identity changed during mutation'; return 1
  fi
  rm -rf "$pending"
  printf '%s\n' "$after"
  # A newly observable exact open request reconciles an uncertain create.
  # For updates, the old request's existence does not prove title/body applied.
  [ "$before" != null ] || return 0
  return "$rc"
}

# Safe inventory, usable without goal-config.json or PROJECT_ROOT. Auth output
# is suppressed entirely. Returns nonzero if selected platforms are unready.
forge_doctor() {
  local platform="${1:-}" cli version present auth capabilities entries='[]' deps ready=true spec sub flag value
  command -v jq >/dev/null 2>&1 || { forge_error dependency 'jq required'; return 1; }
  case "$platform" in ''|github|gitlab) ;; *) forge_error usage 'Unknown platform'; return 1 ;; esac
  deps=$(jq -cn --argjson git "$(command -v git >/dev/null 2>&1 && echo true || echo false)" '{jq:true,git:$git}')
  jq -e 'all(.[]; .==true)' <<< "$deps" >/dev/null || ready=false
  for cli in gh glab; do
    [ "$platform:$cli" != github:glab ] && [ "$platform:$cli" != gitlab:gh ] || continue
    present=false; auth=false; version=''; capabilities='{}'
    if type -P "$cli" >/dev/null 2>&1; then
      present=true
      version=$(command "$cli" --version 2>/dev/null | head -n 1) || version=''
      forge_run read "$cli" auth status >/dev/null 2>&1 && auth=true
      local -a specs=()
      if [ "$cli" = gh ]; then
        specs=('pr list|--json' 'pr list|--head' 'pr list|--base' 'pr list|--state' 'pr list|--limit' 'pr list|--repo' 'pr view|--json' 'pr view|--repo' 'pr create|--head' 'pr create|--base' 'pr create|--title' 'pr create|--body-file' 'pr create|--repo' 'pr edit|--title' 'pr edit|--body-file' 'pr edit|--repo' 'api|--hostname' 'api|--method' 'api|--input' 'issue create|--body-file' 'issue create|--title' 'issue create|--repo')
      else
        specs=('mr list|--source-branch' 'mr list|--target-branch' 'mr list|--output' 'mr list|--page' 'mr list|--per-page' 'mr list|--repo' 'mr view|--output' 'mr view|--repo' 'mr create|--source-branch' 'mr create|--target-branch' 'mr create|--title' 'mr create|--yes' 'mr create|--repo' 'mr update|--title' 'mr update|--repo' 'api|--hostname' 'api|--method' 'issue create|--title' 'issue create|--yes' 'issue create|--repo' 'issue list|--all' 'issue list|--page' 'issue list|--per-page' 'issue list|--output' 'issue list|--order' 'issue list|--sort')
      fi
      for spec in "${specs[@]}"; do
        sub="${spec%|*}"; flag="${spec#*|}"; value=false
        forge_supports "$cli" "$sub" "$flag" && value=true
        capabilities=$(jq -c --arg key "$spec" --argjson v "$value" '.+{($key):$v}' <<< "$capabilities") || return 1
      done
      if [ "$cli" = glab ]; then
        for sub in 'mr create' 'mr update' 'issue create'; do
          value=false
          if forge_supports glab "$sub" --description-file || forge_supports glab "$sub" --description; then value=true; fi
          capabilities=$(jq -c --arg key "$sub|description" --argjson v "$value" '.+{($key):$v}' <<< "$capabilities") || return 1
        done
      fi
    fi
    [ "$present" = true ] && [ "$auth" = true ] && jq -e 'all(.[]; .==true)' <<< "$capabilities" >/dev/null || ready=false
    entries=$(jq -cn --argjson entries "$entries" --arg cli "$cli" --arg version "$version" --argjson present "$present" --argjson auth "$auth" --argjson caps "$capabilities" '$entries+[{cli:$cli,installed:$present,version:$version,auth:{authenticated:$auth},capabilities:$caps}]') || return 1
  done
  jq -cn --argjson dependencies "$deps" --argjson platforms "$entries" --argjson ready "$ready" '{dependencies:$dependencies,platforms:$platforms,ready:$ready}'
  [ "$ready" = true ]
}

# One entry per review discussion. GitHub uses the root comment body; GitLab
# combines resolvable note bodies in positioned discussions and requires all
# to be resolved. GitLab Discussions API has no outdated field: false denotes
# unavailable, never proof that the position is current.
# No discussions => []; incomplete pagination/schema/API errors => nonzero.
forge_threads() {
  local platform="${1:-}" repo="${2:-}" number="${3:-}" data result cli
  case "$number" in ''|*[!0-9]*|0) forge_error usage 'Positive request number required'; return 1 ;; esac
  case "$platform" in github) cli=gh ;; gitlab) cli=glab ;; *) forge_error usage 'Unknown platform'; return 1 ;; esac
  forge_api_repo "$cli" "$repo" || return 1
  if [ "$cli" = glab ]; then
    data=$(forge_api_pages glab "$FORGE_API_PATH/merge_requests/$number/discussions" "$FORGE_API_HOST") || return 1
    data=$(printf '%s\n' "$data" | forge_json 'all(.[]; (.id|type)=="string" and (.notes|type)=="array" and all(.notes[]; ((.resolvable|type)=="boolean" or .resolvable==null) and (if .resolvable==true then (.body|type)=="string" and (.resolved|type)=="boolean" else true end)))') || return 1
    result=$(jq -c '[.[] | [.notes[] | select(.resolvable==true)] as $notes | select(($notes|length)>0) | ($notes | map(select(.position!=null))) as $positioned | select(($positioned|length)>0) | {
      id:.id,path:($positioned[0].position.new_path // $positioned[0].position.old_path),
      line:($positioned[0].position.new_line // $positioned[0].position.old_line // null),
      body:($notes | map(.body) | join("\n\n")),resolved:($notes | all(.[]; .resolved==true)),outdated:false
    }]' <<< "$data") || return 1
  else
    forge_require_flags gh api --hostname --method --input || return 1
    local path="${FORGE_API_PATH#repos/}" owner name cursor='' previous='' page=0 all='[]' payload query
    owner="${path%%/*}"; name="${path#*/}"
    query='query($owner:String!,$name:String!,$number:Int!,$cursor:String) { repository(owner:$owner,name:$name) { pullRequest(number:$number) { reviewThreads(first:100,after:$cursor) { nodes { id path line isResolved isOutdated comments(first:1) { nodes { body } } } pageInfo { hasNextPage endCursor } } } } }'
    while :; do
      payload=$(mktemp) || return 1
      if ! jq -cn --arg query "$query" --arg owner "$owner" --arg name "$name" --argjson number "$number" --arg cursor "$cursor" '{query:$query,variables:{owner:$owner,name:$name,number:$number,cursor:(if $cursor=="" then null else $cursor end)}}' > "$payload"; then rm -f "$payload"; return 1; fi
      if data=$(forge_run read gh api graphql --hostname "$FORGE_API_HOST" --method POST --input "$payload"); then
        rm -f "$payload"
      else rm -f "$payload"; return 1; fi
      data=$(printf '%s\n' "$data" | forge_json '((.errors // [])|length)==0 and (.data.repository.pullRequest.reviewThreads.nodes|type)=="array" and (.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage|type)=="boolean" and all(.data.repository.pullRequest.reviewThreads.nodes[]; (.id|type)=="string" and (.isResolved|type)=="boolean" and (.isOutdated|type)=="boolean" and (.comments.nodes|type)=="array" and (.comments.nodes|length)>0 and (.comments.nodes[0].body|type)=="string")') || return 1
      result=$(jq -c '[.data.repository.pullRequest.reviewThreads.nodes[] | {id,path,line,body:.comments.nodes[0].body,resolved:.isResolved,outdated:.isOutdated}]' <<< "$data") || return 1
      all=$(jq -cn --argjson a "$all" --argjson b "$result" '$a+$b') || return 1
      [ "$(jq -r .data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage <<< "$data")" = true ] || break
      previous="$cursor"
      cursor=$(jq -er '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor | select(type=="string" and length>0)' <<< "$data") || { forge_error pagination 'Missing GraphQL cursor'; return 1; }
      [ "$cursor" != "$previous" ] || { forge_error pagination 'GraphQL cursor did not advance'; return 1; }
      page=$((page + 1))
      [ "$page" -lt 10000 ] || { forge_error pagination 'GraphQL pagination did not terminate'; return 1; }
    done
    result="$all"
  fi
  printf '%s\n' "$result" | forge_json 'type=="array" and all(.[]; (.id|type)=="string" and (.path|type)=="string" and (.line==null or (.line|type)=="number") and (.body|type)=="string" and (.resolved|type)=="boolean" and (.outdated|type)=="boolean")'
}
