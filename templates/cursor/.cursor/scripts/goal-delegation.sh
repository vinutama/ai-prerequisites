#!/usr/bin/env bash
# Sourced by goal-git.sh before dispatch. No launch/network calls happen here.
# spawn reserves; spawn-confirm records a real agent ID and charges metrics once.
# spawn-fail uncertain holds capacity until an explicit confirm/definitive fail.
# spawn-finish <agent> completed|failed [--closed] keeps cumulative run metrics.
# Goal-level spawn_reservations is the durable ledger across group switches and
# harness re-init; harness.spawn_reservations is the current group's projection.
# All checks and writes use state_mutate's shared lock, including group mirrors.

models_role_multimodal() {
  local models_file="$1" role="$2"
  [ "$role" = visual-reviewer ] && return 0
  jq -e --arg role "$role" '
    .[$role].capabilities.multimodal == true or
    ."$routing"[$role].capabilities.multimodal == true or
    any(."$routing"[$role][]?; type == "object" and .capabilities.multimodal == true)
  ' "$models_file" >/dev/null 2>&1
}

cmd_models() {
  require_cmd jq
  local models_file="$PROJECT_ROOT/$AGENT_CONFIG_DIR/goal-models.json"
  [ -f "$models_file" ] || { err "goal-models.json not found: $models_file"; return 1; }
  local role="${1:-}" level=NORMAL vision=false candidate="" current="" resolved
  [ -n "$role" ] || { jq . "$models_file"; return; }
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --complexity)
        [ $# -ge 2 ] || { err '--complexity requires a level'; return 1; }
        level="$2"; shift 2 ;;
      --require-multimodal)
        vision=true; shift
        if [ $# -gt 0 ] && [[ "$1" != --* ]]; then candidate="$1"; shift; fi ;;
      --next)
        [ $# -ge 2 ] && [ -n "$2" ] && [[ "$2" != --* ]] || { err '--next requires a model'; return 1; }
        current="$2"; shift 2 ;;
      *) err "Unknown models argument: $1"; return 1 ;;
    esac
  done
  case "$level" in TRIVIAL|NORMAL|COMPLEX|ARCHITECTURAL) ;; *) err "Invalid complexity: $level"; return 1 ;; esac
  if [ -n "$candidate" ] && [ -n "$current" ] && [ "$candidate" != "$current" ]; then
    err '--require-multimodal candidate conflicts with --next model'; return 1
  fi
  models_role_multimodal "$models_file" "$role" && vision=true
  if jq -e --arg role "$role" --arg level "$level" '
    (."$routing"[$role] // {}) | has($level) and .[$level] == null
  ' "$models_file" >/dev/null; then
    err "Role '$role' skipped for $level complexity (null routing)"; return 2
  fi
  resolved="$(jq -cer --arg role "$role" --arg level "$level" --arg candidate "$candidate" \
    --arg current "$current" --argjson vision "$vision" '
    def nonempty: type == "string" and length > 0 and (test("[\\s,]") | not);
    def effort: .model_reasoning_effort // .effort // "medium";
    . as $config
    | (.[$role] // {}) as $legacy
    | (."$routing"[$role][$level] // $legacy) as $r
    | if (has($role) or ((."$routing" // {}) | has($role))) | not
      then error("Unknown role: " + $role) else . end
    | ($r.model // $legacy.model) as $primary
    | ($r.model_reasoning_effort // $r.effort // ($legacy | effort)) as $effort
    | if ($primary | nonempty) | not then error("No configured model for " + $role + " at " + $level) else . end
    | ([$primary] + ($r.fallback_models // []) + ($legacy.fallback_models // []))
    | map(if type == "string" then {model: ., effort: $effort}
          elif type == "object" then {model: .model, effort: (.model_reasoning_effort // .effort // $effort)}
          else error("Invalid fallback entry") end)
    | reduce .[] as $m ([]; if any(.[]; .model == $m.model) then . else . + [$m] end)
    | if all(.[]; (.model | nonempty) and (.effort | IN("minimal", "low", "medium", "high", "xhigh"))) | not
      then error("Invalid model/effort in configured chain") else . end
    | . as $chain
    | (if $current != "" then $current elif $candidate != "" then $candidate else $primary end) as $start
    | (map(.model) | index($start)) as $pos
    | if $pos == null then error("Model is outside the authorized role chain: " + $start) else . end
    | .[($pos + (if $current != "" then 1 else 0 end)):]
    | map(select($vision == false or .model == "inherit" or (.model as $m | ($config."$capabilities".vision_models // [] | index($m)) != null)))
    | if length == 0 then error("No eligible fallback/model remains for " + $role + " after " + $start) else . end
    | {model: .[0].model, effort: .[0].effort, fallback: (.[1:] | map(.model) | join(",")),
       changed: ($current == "" and .[0].model != $start), from: $start}
  ' "$models_file")" || return 1
  if [ "$(printf '%s' "$resolved" | jq -r .changed)" = true ]; then
    warn "Multimodal requirement selects configured fallback $(printf '%s' "$resolved" | jq -r .model) instead of $(printf '%s' "$resolved" | jq -r .from)"
  fi
  printf '%s' "$resolved" | jq -r '[.model, .effort, .fallback] | @tsv'
}

# Dynamic scope makes harness_require, state_mutate and the main lock helpers
# operate on the same shared file. Do not maintain a second worktree ledger.
delegation_shared() {
  local STATE_FILE="$STATE_FILE"
  local STATE_LOCK_DIR="${STATE_LOCK_DIR:-$(dirname "$STATE_FILE")/$AGENT_CONFIG_DIR/.state.lock}"
  # A group view must stay distinct from the shared input: context_project_group
  # redirects into STATE_FILE. Binding that to the actual file would truncate it.
  if [ -z "${GOAL_GROUP:-}" ] || [ -z "${GROUP_STATE_VIEW:-}" ]; then
    STATE_FILE="${SHARED_STATE_FILE:-$STATE_FILE}"
  fi
  if [ -n "${SHARED_STATE_FILE:-}" ]; then
    STATE_LOCK_DIR="$(dirname "$SHARED_STATE_FILE")/$AGENT_CONFIG_DIR/.state.lock"
  fi
  harness_require || return 1
  "$@"
}

# Parse role config for the active platform. Codex uses TOML; Cursor uses
# Markdown frontmatter (and may pin model there — that is intentional).
delegation_role_config() {
  local role="$1"
  [[ "$role" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || { err "Invalid role name: $role"; return 1; }
  require_cmd python3
  if [ "${AGENT_PLATFORM:-}" = "cursor" ]; then
    python3 - "$PROJECT_ROOT/$AGENT_CONFIG_DIR/agents/$role.md" "$role" <<'PY'
import sys
path, expected = sys.argv[1], sys.argv[2]
try:
    text = open(path, encoding="utf-8").read()
except OSError as e:
    sys.exit("Invalid role markdown " + path + ": " + str(e))
if not text.startswith("---"):
    sys.exit("Invalid role markdown " + path + ": missing opening frontmatter delimiter")
parts = text.split("---", 2)
if len(parts) < 3:
    sys.exit("Invalid role markdown " + path + ": missing closing frontmatter delimiter")
frontmatter, body = parts[1], parts[2]
name = None
for line in frontmatter.splitlines():
    raw = line.strip()
    if raw.startswith("name:"):
        name = raw.split(":", 1)[1].strip().strip('"').strip("'")
        break
if name != expected:
    sys.exit("Invalid role markdown " + path + ": name must match requested role " + expected)
if not body.strip():
    sys.exit("Invalid role markdown " + path + ": body after frontmatter must be nonempty")
PY
    return
  fi
  python3 - "$PROJECT_ROOT/$AGENT_CONFIG_DIR/agents/$role.toml" "$role" <<'PY'
import sys
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        sys.exit("Role validation requires Python 3.11+ or tomli")
try:
    with open(sys.argv[1], "rb") as f:
        role = tomllib.load(f)
    if role.get("name") != sys.argv[2]:
        raise ValueError("name must match requested role " + sys.argv[2])
    if not isinstance(role.get("developer_instructions"), str) or not role["developer_instructions"].strip():
        raise ValueError("developer_instructions must be a nonempty string")
    pins = [k for k in ("model", "model_reasoning_effort", "effort") if k in role]
    if pins:
        raise ValueError("role conflicts with runtime routing: remove pinned " + ", ".join(pins) + "; pass model/effort explicitly")
except (OSError, ValueError) as e:
    sys.exit("Invalid role TOML " + sys.argv[1] + ": " + str(e))
PY
}

# Shared jq definitions. Validation executes inside the mutation lock, so two
# reservations cannot both pass a stale budget/concurrency read.
delegation_jq() {
  cat <<'JQ'
    def held: .state == "pending" or .state == "uncertain";
    def active: held or (.agent_id != null and .closed != true);
    def ledger:
      [.[] | (.spawn_reservations // [])[], (.harness.spawn_reservations // [])[],
        (.delivery_groups[]?.harness.spawn_reservations // [])[]]
      | reduce .[] as $r ([]; if any(.[]; .id == $r.id) then . else . + [$r] end);
    def metric($role):
      {planner:"planner_runs", researcher:"researcher_runs", builder:"builder_runs",
       "builder-expert":"expert_runs", reviewer:"reviewer_runs", qa:"qa_runs",
       "visual-reviewer":"visual_runs"}[$role] // ($role + "_runs");
    def cap($role):
      {planner:"max_planner_runs", researcher:"max_researcher_runs", builder:"max_builder_runs",
       "builder-expert":"max_builder_expert_runs", reviewer:"max_reviewer_runs", qa:"max_qa_runs",
       "visual-reviewer":"max_visual_runs"}[$role] // ("max_" + $role + "_runs");
    def commit($idx):
      .[$idx] as $g
      | .[$idx].harness.spawn_reservations = [($g.spawn_reservations // [])[]
          | select(.group_id == ($g.active_group_id // null))]
      | if $g.active_group_id != null then
          .[$idx].harness as $h
          | .[$idx].delivery_groups |= map(if .id == $g.active_group_id then .harness = $h else . end)
        else . end;
    def event($idx; $at; $name; $detail):
      .[$idx].harness.events = ((.[$idx].harness.events // []) +
        [{at:$at, agent:"harness", event:$name, detail:$detail}]);
    def owner($idx; $r):
      if $r.group_id != (.[$idx].active_group_id // null) then
        error("Reservation belongs to another delivery group; activate " + ($r.group_id // "root"))
      else . end;
JQ
}

delegation_output() {
  local id="$1"
  jq --argjson idx "$GOAL_IDX" --arg id "$id" '
    {reservation: (.[$idx].spawn_reservations | map(select(.id == $id)) | .[0]),
     metrics: .[$idx].harness.metrics}
  ' "$STATE_FILE"
}

cmd_harness_spawn() { delegation_shared delegation_reserve "$@"; }

delegation_reserve() {
  local role="${1:-}" model="${2:-}" effort="${3:-}" task="" phase route line allowed cap_value id now sha="" vision=false
  [ $# -ge 3 ] && [ -n "$model" ] && [ -n "$effort" ] || {
    err 'harness spawn requires <role> <model> <effort> [--task tN]'; return 1;
  }
  shift 3
  if [ $# -gt 0 ]; then
    [ $# -eq 2 ] && [ "$1" = --task ] && [ -n "$2" ] || { err 'Expected --task tN'; return 1; }
    task="$2"
  fi
  case "$effort" in minimal|low|medium|high|xhigh) ;; *) err "Invalid effort: $effort"; return 1 ;; esac
  if jq -e --argjson idx "$GOAL_IDX" '.[$idx].kind == "queue"' "$STATE_FILE" >/dev/null 2>&1; then
    case "$role" in
      planner|researcher) ;;
      *)
        goal_error assignment \
          "Queue record allows only planner/researcher; got $role" \
          "Export GOAL_ID=queue-<run_id> only for queue planning, then clear it before issue workers"
        return 1
        ;;
    esac
  fi
  delegation_role_config "$role" || return 1
  phase="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].harness.phase' "$STATE_FILE")"
  route="$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].harness.complexity // "NORMAL"' "$STATE_FILE")"
  line="$(cmd_models "$role" --complexity "$route")" || return 1
  allowed="$(printf '%s' "$line" | jq -R 'split("\t") | [.[0]] + ((.[2] // "") | split(",") | map(select(length > 0)))')"
  if ! printf '%s' "$allowed" | jq -e --arg m "$model" 'index($m) != null' >/dev/null; then
    # Cursor catalogs use inherit; accept when chain includes it or platform is cursor.
    if [ "$model" = "inherit" ] && {
      printf '%s' "$allowed" | jq -e 'index("inherit") != null' >/dev/null ||
      [ "${AGENT_PLATFORM:-}" = "cursor" ]
    }; then
      :
    else
      err "Model '$model' is outside the authorized $role/$route chain; update goal-models.json explicitly"; return 1
    fi
  fi
  models_role_multimodal "$PROJECT_ROOT/$AGENT_CONFIG_DIR/goal-models.json" "$role" && vision=true
  if [ "$vision" = true ] && ! models_is_vision "$PROJECT_ROOT/$AGENT_CONFIG_DIR/goal-models.json" "$model"; then
    err "Role '$role' requires a vision-capable model: $model"; return 1
  fi
  # Auto-advance to the role's expected phase when that transition is legal.
  local expected_phase
  expected_phase=$(jq -nr --arg role "$role" '
    {planner:"PLANNED", researcher:"RESEARCHING", builder:"BUILDING", "builder-expert":"BUILDING",
     reviewer:"REVIEWING", qa:"QA", "visual-reviewer":"VISUAL_REVIEW"}[$role] // "BUILDING"')
  if [ "$phase" != "$expected_phase" ] && \
     { [ "$role" != "builder-expert" ] || [ "$phase" != "ESCALATED" ]; }; then
    if [ "$role" = "builder-expert" ] && [ "$phase" = "ESCALATED" ]; then
      :
    elif declare -F harness_phase_allowed >/dev/null && harness_phase_allowed "$phase" "$expected_phase"; then
      cmd_harness_phase "$expected_phase" || return 1
      phase="$expected_phase"
    else
      goal_error assignment \
        "Spawn rejected: role $role during $phase; expected $expected_phase" \
        "Run: GOAL_* selectors goal-git.sh harness phase $expected_phase"
      return 1
    fi
  fi
  # Evidence workers inspect a committed, clean implementation. This is a
  # readonly check; an isolated module host may omit the fingerprint helper.
  case "$role" in
    reviewer|qa|visual-reviewer)
      if declare -F implementation_fingerprint >/dev/null; then
        sha="$(implementation_fingerprint)" || return 1
        [ -n "$sha" ] || { err 'Evidence launch requires a committed implementation SHA'; return 1; }
      fi ;;
  esac
  local launch_worktree parent_worktree
  launch_worktree=$(jq -r --argjson idx "$GOAL_IDX" '.[$idx].worktree // ""' "$STATE_FILE")
  parent_worktree="$launch_worktree"
  if declare -F repo_dir >/dev/null; then
    launch_worktree=$(repo_dir "${GOAL_REPO:-.}") || return
    if [ -n "${GOAL_TASK:-}" ]; then
      parent_worktree="$PROJECT_ROOT/$parent_worktree"
    else parent_worktree="$launch_worktree"; fi
  fi
  # MAIN occupies one thread. The project concurrency setting limits children.
  cap_value="$(config_read concurrency)"; cap_value="${cap_value:-7}"
  [[ "$cap_value" =~ ^[0-9]+$ ]] && [ "$cap_value" -gt 0 ] || { err 'concurrency must be a positive integer'; return 1; }
  id="spawn-$(python3 -c 'import uuid; print(uuid.uuid4())')"
  now="$(harness_now)"
  state_mutate --argjson idx "$GOAL_IDX" --arg role "$role" --arg model "$model" --arg effort "$effort" \
    --arg task "$task" --arg phase "$phase" --arg complexity "$route" --arg id "$id" --arg at "$now" --arg sha "$sha" --arg worktree "$launch_worktree" --arg parent_wt "$parent_worktree" --arg repo "${GOAL_REPO:-.}" --argjson concurrency "$cap_value" "$(delegation_jq)"'
    .[$idx] as $g | $g.harness as $h | ledger as $all
    | if $h.phase != $phase or ($h.complexity // "NORMAL") != $complexity then error("Harness changed; resolve routing and retry") else . end
    | ({planner:"PLANNED", researcher:"RESEARCHING", builder:"BUILDING", "builder-expert":"BUILDING",
        reviewer:"REVIEWING", qa:"QA", "visual-reviewer":"VISUAL_REVIEW"}[$role] // "BUILDING") as $expected
    | if $phase != $expected and ($role != "builder-expert" or $phase != "ESCALATED") then
        error("Spawn rejected: role " + $role + " during " + $phase + "; expected " + $expected + ". Run: harness phase " + $expected)
      else . end
    | if any($all[]; .state == "uncertain") then error("Uncertain launch outcome; reconcile reservation via spawn-confirm/fail before launching again") else . end
    | if ([$all[] | select(active)] | length) >= $concurrency then error("Global concurrency limit reached across issues/groups; finish and close an agent") else . end
    | [($g.spawn_reservations // [])[] | select(.group_id == ($g.active_group_id // null) and held)] as $pending
    | if $task != "" then
        ($h.tasks // [] | map(select(.id == $task)) | .[0]) as $t
        | if $t == null then error("Unknown task: " + $task)
          elif $t.role != $role then error("Task role conflicts with spawn role: " + $task)
          elif ($t.state != "PENDING" and $t.state != "SPAWNING") then error("Task must be PENDING/SPAWNING: " + $task)
          elif any($all[]; .task == $task and .goal_key == ($g.id // $g.branch // ($idx | tostring)) and .group_id == ($g.active_group_id // null) and active)
            then error("Task already has a live reservation/agent: " + $task)
          else . end
      elif any($pending[]; .role == $role and .task == null) then error("Role already has a pending reservation; confirm/fail it first") else . end
    | if ($role == "builder" or $role == "builder-expert" or $expected == "BUILDING") and
        (any($all[]; active and (.worktree == $worktree) and
          (.role == "builder" or .role == "builder-expert" or .phase == "BUILDING")) or
         any($h.tasks[]?; (.role == "builder" or .role == "builder-expert") and
           (.state == "RUNNING" or (.state == "SPAWNING" and .id != $task)) and
           .spawn_reservation_id == null and $worktree == $parent_wt))
      then error("Parallel builders cannot share worktree " + $worktree) else . end
    | ($h.metrics.agent_spawns // 0) as $total
    | (($h.budget.max_total_spawns // 10)) as $max
    | ((if $h.requirements.qa == true and ($h.metrics.qa_runs // 0) == 0 and $role != "qa" and
          (any($pending[]; .role == "qa") | not) then 1 else 0 end) +
       (if $h.requirements.visual == true and ($h.metrics.visual_runs // 0) == 0 and $role != "visual-reviewer" and
          (any($pending[]; .role == "visual-reviewer") | not) then 1 else 0 end)) as $required
    | if $total + ($pending | length) + 1 + $required > $max then error("Spawn budget exceeded (confirmed + reservations + required QA/Visual); raise max_total_spawns explicitly") else . end
    | cap($role) as $cap | metric($role) as $metric
    | ($h.budget[$cap] // (if $role == "builder" or ($expected == "BUILDING" and $role != "builder-expert") then $max else 0 end)) as $limit
    | if ($h.metrics[$metric] // 0) + ([$pending[] | select(.role == $role)] | length) >= $limit
      then error("Spawn role budget exceeded: " + $cap + "; raise it explicitly") else . end
    | .[$idx].spawn_reservations = (($g.spawn_reservations // []) + [{
        id:$id, role:$role, model:$model, effort:$effort, task:(if $task == "" then null else $task end),
        phase:$phase, prior_phase:$phase, state:"pending", created_at:$at, closed:false,
        sha:(if $sha == "" then null else $sha end),
        group_id:($g.active_group_id // null), goal_key:($g.id // $g.branch // ($idx | tostring)),
        run_id:($g.run_id // null), rework_cycle:($h.counters.rework // 0), repo:$repo, worktree:$worktree }])
    | if $task != "" then .[$idx].harness.tasks |= map(if .id == $task then
        .state = "SPAWNING" | .spawn_reservation_id = $id else . end) else . end
    | event($idx; $at; "spawn_reserved"; $id + " role=" + $role + " model=" + $model + " effort=" + $effort)
    | commit($idx)
  ' || return 1
  delegation_output "$id"
}

cmd_harness_spawn_confirm() { delegation_shared delegation_confirm "$@"; }

delegation_confirm() {
  local id="${1:-}" agent="${2:-}" now
  [ $# -eq 2 ] && [ -n "$id" ] && [ -n "$agent" ] && [[ "$agent" != *[[:space:]]* ]] || {
    err 'spawn-confirm requires <reservation-id> <real-agent-id>'; return 1;
  }
  now="$(harness_now)"
  state_mutate --argjson idx "$GOAL_IDX" --arg id "$id" --arg agent "$agent" --arg at "$now" "$(delegation_jq)"'
    (.[$idx].spawn_reservations // [] | map(select(.id == $id)) | .[0]) as $r
    | if $r == null then error("Unknown reservation: " + $id) else . end
    | owner($idx; $r)
    | if $r.agent_id != null then
        if $r.agent_id == $agent then . else error("Reservation already confirmed with another agent ID") end
      elif ($r | held | not) then error("Cannot confirm a released reservation")
      elif any(ledger[]; .agent_id == $agent and .id != $id) then error("Agent ID already belongs to another reservation")
      elif .[$idx].harness.phase != $r.prior_phase and
        (.[$idx].harness.phase != "FAILED" or .[$idx].harness.spawn_failure.reservation_id != $id)
        then error("Phase changed; reconcile the harness before confirming this agent")
      else
        .[$idx].spawn_reservations |= map(if .id == $id then
          .state = "confirmed" | .agent_id = $agent | .confirmed_at = $at else . end)
        | .[$idx].harness.metrics.agent_spawns = ((.[$idx].harness.metrics.agent_spawns // 0) + 1)
        | metric($r.role) as $metric
        | .[$idx].harness.metrics[$metric] = ((.[$idx].harness.metrics[$metric] // 0) + 1)
        | if $r.task != null then .[$idx].harness.tasks |= map(if .id == $r.task then
            if .spawn_reservation_id != $id or (.state != "SPAWNING" and (.state != "BLOCKED" or .blocker_kind != "spawn"))
            then error("Task changed; reconcile it before confirmation") else
              .state = "RUNNING" | .agent_id = $agent | .attempts = ((.attempts // 0) + 1)
              | del(.blocker_kind, .blocked_kind, .blocker_reason, .spawn_failure)
            end else . end) else . end
        | if .[$idx].harness.phase == "FAILED" and .[$idx].harness.spawn_failure.reservation_id == $id then
            .[$idx].harness.phase = $r.prior_phase | .[$idx].harness |= del(.spawn_failure) else . end
        | event($idx; $at; "spawn_confirmed"; $id + " agent=" + $agent)
      end
    | commit($idx)
  ' || return 1
  delegation_output "$id"
}

cmd_harness_spawn_fail() { delegation_shared delegation_fail "$@"; }

delegation_fail() {
  local id="${1:-}" category="${2:-}" reason="${3:-}" now
  [ $# -eq 3 ] && [ -n "$id" ] && [ -n "$category" ] && [ -n "$reason" ] || {
    err 'spawn-fail requires <reservation-id> <category> <reason>; uncertain holds capacity'; return 1;
  }
  now="$(harness_now)"
  state_mutate --argjson idx "$GOAL_IDX" --arg id "$id" --arg category "$category" --arg reason "$reason" --arg at "$now" "$(delegation_jq)"'
    (.[$idx].spawn_reservations // [] | map(select(.id == $id)) | .[0]) as $r
    | if $r == null then error("Unknown reservation: " + $id) else . end
    | owner($idx; $r)
    | if $r.agent_id != null then error("Confirmed agent cannot be released by spawn-fail; use spawn-finish")
      elif ($r | held | not) then
        if $r.failure.category == $category and $r.failure.reason == $reason then .
        else error("Reservation already released with a different failure") end
      else
        .[$idx].spawn_reservations |= map(if .id == $id then
          .state = (if $category == "uncertain" then "uncertain" else "failed" end)
          | .failure = {category:$category, reason:$reason, at:$at}
          | .closed = ($category != "uncertain") else . end)
        | if $r.task != null then .[$idx].harness.tasks |= map(if .id == $r.task and .spawn_reservation_id == $id then
            if .state != "SPAWNING" and (.state != "BLOCKED" or .blocker_kind != "spawn") then
              error("Task has a real failure/state change; reconcile explicitly") else
              .state = "BLOCKED" | .blocker_kind = "spawn" | .blocker_reason = $reason
              | .spawn_failure = {reservation_id:$id, category:$category, reason:$reason}
            end else . end) else . end
        | .[$idx].harness.spawn_failure = {reservation_id:$id, prior_phase:$r.prior_phase, category:$category}
        | event($idx; $at; "spawn_failed"; $id + " " + $category + ": " + $reason)
      end
    | commit($idx)
  ' || return 1
  [ "$category" != uncertain ] || warn "Launch outcome uncertain for $id; stop and reconcile via spawn-confirm or definitive spawn-fail"
  delegation_output "$id"
}

cmd_harness_spawn_finish() { delegation_shared delegation_finish "$@"; }

delegation_finish() {
  local agent="${1:-}" status="${2:-}" closed=false now id
  [ $# -ge 2 ] && [ -n "$agent" ] || { err 'spawn-finish requires <agent-id> completed|failed [--closed]'; return 1; }
  case "$status" in completed|failed) ;; *) err 'spawn-finish status must be completed or failed'; return 1 ;; esac
  shift 2
  if [ $# -gt 0 ]; then
    [ $# -eq 1 ] && [ "$1" = --closed ] || { err 'Expected --closed'; return 1; }; closed=true
  fi
  now="$(harness_now)"
  state_mutate --argjson idx "$GOAL_IDX" --arg agent "$agent" --arg status "$status" --arg at "$now" --argjson closed "$closed" "$(delegation_jq)"'
    (.[$idx].spawn_reservations // [] | map(select(.agent_id == $agent)) | .[0]) as $r
    | if $r == null then error("Unknown confirmed agent ID: " + $agent) else . end
    | owner($idx; $r)
    | if $r.state != "confirmed" and $r.state != $status then error("Agent already finished with a different status") else . end
    | .[$idx].spawn_reservations |= map(if .id == $r.id then
        .state = $status | .finished_at = (.finished_at // $at) | .closed = (.closed == true or $closed) else . end)
    | if $r.task != null and $r.state == "confirmed" then .[$idx].harness.tasks |= map(
        if .id == $r.task and .agent_id == $agent and .state == "RUNNING" then
          .state = (if $status == "completed" then "DONE" else "FAILED" end)
          | if $status == "failed" then .blocker_kind = "agent" else . end
        else . end) else . end
    | if $r.state == "confirmed" or ($closed and $r.closed != true) then
        event($idx; $at; "spawn_finished"; $agent + " " + $status + " closed=" + ($closed | tostring)) else . end
    | commit($idx)
  ' || return 1
  id="$(jq -r --argjson idx "$GOAL_IDX" --arg agent "$agent" '.[$idx].spawn_reservations[] | select(.agent_id == $agent) | .id' "$STATE_FILE")"
  delegation_output "$id"
}

cmd_harness_recover_spawn() { delegation_shared delegation_recover "$@"; }

# Gate callers can require actual successful child completion, rather than
# treating a launch counter as evidence. No gate is changed by this predicate.
harness_role_completed() { delegation_shared delegation_role_completed "$@"; }

delegation_role_completed() {
  local role="${1:-}" sha=""
  [ $# -eq 1 ] && [ -n "$role" ] || return 1
  case "$role" in reviewer|qa|visual-reviewer)
    if declare -F implementation_fingerprint >/dev/null; then sha="$(implementation_fingerprint)" || return 1; fi ;;
  esac
  jq -e --argjson idx "$GOAL_IDX" --arg role "$role" --arg sha "$sha" '
    .[$idx] as $g
    | [($g.spawn_reservations // [])[] | select(
        .group_id == ($g.active_group_id // null) and .role == $role and
        .run_id == ($g.run_id // null) and .rework_cycle == ($g.harness.counters.rework // 0))] | last
    | .state == "completed" and .closed == true and ($sha == "" or .sha == $sha) and (.agent_id | type) == "string" and
        (.agent_id | length) > 0 and .confirmed_at != null and .finished_at != null
  ' "$STATE_FILE" >/dev/null
}

delegation_recover() {
  [ $# -eq 0 ] || { err 'recover-spawn accepts no arguments'; return 1; }
  local now
  now="$(harness_now)"
  state_mutate --argjson idx "$GOAL_IDX" --arg at "$now" "$(delegation_jq)"'
    .[$idx] as $g | ledger as $all
    | if any($all[]; .state == "uncertain") then error("Uncertain launch outcome; explicitly confirm/fail its reservation before recovery") else . end
    | [($g.spawn_reservations // [])[] | select(.group_id == ($g.active_group_id // null))] as $records
    | .[$idx].harness.tasks |= map(
        . as $t | ($records | map(select(.id == $t.spawn_reservation_id)) | .[0]) as $r
        | if ($t.state == "SPAWNING" or ($t.state == "BLOCKED" and ($t.blocker_kind // $t.blocked_kind) == "spawn")) and
             $t.agent_id == null and
             (any($records[]; .task == $t.id and active) | not) and
             (($r == null and $t.spawn_reservation_id == null) or ($r.state == "failed" and $r.agent_id == null)) then
            .state = "PENDING" | del(.blocker_kind, .blocked_kind, .blocker_reason, .spawn_failure, .spawn_reservation_id)
          else . end)
    | (.[$idx].harness.spawn_failure // {}) as $failure
    | ($records | map(select(.id == $failure.reservation_id and .state == "failed" and .agent_id == null)) | .[0]) as $failed
    | if .[$idx].harness.phase == "FAILED" and $failed != null and
         (any(.[$idx].harness.tasks[]?; .state == "FAILED" or (.state == "BLOCKED" and (.blocker_kind // .blocked_kind) != "spawn")) | not) and
         (any(.[$idx].harness.gates[]?; .status == "FAIL") | not) and
         (any($records[]; .agent_id != null and .state == "failed") | not) then
        .[$idx].harness.phase = $failed.prior_phase | .[$idx].harness |= del(.spawn_failure)
      else . end
    | event($idx; $at; "recover_spawn"; "Only unconfirmed spawn failures reset; pending/confirmed reservations remain held")
    | commit($idx)
  ' || return 1
  jq --argjson idx "$GOAL_IDX" '.[$idx].harness | {phase, next: ([.tasks[]? | select(.state == "PENDING")] | .[0] // null)}' "$STATE_FILE"
}
