#!/usr/bin/env python3
"""Read explicit interactive-plan checkpoints locally or over SSH. Blastworks.ai; MIT."""
from __future__ import annotations

import argparse
from collections.abc import Iterator
from itertools import islice
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import uuid

START = '<!-- TERN-SESSION:START -->'
END = '<!-- TERN-SESSION:END -->'
LIMIT = 1024 * 1024
CATALOG_SCAN_LIMIT = 512
CATALOG_LIMIT = 100
CATALOG_BYTES = 16 * LIMIT
STATES = {'pending', 'active', 'blocked', 'done'}


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError(message)


class LegacyPlan(ValueError):
    """The canonical plan lacks both markers and can be deliberately adopted."""


class InvalidCheckpointBlock(ValueError):
    """An existing checkpoint block is malformed or does not match its schema."""


MAX_CHECKPOINTS = 30
MAX_TASKS = 20      # per checkpoint
MAX_ITEMS = 30      # per task
MAX_ENTITIES = 500  # checkpoints + tasks + items, so every reader and board stays bounded
ITEM_KINDS = {'file', 'step', 'validation'}
ID_RE = re.compile(r'[a-z][a-z0-9_-]{0,39}')


def _text(value, label, limit):
    if not isinstance(value, str) or not 1 <= len(value.strip()) <= limit:
        raise ValueError(f'{label} must contain 1\u2013{limit} characters')


def _entity(item, label, extra, ids, active):
    """Validate the fields every nested entity shares; ids are unique across the whole plan."""
    if not isinstance(item, dict) or not {'id', 'text', 'state'} <= set(item) or set(item) - ({'id', 'text', 'state', 'reason'} | extra):
        raise ValueError(f'{label} needs id, text, state and optional reason'
                         + (' plus ' + ', '.join(sorted(extra)) if extra else '') + ' only')
    if not isinstance(item['id'], str) or not ID_RE.fullmatch(item['id']) or item['id'] in ids:
        raise ValueError(f'{label} ids must be stable and unique across the whole plan')
    _text(item['text'], f'{label} text', 240)
    if not isinstance(item['state'], str) or item['state'] not in STATES:
        raise ValueError(f'unsupported {label} state')
    reason = item.get('reason')
    if reason is not None:
        _text(reason, 'blocked reason', 400)
    if (item['state'] == 'blocked') != (reason is not None):
        raise ValueError(f'only blocked {label}s carry a required reason')
    if len(ids) >= MAX_ENTITIES:
        raise ValueError(f'a plan holds at most {MAX_ENTITIES} checkpoints, tasks and steps together')
    ids[item['id']] = item['state']
    if item['state'] == 'active':
        active.append(item['id'])


def validate(plan):
    """Closed, bounded plan shape. Schema 1 holds checkpoints only; schema 2 nests
    checkpoint -> task -> file/step/validation item. Parents are structural, so a
    parent reference cannot dangle; every unknown key is refused."""
    if not isinstance(plan, dict) or set(plan) != {'schema', 'plan_id', 'title', 'current', 'checkpoints'}:
        raise ValueError('checkpoint block needs schema, plan_id, title, current and checkpoints only')
    schema = plan['schema']
    if type(schema) is not int or schema not in (1, 2):
        raise ValueError('unsupported checkpoint schema')
    if not isinstance(plan['plan_id'], str) or not re.fullmatch(r'plan-[0-9a-f]{12}', plan['plan_id']):
        raise ValueError('invalid stable plan_id')
    _text(plan['title'], 'plan title', 160)
    if not isinstance(plan['checkpoints'], list) or not 1 <= len(plan['checkpoints']) <= MAX_CHECKPOINTS:
        raise ValueError(f'use 1\u2013{MAX_CHECKPOINTS} agreed checkpoints')
    ids, active = {}, []
    for checkpoint in plan['checkpoints']:
        _entity(checkpoint, 'checkpoint', {'tasks'} if schema == 2 else set(), ids, active)
        tasks = checkpoint.get('tasks', [])
        if not isinstance(tasks, list) or len(tasks) > MAX_TASKS:
            raise ValueError(f'a checkpoint holds at most {MAX_TASKS} tasks, in a list')
        for task in tasks:
            _entity(task, 'task', {'items'}, ids, active)
            items = task.get('items', [])
            if not isinstance(items, list) or len(items) > MAX_ITEMS:
                raise ValueError(f'a task holds at most {MAX_ITEMS} items, in a list')
            for item in items:
                if not isinstance(item, dict) or item.get('kind') not in ITEM_KINDS:
                    raise ValueError('an item needs kind file, step or validation')
                _entity(item, 'item', {'kind', 'path'}, ids, active)
                has_path = 'path' in item
                if (item['kind'] == 'file') != has_path:
                    raise ValueError('only file items carry a required path')
                if has_path:
                    _text(item['path'], 'file path', 240)
    current = plan['current']
    if current is not None and (not isinstance(current, str) or current not in ids or ids[current] not in {'active', 'blocked'}):
        raise ValueError('current must name an active/blocked entity, or be null')
    # Several entities may be active at once (parallel builders); current is an optional focus on one active/blocked entity.
    return plan


def read_plan(path):
    if not path.is_absolute():
        raise ValueError('PLAN path must be absolute on the agent machine')
    if path.is_symlink():
        raise ValueError('PLAN must be a regular non-symlink file')
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
    fd = os.open(path, flags)
    with os.fdopen(fd, 'rb') as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError('PLAN must be a regular file')
        raw = stream.read(LIMIT + 1)
    if len(raw) > LIMIT:
        raise ValueError('PLAN exceeds 1 MiB')
    text = raw.decode('utf-8').replace('\r\n', '\n')
    start_count, end_count = text.count(START), text.count(END)
    if (start_count, end_count) != (1, 1):
        error = LegacyPlan if (start_count, end_count) == (0, 0) else InvalidCheckpointBlock
        raise error('PLAN needs one explicit TERN-SESSION checkpoint block; deliberately adopt it through the planning workflow')
    _, _, after_start = text.partition(START)
    block, end, _ = after_start.partition(END)
    if not end:
        raise InvalidCheckpointBlock('checkpoint block markers are out of order')
    block = block.strip()
    if not block.startswith('```json\n') or not block.endswith('\n```'):
        raise InvalidCheckpointBlock('checkpoint block must contain one fenced JSON object')
    try:
        return validate(json.loads(block[len('```json\n'):-len('\n```')]))
    except (ValueError, RecursionError, TypeError) as error:
        raise InvalidCheckpointBlock(str(error)) from error


def verify_glitch_root(path: Path) -> Path:
    """Verify the configured local Glitch root by its managed execute entry points."""
    if not path.is_absolute() or str(path).startswith(('\\\\', '//')):
        raise ValueError('Glitch root must be an absolute local path')
    root = path.resolve(strict=True)
    markers = (root / '.claude/scripts/plan_check.py',
               root / '.claude/skills/glitch-execute/SKILL.md')
    for marker in markers:
        canonical = marker.resolve(strict=True)
        if not canonical.is_relative_to(root) or not canonical.is_file():
            raise ValueError('configured path is not a Glitch root')
    _plan_area(root)
    return root


def _plan_area(root: Path) -> Path:
    plans = root / 'plans'
    canonical = plans.resolve(strict=True)
    if canonical == root or not canonical.is_relative_to(root) or not canonical.is_dir():
        raise ValueError('Glitch plans must be a directory inside the configured root')
    return canonical


def _canonical_plan(candidate: Path, area: Path) -> Path:
    canonical = candidate.resolve(strict=True)
    if not canonical.is_relative_to(area):
        raise ValueError('the plan resolves outside the canonical plan area')
    if canonical.suffix.lower() != '.md' or not canonical.is_file() or any(ord(c) < 32 for c in str(canonical)):
        raise ValueError('the plan must be a regular Markdown file')
    return canonical


def _catalog_root(cwd: Path | None) -> Path:
    configured = os.environ.get('GLITCH_ROOT')
    if configured:
        return verify_glitch_root(Path(configured))
    home = Path.home()
    candidates = (home / 'glitch', home / 'Glitch', home / '.glitch', Path('/opt/glitch'))
    if cwd is not None and cwd.is_absolute():
        candidates = (cwd, *cwd.parents, *candidates)
    for candidate in candidates:
        try:
            return verify_glitch_root(candidate)
        except (OSError, ValueError):
            continue
    raise ValueError('Could not find a Glitch plans folder on this host.')


def _catalog_candidates(area: Path) -> Iterator[Path]:
    yield from area.iterdir()
    archive = area / 'archive'
    if not archive.is_symlink():
        for directory, _, files in os.walk(archive):
            yield from (Path(directory) / name for name in files)


def list_plans(cwd: Path | None) -> dict:
    """Offer readable checkpoint plans from the current host without reading across workspaces."""
    root = _catalog_root(cwd)
    area = _plan_area(root)
    plans, seen = [], set()
    remaining = CATALOG_BYTES
    truncated = False
    for index, candidate in enumerate(islice(_catalog_candidates(area), CATALOG_SCAN_LIMIT + 1)):
        if index == CATALOG_SCAN_LIMIT or len(plans) == CATALOG_LIMIT:
            truncated = True
            break
        if candidate.suffix.lower() != '.md' or candidate.is_symlink():
            continue
        try:
            canonical = _canonical_plan(candidate, area)
            if canonical in seen:
                continue
            size = canonical.stat().st_size
            if size > LIMIT:
                continue
            if size > remaining:
                truncated = True
                continue
            remaining -= size
            plan = read_plan(canonical)
        except (OSError, ValueError):
            continue
        seen.add(canonical)
        plans.append({'path': str(canonical), 'name': canonical.relative_to(area).as_posix(),
                      'plan_id': plan['plan_id'], 'title': plan['title'].strip()})
    plans.sort(key=lambda plan: (plan['name'].startswith('archive/'), plan['title'].casefold(), plan['name']))
    return {'ok': True, 'root': str(root), 'plans': plans, 'truncated': truncated}


def _raise_walk_error(error: OSError) -> None:
    raise error


def resolve_execute_plan(root: Path, argument: str) -> Path:
    """Resolve one decoded execute operand without examining other workspaces."""
    if not isinstance(argument, str) or not argument.strip() or any(ord(c) < 32 for c in argument):
        raise ValueError('execute needs one explicit plan path')
    requested = Path(argument)
    if requested.suffix.lower() != '.md' or '..' in requested.parts:
        raise ValueError('execute needs a Markdown plan path within Glitch plans')
    root = verify_glitch_root(root)
    plans = _plan_area(root)
    bare_name = not requested.is_absolute() and len(requested.parts) == 1
    candidate = plans / requested if bare_name else root / requested
    if not (candidate.is_relative_to(plans) or candidate.is_relative_to(root / 'plans')):
        raise ValueError('execute plan must be in the canonical plan area')
    try:
        candidate.lstat()
    except FileNotFoundError:
        if not bare_name:
            raise
    else:
        return _canonical_plan(candidate, plans)

    archive = (plans / 'archive').resolve(strict=True)
    if archive == plans or not archive.is_relative_to(plans) or not archive.is_dir():
        raise ValueError('Glitch plan archive must be inside the canonical plan area')
    matches = set()
    for directory, _, files in os.walk(archive, onerror=_raise_walk_error):
        if requested.name in files:
            matches.add(_canonical_plan(Path(directory) / requested, archive))
            if len(matches) > 1:
                raise ValueError('the explicit plan name matches multiple archived plans')
    if not matches:
        raise FileNotFoundError('the explicit plan is absent from Glitch plans and archive')
    return matches.pop()


def _read_scoped_plan(path: Path) -> dict | None:
    try:
        return read_plan(path)
    except LegacyPlan:
        return None


def _linux_invocation(pid: int) -> tuple[Path, list[str]]:
    from process_identity import invocation

    return invocation(pid)


def _linux_foreground_terminal(pid: int) -> bool:
    folder = Path('/proc') / str(pid)
    fields = (folder / 'stat').read_text().rpartition(') ')[2].split()
    if len(fields) <= 5:
        raise ValueError('cannot verify native terminal ownership')
    tty, process_group, foreground_group = int(fields[4]), int(fields[2]), int(fields[5])
    if tty <= 0 or process_group != foreground_group:
        return False
    stdin = (folder / 'fd' / '0').stat()
    return stat.S_ISCHR(stdin.st_mode) and stdin.st_rdev == tty


def _interactive_invocation(harness: str, arguments: list[str]) -> bool:
    if harness == 'claude':
        return not any(arg.startswith('-p') or arg.partition('=')[0] in {'--print', '--sdk-url'}
                       for arg in arguments)
    if harness == 'codex':
        noninteractive = {'exec', 'e', 'app-server', 'app-server-client', 'mcp-server',
                          'review', 'cloud', 'debug', 'stdio-to-uds'}
        if any(arg in noninteractive or arg in {'--sandbox=read-only', '-s=read-only', '-sread-only'}
               for arg in arguments):
            return False
        return not any(flag in {'--sandbox', '-s'} and mode == 'read-only'
                       for flag, mode in zip(arguments, arguments[1:]))
    raise ValueError('unsupported native execute adapter')


def verify_execute_process(harness: str, *, executable: Path, declared_pid: int | None = None) -> tuple[int, str]:
    """Find the verified interactive agent process that owns this Tern hook."""
    from process_identity import ancestors, invocation, interactive_terminal, process

    if not executable.is_absolute():
        raise ValueError('the configured agent executable must be an absolute path')
    if sys.platform.startswith('linux'):
        invocation, interactive_terminal = _linux_invocation, _linux_foreground_terminal
    configured = executable.resolve(strict=True)
    identity = process(os.getpid())['owner']
    chain = ancestors(os.getppid())
    tern_image, tern_arguments = invocation(chain[-1]['pid'])
    if tern_image.name.lower().removesuffix('.exe') != 'tern' or 'daemon' not in tern_arguments:
        raise ValueError('the caller has no verified native Tern daemon ancestor')

    matches = []
    for item in chain[:-1]:
        if item['owner'] != identity:
            break
        pid = item['pid']
        image, arguments = invocation(pid)
        if image == configured:
            matches.append((item, arguments))
    if len(matches) != 1:
        raise ValueError('cannot identify one verified native agent process')
    agent, arguments = matches[0]
    pid = agent['pid']
    if declared_pid is not None and pid != declared_pid:
        raise ValueError('the native agent identity conflicts with the runtime declaration')
    if not _interactive_invocation(harness, arguments) or not interactive_terminal(pid):
        raise ValueError('the native agent is not the interactive pane process')
    if process(pid) != agent or process(chain[-1]['pid']) != chain[-1]:
        raise ValueError('the native execute process chain changed during verification')
    return pid, agent['birth']


def publish_execute_plan(root: Path, argument: str, *, agent_pid: int, expected_birth: str,
                         session_id: str, observed_ns: int, invocation_id: str | None = None) -> dict:
    """Use the common publisher for one explicit native execute event."""
    import publication

    plan_path = resolve_execute_plan(root, argument)
    return publication.publish_execute(plan_path, _read_scoped_plan, agent_pid,
                                       expected_birth=expected_birth, session_id=session_id,
                                       observed_ns=observed_ns, invocation_id=invocation_id)


def clear_execute_plan(*, agent_pid: int, expected_birth: str, session_id: str,
                       observed_ns: int, startup: bool = False) -> dict:
    import publication

    return publication.clear_execute(agent_pid, expected_birth=expected_birth,
                                     session_id=session_id, observed_ns=observed_ns, startup=startup)


def _source_envelope(plan):
    return json.dumps({'ok': True, 'plan': plan}, ensure_ascii=True, separators=(',', ':'))


# read_plan bounds the entire UTF-8 canonical input by LIMIT bytes. Validation
# preserves accepted leading/trailing whitespace, so stripped field limits are
# not wire-size limits. ensure_ascii emits at most six bytes per input byte
# (including JSON escapes); schema validation admits only the existing plan
# fields and bounded numeric/enum values. The only added success-envelope
# bytes are the fixed wrapper and newline. Errors face the same receive cap.
SSH_RESPONSE_LIMIT = 6 * LIMIT + len('{"ok":true,"plan":') + len('}\n')


def read_ssh(destination, path):
    if not re.fullmatch(r'(?:[A-Za-z0-9][A-Za-z0-9._-]*@)?[A-Za-z0-9][A-Za-z0-9._-]{0,252}', destination):
        raise ValueError('use a reviewed SSH config alias or user@host, with no shell options')
    if destination.split('@')[-1].lower().startswith('seat-'):
        raise ValueError('seat-* forced agent launchers are not SSH file-reading destinations')
    # Only this reviewed reader travels to the configured POSIX host; no install or writes.
    remote = shlex.join(['python3', '-I', '-', 'source', '--plan', str(path)])
    result = subprocess.run(['ssh', '-T', '-a', '-x', '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
                             '-o', 'PermitLocalCommand=no', '-o', 'GSSAPIDelegateCredentials=no',
                             '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3',
                             '-o', 'ClearAllForwardings=yes', '-o', 'StrictHostKeyChecking=yes',
                             '-o', 'UpdateHostKeys=no', '--', destination, remote],
                            input=Path(__file__).read_bytes(),
                            capture_output=True, timeout=4)
    unavailable = 'SSH source unavailable; verify the reviewed destination, existing trust/authentication and Python 3'
    if len(result.stdout) > SSH_RESPONSE_LIMIT:
        raise ValueError(unavailable)
    try:
        envelope = json.loads(result.stdout)
    except ValueError:
        raise ValueError(unavailable) from None
    if isinstance(envelope, dict) and envelope.get('ok') is False and isinstance(envelope.get('error'), str) and envelope['error'].strip():
        raise ValueError('Remote PLAN: ' + envelope['error'])
    if result.returncode or not isinstance(envelope, dict) or envelope.get('ok') is not True:
        raise ValueError(unavailable)
    return validate(envelope.get('plan'))


def main(argv=None):
    try:
        parser = Parser(description=__doc__)
        commands = parser.add_subparsers(dest='command', required=True, parser_class=Parser)
        source = commands.add_parser('source', help='read the agent’s canonical checkpoint block')
        source.add_argument('--plan', required=True)
        source_kind = source.add_mutually_exclusive_group()
        source_kind.add_argument('--ssh', help='explicitly reviewed ordinary SSH destination; remote host needs Python 3 and a POSIX shell')
        source_kind.add_argument('--glitch-root', type=Path, help='revalidate an explicitly selected plan against this host’s Glitch root')
        plans = commands.add_parser('plans', help='list readable canonical plans on this execution host')
        plans.add_argument('--cwd', type=Path, help='working directory of the selected Tern pane')
        publish = commands.add_parser('publish', help='publish this agent session’s existing active plan identity')
        publish.add_argument('--plan', required=True)
        publish.add_argument('--agent-pid', required=True, type=int)
        adopt = commands.add_parser('adopt', help='publish a legacy plan this native execute event reserved')
        adopt.add_argument('--plan', required=True)
        adopt.add_argument('--token', required=True)
        clear = commands.add_parser('clear', help='clear this agent session’s published plan identity')
        clear.add_argument('--agent-pid', required=True, type=int)
        commands.add_parser('ancestry', help='show native caller process facts so the agent can identify its own durable process')
        discover = commands.add_parser('discover', help='resolve a publication on this native execution host')
        discover.add_argument('--parent-pid', required=True, type=int)
        discover.add_argument('--parent-birth', help='the process birth this view saw; a different birth ends the wait')
        discover.add_argument('--with-identity', action='store_true', help='also report the process birth')
        published = commands.add_parser('published', help='read only the plan of an already-bound publishing process')
        published.add_argument('--binding', required=True)
        template = commands.add_parser('template', help='print a block for the agent to place in its approved plan; never writes it')
        template.add_argument('--title', required=True)
        template.add_argument('--step', action='append', required=True)
        args = parser.parse_args(argv)
        if args.command in {'publish','clear','discover','published','ancestry','adopt'}:
            # Python -I intentionally ignores environment/CWD imports. Only our
            # installed, adjacent implementation modules are added here.
            sys.path.insert(0,str(Path(__file__).resolve().parent))
            import publication
            if args.command in {'publish','clear'}:
                result=publication.publish(args.plan if args.command=='publish' else None,read_plan,args.agent_pid)
            elif args.command == 'adopt':
                result = publication.adopt(args.plan, args.token, read_plan)
            elif args.command=='ancestry':
                from process_identity import ancestors
                result={'ok':True,'ancestors':ancestors(os.getppid())}
            elif args.command=='discover': result=publication.discover(args.parent_pid,args.parent_birth,args.with_identity)
            else: result=publication.read_binding(json.loads(args.binding),read_plan)
            print(json.dumps(result,ensure_ascii=True,separators=(',',':')))
        elif args.command == 'template':
            plan = validate({'schema': 2, 'plan_id': 'plan-' + uuid.uuid4().hex[:12], 'title': args.title,
                             'current': None, 'checkpoints': [{'id': f'cp{i}', 'text': text, 'state': 'pending'} for i, text in enumerate(args.step, 1)]})
            print(START+'\n```json\n'+json.dumps(plan, indent=2, ensure_ascii=False)+'\n```\n'+END)
        elif args.command == 'plans':
            print(json.dumps(list_plans(args.cwd), ensure_ascii=True, separators=(',', ':')))
        else:
            path = Path(args.plan)
            if args.glitch_root is not None:
                path = resolve_execute_plan(args.glitch_root, args.plan)
            plan = read_ssh(args.ssh, args.plan) if args.ssh else read_plan(path)
            print(_source_envelope(plan))
        return 0
    except (ValueError, OSError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        envelope={'ok':False,'error':str(error)}
        if getattr(error,'terminal',False): envelope['terminal']=True
        print(json.dumps(envelope,ensure_ascii=True))
        return 1


if __name__ == '__main__':
    # Native readers and every CLI shim share this entrypoint. Imports must not
    # modify the installed plugin, including when -I ignores Python env flags.
    sys.dont_write_bytecode = True
    sys.exit(main())
