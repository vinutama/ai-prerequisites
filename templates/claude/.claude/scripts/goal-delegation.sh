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

# Parse role config for the active platform. Codex uses TOML; Cursor and Claude
# use Markdown frontmatter (and may pin model there — that is intentional).
delegation_role_config() {
  local role="$1"
  [[ "$role" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || { err "Invalid role name: $role"; return 1; }
  require_cmd python3
  if [ "${AGENT_PLATFORM:-}" = "cursor" ] || [ "${AGENT_PLATFORM:-}" = "claude" ]; then
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
  # Goals tagged for another platform (a Cursor leftover in a Codex project)
  # must not consume this platform's concurrency or block it as "uncertain".
  if declare -F goal_platform_program >/dev/null; then goal_platform_program
  else printf '%s\n' 'def goal_platform: "unknown";'; fi
  printf 'def me: "%s";\n' "${AGENT_PLATFORM:-}"
  cat <<'JQ'
    def held: .state == "pending" or .state == "uncertain";
    def active: held or (.agent_id != null and .closed != true);
    def ledger:
      [.[] | select(goal_platform == me or goal_platform == "unknown")
        | (.spawn_reservations // [])[], (.harness.spawn_reservations // [])[],
        (.delivery_groups[]?.harness.spawn_reservations // [])[]]
      | reduce .[] as $r ([]; if any(.[]; .id == $r.id) then . else . + [$r] end);
    def metric($role):
      {planner:"planner_runs", researcher:"researcher_runs", builder:"builder_runs",
       "builder-expert":"expert_runs", reviewer:"reviewer_runs",
       "visual-reviewer":"visual_runs"}[$role] // ($role + "_runs");
    def cap($role):
      {planner:"max_planner_runs", researcher:"max_researcher_runs", builder:"max_builder_runs",
       "builder-expert":"max_builder_expert_runs", reviewer:"max_reviewer_runs",
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

# Concrete next command when the harness is not in the phase a role needs.
delegation_phase_hint() {
  local phase="$1" expected="$2"
  case "$phase->$expected" in
    VERIFYING-\>BUILDING|REVIEWING-\>BUILDING|VISUAL_REVIEW-\>BUILDING|DONE-\>BUILDING|FAILED-\>BUILDING|QA-\>BUILDING)
      printf '%s' "New implementation work needs a rework cycle: goal-git.sh harness retry rework && goal-git.sh harness phase REWORK && goal-git.sh harness phase BUILDING (then retry the spawn)" ;;
    FAILED-\>*)
      printf '%s' "Phase is FAILED: inspect harness status (blocker/spawn_failure); if recoverable run goal-git.sh harness recover-spawn or harness phase REWORK, otherwise save the blocker with harness event blocker" ;;
    *)
      printf '%s' "Run: goal-git.sh harness phase $expected (or harness status for the next legal step)" ;;
  esac
}

delegation_reserve() {
  local role="${1:-}" model="${2:-}" effort="${3:-}" task="" phase route line allowed cap_value id now sha="" vision=false
  [ $# -ge 3 ] && [ -n "$model" ] && [ -n "$effort" ] || {
    err 'harness spawn requires <role> <model> <effort> [--task tN]'; return 1;
  }
  if [ "$role" = "qa" ]; then
    err "QA was removed from the goal workflow"
    return 1
  fi
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
    # Cursor/Claude sessions own the real model: accept inherit (and, on Claude,
    # the sonnet/opus/haiku aliases) when the chain includes it or the platform allows it.
    if [ "$model" = "inherit" ] && {
      printf '%s' "$allowed" | jq -e 'index("inherit") != null' >/dev/null ||
      [ "${AGENT_PLATFORM:-}" = "cursor" ] || [ "${AGENT_PLATFORM:-}" = "claude" ]
    }; then
      :
    elif [ "${AGENT_PLATFORM:-}" = "claude" ] && case "$model" in sonnet|opus|haiku) true ;; *) false ;; esac; then
      :
    else
      goal_error model "Model '$model' is outside the authorized $role/$route chain: $(printf '%s' "$allowed" | jq -r 'join(",")')" \
        "Use a model from: goal-git.sh models $role --complexity $route (or add it to goal-models.json), then retry the spawn"; return 1
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
     reviewer:"REVIEWING", "visual-reviewer":"VISUAL_REVIEW"}[$role] // "BUILDING"')
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
        "$(delegation_phase_hint "$phase" "$expected_phase")"
      return 1
    fi
  fi
  # Evidence workers inspect a committed, clean implementation. This is a
  # readonly check; an isolated module host may omit the fingerprint helper.
  case "$role" in
    reviewer|visual-reviewer)
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
        reviewer:"REVIEWING", "visual-reviewer":"VISUAL_REVIEW"}[$role] // "BUILDING") as $expected
    | if $phase != $expected and ($role != "builder-expert" or $phase != "ESCALATED") then
        error("Spawn rejected: role " + $role + " during " + $phase + "; expected " + $expected + ". Run: harness phase " + $expected + " (from VERIFYING/REVIEWING use harness retry rework, harness phase REWORK, then BUILDING)")
      else . end
    | if any($all[]; .state == "uncertain") then error("Uncertain launch outcome; run harness spawn-confirm <reservation> <agent-id> if the agent started, harness spawn-fail <reservation> <category> <reason> if it did not, or harness reap for leftovers of a previous session") else . end
    | if ([$all[] | select(active)] | length) >= $concurrency then error("Concurrency limit reached across issues/groups of this platform; finish and close an agent (spawn-finish <agent> completed|failed --closed), or run harness reap for stale reservations of a previous session") else . end
    | [($g.spawn_reservations // [])[] | select(.group_id == ($g.active_group_id // null) and held)] as $pending
    | if $task != "" then
        ($h.tasks // [] | map(select(.id == $task)) | .[0]) as $t
        | if $t == null then error("Unknown task: " + $task)
          elif $t.role != $role then error("Task role conflicts with spawn role: " + $task)
          elif ($t.state != "PENDING" and $t.state != "SPAWNING") then error("Task must be PENDING/SPAWNING: " + $task + " is " + $t.state + "; run harness task retry " + $task + " (or harness task cancel " + $task + "; harness reap if its agent is from a previous session)")
          elif any($all[]; .task == $task and .goal_key == ($g.id // $g.branch // ($idx | tostring)) and .group_id == ($g.active_group_id // null) and active)
            then error("Task already has a live reservation/agent: " + $task)
          else . end
      elif any($pending[]; .role == $role and .task == null) then error("Role already has a pending reservation; run spawn-confirm/spawn-fail for it, or harness reap if it is left over from a previous session") else . end
    | if ($role == "builder" or $role == "builder-expert" or $expected == "BUILDING") and
        (any($all[]; active and (.worktree == $worktree) and
          (.role == "builder" or .role == "builder-expert" or .phase == "BUILDING")) or
         any($h.tasks[]?; (.role == "builder" or .role == "builder-expert") and
           (.state == "RUNNING" or (.state == "SPAWNING" and .id != $task)) and
           .spawn_reservation_id == null and $worktree == $parent_wt))
      then error("Parallel builders cannot share worktree " + $worktree) else . end
    | ($h.metrics.agent_spawns // 0) as $total
    | (($h.budget.max_total_spawns // 10)) as $max0
    | ((if $h.requirements.visual == true and ($h.metrics.visual_runs // 0) == 0 and $role != "visual-reviewer" and
          (any($pending[]; .role == "visual-reviewer") | not) then 1 else 0 end)) as $required
    | ($h.counters.rework // 0) as $rw
    # Review/rework loops must not stall on a hard cap: grow the caps while the
    # rework counter is still within max_rework (harness retry rework fails the
    # goal beyond it, so the loop stays bounded).
    | ((($role == "reviewer" and $phase == "REVIEWING") or ($role == "builder" and $phase == "BUILDING" and $rw > 0))
        and $rw <= ($h.limits.max_rework // 3)) as $grow
    | ($total + ($pending | length) + 1 + $required) as $need
    | (if $grow and $need > $max0 then $need else $max0 end) as $max
    | cap($role) as $cap | metric($role) as $metric
    | $h.budget[$cap] as $configured
    | (($h.metrics[$metric] // 0) + ([$pending[] | select(.role == $role)] | length)) as $used
    | ($configured // (if $role == "builder" or ($expected == "BUILDING" and $role != "builder-expert") then $max else 0 end)) as $limit0
    | (if $grow and $configured != null and $used >= $limit0 then $used + 1 else $limit0 end) as $limit
    | if $need > $max then error("Spawn budget exceeded (confirmed + reservations + required Visual); run: harness budget set max_total_spawns " + ($need | tostring)) else . end
    | if $used >= $limit then error("Spawn role budget exceeded: " + $cap + "; run: harness budget set " + $cap + " " + (($used + 1) | tostring)) else . end
    | if $max != $max0 then .[$idx].harness.budget.max_total_spawns = $max
        | event($idx; $at; "budget_grow"; "max_total_spawns " + ($max0 | tostring) + " -> " + ($max | tostring) + " (rework " + ($rw | tostring) + ")") else . end
    | if $limit != $limit0 then .[$idx].harness.budget[$cap] = $limit
        | event($idx; $at; "budget_grow"; $cap + " " + ($limit0 | tostring) + " -> " + ($limit | tostring) + " (rework " + ($rw | tostring) + ")") else . end
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
  [ "$category" != uncertain ] || warn "Launch outcome uncertain for $id; run spawn-confirm $id <agent-id> if the agent started, or a definitive spawn-fail $id <category> <reason> (or harness reap) before launching again"
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
  case "$role" in reviewer|visual-reviewer)
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
  if jq -e --argjson idx "$GOAL_IDX" '.[$idx].harness.phase == "FAILED"' "$STATE_FILE" >/dev/null 2>&1; then
    warn "Phase is still FAILED (failed tasks, failed gates or a failed agent remain): fix the cause, use harness task retry <id>, then harness phase REWORK"
  fi
  jq --argjson idx "$GOAL_IDX" '.[$idx].harness | {phase, next: ([.tasks[]? | select(.state == "PENDING")] | .[0] // null)}' "$STATE_FILE"
}

# --- Recovery: release stale reservations and retry/cancel tasks -------------

# Epoch seconds of a local ISO timestamp with offset (2026-09-13T20:12:00+07:00).
delegation_epoch_jq() {
  cat <<'JQ'
    def epoch:
      (. // "") as $t
      | ($t | capture("^(?<d>.*)(?<sign>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2})$")? // null) as $c
      | if $c == null then (try ($t | sub("Z$"; "Z") | fromdateiso8601) catch 0)
        else (($c.d + "Z" | fromdateiso8601) - ((if $c.sign == "-" then -1 else 1 end) * (($c.h | tonumber) * 3600 + ($c.m | tonumber) * 60)))
        end;
JQ
}

delegation_stale_jq() {
  cat <<'JQ'
    def stale($cutoff): active and ((.created_at | epoch) <= $cutoff);
JQ
}

# Read-only: print a warning when reservations from a previous session still
# hold capacity. Used by `continue`.
delegation_stale_report() {
  [ -f "$STATE_FILE" ] || return 0
  local count ids
  ids="$(jq -r --argjson idx "$GOAL_IDX" "$(delegation_jq)"'
    [(.[$idx].spawn_reservations // [])[] | select(active) | .id] | join(" ")
  ' "$STATE_FILE" 2>/dev/null || true)"
  [ -n "$ids" ] || return 0
  count="$(printf '%s' "$ids" | wc -w | tr -d ' ')"
  warn "$count spawn reservation(s) are still held: $ids"
  warn "If no worker is running (new session), release them with: goal-git.sh harness reap"
}

cmd_harness_reap() { delegation_shared delegation_reap "$@"; }

delegation_reap() {
  local older=0 now cutoff reaped
  while [ $# -gt 0 ]; do
    case "$1" in
      --older-than)
        [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || { err 'harness reap --older-than requires minutes'; return 1; }
        older="$2"; shift 2 ;;
      *) err "Unknown harness reap argument: $1"; return 1 ;;
    esac
  done
  now="$(harness_now)"
  cutoff=$(( $(date +%s) - older * 60 ))
  reaped="$(jq -c --argjson idx "$GOAL_IDX" --argjson cutoff "$cutoff" "$(delegation_jq)$(delegation_epoch_jq)$(delegation_stale_jq)"'
    [(.[$idx].spawn_reservations // [])[] | select(stale($cutoff)) | .id]
  ' "$STATE_FILE")" || return 1
  if [ "$reaped" = "[]" ]; then
    log "No stale reservations to reap"
    printf '{"reaped":[],"tasks_reset":[]}\n'
    return 0
  fi
  state_mutate --argjson idx "$GOAL_IDX" --argjson cutoff "$cutoff" --argjson ids "$reaped" --arg at "$now" "$(delegation_jq)$(delegation_epoch_jq)$(delegation_stale_jq)"'
    def release_tasks: map(
      . as $t
      | if ($t.state == "SPAWNING" or $t.state == "RUNNING" or ($t.state == "BLOCKED" and ($t.blocker_kind // $t.blocked_kind) == "spawn"))
           and (($ids | index($t.spawn_reservation_id)) != null)
        then .state = "PENDING" | del(.agent_id, .spawn_reservation_id, .blocker_kind, .blocked_kind, .blocker_reason, .spawn_failure)
        else . end);
    def release: map(. as $r | if (($ids | index($r.id)) != null) and ($r | stale($cutoff)) then
        .state = "failed" | .closed = true | .finished_at = (.finished_at // $at)
        | .failure = {category:"reaped", reason:"stale reservation from a previous session", at:$at}
      else . end);
    .[$idx].spawn_reservations |= release
    | .[$idx].harness.spawn_reservations |= (. // [] | release)
    | if .[$idx].delivery_groups then .[$idx].delivery_groups |= map(if .harness then .harness.spawn_reservations |= (. // [] | release) else . end) else . end
    | .[$idx].harness.tasks |= (. // [] | release_tasks)
    | if .[$idx].delivery_groups then .[$idx].delivery_groups |= map(if .harness then .harness.tasks |= (. // [] | release_tasks) else . end) else . end
    | (.[$idx].harness.spawn_failure.reservation_id // "") as $sf
    | if .[$idx].harness.phase == "FAILED" and (($ids | index($sf)) != null) then
        .[$idx].harness.phase = (.[$idx].harness.spawn_failure.prior_phase // "BUILDING")
        | .[$idx].harness |= del(.spawn_failure)
      else . end
    | event($idx; $at; "reap"; ($ids | length | tostring) + " stale reservation(s): " + ($ids | join(",")))
    | commit($idx)
  ' || return 1
  log "Reaped $(printf '%s' "$reaped" | jq length) stale reservation(s); their tasks are PENDING again"
  jq -c --argjson idx "$GOAL_IDX" --argjson ids "$reaped" '{reaped:$ids, tasks_reset:[.[$idx].harness.tasks[]? | select(.state == "PENDING") | .id]}' "$STATE_FILE"
}

cmd_harness_task_retry() { delegation_shared delegation_task_release retry "$@"; }
cmd_harness_task_cancel() { delegation_shared delegation_task_release cancel "$@"; }

# retry: FAILED/BLOCKED/stuck task back to PENDING (re-spawn with --task tN).
# cancel: CANCELLED is accepted by VERIFYING and harness done.
# Both release the task's live reservation so a new launch is not blocked.
delegation_task_release() {
  local mode="${1:-}" id="${2:-}" reason="" now
  shift 2 || true
  [ -n "$id" ] || { err "harness task $mode requires <task-id> [reason]"; return 1; }
  reason="$*"
  now="$(harness_now)"
  state_mutate --argjson idx "$GOAL_IDX" --arg id "$id" --arg mode "$mode" --arg reason "$reason" --arg at "$now" "$(delegation_jq)"'
    (.[$idx].harness.tasks // [] | map(select(.id == $id)) | .[0]) as $t
    | (.[$idx].active_group_id // null) as $gid
    | if $t == null then error("Unknown task: " + $id) else . end
    | if $t.state == "DONE" then error("Task " + $id + " is already DONE; for new work run harness retry rework, harness phase REWORK, harness phase BUILDING and add a task") else . end
    | if $mode == "cancel" and $t.state == "CANCELLED" then error("Task " + $id + " is already CANCELLED") else . end
    | .[$idx].spawn_reservations |= map(
        if .task == $id and .group_id == $gid and active then
          .state = "failed" | .closed = true | .finished_at = (.finished_at // $at)
          | .failure = {category:"released", reason:("task " + $mode), at:$at}
        else . end)
    | .[$idx].harness.tasks |= map(if .id == $id then
        (if $mode == "retry" then .state = "PENDING" else .state = "CANCELLED" end)
        | del(.agent_id, .spawn_reservation_id, .blocker_kind, .blocked_kind, .blocker_reason, .spawn_failure)
        | .history = ((.history // []) + [{at:$at, action:$mode, from:$t.state, reason:$reason}])
      else . end)
    | event($idx; $at; "task_" + $mode; $id + " " + $t.state + (if $reason != "" then ": " + $reason else "" end))
    | commit($idx)
  ' || return 1
  case "$mode" in
    retry) log "Task $id -> PENDING; relaunch with: harness spawn <role> <model> <effort> --task $id" ;;
    *) log "Task $id -> CANCELLED (ignored by VERIFYING and harness done)" ;;
  esac
}
