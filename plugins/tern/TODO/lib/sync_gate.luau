--!strict
-- Remembers which plan revision the board last matched, so an unchanged plan costs no board read. MIT.
-- The memory is only valid while sync stays on: with sync off the cards can be edited or deleted by hand and
-- nothing watches them, so turning sync on (or pointing it at another session) forgets everything and the
-- next tick reads the board and repairs it.
local settings = require("./settings")
local gate = {}

function gate.new()
	local revs: { [string]: number } = {}
	local generation = 0
	local self = {}
	function self.matches(key: string, rev: number): boolean return revs[key] == rev end
	-- A sync pass takes the generation when it starts; its result is remembered only if no reset happened since.
	-- Without that, a pass that was already running when sync was turned off and on again would report success
	-- for a board that was edited in between, and the reset would be undone.
	function self.generation(): number return generation end
	function self.mark(key: string, rev: number, gen: number): boolean
		if gen ~= generation then return false end
		revs[key] = rev
		return true
	end
	function self.reset() revs = {}; generation += 1 end
	-- Call with the settings before and after every change.
	function self.settingsChanged(before: any, after: any)
		local wasOn = settings.mode(before) == "glitch-sync"
		local isOn = settings.mode(after) == "glitch-sync"
		if not isOn or not wasOn or before.attach ~= after.attach then self.reset() end
	end
	return self
end

return gate
