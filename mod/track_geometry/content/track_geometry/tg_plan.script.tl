-- The plan for the new track: everything the ghost shows and the tool builds, from the picked ends
-- and the edit. A plan holds the path twice:
--   dense : a node every STEP, following the profile. The ground is read under it, and the
--           readout (grades, badges, the tooltip's summary) reads it.
--   built : the pieces handed to the game (tg_proposal): long, with a node wherever the track
--           changes (a bridge or tunnel starts or ends, an elevation point), so each piece is one
--           kind and one span of the profile.
-- The game's curve speed limits come per built piece, after the ghost is shown; readout() puts
-- them on the dense nodes. The ground and the water are handed in as functions, and there is no
-- game API here, so test/plan_test.lua runs it outside the game.

local geometry = require("westrom_track_geometry::/track_geometry/tg_geometry.script.tl")
local alignment = require("westrom_track_geometry::/track_geometry/tg_alignment.script.tl")
local ends = require("westrom_track_geometry::/track_geometry/tg_ends.script.tl")
local edits = require("westrom_track_geometry::/track_geometry/tg_edit.script.tl")
local profiles = require("westrom_track_geometry::/track_geometry/tg_profile.script.tl")
local structures = require("westrom_track_geometry::/track_geometry/tg_structures.script.tl")
local readout = require("westrom_track_geometry::/track_geometry/tg_readout.script.tl")

-- The path as nodes, with the height at each.
local record Track
	nodes : {alignment.Sample}
	z : {number}
end

local record Plan
	dense : Track
	built : Track
	grades : {number} -- the grade at each built node
	kinds : {string} -- each built piece "ground", "bridge" or "tunnel"; nil: all ground
	info : string -- "412 m, 2 turns"
	structures : string -- "1 bridge (300 m)"; nil when there are none
	note : string -- why there are no structures, when placing them failed; else nil
	minRadius : number -- the smallest arc radius (m), math.huge without arcs
	curves : {readout.Curve}
end

-- A plan read out with the game's speeds.
local record Readout
	plan : Plan
	speeds : {number} -- the game's curve limit on each dense piece (m/s; nil where it gave none)
	badges : {readout.Badge} -- nil when making them failed
end

local type Ground = function(number, number) : number
local type Water = function(number, number) : boolean

local record PlanMod
	Track : Track
	Plan : Plan
	Readout : Readout
	STEP : number
	MAX_TURN : number
	BADGE_EVERY : number
	PARAMS : geometry.DesignParams
	path : function(a : ends.End, b : ends.End, e : edits.Edit, ground : Ground, water : Water) : Plan, string
	readout : function(plan : Plan, speeds : {number}) : Readout, string
	summary : function(r : Readout, trackSpeed : number) : {string}
end

local M : PlanMod = {}

M.STEP = edits.STEP -- the path is read this finely (m): for the ground under it, the readout, picking...
M.MAX_TURN = math.rad(15) -- ...but built in pieces turning at most this much (straights: one piece)
M.BADGE_EVERY = 50.0 -- a speed badge this often along the path (m)
M.PARAMS = edits.PARAMS

-- The end nodes moved exactly onto the existing nodes, so the new track joins them.
local function pinEnds(nodes : {alignment.Sample}, a : ends.End, b : ends.End)
	nodes[1].x, nodes[1].y = a.x, a.y
	nodes[#nodes].x, nodes[#nodes].y = b.x, b.y
end

local function chainages(nodes : {alignment.Sample}) : {number}
	local ss : {number} = {}
	for i, nd in ipairs(nodes) do ss[i] = nd.s end
	return ss
end

-- Bridges and tunnels where the track is far off the ground: each piece's kind and the summary.
-- Without a ground function, or when reading the ground fails, there are none (nil, nil, and why
-- it failed).
local function classify(nodes : {alignment.Sample}, z : {number}, ground : Ground, water : Water) : {string}, string, string
	if ground == nil then return nil, nil, nil end
	local ok, kinds, summary = pcall(function() : {string}, string
		local ks = structures.classify(nodes, z, ground, water, structures.DEFAULT)
		return ks, structures.summary(nodes, ks)
	end)
	if not ok then return nil, nil, tostring(kinds) end
	return kinds as {string}, summary as string, nil
end

-- The built nodes with the pieces out of a switch end a (and into one at b) merged, so the piece
-- at a switch runs on to the first node clear of the track at both ends (ends.CLEAR): only that
-- piece shares a node with the track, and the game refuses any other piece that overlaps it. (Of
-- both ends: a node clear of a's track but on b's would leave the piece before it on b's track.)
-- With no node clear, the path is one piece. A break among the merged nodes goes with them.
local function clearSwitches(nodes : {alignment.Sample}, a : ends.End, b : ends.End) : {alignment.Sample}
	local function clear(nd : alignment.Sample) : boolean
		return ends.clearance(a, nd.x, nd.y) >= ends.CLEAR and ends.clearance(b, nd.x, nd.y) >= ends.CLEAR
	end
	local first, last = 2, #nodes - 1
	while first <= last and not clear(nodes[first]) do first = first + 1 end
	while last >= first and not clear(nodes[last]) do last = last - 1 end
	local out : {alignment.Sample} = { nodes[1] }
	for i = first, last do out[#out + 1] = nodes[i] end
	out[#out + 1] = nodes[#nodes]
	return out
end

-- The new track from a to b along the edit e (nil: the starting alignment), or nil and why there
-- is none. Its profile leaves each end at its existing track's grade (tg_edit).
function M.path(a : ends.End, b : ends.End, e : edits.Edit, ground : Ground, water : Water) : Plan, string
	local how : string
	if e == nil then
		e, how = edits.new(a, b)
		if e == nil then return nil, how end
	else
		local n = edits.turnCount(e)
		how = string.format("%d turn%s", n, n == 1 and "" or "s")
	end
	local path = edits.path(e)
	-- (the edit's own nodes, copied: the ends are pinned below)
	local dense : {alignment.Sample} = {}
	for i, nd in ipairs(edits.nodes(e)) do
		dense[i] = { x = nd.x, y = nd.y, heading = nd.heading, s = nd.s, k = nd.k }
	end
	if #dense < 2 then return nil, "the path is too short" end
	pinEnds(dense, a, b)
	local minRadius = math.huge
	for _, s in ipairs(path) do
		if s.kind == "arc" and geometry.length(s) > 1e-6 then minRadius = math.min(minRadius, s.radius) end
	end
	local prof, pwhy = edits.profile(e)
	if prof == nil then return nil, pwhy end
	local denseZ = profiles.sample(prof, chainages(dense))
	local kinds, structs, note = classify(dense, denseZ, ground, water)
	-- (a bridge or tunnel may start or end a little off, an elevation point may not: where the
	-- two are too close for a node each, the elevation point has it)
	local breaks : {number} = {}
	for _, s in ipairs(kinds ~= nil and structures.changes(dense, kinds) or {}) do
		local free = true
		for _, pt in ipairs(prof.points) do
			if math.abs(pt.s - s) < alignment.MIN_PIECE then free = false end
		end
		if free then breaks[#breaks + 1] = s end
	end
	for _, pt in ipairs(prof.points) do breaks[#breaks + 1] = pt.s end
	local built = clearSwitches(alignment.sample(path, math.huge, M.MAX_TURN, breaks), a, b)
	pinEnds(built, a, b)
	if kinds ~= nil then kinds = alignment.carry(dense, kinds, built) end
	local z, grades = profiles.sample(prof, chainages(built))
	return { dense = { nodes = dense, z = denseZ }, built = { nodes = built, z = z }, grades = grades, kinds = kinds,
		info = string.format("%.0f m, %s", dense[#dense].s, how), structures = structs, note = note,
		minRadius = minRadius, curves = readout.curves(path) }
end

-- The plan read out with the game's curve limits, one per built piece (nil where it gave none):
-- the limits on the dense pieces, and a badge at each curve and every BADGE_EVERY along the path.
-- Also why there are no badges, when making them failed.
function M.readout(plan : Plan, speeds : {number}) : Readout, string
	local d = plan.dense
	local carried = alignment.carry(plan.built.nodes, speeds, d.nodes)
	local ok, bs = pcall(function() : {readout.Badge}
		local out = readout.badges(d.nodes, d.z, carried, plan.curves)
		for _, b in ipairs(readout.alongBadges(d.nodes, d.z, carried, M.BADGE_EVERY)) do out[#out + 1] = b end
		return out
	end)
	return { plan = plan, speeds = carried, badges = ok and bs as {readout.Badge} or nil }, not ok and tostring(bs) or nil
end

-- The tooltip's summary lines (tg_readout); trackSpeed is the track type's top speed (m/s).
function M.summary(r : Readout, trackSpeed : number) : {string}
	local d = r.plan.dense
	return readout.summary(d.nodes, d.z, r.speeds, trackSpeed, r.plan.minRadius)
end

return M
