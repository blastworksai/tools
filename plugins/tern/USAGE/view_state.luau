--!strict
-- Display state only: the companion owns acquisition and its persisted cadence.
local companion = require("./companion")
local view_state = {}
function view_state.new(changed: () -> ())
	local self: any = { progress = nil, preferences = nil, problem = nil, preference_problem = nil,
		requesting = false, reading = false, reading_preferences = false, saving = false, revision = 0, preference_revision = 0 }
	-- done(problem, fresh_cx) lets a palette Refresh report a failure that no
	-- open view would otherwise show.
	function self:refresh(done: ((string?, any) -> ())?)
		if self.requesting then return end
		self.requesting = true
		self.revision += 1
		changed()
		companion.request("usage_refresh", {}, function(value, err, fresh)
			self.requesting = false
			self.revision += 1
			self.progress = value or self.progress
			self.problem = if err then err.message else nil
			changed()
			if done ~= nil then done(self.problem, fresh) end
		end)
	end
	function self:poll()
		if self.reading then return end
		self.reading = true
		local revision = self.revision
		companion.request("usage_status", {}, function(value, err)
			self.reading = false
			-- A status read that started before a newer refresh acknowledgement
			-- cannot overwrite it; still report completion so pollers re-arm.
			if revision == self.revision then
				self.progress = value or self.progress
				self.problem = if err then err.message else nil
			end
			changed()
		end)
	end
	function self:read_preferences()
		if self.saving or self.reading_preferences then return end
		self.reading_preferences = true
		local revision = self.preference_revision
		companion.request("usage_preferences", {}, function(value, err)
			self.reading_preferences = false
			if revision ~= self.preference_revision then return end
			self.preferences = value or self.preferences
			self.preference_problem = if err then err.message else nil
			changed()
		end)
	end
	function self:set_interval(seconds: number)
		if seconds ~= math.floor(seconds) or (seconds ~= 0 and (seconds < 60 or seconds > 86400)) then
			self.preference_problem = "Enter whole seconds from 60 to 86400, or choose Manual."
			changed(); return
		end
		self.desired_interval = seconds
		self.preference_revision += 1
		if self.saving then return end
		self.saving = true
		changed()
		companion.request("usage_preferences", { refresh_interval_seconds = seconds }, function(value, err)
			self.saving = false
			self.preferences = value or self.preferences
			self.preference_problem = if err then err.message else nil
			local desired = self.desired_interval
			self.desired_interval = nil
			if desired ~= seconds then self:set_interval(desired) else changed() end
		end)
	end
	-- Failures are counted here; the configuration pane and account rows name them.
	function self:text(): string
		if self.requesting then return "Requesting refresh…" end
		if self.problem then return "Refresh unavailable: " .. self.problem end
		local progress = self.progress
		if progress == nil then return "Loading refresh status…" end
		if progress.state == "running" then
			return "Refreshing · " .. tostring(progress.completed or 0) .. "/" .. tostring(progress.total or 0) .. " accounts processed"
		end
		if type(progress.last_completed_ms) == "number" and progress.last_completed_ms > 0 then
			local failures = #(progress.failures or {})
			return "Refreshed " .. os.date("%H:%M:%S", math.floor(progress.last_completed_ms / 1000))
				.. (if failures > 0 then " · " .. tostring(failures) .. (if failures == 1 then " issue" else " issues") else "")
		end
		return "Manual refresh ready · no refresh completed yet"
	end
	return self
end
return view_state
