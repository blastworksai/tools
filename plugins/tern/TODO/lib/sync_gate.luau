--!strict
-- Remembers which plan revision the board last matched, so an unchanged plan costs no board read. MIT.
-- The memory is only valid while sync stays on: with sync off the cards can be edited or deleted by hand and
-- nothing watches them, so turning sync on (or pointing it at another session) forgets everything and the
-- next tick reads the board and repairs it.
local settings = require("./settings")
local gate = {}

function gate.new()
	local revs: { [string]: number } = {}
	local self = {}
	function self.matches(key: string, rev: number): boolean return revs[key] == rev end
	function self.mark(key: string, rev: number) revs[key] = rev end
	function self.reset() revs = {} end
	-- Call with the settings before and after every change.
	function self.settingsChanged(before: any, after: any)
		local wasOn = settings.mode(before) == "glitch-sync"
		local isOn = settings.mode(after) == "glitch-sync"
		if isOn and (not wasOn or before.attach ~= after.attach) then revs = {} end
		if not isOn then revs = {} end
	end
	return self
end

return gate
