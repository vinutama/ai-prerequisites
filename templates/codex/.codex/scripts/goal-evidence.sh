#!/usr/bin/env bash
# Evidence belongs to a committed implementation, and comes from confirmed agents.

harness_invalidate() {
  [ -f "$STATE_FILE" ] || return 0
  jq -e --argjson idx "$GOAL_IDX" '.[$idx].harness != null' "$STATE_FILE" >/dev/null || return 0
  state_mutate --argjson idx "$GOAL_IDX" --arg reason "$1" '
    reduce ["ANALYSIS","VERIFICATION","REVIEW","QA","VISUAL"][] as $k (.;
      if .[$idx].harness.gates[$k].status == "SKIPPED" then . else
        .[$idx].harness.gates[$k] = {status:"NOT_RUN",reason:$reason} end)
    | .[$idx].harness.repo_gates = {}
    | .[$idx].harness.context |= del(.review_verdict, .repo_review_verdict, .verification_report, .verification_reports)
  '
}

harness_completed_role() {
  local role="$1" sha
  sha=$(implementation_fingerprint) || return
  jq -e --argjson idx "$GOAL_IDX" --arg repo "${GOAL_REPO:-.}" --arg role "$role" --arg sha "$sha" '
    any((.[$idx].harness.spawn_reservations // [])[];
      .role == $role and .agent_id != null and .state == "completed" and .closed == true and .sha == $sha and (.repo // ".") == $repo)
  ' "$STATE_FILE" >/dev/null || {
    goal_error missing_agent "Evidence requires a confirmed, completed, closed $role agent"; return 1;
  }
}

harness_review_verdict_ok() {
  local sha
  harness_completed_role reviewer || return
  sha=$(implementation_fingerprint) || return
  jq -e --arg repo "${GOAL_REPO:-.}" --argjson idx "$GOAL_IDX" --arg sha "$sha" '
    (.[$idx].harness.context.repo_review_verdict[$repo] // .[$idx].harness.context.review_verdict) | .verdict == "LGTM" and .sha == $sha
  ' "$STATE_FILE" >/dev/null || {
    goal_error missing_review "Persist the reviewer's LGTM verdict with the reviewed sha before REVIEW PASS"; return 1;
  }
}

forge_target() {
  local wd="$1" identity
  identity=$(delivery_repo "$wd") || return
  local cli=gh
  [ "$platform" != gitlab ] || cli=glab
  forge_api_repo "$cli" "$identity" || return
  FORGE_TARGET_HOST="$FORGE_API_HOST"
  FORGE_TARGET_PATH="${FORGE_API_PATH#repos/}"
  [ "$cli" != glab ] || FORGE_TARGET_PATH="${identity#*://}"; 
  if [ "$cli" = glab ] && [[ "$identity" == *://* ]]; then FORGE_TARGET_PATH="${FORGE_TARGET_PATH#*/}"; fi
  FORGE_TARGET_REPO="$identity"
  FORGE_TARGET_ENCODED=$(printf '%s' "$FORGE_TARGET_PATH" | jq -sRr @uri)
}

cmd_doctor() {
  local data role missing='[]' selected="$platform" idx
  if [ -f "$STATE_FILE" ] && idx=$(resolve_goal_idx 2>/dev/null); then
    selected=$(jq -r --argjson idx "$idx" --arg fallback "$selected" '.[$idx].source.platform // .[$idx].platform // $fallback' "$STATE_FILE")
  fi
  data=$(forge_doctor "${selected/unknown/}") || true
  [ -n "$data" ] || return 1
  for role in planner researcher builder builder-expert reviewer qa visual-reviewer; do
    if ! delegation_role_config "$role" >/dev/null 2>&1; then
      missing=$(printf '%s' "$missing" | jq --arg role "$role" '. + [$role]')
    fi
  done
  printf '%s' "$data" | jq --arg codex "$(codex --version 2>/dev/null || true)" --arg root "$PROJECT_ROOT" --argjson invalid "$missing" \
    '. + {codex_version:$codex,invalid_roles:$invalid,workflow_root:$root,ready:(.ready and $codex != "" and ($invalid | length)==0)}'
}
