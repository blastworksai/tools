--!strict
-- Every owner-visible string of "Forget this orchestration…". Dynamic values are substituted as plain text only; they are
-- never interpreted as markup or format directives.
local M = {}
M.MENU = "Forget this orchestration…"
M.CHECKING = "Checking whether this orchestration can be forgotten…"
M.BLOCKED = "Cannot forget yet. Review the blockers below."
M.CLOSE_PANES = "Close these panes using Tern, then check again:"
M.CHECK_AGAIN = "Check again"
M.BACK = "Back"
M.KEEP = "Keep orchestration"
M.FORGET = "Forget orchestration"
M.CHANGED = "The orchestration changed. Check again before forgetting it."
M.OWNED_ELSEWHERE = "This orchestration is owned elsewhere. Open its owning window."
M.UNSUPPORTED = "Forget requires a reachable SPAWN version that supports it. No discard fence was added."
M.PENDING = "Forgetting is pending. This orchestration remains fenced. Resolve the listed blockers, then continue."
M.CONTINUE = "Continue forgetting"
M.DONE = "Orchestration forgotten. Mailbox files were kept. You can create a new orchestration."
M.MANUAL_RESET = "Manual reset is the last resort. Resetting ORCH+ removes all its saved orchestrations. Resetting SPAWN also removes its saved agent roster and dispatch state. Resetting either plugin does not prove that existing agents have stopped."
local function plain(value: any): string
	local text = if type(value) == "string" then value else ""
	text = text:gsub("%c", " ")
	return text:sub(1, 256)
end
function M.confirm(name: any): string
	return "Forget “" .. plain(name) .. "”? This discards its saved orchestration state and unfinished obligations. Documents, sources, Git, mailbox files, your SPAWN agent roster and other orchestrations stay. After confirmation, this cannot be cancelled. If execution changes before removal, the orchestration stays fenced until forgetting can finish."
end
-- One blocker row. Only `pane` rows exclusively owned by this orchestration are told to close through Tern; shared panes
-- carry the explicit instruction not to.
function M.row(blocker: any): string
	local agent, host = plain(blocker.agent), plain(blocker.host)
	if blocker.kind == "pane" then return agent .. " · pane " .. plain(blocker.pane) .. " · " .. host end
	if blocker.kind == "unobservable" then return agent .. " · cannot be checked on " .. host end
	if blocker.kind == "uncertain" then return agent .. " · execution outcome is uncertain on " .. host end
	return agent .. " · pane " .. plain(blocker.pane) .. " on " .. host .. " is associated with another orchestration. Do not close it for this reset."
end
return M
