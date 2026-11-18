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
local type PiecesAt = function(ends.End) : {integer}
local type Mergeable = function(joint : integer, from : integer, to : integer) : boolean

local record PlanMod
	Plan : Plan
	Readout : Readout
	BADGE_EVERY : number
	path : function(a : ends.End, b : ends.End, e : edits.Edit, ground : Ground, water : Water) : Plan, string
	switches : function(a : ends.End, b : ends.End, nodes : {alignment.Sample}, piecesAt : PiecesAt, mergeable : Mergeable, only ?: integer) : {integer}, {ends.Run}
	readout : function(plan : Plan, speeds : {number}) : Readout, string
	summary : function(r : Readout, trackSpeed : number) : {string}
	changed : function(ref : {alignment.Sample}, refZ : {number}, nodes : {alignment.Sample}, z : {number}) : integer, integer
end

local M : PlanMod = {}

-- The stretch of built nodes (nodes, heights z) that differs from those of an earlier plan (ref,
-- refZ): from the last node before it that is the same to the first one after it (so the pieces
-- either side of each changed node are in it); nil when none differs. Compared
-- from both ends (by index from each end: a change shifts the indices after it). In plan first:
-- the profile's heights run the length of the path, so a horizontal drag shifts them all a little;
-- only when no node moved in plan, by height (an elevation point dragged changes the stretch
-- between its neighbours).
local SAME_XY = 1e-3 -- m
local SAME_HEADING = 1e-6 -- rad
local SAME_Z = 1e-3 -- m
function M.changed(ref : {alignment.Sample}, refZ : {number}, nodes : {alignment.Sample}, z : {number}) : integer, integer
	local n, nr = #nodes, #ref
	local function same(i : integer, j : integer, byZ : boolean) : boolean
		local a, b = nodes[i], ref[j]
		if byZ then return math.abs(z[i] - refZ[j]) <= SAME_Z end
		return math.abs(a.x - b.x) <= SAME_XY and math.abs(a.y - b.y) <= SAME_XY
			and math.abs(math.sin(a.heading - b.heading)) <= SAME_HEADING and math.cos(a.heading - b.heading) > 0
	end
	local function span(byZ : boolean) : integer, integer
		local m = math.min(n, nr)
		local f = 1
		while f <= m and same(f, f, byZ) do f = f + 1 end
		if f > m and n == nr then return nil, nil end -- (all the same)
		local t = 0
		while t < m - f + 1 and same(n - t, nr - t, byZ) do t = t + 1 end
		local l = n - t -- the last node that differs (in nodes)
		if l < f then l = f end
		return math.max(1, f - 1), math.min(n, l + 1)
	end
	local lo, hi = span(false)
	if lo == nil then lo, hi = span(true) end
	return lo, hi
end

-- The path is read every edits.STEP, but built in pieces turning at most this much (straights: one piece).
local MAX_TURN = math.rad(15)
M.BADGE_EVERY = 50.0 -- a speed badge this often along the path (m)

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
		local ks = structures.classify(nodes, z, ground, water)
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
	local built = clearSwitches(alignment.sample(path, math.huge, MAX_TURN, breaks), a, b)
	pinEnds(built, a, b)
	if kinds ~= nil then kinds = alignment.carry(dense, kinds, built) end
	local z, grades = profiles.sample(prof, chainages(built))
	return { dense = { nodes = dense, z = denseZ }, built = { nodes = built, z = z }, grades = grades, kinds = kinds,
		info = string.format("%.0f m, %s", dense[#dense].s, how), structures = structs, note = note,
		minRadius = minRadius, curves = readout.curves(path) }
end

-- The existing track a switch changes, for the built nodes from a to b (tg_proposal): the pieces
-- at a node end, replaced as the game's builder does (each once: two node ends can share a piece),
-- and the runs of a shallow switch: the track it runs beside, merged through the joints there
-- (ends.runs), each piece into one run only, and never a piece or node the other end is on. The
-- world is read through piecesAt and mergeable (tg_world).
function M.switches(a : ends.End, b : ends.End, nodes : {alignment.Sample}, piecesAt : PiecesAt, mergeable : Mergeable, only ?: integer) : {integer}, {ends.Run}
	local replace : {integer} = {}
	local used : {integer : boolean} = {}
	for i, en in ipairs({ a, b }) do
		for _, e in ipairs((only == nil or only == i) and piecesAt(en) or {}) do
			if not used[e] then used[e] = true; replace[#replace + 1] = e end
		end
	end
	local runs : {ends.Run} = {}
	for _, en in ipairs({ a, b }) do
		if en.kind == "split" then used[en.piece.edge] = true end
	end
	for i, en in ipairs({ a, b }) do
		if only == nil or only == i then
			local other = i == 1 and b or a
			local n0, n1 = nodes[i == 1 and 1 or #nodes - 1], nodes[i == 1 and 2 or #nodes]
			local T = alignment.tangentLength(n0, n1)
			local branch : ends.Piece = { edge = -1, p0 = { x = n0.x, y = n0.y, z = 0 }, p1 = { x = n1.x, y = n1.y, z = 0 },
				t0 = { x = math.cos(n0.heading) * T, y = math.sin(n0.heading) * T, z = 0 },
				t1 = { x = math.cos(n1.heading) * T, y = math.sin(n1.heading) * T, z = 0 } }
			for _, r in ipairs(ends.runs(en, branch, function(joint : integer, from : integer, to : integer) : boolean
				if used[to] or joint == other.node or not mergeable(joint, from, to) then return false end
				used[to] = true
				return true
			end)) do runs[#runs + 1] = r end
		end
	end
	return replace, runs
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
