-- Run in Tern's Lua runtime: assert(loadstring(tern.fs.read(TEST_PATH)))(PLUGIN_DIR)
local root = ...
assert(type(root) == "string", "pass the plugin directory")
local modules = {}
local environment = getfenv()
local function load(name)
	name = name:gsub("^%./", "")
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(tern.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ require = load }, { __index = environment }))
	local module = chunk()
	modules[name] = module
	return module
end
local identity, enrichment = load("identity"), load("enrichment")
local checks = 0
local function check(condition, message)
	assert(condition, message)
	checks += 1
end
for _, principal in { "hidden***@example.invalid", "person@example", "person@.example.invalid",
	"Contact person@example.invalid", "API key" } do
	check(identity.metadata("openai", { principal = principal, principal_kind = "email", label = "Person" }) == nil,
		"masked, partial or prose email principals fail closed")
end
local person = assert(identity.metadata("claude", { principal = " Person@Example.invalid ", principal_kind = "email",
	label = "Person", organization_id = "org-a", organization = "Company" }))
check(person.id == identity.email("claude", "person@example.invalid", { organization_id = "org-a" }).id
	and person.label == "Person@Example.invalid · Company",
	"emails are normalized and the reported organization ID scopes the identity")
check(identity.metadata("claude", { principal = "person@example.invalid", principal_kind = "email", label = "Person",
	organization_id = "org-a\n" }) == nil, "control characters in a scope fail closed")
check(identity.metadata("claude", { principal = "person@example.invalid", principal_kind = "token" }) == nil,
	"unknown principal kinds are not identities")
local workspace = assert(identity.metadata("kimi", { principal = "workspace-member-7", principal_kind = "id", label = "Member" }))
check(workspace.id == identity.provider_id("kimi", "workspace-member-7").id and workspace.label == "Member",
	"provider account IDs keep the reported display label")
local aliases = identity.aliases("claude", { principal = "person@example.invalid", principal_kind = "email", label = "Person",
	organization = "Company", organization_id = "org-a" })
check(#aliases == 3 and table.find(aliases, person.id) ~= nil
	and table.find(aliases, identity.email("claude", "person@example.invalid").id) ~= nil
	and table.find(aliases, identity.email("claude", "person@example.invalid", { organization = "Company" }).id) ~= nil,
	"aliases cover only name and ID variants of the same reported identity")
check(#identity.aliases("claude", { principal = "API key", principal_kind = "email" }) == 0,
	"an unverifiable document yields no aliases")
local tenant_a = identity.email("openai", "person@example.invalid", { tenant_id = "a:b", workspace_id = "c" })
local tenant_b = identity.email("openai", "person@example.invalid", { tenant_id = "a", workspace_id = "b:c" })
check(tenant_a.id ~= tenant_b.id, "opaque scope separators cannot collide")

local reading = { id = "observation", provider = "kimi", provider_label = "Kimi", source_label = "Agent", usage_source = "headless",
	windows = { { key = "five_hour", pool = "default", used = 20, remaining = 80, observed_at_ms = 1000 } } }
local metadata = { principal = "person@example.invalid", principal_kind = "email", label = "Person", plan = "Kimi Moderato", workspace_id = "work-a" }
local enriched = enrichment.apply(reading, { metadata = metadata })
check(enriched.canonical_id == identity.email("kimi", "person@example.invalid", { workspace_id = "work-a" }).id
	and enriched.plan == "Kimi Moderato", "metadata supplies the canonical scoped identity and plan")
check(reading.account_id == nil and reading.plan == nil and enriched.windows[1] ~= reading.windows[1],
	"enrichment never mutates the original observation")
local conflict = table.clone(reading)
conflict.canonical_id = identity.email("kimi", "other@example.invalid").id
local kept, disagreement = enrichment.apply(conflict, { metadata = metadata })
check(disagreement ~= nil and kept.canonical_id == conflict.canonical_id and kept.account_id == nil,
	"metadata cannot overwrite a contradictory account identity")
return "PASS " .. tostring(checks) .. " canonical identity checks"
