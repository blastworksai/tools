local Source = require("../source")

return {
	{"encode percent-encodes plus", function()
		assert(Source.encode("ORCH+") == "ORCH%2B")
		assert(Source.encode("a_b.c~d-e") == "a_b.c~d-e")
	end},
	{"manifest_url encodes dir", function()
		assert(Source.manifest_url("ORCH+") == "https://raw.githubusercontent.com/blastworksai/tools/main/plugins/tern/ORCH%2B/plugin.toml")
	end},
	{"requires_url encodes dir", function()
		assert(Source.requires_url("ORCH+") == "https://raw.githubusercontent.com/blastworksai/tools/main/plugins/tern/ORCH%2B/requires.json")
	end},
	{"install_src keeps raw dir", function()
		assert(Source.install_src("ORCH+") == "github.com/blastworksai/tools/plugins/tern/ORCH+")
	end},
	{"page_url encodes dir", function()
		assert(Source.page_url("ORCH+") == "https://github.com/blastworksai/tools/tree/main/plugins/tern/ORCH%2B")
	end},
	{"valid_dir accepts plugin dirs", function()
		assert(Source.valid_dir("ORCH+"))
		assert(Source.valid_dir("TODO"))
		assert(Source.valid_dir("a.b_c-d"))
		assert(Source.valid_dir(string.rep("a", 64)))
	end},
	{"valid_dir rejects unsafe dirs", function()
		for _, bad in { "../x", "a/b", "", ".hidden", "a..b", string.rep("a", 65), "a'b" } do
			assert(not Source.valid_dir(bad), bad)
		end
		assert(not Source.valid_dir(42))
		assert(not Source.valid_dir(nil))
	end},
}
