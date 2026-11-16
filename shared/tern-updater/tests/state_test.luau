local State = require("../state")
local NOW = 1800000000
local owner = { window = "one", conn = 7, since = 100, route = { socket = "/owned/daemon", config = "/owned/config" } }
local function attempt(two)
	local targets = { { id = "local", kind = "local", label = "local", from = "1.0.0", preview = "1.1.0",
		source = "github.com/example/repo/FIXTURE", phase = "planned" } }
	if two then table.insert(targets, { id = "remote", kind = "remote", label = "remote", from = "1.0.0", preview = "1.1.0",
		source = targets[1].source, phase = "planned" }) end
	return assert(State.begin(owner, "attempt-one", NOW, targets, false))
end
local function evidence(version)
	return { operation = "stopped", installed = { observed = true, id = "fixture", version = version or "1.1.0" },
		requirements = { observed = true, satisfied = true }, host = { observed = true, status = "ready", version = version or "1.1.0" },
		window = { registered = true, version = version or "1.1.0" } }
end
local function observe(record, value, at)
	return assert(State.reconcile(record, at or NOW, { targets = { ["local"] = value } }, "Fixture"))
end
local function install(record)
	return assert(State.command(record, "local", "install", "exact command", NOW,
		{ "/tern", "plugin", "install", record.payload.targets[1].source, "--force", "--json" }))
end
return {
	{ "malformed persisted commands and resolver references stay unexecutable", function()
		local mutations = {
			function(r) r.payload.resolving = "broken" end,
			function(r) r.payload.resolving = { name = "../foreign", kind = "takeover", bytes_base64 = "" } end,
			function(r) r.payload.resolving = { name = "foreign.json", kind = "takeover" } end,
			function(r) r.payload.resolving = { name = "foreign.json", kind = "takeover", bytes_base64 = "", owner_stopped_attested = "yes" } end,
			function(r) r.payload.legacy = "broken" end,
			function(r) r.payload.targets[1].install = true end,
			function(r) r.payload.targets[1].command.argv = { [1] = "/tern", [3] = "install" } end,
			function(r) r.payload.targets[1].command.completed = true end,
			function(r) r.payload.targets[1].route = { socket = 17, config = false } end,
			function(r) r.payload.targets[1].plugins_dir = {} end,
			function(r) r.payload.targets[1].unknown_attempt = "false" end,
		}
		for _, mutate in ipairs(mutations) do
			local record = install(attempt())
			record.phase = "resolving"
			mutate(record)
			assert(not State.valid(record))
			assert(State.target(record, "local") == nil)
		end
	end },
	{ "timeout and clock changes do not release pending ownership", function()
		local record = install(attempt())
		local failed = assert(State.command_result(record, "local", record.attempt, 1,
			{ status = -1, timed_out = true }))
		for _, at in ipairs({ NOW - 100, NOW + State.PENDING_TIMEOUT, NOW + 86400 }) do
			local out = observe(failed, { operation = "unknown" }, at)
			assert(out.payload.targets[1].result == nil and not State.finished(out))
			assert(out.payload.targets[1].install.line == "exact command")
		end
	end },
	{ "changed version is a mismatch, not the preview's success", function()
		local out = observe(install(attempt()), evidence("1.2.0"))
		assert(out.payload.targets[1].result.kind == "mismatch")
		assert(not State.finished(out))
	end },
	{ "the previous version is not proof of unchanged package bytes", function()
		local out = observe(install(attempt()), evidence("1.0.0"), NOW + 86400)
		assert(out.payload.targets[1].phase == "unknown" and out.payload.targets[1].result == nil)
	end },
	{ "exact preview still needs quiescence and each claimed health observation", function()
		local mutations = {
			function(e) e.operation = "running" end,
			function(e) e.operation = "unknown" end,
			function(e) e.requirements.observed = false end,
			function(e) e.requirements.satisfied = false end,
			function(e) e.host.status = "failed" end,
			function(e) e.host.paused = true end,
			function(e) e.host.problems = true end,
			function(e) e.host.version = "1.0.0" end,
			function(e) e.window.registered = false end,
			function(e) e.window.version = "1.0.0" end,
			function(e) e.window.paused = true end,
		}
		for _, mutate in ipairs(mutations) do
			local e = evidence()
			mutate(e)
			assert(observe(install(attempt()), e).payload.targets[1].result == nil)
		end
	end },
	{ "targets settle independently and are retained until their outcomes are presented", function()
		local record = observe(install(attempt(true)), evidence())
		assert(record.payload.targets[1].result.kind == "verified" and record.payload.targets[2].result == nil)
		record = assert(State.presented(record, "local"))
		assert(not State.finished(record))
		record = assert(State.resolve(record, "remote", { operation = "unknown" }, true))
		assert(record.payload.targets[2].result.kind == "resolved_unknown" and not State.finished(record))
		record = assert(State.presented(record, "remote"))
		assert(State.finished(record))
	end },
	{ "an attestation cannot override a positively live installer", function()
		assert(State.resolve(install(attempt()), "local", { operation = "running" }, true) == nil)
		assert(State.resolve(install(attempt()), "local", { operation = "unknown" }, false) == nil)
		assert(State.resolve(install(attempt()), "local", { operation = "stopped" }, false) ~= nil)
	end },
	{ "late and duplicate completions cannot change a newer command", function()
		local record = install(attempt())
		assert(State.command_result(record, "local", "different-attempt", 1, { status = 0 }) == nil)
		record = assert(State.command_result(record, "local", record.attempt, 1, { status = 0 }))
		assert(State.command_result(record, "local", record.attempt, 1, { status = 9 }) == nil)
		record = assert(State.command(record, "local", "catalog", "new observation", NOW + 1))
		assert(State.command_result(record, "local", record.attempt, 1, { status = 9 }) == nil)
		assert(record.payload.targets[1].install.status == 0)
	end },
	{ "resolution cannot launch an installer", function()
		local record = attempt()
		record.phase = "resolving"
		assert(State.command(record, "local", "install", "forbidden", NOW) == nil)
		local observed = assert(State.command(record, "local", "catalog", "read-only", NOW))
		assert(observed.phase == "resolving")
	end },
	{ "write-ahead install intent cannot be relabeled as never started", function()
		assert(State.not_started(attempt(), "local", "preflight refused") ~= nil)
		assert(State.not_started(install(attempt()), "local", "unsafe inference") == nil)
	end },
	{ "reconciliation does not mutate retained input evidence", function()
		local record = install(attempt())
		local bytes = tern.json.encode(record)
		local out = observe(record, evidence())
		assert(tern.json.encode(record) == bytes and record.payload.targets[1].result == nil)
		local shown = assert(State.presented(out, "local"))
		assert(out.payload.targets[1].result.presented == false and shown.payload.targets[1].result.presented == true)
	end },
	{ "check notification deduplication resets only for a different preview", function()
		local record, outcome, notice = State.after_check(nil, NOW, "1.0.0", "1.1.0", nil, "Fixture")
		assert(outcome == "update" and notice ~= nil)
		local _, repeated, duplicate = State.after_check(record, NOW + 1, "1.0.0", "1.1.0", nil, "Fixture")
		assert(repeated == "update" and duplicate == nil)
		local _, changed, fresh = State.after_check(record, NOW + 2, "1.0.0", "1.2.0", nil, "Fixture")
		assert(changed == "update" and fresh ~= nil)
		assert(not State.due(record, NOW + State.INTERVAL - 1) and State.due(record, NOW + State.INTERVAL))
	end },
}
