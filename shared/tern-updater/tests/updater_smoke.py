#!/usr/bin/env python3
"""Updater pure-module suite and end-to-end self-update in owned disposable Tern/Xvfb.

Run only under a descendant-owning supervisor, for example:
  systemd-run --user --scope --collect --property=KillMode=control-group \
    --property=RuntimeMaxSec=900s python3 updater_smoke.py --case git --evidence /tmp/updater-git.json
"""
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT/'tests'
FIXTURE = TESTS/'fixture'
TERN = shutil.which('tern')
MODULES = ['version', 'manifest', 'source', 'requires', 'confirm', 'journal', 'state', 'discovery', 'cli', 'shell', 'observe', 'remote', 'host', 'window']
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
                argv = Path('/proc/'+pid+'/cmdline').read_bytes().split(b'\0')
                stat = Path('/proc/'+pid+'/stat').read_text()
            except OSError:
                continue
            # pgrep -f also matches any concurrent pgrep/shell quoting the pattern (e.g. a
            # parallel harness run); only `<tern> daemon --socket /run/user/…` counts.
            if not any(argv[i] == b'daemon' and argv[i+1] == b'--socket' and argv[i+2].startswith(b'/run/user/')
                       for i in range(len(argv)-2)):
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
        """Match words and punctuation despite the palette splitting highlighted spans."""
        rows = self.palette_rows(query or label)
        self.evidence.setdefault('palette_rows', []).append({'query': query or label, 'rows': rows})
        expected = sorted(re.findall(r"\w+|[^\w\s]", label))
        return any(sorted(re.findall(r"\w+|[^\w\s]", row)) == expected for row in rows)

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


def tail(path, size=5000):
    try:
        return path.read_text(errors='replace')[-size:]
    except FileNotFoundError:
        return None


def main():
    from native_cases import main as selected_case
    return selected_case()


if __name__ == '__main__':
    raise SystemExit(main())
