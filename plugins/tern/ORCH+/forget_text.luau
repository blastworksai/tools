--!strict
-- Every owner-visible string of "Forget this orchestration…". Dynamic values are substituted as plain text only; they are
-- never interpreted as markup or format directives.
local M = {}
M.MENU = "Forget this orchestration…"
M.CHECKING = "Checking whether this orchestration can be forgotten…"
M.BLOCKED = "Cannot forget yet. Review the blockers below."
M.PARTICIPANTS = "Agents whose execution is not checked:"
M.RESIDUAL = "Agents still running may continue their assignments and use any approvals already received; Forget neither stops them nor revokes that authority."
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
-- The confirmation: the fixed words, then the informational participants (when there are any), then the residual notice verbatim.
function M.confirm(name: any, participants: any?, omitted: any?): string
	local lines = { "Forget “" .. plain(name) .. "”? This discards its saved orchestration state and unfinished obligations. Documents, sources, Git, mailbox files, your SPAWN agent roster and other orchestrations stay. After confirmation, this cannot be cancelled. If execution changes before removal, the orchestration stays fenced until forgetting can finish." }
	if type(participants) == "table" and #participants > 0 then
		table.insert(lines, M.PARTICIPANTS)
		for _, row in participants do table.insert(lines, M.row(row)) end
		if type(omitted) == "number" and omitted > 0 then table.insert(lines, M.additional(omitted)) end
	end
	table.insert(lines, M.RESIDUAL)
	return table.concat(lines, "\n")
end
-- Proposed verbatim for the owner's approval: "{count} additional blockers."
function M.additional_blockers(count: any): string
	return string.format("%d additional blockers.", if type(count) == "number" then count else 0)
end
function M.additional(count: any): string
	return string.format("%d additional participants whose execution is not checked.", if type(count) == "number" then count else 0)
end
-- One blocker row or participant row. No row ever asks the owner to close a pane: Forget does not observe panes.
function M.row(blocker: any): string
	local agent, host = plain(blocker.agent), plain(blocker.host)
	if blocker.kind == "unobservable" then return agent .. " · cannot be checked on " .. host end
	if blocker.kind == "uncertain" then return agent .. " · execution outcome is uncertain on " .. host end
	return agent .. " · " .. host
end
return M
