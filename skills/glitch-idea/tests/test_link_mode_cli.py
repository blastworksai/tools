"""browser-open link mode through the real CLI path: mode resolution cells and the status x operation grid."""
import io
import json
import os
from pathlib import Path
import re
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
from idea_runtime import Runtime,RuntimeError as OwnerError

BINDING='binding_'+'a'*32
CODE_PATHS={('pairing_code',),('fallback_line',),('browser','link')}


class Output:
    def __init__(self): self.buffer=io.BytesIO()


def walk(value,path=()):
    """Every (path, string) leaf of a JSON value."""
    if isinstance(value,dict):
        for key,item in value.items(): yield from walk(item,path+(key,))
    elif isinstance(value,list):
        for number,item in enumerate(value): yield from walk(item,path+(number,))
    elif isinstance(value,str): yield path,value


class LinkModeCliSeamTests(unittest.TestCase):
    """In-process (open_browser_session mocked): which mode the launcher resolves and what it refuses."""
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

    def test_cell1_config_link_without_flag_opens_link_mode_and_returns_the_link(self):
        self.config(browser_mode='link')
        fixture=dict(binding_id=BINDING,pairing_code='CODE-1',browser=dict(mode='link',url='http://127.0.0.1:1/',
                     link='http://127.0.0.1:1/#pair=CODE-1'),fallback_line='type CODE-1')
        with patch.object(launch,'open_browser_session',return_value=fixture) as opened:
            status,body=self.invoke()
        self.assertEqual(status,0);opened.assert_called_once()
        self.assertEqual(opened.call_args.kwargs['mode'],'link');self.assertIsNone(opened.call_args.kwargs['orcabinding'])
        self.assertEqual(body['browser']['link'],'http://127.0.0.1:1/#pair=CODE-1')

    def test_cell2_no_flag_and_no_config_mode_is_required_and_nothing_launches(self):
        self.config()
        with patch.object(launch,'open_browser_session') as browser,patch.object(launch,'open_session') as session:
            status,body=self.invoke()
        self.assertEqual((status,body['error']['code']),(1,'browser_mode_required'))
        browser.assert_not_called();session.assert_not_called()

    def test_cell3_link_refuses_orca_selectors_and_reconnect_with_usage(self):
        self.config()
        for extra in (['--orca-worktree','X'],['--orca-terminal','X'],['--orca-host','X'],['--reconnect',BINDING]):
            with self.subTest(extra=extra),patch.object(launch,'open_browser_session') as browser,\
                    patch.object(launch,'reconnect_browser_session') as reconnect:
                status,body=self.invoke('--browser','link',*extra)
            self.assertEqual((status,body['error']['code']),(1,'usage'))
            browser.assert_not_called();reconnect.assert_not_called()

    def test_cell3b_config_link_without_flag_also_refuses_orca_options(self):
        self.config(browser_mode='link')
        with patch.object(launch,'open_browser_session') as browser:
            status,body=self.invoke('--orca-worktree','X')
        self.assertEqual((status,body['error']['code']),(1,'usage'));browser.assert_not_called()

    def test_cell4_explicit_system_flag_beats_config_link(self):
        self.config(browser_mode='link')
        with patch.object(launch,'open_browser_session',return_value={'browser':{'mode':'system'}}) as browser:
            status,_=self.invoke('--browser','system')
        self.assertEqual(status,0);self.assertEqual(browser.call_args.kwargs['mode'],'system')

    def test_cell5_invalid_configured_mode_is_invalid_config_not_launcher_failed(self):
        for bad in ('orca','bogus',''):
            self.config(browser_mode=bad)
            with self.subTest(mode=bad),patch.object(launch,'open_browser_session') as browser:
                status,body=self.invoke()
            self.assertEqual((status,body['error']['code']),(1,'invalid_config'));browser.assert_not_called()

    def test_cell5b_invalid_configured_mode_is_refused_even_with_an_explicit_flag(self):
        # launcher_configuration validates the whole config through _fixed_ports, so a bad browser_mode is never silently bypassed.
        self.config(browser_mode='orca')
        with patch.object(launch,'open_browser_session') as browser:
            status,body=self.invoke('--browser','system')
        self.assertEqual((status,body['error']['code']),(1,'invalid_config'));browser.assert_not_called()


@unittest.skipUnless(os.name=='posix','Native Windows privacy is not qualified')
class LinkModeRealServiceTests(unittest.TestCase):
    """Real subprocess CLI against a real owner service; open_browser_session is NOT mocked."""
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.directory=Path(self.temp.name)
        self.package=self.directory/'source/glitch-idea'
        shutil.copytree(SCRIPTS.parent,self.package,ignore=shutil.ignore_patterns('__pycache__'))
        self.script=self.package/'scripts/idea.py'
        self.store=self.directory/'ideas';self.root=self.directory/'private runtime'
        self.client=Runtime(self.store,self.root);self.addCleanup(self.cleanup)
        self.write_config(browser_mode='link')

    def write_config(self,**extra):
        (self.package/'config.json').write_text(json.dumps(dict(store_path=str(self.store),plan_validator_argv=None,
                                                               validator_timeout_seconds=30,**extra)))

    def cleanup(self):
        try: self.client.request_owned_stop(timeout=3)
        except OwnerError as exc:
            if exc.code!='owner_unavailable': raise
        deadline=time.monotonic()+4
        while (self.client.path/'discovery.json').exists() and time.monotonic()<deadline: time.sleep(.02)

    def cli(self,*args,ok=True):
        result=subprocess.run([sys.executable,str(self.script),'--store',str(self.store),*map(str,args)],
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)
        self.assertEqual(result.stderr,b'','only one JSON result')
        body=json.loads(result.stdout)
        self.assertEqual(body['ok'],ok,body);self.assertEqual(result.returncode,0 if ok else 1)
        return body

    def link(self,*extra,ok=True):
        return self.cli('browser-open','--runtime-root',self.root,*extra,ok=ok)

    def bindings(self):
        return sorted(p.name for p in (self.client.path/'bindings').glob('binding_*.json'))

    def assert_link_shape(self,body):
        code=body['pairing_code']
        self.assertEqual(body['browser']['mode'],'link')
        self.assertEqual(body['browser']['link'],body['origin'].rstrip('/')+'/#pair='+code)
        self.assertEqual(body['browser']['url'],body['origin'])
        self.assertIn(code,body['fallback_line'])
        self.assertNotIn('browser_page_id',body['browser'])

    def test_cell1_real_config_link_without_flag_returns_a_paired_link(self):
        body=self.link()
        self.assert_link_shape(body)
        # The link's code really pairs: the service accepts it once.
        import http.client
        port=int(body['origin'].split(':')[-1].rstrip('/'))
        conn=http.client.HTTPConnection('127.0.0.1',port,timeout=5)
        try:
            conn.request('POST','/api/v1/pair',json.dumps({'code':body['pairing_code']}),
                         {'Content-Type':'application/json','Origin':body['origin'].rstrip('/'),'X-Idea-Binding':body['binding_id']})
            self.assertEqual(conn.getresponse().status,200)
        finally: conn.close()

    def test_cell6_code_appears_only_in_the_three_named_fields(self):
        body=self.link();code=body['pairing_code']
        found={path for path,text in walk(body) if code in text}
        self.assertEqual(found,CODE_PATHS)
        # and nowhere else in the serialised result (keys included)
        self.assertEqual(json.dumps(body).count(code),3)

    def test_cell6b_explicit_system_flag_with_config_link_is_not_link_mode(self):
        # system would try to launch a real browser; prove precedence in-process instead (cell 4). Here: link flag works without config.
        self.write_config()
        body=self.link('--browser','link');self.assert_link_shape(body)

    def test_cell7_new_binding_returns_link(self):
        before=self.bindings()
        body=self.link();self.assert_link_shape(body)
        self.assertRegex(body['binding_id'],r'^binding_[0-9a-f]{32}$')
        self.assertEqual(len(self.bindings()),len(before)+1)

    def test_cell8_resumed_binding_returns_a_new_link_with_a_different_code(self):
        first=self.link()
        resumed=self.link('--resume',first['binding_id'])
        self.assert_link_shape(resumed)
        self.assertEqual(resumed['binding_id'],first['binding_id']);self.assertEqual(resumed['session_id'],first['session_id'])
        self.assertNotEqual(resumed['pairing_code'],first['pairing_code'])
        self.assertNotEqual(resumed['browser']['link'],first['browser']['link'])
        self.assertEqual(self.bindings(),[first['binding_id']+'.json'])
        self.assertEqual({p for p,t in walk(resumed) if first['pairing_code'] in t},set())

    def test_cell9_binding_at_capacity_keeps_code_and_sessions_list(self):
        made=[self.link()['binding_id'] for _ in range(8)]
        self.assertEqual(len(set(made)),8)
        body=self.link(ok=False)
        self.assertEqual(body['error'],dict(code='binding_capacity',message='binding_capacity'))
        self.assertEqual(set(body),{'ok','error','sessions'})
        self.assertEqual({row['binding_id'] for row in body['sessions']},set(made))
        self.assertTrue(all(set(row)=={'binding_id','selected_idea_id','title','finished','in_use'} for row in body['sessions']))
        self.assertNotIn('browser',body);self.assertNotIn('pairing_code',body);self.assertNotIn('#pair=',json.dumps(body))
        self.assertEqual(len(self.bindings()),8)
        # resuming an existing binding at capacity still works and returns a link
        self.assert_link_shape(self.link('--resume',made[0]))

    def test_cell10_resume_unknown_binding_is_binding_not_found_and_launches_nothing(self):
        self.link()
        before=self.bindings()
        body=self.link('--resume','binding_'+'0'*32,ok=False)
        self.assertEqual(body['error'],dict(code='binding_not_found',message='binding_not_found'))
        for key in ('browser','pairing_code','fallback_line','origin'): self.assertNotIn(key,body)
        self.assertNotIn('#pair=',json.dumps(body))
        self.assertEqual(self.bindings(),before)


if __name__=='__main__':unittest.main()
