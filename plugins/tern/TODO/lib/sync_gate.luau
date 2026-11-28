--!strict
-- Remembers which plan revision the board last matched, so an unchanged plan costs no board read. MIT.
-- The memory is only valid while sync stays on: with sync off the cards can be edited or deleted by hand and
-- nothing watches them, so turning sync on (or pointing it at another session) forgets everything and the
-- next tick reads the board and repairs it.
local settings = require("./settings")
local gate = {}

-- A pass that succeeded is not final: another window's board write that was already on its way (its claim lapsed
-- and was handed on) may land after our verification read. So a success is remembered as provisional and one more
-- pass runs after VERIFY_MS, which is longer than the claim lease (lib/board_claim LEASE_S = 120 s), by which time
-- any such write has landed. Only a clean delayed pass settles the revision; a pass that fixed something is
-- provisional again. Nothing changing means no further passes, so there is no periodic loop.
gate.VERIFY_MS = 125000

function gate.new()
	local revs: { [string]: number } = {}
	local generation = 0
	local verifyAt: { [string]: number? } = {} -- key -> time from which the provisional pass is re-verified
	local self = {}
	-- nowMs is the clock in milliseconds; without it a provisional entry counts as matching.
	function self.matches(key: string, rev: number, nowMs: number?): boolean
		if revs[key] ~= rev then return false end
		local due = verifyAt[key]
		return not (due and nowMs and nowMs >= due)
	end
	-- A sync pass takes the generation when it starts; its result is remembered only if no reset happened since.
	-- Without that, a pass that was already running when sync was turned off and on again would report success
	-- for a board that was edited in between, and the reset would be undone.
	function self.generation(): number return generation end
	function self.mark(key: string, rev: number, gen: number): boolean
		if gen ~= generation then return false end
		revs[key] = rev
		verifyAt[key] = nil
		return true
	end
	-- A pass for (key, rev) succeeded having made `count` board changes. Settles only a clean re-verification.
	function self.passed(key: string, rev: number, gen: number, count: number, nowMs: number): boolean
		if gen ~= generation then return false end
		local due = verifyAt[key]
		local reverifying = revs[key] == rev and due ~= nil and nowMs >= due
		revs[key] = rev
		verifyAt[key] = if reverifying and count == 0 then nil else nowMs + gate.VERIFY_MS
		return true
	end
	function self.reset() revs = {}; verifyAt = {}; generation += 1 end
	-- Call with the settings before and after every change.
	function self.settingsChanged(before: any, after: any)
		local wasOn = settings.mode(before) == "glitch-sync"
		local isOn = settings.mode(after) == "glitch-sync"
		if not isOn or not wasOn or before.attach ~= after.attach then self.reset() end
	end
	return self
end

return gate
