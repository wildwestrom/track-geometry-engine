-- The starting alignment between two picked ends. A free track end is a point and the unit
-- direction pointing out of the existing track, away from it; the new track leaves the first end
-- along its direction and arrives at the second against its direction. The PIs put the first leg
-- along the first end's direction and the last leg along the second end's, so buildPath keeps both
-- headings. A ground end has no heading: it takes its leg's direction (a path end with no curve
-- at it). A layout uses only as many turns as the ends' geometry needs (initialPis): none, one
-- where the rays meet, one on each end's ray, or (ends far apart) a lead on each ray and a free
-- turn between; with one ground end, one turn on the other end's ray.
-- Also what the mouse picks (snap): a free end tg_world finds near it, else the ground there.
-- No game API here, so test/ends_test.lua runs it outside the game.

local geometry = require("westrom_track_geometry::/track_geometry/tg_geometry.script.tl")

-- What an end of the alignment is: "track", a free track end, where a line of track stops (a node
-- with a single track piece); "ground", a point on open ground, with no heading, grade or node.
-- (To come: any existing node, such as one mid-line; a point partway along a piece.)
local enum Kind
	"track"
	"ground"
end

-- An end of the alignment: where it is, and what it is. The layouts, profile, plan, proposal and
-- session read an end only through this.
local record End
	kind : Kind
	x : number
	y : number
	z : number -- height (m)
	dx : number -- unit direction out of the existing track, away from it; nil when it has none
	dy : number -- (nil with dx)
	grade : number -- the existing track's grade, going out along (dx, dy); nil when it has none
	node : integer -- the existing node at the end; nil when there is none
end

local record Ends
	Kind : Kind
	End : End
	SNAP : number
	MIN_LEG : number
	MAX_REACH : number
	LEAD : number
	FAR : number
	STRAIGHT_ANGLE : number
	STRAIGHT_OFFSET : number
	trackEnd : function(node : integer, x : number, y : number, z : number, dx : number, dy : number,
		grade : number) : End
	groundEnd : function(x : number, y : number, z : number) : End
	hasHeading : function(e : End) : boolean
	name : function(e : End) : string
	key : function(e : End) : string
	initialPis : function(a : End, b : End) : {geometry.Vec}, string
	snap : function(near : {End}, onHovered : {integer : boolean}, x : number, y : number, z : number,
		exclude : integer) : End, string
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

-- The free track end at node, at (x, y, z), with (dx, dy) the unit direction out of its piece and
-- grade the piece's grade going out along it.
function M.trackEnd(node : integer, x : number, y : number, z : number, dx : number, dy : number, grade : number) : End
	return { kind = "track", node = node, x = x, y = y, z = z, dx = dx, dy = dy, grade = grade }
end

-- The point (x, y) on the ground, z the terrain's height there.
function M.groundEnd(x : number, y : number, z : number) : End
	return { kind = "ground", x = x, y = y, z = z }
end

-- Does the new track have to leave (or arrive at) e along a direction of its own?
function M.hasHeading(e : End) : boolean
	return e.dx ~= nil
end

-- e for a person: "node 7", "the ground at (120, -45)".
function M.name(e : End) : string
	if e.node ~= nil then return "node " .. tostring(e.node) end
	return string.format("the ground at (%.0f, %.0f)", e.x, e.y)
end

-- What tells e apart from another end: its node, else where it is (to the centimetre).
function M.key(e : End) : string
	if e.node ~= nil then return "n" .. tostring(e.node) end
	return string.format("g%.2f,%.2f", e.x, e.y)
end

-- With b a ground end and a not: one turn on a's ray, as far from a as from b, so the curve there
-- is symmetric and takes all of both legs ("arc", like the game's own arc). That turn is at least
-- dist/2 out, so never closer than MIN_LEG; when b is behind or beside a (no such turn) or it is
-- further out than MAX_REACH, the turn goes min(LEAD, dist/3) out ("turn on the ray"). Laid from
-- a to b; the caller reverses it when the ground end comes first.
local function towardGround(a : End, b : End, dist : number) : {geometry.Vec}, string
	local ex, ey = b.x - a.x, b.y - a.y
	local along = ex * a.dx + ey * a.dy
	-- |a + t (a.dx, a.dy) - b| = t
	local t = along > 0 and dist * dist / (2 * along) or math.huge
	local how = "arc"
	if t > M.MAX_REACH then t, how = math.min(M.LEAD, dist / 3), "turn on the ray" end
	return { geometry.vec(a.x, a.y, 0), geometry.vec(a.x + t * a.dx, a.y + t * a.dy, 0), geometry.vec(b.x, b.y, 0) }, how
end

-- The PIs from a to b, at z = 0, and how they were laid. With a ground end:
--   "straight"    : both on the ground (no turns);
--   "arc", "turn on the ray": one ground end (towardGround).
-- Between two ends with headings, in order:
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
	local ha, hb = M.hasHeading(a), M.hasHeading(b)
	if not ha and not hb then return { geometry.vec(a.x, a.y, 0), geometry.vec(b.x, b.y, 0) }, "straight" end
	if not hb then return towardGround(a, b, dist) end
	if not ha then
		local back, how = towardGround(b, a, dist)
		return { back[3], back[2], back[1] }, how
	end
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

-- What the mouse at (x, y) picks, from the free ends near it (onHovered: those of the piece under
-- the mouse, which is a track piece when there are any): an end of the piece under the mouse
-- however far; any other within SNAP; of those, the nearest. Never the node exclude. Else, off
-- track, the ground there (z its height). nil and a hint when the mouse is over track with no
-- free end near, or over no ground (x nil: then only the hovered piece's ends).
function M.snap(near : {End}, onHovered : {integer : boolean}, x : number, y : number, z : number,
	exclude : integer) : End, string
	local best : End = nil
	local bestD = math.huge
	for _, e in ipairs(near) do
		if e.node ~= exclude then
			local d = x ~= nil and math.sqrt((e.x - x) ^ 2 + (e.y - y) ^ 2) or 0.0
			if (d <= M.SNAP or onHovered[e.node]) and d < bestD then best, bestD = e, d end
		end
	end
	if best ~= nil then return best, nil end
	if next(onHovered) ~= nil then return nil, "No free track end here. Point at the last piece of a line, near its end." end
	if x == nil or z == nil then return nil, "Point at the ground or at the end of a track." end
	return M.groundEnd(x, y, z), nil
end

return M
