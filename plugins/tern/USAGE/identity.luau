--!strict
-- Only provider-reported, non-secret account fields. Acquisition and modal
-- ownership belong to callers; pane titles, profiles, and model names are not identities.
local identity = {}

export type Identity = {
	id: string,
	label: string,
	canonical_id: string?,
	principal_id: string?,
}

local function trim(value: string): string
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function email(value: string): string?
	-- Accept one complete email field, not an email mentioned in prose, a
	-- masked address, or an API-key/authentication-mode description.
	local address = value:match("^([%w.!#$%%&'*+/=?^_`{|}~%-]+@[%w%.%-]+)$")
	if address == nil or address:find("*", 1, true) then return nil end
	local domain = address:match("@(.+)$") :: string
	if not domain:find(".", 1, true) or domain:find("..", 1, true) or domain:match("^[%.%-]") or domain:match("[%.%-]$") then return nil end
	return address
end

local function component(value: string): string
	-- Length-prefix opaque scopes so embedded separators cannot collide.
	return tostring(#value) .. ":" .. value
end

local function scoped(principal: string, label: string, scopes: any?): Identity?
	local id = principal
	if scopes ~= nil then
		if type(scopes) ~= "table" then return nil end
		for _, scope in { "organization", "workspace", "tenant" } do
			local name, reported_id = scopes[scope], scopes[scope .. "_id"]
			for _, key in { scope, scope .. "_id" } do
				local field = scopes[key]
				if field ~= nil and (type(field) ~= "string" or trim(field) == "" or #field > 1024 or field:find("%c")) then return nil end
			end
			local scoped = reported_id or name
			if scoped ~= nil then
				id ..= ":" .. scope .. (if reported_id ~= nil then "-id:" else "-name:") .. component(trim(scoped))
				label ..= " · " .. trim(name or scoped)
			end
		end
	end
	return { id = id, label = label, canonical_id = id, principal_id = principal }
end

function identity.email(provider: string, value: any, scopes: any?): Identity?
	if type(value) ~= "string" or not provider:match("^[a-z][a-z0-9_%-]*$") then return nil end
	local address = email(trim(value))
	if address == nil then return nil end
	return scoped(provider .. ":email:" .. component(address:lower()), address, scopes)
end

function identity.provider_id(provider: string, value: any, scopes: any?, label: string?): Identity?
	if type(value) ~= "string" or not provider:match("^[a-z][a-z0-9_%-]*$") then return nil end
	value = trim(value)
	if value == "" or #value > 512 or value:find("%c") then return nil end
	return scoped(provider .. ":id:" .. component(value), label or value, scopes)
end

function identity.metadata(provider: string, document: any): Identity?
	if type(document) ~= "table" then return nil end
	if document.principal_kind == "email" then
		return identity.email(provider, document.principal, document)
	elseif document.principal_kind == "id" then
		return identity.provider_id(provider, document.principal, document, document.label)
	end
	return nil
end

-- Only aliases explicitly connected by the same provider identity document.
-- Names and IDs can differ between a provider's status view and source metadata.
function identity.aliases(provider: string, document: any): { string }
	local result: { string } = {}
	if identity.metadata(provider, document) == nil then return result end
	local variants = { { principal = document.principal, principal_kind = document.principal_kind } }
	for _, scope in { "organization", "workspace", "tenant" } do
		local count = #variants
		for index = 1, count do
			for _, field in { scope, scope .. "_id" } do
				if document[field] ~= nil then
					local variant = table.clone(variants[index])
					variant[field] = document[field]
					table.insert(variants, variant)
				end
			end
		end
	end
	for _, variant in variants do
		local account = identity.metadata(provider, variant)
		if account ~= nil and table.find(result, account.id) == nil then table.insert(result, account.id) end
	end
	return result
end

return identity
