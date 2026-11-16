-- Vendored from shared/tern-updater by sync.py; edit there, then run sync.py.
-- Installation, actual requirements, host catalog and this-window registration are
-- independent observations. None is inferred from an install exit code or toast.
local Manifest = require("./manifest")
local Requires = require("./requires")
local Cli = require("./cli")
local Observe = {}

function Observe.package(manifest_bytes, requirement_bytes, requirement_absent, id)
	if type(manifest_bytes) ~= "string" or #manifest_bytes > 65536 then return nil, "Installed manifest is unreadable or oversized" end
	local manifest = Manifest.read(manifest_bytes)
	if manifest.id ~= id or type(manifest.version) ~= "string" then return nil, "Installed manifest identity or version is unavailable" end
	local requirements, err
	if requirement_absent == true then requirements = { plugins = {} }
	elseif type(requirement_bytes) == "string" and #requirement_bytes <= 65536 then requirements, err = Requires.read(requirement_bytes, tern.json.decode)
	else err = "Installed requirements are unreadable or oversized" end
	return { installed = { observed = true, version = manifest.version, id = id }, requirements = requirements, requirements_error = err }
end
function Observe.local_files(plugins_dir, id)
	local root = plugins_dir .. "/" .. id
	local listed, names = pcall(tern.fs.list, root)
	if not listed or type(names) ~= "table" or #names > 4096 then return nil, "Installed package directory is unreadable or oversized" end
	local present, count = {}, 0
	for index, name in pairs(names) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #names or type(name) ~= "string" or present[name] then
			return nil, "Installed package directory listing is incomplete"
		end
		present[name], count = true, count + 1
	end
	if count ~= #names or not present["plugin.toml"] then return nil, "Installed package manifest is missing" end
	local read_manifest, manifest = pcall(tern.fs.read, root .. "/plugin.toml", 65536)
	if not read_manifest then return nil, "Installed package manifest is unreadable" end
	local requirements, requirement_error
	if present["requires.json"] then
		local ok, value = pcall(tern.fs.read, root .. "/requires.json", 65536)
		if ok then requirements = value else requirement_error = "Installed requirements are unreadable" end
	end
	local package, err = Observe.package(manifest, requirements, not present["requires.json"], id)
	if package == nil then return nil, err end
	if requirement_error then package.requirements_error = requirement_error end
	return package
end
function Observe.combine(package, package_error, catalog, catalog_error, version, registration, id)
	local observed = { installed = if package then package.installed else { observed = false, problem = package_error },
		requirements = { observed = false }, host = { observed = false, problem = catalog_error } }
	if catalog ~= nil and catalog.daemon_observed == true then
		local plugin = catalog.plugins[id]
		if plugin ~= nil then
			local hooks = plugin.paused
			observed.host = { observed = true, version = plugin.version, status = plugin.status,
				paused = hooks == true or (type(hooks) == "table" and next(hooks) ~= nil),
				hooks_observed = hooks == nil or type(hooks) == "table", problems = catalog.problems }
		end
	end
	if package and package.requirements then
		local problem = if catalog then Requires.check(package.requirements, Requires.tern_version(version), catalog.versions)
			else "Installed requirements cannot be checked without the target's catalog"
		observed.requirements = { observed = true, satisfied = problem == nil, problem = problem, actual = package.requirements }
	elseif package then observed.requirements.problem = package.requirements_error end
	if registration ~= nil then
		observed.window = { registered = registration.registered == true, version = registration.version, paused = next(registration.paused or {}) ~= nil }
	end
	return observed
end
-- Persisted clocks/labels cannot prove that a callback ran in this VM. Only
-- this live registration's exact completed-install object supplies that fact.
function Observe.completed_here(install, registration)
	return type(install) == "table" and registration ~= nil and install == registration.completed_install
		and install.completed == true and install.completion == "native_callback" and install.timed_out ~= true
end
function Observe.local_target(info, id, target, registration, cx, cb)
	local route, directory = target.route or info.owner.route, target.plugins_dir or info.plugins_dir
	Cli.catalog(info.exe, route, function(catalog, catalog_error, catalog_cx)
		Cli.tern_version(info.exe, route, function(version, _, version_cx)
			local now = version_cx or catalog_cx or cx
			local package, package_error = Observe.local_files(directory, id)
			local observed = Observe.combine(package, package_error, catalog, catalog_error, version, registration, id)
			local install = target.install
			if Observe.completed_here(install, registration) then
				observed.operation, observed.operation_evidence = "stopped", "same_vm_native_completion"
				cb(observed, now)
			elseif install and install.spawn_failed then
				observed.operation, observed.operation_evidence = "stopped", "native_spawn_failure"
				cb(observed, now)
			else
				local command = install or target.command
				if command == nil or command.kind ~= "install" or type(command.argv) ~= "table" then
					observed.operation, observed.reason = "unknown", "No native installer argv was retained"
					cb(observed, now)
					return
				end
				Cli.processes(now, command.argv, command.identity, function(operation, fresh)
					observed.operation, observed.operation_evidence = operation.operation, operation.evidence
					observed.process_identity, observed.reason = operation.identity, operation.reason
					cb(observed, fresh or now)
				end)
			end
		end)
	end)
end
function Observe.unknown(info, id, registration, cx, cb)
	Observe.local_target(info, id, {}, registration, cx, function(observed, fresh)
		Cli.processes(fresh, nil, nil, function(operation, current)
			observed.local_operation = operation
			observed.operation = if operation.operation == "running" then "running" else "unknown"
			observed.reason = "Only local installer processes were observed; missing remote targets remain unverified"
			cb(observed, current or fresh)
		end)
	end)
end
return Observe
