"""Tern pane mode: ask the Tern window to open the paired page above the pane this helper runs in. Standard library only.

The helper offers the pairing link to its own idea service over the authenticated control channel, then writes one
terminal title escape to the pane's terminal. The title carries a one-time request id, never the link. The Tern window
plugin claims the link from the loopback service with that id and reports where the page opened.
The link is held in memory and sent only to the service; it is never in an argv, a title, a log or a file.
Design and contract: docs/tern-pane-road.md.
"""
import os
import re
import secrets
import stat
import subprocess
import time

# The whole pairing-URL grammar, checked locally AND by both remote scripts before any opener runs.
PAIR_URL_PATTERN = (r'http://127\.0\.0\.1:([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])'
                    r'/(\?binding=binding_[0-9a-f]{32})?#pair=[0-9a-f]{32}')
URL_SHAPE = re.compile(PAIR_URL_PATTERN)
TITLE_TEXT = re.compile(r'[a-z0-9:-]{1,80}')
FIXED_TITLE = 'glitch-idea'
FAILURES = ('no_terminal', 'plugin_no_answer', 'open_failed', 'no_result', 'offer_failed')
MAX_HOPS = 64


class Result:
    def __init__(self, returncode, stdout='', stderr=''):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr


def default_runner(argv, *, input=None, timeout=15):
    """The one place a process is started: argv list, no shell, bounded, text in and out."""
    try:
        done = subprocess.run(argv, input=input, capture_output=True, text=True, timeout=timeout, shell=False,
                              stdin=None if input is not None else subprocess.DEVNULL, errors='replace')
    except subprocess.TimeoutExpired:
        return Result(124, '', 'timeout')
    except OSError:
        return Result(127, '', 'not found')
    return Result(done.returncode, done.stdout or '', done.stderr or '')


# ---- which terminal is this pane --------------------------------------------------------------------

def _parent(proc, pid):
    """Parent pid from <proc>/<pid>/stat: the second field after the last ')' (the name may hold spaces and parens)."""
    try:
        with open(os.path.join(proc, str(pid), 'stat'), 'rb') as stream:
            data = stream.read(4096).decode('ascii', 'replace')
        return int(data[data.rindex(')') + 1:].split()[1])
    except (OSError, ValueError, IndexError):
        return None


def _writable_terminal(uid):
    def check(path):
        try:
            if not (path.startswith('/dev/pts/') or path.startswith('/dev/tty')):
                return False
            info = os.stat(path)
            return stat.S_ISCHR(info.st_mode) and info.st_uid == uid and os.access(path, os.W_OK)
        except OSError:
            return False
    return check


def find_terminal(pid=None, *, proc='/proc', uid=None, devcheck=None):
    """The first terminal device this account may write, on fds 0 to 2 of this process or an ancestor. None if none (or no /proc)."""
    try:
        pid = os.getpid() if pid is None else pid
        devcheck = _writable_terminal(os.getuid() if uid is None else uid) if devcheck is None else devcheck
        seen = set()
        for _ in range(MAX_HOPS):
            if type(pid) is not int or pid < 1 or pid in seen:
                return None
            seen.add(pid)
            for fd in (0, 1, 2):
                try:
                    path = os.readlink(os.path.join(proc, str(pid), 'fd', str(fd)))
                except OSError:
                    continue
                if devcheck(path):
                    return path
            if pid == 1:
                return None
            pid = _parent(proc, pid)
    except Exception:
        return None
    return None


def ancestor_named(name, pid=None, *, proc='/proc'):
    """True when this process or any ancestor's comm equals name."""
    try:
        pid = os.getpid() if pid is None else pid
        seen = set()
        for _ in range(MAX_HOPS):
            if type(pid) is not int or pid < 1 or pid in seen:
                return False
            seen.add(pid)
            try:
                with open(os.path.join(proc, str(pid), 'comm'), 'rb') as stream:
                    if stream.read(256).decode('ascii', 'replace').strip() == name:
                        return True
            except OSError:
                pass
            if pid == 1:
                return False
            pid = _parent(proc, pid)
    except Exception:
        return False
    return False


def default_is_tern(env=None, *, terminal=None, named=None):
    """Only a default: a terminal was found AND (TERN_PANE is set or an ancestor is named tern). The plugin's claim is the proof."""
    env = os.environ if env is None else env
    terminal = find_terminal() if terminal is None else terminal
    if not terminal:
        return False
    if env.get('TERN_PANE'):
        return True
    return bool(ancestor_named('tern') if named is None else named)


# ---- the request --------------------------------------------------------------------------------------

def title_escape(text):
    """ESC ] 2 ; text BEL, for text of [a-z0-9:-]{1,80} only."""
    if type(text) is not str or TITLE_TEXT.fullmatch(text) is None:
        raise ValueError('invalid_title')
    return b'\x1b]2;' + text.encode('ascii') + b'\x07'


def write_title(path, text, *, opener=os.open, writer=os.write):
    """One write of the title escape to the terminal. Never raises; False when it could not be written."""
    try:
        data = title_escape(text)
        fd = opener(path, os.O_WRONLY | getattr(os, 'O_NOCTTY', 0) | getattr(os, 'O_NONBLOCK', 0))
        try:
            return writer(fd, data) == len(data)
        finally:
            os.close(fd)
    except Exception:
        return False


def send_request(runtime, url, port, *, terminal, sleep=time.sleep, clock=time.monotonic, token=secrets.token_hex,
                 write=write_title, claim_wait=4.0, result_wait=6.0, poll=0.25):
    """Offer the link, write the request title, wait for the plugin. Returns (how, None) or (None, failure)."""
    match = URL_SHAPE.fullmatch(url) if type(url) is str else None
    if match is None or type(port) is not int or match.group(1) != str(port):
        from idea_launch import LaunchError
        raise LaunchError('invalid_pair_url')
    if terminal is None:
        return None, 'no_terminal'
    try:
        rid = token(16)
        runtime.tern_offer(rid, url)
    except Exception:
        return None, 'offer_failed'
    try:
        if not write(terminal, 'glitch-idea:1:%d:%s' % (port, rid)):
            return None, 'no_terminal'
        claim_deadline, claimed_at = clock() + claim_wait, None
        while True:
            try:
                state = runtime.tern_state(rid)
            except Exception:
                return None, 'offer_failed'
            if state in ('above', 'beside'):
                return state, None
            if state == 'open_failed':
                return None, 'open_failed'
            now = clock()
            if state == 'claimed' and claimed_at is None:
                claimed_at = now
            if claimed_at is not None:
                if now >= claimed_at + result_wait or state == 'unknown':
                    return None, 'no_result'
            elif now >= claim_deadline:
                return None, 'plugin_no_answer'
            sleep(poll)
    finally:
        write(terminal, FIXED_TITLE)


def open_tern_session(store_path, runtime_root, config=None, *, terminal=None, sender=send_request, **options):
    """One session, one request, no retry. Success returns no link and no code; failure returns the live link as link mode does."""
    import idea_launch
    import idea_runtime
    from urllib.parse import urlsplit
    result = idea_launch.open_session(store_path, runtime_root, config, **options)
    code = result['pairing_code']
    origin = result['origin']
    link = origin.rstrip('/') + '/#pair=' + code
    try:
        how, failure = sender(idea_runtime.Runtime(store_path, runtime_root), link, urlsplit(origin).port, terminal=terminal)
    except idea_launch.LaunchError:
        raise
    except Exception:
        how, failure = None, 'no_result'
    fallback = f'Only if the tab did not open paired: type {code} within 60 s.'
    if how is not None:
        result = {key: value for key, value in result.items() if key != 'pairing_code'}
        return dict(result, browser=dict(mode='tern', url=origin, opened=True, how=how))
    return dict(result, warning='tern_open_failed', fallback_line=fallback,
                browser=dict(mode='tern', url=origin, opened=False, link=link, failure=failure))
