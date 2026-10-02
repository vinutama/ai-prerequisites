# Git delivery guards. No forge operation is inferred from the shell cwd.

delivery_repo() {
  local wd="$1" remote override
  local key="${wd#"$PROJECT_ROOT"/}"
  [ "$wd" != "$PROJECT_ROOT" ] || key=.
  case "$key" in .worktrees/*) key=. ;; esac
  override=$(jq -r --arg key "$key" '.forge_repos[$key] // empty' "$CONFIG_FILE")
  if [ -z "$override" ]; then
    override=$(config_read forge_repo)
    if [ -n "$override" ] && is_multi_repo; then goal_error configuration "Use forge_repos per repository instead of one forge_repo for a multi-repo goal"; return 1; fi
  fi
  [ -z "$override" ] || { printf '%s\n' "$override"; return; }
  remote=$(git -C "$wd" remote get-url origin) || return
  python3 - "$platform" "$remote" <<'PY'
import re,sys
from urllib.parse import urlsplit
platform,remote=sys.argv[1:]
if re.match(r'^[^/@:]+@[^/:]+:',remote):
    host,path=remote.split('@',1)[1].split(':',1)
else:
    u=urlsplit(remote);host=u.hostname;path=u.path.strip('/')
if not host or not path: raise SystemExit('Forge identity missing; configure forge_repo for a local transport')
path=re.sub(r'\.git$','',path)
print(('' if host=='github.com' else host+'/')+path if platform=='github' else 'https://'+host+'/'+path)
PY
}

delivery_clean() {
  local wd="$1"
  [ -z "$(git -C "$wd" status --porcelain)" ] || {
    goal_error dirty_checkout "Uncommitted changes remain in $wd" "Stage and commit scoped changes, then verify and review again."; return 1;
  }
}

delivery_prepare() {
  local wd="$1" branch="$2" base="$3" sha remote_sha
  context_assert_branch "$wd" "$branch" || return
  delivery_clean "$wd" || return
  git -C "$wd" fetch origin "+refs/heads/$base:refs/remotes/origin/$base" >&2 || {
    goal_error fetch "Cannot refresh target branch $base"; return 1;
  }
  git -C "$wd" merge-base "origin/$base" HEAD >/dev/null || return
  if git -C "$wd" diff --quiet "origin/$base...HEAD"; then
    goal_error empty_diff "No changes to publish against $base" "Keep this goal incomplete; inspect staged work, task integration, and whether the target already contains the change."; return 1
  fi
  sha=$(git -C "$wd" rev-parse HEAD)
  remote_sha=$(git -C "$wd" ls-remote --exit-code origin "refs/heads/$branch" | awk '{print $1}') || {
    goal_error unpublished "Source branch $branch has not been pushed" "Run the assigned helper push command."; return 1;
  }
  [ "$sha" = "$remote_sha" ] || {
    goal_error stale_remote "Remote source branch differs from the local implementation" "Push the reviewed commit and retry delivery."; return 1;
  }
  printf '%s\n' "$sha"
}

delivery_validate_metadata() {
  local meta="$1" branch="$2" base="$3" sha="$4"
  printf '%s' "$meta" | jq -e --arg branch "$branch" --arg base "$base" --arg sha "$sha" '
    (.number | type) == "number" and .number > 0 and (.url | type) == "string" and
    .head == $branch and .base == $base and .sha == $sha and
    (.state == "open" or .state == "opened") and (.files | type) == "array" and (.files | length) > 0
  ' >/dev/null || {
    goal_error delivery_metadata "PR/MR metadata does not match the published commit, target, or nonempty diff"; return 1;
  }
}

delivery_current_pr() {
  local wd="$1" number="$2" branch base repo metadata
  branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch' "$STATE_FILE")
  base=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].base_branch' "$STATE_FILE")
  repo=$(delivery_repo "$wd") || return
  metadata=$(forge_pr_metadata "$platform" "$repo" "$branch" "$base") || return
  printf '%s' "$metadata" | jq -e --argjson n "$number" '.number == $n' >/dev/null || {
    goal_error stale_delivery "The recorded PR/MR no longer matches this repository, source branch, and target"; return 1;
  }
  printf '%s\n' "$metadata"
}

delivery_remote_request() {
  local wd="$1" number="$2"
  forge_target "$wd" || return
  if [ "$platform" = github ]; then
    forge_run read gh api "$FORGE_API_PATH/pulls/$number" --hostname "$FORGE_API_HOST" --method GET
  else
    forge_run read glab api "$FORGE_API_PATH/merge_requests/$number" --hostname "$FORGE_API_HOST" --method GET
  fi
}

delivery_merged_request_ok() {
  local metadata="$1" number="$2" branch="$3" base="$4" sha="$5"
  printf '%s' "$metadata" | jq -e --arg platform "$platform" --argjson n "$number" --arg head "$branch" --arg base "$base" --arg sha "$sha" '
    if $platform == "github" then
      .merged == true and .number == $n and .head.ref == $head and .base.ref == $base and
      .head.sha == $sha and .head.repo.full_name == .base.repo.full_name and .head.repo.full_name != null
    else
      .state == "merged" and .iid == $n and .source_branch == $head and .target_branch == $base and
      (.sha // .diff_refs.head_sha) == $sha and .source_project_id == .target_project_id and .source_project_id != null
    end
  ' >/dev/null
}

pr_suggest_title() {
  local branch type scope subject raw suggested
  branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch // empty' "$STATE_FILE")
  type=$(printf '%s' "$branch" | awk -F/ '{print $1}')
  case "$type" in feat|fix|docs|refactor|perf|test|chore|build|ci|bug) ;;
    *) type="feat" ;; esac
  [ "$type" = bug ] && type=fix
  raw=$(jq -r --argjson idx "$GOAL_IDX" '
    .[$idx].pr_title // .[$idx].source.title // .[$idx].issue.title //
    (.[$idx].goal | split("\n")[0]) // "implement changes"
  ' "$STATE_FILE")
  # If already conventional, keep it (truncated).
  if printf '%s' "$raw" | python3 -c '
import re,sys
s=sys.stdin.read().strip()
sys.exit(0 if re.match(r"^(feat|fix|docs|refactor|perf|test|chore|build|ci)(\([a-z0-9-]+\))?!?: [^A-Z].+$", s) and len(s)<=72 else 1)
'; then
    printf '%s\n' "$raw"
    return
  fi
  subject=$(printf '%s' "$raw" | python3 -c '
import re,sys
s=sys.stdin.read().strip()
s=re.sub(r"^\[[^\]]+\]\s*","",s)
s=re.sub(r"^(feat|fix|docs|refactor|perf|test|chore|build|ci)(\([^)]*\))?!?:\s*","",s,flags=re.I)
s=re.sub(r"\s+"," ",s).strip(" .")
s=re.split(r"[.—;]",s)[0].strip()
words=s.split()
if words:
    w=words[0]
    if w[:1].isupper() and not w.isupper():
        words[0]=w[0].lower()+w[1:]
    s=" ".join(words[:10])
if not s:
    s="implement changes"
# Ensure subject does not start with uppercase
if s and s[0].isupper() and not s.isupper():
    s=s[0].lower()+s[1:]
print(s)
')
  scope=$(printf '%s' "$branch" | python3 -c '
import re,sys
b=sys.stdin.read().strip()
parts=b.split("/",1)
slug=parts[1] if len(parts)>1 else b
slug=re.sub(r"^\d+-","",slug)
# Prefer a meaningful token that is not just g1/g2 group ids alone when longer slug exists
tokens=[t for t in slug.split("-") if t]
token=""
for t in tokens:
    if re.match(r"^[a-z][a-z0-9-]{1,19}$", t) and not re.match(r"^g\d+$", t):
        token=t; break
if not token and tokens:
    token=tokens[0] if re.match(r"^[a-z0-9-]{2,20}$", tokens[0]) else ""
print(token)
')
  if [ -n "$scope" ]; then
    suggested="${type}(${scope}): ${subject}"
  else
    suggested="${type}: ${subject}"
  fi
  printf '%s' "$suggested" | python3 -c '
import sys
s=sys.stdin.read().strip()
if len(s)>72:
    s=s[:72].rstrip(" -:")
print(s)
'
}

pr_metadata_args() {
  local title="" file="" default_title="$1" title_explicit=false
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) [ $# -ge 2 ] || return 1; title="$2"; title_explicit=true; shift 2 ;;
      --body-file) [ $# -ge 2 ] || return 1; file="$2"; shift 2 ;;
      *) goal_error arguments "Unknown PR metadata argument: $1"; return 1 ;;
    esac
  done
  [ -n "$title" ] || title=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].pr_title // empty' "$STATE_FILE")
  [ -n "$title" ] || title="$default_title"
  local suggested
  suggested=$(pr_suggest_title)
  if ! printf '%s' "$title" | python3 -c '
import re,sys
s=sys.stdin.read()
ok = s.strip()==s and s and len(s)<=72 and not any(c in s for c in "\r\n\t")
ok = ok and bool(re.match(r"^(feat|fix|docs|refactor|perf|test|chore|build|ci)(\([a-z0-9-]+\))?!?: [^A-Z].+$", s))
sys.exit(0 if ok else 1)
'; then
    if [ "$title_explicit" = false ] && [ -n "$suggested" ]; then
      title="$suggested"
    else
      goal_error pr_title \
        "PR/MR title must be conventional, one line, ≤72 chars (e.g. feat(grab): enforce per-key rate limit)" \
        "Suggested: $suggested — supply --title with a rewritten concise title."
      return 1
    fi
  fi
  # Re-validate after auto-suggest
  printf '%s' "$title" | python3 -c '
import re,sys
s=sys.stdin.read()
ok = s.strip()==s and s and len(s)<=72 and not any(c in s for c in "\r\n\t")
ok = ok and bool(re.match(r"^(feat|fix|docs|refactor|perf|test|chore|build|ci)(\([a-z0-9-]+\))?!?: [^A-Z].+$", s))
sys.exit(0 if ok else 1)
' || {
    goal_error pr_title \
      "PR/MR title must be conventional, one line, ≤72 chars (e.g. feat(grab): enforce per-key rate limit)" \
      "Suggested: $suggested — supply --title with a rewritten concise title."
    return 1
  }
  local body
  if [ -n "$file" ]; then
    [ -f "$file" ] || { goal_error pr_body "Body file missing: $file"; return 1; }
    body=$(cat "$file")
  else
    body=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].pr_body // empty' "$STATE_FILE")
  fi
  [ -n "$body" ] || {
    goal_error pr_body "Provide --body-file with implementation summary, actual checks, and references" \
      "Run: goal-git.sh pr draft then edit the Summary section and pass --body-file."
    return 1
  }
  if printf '%s' "$body" | grep -Eq 'REWRITE_THIS_SUMMARY|TODO: rewrite summary|\(MAIN must rewrite'; then
    goal_error pr_body "PR/MR body still contains the Summary placeholder" \
      "Edit the body file Summary section (2-4 sentences of actual changes), then retry pr --body-file."
    return 1
  fi
  state_mutate --argjson idx "$GOAL_IDX" --arg title "$title" --arg body "$body" \
    '.[$idx].pr_title=$title | .[$idx].pr_body=$body' || return
  PR_TITLE="$title"; PR_BODY="$body"
}

cmd_pr_draft() {
  require_active_goal; refresh_goal_idx
  local group_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --group) [ $# -ge 2 ] || return 1; group_id="$2"; shift 2 ;;
      *) goal_error arguments "Unknown pr draft argument: $1"; return 1 ;;
    esac
  done
  if [ -n "$group_id" ]; then
    if declare -F groups_activate >/dev/null; then
      groups_activate "$group_id" || return
    else
      GOAL_GROUP="$group_id"
      refresh_goal_idx || return
    fi
  fi
  local wd branch base title body_file commits stats verify_json review_bits refs
  wd=$(repo_dir "${GOAL_REPO:-.}") || return
  branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch' "$STATE_FILE")
  base=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].base_branch' "$STATE_FILE")
  title=$(pr_suggest_title)
  mkdir -p "$PROJECT_ROOT/.codex/pr-drafts"
  body_file="$PROJECT_ROOT/.codex/pr-drafts/$(slugify "$branch").md"
  commits=$(git -C "$wd" log --oneline "origin/${base}..HEAD" 2>/dev/null | head -20 || true)
  stats=$(git -C "$wd" diff --stat "origin/${base}...HEAD" 2>/dev/null || true)
  verify_json=$(jq -c --argjson idx "$GOAL_IDX" --arg repo "${GOAL_REPO:-.}" '
    .[$idx].harness.context.verification_reports[$repo]
    // .[$idx].harness.context.verification_report // null
  ' "$STATE_FILE")
  review_bits=$(jq -r --argjson idx "$GOAL_IDX" '
    .[$idx].harness as $h |
    "- REVIEW: \($h.gates.REVIEW.status // "NOT_RUN")\n" +
    "- QA: \($h.gates.QA.status // "SKIPPED / NOT_RUN")\n" +
    "- VISUAL: \($h.gates.VISUAL.status // "SKIPPED / NOT_RUN")"
  ' "$STATE_FILE")
  refs=$(jq -r --argjson idx "$GOAL_IDX" '
    if .[$idx].issue.number then "Closes #\(.[$idx].issue.number)"
    elif .[$idx].source.type == "jira" then "Jira: \(.[$idx].source.reference // "")"
    elif .[$idx].source.type == "markdown" then "Markdown: \(.[$idx].source.reference // "")"
    else "Source: \(.[$idx].source.type // "prompt")" end
  ' "$STATE_FILE")

  {
    printf '## Summary\n\n'
    printf 'REWRITE_THIS_SUMMARY: Replace this paragraph with 2-4 sentences describing the actual changes.\n\n'
    printf '## Changes\n\n'
    if [ -n "$commits" ]; then
      printf '%s\n\n' "$commits"
    else
      printf '(no commits ahead of origin/%s yet)\n\n' "$base"
    fi
    if [ -n "$stats" ]; then
      printf '```\n%s\n```\n\n' "$stats"
    fi
    printf '## Verification\n\n'
    if [ "$verify_json" != "null" ]; then
      printf '%s\n' "$verify_json" | jq -r '
        "- overall: \(.overall // "?") @ \(.sha // "?")",
        ((.results // [])[] | "- \(.name): \(.status) (\(.command))")
      '
      printf '\n'
    else
      printf '(no verification_report stored yet)\n\n'
    fi
    printf '## Review\n\n%s\n\n' "$review_bits"
    printf '## References\n\n%s\n' "$refs"
  } > "$body_file"

  jq -n --arg title "$title" --arg body_file "$body_file" \
    '{title_suggestion:$title,body_file:$body_file}'
}

cmd_pr() {
  [ -z "${GOAL_TASK:-}" ] || { goal_error assignment "Integrate task worktrees and clear GOAL_TASK before PR/MR delivery"; return 1; }
  require_active_goal; refresh_goal_idx; require_vcs_cli
  local mode gid
  mode=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].delivery_mode // "single"' "$STATE_FILE")
  gid=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].active_group_id // empty' "$STATE_FILE")
  if [ "$mode" = multi-pr ]; then
    [ -n "$gid" ] || { goal_error assignment "Refusing aggregation PR/MR; use groups pr <id>"; return 1; }
    cmd_groups_pr "$gid" "$@"; return
  fi
  local title branch base repo
  title=$(pr_suggest_title)
  pr_metadata_args "$title" "$@" || return
  branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch' "$STATE_FILE")
  base=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].base_branch' "$STATE_FILE")
  local repos
  repos=$(jq -r --argjson idx "$GOAL_IDX" 'if (.[$idx].repos // [] | length) == 0 then ["."] else [.[$idx].repos[].path] end | .[]' "$STATE_FILE")
  while IFS= read -r repo; do
    create_pr "$repo" "$branch" "$base" "$PR_TITLE" "$PR_BODY" || return
    state_mutate --argjson idx "$GOAL_IDX" --arg repo "$repo" --argjson n "$PR_RESULT_NUMBER" \
      --arg url "$PR_RESULT_URL" --argjson delivery "$PR_RESULT_DELIVERY" '
      .[$idx].repos |= ((. // []) | map(if .path == $repo then . + {pr_number:$n,pr_url:$url,delivery:$delivery} else . end))
      | if $repo == "." then .[$idx] += {pr_number:$n,pr_url:$url,delivery:$delivery} else . end
    ' || return
  done <<< "$repos"
  groups_persist_active
}

create_pr() {
  local repo_path="$1" branch="$2" base="$3" title="$4" body="$5" wd repo sha file meta attempt issue
  wd=$(repo_dir "${repo_path:-.}") || return
  sha=$(delivery_prepare "$wd" "$branch" "$base") || return
  repo=$(delivery_repo "$wd") || return
  issue=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].issue.number // empty' "$STATE_FILE")
  if [ -n "$issue" ] && ! printf '%s' "$body" | grep -Eq "(Closes|Fixes|Resolves) #$issue([^0-9]|$)"; then
    local issue_repo
    issue_repo=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].issue.repo // empty' "$STATE_FILE")
    if [ -z "$issue_repo" ] || [ "$issue_repo" = "$repo" ]; then
      body="${body}

Closes #${issue}"
    else
      body="${body}

Related issue: $(jq -r --argjson idx "$GOAL_IDX" '.[$idx].issue.url' "$STATE_FILE")"
    fi
  fi
  file=$(mktemp); printf '%s\n' "$body" > "$file"
  # Upsert reconciles uncertain outcomes, and never retries creation blindly.
  meta=$(forge_pr_upsert "$platform" "$repo" "$branch" "$base" "$title" "$file") || { rm -f "$file"; return 1; }
  rm -f "$file"
  attempt=0
  while ! delivery_validate_metadata "$meta" "$branch" "$base" "$sha"; do
    attempt=$((attempt + 1)); [ "$attempt" -lt 3 ] || return 1
    sleep "${GOAL_METADATA_RETRY_DELAY:-2}"
    meta=$(forge_pr_metadata "$platform" "$repo" "$branch" "$base") || return
  done
  PR_RESULT_NUMBER=$(printf '%s' "$meta" | jq -r .number)
  PR_RESULT_URL=$(printf '%s' "$meta" | jq -r .url)
  PR_RESULT_DELIVERY=$(printf '%s' "$meta" | jq --arg repo "$repo" --arg sha "$sha" '. + {repo:$repo,verified_sha:$sha,validated:true}')
  log "Validated delivery: $PR_RESULT_URL @ $sha"
}

delivery_require_complete() {
  local repo wd branch sha
  jq -e --argjson idx "$GOAL_IDX" '
    .[$idx] | if (.repos // [] | length) > 0 then
      all(.repos[]; .delivery.validated == true and (.pr_url // "") != "")
    else .delivery.validated == true and (.pr_url // "") != "" end
  ' "$STATE_FILE" >/dev/null || { goal_error delivery "Completion requires validated PR/MR delivery for every repository"; return 1; }
  while IFS= read -r repo; do
    wd=$(repo_dir "$repo") || return
    branch=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].branch' "$STATE_FILE")
    context_assert_branch "$wd" "$branch" || return
    delivery_clean "$wd" || return
    sha=$(git -C "$wd" rev-parse HEAD)
    jq -e --argjson idx "$GOAL_IDX" --arg repo "$repo" --arg sha "$sha" '
      .[$idx] | (if (.repos // [] | length) > 0 then .repos[] | select(.path == $repo) else . end)
      | .delivery.verified_sha == $sha
    ' "$STATE_FILE" >/dev/null || { goal_error stale_evidence "Delivered SHA differs from the current implementation"; return 1; }
  done < <(jq -r --argjson idx "$GOAL_IDX" 'if (.[$idx].repos // [] | length) > 0 then .[$idx].repos[].path else "." end' "$STATE_FILE")
}

implementation_fingerprint() {
  local wd sha tree
  wd=$(repo_dir "${GOAL_REPO:-.}") || return
  delivery_clean "$wd" || return
  context_assert_branch "$wd" || return
  sha=$(git -C "$wd" rev-parse HEAD)
  printf '%s\n' "$sha"
}

harness_require_current_evidence() {
  local sha required repo wd multiple=false
  required=$(jq -c --argjson idx "$GOAL_IDX" '.[$idx].harness.requirements |
    ["ANALYSIS","VERIFICATION"] + (if .reviewer == false then [] else ["REVIEW"] end)
    + (if .qa == true then ["QA"] else [] end) + (if .visual == true then ["VISUAL"] else [] end)' "$STATE_FILE")
  is_multi_repo && multiple=true
  while IFS= read -r repo; do
    wd=$(repo_dir "$repo") || return
    delivery_clean "$wd" || return
    context_assert_branch "$wd" || return
    sha=$(git -C "$wd" rev-parse HEAD)
    jq -e --argjson idx "$GOAL_IDX" --arg repo "$repo" --argjson multiple "$multiple" --arg sha "$sha" --argjson req "$required" '
      .[$idx].harness as $h
      | (if $multiple then ($h.repo_gates[$repo] // {}) else $h.gates end) as $g
      | all($req[]; $g[.].sha == $sha and $g[.].status == "PASS")
    ' "$STATE_FILE" >/dev/null || {
      goal_error stale_evidence "Analysis, verification, or review evidence is missing or belongs to another commit in repository $repo"; return 1;
    }
  done < <(jq -r --argjson idx "$GOAL_IDX" 'if (.[$idx].repos // [] | length) > 0 then .[$idx].repos[].path else "." end' "$STATE_FILE")
}
