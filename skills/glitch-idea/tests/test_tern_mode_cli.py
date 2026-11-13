"""browser-open tern mode through the real CLI entry: the mode grid, then the status cells against a real service.

No real terminal is ever touched: the terminal finder is patched to a temp file, and a watcher thread plays the plugin
(it reads the request title from that file and claims over loopback HTTP). Nothing binds 8845 or 8860.
"""
import http.client
import io
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

SCRIPTS=Path(__file__).resolve().parents[1]/'glitch-idea/scripts'
sys.path.insert(0,str(SCRIPTS))
import idea
import idea_launch as launch
import idea_tern
from idea_runtime import Runtime,RuntimeError as OwnerError

BINDING='binding_'+'a'*32
TITLE=re.compile(rb'\x1b\]2;glitch-idea:1:([0-9]{1,5}):([0-9a-f]{32})\x07')


class Output:
    def __init__(self): self.buffer=io.BytesIO()


class Base(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.directory=Path(self.temp.name)
        self.package=self.directory/'package/glitch-idea';self.package.mkdir(parents=True)
        fake=self.package/'scripts/idea.py';fake.parent.mkdir();fake.write_text('fixture')
        self.store=self.directory/'ideas';self.runtime=self.directory/'runtime'
        patcher=patch.object(idea,'__file__',str(fake));patcher.start();self.addCleanup(patcher.stop)

    def config(self,**extra):
        (self.package/'config.json').write_text(json.dumps(dict(store_path=str(self.store),plan_validator_argv=None,
                                                               validator_timeout_seconds=30,**extra)))

    def invoke(self,*args):
        stream=Output()
        with patch.object(idea.sys,'stdout',stream): status=idea.main(['browser-open','--runtime-root',str(self.runtime),*args])
        return status,json.loads(stream.buffer.getvalue())


class TernModeGridTests(Base):
    """open_tern_session / open_browser_session mocked: which mode the launcher resolves and what it refuses."""
    def setUp(self):
        super().setUp()
        self.fixture=dict(binding_id=BINDING,browser=dict(mode='tern',url='http://127.0.0.1:1/',opened=True,how='above'))
        self.terminal='/dev/pts/not-a-real-one'
        for name,value in (('find_terminal',self.terminal),):
            patcher=patch.object(idea_tern,name,return_value=value);patcher.start();self.addCleanup(patcher.stop)

    def run_cell(self,*args,default=False):
        with patch.object(idea_tern,'default_is_tern',return_value=default) as probe,\
             patch.object(idea_tern,'open_tern_session',return_value=self.fixture) as tern,\
             patch.object(launch,'open_browser_session',return_value={'browser':{'mode':'link'}}) as browser,\
             patch.object(launch,'open_session') as session:
            status,body=self.invoke(*args)
        return status,body,tern,browser,session,probe

    def assert_tern(self,status,body,tern):
        self.assertEqual(status,0);tern.assert_called_once()
        self.assertEqual(tern.call_args.kwargs['terminal'],self.terminal)
        self.assertEqual(body['browser'],self.fixture['browser'])

    def test_flag_tern(self):
        self.config()
        status,body,tern,browser,_,_=self.run_cell('--browser','tern')
        self.assert_tern(status,body,tern);browser.assert_not_called()

    def test_config_tern(self):
        self.config(browser_mode='tern')
        status,body,tern,browser,_,probe=self.run_cell()
        self.assert_tern(status,body,tern);browser.assert_not_called();probe.assert_not_called()

    def test_unset_and_default_true_is_tern(self):
        self.config()
        status,body,tern,browser,_,probe=self.run_cell(default=True)
        self.assert_tern(status,body,tern);browser.assert_not_called();probe.assert_called_once()

    def test_unset_and_default_false_is_browser_mode_required(self):
        self.config()
        status,body,tern,browser,session,_=self.run_cell(default=False)
        self.assertEqual((status,body['error']['code']),(1,'browser_mode_required'))
        for mock in (tern,browser,session): mock.assert_not_called()

    def test_config_link_beats_the_default(self):
        self.config(browser_mode='link')
        status,body,tern,browser,_,probe=self.run_cell(default=True)
        self.assertEqual(status,0);self.assertEqual(browser.call_args.kwargs['mode'],'link')
        tern.assert_not_called();probe.assert_not_called()

    def test_explicit_flag_beats_the_default(self):
        self.config()
        status,body,tern,browser,_,_=self.run_cell('--browser','system',default=True)
        self.assertEqual(status,0);self.assertEqual(browser.call_args.kwargs['mode'],'system');tern.assert_not_called()
        status,body,tern,browser,_,_=self.run_cell('--browser','link',default=True)
        self.assertEqual(browser.call_args.kwargs['mode'],'link');tern.assert_not_called()

    def test_flag_tern_beats_config_link(self):
        self.config(browser_mode='link')
        status,body,tern,browser,_,_=self.run_cell('--browser','tern')
        self.assert_tern(status,body,tern);browser.assert_not_called()

    def test_tern_refuses_orca_selectors_and_reconnect_with_usage(self):
        self.config()
        for extra in (['--orca-worktree','X'],['--orca-terminal','X'],['--orca-host','X'],['--reconnect',BINDING]):
            with self.subTest(extra=extra):
                status,body,tern,browser,session,_=self.run_cell('--browser','tern',*extra)
                self.assertEqual((status,body['error']['code']),(1,'usage'))
                for mock in (tern,browser,session): mock.assert_not_called()

    def test_default_tern_also_refuses_orca_selectors(self):
        self.config()
        status,body,tern,_,_,_=self.run_cell('--orca-worktree','X',default=True)
        self.assertEqual((status,body['error']['code']),(1,'usage'));tern.assert_not_called()

    def test_a_refused_link_is_a_typed_error_not_launcher_failed(self):
        self.config()
        with patch.object(idea_tern,'open_tern_session',side_effect=launch.LaunchError('invalid_pair_url')):
            status,body=self.invoke('--browser','tern')
        self.assertEqual((status,body['error']['code']),(1,'invalid_pair_url'))

    def test_bad_configured_mode_is_still_invalid_config(self):
        self.config(browser_mode='orca')
        with patch.object(idea_tern,'open_tern_session') as tern:
            status,body=self.invoke('--browser','tern')
        self.assertEqual((status,body['error']['code']),(1,'invalid_config'));tern.assert_not_called()


class TernModeDetectionTests(Base):
    """The real default_is_tern is never patched: its inputs (terminal, TERN_PANE, ancestor) pick the mode."""
    FIXTURE=dict(binding_id=BINDING,browser=dict(mode='tern',url='http://127.0.0.1:1/',opened=True,how='above'))

    def cell(self,terminal,pane,named):
        self.config()
        env={key:value for key,value in os.environ.items() if key!='TERN_PANE'}
        if pane: env['TERN_PANE']='1'
        with patch.dict(os.environ,env,clear=True),\
             patch.object(idea_tern,'find_terminal',return_value=terminal),\
             patch.object(idea_tern,'ancestor_named',return_value=named) as ancestor,\
             patch.object(idea_tern,'open_tern_session',return_value=self.FIXTURE) as tern,\
             patch.object(launch,'open_browser_session') as browser,\
             patch.object(launch,'open_session') as session:
            status,body=self.invoke()
        return status,body,tern,browser,session,ancestor

    def test_terminal_and_tern_pane_select_tern_mode(self):
        status,body,tern,browser,session,_=self.cell('/dev/pts/999',True,False)
        self.assertEqual(status,0);tern.assert_called_once()
        self.assertEqual(tern.call_args.kwargs['terminal'],'/dev/pts/999')
        self.assertEqual(body['browser'],self.FIXTURE['browser']);browser.assert_not_called()

    def test_a_named_ancestor_without_tern_pane_selects_tern_mode(self):
        status,body,tern,_,_,ancestor=self.cell('/dev/pts/999',False,True)
        self.assertEqual(status,0);tern.assert_called_once();ancestor.assert_called_once_with('tern')

    def test_no_terminal_is_browser_mode_required(self):
        status,body,tern,browser,session,_=self.cell(None,True,True)
        self.assertEqual((status,body['error']['code']),(1,'browser_mode_required'))
        for mock in (tern,browser,session): mock.assert_not_called()

    def test_terminal_without_tern_pane_or_named_ancestor_is_browser_mode_required(self):
        status,body,tern,browser,session,ancestor=self.cell('/dev/pts/999',False,False)
        self.assertEqual((status,body['error']['code']),(1,'browser_mode_required'))
        for mock in (tern,browser,session): mock.assert_not_called()
        ancestor.assert_called_once_with('tern')


@unittest.skipUnless(os.name=='posix','Native Windows privacy is not qualified')
class TernModeRealServiceTests(Base):
    """Real owner service through the CLI path; the terminal is a temp file and a watcher thread is the plugin."""
    def setUp(self):
        super().setUp()
        self.config()
        self.terminal=self.directory/'fake-pts';self.terminal.write_bytes(b'')
        patcher=patch.object(idea_tern,'find_terminal',return_value=str(self.terminal));patcher.start();self.addCleanup(patcher.stop)
        self.client=Runtime(self.store,self.runtime);self.addCleanup(self.cleanup)
        self.stop=threading.Event();self.claimed=[];self.seen=set()
        self.watcher=threading.Thread(target=self.watch);self.watcher.start()
        self.addCleanup(self.stop_watcher)

    def stop_watcher(self):
        self.stop.set();self.watcher.join(timeout=5)

    def cleanup(self):
        try: self.client.request_owned_stop(timeout=3)
        except OwnerError as exc:
            if exc.code!='owner_unavailable': raise
        deadline=time.monotonic()+4
        while (self.client.path/'discovery.json').exists() and time.monotonic()<deadline: time.sleep(.02)

    def get(self,port,path):
        conn=http.client.HTTPConnection('127.0.0.1',port,timeout=5)
        try:
            conn.request('GET',path,headers={'Host':'127.0.0.1:%d'%port})
            response=conn.getresponse();return response.status,json.loads(response.read())
        finally: conn.close()

    def watch(self):
        while not self.stop.is_set():
            for port,rid in TITLE.findall(self.terminal.read_bytes()):
                if rid in self.seen: continue
                self.seen.add(rid)
                status,body=self.get(int(port),'/api/v1/tern-claim?rid='+rid.decode())
                if status==200: self.claimed.append(body['url'])
                self.get(int(port),'/api/v1/tern-result?rid=%s&how=above'%rid.decode())
            time.sleep(.02)

    def bindings(self):
        return sorted(p.name for p in (self.client.path/'bindings').glob('binding_*.json'))

    def open(self,*args,ok=True):
        status,body=self.invoke(*args)
        self.assertEqual(body['ok'],ok,body);self.assertEqual(status,0 if ok else 1)
        return body

    def assert_opened(self,body):
        self.assertEqual(body['browser'],dict(mode='tern',url=body['origin'],opened=True,how='above'))
        text=json.dumps(body)
        self.assertNotIn('#pair=',text)
        for key in ('pairing_code','fallback_line','warning'): self.assertNotIn(key,body)
        self.assertNotIn(self.claimed[-1].rsplit('=',1)[1],text)

    def test_new_binding_opens_above_without_a_link(self):
        body=self.open('--browser','tern')
        self.assert_opened(body);self.assertRegex(body['binding_id'],r'^binding_[0-9a-f]{32}$')
        self.assertEqual(self.bindings(),[body['binding_id']+'.json'])

    def test_config_tern_without_a_flag(self):
        self.config(browser_mode='tern')
        self.assert_opened(self.open())

    def test_resume_keeps_the_binding(self):
        first=self.open('--browser','tern')
        resumed=self.open('--browser','tern','--resume',first['binding_id'])
        self.assert_opened(resumed)
        self.assertEqual((resumed['binding_id'],resumed['session_id']),(first['binding_id'],first['session_id']))
        self.assertEqual(self.bindings(),[first['binding_id']+'.json'])
        self.assertEqual(len(self.claimed),2);self.assertNotEqual(*self.claimed)

    def test_capacity_refuses_before_anything_is_written_to_the_pane(self):
        # Seven by link, one by tern: the service holds at most eight live offers for 30 s, so eight tern opens in a row would hit that cap, not this one.
        made=[self.open('--browser','tern')['binding_id']]+[self.open('--browser','link')['binding_id'] for _ in range(7)]
        self.assertEqual(len(set(made)),8)
        before=self.terminal.read_bytes()
        body=self.open('--browser','tern',ok=False)
        self.assertEqual(body['error'],dict(code='binding_capacity',message='binding_capacity'))
        self.assertEqual({row['binding_id'] for row in body['sessions']},set(made))
        self.assertNotIn('browser',body);self.assertNotIn('pairing_code',body)
        self.assertEqual(self.terminal.read_bytes(),before)
        self.assert_opened(self.open('--browser','tern','--resume',made[0]))

    def test_binding_not_found_launches_nothing(self):
        self.open('--browser','tern')
        before,titles=self.bindings(),self.terminal.read_bytes()
        body=self.open('--browser','tern','--resume','binding_'+'0'*32,ok=False)
        self.assertEqual(body['error'],dict(code='binding_not_found',message='binding_not_found'))
        for key in ('browser','pairing_code','fallback_line','origin'): self.assertNotIn(key,body)
        self.assertEqual((self.bindings(),self.terminal.read_bytes()),(before,titles))

    def test_no_terminal_returns_the_live_link(self):
        with patch.object(idea_tern,'find_terminal',return_value=None):
            body=self.open('--browser','tern')
        self.assertEqual(body['warning'],'tern_open_failed')
        self.assertEqual(body['browser'],dict(mode='tern',url=body['origin'],opened=False,failure='no_terminal',
                                              link=body['origin'].rstrip('/')+'/#pair='+body['pairing_code']))
        self.assertEqual(len(self.bindings()),1)


if __name__=='__main__':unittest.main()
