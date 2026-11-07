-- Vendored from shared/tern-updater by sync.py; edit there, then run sync.py.
-- Window half of the plugin self-updater: "Check for updates" and "Update" palette
-- commands, an hourly background check, and the pending journal that survives the
-- plugin reload every install causes. Never installs without the confirm picker.
local Manifest = require("./manifest")
local Source = require("./source")
local Requires = require("./requires")
local Confirm = require("./confirm")
local State = require("./state")
local Cli = require("./cli")

local Updater = {}

local LOAD_DELAY_MS = 1000
local FIRST_TICK_MS = 60000
local TICK_MS = 3600000
local FETCH = { timeout_ms = 10000, headers = { ["Cache-Control"] = "no-cache" } }

function Updater.register(cfg)
	if tern.runtime.os == "ios" or tern.context ~= "window" then return end
	assert(type(cfg) == "table" and type(cfg.name) == "string" and cfg.name ~= "", "updater: cfg.name must be a non-empty string")
	assert(Source.valid_dir(cfg.dir), "updater: cfg.dir must be a plugins/tern folder name")
	local name, dir = cfg.name, cfg.dir
	local prefix = cfg.title_prefix or (name .. " ")
	local id = tern.plugin.id
	local installed = Manifest.read(tern.fs.read(tern.plugin.dir .. "/plugin.toml", 65536)).version
	local shown = installed or "?"

	-- In-memory only, so `available` (4 ms) never touches kv or fs.
	local latest = { outcome = "none", dev = nil, busy = false }
	-- Copy kind: { exe, plugins_dir, dev } once resolved.
	local kind = nil
	local kind_waiting = nil

	local function notify(cx, notice)
		local sub = notice.sub
		tern.log.info("updater notice", notice.level, notice.text, sub or "")
		if cx ~= nil then
			local ok, err = pcall(cx.toast, cx, notice.level, notice.text, sub)
			if not ok then tern.log.warn("updater", "toast failed", tostring(err)) end
		end
	end
	local function say(cx, level, text, sub)
		notify(cx, { level = level, text = text, sub = sub })
	end

	local function load()
		local ok, value = pcall(tern.kv.get, State.KEY)
		if not ok then
			tern.log.warn("updater", "kv read failed", tostring(value))
			return nil, false
		end
		return (if type(value) == "table" then value else nil), true
	end
	local function save(record)
		local ok, err = pcall(tern.kv.set, State.KEY, record)
		if not ok then tern.log.warn("updater", "kv write failed", tostring(err)) end
		latest.busy = State.busy(record, os.time())
		return ok
	end

	local function copy_kind(cb)
		if kind ~= nil then cb(kind, nil, nil); return end
		if kind_waiting ~= nil then table.insert(kind_waiting, cb); return end
		kind_waiting = { cb }
		local function finish(value, err, cx)
			if value ~= nil then
				kind = value
				latest.dev = value.dev
			end
			local callbacks = kind_waiting or {}
			kind_waiting = nil
			for _, callback in callbacks do callback(value, err, cx) end
		end
		Cli.executable(function(exe, err, cx)
			if exe == nil then finish(nil, err, cx); return end
			Cli.plugins_dir(exe, function(plugins_dir, dir_err, dir_cx)
				if plugins_dir == nil then finish(nil, dir_err, dir_cx); return end
				tern.log.debug("updater plugin dir", tern.plugin.dir)
				tern.log.debug("updater plugins dir", plugins_dir)
				finish({ exe = exe, plugins_dir = plugins_dir, dev = Cli.linked(plugins_dir, id) }, nil, dir_cx)
			end)
		end)
	end

	-- cb(remote?, err?, cx): the published version, or a plain-language reason.
	local function fetch_remote(cb)
		local ok, raised = pcall(tern.fetch, Source.manifest_url(dir), FETCH, function(result, cx)
			if result.error ~= nil then
				tern.log.warn("updater", "manifest fetch failed", tostring(result.error))
				cb(nil, "Couldn't reach GitHub", cx)
			elseif result.status == 404 then
				cb(nil, "No published copy at " .. Source.page_url(dir), cx)
			elseif result.status ~= 200 then
				tern.log.warn("updater", "manifest fetch status", result.status)
				cb(nil, "GitHub answered " .. tostring(result.status), cx)
			else
				local manifest = Manifest.read(result.body)
				if manifest.id ~= id then
					cb(nil, "The published copy is a different plugin", cx)
				elseif manifest.version == nil then
					cb(nil, "The published copy has no version", cx)
				else
					cb(manifest.version, nil, cx)
				end
			end
		end)
		if not ok then
			tern.log.warn("updater", "manifest fetch raised", tostring(raised))
			cb(nil, "Couldn't reach GitHub", nil)
		end
	end

	local DEV = name .. " here is a development copy (linked); update it from its source folder"
	local function busy_text() return name .. " update is already running" end
	local function check_failed(cx, err) say(cx, "error", "Couldn't check for " .. name .. " updates", err) end

	-- The explicit (always notifying) text for a non-error outcome.
	local function outcome_notice(cx, outcome, remote)
		if outcome == "update" then
			say(cx, "info", name .. " " .. remote .. " is available (you have " .. shown .. ")")
		elseif outcome == "current" then
			say(cx, "success", name .. " is up to date (" .. shown .. ")")
		elseif outcome == "ahead" then
			say(cx, "info", name .. " " .. shown .. " is newer than GitHub (" .. remote .. ")")
		else
			say(cx, "info", "Can't compare " .. shown .. " with " .. tostring(remote))
		end
	end

	-- Fetch + after_check + kv; cb(outcome, remote?, err?, cx). cx is nil when tern.fetch raised
	-- synchronously, so every caller notifies through `fresh or <its own cx>`.
	local function check(cb)
		fetch_remote(function(remote, err, cx)
			local record = load()
			local out, outcome, notice = State.after_check(record, os.time(), shown, remote, err, name)
			save(out)
			if outcome ~= "error" then latest.outcome = outcome end
			cb(outcome, remote, err, cx, notice)
		end)
	end

	local function tick(cx)
		tern.timer(TICK_MS, tick)
		local record, ok = load()
		if not ok then return end
		latest.busy = State.busy(record, os.time())
		local due = State.due(record, os.time())
		tern.log.debug("updater tick", if due then "due" else "not due")
		if not due then return end
		copy_kind(function(info, err, kind_cx)
			if info == nil then tern.log.warn("updater", "copy kind", tostring(err)); return end
			if info.dev then return end
			check(function(outcome, _, check_err, fresh, notice)
				if outcome == "error" then tern.log.warn("updater", "background check", tostring(check_err)) end
				if notice ~= nil then notify(fresh or kind_cx or cx, notice) end
			end)
		end)
	end

	local function run_check(cx)
		local record = load()
		if State.busy(record, os.time()) then say(cx, "info", busy_text()); return end
		copy_kind(function(info, err, kind_cx)
			local now_cx = kind_cx or cx
			if info == nil then check_failed(now_cx, err); return end
			if info.dev then say(now_cx, "info", DEV); return end
			check(function(outcome, remote, check_err, fresh)
				local now = fresh or now_cx
				if outcome == "error" then check_failed(now, check_err); return end
				outcome_notice(now, outcome, remote)
			end)
		end)
	end

	local function install(cx, info, item, remote, orch)
		local record, ok = load()
		if not ok then say(cx, "error", "Couldn't start the " .. name .. " update", "Couldn't read the updater's saved state"); return end
		if State.busy(record, os.time()) then say(cx, "info", busy_text()); return end
		if not save(State.begin(record, os.time(), shown, remote, orch)) then
			say(cx, "error", "Couldn't start the " .. name .. " update", "Couldn't save the updater's state")
			return
		end
		say(cx, "info", "Updating " .. name .. " to " .. remote .. "…")
		local src = Source.install_src(dir)
		if item.choice == "remote" then
			local opened, err = pcall(function()
				cx.hosts:terminal(item.host, { command = Confirm.remote_command(src) })
			end)
			if not opened then
				tern.log.warn("updater", "remote terminal", tostring(err))
				say(cx, "error", "Couldn't open a shell on that host", tostring(err))
			end
		end
		-- A spawn failure calls back synchronously with no fresh cx; this call's cx is still live then.
		Cli.install(info.exe, src, function(result, fresh_cx)
			local fresh = fresh_cx or cx
			local current = load()
			if result.status == 0 then
				local version = nil
				local decoded, value = pcall(tern.json.decode, result.stdout)
				if decoded and type(value) == "table" and type(value.version) == "string" then version = value.version end
				local out, notice = State.reconcile(current, os.time(), version, name)
				save(out)
				if version ~= nil then latest.outcome = State.outcome(out, version) end
				if notice ~= nil then notify(fresh, notice) end
			else
				tern.log.warn("updater", "install failed", result.status, result.stderr)
				local out, notice = State.install_failed(current, result.status, result.stderr, result.timed_out)
				save(out)
				notify(fresh, notice)
			end
		end)
	end

	-- `installed_plugins` is this machine's `tern plugin list` (id → version). Tern 0.9.12's
	-- cx.actions:list() returns built-in actions only, so a loaded orchplus there counts too.
	local function confirm(cx, info, remote, installed_plugins)
		local orch, remotes = installed_plugins.orchplus ~= nil, {}
		local ok_actions, actions = pcall(function() return cx.actions:list("ORCH+") end)
		if ok_actions and type(actions) == "table" then
			for _, action in actions do
				if action.plugin == "orchplus" then orch = true; break end
			end
		end
		local ok_hosts, hosts = pcall(function() return cx.hosts:list() end)
		if ok_hosts and type(hosts) == "table" then
			for _, host in hosts do
				if host.kind == "remote" and host.state == "connected" then
					table.insert(remotes, { id = host.id, name = host.name })
				end
			end
		end
		local items = Confirm.items({ name = name, from = shown, to = remote, orch = orch, remotes = remotes })
		cx:pick({ items = items, placeholder = "Update " .. name .. "?", icon = "download" }):next(function(item, err, picked_cx)
			if item == nil or item.choice == "cancel" then
				if err ~= nil then tern.log.warn("updater", "picker", tostring(err)) end
				return
			end
			Cli.git_available(function(has_git, git_cx)
				local now_cx = git_cx or picked_cx
				if not has_git then
					local sub = if tern.runtime.os == "macos" then "Run xcode-select --install"
						elseif tern.runtime.os == "windows" then "Install it from https://git-scm.com/download/win"
						else nil
					say(now_cx, "error", "Updating needs git on this machine", sub)
					return
				end
				install(now_cx, info, item, remote, orch)
			end)
		end)
	end

	-- cb(installed_plugins, cx) once this release's requirements are met; otherwise notifies and stops.
	local function requirements(info, cx, cb)
		local function with_plugins(req, fresh)
			Cli.plugin_versions(info.exe, function(map, list_err, list_cx)
				local now_cx = list_cx or fresh
				if map == nil then
					if req ~= nil then
						say(now_cx, "error", "Couldn't read this release's requirements", list_err)
						return
					end
					tern.log.warn("updater", "plugin list", tostring(list_err))
					map = {}
				end
				if req == nil then cb(map, now_cx); return end
				Cli.tern_version(info.exe, function(stdout, version_cx)
					local problem = Requires.check(req, if stdout ~= nil then Requires.tern_version(stdout) else nil, map)
					if problem ~= nil then say(version_cx or now_cx, "error", problem); return end
					cb(map, version_cx or now_cx)
				end)
			end)
		end
		local ok, raised = pcall(tern.fetch, Source.requires_url(dir), FETCH, function(result, fresh)
			if result.error == nil and result.status == 404 then with_plugins(nil, fresh); return end
			if result.error ~= nil or result.status ~= 200 then
				tern.log.warn("updater", "requires fetch", tostring(result.error), result.status)
				say(fresh, "error", "Couldn't read this release's requirements")
				return
			end
			local req, err = Requires.read(result.body, tern.json.decode)
			if req == nil then
				say(fresh, "error", "Couldn't read this release's requirements", err)
				return
			end
			with_plugins(req, fresh)
		end)
		if not ok then
			tern.log.warn("updater", "requires fetch raised", tostring(raised))
			say(cx, "error", "Couldn't read this release's requirements")
		end
	end

	local function run_update(cx)
		-- `run` also fires from keybinds, cx:action and `tern ctl plugins run`: re-check everything.
		local record = load()
		if State.busy(record, os.time()) then say(cx, "info", busy_text()); return end
		copy_kind(function(info, err, kind_cx)
			local now_cx = kind_cx or cx
			if info == nil then check_failed(now_cx, err); return end
			if info.dev then say(now_cx, "info", DEV); return end
			check(function(outcome, remote, check_err, fresh)
				local now = fresh or now_cx
				if outcome == "error" then check_failed(now, check_err); return end
				if outcome ~= "update" then outcome_notice(now, outcome, remote); return end
				requirements(info, now, function(installed_plugins, req_cx)
					confirm(req_cx, info, remote, installed_plugins)
				end)
			end)
		end)
	end

	tern.command({ id = "check_updates", title = prefix .. "Check for updates", icon = "download", run = run_check })
	tern.command({
		id = "install_update",
		title = prefix .. "Update",
		icon = "download",
		available = function()
			return latest.outcome == "update" and latest.dev == false and not latest.busy
		end,
		run = run_update,
	})

	tern.timer(LOAD_DELAY_MS, function(cx)
		local record, ok = load()
		if ok then
			local now = os.time()
			local out, notice = State.reconcile(record, now, installed, name)
			-- Write only when a journal existed, so a dev copy's kv is never touched.
			local journal = record ~= nil and (record.pending_from ~= nil or record.pending_to ~= nil or record.pending_at ~= nil)
			if journal then save(out) end
			if notice ~= nil then notify(cx, notice) end
			latest.outcome = State.outcome(out, shown)
			latest.busy = State.busy(out, now)
		end
		copy_kind(function(info, err)
			if info == nil then tern.log.warn("updater", "copy kind", tostring(err)) end
		end)
	end)
	tern.timer(FIRST_TICK_MS, tick)
end

return Updater
