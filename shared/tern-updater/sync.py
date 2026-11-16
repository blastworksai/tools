#!/usr/bin/env python3
"""Vendor the shared Tern updater into plugins.

    sync.py [--check] [DIR ...]

Copies the updater modules into <DIR>/updater/, each prefixed with HEADER.
DIR is a folder name under plugins/tern or a path. With no DIR, every
plugins/tern/*/ whose window.luau calls the updater's register is synced.
--check writes nothing; it exits 1 listing differing, missing or extra copies.
"""
import argparse
from pathlib import Path
import sys

CANON = Path(__file__).resolve().parent
ROOT = Path(__file__).resolve().parents[2]
PLUGINS = ROOT/'plugins/tern'
MODULES = ('version', 'manifest', 'source', 'requires', 'confirm', 'journal', 'state', 'discovery', 'cli', 'shell', 'observe', 'remote', 'host', 'window')
HEADER = b'-- Vendored from shared/tern-updater by sync.py; edit there, then run sync.py.\n'
REGISTER = 'require("./updater/window").register('


def registers(plugin_dir):
    window = Path(plugin_dir)/'window.luau'
    return window.is_file() and REGISTER in window.read_text(encoding='utf-8', errors='replace')


def default_dirs():
    return sorted(d for d in PLUGINS.iterdir() if d.is_dir() and registers(d)) if PLUGINS.is_dir() else []


def resolve(arg):
    named = PLUGINS/arg
    if '/' not in arg and named.is_dir():
        return named
    path = Path(arg).resolve()
    if not path.is_dir():
        raise SystemExit(f'sync.py: no plugin folder {arg!r}')
    return path


def shell_source():
    source = (PLUGINS/'SPAWN/backend.luau').read_bytes()
    start, end = b'local Backend = {}', b'-- Mailbox adapters use this same identity-fenced SSH transport constructor.'
    if source.count(start) != 1 or source.count(end) != 1:
        raise ValueError('SPAWN serializer boundaries changed; update the shared extraction explicitly')
    body = start + source.split(start, 1)[1].split(end, 1)[0]
    return (b'-- Generated from plugins/tern/SPAWN/backend.luau by updater sync.py; edit the serializer there.\n'
            + body.rstrip() + b'\nreturn Backend\n')


def expected():
    return {f'{m}.luau': HEADER + (shell_source() if m == 'shell' else (CANON/f'{m}.luau').read_bytes()) for m in MODULES}


def problems(plugin_dir, want):
    out = []
    target = plugin_dir/'updater'
    for name, data in want.items():
        path = target/name
        if not path.is_file():
            out.append(f'missing {path}')
        elif path.read_bytes() != data:
            out.append(f'differs {path}')
    if target.is_dir():
        out += [f'extra {p}' for p in sorted(target.iterdir()) if p.name not in want]
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description='Vendor shared/tern-updater into Tern plugins.')
    parser.add_argument('--check', action='store_true', help='report stale copies; write nothing')
    parser.add_argument('dirs', nargs='*', metavar='DIR')
    args = parser.parse_args(argv)
    dirs = [resolve(d) for d in args.dirs] if args.dirs else default_dirs()
    want = expected()
    if args.check:
        found = [p for d in dirs for p in problems(d, want)]
        if not (CANON/'shell.luau').is_file() or (CANON/'shell.luau').read_bytes() != shell_source():
            found.append(f'differs {CANON / "shell.luau"}')
        for line in found:
            print(line)
        return 1 if found else 0
    generated = shell_source()
    if not (CANON/'shell.luau').is_file() or (CANON/'shell.luau').read_bytes() != generated:
        (CANON/'shell.luau').write_bytes(generated)
        print(f'wrote {CANON / "shell.luau"}')
    for d in dirs:
        target = d/'updater'
        target.mkdir(exist_ok=True)
        for name, data in want.items():
            path = target/name
            if not path.is_file() or path.read_bytes() != data:
                path.write_bytes(data)
                print(f'wrote {path}')
        for extra in sorted(target.iterdir()):
            if extra.name not in want and extra.is_file():
                extra.unlink()
                print(f'removed {extra}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
