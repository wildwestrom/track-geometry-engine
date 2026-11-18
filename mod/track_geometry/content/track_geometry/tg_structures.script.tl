-- Where the track needs bridges and tunnels. A proposal takes each piece's type literally (the
-- game's own drag tool decides in native code we cannot feed), so we classify the pieces ourselves:
--   bridge : over water, or more than BRIDGE_MIN above the ground
--   tunnel : more than TUNNEL_MIN below the ground
--   ground : else (the game fills the rest with embankments and cuts)
-- The thresholds are the game's track drag-tool defaults (bridge height 6 + 6, tunnel height 9 + 6).
-- Then runs are tidied: a short stretch of ground between two runs of the same kind joins them, and
-- a run shorter than MIN_RUN becomes ground (unless it crosses water).
-- The ghost classifies a dense sampling of the path, then carries the kinds over to its own long
-- pieces, which have a node at every change (changes; alignment.carry).
-- Also picks the bridge or tunnel type the way the game's menu auto-selects one.
-- No game API here (the ground and water come in as functions), so test/structures_test.lua runs it
-- outside the game.

local alignment = require("track_geometry_tool::/track_geometry/tg_alignment.script.tl")

local BRIDGE_MIN = 12.0 -- clearance above the ground that makes a bridge (m)
local TUNNEL_MIN = 15.0 -- depth below the ground that makes a tunnel (m)
local MIN_RUN = 20.0 -- shortest bridge or tunnel kept (m)
local FILL_GAP = 40.0 -- longest stretch of ground merged into the runs either side (m)
local PROBE = 5.0 -- the ground is read at most this far apart along a piece (m)

-- A bridge or tunnel type on offer: from api.res.bridgeTypeRep / tunnelTypeRep.
local record Offer
	id : integer
	speedLimit : number -- m/s
	autoSelectable : boolean
end

local record StructuresMod
	Offer : Offer
	classify : function(nodes : {alignment.Sample}, z : {number}, ground : function(number, number) : number,
		water : function(number, number) : boolean) : {string}
	summary : function(nodes : {alignment.Sample}, kinds : {string}) : string
	changes : function(nodes : {alignment.Sample}, kinds : {string}) : {number}
	pickType : function(offers : {Offer}, speed : number) : integer
end

local M : StructuresMod = {}

-- Each piece's raw kind and whether it crosses water.
local function raw(nodes : {alignment.Sample}, z : {number}, ground : function(number, number) : number,
	water : function(number, number) : boolean) : {string}, {boolean}
	local kinds, wet : {string}, {boolean} = {}, {}
	for i = 1, #nodes - 1 do
		local a, b = nodes[i], nodes[i + 1]
		local len = b.s - a.s
		local n = math.max(1, math.ceil(len / PROBE))
		local sum, isWet = 0.0, false
		for k = 0, n do
			local t = k / n
			local x, y = a.x + t * (b.x - a.x), a.y + t * (b.y - a.y)
			sum = sum + (z[i] + t * (z[i + 1] - z[i])) - ground(x, y)
			if water ~= nil and water(x, y) then isWet = true end
		end
		local clearance = sum / (n + 1)
		wet[i] = isWet
		if isWet or clearance > BRIDGE_MIN then kinds[i] = "bridge"
		elseif -clearance > TUNNEL_MIN then kinds[i] = "tunnel"
		else kinds[i] = "ground" end
	end
	return kinds, wet
end

local record Run
	kind : string
	first : integer -- first piece
	last : integer -- last piece
	len : number
	wet : boolean
end

local function runs(nodes : {alignment.Sample}, kinds : {string}, wet : {boolean}) : {Run}
	local rs : {Run} = {}
	for i, k in ipairs(kinds) do
		local len = nodes[i + 1].s - nodes[i].s
		local r = rs[#rs]
		if r ~= nil and r.kind == k then
			r.last, r.len, r.wet = i, r.len + len, r.wet or wet[i]
		else
			rs[#rs + 1] = { kind = k, first = i, last = i, len = len, wet = wet[i] }
		end
	end
	return rs
end

local function paint(kinds : {string}, r : Run, k : string)
	for i = r.first, r.last do kinds[i] = k end
end

function M.classify(nodes : {alignment.Sample}, z : {number}, ground : function(number, number) : number,
	water : function(number, number) : boolean) : {string}
	local kinds, wet = raw(nodes, z, ground, water)
	-- short ground between two runs of the same structure: one structure
	local rs = runs(nodes, kinds, wet)
	for j = 2, #rs - 1 do
		local r = rs[j]
		if r.kind == "ground" and r.len <= FILL_GAP and rs[j - 1].kind ~= "ground" and rs[j - 1].kind == rs[j + 1].kind then
			paint(kinds, r, rs[j - 1].kind)
		end
	end
	-- too short to be worth a structure: ground (but water always needs its bridge)
	for _, r in ipairs(runs(nodes, kinds, wet)) do
		if r.kind ~= "ground" and r.len < MIN_RUN and not r.wet then paint(kinds, r, "ground") end
	end
	return kinds
end

-- "2 bridges (340 m), 1 tunnel (500 m)", or nil when there are none.
function M.summary(nodes : {alignment.Sample}, kinds : {string}) : string
	local count : {string : integer} = { bridge = 0, tunnel = 0 }
	local len : {string : number} = { bridge = 0, tunnel = 0 }
	for _, r in ipairs(runs(nodes, kinds, {})) do
		if r.kind ~= "ground" then
			count[r.kind] = count[r.kind] + 1
			len[r.kind] = len[r.kind] + r.len
		end
	end
	local parts : {string} = {}
	for _, k in ipairs({ "bridge", "tunnel" }) do
		if count[k] > 0 then
			parts[#parts + 1] = string.format("%d %s%s (%.0f m)", count[k], k, count[k] > 1 and "s" or "", len[k])
		end
	end
	if #parts == 0 then return nil end
	return table.concat(parts, ", ")
end

-- The chainages where one kind gives way to another.
function M.changes(nodes : {alignment.Sample}, kinds : {string}) : {number}
	local out : {number} = {}
	for i = 2, #kinds do
		if kinds[i] ~= kinds[i - 1] then out[#out + 1] = nodes[i].s end
	end
	return out
end

-- As the game's menu auto-selects: of the auto-selectable offers, the slowest that is at least as
-- fast as the track, else the fastest. nil when there is none.
function M.pickType(offers : {Offer}, speed : number) : integer
	local above, below : Offer, Offer = nil, nil
	for _, o in ipairs(offers) do
		if o.autoSelectable then
			if o.speedLimit >= speed then
				if above == nil or o.speedLimit < above.speedLimit then above = o end
			elseif below == nil or o.speedLimit > below.speedLimit then
				below = o
			end
		end
	end
	local best = above or below
	return best ~= nil and best.id or nil
end

return M
