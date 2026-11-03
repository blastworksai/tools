-- Run in Tern: assert(loadstring(tern.fs.read(TEST_PATH)))(PLUGIN_DIR)
local root = ...
assert(type(root) == "string", "pass the plugin directory")
local modules, environment = {}, getfenv()
local function load(name)
	name = name:gsub("^%./", "")
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(tern.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ require = load }, { __index = environment }))
	modules[name] = chunk()
	return modules[name]
end
local snapshot = load("snapshot")
local checks = 0
local function check(condition, message)
	assert(condition, message)
	checks += 1
	-- Yield between cases so no Tern driver slice accumulates several of them.
	if type(await) == "function" then await(tern.sleep(0)) end
end
local function reading(id, account, used, observed, provider)
	return { id = id, provider = provider or "claude", provider_label = "Synthetic provider",
		source_label = "Synthetic source " .. id, usage_source = "Synthetic source " .. id,
		account_id = account, account_label = if account then "Account " .. account else nil,
		last_reading_at_ms = observed, windows = if used == nil then tern.json.array() else {
			{ key = "weekly", pool = "all", used = used, remaining = 100 - used,
				observed_at_ms = observed, resets_at_ms = observed + 2000000 },
		} }
end
local function envelope(publisher, readings, at)
	local scopes = tern.json.array()
	for _, value in readings do
		if value.account_id ~= nil then
			table.insert(scopes, { id = "scope:" .. value.account_id, revision = "fixture", updated_at_ms = 1000,
				accounts = { { id = value.account_id, provider = value.provider, provider_label = value.provider_label,
					account_label = value.account_label, canonical_ids = { value.account_id }, reading_ids = { value.id } } },
				consumers = {} })
		end
	end
	return { version = 3, publisher = publisher, as_of_ms = at or 1000, readings = readings,
		roster = { version = 1, scopes = scopes } }
end
local a = assert(snapshot.decode(envelope("publisher-a", { reading("source-a", "account-a", 0, 1000) })))
local b = assert(snapshot.decode(tern.json.encode(envelope("publisher-b", { reading("source-b", "account-b", 83, 1000) }))))
local before = tern.json.encode({ a = a, b = b })
local model = snapshot.project({ [a.publisher] = a, [b.publisher] = b }, 1500)
check(#model.accounts == 2, "independent publisher slots compose instead of replacing the first")
check(model.accounts[1].windows[1].freshness == "fresh" and model.accounts[2].windows[1].freshness == "fresh"
	and model.accounts[2].windows[1].observed_at_ms == 1000, "receipt time does not replace observation time")
check(model.accounts[1].windows[1].used == 0, "a measured zero is retained")
check(model.freshness.next_change_at_ms == 901001, "the earliest lease expiry schedules the next display change")
local stale = snapshot.project({ [a.publisher] = a, [b.publisher] = b }, 901001)
check(#stale.accounts == 2 and stale.accounts[1].windows[1].freshness == "stale"
	and stale.accounts[2].windows[1].freshness == "stale", "offline sources retain known readings beyond fifteen minutes")
check(stale.accounts[1].windows[1].used == 0 and stale.accounts[1].windows[1].observed_at_ms == 1000,
	"stale values and their source timestamps are preserved")
check(tern.json.encode({ a = a, b = b }) == before, "projection never mutates decoded snapshots")
local removed = snapshot.project({ [b.publisher] = b }, 901001)
check(#removed.accounts == 1 and removed.accounts[1].account_label == "Account account-b", "explicit publisher removal differs from expiry")
local tied = assert(snapshot.decode(envelope("publisher-c", { reading("source-z", "account-a", 65, 1000) })))
local grouped = snapshot.project({ [tied.publisher] = tied, [a.publisher] = a }, 1500)
check(#grouped.accounts == 1 and grouped.accounts[1].windows[1].used == 0, "canonical reducer preserves source-ID tie break without summing")
local unknown_a = assert(snapshot.decode(envelope("unknown-a", { reading("pane-1", nil, 17, 1000) })))
local unknown_b = assert(snapshot.decode(envelope("unknown-b", { reading("pane-1", nil, nil, 1000) })))
local unresolved = snapshot.project({ [unknown_a.publisher] = unknown_a, [unknown_b.publisher] = unknown_b }, 1500)
check(#unresolved.accounts == 0 and #unresolved.unresolved == 2, "unmatched source entries stay diagnostics, not accounts")
local inventory = assert(snapshot.decode(envelope("inventory", { reading("profile", "profile-account", nil, 1000) })))
local unmeasured = snapshot.project({ inventory = inventory }, 1500)
check(#unmeasured.accounts == 1 and #unmeasured.accounts[1].windows == 1
	and unmeasured.accounts[1].windows[1].used == nil
	and unmeasured.accounts[1].windows[1].freshness == "unavailable", "identity-only inventory is not a fabricated percentage")
-- Pre-2.0 publishers left Muse measurements as last-good inventory without a roster.
local muse = reading("muse-source", "muse-account", 42, 1000, "muse")
muse.usage_source = "last-good"
local muse_inventory = assert(snapshot.decode({ version = 3, publisher = "muse-inventory", as_of_ms = 1000, readings = { muse } }))
local muse_roster = assert(snapshot.decode(envelope("muse-roster", { reading("muse-profile", "muse-account", nil, 1000, "muse") })))
local retained = snapshot.project({ muse = muse_roster, inventory = muse_inventory }, 2001001)
check(#retained.accounts == 1 and retained.accounts[1].windows[1].used == 42
	and retained.accounts[1].windows[1].freshness == "stale", "Muse last-known inventory survives restart and past reset")
check(retained.accounts[1].windows[1].observed_at_ms == 1000, "Muse retention never re-dates observations")
local passed = snapshot.project({ [a.publisher] = a }, 2001000)
check(passed.accounts[1].windows[1].freshness == "stale", "passed resets do not imply a fresh cycle")
local remote = envelope("remote", { reading("remote-source", "remote-account", nil, 1000) })
remote.readings[1].windows = { { key = "subscription", pool = "default", observed_at_ms = 1000, unavailable_reason = "source_remote" } }
local remote_expired = tern.json.decode(tern.json.encode(remote))
remote_expired.readings[1].windows[1].unavailable_reason = "web_login_expired"
check(snapshot.decode(remote) ~= nil and snapshot.decode(remote_expired) ~= nil,
	"remote SSH definitions and expired provider logins are explicit unavailable reasons")

local raw = envelope("sanitized", { reading("source", "account", 12, 1000) })
raw.token = "secret-sentinel"
raw.readings[1].environment = "secret-sentinel"
raw.readings[1].windows[1].raw_response = "secret-sentinel"
raw.readings[1].windows[1].reset_calendar = { hour = 12, minute = 0, timezone = "UTC", password = "secret-sentinel" }
local safe = assert(snapshot.decode(raw))
check(not tern.json.encode(safe):find("secret-sentinel", 1, true), "nested export projection strips non-allowlisted data")
local roster_raw = envelope("roster", { reading("source", "account", 12, 1000) })
roster_raw.roster.secret = "secret-sentinel"
roster_raw.roster.scopes[1].accounts[1].command = "secret-sentinel"
roster_raw.roster.scopes[1].source_uid = "secret-sentinel"
local roster_safe = assert(snapshot.decode(roster_raw))
check(roster_safe.roster.scopes[1].accounts[1].account_label == "Account account"
	and not tern.json.encode(roster_safe):find("secret-sentinel", 1, true), "roster fields survive without source-local matching context")
local function rejected(change, message)
	local candidate = tern.json.decode(tern.json.encode(raw))
	change(candidate)
	local value, diagnostic = snapshot.decode(candidate)
	check(value == nil and type(diagnostic) == "string", message)
end
rejected(function(v) v.version = 2 end, "old schema is rejected")
rejected(function(v) v.publisher = "bad\npublisher" end, "control characters cannot enter publisher identity")
rejected(function(v) v.readings[1].source_label = string.rep("x", 1025) end, "display labels are bounded")
rejected(function(v) v.readings[1].windows[1].observed_at_ms = -1 end, "negative source timestamps are rejected")
rejected(function(v) v.readings[1].windows[1].used = 0 / 0 end, "nonfinite percentages are rejected")
rejected(function(v) v.readings[1].windows[1].remaining = 1 end, "complementary percentages must agree")
rejected(function(v) v.readings[1].windows[1].unavailable_reason = "unavailable" end, "unavailable values cannot carry a numeric percentage")
rejected(function(v) v.readings[1].windows[1].unavailable_reason = "secret-sentinel" end, "untrusted error text is rejected")
rejected(function(v) v.readings = { [2] = v.readings[1] } end, "sparse arrays are rejected")
rejected(function(v) for i = 2, 1001 do v.readings[i] = v.readings[1] end end, "more than one thousand readings are rejected")
rejected(function(v) for i = 2, 66 do v.readings[1].windows[i] = v.readings[1].windows[1] end end, "more than sixty-five windows are rejected")
rejected(function(v) v.padding = string.rep("x", 1048576) end, "decoded documents also enforce the byte bound")
rejected(function(v) v.roster.version = 2 end, "unsupported roster schema is rejected")
rejected(function(v) v.roster.scopes[1].updated_at_ms = -1 end, "roster modification time must be a timestamp")
rejected(function(v) v.roster.scopes[1].accounts[1].reading_ids = "source" end, "roster associations must be arrays")
rejected(function(v) table.insert(v.roster.scopes, v.roster.scopes[1]) end, "duplicate roster scopes are rejected")
rejected(function(v) table.insert(v.roster.scopes[1].accounts, v.roster.scopes[1].accounts[1]) end, "duplicate configured membership is rejected")
check(snapshot.decode(string.rep(" ", 1048577)) == nil, "raw JSON documents enforce the byte bound")
local maximum = envelope("maximum", tern.json.array())
for i = 1, 1000 do maximum.readings[i] = reading("source-" .. i, "account-" .. i, nil, 1000) end
check(snapshot.decode(maximum) ~= nil, "the reading-count boundary is inclusive")
local windows = envelope("windows", { reading("source", "account", 10, 1000) })
for i = 2, 65 do windows.readings[1].windows[i] = windows.readings[1].windows[1] end
check(snapshot.decode(windows) ~= nil, "the window-count boundary is inclusive")
return "PASS snapshot: " .. checks .. " checks"
