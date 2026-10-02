#!/usr/bin/env bash
# Public-command integration tests with real local repositories and no network.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$ROOT" <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1]); count = 0
with tempfile.TemporaryDirectory(prefix='codex-context-') as tmp:
    tmp = pathlib.Path(tmp); project = tmp/'project with spaces'; project.mkdir()
    remote = tmp/'remote.git'
    def git(*args, cwd=project):
        return subprocess.check_output(['git', '-C', str(cwd), *args], stderr=subprocess.DEVNULL, text=True).strip()
    git('init','-q','-b','main'); subprocess.check_call(['git','init','-q','--bare',str(remote)])
    git('config','user.name','Fixture'); git('config','user.email','fixture@example.test')
    git('remote','add','origin',str(remote))
    (project/'README.md').write_text('seed\n')
    (project/'.gitignore').write_text('.codex/\n.agents/\nAGENTS.md\nstate.json\n.worktrees/\n.goal-review/\nbin/\n')
    git('add','.gitignore','README.md'); git('commit','-qm','seed'); git('push','-u','origin','main')
    shutil.copytree(root/'templates/codex/.codex',project/'.codex')
    shutil.copytree(root/'templates/codex/.agents',project/'.agents')
    shutil.copy(root/'templates/codex/AGENTS.md',project/'AGENTS.md')
    config = dict(platform='github',goal_source='prompt',target_branch='main',repos=['.'],
                  forge_repo='team/app',review_mode='local',verify_commands=[dict(name='syntax',cmd='git diff --check')])
    config_path=project/'.codex/goal-config.json'
    def set_config(**values):
        config.update(values); config_path.write_text(json.dumps(config))
    set_config()
    mock_dir=project/'bin';mock_dir.mkdir()
    mock='''#!/usr/bin/env python3
import json,os,pathlib,sys
args=sys.argv[1:]
if args==['--version']:print('fixture 1.0');sys.exit(0)
if args[:2]==['issue','view']:
 n=int(args[2]); repo=args[args.index('--repo')+1]
 print(json.dumps(dict(number=n,iid=n,title='Issue '+str(n),body='Full body',description='Full body',labels=[],url=repo+'/issues/'+str(n),web_url=repo+'/-/issues/'+str(n))))
elif args[:2]==['issue','list']:
 pathlib.Path(os.environ['CALL_FILE']).write_text(json.dumps(args));print('[]')
else:raise SystemExit('unexpected forge call '+repr(args))
'''
    for name in ('gh','glab'):
        f=mock_dir/name;f.write_text(mock);f.chmod(0o755)
    env=dict(os.environ,PATH=str(mock_dir)+':'+os.environ['PATH'],CALL_FILE=str(tmp/'calls'))
    helper=project/'.codex/scripts/goal-git.sh'
    def run(*args, selectors=None, success=True, local=None):
        current=dict(env);current.update(selectors or {})
        result=subprocess.run(['bash',str(local or helper),*args],env=current,text=True,capture_output=True,timeout=15)
        if success and result.returncode:raise AssertionError((args,result.stdout,result.stderr))
        if not success and not result.returncode:raise AssertionError(('unexpected success',args,result.stdout))
        return result
    def check(value, label):
        global count
        assert value,label;count+=1;print('PASS:',label)
    state_path=project/'state.json'
    def state():return json.loads(state_path.read_text())
    def save(data):state_path.write_text(json.dumps(data))
    check(run('help').returncode==0,'help works before state exists')
    run('start','Fix intake routing')
    check(state()[-1]['source']['body']=='Fix intake routing','prompt persists full source snapshot')
    first_id=state()[-1]['id']
    git('checkout','main')
    set_config(goal_source='jira')
    run('start','Fix ticket intake','APP-42',success=False)
    check(len(state())==1 and git('branch','--show-current')=='main','Jira without fetched snapshot cannot start')
    source=tmp/'jira.json';source.write_text(json.dumps(dict(type='jira',title='Fix ticket intake',body='Complete ticket body',reference='APP-42',acceptance_criteria=['Intake works'])))
    run('start','Fix ticket intake','APP-42','fix','--source-file',str(source))
    check(state()[-1]['source']['acceptance_criteria']==['Intake works'],'Jira preserves fetched body and acceptance criteria')
    git('checkout','main');set_config(goal_source='markdown',goal_file='README.md',markdown_pr_strategy='auto')
    run('start','Implement file plan')
    check(state()[-1]['source']['body']=='seed\n' and state()[-1]['branch']=='','Markdown snapshot and group delivery persist')
    set_config(goal_source='issues',issue_list_url='https://github.com/team/app/issues')
    run('issues','start','91','--url','https://github.com/team/app/issues','--worktree',
        selectors={'GOAL_ID':'','GOAL_RUN_ID':'run-a','GOAL_ISSUE':'91','GOAL_GROUP':'','GOAL_TASK':'','GOAL_REPO':'','GOAL_ISSUE_REPO':'team/app'})
    check(state()[-1]['issue']['number']==91 and state()[-1]['run_id']=='run-a','explicit new issue selectors bypass unrelated prompt/Jira/Markdown state')
    selected={'GOAL_ISSUE':'91','GOAL_RUN_ID':'run-a'}
    wt=project/state()[-1]['worktree'];local=wt/'.codex/scripts/goal-git.sh'
    check((wt/'.codex/agents/reviewer.toml').exists() and (wt/'.agents/skills/goal/SKILL.md').exists() and (wt/'AGENTS.md').exists(),'worktree receives role files, skills and instructions')
    context=json.loads(run('context',selectors=selected).stdout)
    check(context['TARGET_WORKTREE']==str(wt) and context['WORKFLOW_ROOT']==str(project),'root resolves selected issue worktree')
    check(json.loads(run('context',selectors=selected,local=local).stdout)['GOAL_ID']==state()[-1]['id'],'copied helper resolves shared goal ID')
    (wt/'README.md').write_text('seed\nissue change\n')
    run('stage','README.md',selectors=selected)
    check('issue change' in run('diff',selectors=selected).stdout and git('diff','--cached','--name-only')=='','root diff sees selected staged work and leaves root index untouched')
    run('review','init',selectors=selected);run('review','add','README.md','2','minor','Check result',selectors=selected)
    run('review','init',selectors=selected)
    check(len(json.loads(run('review','list',selectors=selected).stdout))==1,'review resume preserves existing findings')
    run('review','list','.worktrees/issue-91',selectors=selected,success=False)
    check(not (project/'.goal-review'/'.json').exists(),'review rejects worktree paths as repository keys')
    (wt/'.codex/user-settings.txt').write_text('owned by user')
    (project/'.codex/user-settings.txt').write_text('template')
    run('worktree','sync',str(wt),selectors=selected)
    check((wt/'.codex/user-settings.txt').read_text()=='owned by user','sync preserves worktree user configuration')
    check(json.loads(run('issues','queue',selectors={'GOAL_RUN_ID':'run-a'}).stdout)[0]['issue']['number']==91,'queue reads state without blocking on stdin')
    run('commit','fix: intake routing',selectors=selected)
    run('harness','init','--route','backend','--qa','false','--visual','false','--complexity','TRIVIAL',selectors=selected)
    report=json.loads(run('verify','run',selectors=selected).stdout)
    check(report['overall']=='PASS' and report['sha']==git('rev-parse','HEAD',cwd=wt),'verification stdout is one JSON report with committed SHA')
    check(state()[-1]['harness']['gates']['VERIFICATION']['sha']==report['sha'],'verification gate binds evidence to actual commit')
    (wt/'README.md').write_text('seed\nsecond change\n');run('stage','README.md',selectors=selected)
    check(state()[-1]['harness']['gates']['VERIFICATION']['status']=='NOT_RUN','working changes invalidate downstream evidence')
    run('harness','done',selectors=selected,success=False);run('state','complete',selectors=selected,success=False)
    check(state()[-1]['status']=='in_progress','failed or incomplete evidence cannot mark goal complete')
    run('restore','README.md',selectors=selected)
    git('reset','--quiet','HEAD','README.md',cwd=wt);git('restore','README.md',cwd=wt)
    run('worktree','add','task-one',selectors=selected)
    assignment=dict(selected,GOAL_TASK='task-one');task_wt=project/state()[-1]['task_worktrees']['task-one']['worktree']
    (task_wt/'README.md').write_text('seed\ntask change\n');run('stage','README.md',selectors=assignment)
    check(git('diff','--cached','--name-only',cwd=task_wt)=='README.md' and git('diff','--cached','--name-only',cwd=wt)=='','task selector routes staging to task worktree')
    run('commit','fix: task change',selectors=assignment)
    run('worktree','merge','task-one',selectors=selected)
    check('task change' in (wt/'README.md').read_text() and not task_wt.exists(),'task integration merges committed clean source into selected issue')
    (wt/'uncommitted.txt').write_text('keep this')
    run('issues','finish','91',selectors={'GOAL_RUN_ID':'run-a'},success=False)
    check((wt/'uncommitted.txt').exists(),'blocked delivery preserves dirty worktree')
    (wt/'uncommitted.txt').unlink()
    duplicate=state();entry=dict(duplicate[-1],id='other-goal',run_id='run-b');duplicate.append(entry);save(duplicate)
    run('context',selectors={'GOAL_ISSUE':'91'},success=False)
    check(json.loads(run('context',selectors=selected).stdout)['GOAL_ID']!=entry['id'],'repeated issue numbers require unambiguous run or goal ID')
    run('issues','list','https://gitlab.internal/team/nested/app/-/issues?label_name%5B%5D=bug+fix&search=quoted%20value','3')
    argv=json.loads((tmp/'calls').read_text())
    check(argv[argv.index('--repo')+1]=='https://gitlab.internal/team/nested/app' and argv[argv.index('--label')+1]=='bug fix' and argv[argv.index('--search')+1]=='quoted value','issue URL preserves self hosted namespace and decoded filters')
    run('issues','list','https://gitlab.internal/team/app/-/issues?unsupported=1',success=False)
    check(True,'unsupported issue filters fail explicitly')
    # Multi-repository evidence must cover each implementation independently.
    for service in ('svc-a','svc-b'):
        folder=project/service;folder.mkdir()
        git('init','-q','-b','main',cwd=folder)
        git('config','user.name','Fixture',cwd=folder);git('config','user.email','fixture@example.test',cwd=folder)
        (folder/'README.md').write_text(service+' seed\n')
        git('add','README.md',cwd=folder);git('commit','-qm','seed',cwd=folder)
        origin=tmp/(service+'.git');subprocess.check_call(['git','init','-q','--bare',str(origin)])
        git('remote','add','origin',str(origin),cwd=folder);git('push','-qu','origin','main',cwd=folder)
    for name in ('npx','rtk'):
        f=mock_dir/name;f.write_text('#!/usr/bin/env bash\nexit 0\n');f.chmod(0o755)
    set_config(goal_source='prompt',repos=['svc-a','svc-b'],forge_repo=None,
               forge_repos={'svc-a':'team/svc-a','svc-b':'team/svc-b'},
               verify_commands=[dict(name='syntax',cmd='git diff --check'),dict(name='readme',cmd='test -f README.md')])
    run('start','Verify two repositories')
    run('harness','init','--route','backend','--qa','false','--visual','false','--complexity','TRIVIAL')
    a={'GOAL_REPO':'svc-a'};b={'GOAL_REPO':'svc-b'}
    check(json.loads(run('context',selectors=a).stdout)['GOAL_GIT']==str(helper),'configured repositories resolve the installed helper')
    run('analyze',selectors=a)
    partial=json.loads(run('verify','run','--only','syntax',selectors=a,success=False).stdout)
    check(partial['overall']=='UNKNOWN','partial verification cannot pass the full gate')
    run('verify','run',selectors=a)
    blocked=run('harness','done',success=False)
    check('svc-b' in blocked.stderr and 'stale_evidence' in blocked.stderr,'completion requires evidence for every configured repository')
    run('analyze',selectors=b);run('verify','run',selectors=b)
    check(set(state()[-1]['harness']['repo_gates'])=={'svc-a','svc-b'},'per-repository evidence is persisted separately')
    blocked=run('harness','done',success=False)
    check('IMPLEMENTATION' in blocked.stdout+blocked.stderr and 'stale_evidence' not in blocked.stderr,'complete repository checks still require implementation evidence')
print(str(count)+' context assertions passed')
PY
