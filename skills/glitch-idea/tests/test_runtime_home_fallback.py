"""The runtime road grid: home default, then the OS runtime dir, then an owner-only folder in the private home (SKILLS-168)."""
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

SCRIPTS=Path(__file__).resolve().parents[1]/'glitch-idea/scripts'
sys.path.insert(0,str(SCRIPTS))
import idea
import idea_runtime


class RuntimeHomeFallbackTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        # Everything sits below one private folder so the ancestors pass the chain's rule.
        self.base=Path(self.temp.name).resolve();os.chmod(self.base,0o700)
        self.package=self.base/'package/glitch-idea';self.package.mkdir(parents=True)
        fake=self.package/'scripts/idea.py';fake.parent.mkdir();fake.write_text('fixture')
        patcher=patch.object(idea,'__file__',str(fake));patcher.start();self.addCleanup(patcher.stop)
        self.write_config()
        self.home=self.base/'home';self.home.mkdir();os.chmod(self.home,0o750)
        self.xdg=self.base/'xdg'
        self.fallback=self.home/'.glitch-idea'
        self.home_default=self.home/'.local/state/glitch-idea'

    def write_config(self,**extra):
        (self.package/'config.json').write_text(json.dumps(dict(store_path=str(self.base/'ideas'),plan_validator_argv=None,
                                                                validator_timeout_seconds=30,**extra)))

    def loose_state(self):
        """The reported seat shape: ~/.local/state is mode 0775, owner and group the seat."""
        state=self.home/'.local/state';state.mkdir(parents=True)
        os.chmod(self.home/'.local',0o755);os.chmod(state,0o775)

    def resolve(self,*argv,xdg=None):
        with patch.object(idea,'_private_home',return_value=self.home),patch.dict(os.environ,{},clear=False):
            os.environ.pop('XDG_RUNTIME_DIR',None)
            if xdg is not None: os.environ['XDG_RUNTIME_DIR']=str(xdg)
            args=idea.parser().parse_args(['session-open',*argv])
            return idea.launcher_configuration(args)[1],args.runtime_root_fallback

    def expected_marker(self):
        return {'from':str(self.home_default),'to':str(self.fallback),'reason':'home_state_not_private'}

    def assert_private_dir(self,path):
        info=os.lstat(path)
        self.assertTrue(os.path.isdir(path) and not os.path.islink(path))
        self.assertEqual(info.st_uid,os.getuid());self.assertEqual(info.st_mode&0o777,0o700)

    # --- the reported shapes first ---

    def test_seat_shape_xdg_folder_exists_but_variable_unset(self):
        self.loose_state()
        self.xdg.mkdir();os.chmod(self.xdg,0o700)  # /run/user/<uid> exists, the pane has no XDG_RUNTIME_DIR
        root,marker=self.resolve()
        self.assertEqual(root,self.fallback);self.assertEqual(marker,self.expected_marker())
        self.assert_private_dir(self.fallback)

    def test_seat_shape_no_xdg_folder_at_all(self):
        self.loose_state()
        root,marker=self.resolve()
        self.assertEqual(root,self.fallback);self.assertEqual(marker,self.expected_marker())
        self.assert_private_dir(self.fallback)

    # --- the grid ---

    def test_private_home_keeps_home_default_and_creates_nothing(self):
        root,marker=self.resolve()
        self.assertEqual(root,self.home_default);self.assertIsNone(marker)
        self.assertFalse(os.path.lexists(self.fallback))

    def test_usable_xdg_still_outranks_the_home_fallback(self):
        self.loose_state();self.xdg.mkdir();os.chmod(self.xdg,0o700)
        root,marker=self.resolve(xdg=self.xdg)
        self.assertEqual(root,self.xdg/'glitch-idea');self.assertEqual(marker['reason'],'home_not_private')
        self.assertFalse(os.path.lexists(self.fallback))

    def test_unusable_xdg_falls_through_to_the_home_fallback(self):
        self.loose_state();self.xdg.mkdir();os.chmod(self.xdg,0o750)
        root,marker=self.resolve(xdg=self.xdg)
        self.assertEqual(root,self.fallback);self.assertEqual(marker,self.expected_marker())

    def test_group_writable_home_gets_no_fallback(self):
        self.loose_state();os.chmod(self.home,0o2770)
        root,marker=self.resolve()
        self.assertEqual(root,self.home_default);self.assertIsNone(marker)
        self.assertFalse(os.path.lexists(self.fallback))

    def test_existing_loose_folder_is_refused_and_never_remoded(self):
        self.loose_state();self.fallback.mkdir();os.chmod(self.fallback,0o755)
        root,marker=self.resolve()
        self.assertEqual(root,self.home_default);self.assertIsNone(marker)
        self.assertEqual(os.lstat(self.fallback).st_mode&0o777,0o755)

    def test_symlink_in_place_of_the_folder_is_refused(self):
        self.loose_state()
        target=self.base/'elsewhere';target.mkdir();os.chmod(target,0o700)
        os.symlink(target,self.fallback)
        root,marker=self.resolve()
        self.assertEqual(root,self.home_default);self.assertIsNone(marker)
        self.assertTrue(os.path.islink(self.fallback))

    def test_dangling_symlink_is_refused_and_nothing_is_created_through_it(self):
        self.loose_state()
        target=self.base/'not-there'
        os.symlink(target,self.fallback)
        root,marker=self.resolve()
        self.assertEqual(root,self.home_default);self.assertIsNone(marker)
        self.assertFalse(os.path.lexists(target))

    def test_file_in_place_of_the_folder_is_refused(self):
        self.loose_state();self.fallback.write_text('not a folder')
        root,marker=self.resolve()
        self.assertEqual(root,self.home_default);self.assertIsNone(marker)

    def test_folder_owned_by_another_account_is_refused(self):
        self.loose_state();self.fallback.mkdir();os.chmod(self.fallback,0o700)
        real_fstat=os.fstat
        fallback_ino=os.lstat(self.fallback).st_ino
        def foreign(fd):
            info=real_fstat(fd)
            if info.st_ino!=fallback_ino: return info
            fields=list(info);fields[4]=info.st_uid+1
            return os.stat_result(fields)
        with patch.object(idea_runtime.os,'fstat',side_effect=foreign):
            root,marker=self.resolve()
        self.assertEqual(root,self.home_default);self.assertIsNone(marker)

    def test_swap_to_symlink_between_check_and_use_is_refused(self):
        """A path that becomes a symlink just before it is opened is refused on the descriptor road."""
        self.loose_state()
        target=self.base/'attacker';target.mkdir();os.chmod(target,0o700)
        real_mkdir=os.mkdir
        def swap(name,mode=0o777,*,dir_fd=None):
            if name=='.glitch-idea':
                os.symlink(target,self.fallback);raise FileExistsError(name)
            return real_mkdir(name,mode,dir_fd=dir_fd)
        with patch.object(idea_runtime.os,'mkdir',side_effect=swap):
            root,marker=self.resolve()
        self.assertEqual(root,self.home_default);self.assertIsNone(marker)

    def test_world_writable_home_gets_no_fallback(self):
        self.loose_state();os.chmod(self.home,0o757)
        root,marker=self.resolve()
        self.assertEqual(root,self.home_default);self.assertIsNone(marker)
        self.assertFalse(os.path.lexists(self.fallback))

    def test_private_home_creates_no_folder_at_all(self):
        self.resolve()
        self.assertEqual(sorted(os.listdir(self.home)),[])

    def test_missing_home_is_never_created(self):
        os.rmdir(self.home)
        root,marker=self.resolve()
        self.assertEqual(root,self.home_default);self.assertIsNone(marker)
        self.assertFalse(os.path.lexists(self.home))

    def test_home_removed_mid_call_is_never_recreated(self):
        """The leaf is created on the home's own descriptor, so a home that vanishes is not rebuilt."""
        self.loose_state()
        real_open_chain=idea_runtime._open_chain
        def vanish(path,**kw):
            descriptor=real_open_chain(path,**kw)
            if Path(path)==self.home:
                for sub in ('.local/state','.local'): os.rmdir(self.home/sub)
                os.rmdir(self.home)
            return descriptor
        with patch.object(idea_runtime,'_open_chain',side_effect=vanish):
            root,marker=self.resolve()
        self.assertEqual(root,self.home_default);self.assertIsNone(marker)
        self.assertFalse(os.path.lexists(self.home))

    def test_swap_after_the_choice_is_refused_by_the_later_runtime_open(self):
        """The boundary from the default choice to the service's own open of that root."""
        self.loose_state()
        root,marker=self.resolve()
        self.assertEqual(root,self.fallback)
        os.rmdir(self.fallback)
        target=self.base/'attacker';target.mkdir();os.chmod(target,0o700)
        os.symlink(target,self.fallback)
        store=self.base/'ideas';store.mkdir();os.chmod(store,0o700)
        runtime=idea_runtime.Runtime(str(store),str(root))
        with self.assertRaises(idea_runtime.RuntimeError) as caught:
            with runtime._directories(create=True): pass
        self.assertEqual(caught.exception.code,'runtime_not_private')
        self.assertEqual(os.listdir(target),[])

    def test_cold_start_twin_second_run_reuses_without_change(self):
        self.loose_state()
        first,marker1=self.resolve()
        before=os.lstat(self.fallback)
        second,marker2=self.resolve()
        after=os.lstat(self.fallback)
        self.assertEqual(first,second);self.assertEqual(marker1,marker2)
        self.assertEqual((before.st_ino,before.st_mode,before.st_mtime_ns),(after.st_ino,after.st_mode,after.st_mtime_ns))

    def test_two_launches_at_once_end_with_one_private_folder(self):
        self.loose_state()
        barrier=threading.Barrier(2);results=[];errors=[]
        real_mkdir=os.mkdir
        def racing(name,mode=0o777,*,dir_fd=None):
            if name=='.glitch-idea':
                try: barrier.wait(timeout=5)
                except threading.BrokenBarrierError: pass
            return real_mkdir(name,mode,dir_fd=dir_fd)
        def run():
            try: results.append(idea._default_runtime_root())
            except Exception as exc: errors.append(exc)
        with patch.object(idea,'_private_home',return_value=self.home),patch.dict(os.environ,{},clear=False), \
             patch.object(idea_runtime.os,'mkdir',side_effect=racing):
            os.environ.pop('XDG_RUNTIME_DIR',None)
            threads=[threading.Thread(target=run) for _ in range(2)]
            for t in threads: t.start()
            for t in threads: t.join(10)
        self.assertEqual(errors,[])
        self.assertEqual([r[0] for r in results],[self.fallback,self.fallback])
        self.assert_private_dir(self.fallback)

    def test_explicit_flag_still_wins(self):
        self.loose_state();explicit=self.base/'explicit'
        root,marker=self.resolve('--runtime-root',str(explicit))
        self.assertEqual(root,explicit);self.assertIsNone(marker)
        self.assertFalse(os.path.lexists(self.fallback))

    def test_configured_runtime_root_still_wins(self):
        self.loose_state();configured=self.base/'configured'
        self.write_config(runtime_root=str(configured))
        root,marker=self.resolve()
        self.assertEqual(root,configured);self.assertIsNone(marker)
        self.assertFalse(os.path.lexists(self.fallback))


if __name__=='__main__':
    unittest.main()
