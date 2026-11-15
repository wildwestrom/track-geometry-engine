-- The starting alignment between two picked track ends. Each end is a point and the unit direction
-- pointing out of the existing track, away from it; the new track leaves the first end along its
-- direction and arrives at the second against its direction. The PIs put the first leg along the
-- first end's direction and the last leg along the second end's, so buildPath keeps both headings.
-- A layout uses only as many turns as the ends' geometry needs (initialPis): none, one where the
-- rays meet, one on each end's ray, or (ends far apart) a lead on each ray and a free turn between.
-- Also which free end the mouse snaps to (snap), from the ends tg_world finds near it.
-- No game API here, so test/ends_test.lua runs it outside the game.

local geometry = require("westrom_track_geometry::/track_geometry/tg_geometry.script.tl")

local record End
	x : number
	y : number
	dx : number -- unit direction out of the existing track
	dy : number
	z : number -- height (m)
	grade : number -- the existing track's grade, going out along (dx, dy)
end

-- A free track end: an existing node with a single track piece, and the unit direction pointing
-- out of that piece. (An End with its node.)
local record TrackEnd
	node : integer
	x : number
	y : number
	z : number
	dx : number
	dy : number
	grade : number -- the existing track's grade at the node, going out along (dx, dy)
end

local record Ends
	End : End
	TrackEnd : TrackEnd
	SNAP : number
	MIN_LEG : number
	MAX_REACH : number
	LEAD : number
	FAR : number
	STRAIGHT_ANGLE : number
	STRAIGHT_OFFSET : number
	initialPis : function(a : End, b : End) : {geometry.Vec}, string
	snap : function(near : {TrackEnd}, onHovered : {integer : boolean}, sawTrack : boolean, x : number, y : number,
		exclude : integer) : TrackEnd, string
end

local M : Ends = {}

-- Shortest leg from an end to its PI (m).
M.MIN_LEG = 20.0
-- Furthest the rays may meet from an end for a "corner" (m). Rays that meet further away (nearly
-- parallel) make an "s-curve".
M.MAX_REACH = 1000.0
-- How far out of each end its lead PI goes (m), when the room allows.
M.LEAD = 200.0
-- Ends further apart than this (m) get the "long s-curve" layout, unless they are in line.
M.FAR = 800.0
-- Float noise: ends this close to one line are exactly in line. The game keeps positions and
-- tangents in single precision: two ends of one straight line came out 1.4e-7 rad and 0.086 mm
-- apart, and a position on an 8 km map is only good to about 0.5 mm. Anything more is a kink a
-- straight would hide. (Sine of the angle between the directions; offset across the line, m.)
M.STRAIGHT_ANGLE = 1e-6
M.STRAIGHT_OFFSET = 0.002
-- A free end this close to the mouse snaps to it (m).
M.SNAP = 40.0

-- The PIs from a to b, at z = 0, and how they were laid, in order:
--   "straight"    : b exactly in line ahead of a, facing it (no turns);
--   "long s-curve": the ends more than FAR apart: a lead LEAD out on each end's ray and a free
--                   turn halfway between the leads, so the path does not run off towards a far
--                   meeting point (three turns);
--   "corner"      : the rays meet ahead of both ends, MIN_LEG to MAX_REACH from each: one turn
--                   there, next to both ends, so it is fixed until another is added;
--   "s-curve"     : else one turn on each end's ray, min(LEAD, a third of the distance) out.
-- The first and last legs run along the ends' rays, so the path keeps both headings. nil and a
-- reason when the ends are too close.
function M.initialPis(a : End, b : End) : {geometry.Vec}, string
	local ex, ey = b.x - a.x, b.y - a.y
	local dist = math.sqrt(ex * ex + ey * ey)
	if dist < 2 * M.MIN_LEG then return nil, "the ends are too close" end
	local pa, pb = geometry.vec(a.x, a.y, 0), geometry.vec(b.x, b.y, 0)
	local function out(e : End, l : number) : geometry.Vec return geometry.vec(e.x + l * e.dx, e.y + l * e.dy, 0) end
	-- a + s (a.dx, a.dy) = b + t (b.dx, b.dy)
	local cross = a.dx * b.dy - a.dy * b.dx
	local along = ex * a.dx + ey * a.dy
	local lateral = a.dx * ey - a.dy * ex
	local facing = a.dx * b.dx + a.dy * b.dy < 0
	if facing and along > 0 and math.abs(cross) <= M.STRAIGHT_ANGLE and math.abs(lateral) <= M.STRAIGHT_OFFSET then
		return { pa, pb }, "straight"
	end
	if dist > M.FAR then
		local la, lb = out(a, M.LEAD), out(b, M.LEAD)
		return { pa, la, geometry.vec((la.x + lb.x) / 2, (la.y + lb.y) / 2, 0), lb, pb }, "long s-curve"
	end
	if cross ~= 0 then
		local s = (ex * b.dy - ey * b.dx) / cross
		local t = (a.dy * ex - a.dx * ey) / cross
		if s >= M.MIN_LEG and t >= M.MIN_LEG and s <= M.MAX_REACH and t <= M.MAX_REACH then
			return { pa, out(a, s), pb }, "corner"
		end
	end
	local L = math.min(M.LEAD, dist / 3)
	return { pa, out(a, L), out(b, L), pb }, "s-curve"
end

-- The end the mouse at (x, y) snaps to, from the free ends near it (onHovered: those of the piece
-- under the mouse; sawTrack: any track piece was there). An end of the piece under the mouse
-- snaps however far; any other within SNAP; of those, the nearest. Never the node exclude. (x
-- nil: the mouse is over no ground; only the hovered piece's ends.) nil and a hint when none.
function M.snap(near : {TrackEnd}, onHovered : {integer : boolean}, sawTrack : boolean, x : number, y : number,
	exclude : integer) : TrackEnd, string
	local best : TrackEnd = nil
	local bestD = math.huge
	for _, e in ipairs(near) do
		if e.node ~= exclude then
			local d = x ~= nil and math.sqrt((e.x - x) ^ 2 + (e.y - y) ^ 2) or 0.0
			if (d <= M.SNAP or onHovered[e.node]) and d < bestD then best, bestD = e, d end
		end
	end
	if best ~= nil then return best, nil end
	if sawTrack then return nil, "No free track end here. Point at the last piece of a line, near its end." end
	return nil, "Point at the end of a track."
end

return M
