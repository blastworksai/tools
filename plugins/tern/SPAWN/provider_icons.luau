--!strict
-- The one provider -> Tern icon map. The window half registers these as tab icons
-- and the host half draws them on the Start an agent rows; neither keeps its own copy.
local M = {}
M.ICONS = {
	claude = "provider-anthropic",
	codex = "provider-openai-codex",
	kimi = "provider-kimi-code",
	muse = "provider-meta",
	agy = "provider-google-antigravity",
	grok = "provider:xai",
	omp = "pi-mark",
} :: { [string]: string }
-- An unknown provider keeps a generic mark instead of a blank cell.
M.FALLBACK = "sparkle"
function M.for_provider(provider: any): string
	if type(provider) ~= "string" then return M.FALLBACK end
	return M.ICONS[string.lower(provider)] or M.FALLBACK
end
return M
