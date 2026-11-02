-- Samples a path from tg_geometry into track nodes for the game: a node at every segment boundary
-- and at every chainage in `breaks`, and evenly spaced nodes in between, at most `step` apart and
-- turning at most `maxTurn` each, each with its exact position and heading. The game fills each
-- piece between two nodes with a cubic Hermite (see tangentLength), which follows the curve
-- closely even over long pieces (test/alignment_test.lua), so the ghost uses few nodes: a straight
-- is one piece from break to break (step = math.huge), a curve as many as maxTurn asks for.
-- No game API here, so test/alignment_test.lua runs it outside the game.

local geometry = require("westrom_track_geometry::/track_geometry/tg_geometry.script.tl")

local record Sample
	x : number
	y : number
	heading : number -- radians, 0 = +x
	s : number -- chainage (m)
	k : number -- unsigned curvature (1/m)
end

local record Alignment
	Sample : Sample
	MIN_PIECE : number
	sample : function(path : {geometry.Segment}, step : number, maxTurn ?: number, breaks ?: {number}) : {Sample}
	tangentLength : function(Sample, Sample) : number
	pointAt : function(nodes : {Sample}, s : number) : number, number
	project : function(nodes : {Sample}, x : number, y : number) : number, number
	carry : function<T>(nodes : {Sample}, values : {T}, other : {Sample}) : {T}
end

local M : Alignment = {}

-- Shortest piece between two nodes (m). A boundary node closer than this to the previous node is
-- dropped, so short segments (e.g. a zero-length straight between two corners) never make the
-- tiny pieces that crash the game (< 0.1 m).
M.MIN_PIECE = 1.0
-- Segments this short or shorter count as zero-length (m).
local ZERO = 1e-6

local atan2 : function(number, number) : number = (math as {string : any}).atan2 as function(number, number) : number
	or (math.atan as function(number, number) : number)

local function node(seg : geometry.Segment, t : number, s : number) : Sample
	local p, tan = geometry.pointAt(seg, t), geometry.tangentAt(seg, t)
	return { x = p.x, y = p.y, heading = atan2(tan.y, tan.x), s = s, k = geometry.curvatureAt(seg, t) }
end

-- maxTurn (radians) and breaks (chainages, in any order) are optional.
function M.sample(path : {geometry.Segment}, step : number, maxTurn ?: number, breaks ?: {number}) : {Sample}
	if #path == 0 then return {} end
	-- (zero-length segments, e.g. the straight after a curve that ends on the path's end, add
	-- nothing and have no direction of their own: skip them)
	local segs : {geometry.Segment} = {}
	for _, seg in ipairs(path) do
		if geometry.length(seg) > ZERO then segs[#segs + 1] = seg end
	end
	if #segs == 0 then return { node(path[1], 0, 0) } end
	local bs : {number} = {}
	for _, b in ipairs(breaks or {}) do bs[#bs + 1] = b end
	table.sort(bs)
	local nodes : {Sample} = { node(segs[1], 0, 0) }
	local s0 = 0.0
	for i, seg in ipairs(segs) do
		local len = geometry.length(seg)
		-- the stretches between this segment's breaks, each in even pieces
		local cuts : {number} = { 0 }
		for _, b in ipairs(bs) do
			if b - s0 > ZERO and b - s0 < len - ZERO then cuts[#cuts + 1] = b - s0 end
		end
		cuts[#cuts + 1] = len
		for c = 2, #cuts do
			local t0, t1 = cuts[c - 1], cuts[c]
			local n = math.max(1, math.ceil((t1 - t0) / step))
			if maxTurn ~= nil then
				local turn = math.abs(geometry.headingAt(seg, t1) - geometry.headingAt(seg, t0))
				n = math.max(n, math.ceil(turn / maxTurn))
			end
			for j = 1, n do
				local t = t0 + (t1 - t0) * j / n
				local nd = node(seg, t, s0 + t)
				local last = i == #segs and c == #cuts and j == n
				if nd.s - nodes[#nodes].s >= M.MIN_PIECE then
					nodes[#nodes + 1] = nd
				elseif last and #nodes > 1 then
					nodes[#nodes] = nd -- the path's end is fixed: move the previous node there instead
				end
			end
		end
		s0 = s0 + len
	end
	return nodes
end

-- Hermite tangent length for a piece whose ends have these headings (as Track Connector's
-- planner.tangentLength): r = c / (2 sin(phi/2)), T = 4 r tan(phi/4), T = c when phi ~ 0.
function M.tangentLength(a : Sample, b : Sample) : number
	local c = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
	local ax, ay, bx, by = math.cos(a.heading), math.sin(a.heading), math.cos(b.heading), math.sin(b.heading)
	local phi = math.abs(atan2(ax * by - ay * bx, ax * bx + ay * by))
	if phi < 1e-3 then return c end
	local r = c / (2 * math.sin(phi / 2))
	return 4 * r * math.tan(phi / 4)
end

-- The point at chainage s, on the straight between the nodes around it (clamped to the ends).
function M.pointAt(nodes : {Sample}, s : number) : number, number
	local i = 1
	while i < #nodes - 1 and s > nodes[i + 1].s do i = i + 1 end
	local a, b = nodes[i], nodes[i + 1] or nodes[i]
	local t = b.s > a.s and math.max(0, math.min(1, (s - a.s) / (b.s - a.s))) or 0.0
	return a.x + t * (b.x - a.x), a.y + t * (b.y - a.y)
end

-- The chainage nearest (x, y) on the straights between the nodes, and how far off it is.
function M.project(nodes : {Sample}, x : number, y : number) : number, number
	local bestS, bestD = 0.0, math.huge
	for i = 1, #nodes - 1 do
		local a, b = nodes[i], nodes[i + 1]
		local lx, ly = b.x - a.x, b.y - a.y
		local l2 = lx * lx + ly * ly
		local t = l2 > 0 and math.max(0, math.min(1, ((x - a.x) * lx + (y - a.y) * ly) / l2)) or 0.0
		local d = math.sqrt((x - a.x - t * lx) ^ 2 + (y - a.y - t * ly) ^ 2)
		if d < bestD then bestS, bestD = a.s + t * (b.s - a.s), d end
	end
	return bestS, bestD
end

-- Values per piece (between nodes) carried over to the pieces between the other nodes of the same
-- path: each takes the value at its middle (nil where that is nil).
function M.carry<T>(nodes : {Sample}, values : {T}, other : {Sample}) : {T}
	local out : {T} = {}
	local i = 1
	for j = 1, #other - 1 do
		local mid = (other[j].s + other[j + 1].s) / 2
		while i < #nodes - 1 and nodes[i + 1].s < mid do i = i + 1 end
		out[j] = values[i]
	end
	return out
end

return M
