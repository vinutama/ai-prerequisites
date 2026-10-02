#!/usr/bin/env bash
# Public review and merge commands: typed payloads and assignment identity.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$ROOT" <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile
root=pathlib.Path(sys.argv[1]); assertions=0
mock=r'''#!/usr/bin/env python3
import json,os,pathlib,sys
a=sys.argv[1:];p=pathlib.Path(os.environ['FIXTURE']);platform=os.environ['PLATFORM'];sha=os.environ['SHA'];base=os.environ['BASE_SHA']
def v(flag):return a[a.index(flag)+1]
if a==['--version']:print('fixture 1.0');sys.exit(0)
if '--help' in a:
 for flag in ('--repo','--head','--base','--state','--limit','--json','--source-branch','--target-branch','--output','--page','--per-page','--hostname','--method','--input','--merge','--match-head-commit','--sha','--yes','--auto-merge'):print('  '+flag+' value Fixture')
 sys.exit(0)
resolved=(p/'resolved').exists();merged=(p/'merged').exists()
meta=dict(number=7,url='https://forge.test/team/app/pull/7',headRefName='feat/changes',baseRefName='main',headRefOid=sha,state='OPEN',isCrossRepository=False)
if platform=='gitlab':meta=dict(iid=7,web_url='https://forge.test/team/app/-/merge_requests/7',source_branch='feat/changes',target_branch='main',sha=sha,state='opened',source_project_id=1,target_project_id=1)
if a[:2] in (['pr','list'],['mr','list']):print(json.dumps([meta]))
elif a[:2] in (['pr','view'],['mr','view']):print(json.dumps(meta))
elif a[:2] in (['pr','merge'],['mr','merge']):
 assert v('--repo')==('forge.test/team/app' if platform=='github' else 'https://forge.test/team/app')
 assert v('--match-head-commit' if platform=='github' else '--sha')==sha
 if platform=='gitlab':assert '--yes' in a and '--auto-merge=false' in a
 with (p/'writes').open('a') as f:f.write('merge\n')
 if not (p/'queued').exists():(p/'merged').touch()
 print('Merge requested')
elif a[0]=='api':
 endpoint=a[1].split('?')[0];method=v('--method');payload=json.loads(pathlib.Path(v('--input')).read_text()) if '--input' in a else None
 assert v('--hostname')=='forge.test'
 if (p/'fail-other').exists() and ('team/other/' in endpoint or 'team%2Fother/' in endpoint):
  print('Forbidden: second repository fixture',file=sys.stderr);sys.exit(1)
 if endpoint.endswith('/files'):print('[{"filename":"feature.txt"}]')
 elif endpoint.endswith('/diffs'):print('[{"new_path":"feature.txt"}]')
 elif endpoint.endswith('/versions'):print(json.dumps([dict(base_commit_sha=base,head_commit_sha=sha,start_commit_sha=base)]))
 elif endpoint=='graphql':
  if payload['query'].startswith('mutation'):
   assert payload['variables']['id']=='thread-1';(p/'resolved').touch()
   with (p/'writes').open('a') as f:f.write('resolve\n')
   print('{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}')
  else:
   assert payload['variables']['number']==7
   print(json.dumps(dict(data=dict(repository=dict(pullRequest=dict(reviewThreads=dict(nodes=[dict(id='thread-1',path='feature.txt',line=5,isResolved=resolved,isOutdated=False,comments=dict(nodes=[dict(body='Review finding')]))],pageInfo=dict(hasNextPage=False,endCursor=None))))))))
 elif method=='POST':
  with (p/'writes').open('a') as f:f.write('comment\n')
  (p/'payload.json').write_text(json.dumps(payload));print('{"id":1}')
 elif method=='PUT':
  assert endpoint.endswith('/discussions/discussion-1') and payload=={'resolved':True}
  (p/'resolved').touch()
  with (p/'writes').open('a') as f:f.write('resolve\n')
  print('{"id":"discussion-1"}')
 elif endpoint.endswith('/discussions'):
  print(json.dumps([dict(id='discussion-1',notes=[dict(body='Review finding',resolvable=True,resolved=resolved,position=dict(new_path='feature.txt',new_line=5)),dict(body='general note',resolvable=False)])]))
 else:
  if platform=='github':print(json.dumps(dict(number=7,merged=merged,head=dict(ref='feat/changes',sha=sha,repo=dict(full_name='team/app')),base=dict(ref='main',repo=dict(full_name='team/app')))))
  else:print(json.dumps(dict(meta,state='merged' if merged else 'opened')))
else:raise SystemExit('Unexpected call '+repr(a))
'''
with tempfile.TemporaryDirectory(prefix='codex-review-') as temp:
 temp=pathlib.Path(temp)
 for platform in ('github','gitlab'):
  p=temp/platform;p.mkdir();remote=temp/(platform+'.git')
  def git(*args):return subprocess.check_output(['git','-C',str(p),*args],stderr=subprocess.DEVNULL,text=True).strip()
  git('init','-q','-b','main');git('config','user.name','Fixture');git('config','user.email','fixture@example.test')
  (p/'.gitignore').write_text('.codex/\nstate.json\nbin/\n')
  git('add','.gitignore');git('commit','-qm','seed');base=git('rev-parse','HEAD')
  subprocess.check_call(['git','init','-q','--bare',str(remote)]);git('remote','add','origin',str(remote));git('push','-qu','origin','main')
  git('checkout','-qb','feat/changes');(p/'feature.txt').write_text('one\ntwo\nthree\nfour\nfive\n');git('add','feature.txt');git('commit','-qm','feat: changes');git('push','-qu','origin','feat/changes');sha=git('rev-parse','HEAD')
  shutil.copytree(root/'templates/codex/.codex',p/'.codex');(p/'bin').mkdir();fixture=p/'bin'
  cli=fixture/('gh' if platform=='github' else 'glab');cli.write_text(mock);cli.chmod(0o755)
  repo='forge.test/team/app' if platform=='github' else 'https://forge.test/team/app'
  (p/'.codex/goal-config.json').write_text(json.dumps(dict(platform=platform,forge_repo=repo,review_mode='inline')))
  state=[dict(id='review-goal',branch='feat/changes',base_branch='main',status='in_progress',pr_number=7,pr_url='https://forge.test/pr/7',
    harness=dict(phase='DONE',tasks=[],spawn_reservations=[],requirements=dict(planner=False,reviewer=False,qa=False,visual=False),gates=dict(IMPLEMENTATION=dict(status='PASS'),ANALYSIS=dict(status='PASS',sha=sha),VERIFICATION=dict(status='PASS',sha=sha))),
    repos=[dict(path='.',pr_number=7,pr_url='https://forge.test/pr/7',delivery=dict(validated=True,verified_sha=sha))])]
  state_file=p/'state.json';state_file.write_text(json.dumps(state));helper=p/'.codex/scripts/goal-git.sh'
  env=dict(os.environ,PATH=str(fixture)+':'+os.environ['PATH'],FIXTURE=str(fixture),PLATFORM=platform,SHA=sha,BASE_SHA=base)
  def run(*args,ok=True):
   result=subprocess.run(['bash',str(helper),*args],env=env,text=True,capture_output=True,timeout=15)
   assert (result.returncode==0)==ok,(args,result.stdout,result.stderr)
   return result
  def check(condition,label):
   global assertions
   assert condition,label;assertions+=1;print('PASS:',platform,label)
  threads=json.loads(run('threads').stdout);check(threads[0]['path']=='feature.txt' and threads[0]['line']==5,'normalized scoped thread position')
  run('pending',ok=False)
  body='Quotes " and literal \\n\n$(echo must-not-run)'
  run('comment','feature.txt','5',body)
  payload=json.loads((fixture/'payload.json').read_text());check(payload['body']==body,'comment body stays literal')
  if platform=='gitlab':check(payload['position']['new_line']==5 and payload['position']['head_sha']==sha and not any('[' in key for key in payload),'GitLab nested typed position payload')
  else:check(payload['line']==5 and payload['commit_id']==sha and payload['side']=='RIGHT','GitHub typed comment payload')
  before=(fixture/'writes').read_text();run('resolve','foreign-thread',ok=False);check((fixture/'writes').read_text()==before,'foreign thread rejected before mutation')
  tid='thread-1' if platform=='github' else 'discussion-1';run('resolve',tid);check(json.loads(run('pending').stdout)['unresolved']==0,'resolution verified by platform evidence')
  state[0]['pr_number']=8;state[0]['repos'][0]['pr_number']=8;state_file.write_text(json.dumps(state))
  run('comment','feature.txt','5','stale request',ok=False);check((fixture/'writes').read_text().count('comment')==1,'stale PR identity blocks comment')
  state[0]['pr_number']=7;state[0]['repos'][0]['pr_number']=7;state_file.write_text(json.dumps(state))
  (fixture/'queued').touch();result=run('merge',ok=False);check('merge_pending' in result.stderr and not json.loads(state_file.read_text())[0]['repos'][0]['delivery'].get('merged'),'queued merge cannot claim completion')
  (fixture/'queued').unlink()
  # If the second repository fails, keep the first confirmed merge scoped to
  # its repository even when both requests have the same numeric identity.
  second=temp/(platform+'-other')
  subprocess.check_call(['git','clone','-q','-b','feat/changes',str(remote),str(second)])
  config=p/'.codex/goal-config.json'
  # Use a configured relative checkout key; directory contents are already
  # ignored by the fixture so the controller remains clean.
  second.rename(p/'bin'/'other');other_key='bin/other'
  config.write_text(json.dumps(dict(platform=platform,repos=['.',other_key],forge_repos={'.':repo,other_key:repo.replace('team/app','team/other')},review_mode='inline')))
  state[0]['repos'].append(dict(path=other_key,pr_number=7,pr_url='https://forge.test/other/pr/7',delivery=dict(validated=True,verified_sha=sha)))
  state[0]['harness']['repo_gates']={row['path']:dict(ANALYSIS=dict(status='PASS',sha=sha),VERIFICATION=dict(status='PASS',sha=sha)) for row in state[0]['repos']}
  state_file.write_text(json.dumps(state))
  # Fail the second request lookup after the first remote merge confirms.
  (fixture/'fail-other').touch();run('merge',ok=False)
  saved=json.loads(state_file.read_text())[0]['repos']
  check(saved[0]['delivery'].get('merged') and not saved[1]['delivery'].get('merged'),'same request number in another repository retains independent merge state')
  (fixture/'fail-other').unlink()
  state[0]['repos']=saved[:1];state_file.write_text(json.dumps(state))
  config.write_text(json.dumps(dict(platform=platform,forge_repo=repo,review_mode='inline')))
  run('merge');check(json.loads(state_file.read_text())[0]['repos'][0]['delivery']['merged'],'merge pins reviewed SHA and confirms remote state')
  before=(fixture/'writes').read_text();run('merge');check((fixture/'writes').read_text()==before,'completed remote merge resumes without another mutation')
print(str(assertions)+' review assertions passed')
PY
