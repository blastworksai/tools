"""One acquisition owner; UI operations never carry source selectors or commands.

The source Luau bridge alone normalizes canonical identity and publishes through
usage_results/usage_publish. A revision fence binds both ends to the same SPAWN
configuration. Display polling reads this projection; it never queries providers.
"""
from __future__ import annotations

import asyncio
import copy
import hashlib
from pathlib import Path
import shlex
import time

import provider_metadata as helper
from . import profiles
from .protocol import ServiceError, encode, validate_snapshot
from .spawn_roster import read_roster

PREFERENCES = "usage_preferences"
RESULTS = "usage_results"
PUBLICATION = "usage_publication"
# Launch flags that select another config/profile/credential than the default
# context. Only the explicit directory flags below map to a supported selector.
CONTEXT_FLAGS = {"--config-dir": "CLAUDE_CONFIG_DIR", "--codex-home": "CODEX_HOME",
                 "--kimi-code-home": "KIMI_CODE_HOME"}
DENIED_FLAGS = {"--profile", "--config", "--config-file", "--settings", "--settings-file", "--home",
                "--agent-dir", "--api-key", "--auth-token", "--base-url"}


def validate_preferences(payload):
    if not isinstance(payload, dict) or set(payload) - {"refresh_interval_seconds"}:
        raise ServiceError("invalid_request")
    if payload:
        value = payload["refresh_interval_seconds"]
        if type(value) is not int or (value != 0 and not 60 <= value <= 86400):
            raise ServiceError("invalid_request")
    return payload


class Refresh:
    def __init__(self, store, root):
        self.store = store
        # SPAWN's kv.json sits beside USAGE's plugin data directory.
        self.path = Path(root).parent.parent / "spawn" / "kv.json"
        self.job = None
        self.scheduler = None
        self.wake = asyncio.Event()
        self.closed = False
        self.progress = {"state": "idle", "requested_at_ms": 0, "last_completed_ms": 0,
                         "completed": 0, "total": 0, "failures": []}
        saved = store.local_state(RESULTS)
        if saved:
            self.progress["last_completed_ms"] = saved.get("completed_at_ms", 0)

    def preferences(self, payload):
        validate_preferences(payload)
        if payload:
            self.store.set_local_state(PREFERENCES, payload)
            self.wake.set()
        return self.store.local_state(PREFERENCES) or {"refresh_interval_seconds": 0}

    def status(self):
        return copy.deepcopy(self.progress)

    def configuration(self):
        source = self.store.identity()
        roster, definitions = read_roster(self.path, source["device_id"])
        settings = self.store.settings()
        # No metadata, source UID, paths or definition commands leave this module.
        manifest = {"source": source, "enabled": settings["metadata_enabled"], "role": settings["role"],
                    "scopes": [(scope["id"], scope["revision"]) for scope in roster["scopes"]]}
        revision = hashlib.sha256(encode(manifest)).hexdigest()
        return revision, source, roster, definitions

    def _spec(self, item):
        provider = item["provider"]
        kind = profiles.KINDS.get(provider)
        if kind is None:
            raise ServiceError("source_profile_invalid")
        definition = item["definition"]
        # An SSH record runs on another machine; this machine never reads it.
        if definition.get("backend") == "ssh-command":
            raise ServiceError("source_remote")
        if item["source_uid"] is None:
            raise ServiceError("source_profile_invalid")
        # SPAWN records have no environment field; never guess what one selects.
        if "env" in definition or "environment" in definition:
            raise ServiceError("source_context_ambiguous")
        # Inspect the launch command for selectors; never execute it or its arguments.
        command = definition.get("command")
        arguments = list(definition.get("arguments", []))
        if command:
            try:
                words = shlex.split(command) if any(char.isspace() for char in command) else [command]
                if words and words[0].rsplit("/", 1)[-1] == "sudo":
                    index, user = 1, None
                    while index < len(words):
                        option = words[index]
                        index += 1
                        if option == "--":
                            break
                        if option in ("-H", "--set-home", "-n", "--non-interactive"):
                            continue
                        if option in ("-u", "--user") and index < len(words):
                            user = words[index]
                            index += 1
                        elif option.startswith("--user="):
                            user = option.partition("=")[2]
                        else:
                            raise ValueError("Unsupported source user wrapper")
                    if user is None or user not in (definition.get("user"), "#" + item["source_uid"]):
                        raise ValueError("Source user wrapper disagrees with account")
                    words = words[index:]
                if not words:
                    raise ValueError("Missing provider command")
                executable = words[0].replace("\\", "/").rsplit("/", 1)[-1]
                helper.validate_request({"version": 1, "provider": provider, "kind": kind, "command": executable})
                arguments = words[1:] + arguments
            except (ValueError, helper.SafeError):
                raise ServiceError("source_context_ambiguous") from None
        # Context-changing flags must map to a supported profile selector, never guessed.
        selectors = {}
        index = 0
        while index < len(arguments):
            argument = arguments[index]
            flag, separator, value = argument.partition("=")
            if flag in CONTEXT_FLAGS:
                if not separator:
                    index += 1
                    if index >= len(arguments):
                        raise ServiceError("source_context_ambiguous")
                    value = arguments[index]
                selector = CONTEXT_FLAGS[flag]
                if selector not in helper.PROFILE_SELECTORS[kind]:
                    raise ServiceError("source_context_ambiguous")
                selectors[selector] = value
            elif kind == "codex" and flag in {"-c", "--config"}:
                if not separator:
                    index += 1
                    if index >= len(arguments):
                        raise ServiceError("source_context_ambiguous")
                    value = arguments[index]
                key, equals, _ = value.partition("=")
                if not equals or any(part in key.lower() for part in ("auth", "provider", "base_url", "login", "workspace")):
                    raise ServiceError("source_context_ambiguous")
            elif (flag in DENIED_FLAGS or (flag == "-c" and kind != "claude")
                    or (flag == "-p" and kind == "codex")):
                raise ServiceError("source_context_ambiguous")
            index += 1
        # SPAWN alone selects this account's context. No selectors means this
        # verified OS user's default provider context.
        try:
            selectors = helper.validate_selectors(kind, selectors)
        except helper.SafeError:
            raise ServiceError("source_profile_invalid") from None
        spec = {"provider": provider, "kind": kind, "selectors": selectors, "source_uid": item["source_uid"]}
        if definition.get("user"):
            spec["user"] = definition["user"]
        return spec

    def request(self):
        if self.closed:
            raise ServiceError("companion_unavailable", 503)
        if self.job is not None and not self.job.done():
            return self.status()
        if not self.store.settings()["metadata_enabled"]:
            raise ServiceError("source_metadata_disabled", 403)
        configuration = self.configuration()
        # Resolve every local profile selector now, before any awaited provider
        # work. Later configuration changes can only discard the job.
        for item in configuration[3]:
            try:
                item["spec"] = self._spec(item)
            except ServiceError as exc:
                item["error"] = exc.code
        self.progress.update(state="running", requested_at_ms=int(time.time() * 1000),
                             completed=0, total=len(configuration[3]), failures=[])
        self.job = asyncio.create_task(self._run(configuration))
        self.wake.set()
        return self.status()

    async def _run(self, configuration):
        revision, source, roster, definitions = configuration
        results = []
        contexts = {}
        for item in definitions:
            spec = item.get("spec")
            # source_uid already fixes the OS user; the user spelling must not split one context.
            key = ((spec["kind"], spec["source_uid"], encode(spec["selectors"]))
                   if spec is not None else (item["scope_id"], item["id"]))
            contexts.setdefault(key, []).append(item)
        pending = iter(contexts.values())
        async def worker():
            for aliases in pending:
                item = aliases[0]
                try:
                    if "error" in item:
                        raise ServiceError(item["error"])
                    response = await profiles.acquire_usage(self.store, item["spec"])
                except ServiceError as exc:
                    response = {"version": 1, "error": exc.code}
                except Exception:
                    response = {"version": 1, "error": "source_usage_unavailable"}
                usage = response.get("usage", {})
                reason = response.get("error") or usage.get("unavailable_reason")
                if reason is None:
                    reason = next((w["unavailable_reason"] for w in usage.get("windows", []) if "unavailable_reason" in w), None)
                for item in aliases:
                    if reason:
                        self.progress["failures"].append({"account": item["id"], "code": reason})
                    result = {key: item[key] for key in ("scope_id", "id", "provider", "label", "revision")}
                    result["response"] = response
                    results.append(result)
                    self.progress["completed"] += 1
        workers = [asyncio.create_task(worker()) for _ in range(min(2, len(contexts)))]
        try:
            await asyncio.gather(*workers)
            if self.configuration()[0] != revision:
                self.progress["failures"] = [{"code": "source_configuration_changed"}]
                return
            completed = int(time.time() * 1000)
            self.store.set_local_state(RESULTS, {"revision": revision, "items": results, "completed_at_ms": completed})
            self.progress["last_completed_ms"] = completed
        except asyncio.CancelledError:
            for task in workers:
                task.cancel()
            await asyncio.gather(*workers, return_exceptions=True)
            raise
        except ServiceError as exc:
            self.progress["failures"] = [{"code": exc.code}]
        finally:
            self.progress["state"] = "idle"
            self.wake.set()

    def results(self):
        revision, source, roster, definitions = self.configuration()
        if self.store.settings()["role"] == "member":
            return {"disabled": True}
        saved = self.store.local_state(RESULTS) or {}
        items = {(item["scope_id"], item["id"], item["revision"]): item for item in saved.get("items", [])}
        current = []
        for item in definitions:
            value = copy.deepcopy(items.get((item["scope_id"], item["id"], item["revision"])))
            if value is None:
                value = {key: item[key] for key in ("scope_id", "id", "provider", "label", "revision")}
                value["response"] = {"version": 1, "error": "not_yet_measured"}
            elif isinstance(value.get("response"), dict):
                # Results saved by pre-2.0 builds name the reading `native_usage`
                # and carry an always-empty `resets`.
                response = value["response"]
                if "native_usage" in response:
                    response["usage"] = response.pop("native_usage")
                response.pop("resets", None)
            if not self.store.settings()["metadata_enabled"]:
                value["response"] = {"version": 1, "error": "source_metadata_disabled"}
            current.append(value)
        content = {"revision": revision, "source": source, "roster": roster, "items": current}
        token = hashlib.sha256(encode(content)).hexdigest()
        prior = self.store.local_state(PUBLICATION) or {}
        return {**content, "token": token, "previous": prior.get("readings", {}),
                "published_token": prior.get("token", "")}

    def publish(self, payload):
        if not isinstance(payload, dict) or set(payload) != {"token", "snapshot"}:
            raise ServiceError("invalid_request")
        result = self.results()
        if result.get("disabled") or payload["token"] != result["token"]:
            raise ServiceError("source_configuration_changed", 409)
        snapshot = validate_snapshot(payload["snapshot"])
        expected = {(scope["id"], scope["revision"]) for scope in result["roster"]["scopes"]}
        actual = {(scope["id"], scope["revision"]) for scope in snapshot.get("roster", {}).get("scopes", [])}
        if actual != expected:
            raise ServiceError("source_configuration_changed", 409)
        readings = {reading["id"]: reading for reading in snapshot["readings"]}
        with self.store.transaction():
            self.store.local_publish("host", snapshot, replace_inventory=True)
            self.store.set_local_state(PUBLICATION, {"token": result["token"], "readings": readings})
        return {"accepted": True}

    async def start(self):
        self.scheduler = asyncio.create_task(self._schedule())

    async def _schedule(self):
        while not self.closed:
            self.wake.clear()
            interval = self.preferences({})["refresh_interval_seconds"]
            eligible = self.store.settings()["role"] != "member" and self.store.settings()["metadata_enabled"]
            if not interval or not eligible or self.progress["state"] == "running":
                try:
                    await asyncio.wait_for(self.wake.wait(), timeout=5)
                except TimeoutError:
                    pass
                continue
            # Cadence is from the last completed request, not from display polls.
            last = max(self.progress["last_completed_ms"], self.progress["requested_at_ms"])
            delay = interval if not last else max(0, interval - (time.time() - last / 1000))
            try:
                await asyncio.wait_for(self.wake.wait(), timeout=delay)
            except TimeoutError:
                try:
                    self.request()
                except ServiceError as exc:
                    self.progress["failures"] = [{"code": exc.code}]
                    self.progress["requested_at_ms"] = int(time.time() * 1000)

    async def close(self):
        self.closed = True
        tasks = [task for task in (self.scheduler, self.job) if task is not None]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
