local Observe = require("../observe")
local Cli = require("../cli")
local State = require("../state")
local MANIFEST = 'id = "fixture"\nname = "Fixture"\nversion = "1.1.0"\n'
local function catalog(dependency, status)
	local plugins = { { id = "fixture", version = "1.1.0", status = status or "ready" } }
	if dependency then table.insert(plugins, { id = "dependency", version = dependency, status = "ready" }) end
	local value = assert(Cli.parse_catalog({ plugins = plugins, problems = {} }))
	value.daemon_observed = true
	return value
end
local function pending()
	local owner = { window = "one", conn = 1, since = 100, route = { socket = false, config = false } }
	local record = assert(State.begin(owner, "attempt", 100, {
		{ id = "local", kind = "local", label = "this machine", from = "1.0.0", preview = "1.1.0", source = "fixed-source", phase = "planned" },
	}, false))
	return assert(State.command(record, "local", "install", "exact install", 101))
end
local function reconcile(package, cat, registration, tern_version)
	local observed = Observe.combine(package, nil, cat, nil, tern_version or "tern 1.0.0", registration, "fixture")
	observed.operation = "stopped"
	return assert(State.reconcile(pending(), 102, { targets = { ["local"] = observed } }, "Fixture")).payload.targets[1]
end
local function process(pid, started, argv)
	return { pid = pid, started = started, command = argv }
end
local ARGV = { "/bin/tern", "plugin", "install", "fixed-source", "--force", "--json" }
local function inventory(processes, more)
	return { ["local"] = true, processes = processes, sample = 100, total = #processes, more = more or 0 }
end
return {
	{ "reload cannot turn a persisted callback label into live completion proof", function()
		local install = { completed = true, completion = "native_callback", timed_out = false, callback_vm = "0.000030" }
		assert(not Observe.completed_here(install, { vm = "0.000030" }))
		local registration = { completed_install = install }
		assert(Observe.completed_here(install, registration))
		assert(not Observe.completed_here(table.clone(install), registration))
		assert(not Observe.completed_here(install, {}))
		install.timed_out = true
		assert(not Observe.completed_here(install, registration))
	end },
	{ "actual mutable requirements override an earlier successful preview", function()
		local registration = { registered = true, version = "1.1.0", paused = {} }
		local before = assert(Observe.package(MANIFEST, '{"schema":1,"plugins":{"dependency":"1.0.0"}}', false, "fixture"))
		assert(reconcile(before, catalog("1.0.0"), registration).result.kind == "verified")
		local moved = assert(Observe.package(MANIFEST, '{"schema":1,"plugins":{"dependency":"2.0.0"}}', false, "fixture"))
		assert(reconcile(moved, catalog("1.0.0"), registration).result == nil)
		assert(reconcile(moved, catalog("2.0.0"), registration).result.kind == "verified")
	end },
	{ "missing dependency and insufficient native runtime keep installation unverified", function()
		local registration = { registered = true, version = "1.1.0", paused = {} }
		local package = assert(Observe.package(MANIFEST, '{"schema":1,"tern":"2.0.0","plugins":{"dependency":"1.0.0"}}', false, "fixture"))
		assert(reconcile(package, catalog("1.0.0"), registration, "tern 1.0.0").result == nil)
		assert(reconcile(package, catalog(nil), registration, "tern 2.0.0").result == nil)
		assert(reconcile(package, catalog("1.0.0"), registration, "tern 2.0.0").result.kind == "verified")
	end },
	{ "unreadable or malformed requirements are not treated as absent", function()
		local registration = { registered = true, version = "1.1.0", paused = {} }
		for _, bytes in ipairs({ "{broken", '{"schema":2}', string.rep("x", 65537) }) do
			local package = assert(Observe.package(MANIFEST, bytes, false, "fixture"))
			assert(reconcile(package, catalog(nil), registration).result == nil)
		end
		local unreadable = assert(Observe.package(MANIFEST, nil, false, "fixture"))
		assert(reconcile(unreadable, catalog(nil), registration).result == nil)
		local absent = assert(Observe.package(MANIFEST, nil, true, "fixture"))
		assert(reconcile(absent, catalog(nil), registration).result.kind == "verified")
	end },
	{ "a catalog cannot substitute for this window's registration or actual package identity", function()
		local package = assert(Observe.package(MANIFEST, nil, true, "fixture"))
		assert(reconcile(package, catalog(nil), nil).result == nil)
		assert(reconcile(package, catalog(nil), { registered = true, version = "1.0.0" }).result == nil)
		assert(Observe.package(MANIFEST, nil, true, "different-plugin") == nil)
		assert(Observe.package(string.rep("x", 65537), nil, true, "fixture") == nil)
	end },
	{ "host failures and paused hooks remain independent of package and window success", function()
		local package = assert(Observe.package(MANIFEST, nil, true, "fixture"))
		local registration = { registered = true, version = "1.1.0", paused = {} }
		assert(reconcile(package, catalog(nil, "failed"), registration).result == nil)
		local paused = catalog(nil)
		paused.plugins.fixture.paused = { "timer" }
		assert(reconcile(package, paused, registration).result == nil)
		assert(reconcile(package, catalog(nil), { registered = true, version = "1.1.0", paused = { tick = true } }).result == nil)
	end },
	{ "manifest-only ready without a running daemon is not host load proof", function()
		local package = assert(Observe.package(MANIFEST, nil, true, "fixture"))
		local manifest_only = catalog(nil)
		manifest_only.daemon_observed = nil
		local out = reconcile(package, manifest_only, { registered = true, version = "1.1.0", paused = {} })
		assert(out.result == nil and out.observed.host.observed == false)
	end },
	{ "ambiguous catalogs cannot prove package or dependency health", function()
		assert(Cli.parse_catalog({ plugins = { { id = "fixture", version = "1.1.0" }, { id = "fixture", version = "1.0.0" } } }) == nil)
		assert(Cli.parse_catalog({ plugins = {}, truncated = true }) == nil)
		assert(Cli.parse_catalog({ plugins = {}, problems = "unreadable" }) == nil)
	end },
	{ "live installer evidence wins even when the process list is incomplete", function()
		local data = inventory({ process(20, 10, {}), process(21, 11, ARGV) }, 7)
		local observed = Cli.process_inventory(data, ARGV, nil)
		assert(observed.operation == "running" and observed.identity.pid == 21 and observed.identity.started == 11)
	end },
	{ "absence requires complete readable process identities", function()
		local rows = { process(30, 20, { "/bin/sh" }) }
		assert(Cli.process_inventory(inventory(rows), ARGV, nil).operation == "stopped")
		assert(Cli.process_inventory(inventory(rows, 1), ARGV, nil).operation == "unknown")
		assert(Cli.process_inventory(inventory({ process(30, 20, {}) }), ARGV, nil).operation == "unknown")
		assert(Cli.process_inventory(inventory({ rows[1], rows[1] }), ARGV, nil).operation == "unknown")
	end },
	{ "reused PID is not the recorded installer incarnation", function()
		local rows = { process(30, 21, { "/bin/sh" }) }
		assert(Cli.process_inventory(inventory(rows), ARGV, { pid = 30, started = 20 }).operation == "stopped")
		assert(Cli.process_inventory(inventory(rows), ARGV, { pid = 30, started = 21 }).operation == "running")
	end },
	{ "unknown-attempt scans still retain positive installer evidence", function()
		assert(Cli.process_inventory(inventory({ process(31, 20, ARGV) }), nil, nil).operation == "running")
		local different_shape = { "/bin/tern", "plugin", "install", "--force", "fixed-source" }
		assert(Cli.process_inventory(inventory({ process(32, 20, different_shape) }), ARGV, nil).operation == "unknown")
	end },
}
