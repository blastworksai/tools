# USAGE changelog

## 2.5.4

- The companion now starts when the plugin starts after an install (Linux). The host half creates the private runtime once, without waiting for USAGE Setup. Before, a fresh install stayed on "The local USAGE companion is unavailable." until the owner ran Setup, because the host asked for the runtime without consent to install dependencies and was refused with `dependency_consent_required`. Setup remains the retry road; there is one automatic attempt per plugin load, never a retry loop. macOS and Windows keep the Setup-only road.
- A failed bootstrap now names its cause instead of the generic "unavailable": no PyPI access, no prebuilt wheel for this Python (naming the package and the Python version), a pinned-hash mismatch, a missing `venv`/`ensurepip`, or Python older than 3.11. The companion classifies pip's error into a fixed state and a pattern-checked package pin; raw child output never leaves it. Requests made while the first install runs say that it is installing.
- A check that does not install (the collector poll) no longer replaces the saved cause of a failed install with "not installed"; only a new attempt (Setup) does. A missing `python3-venv` is recognised from the venv step's stdout, where Debian and Ubuntu print it.
- Tests: `test_failed_install_names_its_cause_without_echoing_child_output` (Python) and four companion fixtures (Luau).
