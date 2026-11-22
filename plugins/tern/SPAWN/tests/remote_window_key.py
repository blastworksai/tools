#!/usr/bin/env python3
"""Regenerate tests/remote_window_key.fixture.json from two REAL, isolated Tern daemons.

CLIENT daemon: two windows (keys "" and "2"), the machine a remote window half runs on.
HOST daemon: one window (key ""), the machine SPAWN's host half runs on.
The fixture records the client's real window keys, the host's real inventory, and the
host daemon's real refusal of `inspect --window 2`. Only the host's window entry is
relabelled kind "remote": the Tern CLI cannot attach a remote client without SSH.
Usage: remote_window_key.py [--tern PATH] OUT.json   (needs xvfb-run; touches only private temp dirs)
"""
import json, os, shutil, subprocess, sys, tempfile, time


def main():
    args = sys.argv[1:]
    tern = shutil.which('tern') or '/usr/local/lib/tern/current/tern'
    if args[:1] == ['--tern']:
        tern, args = args[1], args[2:]
    out = args[0]
    base = tempfile.mkdtemp(prefix='spawn-remote-key-', dir='/var/tmp')
    procs = []

    def inspect(env, *window):
        return subprocess.run([tern, 'inspect', '--json', *window], env=env, capture_output=True, text=True)

    def machine(name, windows):
        root = os.path.join(base, name)
        env = {k: v for k, v in os.environ.items() if not k.startswith(('TERN_', 'STENCIL_'))}
        dirs = {d: os.path.join(root, d) for d in ('config', 'logs', 'run', 'home')}
        for path in dirs.values():
            os.makedirs(path, mode=0o700)
        sock = os.path.join(root, 'daemon.sock')
        env.update(TERN_CONFIG_DIR=dirs['config'], TERN_DAEMON_SOCKET=sock, STENCIL_LOG_DIR=dirs['logs'],
                   XDG_RUNTIME_DIR=dirs['run'], HOME=dirs['home'], STENCIL_GPU='cpu')
        log = open(os.path.join(root, 'log'), 'w')
        procs.append(subprocess.Popen([tern, 'daemon', '--socket', sock], env=env, stdout=log, stderr=log, start_new_session=True))
        for _ in range(100):
            if os.path.exists(sock):
                break
            time.sleep(.2)
        for index in range(windows):
            procs.append(subprocess.Popen(['xvfb-run', '-a', tern, '--control', os.path.join(root, 'w%d.sock' % index)],
                                          env=env, stdout=log, stderr=log, start_new_session=True))
            for _ in range(100):
                found = inspect(env)
                if found.returncode == 0 and sum(c['kind'] == 'window' for c in json.loads(found.stdout)['clients']) > index:
                    break
                time.sleep(.5)
            else:
                raise SystemExit('window %d of %s never attached' % (index, name))
        return env

    try:
        client = machine('client', 2)
        host = machine('host', 1)
        clients = json.loads(inspect(client).stdout)['clients']
        keys = sorted({c['window'] for c in clients if c['kind'] == 'window'})
        assert keys == ['', '2'], keys
        refused = inspect(host, '--window', '2')
        assert refused.returncode != 0 and 'no window has key 2' in refused.stderr, refused
        scoped = json.loads(inspect(host).stdout)
        pane = scoped['sessions'][0]['tabs'][0]['blocks'][0]['id']
        for entry in scoped['clients']:
            if entry['kind'] == 'window':
                entry['kind'] = 'remote'
        fixture = {'client_keys': keys, 'client_window': '2', 'host_inventory': scoped, 'host_pane': pane,
                   'host_refusal': {'status': refused.returncode, 'stderr': refused.stderr.strip()}}
        with open(out, 'w') as handle:
            json.dump(fixture, handle, indent=1, sort_keys=True)
        print('wrote', out)
    finally:
        for proc in procs:
            try:
                os.killpg(proc.pid, 15)
            except OSError:
                pass
        subprocess.run(['pkill', '-u', str(os.getuid()), '-f', base])
        shutil.rmtree(base, ignore_errors=True)


main()

# Landing policy acceptance proof, 22 Nov 2026: this comment-only line landed by Founder Overrule.
