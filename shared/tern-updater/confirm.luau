--!strict
-- Builds the update confirmation picker items and the remote install command.

local Confirm = {}

Confirm.RELOAD = "Downloads from GitHub, then Tern reloads all its plugins"
Confirm.ORCH = "Running ORCH+ controllers pause until you run ORCH+ Reload recovery guide"

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

function Confirm.remote_command(src: string): string
	if string.find(src, "'", 1, true) then
		error("source path contains a single quote: " .. src)
	end
	return "tern plugin install --force '" .. src .. "'"
end

return Confirm
