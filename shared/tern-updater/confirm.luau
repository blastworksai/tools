--!strict
-- Builds the explicit local/remote update confirmation choices.

local Confirm = {}

Confirm.RELOAD = "Installs the latest repository copy, not a pinned preview; Tern then reloads its plugins"
Confirm.ORCH = "ORCH+ reconnects automatically after reload; unresolved ownership or interrupted operations remain paused for recovery"

export type Remote = { id: number, name: string }

function Confirm.items(args: {
	name: string,
	from: string,
	to: string,
	orch: boolean,
	remotes: { Remote },
}): { { [string]: any } }
	local detail = if args.orch then Confirm.RELOAD .. ". " .. Confirm.ORCH else Confirm.RELOAD
	local items: { { [string]: any } } = {
		{
			label = `Update {args.name} {args.from} → {args.to}`,
			detail = detail,
			choice = "local",
		},
	}
	for _, remote in args.remotes do
		table.insert(items, {
			label = `Update {args.name} here and on {remote.name}`,
			detail = detail,
			choice = "remote",
			host = remote.id,
		})
	end
	table.insert(items, { label = "Cancel", choice = "cancel" })
	return items
end


return Confirm
