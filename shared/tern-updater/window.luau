-- Window-owned updater operations. Every effect is preceded by a verified file;
-- reloads observe pending work and never repeat an uncertain install.
local Manifest = require("./manifest")
local Source = require("./source")
local Requires = require("./requires")
local Confirm = require("./confirm")
local State = require("./state")
local Journal = require("./journal")
local Cli = require("./cli")
local Observe = require("./observe")
local Remote = require("./remote")
local Discovery = require("./discovery")
local Updater = {}
local FETCH = { timeout_ms = 10000, headers = { ["Cache-Control"] = "no-cache" } }

function Updater.register(cfg)
	if tern.runtime.os == "ios" or tern.context ~= "window" then return end
	assert(type(cfg) == "table" and type(cfg.name) == "string" and cfg.name ~= "", "updater name is required")
	assert(Source.valid_dir(cfg.dir), "updater source folder is invalid")
	assert(cfg.background_ready == nil or type(cfg.background_ready) == "function", "updater background readiness must be a function")
	local name, dir, id = cfg.name, cfg.dir, tern.plugin.id
	local prefix = cfg.title_prefix or name .. " "
	local read_ok, manifest = pcall(tern.fs.read, tern.plugin.dir .. "/plugin.toml", 65536)
	local registration = { registered = false, version = if read_ok then Manifest.read(manifest).version else nil,
		paused = {} }
	local latest = { outcome = "none", dev = nil, busy = true }
	local cache, sequence, working = {}, 0, false
	local token_prefix = string.format("%.6f", tern.now())
	local function token()
		sequence += 1
		return token_prefix .. ":" .. tostring(sequence)
	end
	local function say(cx, level, text, sub)
		if cx ~= nil then pcall(cx.toast, cx, level, text, sub) end
		tern.log.info("updater notice", level, text, sub or "")
	end
	local function stop(cx, err)
		working = false
		say(cx, "error", name .. " updater stopped", err)
	end
	local function legacy()
		local ok, value = pcall(tern.kv.get, Journal.LEGACY_KEY)
		if not ok then return nil, "Legacy updater state is unreadable" end
		return value
	end
	local function scan(job)
		local value, err = legacy()
		local rows, scan_error = job.store.scan()
		latest.busy = err ~= nil or scan_error ~= nil or Journal.legacy_pending(value) or (rows ~= nil and #rows > 0)
		return rows, err or scan_error, value
	end
	local function info(cx, cb)
		Cli.executable(function(exe, err, executable_cx)
			local now = executable_cx or cx
			if exe == nil then cb(nil, err, now); return end
			Cli.identity(exe, now, function(owner, identity_error, identity_cx)
				local current = identity_cx or now
				if owner == nil then cb(nil, identity_error, current); return end
				Cli.plugins_dir(exe, owner.route, function(plugins_dir, directory_error, directory_cx)
					local fresh = directory_cx or current
					if plugins_dir == nil then cb(nil, directory_error, fresh); return end
					local dev, link_error = Cli.linked(plugins_dir, id)
					if dev == nil then cb(nil, link_error, fresh); return end
					local store, store_error = Journal.open(tern.plugin.data, owner, tern.fs, tern.json.encode, tern.json.decode)
					if store == nil then cb(nil, store_error, fresh); return end
					local prepared, preparation_error = store.prepare()
					if not prepared then cb(nil, preparation_error, fresh); return end
					tern.log.info("updater plugin dir", tern.plugin.dir)
					tern.log.info("updater plugins dir", plugins_dir)
					latest.dev = dev
					cb({ info = { exe = exe, owner = owner, plugins_dir = plugins_dir, dev = dev }, store = store }, nil, fresh)
				end)
			end)
		end)
	end
	local function save(job, record, cx, err)
		if record == nil then stop(cx, err or "Invalid updater transition"); return false end
		local handle, problem = job.store.advance(job.handle, record)
		if handle == nil then stop(cx, problem); return false end
		job.handle = handle
		latest.busy = true
		return true
	end
	local function patch(job, target, values, cx)
		local record, err = State.patch_target(job.handle.record, target, values)
		return save(job, record, cx, err)
	end
	local function present(job, cx)
		for _, target in ipairs(job.handle.record.payload.targets) do
			if target.result ~= nil and target.result.presented ~= true then
				local result = target.result
				say(cx, if result.kind == "verified" then "success" elseif result.kind == "not_updated" then "info" else "error",
					result.text, (result.detail or "") .. (if job.handle.record.payload.orch then ". " .. State.ORCH else ""))
				local record, err = State.presented(job.handle.record, target.id)
				if not save(job, record, cx, err) then return false end
			end
		end
		return true
	end
	local function finish(job, cx)
		if not present(job, cx) then return end
		if State.finished(job.handle.record) and job.handle.record.payload.resolving == nil and job.handle.record.payload.legacy == nil then
			local removed, err = job.store.remove(job.handle)
			if not removed then stop(cx, err); return end
			job.handle = nil
		else
			local details = {}
			for _, target in ipairs(job.handle.record.payload.targets) do
				if target.result == nil then
					local installed = target.observed and target.observed.installed
					local version = if type(installed) == "table" and installed.observed == true
						then installed.version else "unobserved"
					table.insert(details, target.label .. ": preview " .. tostring(target.preview)
						.. ", installed " .. tostring(version) .. "; " .. (target.reason or "Outcome unverified"))
				end
			end
			table.insert(details, "Use Resolve update outcome; no install will be retried automatically")
			say(cx, "info", name .. " has an unresolved update outcome", table.concat(details, "\n"))
		end
		scan(job)
		working = false
	end
	local function fetch(url, optional, cx, cb)
		local ok, err = pcall(tern.fetch, url, FETCH, function(result, fresh)
			if optional and result.error == nil and result.status == 404 then cb(false, nil, fresh or cx); return end
			if result.error ~= nil or result.status ~= 200 or type(result.body) ~= "string" or #result.body > 65536 then
				cb(nil, "Published metadata is unavailable or exceeds its bound", fresh or cx); return
			end
			cb(result.body, nil, fresh or cx)
		end)
		if not ok then cb(nil, "Couldn't fetch published metadata: " .. tostring(err):sub(1, 160), cx) end
	end
	local function preview(cx, cb)
		fetch(Source.manifest_url(dir), false, cx, function(bytes, err, fresh)
			if bytes == nil then cb(nil, nil, err, fresh); return end
			local remote = Manifest.read(bytes)
			if remote.id ~= id or remote.version == nil then cb(nil, nil, "Published plugin identity or version is invalid", fresh); return end
			fetch(Source.requires_url(dir), true, fresh, function(requirement_bytes, requirement_error, current)
				if requirement_bytes == nil then cb(nil, nil, requirement_error, current); return end
				local req, problem
				if requirement_bytes == false then req = { plugins = {} } else req, problem = Requires.read(requirement_bytes, tern.json.decode) end
				cb(remote.version, req, problem, current)
			end)
		end)
	end
	local function check(job, cx, notify, cb)
		local package, package_error = Observe.local_files(job.info.plugins_dir, id)
		if package == nil then cb(nil, nil, nil, package_error, cx); return end
		preview(cx, function(remote, requirements, err, fresh)
			local notice, outcome
			cache, outcome, notice = State.after_check(cache, os.time(), package.installed.version, remote, err, name)
			latest.outcome = outcome
			if err == nil and notify then
				if outcome == "update" then say(fresh, "info", name .. " " .. remote .. " is available", "Installed: " .. package.installed.version)
				elseif outcome == "current" then say(fresh, "info", name .. " reports version " .. package.installed.version, "Same-version package bytes are not verified")
				elseif outcome == "ahead" then say(fresh, "info", name .. " is newer than the published preview", package.installed.version .. " versus " .. remote)
				else say(fresh, "error", "Can't compare installed and published versions") end
			elseif err == nil and notice then say(fresh, notice.level, notice.text, notice.sub) end
			cb(remote, requirements, package, err, fresh)
		end)
	end
	local function not_started(job, target_id, reason, cx)
		local record, err = State.not_started(job.handle.record, target_id, reason)
		return save(job, record, cx, err)
	end
	local function observe_result(job, target_id, observed, cx)
		local record, err = State.reconcile(job.handle.record, os.time(), { targets = { [target_id] = observed } }, name)
		return save(job, record, cx, err)
	end
	local function remote_command(job, target_id, kind, line, argv, encoded, cx, cb)
		local target = State.target(job.handle.record, target_id)
		local ready, ready_error = Remote.ready(cx, target)
		if ready == nil then cb(nil, ready_error, cx); return end
		local record, err = State.command(job.handle.record, target_id, kind, line, os.time(), argv)
		if record == nil then cb(nil, err, cx); return end
		State.target(record, target_id).command.encoded_output = encoded == true
		if not save(job, record, cx) then return end
		target = State.target(job.handle.record, target_id)
		local command, attempt = target.command, job.handle.record.attempt
		local typed, typing_error = pcall(cx.run, cx, target.pane, line .. "\r")
		if not typed then cb(nil, "Journaled command may have started: " .. tostring(typing_error):sub(1, 160), cx); return end
		Remote.await(cx, target, command, encoded, function(result, problem, fresh)
			if result == nil then cb(nil, problem, fresh); return end
			local next_record, transition_error = State.command_result(job.handle.record, target_id, attempt, command.serial, result)
			if not save(job, next_record, fresh, transition_error) then return end
			cb(result, nil, fresh)
		end)
	end
	local function remote_argv(job, target_id, kind, argv, encoded, cx, cb)
		local target = State.target(job.handle.record, target_id)
		local line, err = Remote.command(target.platform, argv, token(), encoded)
		if line == nil then cb(nil, err, cx); return end
		remote_command(job, target_id, kind, line, argv, encoded, cx, cb)
	end
	local function remote_observe(job, target_id, cx, cb)
		local target = State.target(job.handle.record, target_id)
		local exe = if target.platform.os == "windows" then "tern.exe" else "tern"
		remote_argv(job, target_id, "version", { exe, "--version" }, true, cx, function(version, err, fresh)
			if version == nil or not Cli.complete(version) then cb(nil, err or "Remote Tern version is unavailable", fresh); return end
			remote_argv(job, target_id, "directory", { exe, "plugin", "dir", "--json" }, true, fresh, function(directory, directory_error, current)
				local value, decode_error = Cli.json(directory)
				if value == nil or not Discovery.absolute(value.dir) then cb(nil, directory_error or decode_error or "Remote plugin directory is invalid", current); return end
				if not patch(job, target_id, { plugins_dir = value.dir }, current) then return end
				remote_argv(job, target_id, "catalog", { exe, "plugin", "list", "--json" }, true, current, function(result, catalog_error, catalog_cx)
					local data, data_error = Cli.json(result)
					local catalog, parse_error = Cli.parse_catalog(data)
					if catalog == nil then cb(nil, catalog_error or data_error or parse_error, catalog_cx); return end
					remote_argv(job, target_id, "inspect", { exe, "inspect", "--json" }, true, catalog_cx, function(inventory, inventory_error, inventory_cx)
						local windows, inspect_error = Journal.inventory(inventory, tern.json.decode)
						if windows == nil then cb(nil, inventory_error or inspect_error, inventory_cx); return end
						catalog.daemon_observed = true
						target = State.target(job.handle.record, target_id)
						local line, line_error = Remote.files_command(target.platform, target.plugins_dir, id, token())
						if line == nil then cb(nil, line_error, inventory_cx); return end
						remote_command(job, target_id, "package", line, nil, false, inventory_cx, function(files, files_error, files_cx)
							local package, package_error = Remote.files(files, id)
							if package == nil then cb(nil, files_error or package_error, files_cx); return end
							local observed = Observe.combine(package, nil, catalog, nil, version.stdout, nil, id)
							observed.operation, observed.operation_evidence = "stopped", "exact_native_terminal_completion"
							cb({ observed = observed, package = package, catalog = catalog, version = version.stdout }, nil, files_cx)
						end)
					end)
				end)
			end)
		end)
	end
	local function remote_recover(job, target_id, cx, cb)
		local target = State.target(job.handle.record, target_id)
		if target.install == nil then cb({ operation = "unknown", reason = "No remote install was journaled" }, cx); return end
		local function observe(fresh)
			remote_observe(job, target_id, fresh, function(result, err, current)
				cb(if result then result.observed else { operation = "unknown", reason = err }, current)
			end)
		end
		local command = target.command
		if command and command.completed ~= true then
			Remote.await(cx, target, command, command.encoded_output == true, function(result, err, fresh)
				if result == nil then
					local _, _, state = Remote.completion(fresh, target, command)
					cb({ operation = state or "unknown", reason = err }, fresh); return
				end
				local record, problem = State.command_result(job.handle.record, target_id, job.handle.record.attempt, command.serial, result)
				if not save(job, record, fresh, problem) then return end
				observe(fresh)
			end)
		else observe(cx) end
	end
	local function observe_target(job, target_id, cx, cb)
		local target = State.target(job.handle.record, target_id)
		if target.kind == "local" then Observe.local_target(job.info, id, target, registration, cx, cb)
		else remote_recover(job, target_id, cx, cb) end
	end
	local function recover(job, cx, index)
		index = index or 1
		local target = job.handle.record.payload.targets[index]
		if target == nil then finish(job, cx); return end
		if target.result ~= nil then recover(job, cx, index + 1); return end
		if target.install == nil then
			if not not_started(job, target.id, "Window reloaded before an install command was journaled; no install was replayed", cx) then return end
			recover(job, cx, index + 1)
			return
		end
		observe_target(job, target.id, cx, function(observed, fresh)
			if not observe_result(job, target.id, observed, fresh) then return end
			recover(job, fresh, index + 1)
		end)
	end
	local function launch_local(job, cx)
		local target = State.target(job.handle.record, "local")
		local argv = Cli.install_argv(job.info.exe, target.source)
		local record, err = State.command(job.handle.record, "local", "install", tern.json.encode(argv), os.time(), argv)
		if not save(job, record, cx, err) then return end
		local command, attempt = State.target(job.handle.record, "local").command, job.handle.record.attempt
		say(cx, "info", "Installing the latest repository copy of " .. name, "Preview: " .. target.preview .. "; actual installed version and load state will be observed separately")
		Cli.install(job.info.exe, target.source, job.info.owner.route, function(result, fresh)
			local now = fresh or cx
			local next_record, problem = State.command_result(job.handle.record, "local", attempt, command.serial, result)
			if not save(job, next_record, now, problem) then return end
			registration.completed_install = State.target(job.handle.record, "local").install
			Observe.local_target(job.info, id, State.target(job.handle.record, "local"), registration, now, function(observed, observed_cx)
				registration.completed_install = nil
				if not observe_result(job, "local", observed, observed_cx) then return end
				finish(job, observed_cx)
			end)
		end)
	end
	local function local_install(job, cx)
		local target = State.target(job.handle.record, "local")
		local function refuse(reason, fresh)
			if not not_started(job, "local", reason, fresh) then return end
			finish(job, fresh)
		end
		local dev, dev_error = Cli.linked(job.info.plugins_dir, id)
		local old, old_error = legacy()
		if dev ~= false or old_error ~= nil or Journal.legacy_pending(old) then
			refuse(dev_error or old_error or "Development link or legacy pending state appeared before installation", cx)
			return
		end
		Cli.catalog(job.info.exe, job.info.owner.route, function(catalog, err, catalog_cx)
			local now = catalog_cx or cx
			if catalog == nil then refuse(err, now); return end
			Cli.tern_version(job.info.exe, job.info.owner.route, function(version, version_error, version_cx)
				local fresh = version_cx or now
				local problem = version_error or Requires.check(target.preview_requirements, Requires.tern_version(version), catalog.versions)
				if problem ~= nil then refuse(problem, fresh); return end
				local package, package_error = Observe.local_files(job.info.plugins_dir, id)
				if package == nil then refuse(package_error, fresh); return end
				if package.installed.version ~= target.from then
					refuse("Installed version changed after confirmation; a fresh preview and decision are required", fresh)
					return
				end
				launch_local(job, fresh)
			end)
		end)
	end
	local function remote_install(job, requirements, cx)
		local target = job.handle.record.payload.targets[1]
		local function skip(reason, fresh)
			if not not_started(job, target.id, reason, fresh) then return end
			if not present(job, fresh) then return end
			local_install(job, fresh)
		end
		local host, host_error = Remote.host(cx, target.host)
		if host == nil then skip(host_error, cx); return end
		local opened, pane = pcall(cx.hosts.terminal, cx.hosts, host.id)
		if not opened or type(pane) ~= "number" then skip("Couldn't open a native terminal on the selected host", cx); return end
		if not patch(job, target.id, { pane = pane }, cx) then return end
		local waiting, wait_error = pcall(function()
			cx.session:settle(pane, 30000):next(function(_, ready_error, fresh)
				local now = fresh or cx
				if ready_error ~= nil then skip("Remote terminal did not reach its initial prompt", now); return end
				target = State.target(job.handle.record, target.id)
				local ready, problem = Remote.ready(now, target)
				if ready == nil then skip(problem, now); return end
				local platform, platform_error = Remote.platform(ready.program)
				if platform == nil then skip(platform_error, now); return end
				if not patch(job, target.id, { platform = platform }, now) then return end
				remote_command(job, target.id, "probe", "tern --version", { "tern", "--version" }, false, now, function(probe, probe_error, probe_cx)
					if probe == nil or not Cli.complete(probe) or Requires.tern_version(probe.stdout) == nil then skip(probe_error or "Native command completion is not observable on this host", probe_cx); return end
					remote_observe(job, target.id, probe_cx, function(result, observation_error, observed_cx)
						if result == nil then skip(observation_error, observed_cx); return end
						local requirement_error = Requires.check(requirements, Requires.tern_version(result.version), result.catalog.versions)
						if requirement_error ~= nil then skip(requirement_error, observed_cx); return end
						local from = result.package.installed.version
						if not patch(job, target.id, { from = from, preview_requirements = requirements }, observed_cx) then return end
						local outcome = State.outcome({ remote = target.preview }, from)
						if outcome ~= "update" then skip("Target version " .. from .. " does not require this preview; no replacement or byte-identity claim", observed_cx); return end
						remote_argv(job, target.id, "git", { "git", "--version" }, true, observed_cx, function(git, git_error, git_cx)
							if git == nil or not Cli.complete(git) then skip(git_error or "Git is unavailable on the remote target", git_cx); return end
							local exe = if platform.os == "windows" then "tern.exe" else "tern"
							remote_argv(job, target.id, "install", Cli.install_argv(exe, target.source), false, git_cx, function(installed_result, install_error, installed_cx)
								if installed_result == nil then
									if not patch(job, target.id, { phase = "unknown", reason = install_error }, installed_cx) then return end
									say(installed_cx, "error", "Remote update outcome is unverified", "The command will not be retyped; local installation remains separately approved")
									local_install(job, installed_cx); return
								end
								remote_observe(job, target.id, installed_cx, function(after, after_error, after_cx)
									local observed = if after then after.observed else { operation = "unknown", reason = after_error }
									if not observe_result(job, target.id, observed, after_cx) then return end
									if not present(job, after_cx) then return end
									local_install(job, after_cx)
								end)
							end)
						end)
					end)
				end)
			end)
		end)
		if not waiting then skip("Remote terminal readiness is unavailable: " .. tostring(wait_error):sub(1, 160), cx) end
	end
	local function begin(job, item, host, remote, requirements, package, orch, cx)
		local targets = {}
		if item.choice == "remote" then
			table.insert(targets, { id = "remote", kind = "remote", label = host.name, host = host,
				source = Source.install_src(dir), preview = remote, from = "unknown", phase = "planned" })
		end
		table.insert(targets, { id = "local", kind = "local", label = "this machine", source = Source.install_src(dir),
			preview = remote, from = package.installed.version, phase = "planned", preview_requirements = requirements,
			plugins_dir = job.info.plugins_dir, route = job.info.owner.route, exe = job.info.exe })
		local record, err = State.begin(job.info.owner, token(), os.time(), targets, orch)
		if record == nil then stop(cx, err); return end
		job.handle, err = job.store.claim(record)
		if job.handle == nil then stop(cx, err); return end
		local old, old_error = legacy()
		if old_error ~= nil or Journal.legacy_pending(old) then
			local removed, removal_error = job.store.remove(job.handle)
			stop(cx, old_error or (if removed then "Legacy updater outcome must be resolved first" else removal_error)); return
		end
		latest.busy = true
		if host ~= nil then remote_install(job, requirements, cx) else local_install(job, cx) end
	end
	local function run_update(cx)
		if working then say(cx, "info", "An updater interaction is already open in this window"); return end
		working = true
		info(cx, function(job, err, fresh)
			if job == nil then stop(fresh, err); return end
			local _, scan_error = scan(job)
			if scan_error ~= nil or latest.busy then stop(fresh, scan_error or "Resolve the existing update outcome before another install"); return end
			if job.info.dev then stop(fresh, "This is a development copy; update it from its source folder"); return end
			check(job, fresh, false, function(remote, requirements, package, check_error, current)
				if check_error ~= nil then stop(current, check_error); return end
				if latest.outcome ~= "update" then working = false; say(current, "info", "No newer comparable preview is available"); return end
				Cli.catalog(job.info.exe, job.info.owner.route, function(catalog, catalog_error, catalog_cx)
					if catalog == nil then stop(catalog_cx or current, catalog_error); return end
					Cli.tern_version(job.info.exe, job.info.owner.route, function(version, version_error, version_cx)
						local now = version_cx or catalog_cx or current
						local problem = version_error or Requires.check(requirements, Requires.tern_version(version), catalog.versions)
						if problem ~= nil then stop(now, problem); return end
						Cli.git_available(job.info.owner.route, function(has_git, git_cx)
							local ready = git_cx or now
							if not has_git then stop(ready, "Updating needs Git on this machine"); return end
							local hosts, remotes = {}, {}
							local listed, values = pcall(ready.hosts.list, ready.hosts)
							if listed then
								for _, value in ipairs(values) do
									local snapshot = Remote.snapshot(value)
									if snapshot then hosts[snapshot.id] = snapshot; table.insert(remotes, { id = snapshot.id, name = snapshot.name }) end
								end
							end
							local orch = catalog.plugins.orchplus ~= nil
							ready:pick({ items = Confirm.items({ name = name, from = package.installed.version, to = remote, orch = orch, remotes = remotes }),
								placeholder = "Update " .. name .. "?", icon = "download" }):next(function(item, picker_error, picked)
								if item == nil or item.choice == "cancel" then working = false; return end
								if picker_error ~= nil then stop(picked, tostring(picker_error)); return end
								local host = if item.choice == "remote" then hosts[item.host] else nil
								if item.choice == "remote" and host == nil then stop(picked, "Selected remote host is no longer identifiable"); return end
								begin(job, item, host, remote, requirements, package, orch, picked)
							end)
						end)
					end)
				end)
			end)
		end)
	end

	local function owner_status(job, row, cx, cb)
		local owner = if row.record then row.record.owner else Journal.owner_hint(row.name, job.info.owner.route)
		if owner == nil then cb("unknown", cx); return end
		if Journal.same_owner(owner, job.info.owner) then cb("self", cx); return end
		Cli.inspect(job.info.exe, owner.route, function(rows, _, fresh)
			local status = Journal.owner_status(owner, owner.route, rows)
			cb(if row.record == nil and status ~= "live" then "unknown" else status, fresh or cx)
		end)
	end
	local function resolution_scan(job, allowed, cx)
		local rows, err = job.store.scan()
		if rows == nil then stop(cx, err); return false end
		for _, row in ipairs(rows) do
			if row.name ~= job.store.name and not allowed[row.name] then
				stop(cx, "Another unresolved updater file blocks this resolution: " .. row.name)
				return false
			end
		end
		return true
	end
	local function migrate_legacy(job, cx, cb)
		if job.handle.record.payload.legacy == nil then cb(cx); return end
		local current, err = legacy()
		if err ~= nil then stop(cx, err); return end
		if Journal.legacy_pending(current) then
			local opened, pane = pcall(cx.new_block, cx, id .. ".updater-recovery",
				{ job.handle.name, job.handle.record.attempt }, "tab")
			if not opened or pane == nil then
				stop(cx, "Native host migration is unavailable; legacy KV and its adopted file remain held")
				return
			end
			say(cx, "info", "Host-owned legacy migration opened",
				"After the host confirms removal, use Resolve update outcome again; the saved attestation is retained")
			working = false
			return
		end
		local record = table.clone(job.handle.record)
		record.revision += 1
		record.payload = table.clone(record.payload)
		record.payload.legacy = nil
		if not save(job, record, cx) then return end
		cb(cx)
	end
	local function remove_original(job, original, owner_attested, cx)
		owner_status(job, original, cx, function(status, fresh)
			if status == "live" then stop(fresh, "The original owner is live; resolve this attempt in its original window"); return end
			if status == "unknown" and owner_attested ~= true then stop(fresh, "Original owner absence is unproven; its file was preserved"); return end
			if not present(job, fresh) then return end
			if original.name == job.store.name then original = job.handle end
			if original.missing then
				local rows, err = job.store.scan()
				if rows == nil then stop(fresh, err); return end
				for _, row in ipairs(rows) do
					if row.name == original.name then stop(fresh, "The original updater file reappeared; both records were preserved"); return end
				end
			else
				local removed, err = job.store.remove(original, { outcome = true, owner_status = status, owner_stopped_attested = owner_attested })
				if not removed then stop(fresh, err); return end
			end
			if original.name ~= job.store.name then
				local cleared, clear_error = job.store.remove(job.handle)
				if not cleared then stop(fresh, clear_error); return end
			end
			job.handle = nil
			scan(job)
			working = false
			say(fresh, "info", "Updater outcome resolved", "Only the exact resolved record and this window's resolver claim were removed")
		end)
	end
	local function resolve_targets(job, original, owner_attested, cx, index)
		index = index or 1
		local target = job.handle.record.payload.targets[index]
		if target == nil then remove_original(job, original, owner_attested, cx); return end
		if target.result ~= nil then resolve_targets(job, original, owner_attested, cx, index + 1); return end
		if target.install == nil and not target.unknown_attempt then
			if not not_started(job, target.id, "No install command was journaled; the original owner cannot launch it now", cx) then return end
			resolve_targets(job, original, owner_attested, cx, index + 1)
			return
		end
		local function decide(observed, fresh)
			if observed.operation == "running" then stop(fresh, "An original installer is still running; it cannot be overridden"); return end
			local retained = job.handle.record.payload.resolving
			local attested = retained and retained.operation_stopped_attested == true
			local items = { { label = "Keep pending", choice = "cancel" },
				{ label = if observed.operation == "stopped" or attested then "Resolve this target as unverified"
					else "I confirm the original operation stopped; resolve as unverified",
					choice = "resolve", detail = target.label .. ": " .. (observed.reason or "Fresh observations retained; no success is implied") } }
			fresh:pick({ items = items, placeholder = "Resolve " .. target.label .. " update outcome?" }):next(function(item, _, picked)
				if item == nil or item.choice ~= "resolve" then working = false; return end
				-- Observe again after the human decision; a positively live operation
				-- cannot be overridden by an earlier attestation or a stale picker.
				local function commit(current, current_cx)
					if current.operation == "running" then stop(current_cx, "The original installer is now observed running; no resolution was applied"); return end
					local record, err = State.resolve(job.handle.record, target.id, current, observed.operation ~= "stopped" or attested)
					if not save(job, record, current_cx, err) then return end
					resolve_targets(job, original, owner_attested, current_cx, index + 1)
				end
				if target.unknown_attempt then Observe.unknown(job.info, id, registration, picked, commit)
				else observe_target(job, target.id, picked, commit) end
			end)
		end
		if target.unknown_attempt then
			Observe.unknown(job.info, id, registration, cx, decide)
			return
		end
		observe_target(job, target.id, cx, function(observed, fresh)
			if not observe_result(job, target.id, observed, fresh) then return end
			local current = State.target(job.handle.record, target.id)
			if current.result ~= nil then resolve_targets(job, original, owner_attested, fresh, index + 1) else decide(observed, fresh) end
		end)
	end
	local function resume_resolution(job, row, cx)
		job.handle = row
		local reference = row.record.payload.resolving
		if reference == nil or reference.name == job.store.name then
			if not resolution_scan(job, {}, cx) then return end
			migrate_legacy(job, cx, function(fresh) resolve_targets(job, job.handle, reference and reference.owner_stopped_attested == true, fresh) end)
			return
		end
		local unpacked, expected = pcall(tern.base64.decode, reference.bytes_base64 or "")
		if type(reference.bytes_base64) ~= "string" or not unpacked then stop(cx, "The retained original-byte fence is unreadable"); return end
		local original = job.store.read(reference.name)
		if original.bytes == nil then
			local rows, err = job.store.scan()
			if rows == nil then stop(cx, err); return end
			for _, value in ipairs(rows) do
				if value.name == reference.name then stop(cx, "The original updater record is unreadable, not absent"); return end
			end
			local decoded, value = pcall(tern.json.decode, expected)
			original = { name = reference.name, bytes = expected, record = if decoded and Journal.valid(value) then value else nil, missing = true }
		elseif original.bytes ~= expected then stop(cx, "The original updater record changed while resolution was pending"); return end
		local allowed, dependency_error
		if reference.kind == "cleanup" then allowed, dependency_error = State.resolver_dependencies(job.store, original)
		else allowed = { [reference.name] = true } end
		if allowed == nil then stop(cx, dependency_error); return end
		if not resolution_scan(job, allowed, cx) then return end
		owner_status(job, original, cx, function(status, fresh)
			if status == "live" or (status == "unknown" and reference.owner_stopped_attested ~= true) then
				stop(fresh, "Original owner is live or unproven; all pending files were preserved"); return
			end
			migrate_legacy(job, fresh, function(current) resolve_targets(job, original, reference.owner_stopped_attested == true, current) end)
		end)
	end
	-- A dead resolver did not launch an install. Clear only that abandoned claim;
	-- leave the referenced installation record for its own explicit resolution.
	local function orphan_resolver(job, original, owner_attested, cx)
		local allowed, dependency_error = State.resolver_dependencies(job.store, original)
		if allowed == nil then stop(cx, dependency_error); return end
		local record = { schema = 2, owner = job.info.owner, attempt = token(), revision = 0, phase = "resolving",
			payload = { targets = {}, resolving = { name = original.name, bytes_base64 = tern.base64.encode(original.bytes), kind = "cleanup",
				owner_stopped_attested = owner_attested == true } } }
		local handle, err = job.store.claim(record, allowed)
		if handle == nil then stop(cx, err); return end
		job.handle = handle
		owner_status(job, original, cx, function(status, fresh)
			if status == "live" or (status == "unknown" and not owner_attested) then stop(fresh, "Resolver owner is still live or unproven"); return end
			say(fresh, "info", "Clearing an abandoned resolver claim", "The underlying installation record and its evidence remain pending")
			local removed, removal_error = job.store.remove(original, { outcome = true, owner_status = status, owner_stopped_attested = owner_attested })
			if not removed then stop(fresh, removal_error); return end
			local cleared, clear_error = job.store.remove(job.handle)
			if not cleared then stop(fresh, clear_error); return end
			job.handle = nil
			scan(job)
			working = false
		end)
	end
	local function adopt(job, original, owner_attested, cx)
		local source = original.record
		if source == nil or not State.valid(source) then stop(cx, "Corrupt updater state needs explicit unknown-record resolution"); return end
		if original.name == job.store.name then
			if not Journal.same_owner(source.owner, job.info.owner) then stop(cx, "Updater filename collides with another daemon's owner; no file was changed"); return end
			job.handle = original
			if source.phase ~= "resolving" then
				local record = table.clone(source)
				record.revision += 1
				record.phase = "resolving"
				record.payload = table.clone(source.payload)
				record.payload.resolving = { name = original.name, kind = "self" }
				if not save(job, record, cx) then return end
			end
			resume_resolution(job, job.handle, cx)
			return
		end
		if source.payload.resolving ~= nil and source.payload.resolving.name ~= original.name then
			orphan_resolver(job, original, owner_attested, cx); return
		end
		local record = { schema = 2, owner = job.info.owner, attempt = token(), revision = 0, phase = "resolving",
			payload = { started_at = os.time(), targets = source.payload.targets, orch = source.payload.orch, legacy = source.payload.legacy,
				resolving = { name = original.name, bytes_base64 = tern.base64.encode(original.bytes), owner = source.owner, kind = "takeover",
					owner_stopped_attested = owner_attested == true, operation_stopped_attested = owner_attested == true } } }
		local handle, err = job.store.claim(record, { [original.name] = true })
		if handle == nil then stop(cx, err); return end
		job.handle = handle
		resume_resolution(job, handle, cx)
	end
	local function unknown_record(job, original, cx)
		owner_status(job, original, cx, function(status, owner_cx)
			if status == "live" then stop(owner_cx, "The filename identifies a live original owner; resolve in that window"); return end
			owner_cx:pick({ items = { { label = "Keep pending", choice = "cancel" },
				{ label = "I confirm the original owner and every original operation stopped", choice = "resolve",
					detail = "Resolve unknown outcome, not success. Fresh local observations cannot verify missing remote targets" } },
				placeholder = "Resolve unknown updater history?" }):next(function(item, _, picked)
				if item == nil or item.choice ~= "resolve" then working = false; return end
				if type(original.bytes) ~= "string" then stop(picked, "The original file is unreadable; exact-byte removal is impossible"); return end
				local targets = { { id = "local", kind = "local", label = "unknown attempt (local observation only)", unknown_attempt = true,
					from = "unknown", preview = "unknown", source = Source.install_src(dir), phase = "unknown" } }
				local record = { schema = 2, owner = job.info.owner, attempt = token(), revision = 0, phase = "resolving",
					payload = { started_at = os.time(), targets = targets, resolving = { name = original.name, bytes_base64 = tern.base64.encode(original.bytes),
						kind = "unknown", owner_stopped_attested = true, operation_stopped_attested = true } } }
				local handle, err
				if original.name == job.store.name then
					record.payload.original_base64 = tern.base64.encode(original.bytes)
					record.payload.resolving.bytes_base64 = nil
					handle, err = job.store.adopt_unknown(original, record)
				else handle, err = job.store.claim(record, { [original.name] = true }) end
				if handle == nil then stop(picked, err); return end
				job.handle = handle
				if not resolution_scan(job, { [original.name] = true }, picked) then return end
				Observe.unknown(job.info, id, registration, picked, function(observed, fresh)
					local next_record, problem = State.resolve(job.handle.record, "local", observed, true)
					if not save(job, next_record, fresh, problem) then return end
					remove_original(job, original, true, fresh)
				end)
			end)
		end)
	end
	local function resolve_legacy(job, value, cx)
		cx:pick({ items = { { label = "Keep legacy state pending", choice = "cancel" },
			{ label = "I confirm the legacy owner and its original operations stopped", choice = "adopt",
				detail = "Adopt once into this window's pending file; the native host alone clears the old KV key" } },
			placeholder = "Adopt legacy updater outcome?" }):next(function(item, _, picked)
			if item == nil or item.choice ~= "adopt" then working = false; return end
			local old = if type(value) == "table" then value else {}
			local target = { id = "local", kind = "local", label = "legacy attempt (remote outcomes unknown)", unknown_attempt = true,
				from = if type(old.pending_from) == "string" and #old.pending_from <= 128 and old.pending_from ~= "" then old.pending_from else "unknown",
				preview = if type(old.pending_to) == "string" and #old.pending_to <= 128 and old.pending_to ~= "" then old.pending_to else "unknown",
				source = Source.install_src(dir), phase = "unknown" }
			local record = { schema = 2, owner = job.info.owner, attempt = token(), revision = 0, phase = "resolving",
				payload = { started_at = os.time(), targets = { target },
					resolving = { name = job.store.name, kind = "self", owner_stopped_attested = true, operation_stopped_attested = true },
					legacy = { value = value, owner_stopped_attested = true, operation_stopped_attested = true } } }
			if not State.valid(record) then stop(picked, "Legacy state cannot be safely adopted; its original KV was preserved"); return end
			local handle, err = job.store.claim(record)
			if handle == nil then stop(picked, err); return end
			job.handle = handle
			migrate_legacy(job, picked, function(fresh) resolve_targets(job, job.handle, true, fresh) end)
		end)
	end
	local function run_resolve(cx)
		if working then say(cx, "info", "An updater interaction is already open in this window"); return end
		working = true
		info(cx, function(job, err, fresh)
			if job == nil then stop(fresh, err); return end
			local rows, scan_error, old = scan(job)
			if scan_error ~= nil then stop(fresh, scan_error); return end
			local items = {}
			for _, row in ipairs(rows) do
				table.insert(items, { label = if row.record then "Resolve window " .. (if row.record.owner.window == "" then "(first)" else row.record.owner.window)
					else "Resolve unknown updater record", detail = row.error or row.record.phase, row = row })
			end
			if Journal.legacy_pending(old) then table.insert(items, { label = "Adopt legacy updater.v1 outcome", choice = "legacy" }) end
			if #items == 0 then working = false; say(fresh, "info", "No pending " .. name .. " update outcome"); return end
			table.insert(items, { label = "Keep pending", choice = "cancel" })
			fresh:pick({ items = items, placeholder = "Resolve " .. name .. " update outcome" }):next(function(item, _, picked)
				if item == nil or item.choice == "cancel" then working = false; return end
				if item.choice == "legacy" then resolve_legacy(job, old, picked); return end
				local row = job.store.read(item.row.name)
				if row.bytes ~= item.row.bytes then stop(picked, "The selected updater record changed; no resolution was applied"); return end
				if row.record == nil or not State.valid(row.record) then unknown_record(job, row, picked); return end
				owner_status(job, row, picked, function(status, owner_cx)
					if status == "live" then stop(owner_cx, "This owner is still live. Use Resolve update outcome in that original window"); return end
					if status ~= "unknown" then adopt(job, row, false, owner_cx); return end
					owner_cx:pick({ items = { { label = "Keep pending", choice = "cancel" },
						{ label = "I confirm the original owner and operation stopped", choice = "attest" } },
						placeholder = "Original owner absence cannot be observed" }):next(function(answer, _, answered)
						if answer == nil or answer.choice ~= "attest" then working = false; return end
						adopt(job, row, true, answered)
					end)
				end)
			end)
		end)
	end
	local function run_check(cx)
		if working then say(cx, "info", "An updater interaction is already open in this window"); return end
		working = true
		info(cx, function(job, err, fresh)
			if job == nil then stop(fresh, err); return end
			scan(job)
			if job.info.dev then stop(fresh, "This is a development copy; update it from its source folder"); return end
			check(job, fresh, true, function(_, _, _, problem, current)
				working = false
				if problem ~= nil then say(current, "error", "Couldn't check for " .. name .. " updates", problem) end
			end)
		end)
	end
	tern.command({ id = "check_updates", title = prefix .. "Check for updates", icon = "download", run = run_check })
	tern.command({ id = "install_update", title = prefix .. "Update", icon = "download",
		available = function() return latest.outcome == "update" and latest.dev == false and not latest.busy and not working end, run = run_update })
	tern.command({ id = "resolve_update", title = prefix .. "Resolve update outcome", icon = "download", run = run_resolve })
	tern.on("budget", function(ev)
		if ev.state == "paused" then registration.paused[ev.hook] = true elseif ev.state == "resumed" then registration.paused[ev.hook] = nil end
	end)
	registration.registered = true
	local function initialize(cx)
		if working then return end
		if cfg.background_ready ~= nil and not cfg.background_ready(cx) then
			tern.timer(60000, initialize)
			return
		end
		working = true
		info(cx, function(job, err, fresh)
			if job == nil then stop(fresh, err); return end
			local rows, scan_error, old = scan(job)
			if scan_error ~= nil then stop(fresh, scan_error); return end
			if type(old) == "table" and not Journal.legacy_pending(old) then cache = old end
			for _, row in ipairs(rows) do
				if row.name == job.store.name and State.valid(row.record) and row.record.payload.legacy == nil
					and row.record.payload.resolving == nil and row.record.payload.original_base64 == nil then
					job.handle = row
					recover(job, fresh)
					return
				end
			end
			working = false
			if latest.busy then say(fresh, "info", name .. " has pending updater state", "Use Resolve update outcome; no install was replayed") end
		end)
	end
	tern.timer(1000, initialize)
	local function tick(cx)
		if cfg.background_ready ~= nil and not cfg.background_ready(cx) then
			tern.timer(60000, tick)
			return
		end
		tern.timer(3600000, tick)
		if working or not State.due(cache, os.time()) then return end
		working = true
		info(cx, function(job, _, fresh)
			if job == nil or job.info.dev then working = false; return end
			scan(job)
			if latest.busy then working = false; return end
			check(job, fresh or cx, false, function() working = false end)
		end)
	end
	tern.timer(60000, tick)
end
return Updater
