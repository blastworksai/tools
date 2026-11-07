-- Vendored from shared/tern-updater by sync.py; edit there, then run sync.py.
-- Where updater fetches manifests and installs plugins from. Pure: never reads `tern`.
-- Each *_BASE stays ONE literal on its own line: the smoke harness rewrites them.
local Source = {}

Source.RAW_BASE = "https://raw.githubusercontent.com/blastworksai/tools/main/plugins/tern/"
Source.INSTALL_BASE = "github.com/blastworksai/tools/plugins/tern/"
Source.PAGE_BASE = "https://github.com/blastworksai/tools/tree/main/plugins/tern/"

function Source.valid_dir(dir: any): boolean
	if type(dir) ~= "string" then
		return false
	end
	if #dir < 1 or #dir > 64 or string.find(dir, "..", 1, true) then
		return false
	end
	return string.match(dir, "^[A-Za-z0-9][A-Za-z0-9+_%.%-]*$") ~= nil
end

function Source.encode(dir: string): string
	return (string.gsub(dir, "[^A-Za-z0-9_%.~%-]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

function Source.manifest_url(dir: string): string
	return Source.RAW_BASE .. Source.encode(dir) .. "/plugin.toml"
end

function Source.requires_url(dir: string): string
	return Source.RAW_BASE .. Source.encode(dir) .. "/requires.json"
end

function Source.install_src(dir: string): string
	return Source.INSTALL_BASE .. dir
end

function Source.page_url(dir: string): string
	return Source.PAGE_BASE .. Source.encode(dir)
end

return Source
