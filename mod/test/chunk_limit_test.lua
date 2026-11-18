-- Lua's own limits, which tl check does not see: the game's compiler refuses a function with more
-- than 200 local variables ("too many local variables (limit is 200) in main function", seen in
-- game 2026-11-18: the mod failed to load). A module's top level counts as one function, and its
-- every top-level local and function adds to it.
--
-- The game compiles the Teal itself, and its Lua has more top-level locals than tl here makes: in
-- the file it refused, its 201st was the one tl here (with its compat code, as for Lua 5.1) makes
-- the 194th. Records, enums and types make no locals here; maybe they do there. So each file is
-- counted as tl here makes it, with the compat code, plus one for each top-level record, enum and
-- type, and fails at 200 (past what the game refused, as far as can be told). A function past
-- Lua's limits in any function fails too (compiled here).
local H = dofile("test/harness.lua")
local tl = require("tl")
local check = H.check

local LIMIT = 200

local windows = package.config:sub(1, 1) == "\\"
local list = windows and 'dir /s /b "track_geometry\\content\\*.tl" 2>nul'
	or 'find track_geometry/content -name "*.tl"'
local files = {}
for f in io.popen(list):lines() do files[#files + 1] = f end
table.sort(files)
check(#files > 0, "chunk limits: found the mod's Teal files")

-- The locals at the top of chunk code: how many more it takes to make it fail to compile; nil
-- and why when it fails without any.
local function topLocals(code)
	for extra = 0, 250 do
		local fn, err = load(string.rep("local _p;", extra) .. "\n" .. code, "=chunk")
		if fn == nil then
			if extra > 0 and tostring(err):find("too many local variables", 1, true) then return LIMIT - extra + 1 end
			return nil, err
		end
	end
	return 0
end

local env = assert(tl.new_env({ defaults = { gen_target = "5.1", gen_compat = "optional" } }))
for _, f in ipairs(files) do
	local src = assert(io.open(f, "rb")):read("*a")
	local name = f:gsub("^.*[/\\]track_geometry[/\\]content[/\\]", ""):gsub("\\", "/")
	local code = tl.gen(src, env)
	if code == nil then
		check(false, name .. ": no Lua generated")
	else
		local n, err = topLocals(code)
		local types = 0
		for _ in ("\n" .. src):gmatch("\nlocal record ") do types = types + 1 end
		for _ in ("\n" .. src):gmatch("\nlocal enum ") do types = types + 1 end
		for _ in ("\n" .. src):gmatch("\nlocal type ") do types = types + 1 end
		if n == nil then
			check(false, name .. ": " .. tostring(err))
		else
			check(n + types < LIMIT, string.format("%s: %d top-level locals, %d with its records, enums and types (limit %d)", name, n, n + types, LIMIT))
		end
	end
end

H.done()
