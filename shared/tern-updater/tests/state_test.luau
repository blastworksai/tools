-- State contract: status × operation grid (★ cells), cold start, install-error mapping,
-- input never mutated.
local State = require("../state")

local NOW = 1800000000
local H6 = State.INTERVAL
local T10 = State.PENDING_TIMEOUT

local function snapshot(t: { [string]: any }): { [string]: any }
	local out = {}
	for k, v in t do
		out[k] = v
	end
	return out
end

local function same(a: { [string]: any }, b: { [string]: any }): boolean
	for k, v in a do
		if b[k] ~= v then
			return false
		end
	end
	for k, v in b do
		if a[k] ~= v then
			return false
		end
	end
	return true
end

local function no_pending(r: { [string]: any }): boolean
	return r.pending_from == nil and r.pending_to == nil and r.pending_at == nil and r.pending_orch == nil
end

local function pending(at: number, orch: boolean?): { [string]: any }
	return {
		checked_at = NOW - 60,
		remote = "0.2.0",
		notified = "0.2.0",
		pending_from = "0.1.0",
		pending_to = "0.2.0",
		pending_at = at,
		pending_orch = orch == true,
	}
end

return {
	{"constants and ORCH line", function()
		assert(State.KEY == "updater.v1" and State.INTERVAL == 21600 and State.PENDING_TIMEOUT == 600)
		assert(State.ORCH == "Running ORCH+ controllers pause until you run ORCH+ Reload recovery guide")
	end},

	-- due
	{"due: cold start (nil record) is due", function()
		assert(State.due(nil, NOW) == true)
		assert(State.due({}, NOW) == true)
	end},
	{"grid checked<6h x background tick: not due (no fetch)", function()
		assert(State.due({ checked_at = NOW - 60 }, NOW) == false)
		assert(State.due({ checked_at = NOW - H6 + 1 }, NOW) == false)
	end},
	{"due: steady state due again at 6 h", function()
		assert(State.due({ checked_at = NOW - H6 }, NOW) == true)
		assert(State.due({ checked_at = NOW - H6 - 1 }, NOW) == true)
	end},
	{"due: checked_at in the future (clock moved back) is due", function()
		assert(State.due({ checked_at = NOW + 5 }, NOW) == true)
	end},
	{"grid pending<10min x background tick: not due while busy", function()
		assert(State.due({ pending_from = "0.1.0", pending_to = "0.2.0", pending_at = NOW - 10 }, NOW) == false)
		-- stale journal no longer blocks; the 6 h interval still applies on its own
		assert(State.due({ pending_from = "0.1.0", pending_to = "0.2.0", pending_at = NOW - T10 }, NOW) == true)
		assert(State.due(pending(NOW - T10), NOW) == false)
	end},
	{"due: non-scalar garbage in kv is ignored", function()
		assert(State.due({ checked_at = "yesterday" } :: any, NOW) == true)
	end},

	-- outcome
	{"grid none x load: outcome none (cold start)", function()
		assert(State.outcome(nil, "0.1.0") == "none")
		assert(State.outcome({ checked_at = NOW }, "0.1.0") == "none")
	end},
	{"grid notified=v remote still v x load: seeds update (survives reload)", function()
		assert(State.outcome({ checked_at = NOW, remote = "0.2.0", notified = "0.2.0" }, "0.1.0") == "update")
	end},
	{"outcome: steady state current / ahead / unknown", function()
		assert(State.outcome({ remote = "0.2.0" }, "0.2.0") == "current")
		assert(State.outcome({ remote = "0.2.0" }, "0.3.0") == "ahead")
		assert(State.outcome({ remote = "0.2" }, "0.1.0") == "unknown")
		assert(State.outcome({ remote = "0.2.0" }, "dev") == "unknown")
	end},

	-- after_check
	{"grid none x background tick: cold start checks and notices update", function()
		local r, outcome, notice = State.after_check(nil, NOW, "0.1.0", "0.2.0", nil, "FIXTURE")
		assert(outcome == "update")
		assert(r.checked_at == NOW and r.remote == "0.2.0" and r.notified == "0.2.0")
		assert(notice ~= nil and notice.level == "info")
		assert(notice.text == "FIXTURE 0.2.0 is available (you have 0.1.0)")
		assert(notice.sub == nil)
	end},
	{"grid notified=v remote still v x background tick: no second notice", function()
		local before = { checked_at = NOW - H6, remote = "0.2.0", notified = "0.2.0" }
		local r, outcome, notice = State.after_check(before, NOW, "0.1.0", "0.2.0", nil, "FIXTURE")
		assert(outcome == "update" and notice == nil)
		assert(r.checked_at == NOW and r.remote == "0.2.0" and r.notified == "0.2.0")
	end},
	{"grid notified=v remote now v+1 x background tick: notices again for v+1", function()
		local before = { checked_at = NOW - H6, remote = "0.2.0", notified = "0.2.0" }
		local r, outcome, notice = State.after_check(before, NOW, "0.1.0", "0.3.0", nil, "FIXTURE")
		assert(outcome == "update")
		assert(notice ~= nil and notice.text == "FIXTURE 0.3.0 is available (you have 0.1.0)")
		assert(r.remote == "0.3.0" and r.notified == "0.3.0")
	end},
	{"grid installed ahead of GitHub x background tick: no notice, seeds ahead", function()
		local r, outcome, notice = State.after_check(nil, NOW, "0.3.0-dev", "0.2.0", nil, "FIXTURE")
		assert(outcome == "ahead" and notice == nil)
		assert(r.remote == "0.2.0" and r.notified == nil)
		assert(State.outcome(r, "0.3.0-dev") == "ahead")
	end},
	{"grid unparsable version x background tick: no notice, seeds unknown", function()
		local r, outcome, notice = State.after_check(nil, NOW, "0.1.0", "next", nil, "FIXTURE")
		assert(outcome == "unknown" and notice == nil and r.notified == nil)
		assert(State.outcome(r, "0.1.0") == "unknown")
		local _, outcome2, notice2 = State.after_check(nil, NOW, "0.1", "0.2.0", nil, "FIXTURE")
		assert(outcome2 == "unknown" and notice2 == nil)
	end},
	{"after_check: current is not noticed", function()
		local r, outcome, notice = State.after_check({ remote = "0.1.0" }, NOW, "0.2.0", "0.2.0", nil, "FIXTURE")
		assert(outcome == "current" and notice == nil and r.notified == nil)
	end},
	{"after_check: error keeps remote, stamps checked_at (cold start and steady)", function()
		local r, outcome, notice = State.after_check(nil, NOW, "0.1.0", nil, "HTTP 500", "FIXTURE")
		assert(outcome == "error" and notice == nil and r.checked_at == NOW and r.remote == nil)
		local before = { checked_at = NOW - H6, remote = "0.2.0", notified = "0.2.0" }
		local r2, outcome2, notice2 = State.after_check(before, NOW, "0.1.0", "0.9.0", "offline", "FIXTURE")
		assert(outcome2 == "error" and notice2 == nil)
		assert(r2.checked_at == NOW and r2.remote == "0.2.0" and r2.notified == "0.2.0")
		assert(State.outcome(r2, "0.1.0") == "update")
	end},
	{"after_check: keeps a pending journal untouched", function()
		local r = State.after_check(pending(NOW - 10), NOW, "0.1.0", "0.2.0", nil, "FIXTURE")
		assert(r.pending_from == "0.1.0" and r.pending_to == "0.2.0" and r.pending_at == NOW - 10)
	end},

	-- begin / busy
	{"begin: writes the pending journal", function()
		local r = State.begin({ remote = "0.2.0" }, NOW, "0.1.0", "0.2.0", true)
		assert(r.pending_from == "0.1.0" and r.pending_to == "0.2.0" and r.pending_at == NOW)
		assert(r.pending_orch == true and r.remote == "0.2.0")
		local r2 = State.begin(nil, NOW, "0.1.0", "0.2.0", false)
		assert(r2.pending_orch == false and r2.pending_at == NOW)
	end},
	{"grid pending<10min x Update: run refuses (busy)", function()
		assert(State.busy(State.begin(nil, NOW, "0.1.0", "0.2.0", false), NOW) == true)
		assert(State.busy(pending(NOW - T10 + 1), NOW) == true)
	end},
	{"grid pending>=10min x Update: allowed again (not busy)", function()
		assert(State.busy(pending(NOW - T10), NOW) == false)
		assert(State.busy(nil, NOW) == false)
		assert(State.busy({ remote = "0.2.0" }, NOW) == false)
		assert(State.busy(pending(NOW + 30), NOW) == false) -- future start: stale, never blocks
	end},

	-- reconcile
	{"grid none x load: reconcile is a no-op (cold start)", function()
		local r, notice = State.reconcile(nil, NOW, "0.1.0", "FIXTURE")
		assert(notice == nil and next(r) == nil)
		local before = { checked_at = NOW, remote = "0.2.0", notified = "0.2.0" }
		local r2, notice2 = State.reconcile(before, NOW, "0.1.0", "FIXTURE")
		assert(notice2 == nil and same(r2, before) and r2 ~= before)
	end},
	{"grid pending<10min x load: installed == from keeps pending", function()
		local before = pending(NOW - 30)
		local r, notice = State.reconcile(before, NOW, "0.1.0", "FIXTURE")
		assert(notice == nil and same(r, before))
		local r2, notice2 = State.reconcile(before, NOW, nil, "FIXTURE")
		assert(notice2 == nil and same(r2, before))
	end},
	{"grid pending installed == to x load: success notice, clear", function()
		local r, notice = State.reconcile(pending(NOW - 30), NOW, "0.2.0", "FIXTURE")
		assert(notice ~= nil and notice.level == "success" and notice.text == "FIXTURE updated to 0.2.0")
		assert(notice.sub == nil)
		assert(no_pending(r) and r.remote == "0.2.0" and r.checked_at == NOW - 60)
		assert(State.outcome(r, "0.2.0") == "current")
	end},
	{"grid pending installed == to x load: ORCH sub when pending_orch", function()
		local r, notice = State.reconcile(pending(NOW - 30, true), NOW, "0.2.0", "FIXTURE")
		assert(notice ~= nil and notice.level == "success" and notice.sub == State.ORCH)
		assert(no_pending(r))
	end},
	{"grid pending installed = third version x load: success naming actual version, clear", function()
		local r, notice = State.reconcile(pending(NOW - 30), NOW, "0.2.1", "FIXTURE")
		assert(notice ~= nil and notice.level == "success" and notice.text == "FIXTURE updated to 0.2.1")
		assert(no_pending(r))
		-- also after the timeout: a changed version is still a success
		local _, late = State.reconcile(pending(NOW - T10 * 3), NOW, "0.2.1", "FIXTURE")
		assert(late ~= nil and late.level == "success")
	end},
	{"grid pending>=10min installed == from x load: error didn't complete, clear", function()
		local r, notice = State.reconcile(pending(NOW - T10), NOW, "0.1.0", "FIXTURE")
		assert(notice ~= nil and notice.level == "error")
		assert(notice.text == "FIXTURE update to 0.2.0 didn't complete; still 0.1.0")
		assert(no_pending(r) and r.remote == "0.2.0" and r.notified == "0.2.0")
		assert(State.busy(r, NOW) == false and State.outcome(r, "0.1.0") == "update")
	end},

	-- install_failed: one test per mapping row
	{"install error: installing from git needs git", function()
		local r, n = State.install_failed(pending(NOW), 1, "error: installing from git needs git on PATH\n", false)
		assert(n.level == "error" and n.text == "Updating needs git on this machine" and n.sub == nil)
		assert(no_pending(r) and r.remote == "0.2.0")
	end},
	{"install error: is linked", function()
		local _, n = State.install_failed(pending(NOW), 1, "error: plugin fixture is linked; unlink it first", false)
		assert(n.level == "error" and n.text == "This is a development copy; update it from its source folder")
	end},
	{"install error: git clone and failed", function()
		local stderr = "\n  error: git clone of https://x failed: exit 128  \nfatal: repository not found\n"
		local _, n = State.install_failed(pending(NOW), 1, stderr, false)
		assert(n.level == "error" and n.text == "Couldn't download from GitHub")
		assert(n.sub == "error: git clone of https://x failed: exit 128")
	end},
	{"install error: is not a plugin", function()
		local stderr = "\r\nerror: /tmp/stage/FIXTURE is not a plugin (no plugin.toml)\r\nmore\r\n"
		local _, n = State.install_failed(pending(NOW), 1, stderr, false)
		assert(n.level == "error" and n.text == "The published copy is broken; nothing was changed")
		assert(n.sub == "error: /tmp/stage/FIXTURE is not a plugin (no plugin.toml)")
	end},
	{"install error: timed_out", function()
		local r, n = State.install_failed(pending(NOW), -1, "Cloning into...\n", true)
		assert(n.level == "error" and n.text == "Update timed out; nothing was changed")
		assert(no_pending(r))
		local _, n2 = State.install_failed(nil, -1, "error: git clone failed", true)
		assert(n2.text == "Update timed out; nothing was changed")
	end},
	{"install error: anything else, first non-empty line clipped to 200", function()
		local _, n = State.install_failed(pending(NOW), 2, "\n   \nboom: disk full\nsecond\n", false)
		assert(n.level == "error" and n.text == "Update failed" and n.sub == "boom: disk full")
		local long = string.rep("x", 250)
		local _, n2 = State.install_failed(nil, 2, long, false)
		assert(n2.sub == string.rep("x", 200))
		local _, n3 = State.install_failed(nil, 2, "", false)
		assert(n3.text == "Update failed" and n3.sub == nil)
		local wide = string.rep("é", 150) -- 300 bytes
		local _, n4 = State.install_failed(nil, 2, wide, false)
		assert(n4.sub == string.rep("é", 100))
		local _, n5 = State.install_failed(nil, 2, nil :: any, false)
		assert(n5.text == "Update failed" and n5.sub == nil)
	end},
	{"install_failed: cold start (nil record) returns an empty record", function()
		local r = State.install_failed(nil, 1, "x", false)
		assert(next(r) == nil)
	end},

	-- immutability
	{"inputs are never mutated and results are new tables", function()
		local before = pending(NOW - 30, true)
		local frozen = snapshot(before)
		local results = {}
		table.insert(results, (State.after_check(before, NOW, "0.1.0", "0.3.0", nil, "FIXTURE")))
		table.insert(results, (State.after_check(before, NOW, "0.1.0", nil, "offline", "FIXTURE")))
		table.insert(results, State.begin(before, NOW, "0.1.0", "0.3.0", false))
		table.insert(results, (State.reconcile(before, NOW, "0.2.0", "FIXTURE")))
		table.insert(results, (State.reconcile(before, NOW, "0.1.0", "FIXTURE")))
		table.insert(results, (State.reconcile(before, NOW + T10, "0.1.0", "FIXTURE")))
		table.insert(results, (State.install_failed(before, 1, "error: git clone failed", false)))
		State.due(before, NOW)
		State.busy(before, NOW)
		State.outcome(before, "0.1.0")
		assert(same(before, frozen))
		for _, r in results do
			assert(r ~= before)
		end
		local plain = { checked_at = NOW, remote = "0.2.0" }
		local r = State.reconcile(plain, NOW, "0.1.0", "FIXTURE")
		assert(r ~= plain and same(r, plain))
		r.remote = "9.9.9"
		assert(plain.remote == "0.2.0")
	end},
	{"records hold scalars only; unknown or non-scalar keys are dropped", function()
		local r = State.reconcile({ remote = "0.2.0", junk = "x", checked_at = { 1 } } :: any, NOW, "0.1.0", "FIXTURE")
		assert(r.remote == "0.2.0" and (r :: any).junk == nil and r.checked_at == nil)
		for _, v in r do
			local kind = type(v)
			assert(kind == "string" or kind == "number" or kind == "boolean")
		end
	end},
}
