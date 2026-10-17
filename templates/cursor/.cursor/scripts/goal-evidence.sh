#!/usr/bin/env bash
# Evidence belongs to a committed implementation, and comes from confirmed agents.

harness_invalidate() {
  [ -f "$STATE_FILE" ] || return 0
  jq -e --argjson idx "$GOAL_IDX" '.[$idx].harness != null' "$STATE_FILE" >/dev/null || return 0
  state_mutate --argjson idx "$GOAL_IDX" --arg reason "$1" '
    reduce ["ANALYSIS","VERIFICATION","REVIEW","VISUAL"][] as $k (.;
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
    goal_error missing_agent "Evidence requires a confirmed, completed, closed $role agent for this commit" \
      "Launch the $role (harness spawn $role <model> <effort>, brief, launch, spawn-confirm) and close it with spawn-finish <agent-id> completed --closed; use harness reap if its reservation is from a dead session"; return 1;
  }
}

harness_review_verdict_ok() {
  local sha
  harness_completed_role reviewer || return
  sha=$(implementation_fingerprint) || return
  jq -e --arg repo "${GOAL_REPO:-.}" --argjson idx "$GOAL_IDX" --arg sha "$sha" '
    (.[$idx].harness.context.repo_review_verdict[$repo] // .[$idx].harness.context.review_verdict) | .verdict == "LGTM" and .sha == $sha
  ' "$STATE_FILE" >/dev/null || {
    goal_error missing_review "Persist the reviewer's LGTM verdict with the reviewed sha before REVIEW PASS" \
      "Run: harness context put review_verdict - with {\"verdict\":\"LGTM\",\"sha\":\"<current commit>\"} from the reviewer's report; if findings remain use harness retry rework and harness phase REWORK"; return 1;
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

# CLI binary that hosts the running platform's sessions.
platform_cli_name() {
  case "${AGENT_PLATFORM:-}" in
    cursor) printf 'cursor-agent' ;;
    claude) printf 'claude' ;;
    *) printf 'codex' ;;
  esac
}

cmd_doctor() {
  local data role missing='[]' selected="$platform" idx cli cli_version="" clis='{}' name version tools
  if [ -f "$STATE_FILE" ] && idx=$(resolve_goal_idx 2>/dev/null); then
    selected=$(jq -r --argjson idx "$idx" --arg fallback "$selected" '.[$idx].source.platform // .[$idx].platform // $fallback' "$STATE_FILE")
  fi
  data=$(forge_doctor "${selected/unknown/}") || true
  [ -n "$data" ] || return 1
  for role in planner researcher builder builder-expert reviewer visual-reviewer; do
    if ! delegation_role_config "$role" >/dev/null 2>&1; then
      missing=$(printf '%s' "$missing" | jq --arg role "$role" '. + [$role]')
    fi
  done
  cli=$(platform_cli_name)
  cli_version=$("$cli" --version 2>/dev/null | head -n 1 || true)
  for name in codex cursor-agent claude; do
    version=""
    if command -v "$name" >/dev/null 2>&1; then version=$("$name" --version 2>/dev/null | head -n 1 || true); fi
    clis=$(printf '%s' "$clis" | jq --arg n "$name" --arg v "$version" --argjson i "$(command -v "$name" >/dev/null 2>&1 && echo true || echo false)" \
      '. + {($n):{installed:$i,version:$v}}')
  done
  tools=$(jq -n \
    --argjson rtk "$(command -v rtk >/dev/null 2>&1 && echo true || echo false)" \
    --argjson npx "$(command -v npx >/dev/null 2>&1 && echo true || echo false)" \
    --argjson gitnexus "$({ [ -f "$PROJECT_ROOT/.gitnexus/run.cjs" ] || command -v gitnexus >/dev/null 2>&1; } && echo true || echo false)" \
    '{rtk:$rtk,npx:$npx,gitnexus:$gitnexus}')
  printf '%s' "$data" | jq --arg codex "$(codex --version 2>/dev/null || true)" --arg root "$PROJECT_ROOT" --argjson invalid "$missing" \
    --arg platform "${AGENT_PLATFORM:-}" --arg cli "$cli" --arg cli_version "$cli_version" --argjson clis "$clis" --argjson tools "$tools" \
    '. + {codex_version:$codex,platform:$platform,platform_cli:{name:$cli,installed:($cli_version != ""),version:$cli_version},
          clis:$clis,tools:$tools,invalid_roles:$invalid,workflow_root:$root,
          analyze_ready:($tools.rtk and ($tools.gitnexus or $tools.npx)),
          ready:(.ready and $cli_version != "" and ($invalid | length)==0)}'
}
