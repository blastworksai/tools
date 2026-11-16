"""A service this call started itself is waited for past the short bound; every other case keeps the short bound."""
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPTS=Path(__file__).resolve().parents[1]/'glitch-idea/scripts'
sys.path.insert(0,str(SCRIPTS))
import idea_launch as launch
from idea_domain import IdeaError
from idea_runtime import Runtime, RuntimeError as OwnerError

READY={'identity':{'fixture':'verified'},'origin':'http://127.0.0.1:1234/'}


class ColdStartWaitTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.store=Path(self.temp.name)/'ideas'; self.root=Path(self.temp.name)/'private'
        self.now=[0.0]; self.spawns=[]; self.sessions=[]; self.child_state=[None]  # poll() value: None = alive
        self.ready_at=None

    def clock(self):return self.now[0]
    def sleep(self,seconds):self.now[0]+=max(seconds,.01)

    def spawn(self,*args,**kwargs):
        self.spawns.append(args)
        return SimpleNamespace(poll=lambda:self.child_state[0])

    def probe(self,timeout=1):
        if self.ready_at is not None and self.now[0]>=self.ready_at:return READY
        raise OwnerError('owner_unavailable')

    def open_binding(self,*args,**kwargs):
        self.sessions.append(args); return dict(binding_id='binding_'+'0'*32,origin=READY['origin'])

    def run_ensure(self,**kwargs):
        with patch.object(Runtime,'probe_owner',lambda runtime,timeout=1:self.probe(timeout)):
            return launch.ensure_service(self.store,self.root,spawn=self.spawn,clock=self.clock,sleep=self.sleep,**kwargs)

    # 1
    def test_slow_own_spawn_is_waited_for_and_yields_one_service_and_one_session(self):
        self.ready_at=7
        with patch.object(Runtime,'probe_owner',lambda runtime,timeout=1:self.probe(timeout)),patch.object(Runtime,'open_binding',lambda runtime,*a,**k:self.open_binding(*a,**k)):
            result=self._open_session()
        self.assertEqual(len(self.spawns),1)
        self.assertEqual(len(self.sessions),1)
        self.assertGreaterEqual(self.now[0],7)
        self.assertEqual(result['binding_id'],'binding_'+'0'*32)

    def _open_session(self):
        # open_session has no clock parameter: hand the fake time to the ensure_service it calls.
        real=launch.ensure_service
        def timed(*a,**k):return real(*a,clock=self.clock,sleep=self.sleep,**k)
        with patch.object(launch,'ensure_service',timed):
            return launch.open_session(self.store,self.root,spawn=self.spawn)

    def test_slow_own_spawn_through_ensure_service_returns_the_probe(self):
        self.ready_at=7
        self.assertEqual(self.run_ensure(),READY)
        self.assertEqual(len(self.spawns),1)

    # 2
    def test_a_child_that_exits_ends_the_wait_at_the_short_bound(self):
        self.child_state[0]=1  # exited immediately
        with self.assertRaises(launch.LaunchError) as caught:
            self.run_ensure()
        self.assertEqual(caught.exception.code,'service_readiness_timeout')
        self.assertEqual(len(self.spawns),1)
        self.assertGreaterEqual(self.now[0],5); self.assertLess(self.now[0],6)

    def test_a_child_that_dies_during_the_long_wait_ends_it_at_once(self):
        real_sleep=self.sleep
        def sleep(seconds):
            real_sleep(seconds)
            if self.now[0]>=8:self.child_state[0]=1
        self.sleep=sleep
        with self.assertRaises(launch.LaunchError) as caught:
            self.run_ensure()
        self.assertEqual(caught.exception.code,'service_readiness_timeout')
        self.assertGreaterEqual(self.now[0],8); self.assertLess(self.now[0],8.5)

    # 3
    def test_no_spawn_by_this_call_gives_up_at_the_short_bound(self):
        for code in ('busy','runtime_busy','owner_identity_mismatch'):
            with self.subTest(code=code):
                self.now[0]=0
                def refuse(runtime,timeout=1,code=code):raise OwnerError(code)
                with patch.object(Runtime,'probe_owner',refuse):
                    with self.assertRaises(OwnerError) as caught:
                        launch.ensure_service(self.store,self.root,spawn=self.spawn,clock=self.clock,sleep=self.sleep)
                self.assertEqual(caught.exception.code,code)
                self.assertEqual(self.spawns,[])
                self.assertGreaterEqual(self.now[0],5); self.assertLess(self.now[0],6)

    def test_a_held_port_with_no_spawn_gives_up_at_the_short_bound(self):
        import socket
        listener=socket.socket(); self.addCleanup(listener.close)
        listener.bind(('127.0.0.1',0)); listener.listen(1)
        port=listener.getsockname()[1]
        with patch.object(Runtime,'probe_owner',lambda runtime,timeout=1:self.probe(timeout)):
            with self.assertRaises(launch.LaunchError) as caught:
                launch.ensure_service(self.store,self.root,dict(browser_port=port),spawn=self.spawn,clock=self.clock,sleep=self.sleep)
        self.assertEqual(caught.exception.code,'port_in_use')
        self.assertEqual(self.spawns,[])
        self.assertGreaterEqual(self.now[0],5); self.assertLess(self.now[0],6)

    # 4
    def test_child_alive_but_never_ready_times_out_at_the_own_spawn_bound(self):
        with self.assertRaises(launch.LaunchError) as caught:
            self.run_ensure()
        self.assertEqual(caught.exception.code,'service_readiness_timeout')
        self.assertEqual(len(self.spawns),1)
        self.assertGreaterEqual(self.now[0],30); self.assertLess(self.now[0],30.5)
        # a smaller own bound is honoured, and ready just inside it still succeeds
        self.now[0]=0; self.spawns.clear(); self.ready_at=11.9
        self.assertEqual(self.run_ensure(own_spawn_timeout=12),READY)

    def test_own_spawn_bound_is_validated(self):
        for bad in (0,-1,31,float('nan'),float('inf'),'30'):
            with self.subTest(bad=bad):
                with self.assertRaises(IdeaError) as caught:
                    launch.ensure_service(self.store,self.root,spawn=self.spawn,clock=self.clock,sleep=self.sleep,own_spawn_timeout=bad)
                self.assertEqual(caught.exception.code,'invalid_input')
        self.assertEqual(self.spawns,[]); self.assertEqual(self.now[0],0)

    # 5
    def test_a_timed_out_start_leaves_no_session_and_no_extra_process(self):
        with patch.object(Runtime,'probe_owner',lambda runtime,timeout=1:self.probe(timeout)),patch.object(Runtime,'open_binding',lambda runtime,*a,**k:self.open_binding(*a,**k)):
            with self.assertRaises(launch.LaunchError) as caught:
                self._open_session()
        self.assertEqual(caught.exception.code,'service_readiness_timeout')
        self.assertEqual(self.sessions,[])
        self.assertEqual(len(self.spawns),1)
        self.assertFalse((self.root/'sessions').exists())


if __name__=='__main__':
    unittest.main()
