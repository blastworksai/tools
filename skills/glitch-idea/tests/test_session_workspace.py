"""SKILLS-143: one session's Capture prefill (session_workspace) from the CLI flags to the state payload."""
import http.client
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPTS=Path(__file__).resolve().parents[1]/'glitch-idea/scripts'
sys.path.insert(0,str(SCRIPTS))
import idea
import idea_launch as launch
import idea_runtime
import idea_tern
from idea_domain import IdeaError
from idea_runtime import Runtime, RuntimeError as OwnerError

BINDING='binding_'+'a'*32


def _outside_tern(case):
    """Never let a suite started inside a Tern pane pick the pane road or write a real terminal title."""
    for name,value in (('default_is_tern',False),('find_terminal',None)):
        patcher=patch.object(idea_tern,name,return_value=value);patcher.start();case.addCleanup(patcher.stop)


def fetch(origin,method,route,payload=None,headers=None):
    port=int(origin.rstrip('/').rsplit(':',1)[-1])
    headers=dict(headers or {},Host='127.0.0.1:%d'%port)
    if payload is not None: headers.update({'Origin':origin.rstrip('/'),'Content-Type':'application/json'})
    connection=http.client.HTTPConnection('127.0.0.1',port,timeout=5)
    try:
        connection.request(method,'/api/v1/'+route,None if payload is None else json.dumps(payload),headers)
        response=connection.getresponse()
        return response.status,json.loads(response.read()),response.getheader('Set-Cookie')
    finally: connection.close()


def page_state(origin,binding_id,code):
    """Pair like the page does, then read its state."""
    status,paired,cookie=fetch(origin,'POST','pair',dict(code=code),{'X-Idea-Binding':binding_id})
    assert status==200,paired
    status,state,_=fetch(origin,'GET','state',None,{'X-Idea-Binding':binding_id,'Cookie':cookie.split(';',1)[0],'X-Idea-Tab':paired['tab_secret']})
    assert status==200,state
    return state


class Case(unittest.TestCase):
    """A real in-process owner on a throwaway store; the launcher functions talk to it over the real control channel."""
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.directory=Path(self.temp.name)
        self.store=self.directory/'ideas';self.private=self.directory/'private'
        self.a=self.directory/'project-a';self.a.mkdir()
        self.b=self.directory/'project-b';self.b.mkdir()
        self.owner=None;self.addCleanup(self.stop_owner)

    def start_owner(self,config=None):
        self.owner=launch.OwnerService(Runtime(self.store,self.private).acquire_owner(),config)
        self.owner.start()

    def stop_owner(self):
        if self.owner is not None: self.owner.shutdown();self.owner=None

    def ws(self,folder,name=None): return dict(name=name or folder.name,path=str(folder))

    def open(self,workspace=None,**kwargs):
        if workspace is not None: kwargs['session_workspace']=workspace
        return launch.open_session(self.store,self.private,**kwargs)

    def state(self,opened): return page_state(opened['origin'],opened['binding_id'],opened['pairing_code'])

    def records(self):
        folder=self.private/'bindings'
        return sorted(p.name for p in folder.glob('binding_*.json')) if folder.exists() else []

    def recovery(self):
        folder=self.store/'session-recovery'
        return sorted(p.name for p in folder.glob('*.json')) if folder.exists() else []

    def disk_record(self,binding_id):
        return json.loads(next(Runtime(self.store,self.private).path.rglob(binding_id+'.json')).read_text())


@unittest.skipUnless(os.name=='posix','Native owner ACLs are not qualified on this host')
class SessionWorkspaceTests(Case):
    def test_given_reaches_the_state_and_not_given_is_none_with_the_default_untouched(self):
        default=dict(name='Atlas',path=str(self.b))
        self.start_owner(dict(default_workspace=default))
        given=self.open(self.ws(self.a,'Project A'));plain=self.open()
        one,two=self.state(given),self.state(plain)
        self.assertEqual(one['session_workspace'],dict(name='Project A',path=str(self.a)))
        self.assertIn('session_workspace',two);self.assertIsNone(two['session_workspace'])
        self.assertEqual((one['default_workspace'],two['default_workspace']),(default,default))

    def test_state_without_any_default_still_has_the_key(self):
        self.start_owner()
        state=self.state(self.open())
        self.assertIsNone(state['session_workspace']);self.assertIsNone(state['default_workspace'])

    def test_a_path_equal_to_the_configured_default_is_accepted(self):
        default=dict(name='Atlas',path=str(self.a))
        self.start_owner(dict(default_workspace=default))
        state=self.state(self.open(dict(default)))
        self.assertEqual((state['session_workspace'],state['default_workspace']),(default,default))

    def test_refusals_are_workspace_unavailable_and_allocate_nothing(self):
        self.start_owner()
        plain=self.directory/'a-file';plain.write_text('x')
        locked=self.directory/'locked';locked.mkdir();locked.chmod(0)
        self.addCleanup(locked.chmod,0o700)
        self.open();first=(self.records(),self.recovery())
        good=self.ws(self.a)
        cases={'relative':dict(name='x',path='relative/dir'),'missing':dict(name='x',path=str(self.directory/'nope')),
               'file':dict(name='x',path=str(plain)),'long name':dict(name='n'*101,path=str(self.a)),
               'blank name':dict(name='  ',path=str(self.a)),'empty path':dict(name='x',path=''),
               'extra key':dict(good,confirmed=True),'missing key':dict(name='x'),'not an object':'nope',
               'non-string path':dict(name='x',path=5)}
        if os.geteuid()!=0: cases['unreadable']=dict(name='x',path=str(locked))
        for label,value in cases.items():
            with self.subTest(label),self.assertRaises(IdeaError) as caught:
                self.open(value)
            self.assertEqual(caught.exception.code,'workspace_unavailable')
            self.assertEqual((self.records(),self.recovery()),first,'no session or binding allocated')

    def test_a_refusal_never_starts_the_service(self):
        def spawn(*args,**kwargs): raise AssertionError('the service must not start')
        with self.assertRaises(IdeaError) as caught:
            launch.open_session(self.store,self.private,session_workspace=dict(name='x',path='relative'),spawn=spawn)
        self.assertEqual(caught.exception.code,'workspace_unavailable')
        self.assertEqual((self.records(),self.recovery()),([],[]))
        self.assertFalse((self.private/'discovery.json').exists())

    def test_the_owner_refuses_a_bad_value_itself_before_allocating(self):
        # A helper that skipped its own check still cannot make the owner allocate a session.
        self.start_owner();self.open();before=(self.records(),self.recovery())
        for value in (dict(name='x',path='relative'),dict(name='x',path=str(self.directory/'nope')),dict(name='n'*101,path=str(self.a))):
            with self.subTest(value),self.assertRaises(OwnerError):
                Runtime(self.store,self.private).open_binding('new',None,None,5,session_workspace=value)
            self.assertEqual((self.records(),self.recovery()),before)

    def test_two_sessions_on_one_store_keep_their_own_value(self):
        self.start_owner()
        one,two,none=self.open(self.ws(self.a)),self.open(self.ws(self.b)),self.open()
        self.assertEqual(self.state(one)['session_workspace']['path'],str(self.a))
        self.assertEqual(self.state(two)['session_workspace']['path'],str(self.b))
        self.assertIsNone(self.state(none)['session_workspace'])
        self.assertEqual([Runtime(self.store,self.private).load_binding(row['binding_id']).get('session_workspace') for row in (one,two,none)],
                         [self.ws(self.a),self.ws(self.b),None])
        # The owner rebuilds every session from its own record: each still gets its own value, never the last one opened.
        self.stop_owner();self.start_owner()
        again=[self.open(binding_id=row['binding_id']) for row in (one,two,none)]
        self.assertEqual([self.state(row)['session_workspace'] for row in again],[self.ws(self.a),self.ws(self.b),None])

    def test_a_resumed_session_reports_the_value_it_was_opened_with(self):
        self.start_owner()
        opened=self.open(self.ws(self.a,'Alpha'))
        resumed=self.open(binding_id=opened['binding_id'])
        self.assertEqual(self.state(resumed)['session_workspace'],dict(name='Alpha',path=str(self.a)))
        plain=self.open();again=self.open(binding_id=plain['binding_id'])
        self.assertIsNone(self.state(again)['session_workspace'])

    def test_the_value_survives_an_owner_restart(self):
        self.start_owner()
        opened=self.open(self.ws(self.a,'Alpha'))
        self.stop_owner();self.start_owner()
        resumed=self.open(binding_id=opened['binding_id'])
        self.assertEqual(self.state(resumed)['session_workspace'],dict(name='Alpha',path=str(self.a)))

    def test_a_workspace_with_a_resume_is_a_usage_refusal(self):
        self.start_owner();opened=self.open()
        with self.assertRaises(IdeaError) as caught:
            self.open(self.ws(self.a),binding_id=opened['binding_id'])
        self.assertEqual(caught.exception.code,'usage')
        with self.assertRaises(OwnerError):
            Runtime(self.store,self.private).open_binding('resume',opened['binding_id'],None,5,session_workspace=self.ws(self.a))

    def test_the_value_lives_on_the_session_record_and_never_in_the_shared_config(self):
        self.start_owner(dict(default_workspace=self.ws(self.b)))
        opened=self.open(self.ws(self.a))
        self.assertEqual(self.disk_record(opened['binding_id'])['session_workspace'],self.ws(self.a))
        self.assertNotIn('session_workspace',self.owner.config)
        self.assertEqual(self.owner.config['default_workspace'],self.ws(self.b))

    def test_cold_start_twin_first_ever_open_beside_a_second_open(self):
        for number,workspace in enumerate((self.ws(self.a),None)):
            store=self.directory/('cold-store-%d'%number);private=self.directory/('cold-private-%d'%number)
            owner=launch.OwnerService(Runtime(store,private).acquire_owner(),None);owner.start()
            self.addCleanup(owner.shutdown)
            kwargs={} if workspace is None else dict(session_workspace=workspace)
            first=launch.open_session(store,private,**kwargs)   # the very first open on this runtime root
            second=launch.open_session(store,private)           # a second open beside it
            self.assertEqual(page_state(first['origin'],first['binding_id'],first['pairing_code'])['session_workspace'],workspace)
            self.assertIsNone(page_state(second['origin'],second['binding_id'],second['pairing_code'])['session_workspace'])


@unittest.skipUnless(os.name=='posix','Native owner ACLs are not qualified on this host')
class UpgradeTests(Case):
    def old_owner(self):
        """An owner from the previous release: its binding-open accepts exactly the five old keys."""
        patcher=patch.dict(launch.CONTROL_OPTIONAL,{},clear=True);patcher.start();self.addCleanup(patcher.stop)
        self.start_owner()

    def test_cell_a_a_new_helper_without_a_workspace_works_against_an_old_owner(self):
        self.old_owner()
        self.assertEqual(launch.CONTROL_FIELDS['binding-open'],launch.OPEN_FIELDS)
        self.assertEqual(launch.OPEN_FIELDS,{'challenge','instance_nonce','store_sha256','mode','binding_id','selected_idea_id'})
        opened=self.open()   # any extra key would be refused by the exact-key check
        self.assertIsNone(self.state(opened)['session_workspace'])
        resumed=self.open(binding_id=opened['binding_id'])
        self.assertEqual(resumed['binding_id'],opened['binding_id'])
        self.assertEqual(sorted(self.disk_record(opened['binding_id'])),
                         ['actor','binding_id','receipt_session_id','schema_version','selected_idea_id'])

    def test_a_new_helper_with_a_workspace_against_an_old_owner_fails_cleanly(self):
        self.old_owner();self.open();before=(self.records(),self.recovery())
        with self.assertRaises(OwnerError) as caught:
            self.open(self.ws(self.a))
        self.assertEqual(caught.exception.code,'invalid_control')
        self.assertEqual((self.records(),self.recovery()),before)
        self.assertIsNotNone(self.open(),'the old owner is still healthy')

    def test_cell_b_records_written_by_the_previous_release_are_read(self):
        self.start_owner()
        opened=self.open()
        path=next(Runtime(self.store,self.private).path.rglob(opened['binding_id']+'.json'))
        old=json.loads(path.read_text())
        self.assertEqual(len(old),5,'a record without a prefill is exactly the old shape')
        self.stop_owner();self.start_owner()   # restore reads the old-shape record
        resumed=self.open(binding_id=opened['binding_id'])
        self.assertIsNone(self.state(resumed)['session_workspace'])
        self.assertEqual(json.loads(path.read_text()),old,'a resume leaves an old record byte-compatible')
        self.assertEqual(Runtime(self.store,self.private).load_binding(opened['binding_id']),old)

    def test_binding_validation_accepts_both_shapes_and_refuses_a_malformed_prefill(self):
        base=dict(schema_version=1,binding_id=BINDING,actor='me',receipt_session_id='session_'+'b'*32,selected_idea_id=None)
        idea_runtime._binding(dict(base))
        idea_runtime._binding(dict(base,session_workspace=dict(name='x',path='/tmp')))
        for bad in (None,'x',dict(name='x'),dict(name='',path='/tmp'),dict(name='x',path=''),dict(name='x',path='/tmp',extra=1),dict(name=1,path='/tmp')):
            with self.subTest(bad),self.assertRaises(OwnerError):
                idea_runtime._binding(dict(base,session_workspace=bad))


class CliSeamTests(unittest.TestCase):
    """The flags through idea.main, openers mocked: what is passed, and what is refused as usage."""
    def setUp(self):
        _outside_tern(self)
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.directory=Path(self.temp.name)
        self.package=self.directory/'package/glitch-idea';self.package.mkdir(parents=True)
        fake=self.package/'scripts/idea.py';fake.parent.mkdir();fake.write_text('fixture')
        self.store=self.directory/'ideas';self.runtime=self.directory/'runtime'
        (self.package/'config.json').write_text(json.dumps(dict(store_path=str(self.store),plan_validator_argv=None,validator_timeout_seconds=30)))
        patcher=patch.object(idea,'__file__',str(fake));patcher.start();self.addCleanup(patcher.stop)
        self.folder=self.directory/'proj';self.folder.mkdir()

    def invoke(self,verb,*args):
        class Output:
            def __init__(self): self.buffer=io.BytesIO()
        stream=Output()
        with patch.object(idea.sys,'stdout',stream): status=idea.main([verb,'--runtime-root',str(self.runtime),*args])
        return status,json.loads(stream.buffer.getvalue())

    def flags(self): return ['--workspace-name','Proj','--workspace-path',str(self.folder)]

    def test_both_flags_are_passed_through_every_opener(self):
        expected=dict(name='Proj',path=str(self.folder))
        fixture=dict(binding_id=BINDING,pairing_code='C',browser=dict(mode='link',url='u',link='l'),fallback_line='f')
        with patch.object(launch,'open_session',return_value=dict(binding_id=BINDING)) as opened:
            status,_=self.invoke('session-open',*self.flags())
        self.assertEqual(status,0);self.assertEqual(opened.call_args.kwargs['session_workspace'],expected)
        for mode in ('link','system'):
            with self.subTest(mode),patch.object(launch,'open_browser_session',return_value=fixture) as browser:
                status,_=self.invoke('browser-open','--browser',mode,*self.flags())
            self.assertEqual(status,0);self.assertEqual(browser.call_args.kwargs['session_workspace'],expected)
        with patch.object(launch,'open_browser_session',return_value=fixture) as browser:
            self.invoke('browser-open','--browser','orca','--orca-worktree','11111111-1111-1111-1111-111111111111::x',
                        '--orca-terminal','t',*self.flags())
        self.assertEqual(browser.call_args.kwargs['session_workspace'],expected)
        with patch.object(idea_tern,'open_tern_session',return_value=dict(binding_id=BINDING)) as pane:
            self.invoke('browser-open','--browser','tern',*self.flags())
        self.assertEqual(pane.call_args.kwargs['session_workspace'],expected)

    def test_without_the_flags_no_new_option_is_passed(self):
        with patch.object(launch,'open_session',return_value=dict(binding_id=BINDING)) as opened:
            self.invoke('session-open')
        self.assertNotIn('session_workspace',opened.call_args.kwargs)

    def test_one_flag_without_the_other_is_usage(self):
        for verb,extra in (('session-open',[]),('browser-open',['--browser','link'])):
            for half in (['--workspace-name','Proj'],['--workspace-path',str(self.folder)]):
                with self.subTest(verb=verb,half=half),patch.object(launch,'open_session') as session,patch.object(launch,'open_browser_session') as browser:
                    status,body=self.invoke(verb,*extra,*half)
                self.assertEqual((status,body['error']['code']),(1,'usage'))
                session.assert_not_called();browser.assert_not_called()

    def test_with_resume_is_usage(self):
        for verb,extra in (('session-open',[]),('browser-open',['--browser','link'])):
            with self.subTest(verb),patch.object(launch,'open_session') as session,patch.object(launch,'open_browser_session') as browser:
                status,body=self.invoke(verb,*extra,'--resume',BINDING,*self.flags())
            self.assertEqual((status,body['error']['code']),(1,'usage'))
            session.assert_not_called();browser.assert_not_called()

    def test_with_reconnect_is_usage(self):
        with patch.object(launch,'reconnect_browser_session') as reconnect,patch.object(launch,'open_browser_session') as browser:
            status,body=self.invoke('browser-open','--browser','orca','--orca-worktree','11111111-1111-1111-1111-111111111111::x',
                                    '--orca-terminal','t','--reconnect',BINDING,*self.flags())
        self.assertEqual((status,body['error']['code']),(1,'usage'))
        reconnect.assert_not_called();browser.assert_not_called()


@unittest.skipUnless(os.name=='posix','Native Windows privacy is not qualified')
class RealCliTests(unittest.TestCase):
    """The real subprocess CLI against a real spawned owner, end to end, in link mode."""
    def setUp(self):
        _outside_tern(self)
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.directory=Path(self.temp.name)
        self.package=self.directory/'source/glitch-idea'
        shutil.copytree(SCRIPTS.parent,self.package,ignore=shutil.ignore_patterns('__pycache__'))
        self.script=self.package/'scripts/idea.py'
        self.store=self.directory/'ideas';self.root=self.directory/'private runtime'
        (self.package/'config.json').write_text(json.dumps(dict(store_path=str(self.store),plan_validator_argv=None,validator_timeout_seconds=30)))
        self.client=Runtime(self.store,self.root);self.addCleanup(self.cleanup)
        self.folder=self.directory/'proj';self.folder.mkdir()

    def cleanup(self):
        try: self.client.request_owned_stop(timeout=3)
        except OwnerError: pass
        deadline=time.monotonic()+4
        while (self.client.path/'discovery.json').exists() and time.monotonic()<deadline: time.sleep(.02)

    def cli(self,*args,ok=True):
        result=subprocess.run([sys.executable,str(self.script),'--store',str(self.store),*map(str,args)],
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30)
        body=json.loads(result.stdout)
        self.assertEqual(body['ok'],ok,body);self.assertEqual(result.returncode,0 if ok else 1)
        return body

    def test_the_flags_reach_the_pages_state_and_a_bad_path_starts_nothing(self):
        bad=self.cli('browser-open','--runtime-root',self.root,'--browser','link','--workspace-name','P','--workspace-path','relative',ok=False)
        self.assertEqual(bad['error']['code'],'workspace_unavailable')
        self.assertFalse((self.root).exists() and any(self.root.rglob('discovery.json')),'the refusal started no service')
        good=self.cli('browser-open','--runtime-root',self.root,'--browser','link','--workspace-name','Proj','--workspace-path',self.folder)
        plain=self.cli('session-open','--runtime-root',self.root)
        state=page_state(good['origin'],good['binding_id'],good['pairing_code'])
        self.assertEqual(state['session_workspace'],dict(name='Proj',path=str(self.folder)))
        self.assertIsNone(page_state(plain['origin'],plain['binding_id'],plain['pairing_code'])['session_workspace'])


if __name__=='__main__':
    unittest.main()
