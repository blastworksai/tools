#!/usr/bin/env python3
"""Updater pure-module suite and end-to-end self-update in owned disposable Tern/Xvfb.

Run only under a descendant-owning supervisor, for example:
  systemd-run --user --scope --collect --property=KillMode=control-group \
    --property=RuntimeMaxSec=900s python3 updater_smoke.py --evidence /tmp/updater-e2e.json
"""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT/'tests'
FIXTURE = TESTS/'fixture'
TERN = shutil.which('tern')
MODULES = ['version', 'manifest', 'source', 'requires', 'confirm', 'state', 'cli', 'window']
FIXTURE_ID = 'updater-fixture'
PROXY_VARS = ['http_proxy', 'https_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'all_proxy']
REAL_PLUGINS = Path.home()/'.config/tern/plugins'
REAL_LOGS = Path.home()/'.local/state/tern/logs'
TICK_WAIT = 75
# An idle headless Tern window services plugin timers, process callbacks and log
# writes late (tens of seconds). Every wait pokes each live window with a read-only
# `ctl state` about once a second, as a real window's own input and frames would.
WAKERS = []


def wake():
    for waker in list(WAKERS):
        waker()


def wait_for(check, description, seconds=10, interval=.2):
    deadline = time.monotonic()+seconds
    poked = 0.0
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        if time.monotonic()-poked >= 1:
            wake()
            poked = time.monotonic()
        time.sleep(interval)
    raise AssertionError('timeout: '+description)


def idle(seconds):
    """Let time pass while keeping live windows awake."""
    deadline = time.monotonic()+seconds
    while time.monotonic() < deadline:
        wake()
        time.sleep(min(1, max(0, deadline-time.monotonic())))


def inside(path, parent):
    try:
        Path(path).resolve().relative_to(Path(parent).resolve())
        return True
    except ValueError:
        return False


def tree_hash(path):
    digest = hashlib.sha256()
    for item in sorted(Path(path).rglob('*')):
        digest.update(str(item.relative_to(path)).encode())
        if item.is_file():
            digest.update(item.read_bytes())
    return digest.hexdigest()


def rewrite_base(source_file, key, value):
    text = source_file.read_text()
    pattern = re.compile(r'^Source\.'+key+r' = "[^"\n]*"$', re.M)
    text, count = pattern.subn('Source.'+key+' = '+json.dumps(value), text)
    assert count == 1, (source_file, key, count)
    source_file.write_text(text)


def set_manifest(manifest, **values):
    text = manifest.read_text()
    for key, value in values.items():
        text, count = re.subn(r'^'+key+r' = "[^"\n]*"$', key+' = '+json.dumps(value), text, count=1, flags=re.M)
        assert count == 1, (manifest, key)
    manifest.write_text(text)


def manifest_value(manifest, key):
    for line in manifest.read_text().splitlines():
        if line.lstrip().startswith('['):
            break
        match = re.match(r'^\s*'+key+r'\s*=\s*"([^"]*)"', line)
        if match:
            return match.group(1)
    return None


def vendor(package, with_tests):
    target = package/'updater'
    target.mkdir(parents=True, exist_ok=True)
    for name in MODULES:
        shutil.copy2(ROOT/(name+'.luau'), target/(name+'.luau'))
    if with_tests:
        (target/'tests').mkdir(exist_ok=True)
        for test in TESTS.glob('*.luau'):
            shutil.copy2(test, target/'tests'/test.name)


class Sweep:
    """Socket-free invariants over the user's real Tern."""

    def __init__(self, scratch):
        self.scratch = str(scratch)
        self.plugins = self.listing()
        self.daemons = self.daemon_identity()
        self.logs = {p: p.stat().st_size for p in REAL_LOGS.glob('tern-daemon*.log')} if REAL_LOGS.exists() else {}

    @staticmethod
    def listing():
        if not REAL_PLUGINS.exists():
            return None
        out = {}
        for item in sorted(REAL_PLUGINS.rglob('*')):
            if '.git' in item.relative_to(REAL_PLUGINS).parts:
                continue
            info = item.lstat()
            out[str(item.relative_to(REAL_PLUGINS))] = [info.st_mtime_ns, info.st_size]
        return out

    @staticmethod
    def daemon_identity():
        found = subprocess.run(['pgrep', '-f', 'daemon --socket /run/user/'], capture_output=True, text=True).stdout.split()
        out = {}
        for pid in found:
            try:
                stat = Path('/proc/'+pid+'/stat').read_text()
            except OSError:
                continue
            fields = stat.rsplit(')', 1)[1].split()
            out[pid] = fields[19]  # field 22: start time in clock ticks
        return out

    def check(self, step):
        assert self.listing() == self.plugins, 'real plugins folder changed during '+step
        assert self.daemon_identity() == self.daemons, 'real daemon identity changed during '+step
        for path, size in self.logs.items():
            with path.open('rb') as stream:
                stream.seek(size)
                new = stream.read().decode(errors='replace')
            # The user's live daemon keeps logging its own work; none of it may be ours.
            for marker in (self.scratch, FIXTURE_ID):
                assert marker not in new, 'real daemon log mentions '+marker+' during '+step


class Server:
    def __init__(self, root):
        self.root = root
        self.requests = []
        owner = self

        class Handler(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *a, **k):
                super().__init__(*a, directory=str(owner.root), **k)

            def log_request(self, code='-', size='-'):
                owner.requests.append('%s %s' % (code, self.path))

            def log_message(self, fmt, *a):
                pass

        self.httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


class Tern:
    """One isolated config + daemon + headless window; kills only what it started."""

    def __init__(self, base, name, evidence, processes):
        self.base = base
        self.root = base/name
        self.config = self.root/'config'
        self.config.mkdir(parents=True, mode=0o700)
        self.logs = self.root/'logs'
        self.logs.mkdir()
        self.sock = self.root/'daemon.sock'
        self.control = self.root/'window.sock'
        self.evidence = evidence
        self.processes = processes
        self.own = []
        env = {k: v for k, v in os.environ.items() if k not in PROXY_VARS and not k.startswith('TERN_') and not k.startswith('STENCIL_')}
        env.update(TERN_CONFIG_DIR=str(self.config), TERN_DAEMON_SOCKET=str(self.sock), STENCIL_LOG_DIR=str(self.logs),
                   STENCIL_LOG='warn,stencil=info,tern::plugin=debug', STENCIL_GPU='cpu', no_proxy='127.0.0.1', NO_PROXY='127.0.0.1')
        self.env = env
        self.plugins_dir = Path(json.loads(self.command('plugin', 'dir', '--json'))['dir'])
        if not inside(self.plugins_dir, self.config):
            raise AssertionError('refusing: tern plugin dir is outside the scratch config: '+str(self.plugins_dir))
        if self.sock.exists():
            raise AssertionError('refusing: stale daemon socket '+str(self.sock))
        self.log = open(self.root/'process.log', 'w+')

    def command(self, *parts, check=True, timeout=30):
        result = subprocess.run([TERN, *map(str, parts)], env=self.env, capture_output=True, text=True, timeout=timeout)
        if check and result.returncode:
            raise AssertionError('tern '+' '.join(map(str, parts))+': '+result.stderr+result.stdout)
        return result.stdout

    def spawn(self, argv, cwd=None):
        process = subprocess.Popen(argv, env=self.env, cwd=cwd, stdout=self.log, stderr=self.log, start_new_session=True)
        entry = {'process': process, 'pgid': os.getpgid(process.pid), 'argv': argv[:3]}
        self.processes.append(entry)
        self.own.append(entry)
        return process

    def start(self):
        self.spawn([TERN, 'daemon', '--socket', str(self.sock)])
        wait_for(self.sock.exists, 'private daemon socket', 20)
        self.spawn(['xvfb-run', '-a', TERN, '--control', str(self.control)], cwd=self.root)
        wait_for(self.control.exists, 'private window control socket', 40)
        self.command('ctl', '--control', self.control, 'state', timeout=45)
        WAKERS.append(self.poke)

    def poke(self):
        try:
            subprocess.run([TERN, 'ctl', '--control', str(self.control), 'state'], env=self.env, capture_output=True, timeout=10)
        except subprocess.TimeoutExpired:
            pass

    def ctl(self, *parts):
        result = json.loads(self.command('ctl', '--control', self.control, *parts))
        if result.get('ok') is False:
            raise AssertionError(result)
        return result

    def run(self, action):
        return self.ctl('plugins', 'run', action)

    def window_log(self):
        path = self.logs/'tern.log'
        return path.read_text(errors='replace') if path.exists() else ''

    def notices(self, since=0):
        out = []
        for line in self.window_log()[since:].splitlines():
            if 'updater notice' in line:
                # tern.log joins arguments with tabs; Tern appends ` plugin="<id>"`.
                body = re.sub(r' plugin="[^"]*"$', '', line.split('updater notice', 1)[1])
                out.append([p.strip() for p in body.split('\t')[1:]])
        return out

    def log_offset(self):
        return len(self.window_log())

    def plugins_dir_lines(self, since=0):
        return re.findall(r'updater plugins dir\t(\S+)', self.window_log()[since:])

    def kv(self, plugin_id):
        path = self.config/'plugin-data'/plugin_id/'kv.json'
        try:
            return json.loads(path.read_text()).get('updater.v1')
        except (FileNotFoundError, json.JSONDecodeError):
            return None

    def version(self, plugin_id):
        for plugin in json.loads(self.command('plugin', 'list', '--json'))['plugins']:
            if plugin['id'] == plugin_id:
                return plugin['version']
        return None

    def palette_rows(self, query):
        """Rows the command palette shows for `query`: only available commands appear."""
        self.ctl('palette', query)
        try:
            found = []

            def walk(node, row):
                if isinstance(node, list):
                    for child in node:
                        walk(child, row)
                    return
                if not isinstance(node, dict):
                    return
                if node.get('role') == 'option':
                    row = []
                    found.append(row)
                if row is not None and node.get('text'):
                    row.append(node['text'])
                for child in node.get('children', []):
                    walk(child, row)

            wait_for(lambda: (found.clear(), walk(self.ctl('tree').get('tree'), None), found)[2], 'palette rows for '+query, 5)
            return [' '.join(row) for row in found]
        finally:
            self.ctl('key', 'Escape')
            wait_for(lambda: not self.ctl('state').get('palette'), 'palette closed', 5)

    def shows(self, label, query=None):
        """Whether the palette lists a row with exactly `label`'s words (its match mark splits the text)."""
        rows = self.palette_rows(query or label)
        self.evidence.setdefault('palette_rows', []).append({'query': query or label, 'rows': rows})
        return any(sorted(row.split()) == sorted(label.split()) for row in rows)

    def picker(self):
        return self.ctl('state').get('picker')

    def assert_scratch_plugins_dir(self):
        lines = self.plugins_dir_lines()
        assert lines, 'no updater plugins dir line logged yet; refusing picker enter'
        for line in lines:
            if not inside(line, self.config):
                raise AssertionError('refusing picker enter: updater plugins dir outside scratch config: '+line)

    def stop(self):
        if self.poke in WAKERS:
            WAKERS.remove(self.poke)
        if self.control.exists():
            try:
                subprocess.run([TERN, 'ctl', '--control', str(self.control), 'quit'], env=self.env, capture_output=True, timeout=5)
            except subprocess.TimeoutExpired:
                pass
        for entry in reversed(self.own):
            stop_entry(entry)
        self.log.close()


def stop_entry(entry):
    process, pgid = entry['process'], entry['pgid']
    for sig in (signal.SIGTERM, signal.SIGKILL):
        if process.poll() is not None:
            break
        try:
            os.killpg(pgid, sig)
        except ProcessLookupError:
            break
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
    # Reap the group's leftovers (Xvfb, daemon children) by the recorded pgid only.
    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def build_fixture(dst, version, raw_base=None, install_base=None, suite=False):
    shutil.copytree(FIXTURE, dst)
    vendor(dst, suite)
    set_manifest(dst/'plugin.toml', version=version)
    if raw_base is not None:
        rewrite_base(dst/'updater/source.luau', 'RAW_BASE', raw_base)
    if install_base is not None:
        rewrite_base(dst/'updater/source.luau', 'INSTALL_BASE', install_base)
    if suite:
        with (dst/'host.luau').open('a') as stream:
            stream.write('\nlocal suite = require("./updater/tests/native_suite")\n'
                         'pcall(tern.fs.mkdir, tern.plugin.data)\n'
                         'tern.fs.write(tern.plugin.data .. "/library-tests.json", tern.json.encode(suite))\n')
    return dst


def suite_only(base, evidence, processes, sweep):
    package = build_fixture(base/'pkg-suite', '0.1.0', suite=True)
    tern = Tern(base, 'suite', evidence, processes)
    try:
        tern.spawn([TERN, 'daemon', '--socket', str(tern.sock)])
        wait_for(tern.sock.exists, 'private daemon socket', 20)
        tern.command('plugin', 'link', package)
        listed = json.loads(tern.command('plugin', 'list', '--json'))
        mine = [p for p in listed['plugins'] if p['id'] == FIXTURE_ID]
        assert mine and mine[0]['status'] == 'ready' and not listed['problems'], listed
        evidence['checks'].append('fixture host plugin loads ready in a real Tern')
        location = tern.config/'plugin-data'/FIXTURE_ID/'library-tests.json'
        wait_for(location.exists, 'library-tests.json', 10)
        library = json.loads(location.read_text())
        evidence['luau_tests_passed'] = library['passed']
        evidence['luau_failures'] = library['failures']
        # tern.json.encode writes an empty Lua table as {}; an empty list either way means none failed.
        assert library['failures'] in ([], {}) and library['passed'] > 0, library
        evidence['luau_failures'] = []
        evidence['checks'].append('pure-module suite: %d passed, failures == []' % library['passed'])
        sweep.check('suite')
        evidence['checks'].append('real Tern untouched (suite)')
    finally:
        evidence['daemon_log_tail'] = tail(tern.logs/'tern-daemon.log')
        tern.stop()


def tail(path, size=5000):
    try:
        return path.read_text(errors='replace')[-size:]
    except FileNotFoundError:
        return None


def full(base, evidence, processes, sweep):
    pub = base/'pub'
    pub.mkdir()
    server = Server(pub)
    raw = 'http://127.0.0.1:%d/' % server.port
    pkg = build_fixture(base/'pkg-0.1.0', '0.1.0', raw, str(pub)+'/')
    build_fixture(pub/'FIXTURE', '0.2.0', raw, str(pub)+'/')
    badsrc = build_fixture(base/'pkg-0.1.0-badsrc', '0.1.0', raw, str(base/'missing')+'/')
    checks = evidence['checks']

    def step(label):
        sweep.check(label)
        checks.append(label)

    def notice_after(tern, offset, needle, seconds=20):
        return wait_for(lambda: next((n for n in tern.notices(offset) if any(needle in part for part in n)), None),
                        'notice containing '+repr(needle), seconds)

    def no_pending(record):
        return record is not None and not any(k.startswith('pending_') for k in record)

    def reloaded(tern, offset, seconds=40):
        wait_for(lambda: tern.plugins_dir_lines(offset), 'fixture window VM (re)load', seconds)

    def picker_text(tern):
        value = tern.picker()
        return json.dumps(value, ensure_ascii=False) if value else ''

    try:
        tern = Tern(base, 'main', evidence, processes)
        tern.start()
        # 1. Background tick notices but never installs.
        offset = tern.log_offset()
        tern.command('plugin', 'install', pkg)
        reloaded(tern, offset)
        tern.assert_scratch_plugins_dir()
        record = wait_for(lambda: (lambda r: r if r and r.get('remote') == '0.2.0' else None)(tern.kv(FIXTURE_ID)),
                          'background tick records remote 0.2.0', TICK_WAIT)
        assert record.get('notified') == '0.2.0' and no_pending(record), record
        notice_after(tern, offset, 'FIXTURE 0.2.0 is available (you have 0.1.0)')
        assert tern.version(FIXTURE_ID) == '0.1.0'
        evidence['after_tick_kv'] = record
        step('1 background tick: kv remote == notified == 0.2.0, notice logged, still 0.1.0 (never auto-installs)')

        # 2. Explicit check notifies; Update is available.
        offset = tern.log_offset()
        tern.run('plugin.%s.check_updates' % FIXTURE_ID)
        notice_after(tern, offset, 'FIXTURE 0.2.0 is available (you have 0.1.0)')
        assert tern.shows('FIXTURE Check for updates', 'FIXTURE'), evidence['palette_rows'][-1]
        assert tern.shows('FIXTURE Update', 'FIXTURE'), evidence['palette_rows'][-1]
        step('2 check_updates notifies "is available"; install_update available')

        # 3. Update through the confirm picker.
        offset = tern.log_offset()
        tern.run('plugin.%s.install_update' % FIXTURE_ID)
        text = wait_for(lambda: (lambda t: t if 'Update FIXTURE 0.1.0 → 0.2.0' in t else None)(picker_text(tern)),
                        'confirm picker', 20)
        evidence['picker_step3'] = json.loads(text)
        sweep.check('3 before picker enter')
        tern.assert_scratch_plugins_dir()
        tern.ctl('picker', 'enter')
        wait_for(lambda: tern.version(FIXTURE_ID) == '0.2.0', 'installed 0.2.0', 60)
        wait_for(lambda: no_pending(tern.kv(FIXTURE_ID)), 'pending journal cleared', 30)
        notice_after(tern, offset, 'FIXTURE updated to 0.2.0', 30)
        step('3 picker enter installs 0.2.0; pending cleared; "updated to 0.2.0" notice')

        # 4. Reload persistence + cancel.
        offset = tern.log_offset()
        tern.command('plugin', 'install', pkg, '--force')
        wait_for(lambda: tern.version(FIXTURE_ID) == '0.1.0', 'reinstalled 0.1.0', 30)
        reloaded(tern, offset)
        assert tern.kv(FIXTURE_ID).get('remote') == '0.2.0', tern.kv(FIXTURE_ID)
        requests = len(server.requests)
        idle(1.5)  # the load timer seeds 1 s after load
        assert tern.shows('FIXTURE Update', 'FIXTURE'), evidence['palette_rows'][-1]
        assert len(server.requests) == requests, server.requests[requests:]
        tern.run('plugin.%s.install_update' % FIXTURE_ID)
        wait_for(lambda: 'Update FIXTURE 0.1.0 → 0.2.0' in picker_text(tern), 'confirm picker (cancel)', 20)
        tern.ctl('picker', 'esc')
        wait_for(lambda: not tern.picker(), 'picker closed', 10)
        idle(2)
        assert tern.version(FIXTURE_ID) == '0.1.0' and no_pending(tern.kv(FIXTURE_ID)), tern.kv(FIXTURE_ID)
        step('4 reload keeps remote; Update seeded available without a fetch; picker esc changes nothing')

        # 5. Failure.
        offset = tern.log_offset()
        tern.command('plugin', 'install', badsrc, '--force')
        reloaded(tern, offset)
        idle(1.5)
        offset = tern.log_offset()
        tern.run('plugin.%s.install_update' % FIXTURE_ID)
        wait_for(lambda: 'Update FIXTURE 0.1.0 → 0.2.0' in picker_text(tern), 'confirm picker (badsrc)', 20)
        sweep.check('5 before picker enter')
        tern.assert_scratch_plugins_dir()
        tern.ctl('picker', 'enter')
        failed = notice_after(tern, offset, 'Update failed', 60)
        evidence['failure_notice'] = failed
        assert failed[0] == 'error' and 'no directory' in failed[2], failed
        wait_for(lambda: no_pending(tern.kv(FIXTURE_ID)), 'pending cleared after failure', 10)
        assert tern.version(FIXTURE_ID) == '0.1.0'
        step('5 failed install: error notice, still 0.1.0, pending cleared')

        # 6. Requirements.
        requires = pub/'FIXTURE/requires.json'
        requires.write_text(json.dumps({'schema': 1, 'plugins': {'absent-plugin': '1.0.0'}}))
        offset = tern.log_offset()
        tern.run('plugin.%s.install_update' % FIXTURE_ID)
        refused = notice_after(tern, offset, 'absent-plugin', 30)
        evidence['requires_notice'] = refused
        idle(1)
        assert not tern.picker(), tern.picker()
        assert tern.version(FIXTURE_ID) == '0.1.0' and no_pending(tern.kv(FIXTURE_ID))
        requires.unlink()
        step('6 unmet requirements refuse with the Requires.check message; no picker')
        evidence['main_window_log_tail'] = tern.window_log()[-4000:]
        tern.stop()

        # 7. Linked twin in a fresh config.
        twin = Tern(base, 'twin', evidence, processes)
        twin.start()
        linked = base/'linked-0.1.0'
        shutil.copytree(pkg, linked)
        requests = len(server.requests)
        offset = twin.log_offset()
        twin.command('plugin', 'link', linked)
        reloaded(twin, offset)
        twin.assert_scratch_plugins_dir()
        path_file = twin.plugins_dir/(FIXTURE_ID+'.path')
        before = (tree_hash(linked), path_file.read_bytes(), path_file.stat().st_mtime_ns, twin.kv(FIXTURE_ID))
        idle(TICK_WAIT)
        assert server.requests[requests:] == [], server.requests[requests:]
        offset = twin.log_offset()
        twin.run('plugin.%s.check_updates' % FIXTURE_ID)
        notice_after(twin, offset, 'FIXTURE here is a development copy (linked)')
        assert twin.shows('FIXTURE Check for updates', 'FIXTURE'), evidence['palette_rows'][-1]
        assert not twin.shows('FIXTURE Update', 'FIXTURE'), evidence['palette_rows'][-1]
        offset = twin.log_offset()
        twin.run('plugin.%s.install_update' % FIXTURE_ID)
        notice_after(twin, offset, 'development copy')
        idle(1)
        assert not twin.picker(), twin.picker()
        after = (tree_hash(linked), path_file.read_bytes(), path_file.stat().st_mtime_ns, twin.kv(FIXTURE_ID))
        assert after == before, (before, after)
        assert server.requests[requests:] == [], server.requests[requests:]
        step('7 linked twin: no fetch in %d s, "development copy" notice, Update unavailable and refused, kv/tree/.path unchanged' % TICK_WAIT)
        evidence['twin_window_log_tail'] = twin.window_log()[-3000:]
        twin.stop()
    finally:
        evidence['server_requests'] = server.requests
        server.close()


def plugin_mode(base, evidence, processes, sweep, source):
    source = source.resolve()
    dir_name = source.name
    pub = base/'pub'
    pub.mkdir()
    server = Server(pub)
    raw = 'http://127.0.0.1:%d/' % server.port
    copy = base/'plugin'
    shutil.copytree(source, copy, ignore=shutil.ignore_patterns('.git', '__pycache__', '*.local'))
    original_id = manifest_value(copy/'plugin.toml', 'id')
    test_id = original_id+'-test'
    set_manifest(copy/'plugin.toml', id=test_id)
    rewrite_base(copy/'updater/source.luau', 'RAW_BASE', raw)
    window_entry = manifest_value(copy/'plugin.toml', 'window') or 'window.luau'
    titles = re.findall(r'tern\.command\(\s*\{[^}]*?\btitle\s*=\s*"([^"]+)"', (source/window_entry).read_text())
    version = manifest_value(copy/'plugin.toml', 'version')
    major, minor, patch = re.match(r'^(\d+)\.(\d+)\.(\d+)', version).groups()
    bumped = '%s.%s.%d' % (major, minor, int(patch)+1)
    (pub/dir_name).mkdir()
    published = (copy/'plugin.toml').read_text()
    (pub/dir_name/'plugin.toml').write_text(re.sub(r'^version = "[^"\n]*"$', 'version = '+json.dumps(bumped), published, count=1, flags=re.M))
    if (source/'requires.json').exists():
        shutil.copy2(source/'requires.json', pub/dir_name/'requires.json')
    checks = evidence['checks']
    try:
        tern = Tern(base, 'plugin', evidence, processes)
        tern.start()
        offset = tern.log_offset()
        tern.command('plugin', 'install', copy)
        wait_for(lambda: tern.plugins_dir_lines(offset), 'plugin window VM load', 40)
        tern.assert_scratch_plugins_dir()
        idle(1.5)
        offset = tern.log_offset()
        tern.run('plugin.%s.check_updates' % test_id)
        wait_for(lambda: (tern.kv(test_id) or {}).get('remote') == bumped, 'kv remote == bumped', 20)
        notices = tern.notices(offset)
        assert not any('different plugin' in part for n in notices for part in n), notices
        for log in [tern.logs/'tern.log', tern.logs/'tern-daemon.log']:
            text = log.read_text(errors='replace') if log.exists() else ''
            bad = [line for line in text.splitlines() if test_id in line and ('ERROR' in line or 'failed' in line.lower())]
            assert not bad, bad
        prefix = re.search(r'title_prefix\s*=\s*"([^"]*)"', (source/window_entry).read_text())
        prefix = prefix.group(1) if prefix else re.search(r'register\(\{[^}]*name\s*=\s*"([^"]+)"', (source/window_entry).read_text()).group(1)+' '
        assert tern.shows(prefix+'Check for updates'), evidence['palette_rows'][-1]
        assert tern.shows(prefix+'Update'), evidence['palette_rows'][-1]
        missing = [t for t in titles if not tern.shows(t)]
        evidence['plugin_titles_not_listed'] = missing
        assert not missing, missing
        sweep.check('plugin')
        checks.append('%s as %s: check_updates records remote %s, no different-plugin notice, no load failure, updater and existing commands listed' % (dir_name, test_id, bumped))
        tern.stop()
    finally:
        evidence['server_requests'] = server.requests
        server.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', required=True, type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--suite-only', action='store_true', help='Run the pure-module suite in a real Tern VM only')
    mode.add_argument('--plugin', type=Path, help='plugins/tern/DIR to check as an integrated plugin')
    args = parser.parse_args()
    evidence = {'checks': [], 'mode': 'suite-only' if args.suite_only else ('plugin' if args.plugin else 'full')}
    processes = []
    if TERN is None:
        raise SystemExit('tern is not on PATH')
    with tempfile.TemporaryDirectory(prefix='updater-smoke-', dir=Path.home()/'.cache') as temporary:
        base = Path(temporary)
        sweep = Sweep(base)
        try:
            evidence['runtime'] = subprocess.run([TERN, '--version'], capture_output=True, text=True, timeout=10,
                                                 env={k: v for k, v in os.environ.items() if not k.startswith('TERN_')}).stdout.strip()
            if args.suite_only:
                suite_only(base, evidence, processes, sweep)
            elif args.plugin:
                plugin_mode(base, evidence, processes, sweep, args.plugin)
            else:
                full(base, evidence, processes, sweep)
            sweep.check('end')
            evidence['passed'] = True
        except Exception as error:
            evidence['passed'] = False
            evidence['error'] = '%s: %s' % (type(error).__name__, error)
            evidence['logs'] = {str(p.relative_to(base)): p.read_text(errors='replace')[-6000:] for p in base.rglob('*.log')}
            evidence['plugin_log_lines'] = {str(p.relative_to(base)): [line for line in p.read_text(errors='replace').splitlines()
                                                                       if 'tern::plugin' in line or 'ERROR' in line][-200:]
                                            for p in base.rglob('*.log')}
        finally:
            for entry in reversed(processes):
                stop_entry(entry)
            evidence['own_processes_reaped'] = all(e['process'].poll() is not None for e in processes)
            evidence['process_exit_codes'] = [e['process'].poll() for e in processes]
            try:
                sweep.check('after cleanup')
                evidence['real_tern_untouched'] = True
            except AssertionError as error:
                evidence['real_tern_untouched'] = False
                evidence['passed'] = False
                evidence['error'] = evidence.get('error') or str(error)
            evidence['source_hashes'] = {name+'.luau': hashlib.sha256((ROOT/(name+'.luau')).read_bytes()).hexdigest() for name in MODULES}
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(json.dumps(evidence, indent=2, ensure_ascii=False)+'\n')
    print(json.dumps({k: v for k, v in evidence.items() if k not in ('logs',)}, indent=2, ensure_ascii=False)[:20000])
    return 0 if evidence.get('passed') and evidence.get('own_processes_reaped') else 1


if __name__ == '__main__':
    raise SystemExit(main())
