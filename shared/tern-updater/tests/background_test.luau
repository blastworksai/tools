local native = tern
local dependencies = require
local environment = getfenv()

local function fixture()
	local pending, timers, commands, notices = {}, {}, {}, {}
	local ready, starts = false, 0
	local cx = { toast = function(_, level) table.insert(notices, level) end }
	local runtime = {
		context = "window", runtime = { os = "linux" },
		plugin = { id = "updater-fixture", dir = "/fixture", data = "/fixture/data" },
		fs = { read = function() return 'version = "1.0.0"\n' end },
		now = function() return 100 end,
		log = { info = function() end },
		command = function(command) commands[command.id] = command end,
		on = function() end,
		timer = function(delay, callback) table.insert(timers, { delay = delay, callback = callback }) end,
	}
	local source = native.fs.read(native.plugin.dir .. "/updater/window.luau", 131072)
	local chunk = assert(loadstring(source, "updater scheduling"))
	setfenv(chunk, setmetatable({
		tern = runtime,
		require = function(name)
			if name == "./cli" then
				return { executable = function(callback)
					starts += 1
					table.insert(pending, callback)
				end }
			end
			return dependencies("../" .. name:sub(3))
		end,
	}, { __index = environment }))
	chunk().register({ name = "Fixture", dir = "WORK", background_ready = function() return ready end })
	return {
		ready = function(value) ready = value end,
		starts = function() return starts end,
		notices = notices,
		check = function() commands.check_updates.run(cx) end,
		unavailable = function()
			local callback = assert(table.remove(pending, 1), "no discovery pending")
			callback(nil, "fixture executable unavailable", cx)
		end,
		tick = function(delay)
			for index, timer in ipairs(timers) do
				if timer.delay == delay then
					table.remove(timers, index)
					timer.callback(cx)
					return
				end
			end
			error("expected scheduled timer")
		end,
	}
end

return {
	{ "background discovery waits for the active consumer then resumes", function()
		local f = fixture()
		f.tick(1000)
		f.tick(60000)
		assert(f.starts() == 0)
		f.ready(true)
		f.tick(60000)
		assert(f.starts() == 1)
		f.unavailable()
		assert(f.notices[#f.notices] == "error")
	end },
	{ "explicit check remains available while automatic discovery is deferred", function()
		local f = fixture()
		f.tick(1000)
		f.check()
		assert(f.starts() == 1)
		f.unavailable()
		f.tick(60000)
		assert(f.starts() == 1)
		f.check()
		assert(f.starts() == 2)
	end },
	{ "background discovery owns the interaction until its asynchronous result", function()
		local f = fixture()
		f.ready(true)
		f.tick(1000)
		f.unavailable()
		f.tick(60000)
		assert(f.starts() == 2)
		f.check()
		assert(f.starts() == 2 and f.notices[#f.notices] == "info")
		f.unavailable()
		f.check()
		assert(f.starts() == 3)
	end },
}
