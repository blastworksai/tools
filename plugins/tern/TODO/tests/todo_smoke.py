#!/usr/bin/env python3
"""Real native local/SSH interactive-plan outcomes in owned disposable Tern/Xvfb/SSH."""
import argparse
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import sys
import time
from todo_test import plan, write_plan
from ssh_fixture import loopback_ssh

ROOT = Path(__file__).resolve().parents[1]
TERN = os.environ.get('TODO_TERN_BIN') or shutil.which('tern') or '/usr/local/lib/tern/current/tern'


def wait_for(check, description, seconds=10):
    deadline = time.monotonic()+seconds
    while time.monotonic()<deadline:
        value = check()
        if value:
            return value
        time.sleep(.15)
    raise AssertionError('timeout: '+description)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--files-button', action='store_true', help='Require the actual Files button/picker; needs an available client UI')
    parser.add_argument('--published', action='store_true', help='Attach through the real publication/discovery path')
    parser.add_argument('--contracts-only', action='store_true', help='Run native module/controller contracts without opening a UI window')
    args = parser.parse_args()
    evidence = {'checks': [], 'production_touched': False}
    processes = []
    # sshd StrictModes requires a safe ancestor chain; /var/tmp is deliberately sticky/shared.
    with tempfile.TemporaryDirectory(prefix='interactive-plan-smoke-', dir=Path.home()/'.cache') as temporary, ExitStack() as stack:
        base = Path(temporary)
        config = base/'config'
        config.mkdir(mode=0o700)
        shutil.copytree(ROOT, base/'plugin', ignore=shutil.ignore_patterns('.git', '__pycache__', '*.local'))
        manifest=base/'plugin/plugin.toml'
        manifest.write_text(manifest.read_text().replace('id = "todo"','id = "todo-test"'))
        local = base/'Local plan.md'
        remote = base/'SSH plan.md'
        write_plan(local, plan())
        remote_value = plan('plan-abcdef123456')
        remote_value['title'] = 'SSH interactive task'
        write_plan(remote, remote_value)
        path = stack.enter_context(loopback_ssh(base/'ssh'))
        env = dict(os.environ, PATH=str(base/'cli')+os.pathsep+path, TERN_CONFIG_DIR=str(config),
                   TERN_DAEMON_SOCKET=str(base/'daemon.sock'), STENCIL_GPU='cpu',
                   STENCIL_LOG_DIR=str(base/'logs'), STENCIL_LOG='warn,stencil=info,tern::plugin=debug')
        (base/'cli').mkdir()
        (base/'cli/tern').symlink_to(TERN)
        control = base/'window.sock'
        source_file = base/'plugin/window.luau'
        with source_file.open('a') as stream:
            for name, source in [('test_local', {'path': str(local)}), ('test_ssh', {'path': str(remote), 'ssh': 'session-plan-test'})]:
                encoded = json.dumps(json.dumps(source))
                stream.write('\ntern.command({id="'+name+'", title="Isolated fixture", run=function(cx) controller.openSource(cx,cx.session:focused(),tern.json.decode('+encoded+'),"'+('plan-abcdef123456' if name=='test_ssh' else plan()['plan_id'])+'") end})\n')
        with source_file.open('a') as stream:
            stream.write('\ntern.command({id="test_auto", title="Isolated auto attach", run=function(cx) controller.start(cx,false) end})\n')
        host = base/'plugin/host.luau'
        with host.open('a') as stream:
            stream.write('\nlocal suite=require("./tests/native_suite")\ntern.fs.write(tern.plugin.data.."/library-tests.json",tern.json.encode(suite))\n')
            stream.write('''
local function captureFixtureState()
    local out = {}
    for _, state in instances do
        if state.source then
            out[state.source.path] = {plan_id=state.plan_id, plan=state.plan, error=state.error,failures=state.failures,
                panel=state.panel,saved={schema=2,source=state.source,plan_id=state.plan_id}}
        end
    end
    tern.fs.write(tern.plugin.data .. "/fixture-state.json", tern.json.encode(out))
    tern.timer(100, captureFixtureState)
end
tern.timer(100, captureFixtureState)
''')
        def command(*parts, check=True, timeout=15):
            result = subprocess.run([TERN, *map(str, parts)], env=env, capture_output=True, text=True, timeout=timeout)
            if check and result.returncode:
                raise AssertionError(result.stderr + result.stdout)
            return result.stdout
        def ctl(*parts):
            result = json.loads(command('ctl', '--control', control, *parts))
            if result.get('ok') is False:
                raise AssertionError(result)
            return result
        def rows():
            return ctl('tree', '.sf-ck-item').get('nodes', [])
        def has_row(state, text=None):
            current = rows()
            return len(current)==1 and ('st-'+state) in current[0]['class'] and (text is None or text in current[0].get('text',''))
        def observed(source):
            location=config/'plugin-data/todo-test/fixture-state.json'
            try:return json.loads(location.read_text()).get(str(source),{})
            except (FileNotFoundError,json.JSONDecodeError):return {}
        def source_state(source,state):
            value=observed(source)
            return value.get('plan',{}).get('checkpoints',[{}])[0].get('state')==state
        def action(name):
            ctl('plugins', 'run', 'plugin.todo-test.'+name)
        log = open(base/'process.log', 'w+')
        try:
            processes.append(subprocess.Popen([TERN,'daemon','--socket',str(base/'daemon.sock')],env=env,stdout=log,stderr=log,start_new_session=True))
            wait_for(lambda:(base/'daemon.sock').exists(),'private daemon')
            command('plugin','link',base/'plugin')
            plugins=json.loads(command('plugin','list','--json'))
            assert not plugins['problems'] and plugins['plugins'][0]['status']=='ready' and plugins['plugins'][0]['id']=='todo-test',plugins
            evidence['checks'].append('real Tern host plugin loads ready')
            library=json.loads((config/'plugin-data/todo-test/library-tests.json').read_text())
            assert not library['failures'],library
            evidence['luau_view_tests_passed']=library['passed']
            if not args.contracts_only:
                if args.published:
                    first=int(command('new','session','interactive-test','--',sys.executable,base/'plugin/tests/publication_fixture.py',base/'plugin/bin/todo.py',local,base/'publication-command.json',base/'publication-ready.json').strip())
                    wait_for(lambda:(base/'publication-ready.json').exists(),'agent publishes its plan',8)
                else:
                    first=int(command('new','session','interactive-test','--','/bin/sh').strip())
                launch = ['xvfb-run','-a',TERN,'--control',str(control)]
                processes.append(subprocess.Popen(launch,env=env,cwd=base,stdout=log,stderr=log,start_new_session=True))
                wait_for(lambda:control.exists(),'private window',40)
                command('ctl', '--control', control, 'state', timeout=45)
                command('focus',first)
                wait_for(lambda: any(p.get('id')==first for p in ctl('state').get('panes',[])), 'native window attached to fixture')
                metadata=json.loads(command('process',first,'--window','','--json'))
                assert metadata['pane']==first and metadata['child']['pid']>0, metadata
                evidence['native_process_window_metadata']=metadata
                if args.files_button:
                    selector='.ft-plugin[data-plugin="todo-test"][data-id="todo"]'
                    if not ctl('tree',selector).get('nodes'):ctl('plugins','run','files')
                    wait_for(lambda:ctl('tree',selector).get('nodes'),'native TODO Files button',8)
                    ctl('a11y','click',selector)
                    wait_for(lambda:'Which agent session' in json.dumps(ctl('tree')),'native session picker',8)
                    ctl('type',str(first));ctl('key','Enter')
                    evidence['checks'].append('real Files button selects the publisher session without an agent or operator plan prompt')
                else:action('show' if args.published else 'test_local')
                wait_for(lambda:has_row('pending','Prove the outcome'),'local source checklist')
                evidence['checks'].append('explicit local checkpoint block renders native pending state')
                write_plan(local,plan(state='done'))
                wait_for(lambda:has_row('done'),'automatic source refresh')
                evidence['checks'].append('canonical edit automatically renders done without an agent hook')
                command('focus',first)
                action('show');action('show')
                assert len(rows())==1,rows()
                evidence['checks'].append('repeated show preserves one panel per tab')
                write_plan(local,plan('plan-999999999999'))
                wait_for(lambda:'different plan' in observed(local).get('error','') and not observed(local).get('plan'),'identity replacement refusal')
                evidence['checks'].append('different plan at the same path cannot replace the pinned plan id')
                command('plugin','reload','todo-test')
                wait_for(lambda:'different plan' in observed(local).get('error','') and observed(local).get('saved',{}).get('plan_id')=='plan-123456abcdef','restored identity refusal')
                evidence['checks'].append('plugin restore retains the pinned source/id, never a source-pane number')
                write_plan(local,plan())
                wait_for(lambda:source_state(local,'pending'),'original source restored')
                local.write_text('# No checkpoint block\n')
                wait_for(lambda:'checkpoint block' in observed(local).get('error','') and not observed(local).get('plan'),'source failure invalidation')
                evidence['checks'].append('source loss clears old success and reaches the native error view')
                write_plan(local,plan())
                second=int(command('new','tab','interactive-test','--','/bin/sh').strip())
                command('focus',second)
                wait_for(lambda:ctl('state').get('focused',{}).get('id')==second and any(p.get('id')==second for p in ctl('state').get('panes',[])), 'second fixture pane published in the native window')
                action('test_ssh')
                wait_for(lambda:source_state(remote,'pending'),'real SSH source response in native host',12)
                evidence['checks'].append('real loopback SSH key-authenticated source reaches native host view state')
                remote_value['checkpoints'][0]['state']='done'
                write_plan(remote,remote_value)
                wait_for(lambda:source_state(remote,'done'),'SSH canonical edit refresh',20)
                evidence['checks'].append('SSH source edits automatically refresh native view state')
                remote.unlink()
                wait_for(lambda:observed(remote).get('error') and observed(remote).get('failures')==1,'SSH error backoff',20)
                assert 'Remote PLAN:' in observed(remote).get('error',''), 'remote source failure was reported as an SSH transport problem'
                time.sleep(2.2)
                assert observed(remote).get('failures')==1, 'failed SSH source retried at the local refresh rate'
                evidence['checks'].append('failed real SSH source clears success and does not retry at the local polling rate')
                command('focus',first)
                wait_for(lambda:source_state(local,'pending'),'independent local source')
                evidence['checks'].append('local and SSH views keep independent plan identities and state')
                if args.published:
                    (base/'publication-command.json').write_text(json.dumps({'command':'clear'}))
                    wait_for(lambda:json.loads((base/'publication-ready.json').read_text()).get('command')=='clear','agent clears publication',8)
                    wait_for(lambda:'not working on a published plan' in observed(local).get('error','') and not observed(local).get('plan'),'publication clear invalidates old success',8)
                    os.kill(json.loads((base/'publication-ready.json').read_text())['pid'],0)
                    evidence['checks'].append('clearing the publication removes old success without closing the agent')
                    old=observed(local)['panel'];command('close',old)
                    command('focus',first)
                    wait_for(lambda:all(p.get('id')!=old for p in ctl('state').get('panes',[])),'old TODO panel closes')
                    action('show')
                    wait_for(lambda:'No active plan is published for this session.' in json.dumps(ctl('tree')),'no-plan notice after real attach',8)
                    time.sleep(.3)
                    os.kill(json.loads((base/'publication-ready.json').read_text())['pid'],0)
                    evidence['checks'].append('no published plan exits the TODO flow and leaves the selected program alive')
                evidence['visual_qualification']='Initial local pending/done rows observed; later checks use actual host callback state because the closed-beta sign-in overlay hides the client UI. Remote/restored visual qualification remains open.'
            else:
                evidence['visual_qualification']='Native module/controller contracts only; no window or live agent queried.'
            evidence['runtime']=command('--version').strip()
            evidence['source_hashes']={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in ['host.luau','window.luau','lib/plan_view.luau','lib/polling.luau','lib/attach.luau','bin/todo.py','bin/publication.py','bin/process_identity.py']}
            evidence['passed']=True
        except Exception as error:
            evidence['passed']=False;evidence['error']=str(error)
            log.flush();log.seek(0);evidence['process_log_tail']=log.read()[-3000:]
            evidence['native_logs']={str(p.relative_to(base/'logs')):p.read_text(errors='replace')[-5000:] for p in (base/'logs').rglob('*.log')}
            evidence['process_exit_codes']=[p.poll() for p in processes]
            try:
                evidence['last_native_rows']=rows()
                evidence['last_native_state']=ctl('state')
                evidence['last_native_tree']=ctl('tree')
            except Exception:pass
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    os.killpg(process.pid,signal.SIGTERM)
                    try:process.wait(timeout=4)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=4)
            log.close()
            evidence['own_processes_reaped']=all(p.poll() is not None for p in processes)
        args.evidence.parent.mkdir(parents=True,exist_ok=True)
        args.evidence.write_text(json.dumps(evidence,indent=2)+'\n')
    print(json.dumps({k:v for k,v in evidence.items() if k not in ('last_native_tree','last_native_state')},indent=2))
    return 0 if evidence.get('passed') and evidence.get('own_processes_reaped') else 1


if __name__=='__main__':
    raise SystemExit(main())
