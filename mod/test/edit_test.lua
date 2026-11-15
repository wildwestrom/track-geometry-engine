-- Offline checks for editing the alignment (tg_edit.script.tl). Run from mod/ after check.sh
-- builds .tlpath/:
--   lua test/edit_test.lua
local tl = require("tl")
tl.loader()
package.path = ".tlpath/?.tl;" .. package.path
local G = require("westrom_track_geometry::/track_geometry/tg_geometry.script.tl")
local A = require("westrom_track_geometry::/track_geometry/tg_alignment.script.tl")
local E = require("westrom_track_geometry::/track_geometry/tg_edit.script.tl")

local failures = 0
local function check(ok, what)
	print((ok and "ok   " or "FAIL ") .. what)
	if not ok then failures = failures + 1 end
end
local function atan2(y, x) return math.atan2 and math.atan2(y, x) or math.atan(y, x) end
local function angleDiff(a, b) return math.abs(atan2(math.sin(a - b), math.cos(a - b))) end
local function endAt(x, y, deg)
	return { x = x, y = y, dx = math.cos(math.rad(deg)), dy = math.sin(math.rad(deg)) }
end
local dp = E.PARAMS
local function dist(a, b) return math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2) end

-- The path still starts and ends on the ends, along their headings, with sound nodes.
local function joinsSmoothly(e, what)
	local nodes = E.nodes(e)
	local first, last = nodes[1], nodes[#nodes]
	local leave, arrive = atan2(e.a.dy, e.a.dx), atan2(-e.b.dy, -e.b.dx)
	local bad = #nodes < 2
	for _, nd in ipairs(nodes) do
		if nd.x ~= nd.x or nd.y ~= nd.y or nd.heading ~= nd.heading then bad = true end
	end
	check(not bad and math.abs(first.x - e.a.x) + math.abs(first.y - e.a.y) < 1e-6
		and math.abs(last.x - e.b.x) + math.abs(last.y - e.b.y) < 1e-6
		and angleDiff(first.heading, leave) < 1e-6 and angleDiff(last.heading, arrive) < 1e-6,
		what .. ": joins both ends along their headings")
end

-- No two curves overlap, and none overruns a leg.
local function noOverlap(e, what)
	local ls, pis = E.corners(e), E.polyline(e)
	local ok = true
	for k = 1, #pis - 1 do
		local len = dist(pis[k], pis[k + 1])
		local used = (ls[k] and ls[k].budget or 0) + (ls[k + 1] and ls[k + 1].budget or 0)
		if used > len + 1e-9 then ok = false end
	end
	check(ok, what .. ": no curves overlap")
end

-- long s-curve: a lead turn next to each end, sliding on its ray, and a free turn between them
local e = E.new(endAt(0, 0, 0), endAt(1000, 100, 180))
check(E.turnCount(e) == 3 and E.mobility(e, 2) == "ray" and E.mobility(e, 3) == "free" and E.mobility(e, 4) == "ray",
	"long s-curve: the leads slide on rays, the middle turn is free")
check(E.movePi(e, 2, 150, 80) and math.abs(E.polyline(e)[2].y) < 1e-12 and math.abs(E.polyline(e)[2].x - 150) < 1e-9,
	"long s-curve: a lead moves only along its end's ray")
joinsSmoothly(e, "long s-curve after sliding")
local ok = E.removePi(e, 2)
check(not ok and E.turnCount(e) == 3, "long s-curve: a turn next to an end cannot be removed")
check(E.movePi(e, 3, 420, -150) and E.polyline(e)[3].x == 420 and E.polyline(e)[3].y == -150, "a free turn moves anywhere")
noOverlap(e, "after moving the middle turn")
joinsSmoothly(e, "after moving the middle turn")
check(not E.movePi(e, 3, E.polyline(e)[2].x + 1, E.polyline(e)[2].y), "a turn cannot sit on its neighbour")

-- add a turn in a middle leg: free, and removable
local rev = e.rev
local i = E.insertOnLeg(e, 3, 500, 0)
check(i == 4 and E.turnCount(e) == 4 and E.mobility(e, 4) == "free" and e.rev > rev, "add a turn on a middle leg: free")
joinsSmoothly(e, "after adding a turn")
check(E.removePi(e, 4) and E.turnCount(e) == 3, "a free turn can be removed")

-- s-curve: one turn on each end's ray, both sliding
local sc = E.new(endAt(0, 0, 0), endAt(600, 100, 180))
check(E.turnCount(sc) == 2 and E.mobility(sc, 2) == "ray" and E.mobility(sc, 3) == "ray", "s-curve: two turns, both on rays")
check(E.movePi(sc, 3, 350, 140) and math.abs(E.polyline(sc)[3].y - 100) < 1e-9 and math.abs(E.polyline(sc)[3].x - 350) < 1e-9,
	"s-curve: the second turn slides on its end's ray")
noOverlap(sc, "s-curve after sliding")
joinsSmoothly(sc, "s-curve after sliding")

-- corner: one turn where the rays meet, fixed until a turn is added
local c = E.new(endAt(0, 0, 0), endAt(500, 400, -90))
check(E.turnCount(c) == 1 and E.mobility(c, 2) == "fixed", "corner: one turn, fixed")
check(not E.movePi(c, 2, 450, 50) and E.polyline(c)[2].x == 500 and E.polyline(c)[2].y == 0, "corner: the turn does not move")
check(not E.removePi(c, 2) and E.turnCount(c) == 1, "corner: the turn cannot be removed")
joinsSmoothly(c, "corner as laid")
-- adding a turn on a leg of the corner splits it in place: the track does not move
local size = E.corners(c)[2].budget
local entry2 = E.corners(c)[2].entryPoint
local before = E.nodes(c)
i = E.insertOnLeg(c, 1, entry2.x / 2, 30)
check(i == 2 and E.turnCount(c) == 2 and E.mobility(c, 2) == "ray" and E.mobility(c, 3) == "ray",
	"corner + a turn: both turns slide on rays")
check(math.abs(E.polyline(c)[2].x - entry2.x / 2) < 1e-9 and E.polyline(c)[2].y == 0, "corner + a turn: the new turn is on the leg")
check(math.abs(E.corners(c)[3].budget - size) < 1e-9, "corner + a turn: the old turn keeps its curve size")
local after = E.nodes(c)
local moved = #after ~= #before
for k = 1, math.min(#before, #after) do
	if math.abs(after[k].x - before[k].x) + math.abs(after[k].y - before[k].y) > 1e-9 then moved = true end
end
check(not moved, "corner + a turn: the path is unchanged")
joinsSmoothly(c, "corner + a turn")
-- the curve fills its shorter leg (an end curve takes all its room), so a turn added there sits
-- inside the curve, which shrinks to make room; the path still joins
local c2 = E.new(endAt(0, 0, 0), endAt(500, 400, -90))
i = E.insertOnLeg(c2, 2, 480, 300)
check(i == 3 and E.mobility(c2, 2) == "ray" and E.mobility(c2, 3) == "ray", "corner + a turn on the filled leg: both on rays")
noOverlap(c2, "corner + a turn on the filled leg")
joinsSmoothly(c2, "corner + a turn on the filled leg")
check(E.movePi(c, 2, 60, 0) and E.movePi(c, 3, 500, 100), "corner + a turn: both turns slide")
joinsSmoothly(c, "corner + a turn, slid")

-- straight: adding a turn adds three, the middle one free
local s = E.new(endAt(0, 0, 0), endAt(600, 0, 180))
i = E.insertOnLeg(s, 1, 300, 50)
check(i == 3 and E.turnCount(s) == 3 and E.mobility(s, 3) == "free" and math.abs(E.polyline(s)[3].x - 300) < 1e-9,
	"straight: adding a turn adds three, the middle one free at the mouse")
check(math.abs(E.polyline(s)[2].x - 150) < 1e-9 and math.abs(E.polyline(s)[4].x - 450) < 1e-9,
	"straight: the turns next to the ends stop halfway to the new turn when LEAD does not fit")
local w = E.new(endAt(0, 0, 0), endAt(1000, 0, 180))
E.insertOnLeg(w, 1, 500, 0)
check(math.abs(E.polyline(w)[2].x - 200) < 1e-9 and math.abs(E.polyline(w)[4].x - 800) < 1e-9,
	"straight: on a long span the turns next to the ends go LEAD out")
check(E.movePi(s, 3, 300, 120), "straight: the middle turn moves off the line")
noOverlap(s, "straight after bending")
joinsSmoothly(s, "straight after bending")

-- brackets: drag one to change the curve's budget, within its bounds
local hs = E.handles(s)
local entry
for _, h in ipairs(hs) do if h.kind == "entry" and h.i == 3 then entry = h end end
check(entry ~= nil, "a curving turn has brackets")
local before = E.length(s)
local p3 = E.polyline(s)[3]
check(E.budget(s, 3) == nil, "a new turn's curve sizes itself")
check(E.dragBracket(s, 3, true, p3.x + 1.5 * (entry.x - p3.x), p3.y + 1.5 * (entry.y - p3.y)), "drag a bracket away from its turn")
check(E.length(s) < before, "a wider curve makes the path shorter")
E.dragBracket(s, 3, true, p3.x, p3.y)
local pl = E.polyline(s)
check(math.abs(E.budget(s, 3) - G.cornerLayout(pl[2], p3, pl[4], dp, nil).geometry.minBudget) < 1e-9,
	"a bracket stops at the minimum radius")
check(dp.minRadius == 40, "the minimum radius is 40 m, as the game allows")
local tightest = math.huge
for _, seg in ipairs(E.path(s)) do
	if seg.kind == "arc" and G.length(seg) > 1e-6 then tightest = math.min(tightest, seg.radius) end
end
-- (the radius fit converges from above, to within a few cm in its 4 steps)
check(tightest >= dp.minRadius - 1e-9 and tightest < dp.minRadius + 0.05,
	string.format("a bracket dragged to its turn shrinks the curve to R 40 m (R %.3f m)", tightest))
local l = E.corners(s)[3]
E.dragBracket(s, 3, false, p3.x + 1e5 * l.geometry.uOut.x, p3.y + 1e5 * l.geometry.uOut.y)
local after = E.corners(s)
check(math.abs(E.budget(s, 3) - l.geometry.maxBudget) < 1e-9 and math.abs(after[3].budget - l.geometry.maxBudget) < 1e-9,
	"a bracket stops where the neighbouring curve can shrink no more")
local auto2 = G.cornerLayouts(E.polyline(s), dp, {})[2]
check(after[2].budget < auto2.budget - 1e-9 and math.abs(after[2].budget - auto2.geometry.minBudget) < 1e-9,
	"an end curve of its own size gives way, down to its minimum radius")
noOverlap(s, "straight at the widest")
-- an end curve the player sized keeps its size, and bounds the curve beside it
-- (curve 3 down to its smallest, so curve 2 has room; curve 2 sized by its exit bracket; then
-- curve 3 as wide as it goes)
local fixed = after[2].budget + 20
E.dragBracket(s, 3, true, p3.x, p3.y)
local p2, u2 = pl[2], E.corners(s)[2].geometry.uOut
E.dragBracket(s, 2, false, p2.x + fixed * u2.x, p2.y + fixed * u2.y)
check(math.abs(E.budget(s, 2) - fixed) < 1e-9, "an end curve sized by its bracket")
local l3 = E.corners(s)[3]
E.dragBracket(s, 3, false, p3.x + 1e5 * l3.geometry.uOut.x, p3.y + 1e5 * l3.geometry.uOut.y)
local sized = E.corners(s)
check(math.abs(sized[2].budget - fixed) < 1e-9 and math.abs(sized[2].budget + sized[3].budget - dist(pl[2], pl[3])) < 1e-9,
	"a sized end curve keeps its size; the bracket stops where it begins")
noOverlap(s, "straight with a sized end curve")
joinsSmoothly(s, "straight after resizing")
-- an end curve stays automatic when a turn is added beside it, so it refills its room as its
-- turn slides along the ray
local r = E.new(endAt(0, 0, 0), endAt(600, 0, 180))
E.insertOnLeg(r, 1, 300, 0)
E.movePi(r, 3, 300, 120)
E.insertOnLeg(r, 3, 375, 60)
check(E.budget(r, 2) == nil and E.budget(r, 5) == nil, "adding a turn leaves the end curves automatic")
E.movePi(r, 2, 60, 0)
E.movePi(r, 2, 250, 0)
local full = E.corners(r)[2]
check(full ~= nil and math.abs(full.budget - full.geometry.maxBudget) < 1e-9,
	"an end curve takes all its room again after its turn slides back out")
noOverlap(r, "end curves after adding a turn")

-- what is under the mouse while editing the horizontal alignment
local function same(h, g) return h ~= nil and g ~= nil and h.kind == g.kind and h.i == g.i end
local function hitAt(e, x, y, r) return E.hit(e, false, x, y, r) end
hs = E.handles(s)
local h1 = hs[#hs]
check(same(hitAt(s, h1.x + 3, h1.y, 5), h1), "a handle within the radius is hit")
local turn3 = E.turn(s, 3)
check(same(hitAt(s, turn3.x + 1, turn3.y, 5), turn3) and turn3.kind == "pi" and turn3.mobility == "free",
	"a turn under the mouse is a pi hit")
local q = E.polyline(s)
local mx, my = (q[1].x + q[2].x) / 2, (q[1].y + q[2].y) / 2 + 2
local lh = hitAt(s, mx, my, 5)
check(lh ~= nil and lh.kind == "leg" and lh.i == 1, "off the handles, a leg within the radius is hit")
check(hitAt(s, 300, -400, 5) == nil, "nothing far from the edit is hit")
-- where a curve leaves its legs, the track there still adds a turn on the nearest leg
local function offLegs(e)
	local pis, best, bestD = E.polyline(e), nil, 0
	for _, nd in ipairs(E.nodes(e)) do
		local d = math.huge
		for k = 1, #pis - 1 do
			local a, b = pis[k], pis[k + 1]
			local lx, ly = b.x - a.x, b.y - a.y
			local t = math.max(0, math.min(1, ((nd.x - a.x) * lx + (nd.y - a.y) * ly) / (lx * lx + ly * ly)))
			d = math.min(d, dist(nd, { x = a.x + t * lx, y = a.y + t * ly }))
		end
		if d > bestD then best, bestD = nd, d end
	end
	return best, bestD
end
local nd, off = offLegs(c)
local th = hitAt(c, nd.x, nd.y, off * 0.8)
check(off > 5 and th ~= nil and th.kind == "leg" and th.i ~= nil and math.abs(th.s - nd.s) < 1e-6,
	"the track where it leaves the legs is hit, on the nearest leg: " .. string.format("%.1f m off", off))

-- The vertical profile: elevation points between the ends.
local function vend(x, y, deg, z, grade)
	local e = endAt(x, y, deg)
	e.z, e.grade = z, grade
	return e
end
local v = assert(E.new(vend(0, 0, 0, 100, 0), vend(1000, 0, 180, 110, 0)))
local before = E.profile(v)
local i = E.insertElevation(v, 400)
local after = E.profile(v)
-- the monotone profile picks its own grade at the new point, so the curve around it reshapes a
-- little (0.42 m at most here), but the point is where the profile was
local Pv = require("westrom_track_geometry::/track_geometry/tg_profile.script.tl")
local moved = 0
for s = 0, 1000, 10 do moved = math.max(moved, math.abs(Pv.heightAt(before, s) - Pv.heightAt(after, s))) end
check(i == 1 and math.abs(Pv.heightAt(after, 400) - Pv.heightAt(before, 400)) < 1e-9 and moved < 0.5,
	string.format("an added elevation point sits on the profile; the rest moves %.2f m at most", moved))
check(E.insertElevation(v, 700) == 2 and #E.points(v) == 2 and E.points(v)[1].s < E.points(v)[2].s, "points stay in order")
check(not E.points(v)[1].tooClose and not E.points(v)[2].tooClose and E.spacingProblem(v) == nil, "points 20 m clear are not too close")

local rev, nodes0 = v.rev, E.nodes(v)
check(E.moveElevation(v, 1, 450, E.points(v)[1].z + 1, 0.04) and v.rev > rev
	and math.abs(E.points(v)[1].s - 450) < 1e-9, "a point moves along the path and up")
check(E.nodes(v) == nodes0, "a vertical change keeps the sampled path")
E.moveElevation(v, 1, 400, E.points(v)[1].z + 100, 0.04)
local steep = E.steepest(v)
check(steep <= 0.04 + 1e-9 and steep > 0.039, "raising a point stops at the grade limit: " .. steep * 1000 .. " permille")

-- The 20 m spacing does not stop a drag: a point too close is red, left out of the profile, and
-- blocks the build.
local P = require("westrom_track_geometry::/track_geometry/tg_profile.script.tl")
local function zs(e)
	local p = assert(E.profile(e))
	local out = {}
	for s = 0, E.length(e), 10 do out[#out + 1] = P.heightAt(p, s) end
	return out
end
local function sameZ(a, b)
	if #a ~= #b then return false end
	for k = 1, #a do if math.abs(a[k] - b[k]) > 1e-9 then return false end end
	return true
end
local sp = assert(E.new(vend(0, 0, 0, 100, 0), vend(1000, 0, 180, 110, 0)))
E.insertElevation(sp, 300)
E.insertElevation(sp, 600)
E.moveElevation(sp, 1, 300, 104, 1.0)
E.moveElevation(sp, 2, 600, 108, 1.0)
local without2 = assert(E.new(vend(0, 0, 0, 100, 0), vend(1000, 0, 180, 110, 0)))
E.insertElevation(without2, 300)
E.moveElevation(without2, 1, 300, 104, 1.0)
local ok2, j = E.moveElevation(sp, 2, 312, 108, 1.0)
check(ok2 and j == 2 and math.abs(E.points(sp)[2].s - 312) < 1e-9, "a point dragged within MIN_SPAN of its neighbour is not stopped")
local q = E.points(sp)
check(q[2].tooClose and not q[1].tooClose and math.abs(q[2].gap - 12) < 1e-9 and q[2].near == "neighbour",
	"the dragged point is the one too close, and how close: " .. tostring(q[2].gap))
local why = E.spacingProblem(sp)
check(why == "elevation point 2 is too close to its neighbour (12 m, needs 20 m)", "why: " .. tostring(why))
check(E.profile(sp) ~= nil and sameZ(zs(sp), zs(without2)), "the profile leaves out the point too close")
-- dragged past its neighbour: the points reorder, and the profile follows the new order
ok2, j = E.moveElevation(sp, 2, 250, 108, 1.0)
q = E.points(sp)
check(ok2 and j == 1 and math.abs(q[1].s - 250) < 1e-9 and q[1].z == 108 and q[2].z == 104 and q[1].s < q[2].s,
	"a point dragged past its neighbour comes before it")
check(not q[1].tooClose and not q[2].tooClose and E.spacingProblem(sp) == nil, "dragged clear: no point too close")
local swapped = assert(E.new(vend(0, 0, 0, 100, 0), vend(1000, 0, 180, 110, 0)))
E.insertElevation(swapped, 250); E.insertElevation(swapped, 300)
E.moveElevation(swapped, 1, 250, 108, 1.0); E.moveElevation(swapped, 2, 300, 104, 1.0)
check(sameZ(zs(sp), zs(swapped)), "the profile follows the new order")
-- near an end
ok2, j = E.moveElevation(sp, 1, 8, 108, 1.0)
q = E.points(sp)
check(ok2 and q[1].tooClose and q[1].near == "end" and math.abs(q[1].gap - 8) < 1e-9, "a point dragged within MIN_SPAN of an end is too close")
check(E.spacingProblem(sp) == "elevation point 1 is too close to the end (8 m, needs 20 m)", "why: " .. tostring(E.spacingProblem(sp)))
ok2 = E.moveElevation(sp, 1, -50, 108, 1.0)
check(ok2 and E.points(sp)[1].s == 0, "a point stops at the end of the path")
-- a point added within MIN_SPAN of another is added, too close, rather than refused
local k = E.insertElevation(sp, 310)
check(k == 3 and E.points(sp)[3].tooClose and not E.points(sp)[2].tooClose,
	"a point added within MIN_SPAN of another is added too close (the earlier one stays)")
check(E.removeElevation(sp, 3) and E.removeElevation(sp, 1) and E.spacingProblem(sp) == nil, "removing the points too close clears it")

-- the grade limit still stops a drag, also once the point leaves the too-close range
local gl = assert(E.new(vend(0, 0, 0, 100, 0), vend(1000, 0, 180, 100, 0)))
E.insertElevation(gl, 500)
E.insertElevation(gl, 510) -- too close to the first
ok2 = E.moveElevation(gl, 2, 510, 160, 0.04) -- too close, so no grade check: its height goes through
check(ok2 and E.points(gl)[2].z == 160 and E.points(gl)[2].tooClose, "a point too close changes height freely (it is not in the profile)")
ok2, j = E.moveElevation(gl, 2, 700, 160, 0.04)
local g2 = E.points(gl)[j]
check(ok2 and E.steepest(gl) <= 0.04 + 1e-9, string.format("dragged clear, the grade limit stops it (%.1f permille)", E.steepest(gl) * 1000))
check(g2.tooClose or g2.s < 700, "it does not reach where the profile would be too steep: " .. string.format("%.1f m", g2.s))
-- a point too close, slid clear and raised at once: once clear, the grade limit stops it
local gc = assert(E.new(vend(0, 0, 0, 100, 0), vend(1000, 0, 180, 100, 0)))
E.insertElevation(gc, 500)
E.insertElevation(gc, 510)
-- (at 20 ‰ it cannot clear at all: a 20 m span peaking at the point is 1.5 × its chord grade)
ok2, j = E.moveElevation(gc, 2, 700, 106, 0.03)
local g3 = E.points(gc)[j]
check(ok2 and not g3.tooClose and g3.s > 520 and g3.s < 700 and E.steepest(gc) <= 0.03 + 1e-9,
	string.format("cleared, the grade limit stops it (%.1f m, %.1f m high, %.1f permille)", g3.s, g3.z, E.steepest(gc) * 1000))
local gr = assert(E.new(vend(0, 0, 0, 100, 0), vend(1000, 0, 180, 100, 0)))
E.insertElevation(gr, 500); E.insertElevation(gr, 519.6)
check(E.spacingProblem(gr) == "elevation point 2 is too close to its neighbour (19 m, needs 20 m)", "a gap is rounded down: " .. tostring(E.spacingProblem(gr)))

-- what is under the mouse while editing the vertical alignment
local pt1 = E.points(v)[1]
local vh = E.hit(v, true, pt1.x + 2, pt1.y + 1, 5)
check(vh ~= nil and vh.kind == "point" and vh.i == 1 and vh.s == pt1.s, "an elevation point within the radius is hit")
local th2 = E.hit(v, true, 200, 3, 5)
check(th2 ~= nil and th2.kind == "track" and math.abs(th2.s - 200) < 1e-6, "else the track within the radius, at its chainage")
check(E.hit(v, true, 200, 30, 5) == nil, "nothing far from the track is hit")
local sx, sy = E.chainageAt(v, 333, 4)
check(math.abs(sx - 333) < 1e-6 and math.abs(sy - 4) < 1e-6, "chainage and distance off the track")

-- the track up on its profile (a bridge, 100 m over the ground at 0): the mouse's ground point is
-- behind it, so it is picked along the view ray, from the eye through the ground point
local hi = assert(E.new(vend(0, 0, 0, 100, 0), vend(1000, 0, 180, 100, 0)))
-- the eye at (500, -300, 400) looks through the track at (500, 0, 100) to the ground at (500, 100, 0)
local ray = { ex = 500, ey = -300, ez = 400, gx = 500, gy = 100, gz = 0 }
check(E.hit(hi, true, 500, 100, 5) == nil, "on the ground alone, the mouse is 100 m off the raised track")
local rh = E.hit(hi, true, 500, 100, 5, ray)
check(rh ~= nil and rh.kind == "track" and math.abs(rh.s - 500) < 1, "along the view ray, the raised track is hit: " .. tostring(rh and rh.s))
local rs, rd = E.chainageOnRay(hi, ray)
check(math.abs(rs - 500) < 1 and rd < 1, string.format("the chainage where the ray passes the track (%.1f m, %.2f m off)", rs, rd))
E.insertElevation(hi, 500)
local ph = E.hit(hi, true, 503, 100, 5, ray)
check(ph ~= nil and ph.kind == "point" and ph.i == 1, "an elevation point up at its height is hit along the ray")
local past = E.hit(hi, true, 800, 100, 5, { ex = 800, ey = -300, ez = 400, gx = 800, gy = 100, gz = 0 })
check(past ~= nil and past.kind == "track" and math.abs(past.s - 800) < 1, "a ray 300 m past the point hits the track there, not the point")
local low = E.hit(v, true, 200, 3, 5, { ex = 200, ey = -300, ez = 400, gx = 200, gy = 3, gz = 100 })
check(low ~= nil and low.kind == "track" and math.abs(low.s - 200) < 1, "a track on the ground is still hit at the ground point")

-- the elevation points follow the path when a turn moves; the path is sampled again
local f = E.new(vend(0, 0, 0, 100, 0), vend(1000, 0, 180, 110, 0))
E.insertOnLeg(f, 1, 500, 0)
E.insertElevation(f, 300)
local frac0, hrev0, fn0 = E.points(f)[1].s / E.length(f), f.hrev, E.nodes(f)
E.movePi(f, 3, 500, 150)
local fp = E.points(f)[1]
local ax, ay = A.pointAt(E.nodes(f), fp.s)
check(f.hrev > hrev0 and E.nodes(f) ~= fn0 and E.length(f) > 1000 + 1, "moving a turn samples the path again")
check(math.abs(fp.s / E.length(f) - frac0) < 1e-9 and math.abs(ax - fp.x) + math.abs(ay - fp.y) < 1e-6,
	"an elevation point keeps its place along the path and sits on it after a turn moves")

-- a profile that starts over the limit: moves may not make it steeper, but may ease it (the
-- point at 100 m sits at 4.7 m; raising it towards 7 m eases the climb after it)
local w = assert(E.new(vend(0, 0, 0, 0, 0), vend(400, 0, 180, 30, 0)))
E.insertElevation(w, 100)
local start = E.steepest(w)
check(start > 0.04, "steep profile: over the limit to begin with")
E.moveElevation(w, 1, 100, E.points(w)[1].z - 20, 0.04)
check(E.steepest(w) <= start + 1e-9, "steep profile: a move does not make it steeper")
local z0 = E.points(w)[1].z
E.moveElevation(w, 1, 100, 7, 0.04)
check(E.steepest(w) <= start + 1e-9 and E.points(w)[1].z ~= z0, "steep profile: a move towards easing it goes through")

-- a height set directly goes past the limit; the profile is then too steep and says where
local hs = assert(E.new(vend(0, 0, 0, 100, 0), vend(1000, 0, 180, 100, 0)))
E.insertElevation(hs, 500)
check(E.gradeProblem(hs, 0.04) == nil, "a level profile is not too steep")
local rev1 = hs.rev
check(E.setHeight(hs, 1, 160) and E.points(hs)[1].z == 160 and E.points(hs)[1].s == 500 and hs.rev > rev1,
	"a height set directly applies as asked, past the limit")
check(E.steepest(hs) > 0.04, string.format("the profile is past the limit (%.1f permille)", E.steepest(hs) * 1000))
local gp, gs = E.gradeProblem(hs, 0.04)
local worst, worstAt = 0, 0
for _, nd in ipairs(E.nodes(hs)) do
	local g = math.abs(P.gradeAt(assert(E.profile(hs)), nd.s))
	if g > worst then worst, worstAt = g, nd.s end
end
check(gs == worstAt and gp == string.format("too steep: %d ‰ at %.0f m (limit 40 ‰)", math.ceil(worst * 1000), worstAt),
	"why: " .. tostring(gp))
check(not E.setHeight(hs, 2, 100), "no such point: nothing set")
-- a drag on it still does not make it steeper
local st = E.steepest(hs)
E.moveElevation(hs, 1, 500, 200, 0.04)
check(E.steepest(hs) <= st + 1e-9 and E.points(hs)[1].z == 160, "a drag on a profile too steep does not make it steeper")
check(E.setHeight(hs, 1, 100) and E.gradeProblem(hs, 0.04) == nil, "set back level: no longer too steep")
-- a point too close is not in the profile, so its height never makes it too steep
E.insertElevation(hs, 510)
check(E.points(hs)[2].tooClose and E.setHeight(hs, 2, 300) and E.gradeProblem(hs, 0.04) == nil,
	"a point too close set very high does not make the profile too steep")

check(E.removeElevation(v, 2) and #E.points(v) == 1 and not E.removeElevation(v, 5), "remove a point")

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
