-- The starting alignment between two picked track ends. Each end is a point and the unit direction
-- pointing out of the existing track, away from it; the new track leaves the first end along its
-- direction and arrives at the second against its direction. The PIs put the first leg along the
-- first end's direction and the last leg along the second end's, so buildPath keeps both headings.
-- A turned layout puts a lead PI out on each end's ray (it slides there) and a free PI halfway
-- between the leads, so the middle leg runs near the straight line between the ends and the player
-- can drag the alignment from the start.
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

local record Ends
	End : End
	MIN_LEG : number
	MAX_REACH : number
	LEAD : number
	initialPis : function(a : End, b : End) : {geometry.Vec}, string
end

local M : Ends = {}

-- Shortest leg from an end to its PI (m).
M.MIN_LEG = 20.0
-- Furthest the rays may meet from an end for a "corner", as a multiple of the distance between
-- the ends. Rays that meet further away (nearly parallel) make an "s-curve".
M.MAX_REACH = 3.0
-- How far out of each end its lead PI goes (m), when the room allows.
M.LEAD = 200.0

-- a, a lead la out on a's ray, the middle PI halfway between the leads, a lead lb out on b's ray, b.
local function leads(a : End, b : End, la : number, lb : number) : {geometry.Vec}
	local ax, ay, bx, by = a.x + la * a.dx, a.y + la * a.dy, b.x + lb * b.dx, b.y + lb * b.dy
	return { geometry.vec(a.x, a.y, 0), geometry.vec(ax, ay, 0), geometry.vec((ax + bx) / 2, (ay + by) / 2, 0),
		geometry.vec(bx, by, 0), geometry.vec(b.x, b.y, 0) }
end

-- The PIs from a to b, at z = 0, and how they were laid: "straight" (b dead ahead of a, facing
-- it), "corner" (the rays meet ahead of both ends; each lead LEAD out or halfway to where they
-- meet) or "s-curve" (each lead LEAD out or a third of the distance between the ends). Either way
-- the middle PI sits halfway between the leads, on a straight, so the leads take the turn. nil and
-- a reason when the ends are too close.
function M.initialPis(a : End, b : End) : {geometry.Vec}, string
	local ex, ey = b.x - a.x, b.y - a.y
	local dist = math.sqrt(ex * ex + ey * ey)
	if dist < 2 * M.MIN_LEG then return nil, "the ends are too close" end
	local pa, pb = geometry.vec(a.x, a.y, 0), geometry.vec(b.x, b.y, 0)
	-- a + s (a.dx, a.dy) = b + t (b.dx, b.dy)
	local cross = a.dx * b.dy - a.dy * b.dx
	local along = (ex * a.dx + ey * a.dy) / dist
	local lateral = a.dx * ey - a.dy * ex
	local facing = a.dx * b.dx + a.dy * b.dy < -0.999999
	if facing and along > 0 and math.abs(lateral) < 1e-3 then
		return { pa, pb }, "straight"
	end
	if math.abs(cross) > 1e-9 then
		local s = (ex * b.dy - ey * b.dx) / cross
		local t = (a.dy * ex - a.dx * ey) / cross
		local reach = M.MAX_REACH * dist
		if s >= M.MIN_LEG and t >= M.MIN_LEG and s <= reach and t <= reach then
			return leads(a, b, math.min(M.LEAD, s / 2), math.min(M.LEAD, t / 2)), "corner"
		end
	end
	local L = math.min(M.LEAD, dist / 3)
	return leads(a, b, L, L), "s-curve"
end

return M
