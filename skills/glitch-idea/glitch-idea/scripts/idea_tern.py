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

# The whole pairing-URL grammar, checked here, by the idea service and by the Tern plugin before the page opens.
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


def default_is_tern(env=None, *, terminal=None, named=None, agents=None):
    """Only a default: a terminal was found AND (TERN_PANE is set or an ancestor is named tern); or, with none found,
    the account's agent front end sits in a Tern pane (agent_terminals). The plugin's claim is the proof."""
    env = os.environ if env is None else env
    terminal = find_terminal() if terminal is None else terminal
    if not terminal:
        return bool(agent_terminals(env) if agents is None else agents)
    if env.get('TERN_PANE'):
        return True
    return bool(ancestor_named('tern') if named is None else named)


# ---- agents whose commands do not run under the pane ---------------------------------------------------
# Codex runs commands as children of the account's long-lived app-server daemon, which has no terminal, so the
# ancestor walk finds nothing. Then the pane is found through the account's own front-end process that does sit on a
# terminal. Closed table: marker variable the agent sets for its commands -> its front-end process names. A row is
# added only after that agent is measured. Linux /proc only; elsewhere the lookup is empty.
AGENT_FRONTS = {'CODEX_THREAD_ID': ('codex',)}
MAX_AGENT_TERMINALS = 8  # the idea service's offer cap


def _tty_path(tty_nr):
    """The kernel's decode of stat's tty_nr; a Unix98 pseudo-terminal (majors 136 to 143) only, else None."""
    if type(tty_nr) is not int or tty_nr <= 0:
        return None
    major = (tty_nr >> 8) & 0xfff
    minor = (tty_nr & 0xff) | ((tty_nr >> 12) & 0xfff00)
    if not 136 <= major <= 143:
        return None
    return '/dev/pts/%d' % ((major - 136) * 256 + minor)


def _uid_of(proc, pid):
    """The real uid from <proc>/<pid>/status. Raises on a vanished or unreadable process."""
    with open(os.path.join(proc, str(pid), 'status'), 'rb') as stream:
        for line in stream.read(8192).decode('ascii', 'replace').splitlines():
            if line.startswith('Uid:'):
                return int(line.split()[1])
    raise ValueError('no_uid')


def _agent_candidates(env=None, *, proc='/proc', uid=None, devcheck=None):
    """(pid, path) for this account's agent front-end processes on a terminal it may write, for the first marker in env.
    Deduplicated by path (lowest pid kept), sorted by pts number. A process that vanishes or cannot be read is skipped;
    [] on no marker or when the scan as a whole fails. Never reads another account's process beyond stat and status."""
    try:
        env = os.environ if env is None else env
        names = next((AGENT_FRONTS[key] for key in AGENT_FRONTS if env.get(key)), None)
        if not names:
            return []
        uid = os.getuid() if uid is None else uid
        devcheck = _writable_terminal(uid) if devcheck is None else devcheck
        entries = os.listdir(proc)
    except Exception:
        return []
    found = {}
    for entry in entries:
        try:
            if not entry.isdigit():
                continue
            pid = int(entry)
            with open(os.path.join(proc, entry, 'stat'), 'rb') as stream:
                data = stream.read(4096).decode('ascii', 'replace')
            name = data[data.index('(') + 1:data.rindex(')')]
            if name not in names:
                continue
            path = _tty_path(int(data[data.rindex(')') + 1:].split()[4]))
            if path is None or _uid_of(proc, pid) != uid or not devcheck(path):
                continue
            if path not in found or pid < found[path]:
                found[path] = pid
        except Exception:
            continue
    return sorted(((pid, path) for path, pid in found.items()), key=lambda record: int(record[1].rsplit('/', 1)[1]))


def _in_tern(pid, proc='/proc'):
    """The same test default_is_tern applies to the helper itself: TERN_PANE set in its environ, or an ancestor named tern.
    Called only for this account's own processes."""
    try:
        with open(os.path.join(proc, str(pid), 'environ'), 'rb') as stream:
            for item in stream.read(262144).split(b'\0'):
                if item.startswith(b'TERN_PANE=') and len(item) > len(b'TERN_PANE='):
                    return True
    except Exception:
        pass
    return ancestor_named('tern', pid, proc=proc)


def agent_terminals(env=None, *, proc='/proc', uid=None, devcheck=None):
    """Terminal paths of the in-Tern candidates only, at most MAX_AGENT_TERMINALS. A candidate outside Tern is never written."""
    try:
        records = _agent_candidates(env, proc=proc, uid=uid, devcheck=devcheck)
        return [path for pid, path in records if _in_tern(pid, proc)][:MAX_AGENT_TERMINALS]
    except Exception:
        return []


def pane_terminals(env=None, *, pid=None, proc='/proc', uid=None, devcheck=None):
    """(paths, title version). The ancestor road first, unchanged: ([path], 1). Else the account lookup: (paths, 2) for any
    count from one, because a lone candidate may be another session's pane. Else ([], 1)."""
    path = find_terminal(pid, proc=proc, uid=uid, devcheck=devcheck)
    if path:
        return [path], 1
    paths = agent_terminals(env, proc=proc, uid=uid, devcheck=devcheck)
    return (paths, 2) if paths else ([], 1)


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


TITLE_VERSIONS = (1, 2)  # 1: claim at once, place above the asker. 2: focus-gated (plugin 0.3.0).
TRANSIENT = ('busy', 'runtime_busy')


def send_request(runtime, url, port, *, terminal, version=1, sleep=time.sleep, clock=time.monotonic, token=secrets.token_hex,
                 write=write_title, claim_wait=4.0, result_wait=6.0, poll=0.25):
    """Offer the link, write the request title to each terminal (one request id), wait for the plugin.
    terminal is a path or a list of paths. Returns (how, None) or (None, failure)."""
    match = URL_SHAPE.fullmatch(url) if type(url) is str else None
    if match is None or type(port) is not int or match.group(1) != str(port):
        from idea_launch import LaunchError
        raise LaunchError('invalid_pair_url')
    if type(version) is not int or version not in TITLE_VERSIONS:
        raise ValueError('invalid_title_version')
    terminals = [terminal] if isinstance(terminal, (str, os.PathLike)) else list(terminal or ())
    if not terminals:
        return None, 'no_terminal'
    try:
        rid = token(16)
        runtime.tern_offer(rid, url)
    except Exception:
        return None, 'offer_failed'
    try:
        title = 'glitch-idea:%d:%d:%s' % (version, port, rid)
        written = [bool(write(path, title)) for path in terminals]
        if not any(written):
            return None, 'no_terminal'
        claim_deadline, claimed_at = clock() + claim_wait, None
        while True:
            try:
                state = runtime.tern_state(rid)
            except Exception as exc:
                if getattr(exc, 'code', None) not in TRANSIENT:
                    return None, 'offer_failed'
                state = None  # the owner is live and busy: ask again at the next tick, within the same deadlines
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
        for path in terminals:
            write(path, FIXED_TITLE)


def open_tern_session(store_path, runtime_root, config=None, *, terminal=None, version=1, sender=send_request, **options):
    """One session, one request, no retry. Success returns no link and no code; failure returns the live link as link mode does."""
    import idea_launch
    import idea_runtime
    from urllib.parse import urlsplit
    result = idea_launch.open_session(store_path, runtime_root, config, **options)
    code = result['pairing_code']
    origin = result['origin']
    link = origin.rstrip('/') + '/#pair=' + code
    try:
        how, failure = sender(idea_runtime.Runtime(store_path, runtime_root), link, urlsplit(origin).port, terminal=terminal,
                              version=version)
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
