#!/usr/bin/env python3
"""Bounded native suites and isolated GUI report-path qualification.

Run under systemd-run --user --scope --collect --property=KillMode=control-group
--property=RuntimeMaxSec=900s. No native budget is changed. Module suites are not
runtime scenarios. Runtime evidence retains owned endpoints/logs for captures.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from owned_runtime import owned_runtime

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parents[2]
BASELINE = 'b8c9df4e8ea920586f51d7dd5ecec09963a1bc69'
GROUPS = {
    'orch': ('state', 'transport', 'authority', 'dispatch', 'reports', 'gates', 'health', 'workflow', 'setup_ui', 'readiness_ui'),
    'spawn': ('behavior', 'authority', 'backend', 'dispatch', 'window_dispatch', 'mailbox', 'host_editor', 'retirement_adapter', 'managed_route', 'page_navigation'),
}
PLUGINS = {'orch': 'ORCH+', 'spawn': 'SPAWN'}
SCENARIOS = ('reports', 'setup', 'policy', 'lifecycle', 'rulings', 'recovery', 'repository')


def isolation_library():
    spec = importlib.util.spec_from_file_location('updater_isolation', ROOT/'shared/tern-updater/tests/updater_smoke.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.FIXTURE_ID = 'report-native-tests'
    return module


def supervisor():
    """Reject an ordinary shell before any Tern CLI call, including plugin dir."""
    if sys.platform != 'linux':
        raise RuntimeError('unavailable: this supervisor adapter requires Linux/systemd; macOS/Windows need a descendant-owning native adapter, not Linux mock qualification')
    groups = Path('/proc/self/cgroup').read_text()
    units = re.findall(r'/([^/\n]+\.scope)(?:/|$)', groups)
    units = [unit for unit in units if not unit.startswith(('session-', 'app-'))]
    if not units:
        raise RuntimeError('run the complete harness inside a dedicated systemd-run --user --scope with KillMode=control-group and finite RuntimeMaxSec')
    result = subprocess.run(['systemctl', '--user', 'show', units[-1], '--property=KillMode,RuntimeMaxUSec'], capture_output=True, text=True, timeout=10, check=True)
    properties = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
    if properties.get('KillMode') != 'control-group' or properties.get('RuntimeMaxUSec') in (None, 'infinity', '0'):
        raise RuntimeError('supervisor must own descendants and have a finite runtime: '+str(properties))
    return {'unit': units[-1], **properties}


def source_digest(root):
    h = hashlib.sha256()
    for family in PLUGINS.values():
        for path in sorted((root/'plugins/tern'/family).rglob('*')):
            if path.is_file() and path.suffix in ('.luau', '.sh', '.awk', '.jq', '.ps1', '.toml', '.json'):
                h.update(str(path.relative_to(root)).encode())
                h.update(path.read_bytes())
    return h.hexdigest()


def sections(path):
    """Read the suite's own enumeration, never maintain a second list of names."""
    text = path.read_text()
    listed = re.findall(r'table\.find\(\{([^}]+)\},\s*section\)', text, re.S)
    if listed:
        values = re.findall(r'[\"\']([a-z_][a-z0-9_]*)[\"\']', listed[-1])
    else:
        values = re.findall(r'\bsections\.([a-z_][a-z0-9_]*)\s*=\s*function', text)
        if not values:
            declared = re.search(r'local sections\s*=\s*\{(.*?)\}', text, re.S)
            values = re.findall(r'([a-z_][a-z0-9_]*)\s*=\s*true', declared.group(1)) if declared else []
    # Fixture/helper exports return tables, not checks. Aggregate autonomy runs the
    # same cells as its explicitly enumerated bounded children.
    values = [value for value in values if value not in ('fixture', 'helpers')]
    if 'autonomy_dispatch' in values:
        values.remove('autonomy')
    return list(dict.fromkeys(values)) or [None]


def select_suites(root, selection):
    requested = [f'{family}:{group}' for family, groups in GROUPS.items() for group in groups] + ['shared:corpus'] if selection == 'all' else selection.split(',')
    if len(set(requested)) != len(requested):
        raise ValueError('duplicate suite selections')
    tasks = []
    for selected in requested:
        family, separator, selector = selected.partition(':')
        if not separator:
            raise ValueError('use orch:workflow,spawn:backend or all')
        group, _, requested_section = selector.partition('/')
        if family == 'shared' and group == 'corpus' and not requested_section:
            corpus = json.loads((root/'shared/report-files-v1/corpus.json').read_text())
            for consumer in ('orch', 'spawn'):
                for case in corpus['cases']:
                    tasks.append(dict(id=f'shared:{consumer}/{case["id"]}', family='shared', root=str(root/'plugins/tern'/PLUGINS[consumer]), consumer='wire/codec', case_id=case['id']))
            continue
        if family not in GROUPS or group not in GROUPS[family]:
            raise ValueError('unknown suite '+selected)
        package = root/'plugins/tern'/PLUGINS[family]
        enumerated = sections(package/'tests'/(group+'.luau'))
        if requested_section:
            if requested_section not in enumerated:
                raise ValueError('unknown section '+selected)
            enumerated = [requested_section]
        tasks.extend(dict(id=f'{family}:{group}'+('/'+part if part else ''), family=family, root=str(package), group=group, section=part) for part in enumerated)
    return tasks


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None  # Native fs.write is non-atomic; a partial result is never success.


def log_failures(runtime):
    bad = []
    for path in runtime.logs.glob('*.log'):
        for line in path.read_text(errors='replace').splitlines():
            if 'tern::plugin' in line and ('ERROR' in line or 'exceeded' in line or 'failed to load' in line):
                bad.append(line)
    return bad


def endpoints(runtime):
    return dict(config=str(runtime.config), daemon_socket=str(runtime.sock), control_socket=str(runtime.control), logs=str(runtime.logs))


def manifest(package, host, window=None):
    text = 'schema = 1\nid = "report-native-tests"\nname = "Report native tests"\nversion = "0.1.0"\n'
    text += 'host = '+json.dumps(host)+'\n'
    if window:
        text += 'window = '+json.dumps(window)+'\n[[blocks]]\nid = "reports"\ntitle = "Report transport qualification"\n'
    (package/'plugin.toml').write_text(text)


def suites(base, root, selection, evidence, processes, lib):
    tasks = select_suites(root, selection)
    package = base/'suite-package'
    package.mkdir()
    manifest(package, 'suite_host.luau')
    for name in ('suite_host.luau', 'corpus_runner.luau'):
        shutil.copy2(TESTS/name, package/name)
    if any(task['family'] == 'shared' for task in tasks):
        shutil.copy2(root/'shared/report-files-v1/corpus.json', package/'corpus.json')
    (package/'run.json').write_text(json.dumps({'tasks': tasks}))
    runtime = owned_runtime(lib, base, 'suite-runtime', evidence, processes)
    evidence['endpoints'] = endpoints(runtime)
    evidence['enumeration'] = tasks
    try:
        runtime.start()  # A real owned client keeps the native daemon/timers alive.
        runtime.checked_state()
        runtime.command('plugin', 'link', package)
        result_path = runtime.config/'plugin-data/report-native-tests/suite-results.json'
        def completed():
            runtime.assert_running()
            failures = log_failures(runtime)
            if failures:
                raise AssertionError('\n'.join(failures))
            result = read_json(result_path)
            evidence['suite_result'] = result
            return result if result and result.get('done') else None
        result = lib.wait_for(completed, 'all bounded native suite callbacks', 800, .1)
        expected = [task['id'] for task in tasks]
        assert [item['id'] for item in result['results']] == expected, 'missing/reordered suite result'
        assert all(item['passed'] for item in result['results']), result
        evidence['proof'] = 'native host module suites; not a runtime scenario'
    finally:
        runtime.stop()


def baseline_source(archive, base):
    """Extract only regular source files; refuse links and traversal."""
    destination = base/'baseline-source'
    destination.mkdir()
    with tarfile.open(archive) as stream:
        for member in stream:
            parts = Path(member.name).parts
            if Path(member.name).is_absolute() or '..' in parts or not (member.isfile() or member.isdir()):
                raise ValueError('unsafe baseline archive member '+member.name)
            target = destination/member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with stream.extractfile(member) as source, target.open('wb') as output:
                    shutil.copyfileobj(source, output)
    return destination


def report_component(base, root, name, evidence, processes, lib):
    """Actual native GUI/process/helper transport, explicitly not origin-authorized workflow."""
    required = ('xvfb-run', 'sh', 'jq', 'awk', 'iconv', 'base64', 'sha256sum')
    missing = [binary for binary in required if not shutil.which(binary)]
    if missing:
        return {'status': 'unavailable', 'missing': missing}
    package = base/(name+'-package')
    package.mkdir()
    for family, directory in PLUGINS.items():
        shutil.copytree(root/'plugins/tern'/directory, package/family)
    for file in ('reports_host.luau', 'reports_window.luau'):
        shutil.copy2(TESTS/file, package/file)
    manifest(package, 'reports_host.luau', 'reports_window.luau')
    runtime = owned_runtime(lib, base, name, evidence, processes)
    (runtime.root/'mailboxes').mkdir()
    (package/'report.json').write_text(json.dumps({'root': str(runtime.root/'mailboxes'), 'identity': __import__('pwd').getpwuid(os.getuid()).pw_name, 'size': 12000}))
    result = {'endpoints': endpoints(runtime), 'source_digest': source_digest(root), 'route': 'ordinary Xvfb desktop GUI / native surface events / SPAWN mailbox_adapter / native process.run / packaged POSIX helpers / codec assembly / native host KV cursor / helper ACK'}
    try:
        runtime.start()
        runtime.command('plugin', 'link', package)
        result_path = runtime.config/'plugin-data/report-native-tests/report-result.json'
        def completed():
            runtime.assert_running()
            failures = log_failures(runtime)
            if failures:
                raise AssertionError('\n'.join(failures))
            value = read_json(result_path)
            return value if value and value.get('done') else None
        value = lib.wait_for(completed, name+' report component', 180)
        result.update(value)
        result['surface'] = runtime.ctl('tree')
        result['window_state'] = runtime.checked_state()
        result['status'] = 'component_passed' if value.get('ok') else 'failed'
    finally:
        runtime.stop()
    return result


def scenarios(base, root, selection, args, evidence, processes, lib):
    requested = selection.split(',')
    if len(set(requested)) != len(requested) or any(name not in SCENARIOS for name in requested):
        raise ValueError('unknown/duplicate scenario; available names: '+','.join(SCENARIOS))
    results = {}
    evidence['scenarios'] = results
    for name in requested:
        if name in ('setup', 'policy'):
            from product_c2 import product_setup, product_policy
            run = product_setup if name == 'setup' else product_policy
            results[name] = run(base, root, evidence, processes, lib, args)
            continue
        if name != 'reports':
            results[name] = {'status': 'unavailable', 'reason': 'checkpoint runtime driver not implemented; no fixture substitute is accepted'}
            continue
        from product_scenario import product_reports
        comparison = {}
        product_comparison = {}
        entry = results[name] = {
            'status': 'failed', 'product_comparison': product_comparison, 'component': comparison,
            'measurement_scope': 'product_comparison runs the same actual native managed-report driver against pinned baseline and current source. Component measurements remain separate and cannot qualify workflow performance.',
            'provider_prerequisites': 'C1 uses a deterministic actual managed terminal. Provider-backed workflow/setup qualification needs configured credentials and disposable-worker consent; no operator agents or credentials are borrowed.',
        }
        baseline = None
        if args.baseline_archive:
            baseline = baseline_source(args.baseline_archive, base)
            provenance = {'expected_commit': BASELINE, 'archive': str(args.baseline_archive.resolve()), 'archive_sha256': hashlib.sha256(args.baseline_archive.read_bytes()).hexdigest(),
                          'provenance': 'caller must verify archive is git archive of expected_commit; archive hash is not commit authentication'}
            product_comparison['baseline'] = provenance
            product_comparison['before'] = product_reports(base, baseline, evidence, processes, lib, 'reports-product-baseline')
            product_comparison['before']['source_digest'] = source_digest(baseline)
        product = product_comparison['after'] = product_reports(base, root, evidence, processes, lib, 'reports-product-current')
        product['source_digest'] = source_digest(root)
        entry['product_path'] = product
        if baseline:
            comparison['baseline'] = provenance
            comparison['before'] = report_component(base, baseline, 'reports-baseline', evidence, processes, lib)
        comparison['after'] = report_component(base, root, 'reports-current', evidence, processes, lib)
        for observed in (product_comparison, comparison):
            before = observed.get('before', {}).get('metrics', {})
            after = observed['after'].get('metrics', {})
            if before and after:
                observed['delta_after_minus_before'] = {key: after[key] - before[key] for key in
                    ('helper_processes', 'native_helper_processes', 'producer_helper_processes', 'codec_hashed_bytes', 'codec_hash_calls',
                     'bridge_events', 'kv_writes', 'report_to_ack_ms', 'publication_return_to_ack_ms')
                    if key in before and key in after}
                observed['timing_qualification'] = 'single sequential same-host, same-driver instrumented observations; not a statistically established speedup'
        component_ok = all(comparison[side].get('status') == 'component_passed' for side in ('before', 'after') if side in comparison)
        product_ok = all(product_comparison[side].get('status') == 'passed' for side in ('before', 'after') if side in product_comparison)
        if component_ok and product_ok:
            entry['status'] = 'passed' if baseline else 'unavailable'
        if not baseline:
            entry['comparison_limitation'] = '--baseline-archive is required for C1 before/after product-path acceptance; current product proof alone does not qualify the comparison'
    evidence['passed'] = all(value['status'] == 'passed' for value in results.values())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--suites')
    mode.add_argument('--scenarios')
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--baseline-archive', type=Path, help='verified git archive of pinned '+BASELINE)
    parser.add_argument('--source', type=Path, default=ROOT, help='owned source root (default this checkout)')
    parser.add_argument('--policy-modes', default='cross_family_review,helper_checks,review_disabled',
                        help='actual deterministic native policy cells (comma-separated)')
    parser.add_argument('--policy-cases', default='passed,failed,missing,stale,empty',
                        help='actual helper check cases (comma-separated)')
    parser.add_argument('--capture-hold', type=int, default=0,
                        help='hold each C2 owned desktop for inspection, at most 600 seconds; release via metadata release_file')
    parser.add_argument('--capture-desktop', action='store_true',
                        help='owned 1920x1080 Xvfb/native window, 17px native fonts, passive display metadata; no video process')
    parser.add_argument('--capture-start-hold', type=int, default=0,
                        help='pause before C2 inputs for recorder attachment, at most 600 seconds; metadata exposes release path')
    parser.add_argument('--control-metadata', type=Path,
                        help='write current owned C2 endpoints/input protocol here before native interaction')
    parser.add_argument('--legacy-archive', type=Path,
                        help='verified prior-version source archive for native create/update/adoption qualification')
    parser.add_argument('--provider-readiness', action='store_true',
                        help='EXPLICIT CONSENT: policy scenario uses real configured-provider native readiness, not deterministic workers')
    parser.add_argument('--provider-agent-dir', type=Path,
                        help='explicit existing approved native OMP agent directory used in place; credentials are never copied')
    parser.add_argument('--provider-approve-landing', action='store_true',
                        help='explicitly answer only the ordinary owner gate for the disposable readiness landing; never native tool/auth/billing gates')
    args = parser.parse_args()
    if not 0 <= args.capture_hold <= 600:
        parser.error('--capture-hold must be between 0 and 600 seconds')
    if not 0 <= args.capture_start_hold <= 600:
        parser.error('--capture-start-hold must be between 0 and 600 seconds')
    if args.provider_readiness:
        if not args.provider_agent_dir or not args.scenarios or 'policy' not in args.scenarios.split(','):
            parser.error('--provider-readiness requires --provider-agent-dir and --scenarios policy')
        if args.policy_cases != 'passed,failed,missing,stale,empty':
            parser.error('provider readiness uses the product fixed real passing-check task; --policy-cases selects deterministic qualification only')
    elif args.provider_agent_dir or args.provider_approve_landing:
        parser.error('provider authentication/landing consent options require --provider-readiness')
    evidence = {'passed': False, 'mode': 'suites' if args.suites else 'scenarios', 'platform': sys.platform, 'checks': []}
    processes = []
    lib = None
    sweep = None
    base = None
    try:
        evidence['supervisor'] = supervisor()
        lib = isolation_library()
        if not lib.TERN:
            raise RuntimeError('unavailable: tern not on PATH')
        base = Path(tempfile.mkdtemp(prefix='report-native-'))
        evidence['scratch'] = str(base)
        sweep = lib.Sweep(base)
        evidence['runtime'] = subprocess.run([lib.TERN, '--version'], capture_output=True, text=True, timeout=10, check=True, env={k: v for k, v in os.environ.items() if not k.startswith(('TERN_', 'STENCIL_'))}).stdout.strip()
        evidence['source_digest'] = source_digest(args.source)
        if args.suites:
            suites(base, args.source.resolve(), args.suites, evidence, processes, lib)
            evidence['passed'] = True
        else:
            scenarios(base, args.source.resolve(), args.scenarios, args, evidence, processes, lib)
    except Exception as error:
        evidence['error'] = f'{type(error).__name__}: {error}'
        evidence['passed'] = False
    finally:
        if lib:
            for entry in reversed(processes):
                lib.stop_entry(entry)
        evidence['own_processes_reaped'] = all(entry['process'].poll() is not None for entry in processes)
        if base:
            evidence['logs'] = {str(path.relative_to(base)): path.read_text(errors='replace')[-12000:] for path in base.rglob('*.log')}
        if sweep:
            try:
                sweep.check('after report harness cleanup')
                evidence['real_tern_untouched'] = True
            except AssertionError as error:
                evidence['real_tern_untouched'] = False
                evidence['error'] = str(error)
                evidence['passed'] = False
        evidence['passed'] = evidence['passed'] and evidence['own_processes_reaped']
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(json.dumps(evidence, indent=2, ensure_ascii=False)+'\n')
    print(json.dumps({'passed': evidence['passed'], 'evidence': str(args.evidence), 'scratch': str(base) if base else None, 'error': evidence.get('error')}))
    return 0 if evidence['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
