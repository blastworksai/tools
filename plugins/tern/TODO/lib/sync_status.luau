--!strict
-- The sync status line shown in TODO Settings, and the repaint of an already open Settings pane when it changes. MIT.
-- Settings is a canvas pane drawn from `settings.draw(..., status)`; assigning a new status does not redraw it.
-- A sync pass ends in a callback without a window context, so the repaint is a zero-delay timer: a timer callback
-- receives a fresh window context (tern.d.luau tern.timer), with which `cx.canvas:set` can redraw the pane.
local status = {}

export type Env = {
	timer: (number, (any?) -> ()) -> any,
	pane: (any) -> number?, -- the open Settings pane, if any
	paint: (any, number) -> (),
}

function status.new(env: Env)
	local current: string? = nil
	local self = {}
	function self.get(): string? return current end
	-- Redraw the open pane even when the text is unchanged (what is drawn around the text may have changed).
	function self.repaint()
		env.timer(0, function(fresh: any?)
			if fresh == nil then return end
			local pane = env.pane(fresh)
			if pane then env.paint(fresh, pane) end
		end)
	end
	function self.set(text: string?)
		if text == current then return end
		current = text
		self.repaint()
	end
	return self
end

return status
