# Delivery-group helpers for Markdown multi-PR goals.
# Sourced from goal-git.sh. Uses PROJECT_ROOT, STATE_FILE, GOAL_IDX, WORKTREES_DIR.

DELIVERY_TASK_TYPES="feat|fix|chore|refactor|docs|test|perf|build|ci"

markdown_pr_strategy_effective() {
  local src strategy
  src="${GOAL_SOURCE_OVERRIDE:-$(config_read goal_source)}"
  strategy="$(config_read markdown_pr_strategy)"
  if [ "$src" != "markdown" ]; then
    echo "single"
    return
  fi
  case "${strategy:-auto}" in
    auto|single|task) echo "${strategy:-auto}" ;;
    *) echo "auto" ;;
  esac
}

canonical_delivery_task_type() {
  local raw
  raw="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "$raw" in
    bug|bugfix|fix|defect) echo fix ;;
    feat|feature) echo feat ;;
    chore|refactor|docs|test|perf|build|ci) echo "$raw" ;;
    "")
      err "task_type is required"
      return 1
      ;;
    *)
      err "Unsupported task type: $raw (allowed: feat fix chore refactor docs test perf build ci; bugfix→fix)"
      return 1
      ;;
  esac
}

delivery_branch_name() {
  local type id slug
  type="$(canonical_delivery_task_type "$1")" || return 1
  id="$(echo "$2" | tr '[:upper:]' '[:lower:]')"
  slug="$(slugify "$3")"
  [ -n "$id" ] || { err "delivery group id is required"; return 1; }
  [ -n "$slug" ] || { err "branch_slug is required"; return 1; }
  echo "${type}/${id}-${slug}"
}

delivery_worktree_rel() {
  local id slug
  id="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  slug="$(slugify "$2")"
  echo ".worktrees/${id}-${slug}"
}

delivery_assert_branch() {
  local branch="$1"
  echo "$branch" | grep -qE '^(feat|fix|chore|refactor|docs|test|perf|build|ci)/g[0-9]+-[a-z0-9-]+$' \
    || { err "Invalid delivery branch '$branch' — expected <task-type>/<group-id>-<slug>"; return 1; }
  echo "$branch" | grep -qE '^goal/' && { err "Delivery branch must not use goal/ prefix: $branch"; return 1; }
  return 0
}

# Returns 0 if path globs/strings likely overlap.
delivery_files_overlap() {
  local a="$1" b="$2" x y xs ys
  a="$(echo "$a" | sed 's|\*\*|*|g; s|/\*$||; s|\*$||')"
  b="$(echo "$b" | sed 's|\*\*|*|g; s|/\*$||; s|\*$||')"
  [ -z "$a" ] || [ -z "$b" ] && return 1
  [ "$a" = "$b" ] && return 0
  case "$a" in "$b"|"$b"/*) return 0 ;; esac
  case "$b" in "$a"|"$a"/*) return 0 ;; esac
  return 1
}

delivery_group_by_id() {
  local gid="$1"
  jq -c --argjson idx "$GOAL_IDX" --arg id "$gid" \
    '.[$idx].delivery_groups // [] | map(select(.id == $id)) | .[0] // empty' \
    "$STATE_FILE"
}

groups_persist_active() {
  [ -f "$STATE_FILE" ] || return 0
  refresh_goal_idx
  local gid
  gid="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].active_group_id // empty' "$STATE_FILE" 2>/dev/null || true)"
  [ -n "$gid" ] && [ "$gid" != "null" ] || return 0

  state_mutate --argjson idx "$GOAL_IDX" --arg gid "$gid" '
    .[$idx] as $g
    | .[$idx].delivery_groups = [
        ($g.delivery_groups // [])[]
        | if .id == $gid then
            . + {
              branch: ($g.branch // .branch),
              worktree: ($g.worktree // .worktree),
              pr_number: ($g.pr_number // .pr_number),
              pr_url: ($g.pr_url // .pr_url // ""),
              harness: ($g.harness // .harness // {}),
              status: (if .status == "merged" or .status == "completed" then .status
                       elif ($g.harness.phase // "") == "DONE" then "ready"
                       else (.status // "in_progress") end)
            }
          else .
          end
      ]
  '
}

groups_activate() {
  local gid="$1"
  [ -z "$gid" ] && { err "groups activate requires <group-id>"; return 1; }
  require_active_goal
  refresh_goal_idx
  groups_persist_active

  local group
  group="$(delivery_group_by_id "$gid")"
  [ -n "$group" ] || { err "Unknown delivery group: $gid"; return 1; }

  state_mutate --argjson idx "$GOAL_IDX" --arg gid "$gid" --argjson group "$group" '
    .[$idx].active_group_id = $gid
    | .[$idx].branch = ($group.branch // .[$idx].branch)
    | .[$idx].worktree = ($group.worktree // "")
    | .[$idx].pr_number = ($group.pr_number // null)
    | .[$idx].pr_url = ($group.pr_url // "")
    | .[$idx].harness = (if ($group.harness | type) == "object" and ($group.harness | length) > 0
                         then $group.harness
                         else {} end)
  '
  log "Active delivery group: $gid ($(echo "$group" | jq -r .branch))"
}

delivery_normalize_groups_json() {
  local raw="$1"
  echo "$raw" | jq '
    (if type == "array" then {delivery_groups: .}
     elif has("delivery_groups") then .
     else error("expected delivery_groups array") end)
    | .delivery_groups |= map(
        .id as $id
        | .task_type as $tt
        | .branch_slug as $slug
        | . + {
            id: ((.id // empty) | ascii_downcase),
            task_ids: (.task_ids // []),
            depends_on: (.depends_on // []),
            files: (.files // []),
            acceptance_checks: (.acceptance_checks // []),
            title: (.title // .id),
            reason: (.reason // "")
          }
      )
  '
}

delivery_validate_normalized() {
  local json="$1" strategy="${2:-auto}"
  local ids types
  echo "$json" | jq -e '.delivery_groups | type == "array" and length > 0' >/dev/null \
    || { err "delivery_groups must be a non-empty array"; return 1; }

  ids="$(echo "$json" | jq -r '.delivery_groups[].id')"
  if [ "$(echo "$ids" | sort | uniq -d | wc -l | tr -d ' ')" -gt 0 ]; then
    err "Duplicate delivery group ids: $(echo "$ids" | sort | uniq -d | tr '\n' ' ')"
    return 1
  fi

  local g n
  n="$(echo "$json" | jq '.delivery_groups | length')"
  local i=0
  while [ "$i" -lt "$n" ]; do
    g="$(echo "$json" | jq -c --argjson i "$i" '.delivery_groups[$i]')"
    local id tt slug branch
    id="$(echo "$g" | jq -r .id)"
    echo "$id" | grep -qE '^g[0-9]+$' || { err "Group id must be gN (got $id)"; return 1; }
    tt="$(canonical_delivery_task_type "$(echo "$g" | jq -r .task_type)")" || return 1
    slug="$(echo "$g" | jq -r '.branch_slug // empty')"
    [ -n "$slug" ] || { err "Group $id missing branch_slug"; return 1; }
    branch="$(delivery_branch_name "$tt" "$id" "$slug")" || return 1
    delivery_assert_branch "$branch" || return 1
    local dep
    for dep in $(echo "$g" | jq -r '.depends_on[]?'); do
      echo "$ids" | grep -qx "$dep" || { err "Group $id depends_on unknown id $dep"; return 1; }
      [ "$dep" = "$id" ] && { err "Group $id cannot depend on itself"; return 1; }
    done
    if [ "$(echo "$g" | jq '.task_ids | length')" -eq 0 ]; then
      err "Group $id has no task_ids"
      return 1
    fi
    if [ "$strategy" = "task" ] && [ "$(echo "$g" | jq '.task_ids | length')" -ne 1 ]; then
      err "markdown_pr_strategy=task requires exactly one task_id per group ($id)"
      return 1
    fi
    i=$((i + 1))
  done

  if [ "$strategy" = "single" ] && [ "$n" -ne 1 ]; then
    err "markdown_pr_strategy=single requires exactly one delivery group (got $n)"
    return 1
  fi

  delivery_assert_no_cycles "$json" || return 1
  return 0
}

delivery_assert_no_cycles() {
  local json="$1"
  printf '%s' "$json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
groups = data.get("delivery_groups") or []
deps = {g["id"]: list(g.get("depends_on") or []) for g in groups}
vis, stack = set(), set()

def dfs(n):
    if n in stack:
        raise SystemExit("dependency cycle involving " + n)
    if n in vis:
        return
    stack.add(n)
    for d in deps.get(n, []):
        dfs(d)
    stack.remove(n)
    vis.add(n)

for gid in deps:
    dfs(gid)
'
}

delivery_apply_overlap_deps() {
  local json="$1"
  python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
groups = data["delivery_groups"]

def overlap(a, b):
    def norm(p):
        return p.replace("**", "*").rstrip("*").rstrip("/")
    for fa in a.get("files") or []:
        for fb in b.get("files") or []:
            na, nb = norm(fa), norm(fb)
            if not na or not nb:
                continue
            if na == nb or na.startswith(nb + "/") or nb.startswith(na + "/"):
                return True
    return False

def reachable(src, dst, deps):
    seen = set()
    q = [src]
    while q:
        n = q.pop()
        if n == dst:
            return True
        if n in seen:
            continue
        seen.add(n)
        q.extend(deps.get(n, []))
    return False

deps = {g["id"]: list(g.get("depends_on") or []) for g in groups}
ids = [g["id"] for g in groups]
for i, a in enumerate(groups):
    for b in groups[i+1:]:
        if not overlap(a, b):
            continue
        if reachable(a["id"], b["id"], deps) or reachable(b["id"], a["id"], deps):
            continue
        # sequential: later group waits for earlier
        b.setdefault("depends_on", []).append(a["id"])
        deps[b["id"]].append(a["id"])
        print("overlap: %s now depends_on %s" % (b["id"], a["id"]), file=sys.stderr)
data["delivery_groups"] = groups
json.dump(data, sys.stdout)
' <<<"$json"
}

cmd_groups_validate() {
  local src="${1:-}" raw
  if [ -z "$src" ] || [ "$src" = "-" ]; then
    raw="$(cat)"
  else
    [ -f "$src" ] || { err "File not found: $src"; exit 1; }
    raw="$(cat "$src")"
  fi
  local strategy
  strategy="$(markdown_pr_strategy_effective)"
  raw="$(delivery_normalize_groups_json "$raw")" || exit 1
  delivery_validate_normalized "$raw" "$strategy" || exit 1
  echo "$raw" | jq .
  log "delivery_groups valid (strategy=$strategy)"
}

cmd_groups_init() {
  require_cmd jq
  require_active_goal
  refresh_goal_idx
  local src="${1:-}" raw strategy
  if [ -z "$src" ] || [ "$src" = "-" ]; then
    raw="$(cat)"
  else
    [ -f "$src" ] || { err "File not found: $src"; exit 1; }
    raw="$(cat "$src")"
  fi
  strategy="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].markdown_pr_strategy // empty' "$STATE_FILE")"
  [ -n "$strategy" ] || strategy="$(markdown_pr_strategy_effective)"

  raw="$(delivery_normalize_groups_json "$raw")" || exit 1
  raw="$(delivery_apply_overlap_deps "$raw")" || exit 1
  delivery_validate_normalized "$raw" "$strategy" || exit 1

  local existing
  existing="$(jq -c --argjson idx "$GOAL_IDX" '.[$idx].delivery_groups // []' "$STATE_FILE")"
  if [ "$existing" != "[]" ]; then
    log "Merging into existing delivery_groups (idempotent; keep branches/PRs)"
  fi

  local groups_out user_tt
  user_tt="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].user_task_type // empty' "$STATE_FILE")"
  groups_out="$(jq -c --argjson existing "$existing" '
    .delivery_groups
    | map(. as $n
      | ($existing | map(select(.id == $n.id)) | .[0] // {}) as $old
      | {
          id: $n.id,
          task_type: $n.task_type,
          title: $n.title,
          branch_slug: $n.branch_slug,
          task_ids: $n.task_ids,
          depends_on: $n.depends_on,
          files: $n.files,
          acceptance_checks: $n.acceptance_checks,
          reason: $n.reason,
          inseparable_reason: ($n.inseparable_reason // $old.inseparable_reason // ""),
          branch: ($old.branch // ""),
          worktree: ($old.worktree // ""),
          status: ($old.status // "planned"),
          pr_number: ($old.pr_number // null),
          pr_url: ($old.pr_url // ""),
          harness: ($old.harness // {}),
          pr_title: ($old.pr_title // "")
        }
    )
  ' <<<"$raw")"

  # Fill canonical type + branch names for new groups
  groups_out="$(USER_TASK_TYPE="$user_tt" python3 -c '
import json, os, re, sys
groups = json.load(sys.stdin)
user_tt = (os.environ.get("USER_TASK_TYPE") or "").strip().lower()

def canon(t):
    t = (t or "").strip().lower()
    mapped = {"bug":"fix","bugfix":"fix","defect":"fix","feature":"feat"}.get(t, t)
    allowed = {"feat","fix","chore","refactor","docs","test","perf","build","ci"}
    if mapped not in allowed:
        raise SystemExit("Unsupported task type: %s" % t)
    return mapped

def slug(s):
    s = re.sub(r"[^a-z0-9]+", "-", (s or "").lower()).strip("-")
    return s[:50].rstrip("-")

for g in groups:
    inferred = canon(g.get("task_type"))
    # User-supplied type overrides inference only for a single delivery unit.
    # Multi-group plans keep per-group types (feat + fix + docs in one Markdown goal).
    if user_tt and len(groups) == 1:
        g["task_type"] = canon(user_tt)
    else:
        g["task_type"] = inferred
    slug_s = slug(g.get("branch_slug") or g.get("title") or g["id"])
    g["branch_slug"] = slug_s
    if not g.get("branch"):
        g["branch"] = "%s/%s-%s" % (g["task_type"], g["id"], slug_s)
    if not g.get("worktree"):
        g["worktree"] = ".worktrees/%s-%s" % (g["id"], slug_s)
    if g["branch"].startswith("goal/"):
        raise SystemExit("refusing goal/ branch for %s" % g["id"])
print(json.dumps(groups))
' <<<"$groups_out")"

  state_mutate --argjson idx "$GOAL_IDX" --argjson groups "$groups_out" --arg strategy "$strategy" '
    .[$idx].delivery_mode = "multi-pr"
    | .[$idx].markdown_pr_strategy = $strategy
    | .[$idx].delivery_groups = $groups
  '
  harness_event "main" "delivery_grouping_completed" "groups=$(echo "$groups_out" | jq 'length') strategy=$strategy"
  echo "$groups_out" | jq .
  log "Initialized $(echo "$groups_out" | jq 'length') delivery group(s)"
}

cmd_groups_list() {
  require_active_goal
  refresh_goal_idx
  jq --argjson idx "$GOAL_IDX" '
    .[$idx] | {
      goal: .goal,
      delivery_mode: (.delivery_mode // "single"),
      strategy: (.markdown_pr_strategy // "single"),
      active_group_id: (.active_group_id // null),
      groups: (.delivery_groups // [] | map({
        id, task_type, title, branch, status, depends_on, pr_number, pr_url,
        phase: (.harness.phase // null)
      }))
    }
  ' "$STATE_FILE"
}

cmd_groups_status() {
  require_active_goal
  refresh_goal_idx
  local gid="${1:-}"
  if [ -z "$gid" ]; then
    cmd_groups_list
    return
  fi
  local g
  g="$(delivery_group_by_id "$gid")"
  [ -n "$g" ] || { err "Unknown delivery group: $gid"; exit 1; }
  echo "$g" | jq .
}

groups_deps_merged() {
  local gid="$1" dep
  for dep in $(jq -r --argjson idx "$GOAL_IDX" --arg id "$gid" \
    '.[$idx].delivery_groups[] | select(.id == $id) | .depends_on[]?' "$STATE_FILE"); do
    local st
    st="$(jq -r --argjson idx "$GOAL_IDX" --arg d "$dep" \
      '.[$idx].delivery_groups[] | select(.id == $d) | .status' "$STATE_FILE")"
    case "$st" in
      merged|completed) ;;
      *)
        err "Group $gid blocked on $dep (status=$st)"
        return 1
        ;;
    esac
  done
  return 0
}

cmd_groups_start() {
  require_cmd git jq
  require_active_goal
  refresh_goal_idx
  local gid="${1:-}"
  [ -z "$gid" ] && { err "groups start requires <group-id>"; exit 1; }
  groups_deps_merged "$gid" || exit 1

  local group
  group="$(delivery_group_by_id "$gid")"
  [ -n "$group" ] || { err "Unknown delivery group: $gid"; exit 1; }

  local st max_p in_flight
  st="$(echo "$group" | jq -r '.status // "planned"')"
  max_p="$(config_read max_parallel_prs)"; max_p="${max_p:-2}"
  in_flight="$(jq -r --argjson idx "$GOAL_IDX" --arg id "$gid" '
    [.[$idx].delivery_groups[]? | select(.status == "in_progress" and .id != $id)] | length
  ' "$STATE_FILE")"
  if [ "$st" != "in_progress" ] && [ "$st" != "ready" ] && [ "${in_flight:-0}" -ge "$max_p" ]; then
    err "max_parallel_prs=$max_p reached ($in_flight in progress). Wait for a group to merge."
    exit 1
  fi

  local branch wt_rel wt_abs base
  branch="$(echo "$group" | jq -r .branch)"
  wt_rel="$(echo "$group" | jq -r .worktree)"
  wt_abs="$PROJECT_ROOT/$wt_rel"
  base="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].base_branch' "$STATE_FILE")"
  [ -n "$base" ] && [ "$base" != "null" ] || base="$(detect_base)"

  delivery_assert_branch "$branch" || exit 1
  groups_activate "$gid"

  (
    cd "$PROJECT_ROOT"
    git fetch origin "$base" 2>/dev/null || true
    local start_ref="origin/$base"
    git rev-parse --verify "$start_ref" >/dev/null 2>&1 || start_ref="$base"
    if [ -d "$wt_abs" ]; then
      log "Reusing worktree $wt_rel"
    else
      mkdir -p "$(dirname "$wt_abs")"
      if git show-ref --verify --quiet "refs/heads/$branch"; then
        git worktree add "$wt_abs" "$branch"
      else
        git worktree add -b "$branch" "$wt_abs" "$start_ref"
      fi
      sync_worktree_config "$wt_abs"
      harness_event "harness" "group_branch_created" "$branch"
      harness_event "harness" "group_worktree_created" "$wt_rel"
    fi
  )

  state_mutate --argjson idx "$GOAL_IDX" --arg gid "$gid" --arg branch "$branch" --arg wt "$wt_rel" --arg base "$base" '
    .[$idx].delivery_groups = [
      .[$idx].delivery_groups[]
      | if .id == $gid then . + {branch: $branch, worktree: $wt, status: (if .status == "planned" then "in_progress" else .status end)} else . end
    ]
    | .[$idx].branch = $branch
    | .[$idx].worktree = $wt
    | .[$idx].base_branch = $base
    | .[$idx].active_group_id = $gid
  '
  groups_activate "$gid"
  harness_event "main" "group_builder_ready" "$gid $branch"
  echo "$wt_rel"
  log "Group $gid ready: $branch @ $wt_rel"
}

cmd_groups_continue() {
  cmd_groups_start "$@"
}

cmd_groups_pr() {
  require_active_goal
  require_vcs_cli
  refresh_goal_idx
  local gid="${1:-}"
  [ -z "$gid" ] && { err "groups pr requires <group-id>"; exit 1; }
  groups_activate "$gid"

  local group root_goal title body tt slug
  group="$(delivery_group_by_id "$gid")"
  root_goal="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].goal' "$STATE_FILE")"
  tt="$(echo "$group" | jq -r .task_type)"
  slug="$(echo "$group" | jq -r .branch_slug)"
  title="$(echo "$group" | jq -r --arg tt "$tt" --arg slug "$slug" \
    '.pr_title // ($tt + "(" + $slug + "): " + .title)')"
  title="${title:0:250}"

  body="$(GROUP_JSON="$group" ROOT_GOAL="$root_goal" python3 -c '
import json, os
g = json.loads(os.environ["GROUP_JSON"])
root = os.environ.get("ROOT_GOAL", "")
deps = ", ".join(g.get("depends_on") or []) or "none"
tasks = ", ".join(g.get("task_ids") or []) or "none"
checks = "\n".join("- " + c for c in (g.get("acceptance_checks") or [])) or "- (none listed)"
files = "\n".join("- `" + f + "`" for f in (g.get("files") or [])) or "- (none listed)"
print("## Root Markdown goal\n" + root + "\n\n## Delivery group `" + str(g.get("id","")) + "`\n" + (g.get("title") or "") +
      "\n\n**Task type:** " + str(g.get("task_type")) + "\n**Branch:** `" + str(g.get("branch")) +
      "`\n**Planner tasks:** " + tasks + "\n**Depends on:** " + deps +
      "\n\n## Scope\n" + files + "\n\n## Acceptance checks\n" + checks +
      "\n\n## Excluded work\nWork belonging to other delivery groups in this Markdown goal is intentionally out of scope.\n\n## Why this split\n" + (g.get("reason") or "(not provided)"))
')"

  local branch base
  branch="$(echo "$group" | jq -r .branch)"
  base="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].base_branch' "$STATE_FILE")"
  delivery_assert_branch "$branch" || exit 1

  if [ "$(echo "$group" | jq -r '.pr_number // empty')" != "" ] && [ "$(echo "$group" | jq -r '.pr_number')" != "null" ]; then
    log "PR already exists for $gid: #$(echo "$group" | jq -r .pr_number)"
    echo "$group" | jq '{id, pr_number, pr_url}'
    return 0
  fi

  create_pr "" "$branch" "$base" "$title" "$body"
  state_mutate --argjson idx "$GOAL_IDX" --arg gid "$gid" \
    --argjson pn "$PR_RESULT_NUMBER" --arg url "$PR_RESULT_URL" --arg title "$title" '
    .[$idx].pr_number = $pn
    | .[$idx].pr_url = $url
    | .[$idx].delivery_groups = [
        .[$idx].delivery_groups[]
        | if .id == $gid then . + {pr_number: $pn, pr_url: $url, pr_title: $title} else . end
      ]
  '
  harness_event "main" "group_pr_created" "$gid #$PR_RESULT_NUMBER $PR_RESULT_URL"
  log "Created $gid PR: $PR_RESULT_URL"
}

cmd_groups_merge() {
  require_active_goal
  require_vcs_cli
  refresh_goal_idx
  local gid="${1:-}"
  [ -z "$gid" ] && { err "groups merge requires <group-id>"; exit 1; }
  groups_activate "$gid"
  local group pr_number pr_url wt_rel
  group="$(delivery_group_by_id "$gid")"
  pr_number="$(echo "$group" | jq -r '.pr_number // empty')"
  pr_url="$(echo "$group" | jq -r '.pr_url // empty')"
  wt_rel="$(echo "$group" | jq -r '.worktree // empty')"
  [ -n "$pr_number" ] && [ "$pr_number" != "null" ] || { err "No PR for group $gid — run groups pr first"; exit 1; }

  merge_pr "$pr_number" "$pr_url"

  if [ -n "$wt_rel" ] && [ -d "$PROJECT_ROOT/$wt_rel" ]; then
    (
      cd "$PROJECT_ROOT"
      git worktree remove "$PROJECT_ROOT/$wt_rel" --force 2>/dev/null \
        || git worktree remove "$PROJECT_ROOT/$wt_rel"
    )
    harness_event "harness" "group_worktree_removed" "$wt_rel"
  fi

  state_mutate --argjson idx "$GOAL_IDX" --arg gid "$gid" '
    .[$idx].delivery_groups = [
      .[$idx].delivery_groups[]
      | if .id == $gid then . + {status: "merged", worktree: ""} else . end
    ]
    | if .[$idx].active_group_id == $gid then .[$idx].active_group_id = null | .[$idx].worktree = "" else . end
  '
  harness_event "main" "group_merged" "$gid #$pr_number"
  harness_event "main" "group_deps_resolved" "$gid merged"
  log "Merged group $gid"
}

cmd_groups_complete() {
  require_active_goal
  refresh_goal_idx
  local gid="${1:-}"
  [ -z "$gid" ] && { err "groups complete requires <group-id>"; exit 1; }
  groups_persist_active
  state_mutate --argjson idx "$GOAL_IDX" --arg gid "$gid" '
    .[$idx].delivery_groups = [
      .[$idx].delivery_groups[]
      | if .id == $gid then . + {status: "completed"} else . end
    ]
  '
  log "Group $gid marked completed"
}

cmd_groups_cancel() {
  require_cmd git jq
  require_active_goal
  refresh_goal_idx
  local gid="${1:-}"
  [ -z "$gid" ] && { err "groups cancel requires <group-id>"; exit 1; }
  groups_persist_active
  local group wt_rel
  group="$(delivery_group_by_id "$gid")"
  [ -n "$group" ] || { err "Unknown delivery group: $gid"; exit 1; }
  wt_rel="$(echo "$group" | jq -r '.worktree // empty')"
  if [ -n "$wt_rel" ] && [ -d "$PROJECT_ROOT/$wt_rel" ]; then
    (
      cd "$PROJECT_ROOT"
      git worktree remove "$PROJECT_ROOT/$wt_rel" --force 2>/dev/null \
        || git worktree remove "$PROJECT_ROOT/$wt_rel"
    )
    harness_event "harness" "group_worktree_removed" "$wt_rel"
  fi
  state_mutate --argjson idx "$GOAL_IDX" --arg gid "$gid" '
    .[$idx].delivery_groups = [
      .[$idx].delivery_groups[]
      | if .id == $gid then . + {status: "cancelled", worktree: ""} else . end
    ]
    | if .[$idx].active_group_id == $gid then .[$idx].active_group_id = null | .[$idx].worktree = "" else . end
  '
  log "Group $gid cancelled"
}

cmd_groups_ready() {
  require_active_goal
  refresh_goal_idx
  jq --argjson idx "$GOAL_IDX" '
    .[$idx].delivery_groups // [] as $gs
    | [
        $gs[]
        | . as $g
        | ($g.depends_on // []) as $deps
        | if ($g.status == "merged" or $g.status == "completed") then empty
          elif ([$deps[] as $d | $gs[] | select(.id == $d) | .status] | all(. == "merged" or . == "completed"))
          then {id: $g.id, branch: $g.branch, status: $g.status, title: $g.title}
          else empty end
      ]
  ' "$STATE_FILE"
}

cmd_groups() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    list)     cmd_groups_list ;;
    init)     cmd_groups_init "${1:-}" ;;
    validate) cmd_groups_validate "${1:-}" ;;
    status)   cmd_groups_status "${1:-}" ;;
    activate) groups_activate "${1:-}" ;;
    start)    cmd_groups_start "${1:-}" ;;
    continue) cmd_groups_continue "${1:-}" ;;
    ready)    cmd_groups_ready ;;
    pr)       cmd_groups_pr "${1:-}" ;;
    merge)    cmd_groups_merge "${1:-}" ;;
    complete) cmd_groups_complete "${1:-}" ;;
    cancel)   cmd_groups_cancel "${1:-}" ;;
    persist)  groups_persist_active ;;
    *)
      err "groups subcommand must be: list, init, validate, status, activate, start, continue, ready, pr, merge, complete, cancel, persist"
      exit 1
      ;;
  esac
}
