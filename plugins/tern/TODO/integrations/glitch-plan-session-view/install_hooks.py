#!/usr/bin/env python3
"""Register TODO's native Glitch hooks on the execution host. Blastworks.ai, MIT."""
from __future__ import annotations

import argparse
from collections.abc import Iterator
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shlex
import shutil
import stat
import subprocess
import sys

COMPANION = Path(__file__).resolve().parent
PACKAGE = COMPANION.parents[1]
# Isolated Python does not add the script directory to its import path.
sys.dont_write_bytecode = True
sys.path.insert(0, str(COMPANION))
from install_files import (
    Refused, Snapshot, _absolute, _digest, _directory, _locked,
    _private_group_write, _private_primary_group, _snapshot, _snapshot_at, _write,
)

VERSION_TIMEOUT = 2
HOOK_TIMEOUT = 2
DOCUMENTS = {
    'README.md': '4d51d1746d1ddb9b2aaef3adce17102ab73c346c21acab5177a4d23515458464',
    'CONTRACT.md': 'f8edbf1a9b06c06a49f90f6154c061a49cda9af49184f90ae7acdd8e691982aa',
    'capability.json': 'f673b512762cb57e56e2fc27d3dbf957ba477007e8a7188677b3b231b2edbe21',
}
EVENTS = {
    'claude': (('SessionStart', 'startup|clear|resume'), ('SessionEnd', None),
               ('UserPromptExpansion', 'glitch-execute'), ('PreToolUse', 'Skill')),
    'codex': (('SessionStart', 'startup'), ('UserPromptSubmit', None), ('SessionEnd', None)),
}
VERSION = {
    'claude': (re.compile(r'([0-9]+\.[0-9]+\.[0-9]+) \(Claude Code\)'), (2, 1, 332)),
    'codex': (re.compile(r'codex-cli ([0-9]+\.[0-9]+\.[0-9]+)'), (0, 172, 0)),
}
DIGEST = re.compile(r'[0-9a-f]{64}')


class Unconfigured(Refused):
    """Automatic setup could not establish that this account opted in."""


def _unique_pairs(pairs: list[tuple[str, object]]) -> dict:
    value = dict(pairs)
    if len(value) != len(pairs):
        raise Refused('TODO setup found duplicate JSON keys.')
    return value


def _bad_constant(_: str) -> None:
    raise Refused('TODO setup found a non-JSON number.')


def _json(data: bytes | None) -> dict:
    if data is None:
        return {}
    try:
        value = json.loads(data, object_pairs_hook=_unique_pairs, parse_constant=_bad_constant)
    except (UnicodeError, json.JSONDecodeError, RecursionError):
        raise Refused('TODO setup could not read a valid JSON configuration.') from None
    if not isinstance(value, dict):
        raise Refused('TODO setup needs a JSON object at the configuration root.')
    return value


def _encode(value: dict) -> bytes:
    return (json.dumps(value, ensure_ascii=True, indent=2, allow_nan=False) + '\n').encode()


def _markers(root: Path) -> None:
    with _directory(root, owned=True), _directory(root / 'plans'):
        for path in (root / '.claude/scripts/plan_check.py',
                     root / '.claude/skills/glitch-execute/SKILL.md'):
            if _snapshot(path, trusted=True).data is None:
                raise Unconfigured('TODO setup could not verify this Glitch installation.')


def _root(explicit: Path | None) -> Path:
    environment = os.environ.get('GLITCH_ROOT')
    if explicit is not None or environment:
        root = _absolute(explicit if explicit is not None else Path(environment))
        try:
            _markers(root)
        except (Refused, OSError):
            raise Unconfigured('TODO setup needs a verified Glitch root owned by this account.') from None
        return root
    home = Path.home()
    candidates = (home / 'glitch', home / 'Glitch', home / '.glitch', Path('/opt/glitch'))
    matches = []
    for root in candidates:
        try:
            _markers(root)
        except (Refused, OSError):
            continue
        matches.append(root)
    if len(matches) != 1:
        raise Unconfigured('TODO setup needs one verified Glitch root owned by this account.')
    return matches[0]


def _package_manifest() -> tuple[str, str]:
    import tomllib

    manifest = tomllib.loads(_source_file(PACKAGE / 'plugin.toml').decode())
    ident, version = manifest.get('id'), manifest.get('version')
    if not isinstance(ident, str) or not re.fullmatch(r'todo(?:-[a-z0-9-]+)?', ident):
        raise Refused('TODO setup could not identify its installed package.')
    if not isinstance(version, str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise Refused('TODO setup could not verify its package version.')
    return ident, version


def _native_daemon() -> None:
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(PACKAGE / 'bin'))
    from process_identity import ancestors, process

    try:
        daemon = ancestors(os.getppid())[-1]
        folder = Path('/proc') / str(daemon['pid'])
        image = (folder / 'exe').readlink()
        with (folder / 'cmdline').open('rb') as stream:
            arguments = stream.read(64 * 1024)
        native = (daemon['owner'] == str(os.geteuid()) and image.name == 'tern'
                  and b'daemon' in arguments.split(b'\0')[1:]
                  and process(daemon['pid']) == daemon)
    except (ValueError, OSError):
        native = False
    if not native:
        raise Unconfigured('TODO automatic setup needs this account\'s native Tern daemon.')


def _automatic(plugin_data: Path, ident: str) -> None:
    _absolute(plugin_data)
    expected = PACKAGE.parent.parent / 'plugin-data' / ident
    if PACKAGE.name != ident or PACKAGE.parent.name != 'plugins' or plugin_data != expected:
        raise Unconfigured('TODO automatic setup needs the native installed plug-in and its data folder.')
    with _directory(PACKAGE, owned=True), _directory(plugin_data, owned=True):
        _native_daemon()
        _consent(plugin_data)


def _consent(plugin_data: Path | None) -> None:
    if plugin_data is None:
        return
    document = _json(_snapshot(plugin_data / 'kv.json').data)
    legacy = document.get('settings')
    default = legacy.get('glitch') if isinstance(legacy, dict) else False
    if document.get('settings.glitch', default) is not True:
        raise Unconfigured('TODO Glitch integration is off.')


def _system_executable(path: Path) -> Path:
    native = _absolute(path).resolve(strict=True)
    private_group = _private_primary_group()
    with _directory(native.parent, private_group=private_group) as parent:
        fd = os.open(native.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        try:
            info = os.fstat(fd)
            if (not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o111
                    or info.st_uid not in (0, os.geteuid()) or info.st_mode & 0o7000):
                raise Refused('TODO setup could not verify an installed executable.')
            if info.st_mode & 0o022 and not _private_group_write(info, fd, private_group):
                raise Refused('TODO setup found an unsafe executable write permission.')
        finally:
            os.close(fd)
    return native


def _codex_native(launcher: Path) -> Iterator[Path]:
    yield launcher
    if launcher.name != 'codex.js' or launcher.parent.parent.name != 'codex':
        return
    arches = {'x86_64': ('x64', 'x86_64'), 'aarch64': ('arm64', 'aarch64')}
    arch = arches.get(platform.machine())
    if arch is None:
        return
    platform_name, triple = arch
    npm = launcher.parent.parent
    native = (Path('codex-linux-' + platform_name) / 'vendor'
              / (triple + '-unknown-linux-musl') / 'bin/codex')
    yield npm / 'node_modules' / '@openai' / native
    yield npm.parent / native


def _detect_runtime(harness: str, explicit: Path | None) -> tuple[Path, str] | None:
    on_path = shutil.which(harness)
    defaults = (Path('/usr/bin') / harness, Path('/usr/local/bin') / harness,
                Path.home() / '.local/bin' / harness)
    candidates = (explicit,) if explicit is not None else (
        (Path(on_path).absolute(), *defaults) if on_path else defaults
    )
    pattern, minimum = VERSION[harness]
    seen = set()
    for candidate in candidates:
        try:
            resolved = _system_executable(candidate)
        except (OSError, Refused):
            continue
        paths = _codex_native(resolved) if harness == 'codex' else (resolved,)
        for path in paths:
            if path in seen or path.name != harness:
                continue
            seen.add(path)
            try:
                native = _system_executable(path)
                if explicit is None:
                    with native.open('rb') as stream:
                        if stream.read(4) != b'\x7fELF':
                            continue
                result = subprocess.run([str(native), '--version'], capture_output=True, text=True,
                                        timeout=VERSION_TIMEOUT, cwd='/', check=False,
                                        env={'PATH': os.defpath, 'HOME': str(Path.home()), 'LANG': 'C'})
            except (OSError, subprocess.TimeoutExpired, UnicodeError, Refused):
                continue
            match = pattern.fullmatch(result.stdout.strip())
            if result.returncode == 0 and match and tuple(map(int, match[1].split('.'))) >= minimum:
                return native, match[1]
    if explicit is not None:
        raise Refused(f'TODO setup could not verify the requested {harness} executable and version.')
    return None


def _config_paths(root: Path) -> dict[str, Path]:
    effective = os.environ.get('CODEX_HOME')
    codex = _absolute(Path(effective) if effective else Path.home() / '.codex')
    try:
        canonical = codex.resolve()
    except RuntimeError:
        raise Refused('TODO setup found a linked or invalid Codex home.') from None
    if canonical.is_relative_to(root):
        raise Refused('TODO setup refuses a Codex home inside the Glitch engine tree.')
    for parent in canonical.parents:
        if (parent / '.claude/scripts/plan_check.py').is_file() and (
            parent / '.claude/skills/glitch-execute/SKILL.md'
        ).is_file():
            raise Refused('TODO setup refuses a Codex home inside another Glitch engine tree.')
    return {'claude': root / '.claude/settings.local.json', 'codex': codex / 'hooks.json'}


def _preflight_hooks(harness: str, path: Path, document: dict) -> None:
    if harness == 'claude':
        if document.get('disableAllHooks', False) is not False:
            raise Refused('Claude hooks are disabled or invalid in local settings.')
        return
    import tomllib

    data = _snapshot(path.parent / 'config.toml').data
    if data is None:
        return
    try:
        configuration = tomllib.loads(data.decode())
    except (ValueError, UnicodeError):
        raise Refused('TODO setup could not read a valid Codex configuration.') from None
    features = configuration.get('features', {})
    if not isinstance(features, dict) or any(features.get(name, True) is not True for name in ('hooks', 'codex_hooks')):
        raise Refused('Codex hooks are disabled or invalid in the effective configuration.')


def _source_file(path: Path) -> bytes:
    with _directory(path.parent, trusted_from=PACKAGE) as folder:
        value = _snapshot_at(folder, path.name, trusted=True).data
    if value is None:
        raise Refused('TODO setup could not read all of its package files.')
    return value


def _bundle() -> dict[str, bytes]:
    source_files = {name: COMPANION / name for name in (*DOCUMENTS, 'entry_hook.py')}
    source_files['LICENSE'] = PACKAGE / 'LICENSE'
    for name in ('todo.py', 'publication.py', 'process_identity.py'):
        path = 'bin/' + name
        source_files[path] = PACKAGE / path
    return {name: _source_file(path) for name, path in source_files.items()}


def _generation(bundle: dict[str, bytes], version: str) -> str:
    hashes = {name: _digest(data) for name, data in bundle.items()}
    return _digest(_encode({'version': version, 'files': hashes}))


def _stage(companion: Path, generation: str, bundle: dict[str, bytes]) -> Path:
    target = companion / 'versions' / generation
    for name, data in bundle.items():
        path = target / name
        with _directory(path.parent, create=True, owned=True):
            prior = _snapshot(path)
            if prior.data is None:
                _write(path, prior, data)
            elif prior.data != data:
                raise Refused('TODO setup found a modified immutable helper generation.')
    return target


def _verify_generation(companion: Path, active: dict) -> Path | None:
    generation = active.get('generation')
    if generation is None:
        return None
    version = active.get('version')
    if not isinstance(generation, str) or not DIGEST.fullmatch(generation) or not isinstance(version, str):
        raise Refused('TODO setup found invalid companion metadata.')
    directory = companion / 'versions' / generation
    bundle = {}
    names = (*DOCUMENTS, 'entry_hook.py', 'LICENSE', 'bin/todo.py', 'bin/publication.py', 'bin/process_identity.py')
    for name in names:
        data = _snapshot(directory / name).data
        if data is None:
            raise Refused('TODO setup found an incomplete companion generation.')
        bundle[name] = data
    if _generation(bundle, version) != generation:
        raise Refused('TODO setup could not verify the staged companion bytes.')
    return directory


def _sync_documents(companion: Path, active: Path, previous: Path | None) -> list[str]:
    kept = []
    for name, old_digest in DOCUMENTS.items():
        saved = _snapshot(companion / name)
        data = _snapshot(active / name).data
        if saved.data == data:
            continue
        prior = _snapshot(previous / name).digest if previous else None
        if saved.data is not None and saved.digest not in {old_digest, prior}:
            kept.append(name)
            continue
        _write(companion / name, saved, data)
    return kept


def _hook_events(document: dict) -> dict:
    events = document.get('hooks', {})
    if not isinstance(events, dict):
        raise Refused('TODO setup expected a JSON object for hooks.')
    for groups in events.values():
        if not isinstance(groups, list):
            raise Refused('TODO setup expected arrays for hook events.')
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get('hooks'), list):
                raise Refused('TODO setup found an invalid hook group.')
            if any(not isinstance(call, dict) for call in group['hooks']):
                raise Refused('TODO setup found an invalid hook callback.')
    return events


def _refs(document: dict) -> Iterator[list]:
    for event, groups in _hook_events(document).items():
        for group in groups:
            for call in group['hooks']:
                yield [event, group.get('matcher'), call]


def _patch_hooks(document: dict, remove: list, add: list) -> dict:
    if not remove and not add:
        return document
    updated = {}
    for event, groups in _hook_events(document).items():
        kept = []
        for group in groups:
            hooks = [call for call in group['hooks'] if [event, group.get('matcher'), call] not in remove]
            if hooks or not group['hooks'] or set(group) - {'hooks', 'matcher'}:
                kept.append({**group, 'hooks': hooks})
        if kept or not groups:
            updated[event] = kept
    for event, matcher, command in add:
        group = {'hooks': [command]}
        if matcher is not None:
            group = {'matcher': matcher, **group}
        updated.setdefault(event, []).append(group)
    return {**document, 'hooks': updated}


def _new_refs(harness: str, python: Path, adapter: Path, root: Path, native: Path) -> list:
    command = shlex.join([str(python), '-I', str(adapter), '--root', str(root),
                          '--harness', harness, '--executable', str(native)])
    call = {'type': 'command', 'command': command, 'timeout': HOOK_TIMEOUT}
    return [[event, matcher, call] for event, matcher in EVENTS[harness]]


def _words(call: dict) -> list[str]:
    command = call.get('command')
    if call.get('type') != 'command' or not isinstance(command, str):
        return []
    try:
        return shlex.split(command)
    except ValueError:
        return []


def _legacy(ref: list, companion: Path, python: Path) -> bool:
    event, matcher, call = ref
    old = {('SessionStart', 'startup|resume|clear'), ('UserPromptSubmit', None), ('PreToolUse', 'Skill')}
    if not isinstance(matcher, (str, type(None))) or (event, matcher) not in old:
        return False
    if set(call) != {'type', 'command', 'timeout'} or call.get('timeout') != 5:
        return False
    arguments = _words(call)
    interpreters = {'python3', '/usr/bin/python3', str(python)}
    return (len(arguments) == 3 and arguments[0] in interpreters
            and arguments[1:] == ['-I', str(companion / 'entry_hook.py')])


def _owned_refs(document: dict, harness: str, known: list, companion: Path, python: Path) -> list:
    owned = []
    for ref in _refs(document):
        if ref in known or (harness == 'claude' and _legacy(ref, companion, python)):
            owned.append(ref)
            continue
        for word in _words(ref[2]):
            if word.endswith('/entry_hook.py') and '/_local/tern-todo/' in word:
                raise Refused('TODO setup found an unrecognized TODO callback and left it in place.')
    return owned


def _same_refs(left: list, right: list) -> bool:
    def ordered(refs: list) -> list[str]:
        return sorted(json.dumps(ref, sort_keys=True, ensure_ascii=True) for ref in refs)

    return ordered(left) == ordered(right)


def _configs(active: dict) -> dict:
    configs = active.get('configs', {})
    if not isinstance(configs, dict) or set(configs) - set(EVENTS):
        raise Refused('TODO setup found invalid configuration metadata.')
    return configs


def _allowed_config(harness: str, raw_path: str, paths: dict[str, Path]) -> Path:
    expected = paths.get(harness)
    if expected is None or str(expected) != raw_path:
        raise Refused('TODO setup needs the same effective configuration paths as its prior run.')
    return expected


def _validate_refs(harness: str, refs: list, root: Path, generation: str | None) -> None:
    companion = root / '_local/tern-todo'
    if not isinstance(refs, list):
        raise Refused('TODO setup found invalid callback metadata.')
    for ref in refs:
        if not isinstance(ref, list) or len(ref) != 3 or not isinstance(ref[2], dict):
            raise Refused('TODO setup found invalid callback metadata.')
        if generation is None:
            if harness == 'claude' and _legacy(ref, companion, Path(sys.executable).resolve()):
                continue
        else:
            words = _words(ref[2])
            adapter = str(companion / 'versions' / generation / 'entry_hook.py')
            if ((ref[0], ref[1]) in EVENTS[harness] and len(words) == 9
                    and words[1:8] == ['-I', adapter, '--root', str(root), '--harness', harness, '--executable']
                    and ref[2] == {'type': 'command', 'command': shlex.join(words), 'timeout': HOOK_TIMEOUT}):
                continue
        raise Refused('TODO setup found invalid callback metadata.')


def _validate_state(active: dict, root: Path, paths: dict[str, Path]) -> None:
    if not isinstance(active, dict):
        raise Refused('TODO setup found invalid companion metadata.')
    generation = active.get('generation')
    if generation is not None and (not isinstance(generation, str) or not DIGEST.fullmatch(generation)):
        raise Refused('TODO setup found invalid companion metadata.')
    for harness, entry in _configs(active).items():
        _allowed_config(harness, entry['path'], paths)
        _validate_refs(harness, entry['refs'], root, generation)


def _load_state(saved: Snapshot, root: Path, paths: dict[str, Path]) -> dict:
    if saved.data is None:
        return {'schema': 1, 'active': {}, 'previous': {}}
    document = _json(saved.data)
    if document.get('schema') != 1:
        raise Refused('TODO setup could not read its version metadata.')
    for key in ('active', 'previous'):
        _validate_state(document[key], root, paths)
    return document


def _observe(path: Path, *, create: bool = False) -> Snapshot:
    if create:
        with _directory(path.parent, create=True, owned=True):
            return _snapshot(path)
    try:
        return _snapshot(path)
    except FileNotFoundError:
        return Snapshot(None, (), 0o600)


def _verify_configs(active: dict, paths: dict[str, Path]) -> None:
    for harness, entry in _configs(active).items():
        path = _allowed_config(harness, entry['path'], paths)
        existing = list(_refs(_json(_observe(path).data)))
        found = [ref for ref in existing if ref in entry['refs']]
        if not _same_refs(found, entry['refs']):
            raise Refused('TODO setup could not verify the registered native callbacks.')


def _verify_changes(changes: list[dict], paths: dict[str, Path]) -> None:
    for change in changes:
        path = _allowed_config(change['harness'], change['path'], paths)
        refs = _refs(_json(_snapshot(path).data))
        affected = [ref for ref in refs if ref in change['remove'] or ref in change['add']]
        if not _same_refs(affected, change['add']):
            raise Refused('TODO setup could not verify the changed native callbacks.')


def _prepare(root: Path, harness: str, path: Path, known: list, desired: list,
             python: Path, *, install: bool) -> tuple[Snapshot, dict | None, list]:
    current = _observe(path, create=bool(desired))
    document = _json(current.data)
    if install:
        _preflight_hooks(harness, path, document)
    owned = _owned_refs(document, harness, known, root / '_local/tern-todo', python)
    if _same_refs(owned, desired):
        return current, None, owned
    value = _encode(_patch_hooks(document, owned, desired)).decode()
    change = {'harness': harness, 'path': str(path), 'before': current.digest, 'after': _digest(value.encode()),
              'remove': owned, 'add': desired, 'value': value}
    return current, change, owned


def _apply_change(change: dict, observed: Snapshot) -> None:
    _write(Path(change['path']), observed, change['value'].encode())


def _rollback_change(change: dict, paths: dict[str, Path], original: Snapshot | None) -> None:
    path = _allowed_config(change['harness'], change['path'], paths)
    observed = _observe(path)
    if observed.digest == change['before']:
        return
    before, after = change['remove'], change['add']
    document = _json(observed.data)
    relevant = [ref for ref in _refs(document) if ref in before or ref in after]
    if _same_refs(relevant, before):
        return
    if observed.digest == change['after']:
        if change['before'] is None:
            _write(path, observed, None)
            return
        if original is not None:
            _write(path, observed, original.data)
            return
    elif not after or not _same_refs(relevant, after):
        raise Refused('TODO setup met a concurrent edit and left that configuration in place.')
    value = _encode(_patch_hooks(document, after, before))
    _write(path, observed, value)


def _recover(meta: Path, root: Path, paths: dict[str, Path],
             originals: dict[str, Snapshot] | None = None) -> None:
    journal = meta / 'journal.json'
    saved = _snapshot(journal)
    if saved.data is None:
        return
    pending = _json(saved.data)
    current = _snapshot(meta / 'state.json')
    if pending.get('schema') != 1 or current.digest not in (pending['before'], pending['after']):
        raise Refused('TODO setup could not safely recover its interrupted operation.')
    if current.digest == pending['after']:
        _verify_configs(_load_state(current, root, paths)['active'], paths)
        _verify_changes(pending['changes'], paths)
    else:
        error = None
        for change in reversed(pending['changes']):
            try:
                original = originals.get(change['path']) if originals else None
                _rollback_change(change, paths, original)
            except (Refused, OSError) as failure:
                error = failure
        if error is not None:
            raise error
    _write(journal, saved, None)


def _transaction(meta: Path, root: Path, paths: dict[str, Path], current: Snapshot, desired: dict,
                 changes: list[dict], originals: dict[str, Snapshot], plugin_data: Path | None) -> None:
    if not changes and current.data == _encode(desired):
        return
    wire = _encode({**desired, 'revision': secrets.token_hex(16)})
    # The journal records exact callback edits and content digests. Full config
    # contents only live in this running process and never reach the journal.
    journal_changes = [{key: value for key, value in item.items() if key != 'value'} for item in changes]
    record = {'schema': 1, 'before': current.digest, 'after': _digest(wire), 'changes': journal_changes}
    journal = meta / 'journal.json'
    _consent(plugin_data)
    _write(journal, _snapshot(journal), _encode(record))
    try:
        for change in changes:
            _consent(plugin_data)
            _apply_change(change, originals[change['path']])
        _verify_changes(changes, paths)
        _verify_configs(desired['active'], paths)
        _write(meta / 'state.json', current, wire)
    except (Refused, OSError):
        _recover(meta, root, paths, originals)
        raise
    _recover(meta, root, paths)


def _result(state: str, message: str, active: dict, companion: Path | None = None,
            kept: list[str] | None = None, documents_need_retry: bool = False) -> dict:
    result = {'ok': True, 'state': state, 'message': message}
    if companion is not None:
        result.update(companion=str(companion), generation=active['generation'], runtimes=active.get('runtimes', {}))
        missing = [name for name in EVENTS if name not in result['runtimes']]
        if missing:
            result['unconfigured_runtimes'] = missing
            result['message'] += ' No registration for: ' + ', '.join(missing) + '.'
    if kept:
        result['preserved_documents'] = kept
        result['message'] += ' Existing member-edited companion documents were kept.'
    if documents_need_retry:
        result['documents_need_retry'] = True
        result['message'] += ' Companion documents could not be refreshed. Rerun setup to retry.'
    return result


def _select_active(action: str, prior: dict, companion: Path, root: Path, paths: dict[str, Path],
                   python: Path, runtimes: dict[str, tuple[Path, str]], version: str) -> dict:
    if action == 'remove':
        return {}
    if action == 'rollback':
        target = prior['previous']
        if not target:
            raise Unconfigured('TODO setup has no older registration to restore.')
        if _verify_generation(companion, target) is None and _snapshot(companion / 'entry_hook.py').data is None:
            raise Refused('TODO setup could not verify the legacy callback for rollback.')
        return target
    bundle = _bundle()
    generation = _generation(bundle, version)
    adapter = companion / 'versions' / generation / 'entry_hook.py'
    if set(_configs(prior['active'])) - set(runtimes):
        raise Refused('TODO setup could not verify a previously configured runtime.')
    configs = {
        harness: {'path': str(paths[harness]), 'refs': _new_refs(harness, python, adapter, root, native)}
        for harness, (native, _) in runtimes.items()
    }
    active = {'generation': generation, 'version': version, 'configs': configs,
              'runtimes': {harness: runtime_version for harness, (_, runtime_version) in runtimes.items()}}
    _stage(companion, generation, bundle)
    return active


def _next_state(action: str, prior: dict, active: dict, paths: dict[str, Path],
                observed: dict[str, list]) -> dict:
    if action == 'remove':
        return {'schema': 1, 'active': {}, 'previous': {}}
    if prior['active'] == active:
        return prior
    previous = prior['active']
    if not previous and observed:
        configs = {harness: {'path': str(paths[harness]), 'refs': refs}
                   for harness, refs in observed.items()}
        previous = {'configs': configs}
    return {'schema': 1, 'active': active, 'previous': previous}


def _setup_locked(args: argparse.Namespace, root: Path, meta: Path, companion: Path, paths: dict[str, Path],
                  python: Path, runtimes: dict[str, tuple[Path, str]], version: str) -> dict:
    _consent(args.plugin_data)
    if args.action == 'check' and _snapshot(meta / 'journal.json').data is not None:
        raise Refused('TODO setup found an interrupted operation. Run install again to recover it.')
    _recover(meta, root, paths)
    saved = _snapshot(meta / 'state.json')
    prior = _load_state(saved, root, paths)
    previous = None
    if args.action != 'remove':
        try:
            previous = _verify_generation(companion, prior['active'])
        except (Refused, OSError):
            if args.action != 'rollback':
                raise
    if args.action == 'check':
        if not _configs(prior['active']):
            raise Unconfigured('TODO native hooks are not configured for this Glitch root.')
        _verify_configs(prior['active'], paths)
        return _result('checked', 'TODO native hook registration verified.', prior['active'], previous)

    active = _select_active(args.action, prior, companion, root, paths, python, runtimes, version)
    current_configs = _configs(prior['active'])
    desired_configs = _configs(active)
    changes, originals, observed = [], {}, {}
    for harness, path in paths.items():
        if harness not in desired_configs and harness not in current_configs and not (
            harness == 'claude' and args.action == 'remove'
        ):
            continue
        known = current_configs.get(harness, {}).get('refs', [])
        want = desired_configs.get(harness, {}).get('refs', [])
        if args.action == 'rollback':
            known = [*known, *want]
        snapshot, change, found = _prepare(root, harness, path, known, want, python,
                                           install=args.action == 'install')
        if found:
            observed[harness] = found
        if change is not None:
            changes.append(change)
            originals[str(path)] = snapshot
    desired = _next_state(args.action, prior, active, paths, observed)
    _transaction(meta, root, paths, saved, desired, changes, originals, args.plugin_data)
    staged = _verify_generation(companion, active)
    kept = []
    documents_need_retry = False
    if staged is not None:
        try:
            old_docs = _verify_generation(companion, desired['previous']) if not changes else previous
            kept = _sync_documents(companion, staged, old_docs)
        except (Refused, OSError):
            documents_need_retry = True
    if args.action == 'remove':
        return _result('removed', 'TODO-owned native callbacks removed.', active)
    if args.action == 'rollback':
        return _result('rolled-back', 'Previous TODO native callbacks restored.', active, staged, kept, documents_need_retry)
    if not changes and desired == prior:
        return _result('current', 'TODO native hooks are already verified.', active, staged, kept, documents_need_retry)
    return _result('installed', 'TODO native hooks installed and verified.', active, staged, kept, documents_need_retry)


def _setup(args: argparse.Namespace) -> dict:
    if not sys.platform.startswith('linux') or sys.version_info < (3, 11):
        raise Unconfigured('TODO native hook setup requires Linux and Python 3.11 or later.')
    if os.geteuid() == 0 or os.geteuid() != os.getuid():
        raise Unconfigured('Run TODO setup as the unprivileged Glitch account.')
    ident, version = _package_manifest()
    if args.plugin_data is not None:
        if args.action != 'install':
            raise Refused('Native TODO automatic setup only performs installation.')
        _automatic(args.plugin_data, ident)
    root = _root(args.root)
    paths = _config_paths(root)
    python = _system_executable(Path(sys.executable))
    runtimes = {}
    if args.action == 'install':
        for harness in EVENTS:
            runtime = _detect_runtime(harness, getattr(args, f'{harness}_executable'))
            if runtime is not None:
                runtimes[harness] = runtime
        if not runtimes:
            raise Unconfigured('TODO setup found no supported Claude or Codex executable for this account.')
    companion = root / '_local/tern-todo'
    meta = companion / '.setup'
    create = args.action in ('install', 'remove')
    try:
        with _directory(meta, create=create, owned=True), _locked(meta):
            return _setup_locked(args, root, meta, companion, paths, python, runtimes, version)
    except FileNotFoundError:
        if not create and not meta.exists():
            raise Unconfigured('TODO native hooks are not configured for this Glitch root.') from None
        raise


class SetupParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise Refused('TODO setup received invalid command arguments.')


def main(argv: list[str] | None = None) -> int:
    try:
        parser = SetupParser(description=__doc__, allow_abbrev=False)
        parser.add_argument('--root', type=Path)
        parser.add_argument('--action', choices=('install', 'check', 'rollback', 'remove'), default='install')
        parser.add_argument('--claude-executable', type=Path)
        parser.add_argument('--codex-executable', type=Path)
        parser.add_argument('--plugin-data', type=Path)
        result = _setup(parser.parse_args(argv))
    except Unconfigured as error:
        result = {'ok': False, 'state': 'unconfigured', 'message': str(error)}
    except Refused as error:
        result = {'ok': False, 'state': 'error', 'message': str(error)}
    except (OSError, ValueError, TypeError, KeyError, ImportError, RuntimeError):
        result = {'ok': False, 'state': 'error', 'message': 'TODO setup could not verify or update its local files.'}
    print(json.dumps(result, ensure_ascii=True))
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
