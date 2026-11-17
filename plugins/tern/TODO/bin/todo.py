#!/usr/bin/env python3
"""Read explicit interactive-plan checkpoints locally or over SSH. Blastworks.ai; MIT."""
import argparse
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
STATES = {'pending', 'active', 'blocked', 'done'}


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError(message)


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
    if text.count(START) != 1 or text.count(END) != 1:
        raise ValueError('PLAN needs one explicit TERN-SESSION checkpoint block; deliberately adopt it through the planning workflow')
    before, block = text.split(START, 1)
    block, after = block.split(END, 1)
    block = block.strip()
    if not block.startswith('```json\n') or not block.endswith('\n```'):
        raise ValueError('checkpoint block must contain one fenced JSON object')
    return validate(json.loads(block[len('```json\n'):-len('\n```')]))


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
        source.add_argument('--ssh', help='explicitly reviewed ordinary SSH destination; remote host needs Python 3 and a POSIX shell')
        publish = commands.add_parser('publish', help='publish this agent session’s existing active plan identity')
        publish.add_argument('--plan', required=True)
        publish.add_argument('--agent-pid', required=True, type=int)
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
        if args.command in {'publish','clear','discover','published','ancestry'}:
            # Python -I intentionally ignores environment/CWD imports. Only our
            # installed, adjacent implementation modules are added here.
            sys.path.insert(0,str(Path(__file__).resolve().parent))
            import publication
            if args.command in {'publish','clear'}:
                result=publication.publish(args.plan if args.command=='publish' else None,read_plan,args.agent_pid)
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
        else:
            plan = read_ssh(args.ssh, args.plan) if args.ssh else read_plan(Path(args.plan))
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
