--!strict
-- Native names verified against the installed Tern's embedded SVG registry.
local ICONS = { claude = "provider-anthropic", anthropic = "provider-anthropic",
	codex = "provider-openai-codex", openai = "provider-openai-codex", omp = "pi-mark",
	kimi = "provider-kimi-code", muse = "provider-meta", agy = "provider-google-antigravity",
	antigravity = "provider-google-antigravity", grok = "provider-xai" }
local NAMES = { claude = "Claude", anthropic = "Claude", codex = "Codex", openai = "Codex", omp = "OMP",
	kimi = "Kimi", muse = "Muse", agy = "Agy", antigravity = "Antigravity", grok = "Grok" }
local M = {}
function M.icon(provider: string?): string?
	return ICONS[string.lower(provider or "")]
end
function M.name(provider: string?): string
	return NAMES[string.lower(provider or "")] or provider or "Agent"
end
-- Native metadata has no user-title flag. Suppress only the wrapper's unchanged default,
-- never infer a name from an account, executable or saved launch record.
function M.pane_title(pane: any): string?
	if not pane or type(pane.title) ~= "string" or not pane.title:find("%S") then return nil end
	local program = if type(pane.program) == "string" then pane.program:match("([^/\\]+)$") else nil
	if pane.title == "sudo" and program == "sudo" then return nil end
	return pane.title
end
return M
