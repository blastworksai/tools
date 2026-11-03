"""Bounded JSON launcher. No third-party imports, shell commands or secret argv."""
import json
from pathlib import Path
import sys

# Set before importing our package, including when invoked without -B from Tern.
sys.dont_write_bytecode = True


def main():
    if sys.version_info < (3, 11):
        print(json.dumps({"ok": False, "error": {"code": "setup_required", "message": "USAGE setup is required."},
                          "state": "python_311_required"}, separators=(",", ":")))
        return 1
    # Detached children use -I: only this immutable package is added back.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    try:
        from usage_service.runtime import main as dispatch
    except Exception:
        print(json.dumps({"ok": False, "error": {"code": "setup_required", "message": "USAGE setup is required."},
                          "state": "package_invalid"}, separators=(",", ":")))
        return 1
    return dispatch()


if __name__ == "__main__":
    raise SystemExit(main())
