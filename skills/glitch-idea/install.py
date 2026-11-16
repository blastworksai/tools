#!/usr/bin/env python3
"""Materialize the personal skill; never put durable idea data in its install tree."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid


PRODUCT = "glitch-idea-personal"
MANIFEST = ".glitch-idea-install.json"
SUPPORTED_KEYS = frozenset(("store_path", "plan_validator_argv", "validator_timeout_seconds",
                            "runtime_root", "runtime_python", "default_workspace",
                            "browser_port", "prototype_port", "browser_mode", "account_ports_file"))
MINIMUM_PYTHON = (3, 10)
# A Glitch Brain is identified by its engine updater beside its operations manual.
BRAIN_MARKERS = (Path(".claude") / "scripts" / "update.py", Path("operations-reference.md"))
BRAIN_MEMBER_ROOTS = ("workspaces", "_local")  # member-owned folders inside a Brain
PROBE = ("import json, sys\n"
         "try:\n    import yaml\n    version = getattr(yaml, '__version__', None)\n"
         "except Exception:\n    version = None\n"
         "print(json.dumps({'python': list(sys.version_info[:2]), 'pyyaml': version}))\n")


class InstallError(Exception):
    code = "install_error"


class PrerequisiteError(InstallError):
    """The selected runtime lacks a pinned dependency; the installer never downloads it."""
    code = "runtime_prerequisite"


def read_json(path):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise InstallError(f"Cannot read {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise InstallError(f"Expected an object in {path}")
    return value


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def within(path, root):
    return path == root or root in path.parents


def tree_files(root):
    result = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if "__pycache__" in relative.parts or path.suffix == ".pyc":
            continue
        if path.is_symlink():
            raise InstallError(f"Symlinks are not accepted in a skill tree: {path}")
        if path.is_file():
            result[relative.as_posix()] = path.read_bytes()
    return result


PATH_LIMIT = 4096  # the helper's text() bound on configured paths
LAUNCH_CONFIG_LIMIT = 16384  # idea_launch._config's encoded launch-configuration bound


def path_text(value, name):
    if (not isinstance(value, str) or not value.strip() or "\x00" in value or len(value) > PATH_LIMIT
            or any(0xD800 <= ord(c) <= 0xDFFF for c in value)):
        raise InstallError(f"{name} must be a nonempty path within {PATH_LIMIT} characters")
    return value


def absolute_path(value, name, no_symlinks=False):
    path = Path(path_text(value, name)).expanduser()
    if not path.is_absolute():
        raise InstallError(f"{name} must be an absolute path: {value}")
    if no_symlinks:
        # Same walk as the helper's launch paths: inspect every original component,
        # including those before '..', before any normalization can hide a symlink.
        current = Path(path.anchor)
        for part in path.parts[1:]:
            current = current / part
            if current.is_symlink():
                raise InstallError(f"{name} contains a symlink ({current}); the helper refuses it at launch")
    # Keep the spelling: a venv interpreter is a symlink whose own path selects the venv.
    return Path(os.path.abspath(path))


def default_runtime_root():
    """The helper's default when runtime_root is unset: the account's passwd home on POSIX
    (not $HOME), matching idea.py's _private_home."""
    if os.name == "posix":
        import pwd
        return Path(pwd.getpwuid(os.getuid()).pw_dir) / ".local" / "state" / "glitch-idea"
    return Path.home() / ".local" / "state" / "glitch-idea"


def real(path):
    """Resolved form, used only to compare locations; stored spellings are unchanged."""
    return Path(os.path.realpath(path))


def managed_brain(path):
    """The Brain whose engine-managed files would contain path; its member roots are not managed.

    Only the containing directory is resolved: a final symlink (a venv interpreter) is judged
    by where it sits, not by the base interpreter it points to."""
    path = real(path.parent) / path.name
    for candidate in (path, *path.parents):
        if all((candidate / marker).is_file() for marker in BRAIN_MARKERS):
            if any(within(path, candidate / own) for own in BRAIN_MEMBER_ROOTS):
                return None
            return candidate
    return None


def venv_python(venv):
    return venv / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


def pinned_requirements(source):
    path = source / "requirements.txt"
    pins = {}
    if not path.is_file():
        return pins
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        match = re.fullmatch(r"([A-Za-z0-9_.-]+)==([A-Za-z0-9_.+-]+)", line)
        if not match:
            raise InstallError(f"Unsupported requirement line in {path}: {line}")
        pins[match.group(1).lower()] = match.group(2)
    return pins


def check_runtime(python, source):
    """Ask the selected interpreter what it can import; report, never install."""
    requirements = source / "requirements.txt"
    remedy = f'"{python}" -m pip install -r "{requirements}"'
    if not python.is_file() or not os.access(python, os.X_OK):
        raise InstallError(f"runtime_python is not an existing executable: {python}")
    try:
        with tempfile.TemporaryDirectory() as neutral:
            # A neutral working directory keeps a stray local yaml/ from answering for the runtime.
            # -E: PYTHONPATH/PYTHONHOME cannot lend a yaml the runtime lacks; -B: write no bytecode.
            probe = subprocess.run([str(python), "-E", "-B", "-c", PROBE], capture_output=True, text=True,
                                   timeout=30, cwd=neutral)
        reply = json.loads(probe.stdout)
        found = tuple(reply["python"])
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as exc:
        raise InstallError(f"Cannot query runtime_python {python}: {exc}") from exc
    if found < MINIMUM_PYTHON:
        raise InstallError(f"runtime_python {python} is Python {found[0]}.{found[1]}; "
                           f"{MINIMUM_PYTHON[0]}.{MINIMUM_PYTHON[1]} or newer is required")
    wanted = pinned_requirements(source).get("pyyaml")
    if wanted is not None and reply.get("pyyaml") != wanted:
        have = "is missing PyYAML" if reply.get("pyyaml") is None else f"has PyYAML {reply['pyyaml']}"
        raise PrerequisiteError(f"runtime_python {python} {have}; PyYAML {wanted} is required. "
                                f"Install it yourself, then rerun this installer: {remedy}")
    return {"python": str(python), "python_version": f"{found[0]}.{found[1]}",
            "pyyaml": reply.get("pyyaml"), "status": "ready"}


def effective_config(source, destination, explicit_store, recognized, explicit_runtime=None,
                     shared=False, account_ports_file=None):
    installed_config = destination / "config.json"
    source_config = source / "config.json"
    if recognized:
        if not installed_config.is_file():
            raise InstallError(f"Recognized installation is missing {installed_config}; restore its saved config before upgrading so the durable store is not changed")
        config_path = installed_config
    else:
        config_path = source_config if source_config.exists() else source.parent / "config.json"
    config = read_json(config_path) if config_path.exists() else {}
    # Retired ssh mode: these keys, and a browser_mode of "ssh", are dropped (read as absent) before the unknown-key refusal.
    retired = [key for key in ("ssh_client", "ssh_server_port") if key in config]
    if config.get("browser_mode") == "ssh":
        retired.append("browser_mode")
    if retired:
        config = {key: value for key, value in config.items() if key not in retired}
        print(f"Dropped retired ssh mode settings from {config_path}: {', '.join(retired)} (ssh mode no longer exists).", file=sys.stderr)
    unknown = sorted(set(config) - SUPPORTED_KEYS)
    if unknown:
        raise InstallError(f"Unsupported configuration keys in {config_path}: {', '.join(unknown)}; "
                           f"supported keys are {', '.join(sorted(SUPPORTED_KEYS))}")
    if recognized and (not isinstance(config.get("store_path"), str) or not config["store_path"].strip()):
        raise InstallError(f"Recognized installation has no valid store_path in {config_path}; restore its saved config before upgrading")
    store_value = path_text(explicit_store or config.get("store_path", str(source.parent / "ideas")), "store_path")
    store = Path(store_value).expanduser()
    if not store.is_absolute():
        store = (Path.cwd() if explicit_store else config_path.parent) / store
    store = store.resolve()
    path_text(str(store), "store_path")  # the absolute form the helper reads, not just the input
    if within(store, destination) or within(destination, store) or within(store, source) or within(source, store):
        raise InstallError("The durable store must be outside the source and installed skill trees, and cannot contain the installation")
    if managed_brain(store) is not None:
        raise InstallError(f"The durable store {store} is inside the managed Glitch Brain at {managed_brain(store)}")
    argv = config.get("plan_validator_argv")
    # Same bounds the helper enforces at run time, so an install never writes a config it refuses.
    if argv is not None and (not isinstance(argv, list) or not 0 < len(argv) <= 32 or
                             any(not isinstance(v, str) or not v.strip() or "\x00" in v for v in argv)):
        raise InstallError("plan_validator_argv must be null or a list of 1 to 32 nonempty strings")
    timeout = config.get("validator_timeout_seconds", 30)
    if type(timeout) is not int or not 1 <= timeout <= 120:
        raise InstallError("validator_timeout_seconds must be an integer from 1 to 120")
    result = {"store_path": str(store), "plan_validator_argv": argv,
              "validator_timeout_seconds": timeout}
    workspace = config.get("default_workspace")
    if workspace is not None:
        # The helper checks the folder exists each time it runs; here only the shape, so an install never writes a config it refuses.
        if (not isinstance(workspace, dict) or set(workspace) != {"name", "path"} or not isinstance(workspace["name"], str)
                or not 1 <= len(workspace["name"]) <= 100 or not workspace["name"].strip() or "\n" in workspace["name"]
                or "\r" in workspace["name"] or not isinstance(workspace["path"], str) or "\x00" in workspace["path"]
                or not os.path.isabs(workspace["path"])):
            raise InstallError("default_workspace must be null or an object with a one-line name and an absolute path")
        result["default_workspace"] = {"name": workspace["name"], "path": workspace["path"]}
    registry = account_ports_file if account_ports_file is not None else config.get("account_ports_file")
    if registry is not None:
        if os.name != "posix":
            raise InstallError("account_ports_file is not supported on Windows")
        if not _clean_text(registry):
            raise InstallError("account_ports_file must be a path of clean text (no control characters), the same rule the helper applies")
        registry = absolute_path(registry, "account_ports_file")
        if os.path.isdir(registry):
            raise InstallError(f"account_ports_file must name a file, not a folder: {registry}")
    if shared and registry is None:
        raise InstallError("--shared needs --account-ports-file /absolute/path (the registry of each account's two ports); nothing changed")
    if registry is not None:
        result["account_ports_file"] = str(registry)
        inline = [key for key in ("browser_port", "prototype_port") if config.get(key) is not None]
        if inline and not shared:
            raise InstallError(f"account_ports_file and {' / '.join(inline)} are two sources of one fact; remove the ports from the configuration")
        if inline:
            config = {key: value for key, value in config.items() if key not in inline}
            print(f"Dropped {', '.join(inline)} from {config_path}: a shared install takes each account's ports from {registry}.", file=sys.stderr)
    # Same bounds the helper enforces at run time; each key is written only when the seat sets it.
    for key in ("browser_port", "prototype_port"):
        if config.get(key) is not None:  # a JSON null is unset, as the helper reads it
            port = config[key]
            if type(port) is not int or not 1024 <= port <= 65535:
                raise InstallError(f"{key} must be an integer from 1024 to 65535")
            result[key] = port
    if "browser_port" in result and "prototype_port" in result and result["browser_port"] == result["prototype_port"]:
        raise InstallError("browser_port and prototype_port must differ")
    if config.get("browser_mode") is not None:
        if config["browser_mode"] not in ("link", "system", "tern"):
            raise InstallError("browser_mode must be 'link', 'system' or 'tern'")
        result["browser_mode"] = config["browser_mode"]
    if len(json_bytes(result)) > LAUNCH_CONFIG_LIMIT:
        raise InstallError(f"store_path and plan_validator_argv together exceed the {LAUNCH_CONFIG_LIMIT}-byte launch limit")
    explicit_runtime = explicit_runtime or {}
    if shared and ("runtime_root" in explicit_runtime or config.get("runtime_root") is not None):
        raise InstallError("--shared takes no runtime_root: one folder would be every account's runtime; "
                           "each account uses its own default under its own home")
    for key in ("runtime_root", "runtime_python"):
        if key in config and config[key] is None:
            # A present null is malformed, not unset: refuse it rather than drop it.
            raise InstallError(f"{key} must be an absolute path; omit the key instead of setting null")
        value = explicit_runtime.get(key)
        if value is None and key in config:
            value = absolute_path(config[key], key, no_symlinks=key == "runtime_root")
        if value is None:
            continue
        # An interpreter's own name is usually a symlink out of its venv: resolve only the
        # directory holding it, so the venv's location is what gets checked.
        place = real(value.parent) / value.name if key == "runtime_python" else real(value)
        path_text(str(value), key)  # the stored spelling, after ~ expansion, within the helper's bound
        if within(place, destination) or within(destination, place) or within(place, source):
            raise InstallError(f"{key} must be outside the source and installed skill trees")
        brain = managed_brain(place)
        if brain is not None:
            raise InstallError(f"{key} is inside the managed Glitch Brain at {brain}")
        result[key] = str(value)
    return result


def install(source, skills_root, store=None, dry_run=False, runtime_python=None, venv=None,
            runtime_root=None, shared=False, account_ports_file=None):
    if source.is_symlink():
        raise InstallError("Source skill must be a materialized directory")
    source = source.expanduser().resolve()
    skills_root = skills_root.expanduser().resolve()
    destination = skills_root / "glitch-idea"
    if within(destination, source) or within(source, destination):
        raise InstallError("Source and installation must be separate trees")
    if destination.is_symlink():
        raise InstallError(f"Refusing a symlink destination: {destination}")
    if not (source / "SKILL.md").is_file() or not (source / "scripts" / "idea.py").is_file():
        raise InstallError("Source must contain SKILL.md and scripts/idea.py")
    brain = managed_brain(skills_root)
    if brain is not None:
        raise InstallError(f"{skills_root} is inside the managed Glitch Brain at {brain}; "
                           "install into a personal skills directory instead; nothing changed")
    if runtime_python is not None and venv is not None:
        raise InstallError("Choose either --runtime-python or --venv, not both")
    explicit_runtime = {}
    if runtime_root is not None:
        explicit_runtime["runtime_root"] = absolute_path(runtime_root, "--runtime-root", no_symlinks=True)
    if runtime_python is not None:
        explicit_runtime["runtime_python"] = absolute_path(runtime_python, "--runtime-python")
    if venv is not None:
        venv = absolute_path(venv, "--venv")
        if venv.is_symlink() or (venv.exists() and not venv.is_dir()):
            raise InstallError(f"--venv must be a directory: {venv}")
        if venv.is_dir() and any(venv.iterdir()) and not (venv / "pyvenv.cfg").is_file():
            raise InstallError(f"--venv {venv} is a nonempty directory that is not a virtual environment")
        explicit_runtime["runtime_python"] = venv_python(venv)
    if shared and os.name != "posix":
        raise InstallError("--shared is not supported on Windows")
    if account_ports_file is not None and not shared and os.name != "posix":
        raise InstallError("account_ports_file is not supported on Windows")
    recognized = destination.exists()
    was_shared = False
    if recognized:
        marker = destination / MANIFEST
        if not marker.is_file():
            raise InstallError(f"Unrelated skill already occupies {destination}; nothing changed")
        manifest = read_json(marker)
        if manifest.get("product") != PRODUCT or manifest.get("format_version") != 1:
            raise InstallError(f"Unrecognized installation at {destination}; nothing changed")
        was_shared = manifest.get("shared") is True
    config = effective_config(source, destination, store, recognized, explicit_runtime, shared, account_ports_file)
    if venv is not None:
        place, store_path = real(venv), real(config["store_path"])
        runtime_home = real(config["runtime_root"]) if "runtime_root" in config else real(default_runtime_root())
        if within(place, store_path) or within(store_path, place) or \
                within(place, runtime_home) or within(runtime_home, place):
            raise InstallError("--venv must be outside the durable store and the runtime root")
    payload = tree_files(source)
    payload.pop(MANIFEST, None)
    payload["config.json"] = json_bytes(config)
    current = tree_files(destination) if recognized else {}
    current.pop(MANIFEST, None)
    same = recognized and current == payload and was_shared == shared
    drift = same and shared and _shared_drift(destination, payload, source, _skills_gid(skills_root))
    action = ("repaired" if drift else "unchanged" if same else "upgraded" if recognized else "installed")
    store_facts = _store_gate(config["store_path"], skills_root) if shared else None
    result = _publish(source, skills_root, destination, config, payload, action, recognized,
                      venv, dry_run, shared)
    if store_facts is not None:
        result["store"] = store_facts
    return result


def _publish(source, skills_root, destination, config, payload, action, recognized, venv, dry_run, shared=False):
    created_venv = False
    if venv is not None and not dry_run and not venv_python(venv).exists():
        # Standard library only: creating a venv downloads nothing. It runs only after
        # every input and the package itself have been read and validated.
        made = subprocess.run([sys.executable, "-m", "venv", str(venv)],
                              capture_output=True, text=True, timeout=300)
        if made.returncode != 0:
            detail = (made.stderr or made.stdout).strip().splitlines()[-1:] or ["no output"]
            raise PrerequisiteError(f"{sys.executable} could not create a virtual environment at {venv} "
                                    f"({detail[0]}); install your platform's venv support for this "
                                    "Python, or pass --runtime-python with an interpreter that has PyYAML")
        created_venv = True
    try:
        result = _install_files(source, skills_root, destination, config, payload, action,
                                recognized, venv, dry_run, shared)
    except (InstallError, OSError) as exc:
        if not created_venv:
            raise
        note = f" (the virtual environment {venv} was created and kept)"
        if isinstance(exc, InstallError):
            exc.args = (str(exc) + note,)
            raise
        raise InstallError(str(exc) + note) from exc
    if created_venv:
        result["venv_created"] = str(venv)
    return result


def _group_name(gid):
    try:
        import grp
        return grp.getgrgid(gid).gr_name
    except (ImportError, KeyError):
        return str(gid)


def _shared_mode(path, relative, payload, source):
    """The mode a shared install gives this path: folders 2750, files 640, 750 for a source script that is executable."""
    if path.is_dir():
        return 0o2750
    runnable = relative in payload and (source / relative).is_file() and (source / relative).stat().st_mode & 0o111
    return 0o750 if runnable else 0o640


def _shared_drift(destination, payload, source, gid):
    """True when an installed shared tree no longer has the modes, group or executable bits an install gives it."""
    for path in [destination, *destination.rglob("*")]:
        if path.is_symlink():
            continue
        relative = path.relative_to(destination).as_posix()
        if "__pycache__" in path.parts or path.suffix == ".pyc":
            continue
        info = path.stat()
        if info.st_gid != gid or stat.S_IMODE(info.st_mode) != _shared_mode(path, relative, payload, source):
            return True
    return False


def _skills_gid(skills_root):
    return skills_root.stat().st_gid if skills_root.exists() else os.getgid()


def _clean_text(value, limit=4096):
    """The runtime's clean-text rule (idea.py's _clean_text; a test keeps the two in agreement)."""
    return (type(value) is str and bool(value.strip()) and len(value) <= limit
            and all(32 <= ord(c) != 127 and not 0xD800 <= ord(c) <= 0xDFFF for c in value))


def _store_gate(store, skills_root):
    """A shared install checks the store's top folder, read-only, with one lstat: nothing is created, changed or left behind.

    The root must be a real directory, setgid, with group read, write and execute (2770), in a group this account belongs
    to. idea_platform.is_shared_root applies the same test at run time (a test keeps the two equal).
    What is already inside the store is not checked: converting a single-account store is the operator's step."""
    store = Path(store)
    group = _group_name(_skills_gid(skills_root))
    create = f"mkdir '{store}' && chgrp {group} '{store}' && chmod 2770 '{store}'"
    fix = f"chgrp {group} '{store}' && chmod 2770 '{store}'"
    try:
        info = os.lstat(store)
    except FileNotFoundError:
        raise InstallError(f"A shared install needs its store to exist first, and {store} does not. Create it, then rerun: {create} ; nothing changed") from None
    if not stat.S_ISDIR(info.st_mode):
        raise InstallError(f"The store {store} is not a real folder; nothing changed")
    if not info.st_mode & stat.S_ISGID or info.st_mode & 0o070 != 0o070:
        raise InstallError(f"A shared install needs a store several accounts can use, and {store} is not setgid with group read, write "
                           f"and execute (mode 2770). Run: {fix} ; then rerun. Nothing changed")
    if info.st_gid not in {os.getgid(), *os.getgroups()}:
        raise InstallError(f"The store {store} belongs to group {_group_name(info.st_gid)}, which this account is not in; run: {fix} ; nothing changed")
    return {"path": str(store), "status": "ready"}


def _share(stage, payload, source, gid):
    """Shared modes, applied to the staged tree before it is renamed in: group first, since chown clears setgid."""
    for path in [stage, *sorted(stage.rglob("*"))]:
        if path.is_symlink():
            continue
        try:
            os.chown(path, -1, gid)
        except OSError as exc:
            raise InstallError(f"Cannot give {path.name} to the skills folder's group ({_group_name(gid)}): {exc.strerror}; "
                               "the installing account must belong to that group") from exc
        os.chmod(path, _shared_mode(path, path.relative_to(stage).as_posix(), payload, source))


def _install_files(source, skills_root, destination, config, payload, action, recognized, venv, dry_run,
                   shared=False):
    if "runtime_python" not in config:
        runtime = {"status": "not_configured",
                   "message": "Browser launch needs a runtime: rerun with --venv PATH or --runtime-python PATH"}
    elif dry_run and not Path(config["runtime_python"]).exists():
        runtime = {"python": config["runtime_python"], "status": "would_create_venv" if venv is not None else "missing"}
    else:
        runtime = check_runtime(Path(config["runtime_python"]), source)
    result = {"ok": True, "action": action, "destination": str(destination),
              "store_path": config["store_path"], "dry_run": dry_run, "runtime": runtime}
    gid = None
    if shared:
        gid = _skills_gid(skills_root)
        result["shared"] = {"account_ports_file": config["account_ports_file"], "group": _group_name(gid),
                            "folder_mode": "2750", "file_mode": "640"}
    if dry_run or action == "unchanged":
        return result
    skills_root.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".glitch-idea-stage-", dir=skills_root))
    backup = None
    try:
        hashes = {}
        for relative, content in payload.items():
            path = stage / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("wb") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            hashes[relative] = hashlib.sha256(content).hexdigest()
        marker = {"product": PRODUCT, "format_version": 1,
                  "installed_at": datetime.now(timezone.utc).isoformat(),
                  "source": str(source), "files": hashes}
        if shared:
            marker["shared"] = True
        with (stage / MANIFEST).open("wb") as stream:
            stream.write(json_bytes(marker))
            stream.flush()
            os.fsync(stream.fileno())
        if shared:
            _share(stage, payload, source, gid)
        if recognized:
            backup_home = skills_root / ".glitch-idea-backups"
            if backup_home.is_symlink():
                raise InstallError(f"Refusing a symlink backup directory: {backup_home}")
            backup_home.mkdir(exist_ok=True)
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
            backup = backup_home / (stamp + "-" + uuid.uuid4().hex[:8])
            destination.rename(backup)
        try:
            stage.rename(destination)
        except OSError:
            if backup is not None and not destination.exists():
                backup.rename(destination)
                backup = None
            raise
        if backup is not None:
            result["backup"] = str(backup)
        return result
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parent / "glitch-idea")
    parser.add_argument("--skills-root", type=Path, default=Path.home() / ".codex" / "skills")
    parser.add_argument("--store", help="Durable idea store; relative paths resolve against the current directory")
    parser.add_argument("--runtime-python", help="Absolute path of an existing interpreter that has the pinned PyYAML")
    parser.add_argument("--venv", help="Absolute path of a per-skill virtual environment; created if absent")
    parser.add_argument("--runtime-root", help="Absolute owner-private directory for the browser service's runtime files")
    parser.add_argument("--shared", action="store_true",
                        help="One copy for several OS accounts: group-readable, read-only at run time; needs --account-ports-file")
    parser.add_argument("--account-ports-file", help="Absolute path of the registry that gives each account its two ports")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        result = install(args.source, args.skills_root, args.store, args.dry_run,
                         args.runtime_python, args.venv, args.runtime_root, args.shared, args.account_ports_file)
    except InstallError as exc:
        print(json.dumps({"ok": False, "error": {"code": exc.code, "message": str(exc)}}))
        return 1
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(json.dumps({"ok": False, "error": {"code": "install_error", "message": str(exc)}}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
