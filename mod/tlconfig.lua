local windows = package.config:sub(1, 1) == "\\"
local game = windows
	and "D:/SteamLibrary/steamapps/common/Transport Fever 3"
	or "/home/main/.local/share/guix-sandbox-home/.local/share/Steam/steamapps/common/Transport Fever 3"
if windows then
	-- "<modId>::/..." can't be a Windows filename, so check.sh names that .tlpath dir "<modId>__".
	-- test/harness.lua runs this file too, so its requires get the same mapping.
	local tl = require("tl")
	if not tl._colon_patched then
		tl._colon_patched = true
		local search = tl.search_module
		tl.search_module = function(name, ...) return search((name:gsub("::", "__")), ...) end
	end
end
return {
	include_dir = {
		game .. "/api/tealdef",
		game .. "/base/tealdef",
		".tlpath", -- built by check.sh
	},
	global_env_def = "all_def"
}
