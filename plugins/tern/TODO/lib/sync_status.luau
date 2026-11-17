--!strict
-- The sync status line shown in TODO Settings, and the repaint of an already open Settings pane. MIT.
-- Settings is a canvas pane drawn from `settings.draw(..., status)`; assigning a new status does not redraw it.
-- A sync pass ends in a callback without a window context, so the repaint is a zero-delay timer: a timer callback
-- receives a fresh window context (tern.d.luau tern.timer), with which `cx.canvas:set` can redraw the pane.
-- The pane is repainted whenever what it RENDERS differs from what it last drew: `env.key()` names everything drawn
-- besides the status text (mode, attachment, board name and link), and the status text is added here. A status that
-- repeats while the board beside it changed is therefore still repainted.
local status = {}

export type Env = {
	timer: (number, (any?) -> ()) -> any,
	pane: (any) -> number?, -- the open Settings pane, if any
	paint: (any, number) -> (),
	key: (() -> string)?, -- the rendered state other than the status text (none: the status text alone)
}

function status.new(env: Env)
	local current: string? = nil
	local painted: string? = nil -- the render key of the last paint (or of a moment with no pane to paint)
	local queued: string? = nil -- the render key a repaint is already waiting for
	local self = {}
	local function renderKey(): string return (if env.key then env.key() else "") .. "\0" .. (current or "") end
	function self.get(): string? return current end
	-- Whoever draws the pane (window paint, first open) calls this, so `painted` is what is really on screen.
	function self.drawn() painted = renderKey() end
	-- Redraw the open pane now, even when nothing is known to differ.
	function self.repaint()
		env.timer(0, function(fresh: any?)
			queued = nil
			if fresh == nil then return end
			local pane = env.pane(fresh)
			if pane then env.paint(fresh, pane) else painted = renderKey() end
		end)
	end
	-- Repaint when the rendered state changed since the last paint. Call it wherever that state can move.
	function self.check()
		local key = renderKey()
		if key == painted or key == queued then return end
		queued = key
		self.repaint()
	end
	function self.set(text: string?)
		if text == current then return end
		current = text
		self.check()
	end
	return self
end

return status
