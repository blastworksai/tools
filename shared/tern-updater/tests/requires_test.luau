local Requires = require("../requires")

local decode = tern.json.decode

local function read(text)
	return Requires.read(text, decode)
end

return {
	{"read: full valid", function()
		local req, err = read('{"schema":1,"tern":"0.9.8","plugins":{"spawn":"0.3.1"}}')
		assert(err == nil, err)
		assert(req.tern == "0.9.8")
		assert(req.plugins.spawn == "0.3.1")
	end},
	{"read: minimal has empty plugins", function()
		local req = read('{"schema":1}')
		assert(req and req.tern == nil and next(req.plugins) == nil)
	end},
	{"read: plugins null is absent", function()
		local req, err = read('{"schema":1,"plugins":null}')
		assert(err == nil and next(req.plugins) == nil)
	end},
	{"read: empty plugins object", function()
		local req, err = read('{"schema":1,"plugins":{}}')
		assert(err == nil, err)
		assert(next(req.plugins) == nil)
	end},
	{"read: empty object fails schema", function()
		local req, err = read("{}")
		assert(req == nil and type(err) == "string")
	end},
	{"read: schema mismatch", function()
		local req, err = read('{"schema":2}')
		assert(req == nil and type(err) == "string")
		assert(read('{"schema":"1"}') == nil)
	end},
	{"read: non-object plugins", function()
		assert(read('{"schema":1,"plugins":"spawn"}') == nil)
		assert(read('{"schema":1,"plugins":["spawn"]}') == nil)
	end},
	{"read: non-SemVer versions", function()
		assert(read('{"schema":1,"tern":"0.9"}') == nil)
		assert(read('{"schema":1,"tern":9}') == nil)
		assert(read('{"schema":1,"plugins":{"spawn":"latest"}}') == nil)
		assert(read('{"schema":1,"plugins":{"spawn":3}}') == nil)
	end},
	{"read: decode error caught", function()
		local req, err = read("{not json")
		assert(req == nil and type(err) == "string")
		local req2, err2 = Requires.read("x", function() error("boom") end)
		assert(req2 == nil and type(err2) == "string")
	end},
	{"read: non-object top level", function()
		assert(read("[1]") == nil)
		assert(read('"x"') == nil)
	end},
	{"tern_version: parses", function()
		assert(Requires.tern_version("tern 0.9.12 (e498b49)\n") == "0.9.12")
		assert(Requires.tern_version("tern 0.10.0\n") == "0.10.0")
	end},
	{"tern_version: garbage", function()
		assert(Requires.tern_version("garbage") == nil)
		assert(Requires.tern_version("tern banana\n") == nil)
		assert(Requires.tern_version("") == nil)
	end},
	{"check: ok", function()
		local req = { tern = "0.9.8", plugins = { spawn = "0.3.1" } }
		assert(Requires.check(req, "0.9.12", { spawn = "0.3.1" }) == nil)
		assert(Requires.check({ plugins = {} }, nil, {}) == nil)
	end},
	{"check: tern too old", function()
		local msg = Requires.check({ tern = "0.9.13", plugins = {} }, "0.9.12", {})
		assert(msg == "Needs Tern 0.9.13 or later (this is 0.9.12)", msg)
	end},
	{"check: unknown tern with minimum", function()
		local msg = Requires.check({ tern = "0.9.13", plugins = {} }, nil, {})
		assert(msg == "Can't tell this Tern's version; update Tern to 0.9.13 or later first", msg)
	end},
	{"check: plugin absent", function()
		local msg = Requires.check({ plugins = { spawn = "0.3.1" } }, "0.9.12", {})
		assert(msg == "Install spawn 0.3.1 or later first", msg)
	end},
	{"check: plugin too old", function()
		local msg = Requires.check({ plugins = { spawn = "0.3.1" } }, "0.9.12", { spawn = "0.3.0" })
		assert(msg == "Update spawn to 0.3.1 or later first (you have 0.3.0)", msg)
	end},
	{"check: plugin unparsable version", function()
		local msg = Requires.check({ plugins = { spawn = "0.3.1" } }, "0.9.12", { spawn = "dev" })
		assert(msg == "Update spawn to 0.3.1 or later first (you have dev)", msg)
	end},
	{"check: tern first, then sorted ids", function()
		local req = { tern = "1.0.0", plugins = { zed = "1.0.0", alpha = "1.0.0" } }
		assert(Requires.check(req, "0.9.0", {}) == "Needs Tern 1.0.0 or later (this is 0.9.0)")
		req.tern = nil
		assert(Requires.check(req, "0.9.0", {}) == "Install alpha 1.0.0 or later first")
	end},
}
