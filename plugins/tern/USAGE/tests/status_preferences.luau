-- Run in Tern: assert(loadstring(tern.fs.read(TEST_PATH)))(PLUGIN_DIR)
local root = ...
assert(type(root) == "string", "pass the plugin directory")
local environment = getfenv()
local chunk = assert(loadstring(tern.fs.read(root .. "/status_preferences.luau"), "status_preferences"))
setfenv(chunk, setmetatable({ tern = tern, require = function() error("pure module") end }, { __index = environment }))
local prefs = chunk()
local checks = 0
local function check(value, why) assert(value, why); checks += 1 end
-- An in-memory store; `data` stands for the plugin data dir, `present` for the files in it.
local function store(initial, present)
	local self = { kv = initial or {}, sets = 0, files = present or {}, data = "/fixture/usage" }
	self.get = function(key) return self.kv[key] end
	self.set = function(key, value) self.sets += 1; self.kv[key] = value end
	self.exists = function(path) return self.files[path] == true end
	return self
end
local function ids(list) return table.concat(list, ",") end

-- Fresh cold start: Off, empty, migration already complete, written once.
local fresh = store()
local loaded = prefs.load(fresh)
check(loaded.enabled == false and loaded.migration_complete == true and #loaded.selected == 0 and loaded.version == 1, "fresh install starts Off and empty")
check(fresh.sets == 1 and fresh.kv[prefs.KEY].enabled == false, "the fresh decision is stored")
fresh.files["/fixture/usage/companion"] = true
check(prefs.load(fresh).enabled == false and fresh.sets == 1, "companion data created later by this install never turns a fresh install into a retained one")

-- Retained upgrade: companion data, or an old kv setting, with no record: master On, migration pending.
for _, evidence in { { files = { ["/fixture/usage/companion"] = true } }, { kv = { usage_layout = "wide" } }, { kv = { usage_python = "python3" } } } do
	local retained = store(evidence.kv, evidence.files)
	local pending = prefs.load(retained)
	check(pending.enabled == true and pending.migration_complete == false and #pending.selected == 0, "retained data migrates master On with the selection pending")
	check(retained.kv[prefs.KEY].migration_complete == false and prefs.load(retained).migration_complete == false and retained.sets == 1,
		"the pending record is stored once and read back as pending")
end
-- Migration picks exactly the old first three, in the given (provider) order.
local pending = prefs.load(store(nil, { ["/fixture/usage/companion"] = true }))
local done = prefs.complete_migration(pending, { "a", "b", "c", "d", "e" })
check(done.migration_complete and done.enabled and ids(done.selected) == "a,b,c", "retained upgrade selects exactly the legacy first-three projection")
check(prefs.complete_migration(done, { "x" }) == done, "migration runs once")
check(ids(prefs.complete_migration(pending, {}).selected) == "" and prefs.complete_migration(pending, {}).enabled, "an empty roster completes migration with no selection, master On")
check(ids(prefs.complete_migration(pending, { "a", "b" }).selected) == "a,b", "a roster of fewer than three selects them all")
local off_pending = prefs.with_enabled(pending, false)
check(off_pending.migration_complete == false and ids(prefs.complete_migration(off_pending, { "a" }).selected) == "a" and not prefs.complete_migration(off_pending, { "a" }).enabled,
	"turning the master Off while migration is pending keeps the migration and the choice")

-- Reinstall with retained data AND an existing record: the record wins, no second migration.
local existing = store({ [prefs.KEY] = { version = 1, migration_complete = true, enabled = false, selected = { "keep" } } }, { ["/fixture/usage/companion"] = true })
local reinstalled = prefs.load(existing)
check(reinstalled.enabled == false and ids(reinstalled.selected) == "keep" and existing.sets == 0, "an existing record is never re-migrated or rewritten")

-- Corrupted state: Off/empty and repaired; an unreadable store changes nothing.
for _, garbage in { "text", 5, { version = 2, migration_complete = true, enabled = true, selected = {} },
	{ version = 1, migration_complete = "yes", enabled = true, selected = {} },
	{ version = 1, migration_complete = true, enabled = true, selected = "a" },
	{ version = 1, migration_complete = true, enabled = true, selected = {}, extra = true },
	{ version = 1, migration_complete = true, enabled = true } } do
	local damaged = store({ [prefs.KEY] = garbage }, { ["/fixture/usage/companion"] = true })
	local reset = prefs.load(damaged)
	check(reset.enabled == false and reset.migration_complete == true and #reset.selected == 0 and damaged.kv[prefs.KEY].enabled == false,
		"a corrupted record resets to Off and empty, even beside retained data")
end
local unreadable = store()
unreadable.get = function() error("kv unreadable") end
check(prefs.load(unreadable).enabled == false and unreadable.sets == 0, "an unreadable store yields Off without writing")

-- Normalisation: duplicates, invalid ids, bound; preserved while Off.
local normalised = prefs.decode({ version = 1, migration_complete = true, enabled = false,
	selected = { "a", "a", 5, "", "b\n", string.rep("x", prefs.MAX_ID + 1), "c" } })
check(normalised ~= nil and ids(normalised.selected) == "a,c" and normalised.enabled == false, "duplicate and invalid ids drop, a selection survives master Off")
local many = {}
for index = 1, prefs.MAX_SELECTED + 10 do table.insert(many, "id-" .. index) end
check(#prefs.decode({ version = 1, migration_complete = true, enabled = true, selected = many }).selected == prefs.MAX_SELECTED, "the selection is bounded")
local round = store()
check(prefs.save(round, normalised) and round.kv[prefs.KEY].selected[2] == "c" and prefs.save({ set = function() error("full") end }, normalised) == false, "save stores the closed shape and reports a failing store")

-- Roster changes: reorder, rename, removal and reappearance never lose or invent a selection.
local one = { id = "spawn:1:s:a", account_label = "A" }
local two = { id = "spawn:1:s:b", account_label = "B" }
local current = { selected = { one.id }, enabled = true, migration_complete = true }
local set = prefs.selected_set(current)
check(prefs.row_selected(set, one) and not prefs.row_selected(set, two), "selection follows the id")
check(prefs.row_selected(set, { id = "other", also_configured = { { id = one.id } } }), "a row that also answers to the id is selected")
check(prefs.row_selected(set, { id = one.id, account_label = "Renamed" }) and not prefs.row_selected(set, { id = "spawn:1:s:a2", account_label = "A" }),
	"rename keeps the selection; the label never identifies")
local roster = prefs.roster_map({ two, one })
check(roster[one.id] == one.id and roster[two.id] == two.id, "reorder does not matter to the roster map")
local removed = prefs.roster_map({ two })
local after_removal, why = prefs.with_selected(current, one.id, false, removed)
check(after_removal == nil and why == "unknown_account", "a removed account cannot be toggled from stale UI")
local stays = prefs.selected_set(current)
check(stays[one.id] == true, "removal keeps the stored id, drawing no row")
local reappeared = prefs.with_selected(current, two.id, true, prefs.roster_map({ one, two, }))
check(ids(reappeared.selected) == one.id .. "," .. two.id, "a second account is added after the first")
local cleared = prefs.with_selected(reappeared, one.id, false, roster)
check(ids(cleared.selected) == two.id, "unticking removes only that account")
local aliased = prefs.roster_map({ { id = "row", also_configured = { { id = "alias" } } } })
check(ids(prefs.with_selected(current, "alias", true, aliased).selected) == one.id .. ",row", "a selection through an alias is stored under the row id")
check(ids(prefs.with_selected({ selected = { "alias" }, enabled = true, migration_complete = true }, "row", false, aliased).selected) == "", "unticking clears the alias form too")
-- Full selection: stale ids give way, live ones do not.
local full = { selected = {}, enabled = true, migration_complete = true }
local big = {}
for index = 1, prefs.MAX_SELECTED do
	local row = { id = "r" .. index }
	table.insert(big, row)
	full = prefs.with_selected(full, row.id, true, prefs.roster_map(big))
end
local extra = { id = "extra" }
table.insert(big, extra)
local refused, full_why = prefs.with_selected(full, extra.id, true, prefs.roster_map(big))
check(refused == nil and full_why == "selection_full", "a full selection of live accounts refuses another")
local shrunk = {}
for index = 2, #big do table.insert(shrunk, big[index]) end
local made_room = prefs.with_selected(full, extra.id, true, prefs.roster_map(shrunk))
check(made_room ~= nil and #made_room.selected == prefs.MAX_SELECTED and made_room.selected[prefs.MAX_SELECTED] == "extra", "a stale id gives way to a new tick")
check(prefs.with_enabled(current, false).enabled == false and ids(prefs.with_enabled(current, false).selected) == one.id, "master Off preserves the selection")
check(#prefs.roster_map({}) == 0 and next(prefs.roster_map({})) == nil, "an empty roster maps to nothing")
return "PASS status_preferences: " .. checks .. " checks"
