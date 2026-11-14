"""SKILLS-159: one rule for a shared store root, and a named error when a store file may not be read.

The suite runs as one account, so a file its own owner may not read (mode 000) stands in for another
account's private file: the store meets the same permission refusal either way.
"""
import errno
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent / 'glitch-idea/scripts'
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(HERE.parent))
import idea_platform as platform_
import install as installer
from idea_domain import IdeaError

FIXTURE = HERE / 'fixtures/store-v03-preprior'
POSIX = os.name == 'posix' and hasattr(os, 'geteuid') and os.geteuid() != 0
MODES = (0o700, 0o750, 0o770, 0o2700, 0o2710, 0o2720, 0o2730, 0o2740, 0o2750, 0o2760, 0o2770, 0o3770, 0o2771,
         0o2775, 0o2777, 0o2707, 0o2070, 0o2060, 0o2670, 0o6770, 0o4770)


@unittest.skipUnless(POSIX, 'POSIX file modes and a non-root account are required')
class RuleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='shared-rule-')).resolve()
        self.addCleanup(lambda: (os.chmod(self.tmp, 0o700), shutil.rmtree(self.tmp, True)))

    def probe(self, mode):
        folder = self.tmp / 'probe'
        folder.mkdir()
        os.chmod(folder, mode)
        self.addCleanup(lambda: folder.exists() and (os.chmod(folder, 0o700), folder.rmdir()))
        return folder

    def test_half_shared_roots_are_not_shared(self):
        for mode in (0o2720, 0o2730, 0o2710, 0o2740, 0o2750, 0o2760):
            folder = self.probe(mode)
            self.assertFalse(platform_.is_shared_root(folder), oct(mode))
            os.chmod(folder, 0o700)
            folder.rmdir()

    def test_full_group_access_with_setgid_is_shared(self):
        for mode in (0o2770, 0o3770, 0o2771, 0o2775, 0o6770):
            folder = self.probe(mode)
            self.assertTrue(platform_.is_shared_root(folder), oct(mode))
            os.chmod(folder, 0o700)
            folder.rmdir()

    def test_rule_needs_a_directory_and_every_group_bit(self):
        directory = stat.S_IFDIR
        self.assertTrue(platform_.is_shared_mode(directory | 0o2770))
        for missing in (stat.S_IRGRP, stat.S_IWGRP, stat.S_IXGRP, stat.S_ISGID):
            self.assertFalse(platform_.is_shared_mode(directory | (0o2770 & ~missing)), oct(missing))
        self.assertFalse(platform_.is_shared_mode(stat.S_IFREG | 0o2770))
        self.assertFalse(platform_.is_shared_root(self.tmp / 'absent'))
        self.assertFalse(platform_.is_shared_root(None))

    def test_installer_and_runtime_agree_on_every_mode(self):
        skills = self.tmp / 'skills'
        skills.mkdir()
        agreed = {True: 0, False: 0}
        for mode in MODES:
            folder = self.probe(mode)
            try:
                installer._store_gate(folder, skills)
                accepted = True
            except installer.InstallError:
                accepted = False
            self.assertEqual(accepted, platform_.is_shared_root(folder), oct(mode))
            agreed[accepted] += 1
            os.chmod(folder, 0o700)
            folder.rmdir()
        self.assertGreaterEqual(agreed[True], 4)
        self.assertGreaterEqual(agreed[False], 8)


def plain_copy(source, destination):
    """Copy bytes only, into a plain private store.

    shutil.copytree carries the checkout's own metadata along. Measured: a store copied that way gives its new
    lock file mode 0664 whatever the umask, while a bytes-only copy gives 0600. The store under test starts plain.
    """
    for folder, _, files in os.walk(source):
        target = destination / Path(folder).relative_to(source)
        target.mkdir(mode=0o700)
        os.chmod(target, 0o700)
        for name in files:
            shutil.copyfile(Path(folder) / name, target / name)
            os.chmod(target / name, 0o600)


def run_cli(store, *verb, umask=0o022):
    done = subprocess.run([sys.executable, str(SCRIPTS / 'idea.py'), '--store', str(store), *verb],
                          stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120,
                          umask=umask)
    return done.returncode, json.loads(done.stdout[done.stdout.index('{'):]), done.stderr


@unittest.skipUnless(POSIX, 'POSIX file modes and a non-root account are required')
class NamedErrorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='not-shared-')).resolve()
        self.store = self.tmp / 'store'
        plain_copy(FIXTURE, self.store)
        self.restore = []
        self.addCleanup(self.cleanup)
        self.share(0o2770)

    def cleanup(self):
        for path, mode in reversed(self.restore):
            if path.exists() or path.is_symlink():
                os.chmod(path, mode)
        shutil.rmtree(self.tmp, True)

    def share(self, mode):
        os.chmod(self.store, mode)

    def lock_out(self, path, mode=0o000):
        self.restore.append((path, stat.S_IMODE(path.lstat().st_mode)))
        os.chmod(path, mode)

    def let_in(self):
        path, mode = self.restore.pop()
        os.chmod(path, mode)

    def owner(self):
        import pwd
        return pwd.getpwuid(os.geteuid()).pw_name

    def commands(self, group):
        where = str(self.store)
        return ['chgrp -R %s %s' % (group, where),
                'find %s -type d -exec chmod 2770 {} +' % where,
                'find %s -type f -perm /200 -exec chmod 660 {} +' % where,
                'find %s -type f ! -perm /200 -exec chmod 440 {} +' % where]

    def group(self):
        import grp
        return grp.getgrgid(self.store.stat().st_gid).gr_name

    def assert_named(self, result, path):
        status, value, _ = result
        self.assertEqual(status, 1)
        self.assertIs(value['ok'], False)
        self.assertEqual(value['error']['code'], 'store_not_shared', value)
        self.assertEqual(value['path'], str(path))
        self.assertEqual(value['store'], str(self.store))
        return value['error']['message']

    def test_healthy_shared_store_lists(self):
        status, value, _ = run_cli(self.store, 'list')
        self.assertEqual(status, 0, value)
        self.assertTrue(value['ideas'])

    def test_unreadable_idea_file_is_named_with_owner_and_fix(self):
        victim = next(self.store.glob('idea_*.md'))
        self.lock_out(victim)
        message = self.assert_named(run_cli(self.store, 'list'), victim)
        fix = self.commands(self.group())
        self.assertEqual(message, '\n'.join(['This account was refused permission on %s in a shared store. Its owner (%s) must convert the store:'
                                             % (victim, self.owner()), *('  ' + line for line in fix)]))
        self.assertEqual(run_cli(self.store, 'list')[1]['fix'], fix)
        # A blanket recursive group-write would unseal the store's read-only evidence files: never offered.
        self.assertNotIn('g+rwX', message)
        self.assertNotIn('chmod -R', message)

    def test_unreadable_lock_is_named(self):
        run_cli(self.store, 'list')
        lock = self.store / '.lock'
        self.assertTrue(lock.is_file())
        self.lock_out(lock)
        message = self.assert_named(run_cli(self.store, 'list'), lock)
        self.assertIn(str(lock), message)
        self.assertIn('find %s -type f ! -perm /200 -exec chmod 440 {} +' % self.store, message)

    def test_unusable_top_folder_is_named_with_its_mode(self):
        for mode in (0o000, 0o2000, 0o2070):
            self.lock_out(self.store, mode)
            status, value, _ = run_cli(self.store, 'list')
            self.assertEqual((status, value['error']['code']), (1, 'store_not_shared'), (oct(mode), value))
            self.assertEqual(value['store'], str(self.store))
            fix = self.commands('<shared group>')
            self.assertEqual(value['fix'], fix)
            self.assertEqual(value['error']['message'], '\n'.join([
                'This account cannot use the store %s: its top folder is not shared with it (mode %04o, owner %s). '
                'To share it, its owner runs:' % (self.store, mode, self.owner()), *('  ' + line for line in fix)]))
            self.let_in()

    def test_a_symlinked_store_root_is_refused_by_the_store_itself(self):
        # The store never runs on a symlinked root, so the named error cannot be reached that way from the
        # command line; the helper's own symlink handling is tested directly below.
        link = self.tmp / 'link-to-store'
        os.symlink(self.store, link)
        status, value, _ = run_cli(link, 'list')
        self.assertEqual((status, value['error']['code']), (1, 'corrupt_store'), value)

    def test_a_write_refusal_is_named_without_calling_it_a_read(self):
        folder = self.store / 'history'
        refusal = PermissionError(errno.EACCES, 'Permission denied', str(folder / 'new-file.md'))
        error = platform_.not_shared_error(refusal, self.store)
        self.assertIn('was refused permission on %s in a shared store' % (folder / 'new-file.md'), str(error))
        self.assertNotIn('cannot read', str(error))

    def test_file_in_a_private_store_gets_the_top_folder_message(self):
        self.share(0o700)
        victim = next(self.store.glob('idea_*.md'))
        self.lock_out(victim)
        message = self.assert_named(run_cli(self.store, 'list'), victim)
        self.assertIn('its top folder is not shared with it (mode 0700', message)
        self.assertNotIn('in a shared store', message)

    def test_sweep_no_unreadable_store_file_ever_answers_a_raw_errno(self):
        run_cli(self.store, 'list')
        entries = sorted(p for p in self.store.rglob('*') if not p.is_symlink())
        self.assertGreaterEqual(len(entries), 12)
        named = 0
        for entry in entries:
            self.lock_out(entry)
            for verb in (('list',),):
                status, value, _ = run_cli(self.store, *verb)
                if value['ok']:
                    continue
                self.assertEqual(value['error']['code'], 'store_not_shared', (str(entry), value))
                self.assertNotIn('Errno', value['error']['message'], str(entry))
                self.assertTrue(value['path'] == str(entry) or str(entry) in [str(p) for p in Path(value['path']).parents],
                                (str(entry), value))
                named += 1
            self.let_in()
        self.assertGreaterEqual(named, 3)
        status, value, _ = run_cli(self.store, 'list')
        self.assertEqual(status, 0, value)

    def test_owner_of_a_half_shared_store_keeps_working_as_private(self):
        for mode in (0o2720, 0o2730):
            self.share(mode)
            (self.store / '.lock').unlink(missing_ok=True)
            self.assertFalse(platform_.is_shared_root(self.store))
            status, value, _ = run_cli(self.store, 'list', umask=0o077)
            self.assertEqual(status, 0, (oct(mode), value))
            # Private: the lock keeps what the account's own umask gives it; nothing opens it to the group.
            self.assertEqual(stat.S_IMODE((self.store / '.lock').stat().st_mode), 0o600, oct(mode))
        self.share(0o2770)
        (self.store / '.lock').unlink(missing_ok=True)
        status, value, _ = run_cli(self.store, 'list', umask=0o077)
        self.assertEqual(status, 0, value)
        self.assertEqual(stat.S_IMODE((self.store / '.lock').stat().st_mode), 0o660)


@unittest.skipUnless(POSIX, 'POSIX file modes and a non-root account are required')
class HelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='not-shared-helper-')).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.store = self.tmp / 'store'
        self.store.mkdir()
        os.chmod(self.store, 0o2770)
        (self.store / 'idea.md').write_text('x')

    def refusal(self, path, code=errno.EACCES):
        return PermissionError(code, 'Permission denied', str(path))

    def test_only_a_permission_refusal_inside_the_store_is_named(self):
        inside = self.store / 'idea.md'
        error = platform_.not_shared_error(self.refusal(inside), self.store)
        self.assertIsInstance(error, IdeaError)
        self.assertEqual(error.code, 'store_not_shared')
        self.assertEqual({k: error.details[k] for k in ('path', 'store')}, dict(path=str(inside), store=str(self.store)))
        self.assertEqual(len(error.details['fix']), 4)
        self.assertEqual(platform_.not_shared_error(self.refusal(inside, errno.EPERM), self.store).code, 'store_not_shared')
        for other in (self.refusal(self.tmp / 'elsewhere.md'), self.refusal(str(self.store) + '-sibling/idea.md'),
                      FileNotFoundError(errno.ENOENT, 'gone', str(inside)), OSError(errno.EIO, 'io', str(inside)),
                      PermissionError(errno.EACCES, 'no path'), ValueError('x'), None):
            self.assertIsNone(platform_.not_shared_error(other, self.store), repr(other))
        self.assertIsNone(platform_.not_shared_error(self.refusal(inside), None))

    def test_conversion_keeps_sealed_files_read_only_and_quotes_the_path(self):
        odd = self.tmp / "a store's folder"
        commands = platform_.conversion_commands(odd, 'team')
        self.assertEqual(commands[0], """chgrp -R team 'a store'"'"'s folder'""".replace("'a store", "'" + str(self.tmp) + "/a store", 1))
        self.assertTrue(all('-R g+' not in line and 'g+rwX' not in line for line in commands))
        self.assertIn('! -perm /200 -exec chmod 440', commands[3])
        self.assertIn('-perm /200 -exec chmod 660', commands[2])
        self.assertIn('-type d -exec chmod 2770', commands[1])
        sealed = self.store / 'sealed.bin'
        sealed.write_text('evidence')
        os.chmod(sealed, 0o400)
        os.chmod(self.store / 'idea.md', 0o600)
        import grp
        mine = grp.getgrgid(os.getgid()).gr_name
        for line in platform_.conversion_commands(self.store, mine):
            subprocess.run(line, shell=True, check=True, stdin=subprocess.DEVNULL)
        self.assertEqual(stat.S_IMODE(sealed.stat().st_mode), 0o440)
        self.assertEqual(stat.S_IMODE((self.store / 'idea.md').stat().st_mode), 0o660)
        self.assertEqual(stat.S_IMODE(self.store.stat().st_mode), 0o2770)

    def test_a_fault_inside_the_helper_returns_none_and_never_raises(self):
        from unittest.mock import patch

        def broken(*_):
            raise RuntimeError('lookup failed')
        with patch.object(platform_, '_owner_name', broken):
            self.assertIsNone(platform_.not_shared_error(self.refusal(self.store / 'idea.md'), self.store))
        with patch.object(platform_, 'conversion_commands', broken):
            self.assertIsNone(platform_.not_shared_error(self.refusal(self.store / 'idea.md'), self.store))

    def test_a_link_inside_the_store_that_points_outside_is_not_named(self):
        outside = self.tmp / 'outside.md'
        outside.write_text('x')
        os.symlink(outside, self.store / 'link.md')
        self.assertIsNone(platform_.not_shared_error(self.refusal(self.store / 'link.md'), self.store))
        os.symlink(self.tmp, self.store / 'dir-link')
        self.assertIsNone(platform_.not_shared_error(self.refusal(self.store / 'dir-link' / 'outside.md'), self.store))
        through = self.tmp / 'through'
        os.symlink(self.store, through)
        error = platform_.not_shared_error(self.refusal(through / 'idea.md'), self.store)
        self.assertEqual(error.details['path'], str(through / 'idea.md'))
        error = platform_.not_shared_error(self.refusal(self.store / 'idea.md'), through)
        self.assertEqual(error.code, 'store_not_shared')

    def test_group_name_is_quoted_and_cannot_run_anything(self):
        marker = self.tmp / 'ran'
        hostile = 'Domain Users; touch %s; $(touch %s)' % (marker, marker)
        commands = platform_.conversion_commands(self.store, hostile)
        self.assertTrue(commands[0].startswith("chgrp -R 'Domain Users; touch "), commands[0])
        subprocess.run(commands[0], shell=True, stdin=subprocess.DEVNULL, capture_output=True)
        self.assertFalse(marker.exists())
        self.assertEqual(platform_.conversion_commands(self.store, 'agents')[0], 'chgrp -R agents %s' % self.store)
        self.assertIn('chgrp -R <shared group> ', platform_.conversion_commands(self.store, platform_.SHARED_GROUP_PLACEHOLDER)[0])

    def test_bytes_filename_and_missing_owner_never_raise(self):
        as_bytes = PermissionError(errno.EACCES, 'Permission denied', os.fsencode(str(self.store / 'idea.md')))
        error = platform_.not_shared_error(as_bytes, self.store)
        self.assertEqual(error.code, 'store_not_shared')
        gone = self.store / 'deep' / 'gone.md'
        error = platform_.not_shared_error(self.refusal(gone), self.store)
        self.assertEqual(error.details['path'], str(gone))
        self.assertIn('Its owner (', str(error))

    def test_refusal_outside_the_store_keeps_its_plain_error_at_the_command_line(self):
        absent = self.tmp / 'no-such-parent' / 'store'
        status, value, _ = run_cli(absent, 'list')
        self.assertNotEqual(value.get('error', {}).get('code'), 'store_not_shared', value)


if __name__ == '__main__':
    unittest.main()
