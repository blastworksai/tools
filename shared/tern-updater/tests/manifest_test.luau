-- Manifest.read: top-level id/version only; TOML string forms; never raises.
local Manifest = require("../manifest")

-- origin/main plugins/tern/WORK/plugin.toml, verbatim.
local WORK = [==[
schema = 1
id = "tern-work"
name = "WORK"
version = "0.4.0"
description = "Live active Glitch workspaces with Work On and GitHub actions."
icon = "list"
host = "host.luau"
window = "window.luau"
styles = ["styles.css"]

[[blocks]]
id = "panel"
title = "WORK"
icon = "list"
palette = true
]==]

-- origin/main plugins/tern/SPAWN/plugin.toml, verbatim.
local SPAWN = [==[
schema = 1
id = "spawn"
name = "SPAWN"
version = "0.4.0"
description = "SPAWN canonical roster, ordinary launches, and durable managed dispatch bridge."
icon = "sparkle"
host = "host.luau"
window = "window.luau"
styles = ["dispatch.css"]

[[blocks]]
id = "spawner"
title = "SPAWN"
icon = "sparkle"
palette = false

[[blocks]]
id = "dispatch"
title = "SPAWN dispatch"
icon = "sparkle"
palette = false
]==]

local function crlf(s: string): string
	return (string.gsub(s, "\n", "\r\n"))
end

return {
	{ "WORK manifest: top-level id wins over the block id", function()
		local m = Manifest.read(WORK)
		assert(m.id == "tern-work")
		assert(m.version == "0.4.0")
	end },
	{ "SPAWN manifest: top-level id wins over both block ids", function()
		local m = Manifest.read(SPAWN)
		assert(m.id == "spawn")
		assert(m.version == "0.4.0")
	end },
	{ "real manifests with CRLF and a BOM read the same", function()
		local w = Manifest.read("\239\187\191" .. crlf(WORK))
		assert(w.id == "tern-work" and w.version == "0.4.0")
		local s = Manifest.read(crlf(SPAWN))
		assert(s.id == "spawn" and s.version == "0.4.0")
	end },
	{ "missing version gives nil without raising", function()
		local m = Manifest.read('schema = 1\nid = "x"\n[[blocks]]\nversion = "9.9.9"\n')
		assert(m.id == "x")
		assert(m.version == nil)
	end },
	{ "keys after a table header are ignored, even indented headers", function()
		local m = Manifest.read('  [package]\nid = "late"\nversion = "1.0.0"\n')
		assert(m.id == nil and m.version == nil)
	end },
	{ "trailing comments and whole-line comments", function()
		local m = Manifest.read('# header\nid = "a" # the id\nversion = \'1.2.3\'   # lit\n')
		assert(m.id == "a")
		assert(m.version == "1.2.3")
	end },
	{ "a # inside a string is not a comment", function()
		local m = Manifest.read('id = "a#b"\nversion = \'1.0.0#x\'\n')
		assert(m.id == "a#b")
		assert(m.version == "1.0.0#x")
	end },
	{ "bare-key spacing variants and quoted keys", function()
		assert(Manifest.read('id="tight"').id == "tight")
		assert(Manifest.read('   id   =   "loose"   ').id == "loose")
		assert(Manifest.read('id\t=\t"tabs"').id == "tabs")
		assert(Manifest.read('"id" = "dq"').id == "dq")
		assert(Manifest.read("'version' = '2.0.0'").version == "2.0.0")
	end },
	{ "basic-string escapes decode", function()
		local m = Manifest.read('id = "a\\"b\\\\c\\n\\t\\u00e9\\U0001F600"\n')
		assert(m.id == 'a"b\\c\n\t\195\169\240\159\152\128')
	end },
	{ "literal strings keep backslashes", function()
		assert(Manifest.read("id = 'C:\\path\\n'").id == "C:\\path\\n")
	end },
	{ "invalid, unterminated, or non-string values give nil", function()
		assert(Manifest.read('id = "bad \\q escape"').id == nil)
		assert(Manifest.read('id = "\\uD800"').id == nil)
		assert(Manifest.read('id = "open').id == nil)
		assert(Manifest.read("id = 'open").id == nil)
		assert(Manifest.read('id = "a" junk').id == nil)
		assert(Manifest.read("version = 1").version == nil)
		assert(Manifest.read("version = true").version == nil)
	end },
	{ "dotted keys are not the top-level id", function()
		local m = Manifest.read('plugin.id = "nope"\nid.x = "nope"\nversion = "1.0.0"\n')
		assert(m.id == nil and m.version == "1.0.0")
	end },
	{ "first occurrence wins", function()
		assert(Manifest.read('id = "first"\nid = "second"\n').id == "first")
	end },
	{ "multi-line arrays with a line starting [ do not end the top level", function()
		local m = Manifest.read('matrix = [\n  [1, 2],\n  ["]", 3],\n]\nid = "after"\nversion = "1.0.0"\n')
		assert(m.id == "after" and m.version == "1.0.0")
	end },
	{ "multi-line strings containing [ or id lines are skipped", function()
		local m = Manifest.read('description = """\n[not a header]\nid = "inside"\n"""\nid = "outside"\n'
			.. "notes = '''\nversion = \"0.0.0\"\n'''\nversion = \"3.1.4\"\n")
		assert(m.id == "outside")
		assert(m.version == "3.1.4")
		assert(Manifest.read('description = """one line"""\nid = "x"').id == "x")
	end },
	{ "non-string and garbage input never raise", function()
		local none = Manifest.read(nil)
		assert(type(none) == "table" and none.id == nil and none.version == nil)
		for _, input in { 42, true, {}, function() end } do
			local m = Manifest.read(input)
			assert(type(m) == "table" and m.id == nil and m.version == nil)
		end
		local empty = Manifest.read("")
		assert(empty.id == nil and empty.version == nil)
		local junk = Manifest.read("\0\255\254 = = \"\\u{zz}\n[[[\n")
		assert(type(junk) == "table" and junk.id == nil)
		local bom = Manifest.read("\239\187\191")
		assert(bom.id == nil)
	end },
}
