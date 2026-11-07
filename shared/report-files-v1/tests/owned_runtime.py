"""Reuse updater process supervision with a fully private desktop user state tree."""
from datetime import datetime
import os
from pathlib import Path
import time


def owned_runtime(lib, base, name, evidence, processes):
    class OwnedTern(lib.Tern):
        def assert_running(self):
            ended = [(entry['argv'], entry['process'].poll()) for entry in self.own if entry['process'].poll() is not None]
            if ended:
                raise AssertionError('owned native daemon/window exited before completion: '+repr(ended))

        def checked_state(self):
            self.assert_running()
            state = self.ctl('state')
            carly = state.get('carly') or {}
            if carly.get('turns'):
                raise AssertionError('isolated runtime unexpectedly contains Carly conversation history')
            for task in carly.get('tasks', []):
                if task.get('id') != 0 or task.get('by') != 'heartbeat':
                    raise AssertionError('isolated runtime unexpectedly contains a pre-existing Carly task')
                for run in task.get('runs', []):
                    at = datetime.fromisoformat(run['at'].replace('Z', '+00:00')).timestamp()
                    if at < int(self.started_at):
                        raise AssertionError('isolated runtime unexpectedly loaded Carly history predating its creation')
            return state

        def command(self, *parts, **options):
            # Tern.__init__ calls command(plugin dir) before spawning anything.
            # Establish isolation here so even the first native CLI cannot load
            # the operator's HOME/XDG Carly history, settings, or credentials.
            if not hasattr(self, 'owned_environment'):
                self.started_at = time.time()
                directories = {
                    'HOME': self.root/'home',
                    'XDG_CONFIG_HOME': self.root/'xdg-config',
                    'XDG_DATA_HOME': self.root/'xdg-data',
                    'XDG_STATE_HOME': self.root/'xdg-state',
                    'XDG_CACHE_HOME': self.root/'xdg-cache',
                    'XDG_RUNTIME_DIR': self.root/'xdg-runtime',
                    'TMPDIR': self.root/'tmp',
                }
                for directory in directories.values():
                    directory.mkdir(mode=0o700)
                # Deliberately do not inherit API keys, agent configuration roots,
                # SSH_AUTH_SOCK, DBus/keyring addresses, Tern pane/window identity,
                # shell startup variables, or desktop/provider credentials.
                allowed = ('PATH', 'LANG', 'LC_ALL', 'LC_CTYPE', 'TZ', 'TERM', 'USER', 'LOGNAME')
                env = {key: self.env[key] for key in allowed if key in self.env}
                for key in ('TERN_CONFIG_DIR', 'TERN_DAEMON_SOCKET', 'STENCIL_LOG_DIR', 'STENCIL_LOG', 'STENCIL_GPU'):
                    env[key] = self.env[key]
                env.update({key: str(directory) for key, directory in directories.items()})
                env.update(SHELL='/bin/bash', no_proxy='127.0.0.1', NO_PROXY='127.0.0.1')
                if not Path(env['SHELL']).is_file() or not os.access(env['SHELL'], os.X_OK):
                    raise RuntimeError('isolated Linux native scenario requires executable /bin/bash')
                self.env = env
                self.owned_environment = {key: env[key] for key in (*directories, 'SHELL')}
                evidence.setdefault('owned_environments', {})[name] = self.owned_environment
            return super().command(*parts, **options)

    return OwnedTern(base, name, evidence, processes)
