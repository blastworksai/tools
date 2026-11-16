local Remote = require("../remote")
local function fixture()
	local host = { id = 2, name = "owned-host", kind = "remote", state = "connected", address = "fixture.invalid",
		identity = { name = "owned-host", os = "linux" }, detail = { fingerprint = "fixture-key" }, panes = { 20 } }
	local pane = { kind = "terminal", at_prompt = true, program = "/bin/sh",
		last = { line = "exact-command", status = 0, took_ms = 10 } }
	local cx = { hosts = { list = function(_) return { host } end }, session = { pane = function(_, _) return pane end } }
	local target = { host = assert(Remote.snapshot(host)), pane = 20 }
	return cx, target, host, pane
end
local function frame(manifest, requirements)
	local text = "plugin.toml:present\n" .. tern.base64.encode(manifest) .. "\n:END\n"
	if requirements == nil then return text .. "requires.json:absent\n" end
	return text .. "requires.json:present\n" .. tern.base64.encode(requirements) .. "\n:END\n"
end
local MANIFEST = 'id = "fixture"\nversion = "1.1.0"\nname = "Fixture"\n'
return {
	{ "a prompt without a prior command can be used for the harmless first probe", function()
		local cx, target, _, pane = fixture()
		pane.last = nil
		assert(Remote.ready(cx, target) == pane)
		assert(Remote.completion(cx, target, { line = "exact-command" }) == nil)
	end },
	{ "completion requires exact command identity and a usable finished prompt", function()
		local mutations = {
			function(p) p.last.line = "other-command" end,
			function(p) p.last = nil end,
			function(p) p.last.status = "0" end,
			function(p) p.last.took_ms = -1 end,
			function(p) p.at_prompt = false end,
			function(p) p.running = { line = "exact-command" } end,
		}
		for _, mutate in ipairs(mutations) do
			local cx, target, _, pane = fixture()
			mutate(pane)
			assert(Remote.completion(cx, target, { line = "exact-command" }) == nil)
		end
		local cx, target, _, pane = fixture()
		pane.last.status = 17
		assert(Remote.completion(cx, target, { line = "exact-command" }).status == 17)
	end },
	{ "host reconnects and pane reassignment cannot inherit an old command's authority", function()
		local mutations = {
			function(h) h.detail.fingerprint = "replacement-key" end,
			function(h) h.address = "different.invalid" end,
			function(h) h.identity = { name = "replacement", os = "linux" } end,
			function(h) h.state = "disconnected" end,
			function(h) h.panes = { 21 } end,
		}
		for _, mutate in ipairs(mutations) do
			local cx, target, host = fixture()
			mutate(host)
			assert(Remote.ready(cx, target) == nil)
			assert(Remote.completion(cx, target, { line = "exact-command" }) == nil)
		end
	end },
	{ "framed actual package bytes retain requirements and reject clipped or injected boundaries", function()
		local bytes = frame(MANIFEST, '{"schema":1,"plugins":{"dependency":"2.0.0"}}')
		local package = assert(Remote.files({ status = 0, stdout = bytes }, "fixture"))
		assert(package.installed.version == "1.1.0" and package.requirements.plugins.dependency == "2.0.0")
		assert(Remote.files({ status = 0, stdout = bytes:sub(1, #bytes - 3) }, "fixture") == nil)
		assert(Remote.files({ status = 0, stdout = bytes .. "unexpected-output" }, "fixture") == nil)
		assert(Remote.files({ status = 9, stdout = bytes }, "fixture") == nil)
		assert(Remote.files({ status = 0, timed_out = true, stdout = bytes }, "fixture") == nil)
		assert(Remote.files({ status = 0, stdout = bytes }, "different-plugin") == nil)
	end },
	{ "remote absence is explicit and oversized package observations are refused", function()
		local package = assert(Remote.files({ status = 0, stdout = frame(MANIFEST, nil) }, "fixture"))
		assert(next(package.requirements.plugins) == nil)
		assert(Remote.files({ status = 0, stdout = frame(MANIFEST .. string.rep(" ", 16385), nil) }, "fixture") == nil)
		assert(Remote.files({ status = 0, stdout = "plugin.toml:absent\nrequires.json:absent\n" }, "fixture") == nil)
	end },
	{ "correlation text cannot inject an additional shell command", function()
		local posix = assert(Remote.platform("/bin/sh"))
		local windows = assert(Remote.platform("cmd.exe"))
		for _, nonce in ipairs({ "ok\nother-command", "ok;other-command", "ok'", "" }) do
			assert(Remote.command(posix, { "tern", "--version" }, nonce, false) == nil)
			assert(Remote.command(windows, { "tern.exe", "--version" }, nonce, false) == nil)
		end
		assert(Remote.platform("/bin/fish") == nil)
	end },
}
