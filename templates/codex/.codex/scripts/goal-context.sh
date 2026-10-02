# Shared checkout and state boundary. Sourced by goal-git.sh (Bash 3.2+).

goal_error() {
  local code="$1" message="$2" action="${3:-Run goal-git.sh doctor --json; preserve state and stop.}"
  jq -n --arg code "$code" --arg message "$message" --arg action "$action" \
    '{error:{category:$code,message:$message,retryable:false,corrective_action:$action}}' >&2
  return 1
}

resolve_goal_idx() {
  if [ ! -f "$STATE_FILE" ]; then
    [ -z "${GOAL_ID:-}${GOAL_ISSUE:-}${GOAL_GROUP:-}" ] || {
      goal_error assignment "No state exists for the requested assignment"; return 1;
    }
    echo -1; return
  fi
  local matches
  matches=$(jq -c --arg id "${GOAL_ID:-}" --arg issue "${GOAL_ISSUE:-}" \
    --arg run "${GOAL_RUN_ID:-}" --arg repo "${GOAL_ISSUE_REPO:-}" '
    to_entries | map(select(
      ($id == "" or .value.id == $id) and
      ($issue == "" or (.value.issue.number | tostring) == $issue) and
      ($run == "" or .value.run_id == $run) and
      ($repo == "" or .value.issue.repo == $repo))) | map(.key)
  ' "$STATE_FILE") || return
  if [ -z "${GOAL_ID:-}${GOAL_ISSUE:-}" ]; then echo -1; return; fi
  [ "$(printf '%s' "$matches" | jq length)" -eq 1 ] || {
    goal_error assignment "Assignment missing or ambiguous; supply GOAL_ID or GOAL_RUN_ID and GOAL_ISSUE_REPO"; return 1;
  }
  printf '%s' "$matches" | jq -r '.[0]'
}

refresh_goal_idx() { GOAL_IDX="$(resolve_goal_idx)"; }

state_ensure_array() {
  [ -f "$STATE_FILE" ] || return 0
  if jq -e 'if type == "object" then true else any(.[]; .id == null) end' "$STATE_FILE" >/dev/null; then
    state_mutate '(if type == "object" then [.] else . end) | to_entries | map(.value +
      {id:(.value.id // ("goal-legacy-" + (.key | tostring)))})' || return
  fi
}

# A group selector projects that group onto the legacy per-goal interface.
# Mutations re-read shared state while locked and write ONLY that group back.
# Other workers never depend on the shared active_group_id overlay.
context_project_group() {
  local input="$1" output="$2"
  jq --argjson idx "$GOAL_IDX" --arg gid "$GOAL_GROUP" '
    (.[$idx].delivery_groups | map(select(.id == $gid)) | .[0]) as $g
    | if $g == null then error("Unknown GOAL_GROUP") else
      .[$idx] += ($g | {branch,worktree,pr_number,pr_url,harness,pr_title,pr_body,delivery,repos})
      | .[$idx].harness //= {} | .[$idx].active_group_id = $gid end
  ' "$input" > "$output"
}

state_mutate() {
  local actual="${SHARED_STATE_FILE:-$STATE_FILE}" tmp input previous_idx="$GOAL_IDX" i=0
  local jq_args=("$@")
  tmp="$(mktemp "${actual}.tmp.XXXXXX")" || return
  input="$actual"
  if ! state_lock_acquire; then rm -f "$tmp"; return 1; fi
  if [ -n "${GOAL_ID:-}" ] && [ -f "$actual" ]; then
    GOAL_IDX=$(jq -r --arg id "$GOAL_ID" 'map(.id == $id) | indices(true) | if length == 1 then .[0] else null end' "$actual")
    if [ "$GOAL_IDX" = null ]; then rm -f "$tmp"; state_lock_release; goal_error assignment "Selected goal no longer exists"; return 1; fi
    while [ "$i" -lt "${#jq_args[@]}" ]; do
      if [ "${jq_args[$i]}" = --argjson ] && [ "${jq_args[$((i + 1))]:-}" = idx ] && [ "${jq_args[$((i + 2))]:-}" = "$previous_idx" ]; then
        jq_args[$((i + 2))]="$GOAL_IDX"
      fi
      i=$((i + 1))
    done
  fi
  if [ -n "${GOAL_GROUP:-}" ] && [ -n "${GROUP_STATE_VIEW:-}" ]; then
    # GOAL_ID is pinned at projection setup so concurrent history reordering is safe.
    GOAL_IDX=$(jq -r --arg id "$GOAL_ID" 'map(.id == $id) | indices(true) | if length == 1 then .[0] else null end' "$actual")
    if [ "$GOAL_IDX" = null ] || ! context_project_group "$actual" "$STATE_FILE"; then
      rm -f "$tmp"; state_lock_release; return 1
    fi
    input="$STATE_FILE"
  fi
  if ! jq "${jq_args[@]}" "$input" > "$tmp"; then rm -f "$tmp"; state_lock_release; return 1; fi
  if [ -n "${GOAL_GROUP:-}" ] && [ -n "${GROUP_STATE_VIEW:-}" ]; then
    local merged
    merged="$(mktemp "${actual}.tmp.XXXXXX")"
    if ! jq --argjson idx "$GOAL_IDX" --arg gid "$GOAL_GROUP" --slurpfile view "$tmp" '
      $view[0][$idx] as $v
      | .[$idx].spawn_reservations = $v.spawn_reservations
      | .[$idx].delivery_groups |= map(if .id == $gid then
        ($v.delivery_groups | map(select(.id == $gid)) | .[0]) +
        ($v | {branch,worktree,pr_number,pr_url,harness,pr_title,pr_body,delivery,repos}) else . end)
      | if .[$idx].active_group_id == $gid then
          .[$idx] += ($v | {branch,worktree,pr_number,pr_url,harness,pr_title,pr_body,delivery,repos})
        else . end
    ' "$actual" > "$merged"; then
      rm -f "$tmp" "$merged"; state_lock_release; return 1
    fi
    if ! mv "$merged" "$actual" || ! mv "$tmp" "$STATE_FILE"; then
      rm -f "$merged" "$tmp"; state_lock_release; return 1
    fi
  else
    if ! mv "$tmp" "$actual"; then rm -f "$tmp"; state_lock_release; return 1; fi
  fi
  state_lock_release
}

state_append_goal() {
  local entry="$1" actual="${SHARED_STATE_FILE:-$STATE_FILE}" tmp
  [ -z "${GOAL_GROUP:-}" ] || { goal_error assignment "Clear GOAL_GROUP before starting a new goal"; return 1; }
  state_lock_acquire || return
  tmp=$(mktemp "${actual}.tmp.XXXXXX") || { state_lock_release; return 1; }
  if [ -f "$actual" ]; then
    if ! jq --argjson entry "$entry" '(if type == "object" then [.] else . end) + [$entry]' "$actual" > "$tmp"; then
      rm -f "$tmp"; state_lock_release; return 1
    fi
  else
    if ! jq -n --argjson entry "$entry" '[$entry]' > "$tmp"; then
      rm -f "$tmp"; state_lock_release; return 1
    fi
  fi
  if ! mv "$tmp" "$actual"; then rm -f "$tmp"; state_lock_release; return 1; fi
  state_lock_release
}

context_init() {
  SHARED_STATE_FILE="$STATE_FILE"
  REQUESTED_GOAL_ID="${GOAL_ID:-}"
  # Independent commands such as help/doctor/models need no assignment.
  case "${1:-}" in help|--help|-h|doctor|models|config|selfcheck|codex|complexity) return ;; esac
  state_ensure_array || return
  # Intake must run before an assignment exists. In particular, issues start
  # resolves and validates its requested number/run/repository itself; do not
  # bind it to the previous goal or reject the not-yet-created issue.
  if [ "${1:-}" = issues ]; then
    case "${2:-}" in list|queue|start) return ;; esac
  fi
  refresh_goal_idx || return
  if [ -f "$STATE_FILE" ]; then
    GOAL_ID=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].id // empty' "$STATE_FILE")
    local selected_platform
    selected_platform=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].source.platform // .[$idx].platform // empty' "$STATE_FILE")
    if [ -n "$selected_platform" ]; then
      case "$selected_platform" in github|gitlab) platform="$selected_platform" ;; *) goal_error configuration "Invalid platform in goal state"; return 1 ;; esac
    fi
  fi
  if [ -n "${GOAL_GROUP:-}" ]; then
    [ -f "$STATE_FILE" ] || return 1
    GOAL_ID="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].id' "$STATE_FILE")"
    GROUP_STATE_VIEW="$(mktemp)"
    context_project_group "$SHARED_STATE_FILE" "$GROUP_STATE_VIEW" || return
    STATE_FILE="$GROUP_STATE_VIEW"
    trap 'rm -f "$GROUP_STATE_VIEW"' EXIT
  fi
}

repo_dir() {
  local repo="${1:-${GOAL_REPO:-.}}"
  if [ "$repo" = . ]; then goal_workdir; return; fi
  case "$repo" in /*|../*|*/../*|.worktrees/*)
    goal_error assignment "Repository key must identify a configured repository, not a worktree path"; return 1;; esac
  jq -e --arg r "$repo" '.repos // [] | index($r) != null' "$CONFIG_FILE" >/dev/null || {
    goal_error assignment "Repository '$repo' is not configured"; return 1;
  }
  [ -d "$PROJECT_ROOT/$repo" ] || return 1
  (cd "$PROJECT_ROOT/$repo" && pwd)
}

# Resolve a GOAL_TASK selector to either a dedicated task worktree or the
# parent goal/issue checkout when the harness task has no isolated worktree.
task_checkout() {
  local task="${GOAL_TASK:-}" entry=""
  [ -n "$task" ] || return 1
  entry=$(jq -c --argjson idx "$GOAL_IDX" --arg task "$task" \
    '.[$idx].task_worktrees[$task] // empty' "$STATE_FILE" 2>/dev/null) || entry=""
  if [ -n "$entry" ] && [ "$entry" != "null" ]; then
    printf '%s\n' "$entry"
    return 0
  fi
  if jq -e --argjson idx "$GOAL_IDX" --arg task "$task" \
    'any((.[$idx].harness.tasks // [])[]; .id == $task)' "$STATE_FILE" >/dev/null 2>&1; then
    # Harness task without an isolated checkout: use the goal/issue worktree.
    return 2
  fi
  goal_error assignment "Unknown GOAL_TASK '$task'; no task_worktrees entry and no harness.tasks id. Use worktree add $task or clear GOAL_TASK."
  return 1
}

goal_workdir() {
  local wt="" expected="" task_status=0
  if [ -f "$STATE_FILE" ]; then
    wt=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].worktree // empty' "$STATE_FILE")
    expected=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch // empty' "$STATE_FILE")
    if [ -n "${GOAL_TASK:-}" ]; then
      local task
      task=$(task_checkout) && task_status=0 || task_status=$?
      if [ "$task_status" -eq 0 ]; then
        wt=$(printf '%s' "$task" | jq -r .worktree)
        expected=$(printf '%s' "$task" | jq -r .branch)
      elif [ "$task_status" -ne 2 ]; then
        return 1
      fi
      # status 2: harness task ID without dedicated worktree — keep goal/issue wt
    fi
  fi
  if [ -n "$wt" ]; then
    case "$wt" in /*|../*|*/../*) goal_error assignment "Invalid persisted worktree path"; return 1;; esac
    [ -d "$PROJECT_ROOT/$wt" ] || { goal_error assignment "Goal worktree is missing: $PROJECT_ROOT/$wt"; return 1; }
    wt=$(cd "$PROJECT_ROOT/$wt" && pwd)
    if [ "$RUNTIME_ROOT" != "$PROJECT_ROOT" ] && [ "$wt" != "$RUNTIME_ROOT" ]; then
      goal_error assignment "Selected goal belongs to a different worktree; check assignment selectors"; return 1
    fi
    [ "$(git -C "$wt" branch --show-current)" = "$expected" ] || {
      goal_error assignment "Worktree branch differs from its persisted assignment"; return 1;
    }
    echo "$wt"; return
  fi
  echo "$RUNTIME_ROOT"
}

context_assert_branch() {
  local wd="$1" branch="${2:-}" task_status=0
  [ -n "$branch" ] || branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch // empty' "$STATE_FILE")
  if [ -n "${GOAL_TASK:-}" ]; then
    local task
    task=$(task_checkout) && task_status=0 || task_status=$?
    if [ "$task_status" -eq 0 ]; then
      branch=$(printf '%s' "$task" | jq -r .branch)
    elif [ "$task_status" -eq 2 ]; then
      : # harness task without task worktree — assert goal/issue branch
    else
      return 1
    fi
  fi
  [ -n "$branch" ] && [ "$(git -C "$wd" branch --show-current)" = "$branch" ] || {
    goal_error assignment "Expected branch '$branch' is not checked out in $wd"; return 1;
  }
}

cmd_context() {
  require_active_goal; refresh_goal_idx
  local wd
  wd="$(repo_dir "${GOAL_REPO:-.}")" || return
  # Always use the root helper. Workers must not depend on copied .codex trees.
  local script="$PROJECT_ROOT/.codex/scripts/goal-git.sh" branch
  [ -f "$script" ] || script="$SCRIPTS_DIR/goal-git.sh"
  branch=$(git -C "$wd" branch --show-current)
  if [ -n "$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch // empty' "$STATE_FILE")" ]; then context_assert_branch "$wd" || return; fi
  jq -n --arg actual_branch "$branch" --arg root "$PROJECT_ROOT" --arg wd "$wd" --arg script "$script" \
    --argjson idx "$GOAL_IDX" --slurpfile state "$STATE_FILE" \
    --arg group "${GOAL_GROUP:-}" --arg task "${GOAL_TASK:-}" --arg repo "${GOAL_REPO:-.}" '
    $state[0][$idx] as $g | {WORKFLOW_ROOT:$root,TARGET_WORKTREE:$wd,GOAL_GIT:$script,
      GOAL_ID:$g.id,GOAL_RUN_ID:$g.run_id,GOAL_ISSUE:$g.issue.number,GOAL_GROUP:$group,
      GOAL_TASK:$task,GOAL_REPO:$repo,GOAL_ISSUE_REPO:$g.issue.repo,branch:$actual_branch,base_branch:$g.base_branch,source:$g.source}'
}

# Shared exclude block so linked worktrees never see workflow runtime as dirty.
# All worktrees share git-common-dir/info/exclude — no per-worktree copies needed.
WORKFLOW_EXCLUDE_BEGIN="# >>> goal-workflow excludes >>>"
WORKFLOW_EXCLUDE_END="# <<< goal-workflow excludes <<<"

worktree_install_excludes() {
  require_cmd git
  local common exclude_file tmp
  common=$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir) || return 1
  exclude_file="$common/info/exclude"
  mkdir -p "$(dirname "$exclude_file")"
  [ -f "$exclude_file" ] || touch "$exclude_file"
  tmp=$(mktemp)
  # Strip any previous managed block, then append a fresh one.
  awk -v begin="$WORKFLOW_EXCLUDE_BEGIN" -v end="$WORKFLOW_EXCLUDE_END" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "$exclude_file" > "$tmp" || { rm -f "$tmp"; return 1; }
  {
    printf '%s\n' "$WORKFLOW_EXCLUDE_BEGIN"
    printf '%s\n' \
      '.codex/' \
      '.agents/skills/goal/' \
      '.agents/skills/goal-loop/' \
      '.agents/skills/init-goal/' \
      '.agents/skills/init-skills/' \
      '.agents/skills/create-issues/' \
      'AGENTS.md' \
      '.worktrees/' \
      '.goal-review/' \
      'state.json' \
      '.gitnexus/' \
      '.claude/skills/gitnexus-*/'
    printf '%s\n' "$WORKFLOW_EXCLUDE_END"
  } >> "$tmp"
  mv "$tmp" "$exclude_file" || return 1
}

# Compatibility: install excludes and remove previously copied managed files.
# Does not copy scripts/agents into worktrees — MAIN and workers use the root helper.
sync_worktree_config() {
  local wt_path="$1" source_common target_common manifest file
  require_cmd git
  worktree_install_excludes || return 1
  [ -n "$wt_path" ] || return 0
  [ -e "$wt_path" ] || return 0
  [ -f "$wt_path/.git" ] || [ -d "$wt_path/.git" ] || {
    # Plain path that is not yet a worktree — excludes already installed.
    return 0
  }
  wt_path=$(cd "$wt_path" && pwd)
  [ "$wt_path" != "$PROJECT_ROOT" ] || return 0
  source_common=$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir)
  target_common=$(git -C "$wt_path" rev-parse --path-format=absolute --git-common-dir)
  [ "$source_common" = "$target_common" ] || { goal_error assignment "Worktree belongs to another repository"; return 1; }
  manifest="$wt_path/.codex/workflow-manifest"
  if [ -f "$manifest" ]; then
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      if git -C "$wt_path" ls-files --error-unmatch "$file" >/dev/null 2>&1; then continue; fi
      rm -f "$wt_path/$file" 2>/dev/null || true
      rmdir "$(dirname "$wt_path/$file")" 2>/dev/null || true
    done < "$manifest"
    rm -f "$manifest"
  fi
  # Clean leftover workflow-root marker from the old copier.
  rm -f "$wt_path/.codex/workflow-root" 2>/dev/null || true
  # Remove emptied .codex / .agents trees that only held managed copies.
  rmdir "$wt_path/.codex" 2>/dev/null || true
}

source_snapshot() {
  local type="$1" title="$2" body="$3" reference="${4:-}" file="${5:-}"
  if [ -n "$file" ]; then
    jq -ce --arg type "$type" '
      select(type == "object" and .type == $type and (.title | type) == "string" and
        (.body | type) == "string" and (.reference | type) == "string")
      | .acceptance_criteria //= (.acceptance // [])
      | select(.title != "" and ($type != "jira" or (.body != "" and .reference != "")))
    ' "$file" || { goal_error source "Invalid source snapshot; require type,title,body,reference"; return 1; }
  elif [ "$type" = markdown ]; then
    [ -f "$reference" ] || { goal_error source "Markdown source is missing: $reference"; return 1; }
    jq -n --arg type "$type" --arg title "$title" --rawfile body "$reference" --arg ref "$reference" \
      '{type:$type,title:$title,body:$body,reference:$ref,acceptance_criteria:[]}'
  elif [ "$type" = jira ]; then
    goal_error source "Jira requires the fetched ticket as --source-file; discover Atlassian MCP tools first"
  else
    jq -n --arg type "$type" --arg title "$title" --arg body "$body" --arg ref "$reference" \
      '{type:$type,title:$title,body:$body,reference:$ref,acceptance_criteria:[]}'
  fi
}

parse_issue_list_url() {
  local parsed
  parsed=$(python3 - "$1" <<'PY'
import sys,json
from urllib.parse import urlsplit,parse_qs
u=urlsplit(sys.argv[1]); p=u.path.rstrip('/'); q=parse_qs(u.query)
if u.scheme not in ('https','http') or not u.hostname or u.username or u.password:
    raise SystemExit('Invalid issue URL')
if '/-/issues' in p:
    repo=p.split('/-/issues')[0].strip('/'); platform='gitlab'
    allowed={'label_name','label_name[]','state','sort','scope','search','assignee_username','author_username'}
    if set(q)-allowed: raise SystemExit('Unsupported GitLab issue-list filter: '+','.join(set(q)-allowed))
    if q.get('state',['opened'])[0] != 'opened': raise SystemExit('Only open issue queues are supported')
    if q.get('scope',['all'])[0] != 'all': raise SystemExit('Only scope=all is supported')
    if q.get('sort',['created_asc'])[0] != 'created_asc': raise SystemExit('Only sort=created_asc is supported')
    query=','.join(q.get('label_name[]',q.get('label_name',[])))
    target=u.scheme+'://'+u.netloc+'/'+repo
elif '/issues' in p:
    repo=p.split('/issues')[0].strip('/'); platform='github'
    if len(repo.split('/'))!=2 or set(q)-{'q'}: raise SystemExit('Invalid GitHub repository or unsupported filter')
    query=q.get('q',[''])[0]; target=(u.hostname+'/' if u.hostname!='github.com' else '')+repo
else: raise SystemExit('Expected a GitHub or GitLab issue-list URL')
print(json.dumps(dict(platform=platform,repo=target,host=u.hostname,query=query,filters=q)))
PY
  ) || { goal_error source "Cannot parse issue list URL or filters"; return 1; }
  ISSUE_LIST_PLATFORM=$(printf '%s' "$parsed" | jq -r .platform)
  ISSUE_LIST_REPO=$(printf '%s' "$parsed" | jq -r .repo)
  ISSUE_LIST_HOST=$(printf '%s' "$parsed" | jq -r .host)
  ISSUE_LIST_QUERY=$(printf '%s' "$parsed" | jq -r .query)
  ISSUE_LIST_FILTERS=$(printf '%s' "$parsed" | jq -c .filters)
}
