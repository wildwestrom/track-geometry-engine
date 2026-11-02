-- Samples a path from tg_geometry into track nodes for the game: a node at every segment boundary
-- and evenly spaced nodes in between, at most `step` apart, each with its exact position and
-- heading. The game fills each piece between two nodes with a cubic Hermite (see tangentLength).
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
	sample : function(path : {geometry.Segment}, step : number) : {Sample}
	tangentLength : function(Sample, Sample) : number
end

local M : Alignment = {}

-- Shortest piece between two nodes (m). A boundary node closer than this to the previous node is
-- dropped, so short segments (e.g. a zero-length straight between two corners) never make the
-- tiny pieces that crash the game (< 0.1 m).
M.MIN_PIECE = 1.0

local atan2 : function(number, number) : number = (math as {string : any}).atan2 as function(number, number) : number
	or (math.atan as function(number, number) : number)

local function node(seg : geometry.Segment, t : number, s : number) : Sample
	local p, tan = geometry.pointAt(seg, t), geometry.tangentAt(seg, t)
	return { x = p.x, y = p.y, heading = atan2(tan.y, tan.x), s = s, k = geometry.curvatureAt(seg, t) }
end

function M.sample(path : {geometry.Segment}, step : number) : {Sample}
	if #path == 0 then return {} end
	local nodes : {Sample} = { node(path[1], 0, 0) }
	local s0 = 0.0
	for i, seg in ipairs(path) do
		local len = geometry.length(seg)
		local n = math.max(1, math.ceil(len / step))
		for j = 1, n do
			local t = len * j / n
			local nd = node(seg, t, s0 + t)
			local last = i == #path and j == n
			if nd.s - nodes[#nodes].s >= M.MIN_PIECE then
				nodes[#nodes + 1] = nd
			elseif last and #nodes > 1 then
				nodes[#nodes] = nd -- the path's end is fixed: move the previous node there instead
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

return M
