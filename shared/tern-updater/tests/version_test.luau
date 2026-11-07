-- Version.parse / Version.compare: SemVer 2.0 §11 precedence.
local Version = require("../version")

local function lt(a: string, b: string)
	assert(Version.compare(a, b) == -1, a .. " < " .. b)
	assert(Version.compare(b, a) == 1, b .. " > " .. a)
end

local function eq(a: string, b: string)
	assert(Version.compare(a, b) == 0, a .. " == " .. b)
	assert(Version.compare(b, a) == 0, b .. " == " .. a)
end

local function chain(list: { string })
	for i = 1, #list - 1 do
		lt(list[i], list[i + 1])
	end
	lt(list[1], list[#list])
end

return {
	{"parses the numeric core and pre-release identifiers", function()
		local v = Version.parse("2.0.0-dev-headless-r8.7")
		assert(v ~= nil)
		assert(v.major == 2 and v.minor == 0 and v.patch == 0)
		assert(#v.pre == 2 and v.pre[1] == "dev-headless-r8" and v.pre[2] == 7)
		local r = Version.parse("0.3.27")
		assert(r ~= nil and r.major == 0 and r.minor == 3 and r.patch == 27 and #r.pre == 0)
	end},
	{"numeric core compares numerically", function()
		lt("0.3.1", "0.4.0")
		lt("0.3.9", "0.3.10")
		lt("1.9.2", "1.10.0")
		lt("0.3.27", "1.0.0")
		eq("1.9.2", "1.9.2")
	end},
	{"estate pre-release sorts below its release", function()
		chain({ "2.0.0-dev-headless-r8", "2.0.0", "2.1.0" })
	end},
	{"SemVer 11 precedence chain", function()
		chain({
			"1.0.0-alpha",
			"1.0.0-alpha.1",
			"1.0.0-beta",
			"1.0.0-beta.2",
			"1.0.0-beta.11",
			"1.0.0-rc.1",
			"1.0.0",
		})
	end},
	{"numeric identifiers sort below alphanumeric", function()
		lt("1.0.0-1", "1.0.0-a")
		lt("1.0.0-alpha.9", "1.0.0-alpha.beta")
		eq("1.0.0-rc.1", "1.0.0-rc.1")
	end},
	{"leading v is accepted", function()
		eq("v1.2.3", "1.2.3")
		lt("v0.3.9", "0.3.10")
	end},
	{"build metadata is ignored", function()
		eq("1.2.3+abc", "1.2.3")
		eq("1.2.3-rc.1+build.5", "1.2.3-rc.1+other")
		local v = Version.parse("1.2.3+abc")
		assert(v ~= nil and v.patch == 3 and #v.pre == 0)
	end},
	{"missing core parts are not SemVer", function()
		assert(Version.parse("1.2") == nil)
		assert(Version.parse("1") == nil)
		assert(Version.parse("1.2.3.4") == nil)
		assert(Version.parse("v") == nil)
	end},
	{"empty string is not SemVer", function()
		assert(Version.parse("") == nil)
	end},
	{"leading zeros in the numeric core are not SemVer", function()
		assert(Version.parse("01.2.3") == nil)
		assert(Version.parse("1.02.3") == nil)
		assert(Version.parse("1.2.03") == nil)
		assert(Version.parse("0.0.0") ~= nil)
	end},
	{"leading zeros in numeric pre-release ids are not SemVer", function()
		assert(Version.parse("1.0.0-01") == nil)
		assert(Version.parse("1.0.0-rc.007") == nil)
		assert(Version.parse("1.0.0-0") ~= nil)
		assert(Version.parse("1.0.0-0a") ~= nil)
	end},
	{"empty pre-release identifiers are not SemVer", function()
		assert(Version.parse("1.0.0-") == nil)
		assert(Version.parse("1.0.0-rc..1") == nil)
		assert(Version.parse("1.0.0-rc.") == nil)
		assert(Version.parse("1.0.0-.rc") == nil)
		assert(Version.parse("1.0.0+") == nil)
	end},
	{"junk around the version is not SemVer", function()
		assert(Version.parse(" 1.2.3") == nil)
		assert(Version.parse("1.2.3 ") == nil)
		assert(Version.parse("1.2.3-rc_1") == nil)
		assert(Version.parse("V1.2.3") == nil)
		assert(Version.parse("1.2.3rc1") == nil)
	end},
	{"compare returns nil on unparsable input", function()
		assert(Version.compare("1.2", "1.2.3") == nil)
		assert(Version.compare("1.2.3", "") == nil)
		assert(Version.compare("01.2.3", "1.2.3") == nil)
		assert(Version.compare("garbage", "garbage") == nil)
	end},
}
