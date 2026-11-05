"""Run the CLI from a private copy of the skill package, never the source tree.

idea.py reads config.json beside its skill dir, then beside that dir's parent.
In the source tree the parent is the repository root, where a developer may keep a
local, gitignored config.json.  A copy under a fresh temp directory has no such file.
"""
import atexit
import shutil
import tempfile
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[1]/'glitch-idea'
_copy = None


def package():
    global _copy
    if _copy is None:
        root = Path(tempfile.mkdtemp(prefix='idea-hermetic-'))
        atexit.register(shutil.rmtree, root, ignore_errors=True)
        _copy = root/'glitch-idea'
        # Local state never travels: config.json is idea.py's first configuration choice, and
        # .glitch-idea-install.json (and the installer's stage/backup folders) mark an install.
        shutil.copytree(PACKAGE, _copy, ignore=shutil.ignore_patterns(
            '__pycache__', '*.pyc', 'config.json', '.glitch-idea-*'))
    return _copy


def idea_script():
    return package()/'scripts/idea.py'
