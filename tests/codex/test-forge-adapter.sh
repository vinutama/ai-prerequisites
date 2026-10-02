#!/usr/bin/env bash
# Deterministic CLI argv/response tests. Optional local help never calls a forge.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=$(mktemp -d /tmp/forge-tests.XXXXXX)
trap 'result=$?; if [ "$result" -ne 0 ] && [ -f "$WORK/err" ]; then cat "$WORK/err" >&2; fi; rm -rf "$WORK"' EXIT
export FORGE_CACHE_DIR="$WORK/cache" MOCK_ROOT="$WORK" FORGE_RETRY_WAIT_OVERRIDE=0
mkdir -p "$WORK/bin" "$WORK/help"
# Save genuine help when available; static flag definitions keep CI independent.
for cli in gh glab; do
  real=$(type -P "$cli" || true)
  for sub in 'pr list' 'pr view' 'pr create' 'pr edit' 'mr list' 'mr view' 'mr create' 'mr update' 'issue list' 'issue create' api; do
    if [ -n "$real" ]; then
      read -r -a words <<< "$sub"
      "$real" "${words[@]}" --help > "$WORK/help/$cli-${sub// /-}" 2>/dev/null || rm -f "$WORK/help/$cli-${sub// /-}"
    fi
  done
done
cat > "$WORK/bin/mock" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, sys
root=pathlib.Path(os.environ['MOCK_ROOT']); cli=pathlib.Path(sys.argv[0]).name; a=sys.argv[1:]
scenario=os.environ.get('MOCK_SCENARIO','normal')
with (root/'calls').open('a') as f: f.write(json.dumps([cli]+a)+'\n')
if a==['--version']:
    print(cli+' version '+os.environ.get('MOCK_VERSION','1')); sys.exit()
sub=' '.join(a[:2]) if a[0]!='api' else 'api'
if '--help' in a:
    if scenario=='help-fail': sys.exit(1)
    helpfile=root/'help'/f'{cli}-{sub.replace(" ","-")}'
    if helpfile.exists(): print('\n'.join(line for line in helpfile.read_text().splitlines() if '--description-file' not in line))
    else:
        flags=['--head','--base','--state','--limit','--json','--repo','--title','--body-file','--source-branch','--target-branch','--output','--page','--per-page','--description','--yes','--all','--order','--sort','--label','--assignee','--milestone','--hostname','--method','--input']
        if sub=='pr create': flags.remove('--json')
        print('\n'.join('  '+flag+' value  Help' for flag in flags))
    if scenario=='new-description': print('  --description-file string  Read file')
    sys.exit()
if sub=='auth status':
    print('SECRET_AUTH_TOKEN_MUST_NOT_LEAK',file=sys.stderr)
    sys.exit(1 if scenario=='auth' else 0)
if a[0]=='sleep': sys.exit()
countfile=root/'attempt'; count=int(countfile.read_text())+1 if countfile.exists() else 1; countfile.write_text(str(count))
if scenario in ['transient','timeout','rate','auth','permission','missing','unsupported','conflict','validation','unknown']:
    messages={'transient':'HTTP 503 connection reset','timeout':'context deadline exceeded','rate':'HTTP 429\nRetry-After: 9','auth':'HTTP 401 authentication required','permission':'HTTP 403 forbidden','missing':'HTTP 404 not found','unsupported':'unknown flag: --wat','conflict':'HTTP 409 conflict','validation':'HTTP 422 validation failed','unknown':'unexpected failure'}
    if scenario=='rate': messages[scenario]='HTTP 429\nRetry-After: '+os.environ.get('MOCK_RETRY_AFTER','9')
    print('raw stdout',end=''); print(messages[scenario],file=sys.stderr); sys.exit(7)
if scenario=='invalid': print('not json'); sys.exit()
mutating=sub in ['pr create','pr edit','mr create','mr update','issue create']
if mutating:
    if sub.endswith('create') and (root/'created').exists() and sub!='issue create':
        print('DUPLICATE CREATE',file=sys.stderr); sys.exit(9)
    (root/'created').write_text('true')
    if '--body-file' in a or '--description-file' in a:
        flag='--body-file' if '--body-file' in a else '--description-file'; body=pathlib.Path(a[a.index(flag)+1]).read_text()
    elif '--description' in a: body=a[a.index('--description')+1]
    else: raise AssertionError('Missing body')
    (root/'body').write_text(body)
    if scenario=='accepted-failure': print('connection reset after accepted mutation',file=sys.stderr); sys.exit(7)
    print('https://forge.example/team/project/pull/7'); sys.exit()
gh={'number':7,'url':'https://forge.example/team/project/pull/7','headRefName':'topic','baseRefName':'main','headRefOid':'abc123','state':'OPEN','isCrossRepository':False}
gl={'iid':7,'web_url':'https://forge.example/group/sub/project/-/merge_requests/7','source_branch':'topic','target_branch':'main','sha':'abc123','state':'opened','source_project_id':42,'target_project_id':42}
obj=gh if cli=='gh' else gl
if scenario=='wrong-view' and sub.endswith('view'): obj['baseRefName' if cli=='gh' else 'target_branch']='wrong'
if scenario=='closed': obj['state']='CLOSED' if cli=='gh' else 'closed'
if scenario=='wrong-base': obj['baseRefName' if cli=='gh' else 'target_branch']='other'
if scenario=='fork': obj['isCrossRepository' if cli=='gh' else 'source_project_id']=True if cli=='gh' else 99
if sub in ['pr list','mr list']:
    if scenario in ['empty','accepted-failure','vanished'] and not (root/'created').exists(): print('[]')
    elif scenario=='vanished': print('[]')
    elif scenario=='ambiguous': print(json.dumps([obj,obj]))
    else: print(json.dumps([obj]))
elif sub in ['pr view','mr view']: print(json.dumps(obj))
elif sub=='issue list' or (a[0]=='api' and '/issues' in a[1]):
    page=a[a.index('--page')+1] if '--page' in a else a[1].split('page=')[-1]
    if scenario=='issues-fail': print('HTTP 403 forbidden',file=sys.stderr); sys.exit(7)
    if scenario=='issues-invalid': print('{}'); sys.exit()
    if page=='1': print(json.dumps([{'title':'unrelated '+str(i)} for i in range(100)]))
    elif page=='2': print(json.dumps([{'title':'Task B1'}]))
    else: print('[]')
elif a[0]=='api' and a[1]=='graphql':
    payload=json.loads(pathlib.Path(a[a.index('--input')+1]).read_text())
    assert payload['variables']['owner']=='team' and payload['variables']['name']=='project'
    cursor=payload['variables']['cursor']
    node={'id':'thread1' if not cursor else 'thread2','path':'src/main.sh','line':4,'isResolved':bool(cursor),'isOutdated':bool(cursor),'comments':{'nodes':[{'body':'first\nsecond'}]}}
    nodes=[] if scenario=='threads-empty' else [node]
    hasnext=not cursor or scenario=='threads-stuck'
    if scenario=='threads-empty': hasnext=False
    data={'data':{'repository':{'pullRequest':{'reviewThreads':{'nodes':nodes,'pageInfo':{'hasNextPage':hasnext,'endCursor':'cursor1'}}}}}}
    if scenario=='threads-error': data={'errors':[{'message':'access denied'}],'data':{'repository':None}}
    print(json.dumps(data))
elif a[0]=='api' and '/discussions?' in a[1]:
    page=a[1].split('page=')[-1]
    positioned={'resolvable':True,'resolved':True,'body':'first','position':{'new_path':'src/main.sh','new_line':4}}
    reply={'resolvable':True,'resolved':False,'body':'second','position':None}
    if scenario=='threads-empty': data=[{'id':'general','notes':[{'resolvable':False,'body':'general note'}]}]
    elif page=='1': data=[{'id':str(i),'notes':[positioned]} for i in range(100)]
    else: data=[{'id':'last','notes':[positioned,reply,{'resolvable':False,'body':'system note'}]}]
    if scenario=='threads-error': data=[{'id':'bad','notes':None}]
    print(json.dumps(data))
elif a[0]=='api':
    if scenario=='files-paged' and a[1].endswith('page=1'): print(json.dumps([{'filename':str(i),'new_path':str(i)} for i in range(100)]))
    else: print(json.dumps([{'filename':'src/file with spaces.sh','new_path':'src/file with spaces.sh'}]))
else: raise AssertionError('Unexpected command '+repr(a))
PY
chmod +x "$WORK/bin/mock"
ln -s mock "$WORK/bin/gh"
ln -s mock "$WORK/bin/glab"
cat > "$WORK/bin/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$MOCK_ROOT/waits"
SH
chmod +x "$WORK/bin/sleep"
export PATH="$WORK/bin:$PATH"
source "$ROOT/templates/codex/.codex/scripts/forge.sh"
PASS=0
ok() { PASS=$((PASS+1)); printf 'PASS %s\n' "$*"; }
check() { local msg="$1"; shift; if "$@"; then ok "$msg"; else printf 'FAIL %s\n' "$msg" >&2; exit 1; fi; }
reset_mock() {
  export MOCK_SCENARIO="$1"
  rm -f "$WORK/attempt" "$WORK/created" "$WORK/body" "$WORK/calls" "$WORK/waits"
  rm -rf "$FORGE_CACHE_DIR"
  rm -rf "$FORGE_CACHE_DIR/"create-*.pending
}
count_mutations() { python3 - "$WORK/calls" <<'PY'
import json,sys
print(sum('--help' not in json.loads(l) and ' '.join(json.loads(l)[1:3]) in ['pr create','mr create','pr edit','mr update','issue create'] for l in open(sys.argv[1])))
PY
}
check 'syntax' bash -n "$ROOT/templates/codex/.codex/scripts/forge.sh"
reset_mock normal
check 'gh create supports body-file' forge_supports gh 'pr create' --body-file
check 'gh create never assumes JSON' bash -c 'source "$1"; ! forge_supports gh "pr create" --json' _ "$ROOT/templates/codex/.codex/scripts/forge.sh"
forge_supports gh 'pr create' --body-file
check 'help cached once' test "$(rg -c '"pr", "create", "--help"' "$WORK/calls")" = 1
export MOCK_VERSION=2
forge_supports gh 'pr create' --body-file
check 'version invalidates cache' test "$(rg -c '"pr", "create", "--help"' "$WORK/calls")" = 2
unset MOCK_VERSION
printf 'line one\nline "two" `$(echo unsafe)`\n\n' > "$WORK/input"
reset_mock normal
forge_description_args glab 'mr create' "$WORK/input"
printf '%s' "${FORGE_DESCRIPTION_ARGS[1]}" > "$WORK/description"
check 'literal fallback preserves trailing newlines and metacharacters' cmp "$WORK/input" "$WORK/description"
reset_mock new-description
forge_description_args glab 'mr create' "$WORK/input"
check 'new glab uses description-file' test "${FORGE_DESCRIPTION_ARGS[0]}" = --description-file
for category in transient timeout rate_limit auth permission not_found capability conflict validation unknown; do
  scenario="$category"
  case "$category" in rate_limit) scenario=rate ;; not_found) scenario=missing ;; capability) scenario=unsupported ;; esac
  reset_mock "$scenario"
  if forge_run read gh pr list > "$WORK/out" 2> "$WORK/err"; then exit 1; fi
  attempts=1
  case "$category" in transient|timeout|rate_limit) attempts=3 ;; esac
  check "$category attempts" test "$(cat "$WORK/attempt")" = "$attempts"
  check "$category JSON diagnostic" grep -q "\"category\":\"$category\"" "$WORK/err"
  check "$category preserves stdout" test "$(wc -c < "$WORK/out" | tr -d ' ')" = "$((10*attempts))"
done
reset_mock transient
unset FORGE_RETRY_WAIT_OVERRIDE
forge_run read gh pr list > /dev/null 2> /dev/null || true
check 'default retry waits are 2 and 5' test "$(cat "$WORK/waits")" = $'2\n5'
reset_mock rate
forge_run write glab mr create > /dev/null 2> /dev/null || true
check 'write never retries' test "$(cat "$WORK/attempt")" = 1
check 'retry-after saved' test "$(jq -r .retry_after "$FORGE_CACHE_DIR"/blocker-*.json)" = 9
forge_run write glab mr create > /dev/null 2> /dev/null || true
check 'saved blocker honored on later invocation' test "$(head -n 1 "$WORK/waits")" -ge 8
export FORGE_RETRY_WAIT_OVERRIDE=0
reset_mock rate
future=$(( $(date +%s) + 60 ))
MOCK_RETRY_AFTER=$(LC_ALL=C date -u -r "$future" '+%a, %d %b %Y %H:%M:%S GMT' 2>/dev/null || LC_ALL=C date -u -d "@$future" '+%a, %d %b %Y %H:%M:%S GMT')
export MOCK_RETRY_AFTER
forge_run write gh pr create >/dev/null 2> "$WORK/err" || true
check 'HTTP date retry-after persisted' test "$(jq -r .retry_after "$FORGE_CACHE_DIR"/blocker-*.json)" -ge 50
unset MOCK_RETRY_AFTER
reset_mock normal
for command in 'gh pr view --web' 'glab mr create -w' 'gh auth login' 'gh auth token'; do
  read -r -a words <<< "$command"
  if forge_run write "${words[@]}" >/dev/null 2>/dev/null; then exit 1; fi
done
check 'browser/auth-login attempts blocked before execution' test ! -e "$WORK/calls"
if forge_run read gh api repos/team/project --method POST >/dev/null 2>/dev/null; then exit 1; fi
check 'write cannot masquerade as read' test ! -e "$WORK/calls"
if forge_run read gh api repos/team/project -XPOST >/dev/null 2>/dev/null; then exit 1; fi
check 'attached method flag cannot masquerade as read' test ! -e "$WORK/calls"
if forge_run read gh api graphql -f 'query=mutation { resolveReviewThread(input:{threadId:"x"}) { clientMutationId } }' >/dev/null 2>/dev/null; then exit 1; fi
check 'GraphQL mutation cannot masquerade as read' test ! -e "$WORK/calls"
for cli in gh glab; do
  platform=github; repo=forge.example/team/project
  if [ "$cli" = glab ]; then platform=gitlab; repo=https://forge.example/group/sub/project; fi
  reset_mock normal
  metadata=$(forge_pr_metadata "$platform" "$repo" topic main)
  check "$platform normalized metadata" jq -e '.number==7 and .head=="topic" and .base=="main" and .sha=="abc123" and .state=="open" and .files==["src/file with spaces.sh"]' <<< "$metadata"
  check "$platform preserves API host" grep -q '"--hostname", "forge.example"' "$WORK/calls"
  reset_mock files-paged
  metadata=$(forge_pr_metadata "$platform" "$repo" topic main)
  check "$platform paginated files" jq -e '.files|length==101' <<< "$metadata"
  for scenario in ambiguous fork wrong-view invalid; do
    reset_mock "$scenario"
    if forge_pr_upsert "$platform" "$repo" topic main 'A title' "$WORK/input" >/dev/null 2>/dev/null; then exit 1; fi
    check "$platform uncertain $scenario lookup cannot create" test "$(count_mutations)" = 0
  done
  for scenario in closed wrong-base; do
    reset_mock "$scenario"
    metadata=$(forge_pr_metadata "$platform" "$repo" topic main)
    check "$platform ignores $scenario requests" test "$metadata" = null
  done
  reset_mock accepted-failure
  if forge_pr_upsert "$platform" "$repo" topic main 'A title' "$WORK/input" > "$WORK/out" 2> "$WORK/err"; then
    ok "$platform accepted create reconciles to success"
  else exit 1; fi
  check "$platform accepted failure returns refreshed metadata" jq -e '.number==7 and .head=="topic" and .base=="main" and .sha=="abc123" and .state=="open"' "$WORK/out"
  check "$platform accepted failure writes exactly once" test "$(count_mutations)" = 1
  check "$platform body transmitted intact" cmp "$WORK/input" "$WORK/body"
  # A caller retry finds the existing request and updates, rather than creates.
  if forge_pr_upsert "$platform" "$repo" topic main 'A title' "$WORK/input" > "$WORK/out" 2> "$WORK/err"; then exit 1; fi
  check "$platform failed update remains nonzero with fresh identity" jq -e '.number==7' "$WORK/out"
  check "$platform retry uses update" test "$(rg "\"$cli\", \"$([ "$cli" = gh ] && echo pr || echo mr)\", \"create\"" "$WORK/calls" | rg -vc -- '--help')" = 1
  reset_mock empty
  metadata=$(forge_pr_upsert "$platform" "$repo" topic main 'A title' "$WORK/input")
  check "$platform creates after proven absence" jq -e '.number==7' <<< "$metadata"
  check "$platform one creation" test "$(count_mutations)" = 1
  reset_mock normal
  metadata=$(forge_pr_upsert "$platform" "$repo" topic main 'A title' "$WORK/input")
  check "$platform updates existing request" test "$(count_mutations)" = 1
  check "$platform update metadata" jq -e '.number==7' <<< "$metadata"
  reset_mock vanished
  if forge_pr_upsert "$platform" "$repo" topic main 'A title' "$WORK/input" > "$WORK/out" 2>/dev/null; then exit 1; fi
  check "$platform cannot claim success when reread is empty" test ! -s "$WORK/out"
  if forge_pr_upsert "$platform" "$repo" topic main 'A title' "$WORK/input" > "$WORK/out" 2> "$WORK/err"; then exit 1; fi
  check "$platform unresolved creation never repeats a write" test "$(count_mutations)" = 1
  reset_mock threads
  threads=$(forge_threads "$platform" "$repo" 7)
  if [ "$platform" = github ]; then
    check 'GitHub cursor pagination and normalized root body' jq -e 'length==2 and .[0]=={id:"thread1",path:"src/main.sh",line:4,body:"first\nsecond",resolved:false,outdated:false} and .[1].resolved and .[1].outdated' <<< "$threads"
    reset_mock threads-stuck
    if forge_threads "$platform" "$repo" 7 > "$WORK/out" 2> "$WORK/err"; then exit 1; fi
    check 'non advancing cursor fails without partial threads' test ! -s "$WORK/out"
  else
    check 'GitLab discussion pagination and resolution of all resolvable notes' jq -e 'length==101 and .[-1]=={id:"last",path:"src/main.sh",line:4,body:"first\n\nsecond",resolved:false,outdated:false}' <<< "$threads"
  fi
  reset_mock threads-empty
  threads=$(forge_threads "$platform" "$repo" 7)
  check "$platform empty review discussions" test "$threads" = '[]'
  reset_mock threads-error
  if forge_threads "$platform" "$repo" 7 > "$WORK/out" 2> "$WORK/err"; then exit 1; fi
  check "$platform malformed thread response fails closed" test ! -s "$WORK/out"
done
reset_mock normal
unset PROJECT_ROOT
if ! forge_doctor > "$WORK/doctor"; then cat "$WORK/doctor"; exit 1; fi
check 'doctor works without config' jq -e '.ready and (.platforms|length==2) and .dependencies.jq' "$WORK/doctor"
check 'doctor does not leak auth output' bash -c '! grep -q SECRET_AUTH "$1"' _ "$WORK/doctor"
reset_mock auth
if forge_doctor github > "$WORK/doctor"; then exit 1; fi
check 'doctor reports auth failure safely' jq -e '.ready==false and .platforms[0].auth.authenticated==false' "$WORK/doctor"
if (type() { return 1; }; forge_doctor) > "$WORK/doctor"; then exit 1; fi
check 'doctor safely inventories missing CLIs' jq -e '.ready==false and all(.platforms[]; .installed==false and .auth.authenticated==false)' "$WORK/doctor"
if (type() { return 1; }; forge_run read gh pr list) > "$WORK/out" 2> "$WORK/err"; then exit 1; fi
check 'missing CLI categorized as dependency' grep -q '"category":"dependency"' "$WORK/err"
printf '\n%s adapter assertions passed\n' "$PASS"

# Export mocks for optional issue integration, while keeping their lifetime local.
if [ "${FORGE_TEST_ISSUES:-1}" = 1 ]; then
  SCRIPT="$ROOT/templates/codex/.agents/skills/create-issues/scripts/create-issues.sh"
  printf '## Epic\n### Tasks\n- [ ] Task A1\n- [ ] Task B1\n- [ ] Task A1\n' > "$WORK/plan.md"
  for platform in github gitlab; do
    repo=forge.example/team/project
    [ "$platform" = github ] || repo=https://forge.example/group/sub/project
    reset_mock normal
    "$SCRIPT" create "$WORK/plan.md" --platform "$platform" --repo "$repo" > "$WORK/issues"
    check "$platform paginated and within-plan duplicate protection" grep -q 'created=1 skipped=2 failed=0' "$WORK/issues"
    check "$platform issues use adapter once" test "$(count_mutations)" = 1
    check "$platform issue pages fetched" grep -q 'Task A1' "$WORK/body"
    for scenario in issues-fail issues-invalid; do
      reset_mock "$scenario"
      if "$SCRIPT" create "$WORK/plan.md" --platform "$platform" --repo "$repo" > "$WORK/issues" 2> "$WORK/err"; then exit 1; fi
      check "$platform $scenario stops issue creation" test "$(count_mutations)" = 0
    done
    reset_mock accepted-failure
    if "$SCRIPT" create "$WORK/plan.md" --platform "$platform" --repo "$repo" > "$WORK/issues" 2> "$WORK/err"; then exit 1; fi
    check "$platform uncertain issue creation cannot repeat the same title" test "$(count_mutations)" = 1
    reset_mock accepted-failure
    if "$SCRIPT" create "$WORK/plan.md" --platform "$platform" --repo "$repo" --allow-duplicates > "$WORK/issues" 2> "$WORK/err"; then exit 1; fi
    check "$platform failed issue writes are not retried" test "$(count_mutations)" = 3
  done
fi
printf '\n%s total assertions passed\n' "$PASS"
