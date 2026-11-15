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

-- s-curve: a lead turn next to each end, sliding on its ray, and a free turn between them
local e = E.new(endAt(0, 0, 0), endAt(600, 100, 180))
check(E.turnCount(e) == 3 and E.mobility(e, 2) == "ray" and E.mobility(e, 3) == "free" and E.mobility(e, 4) == "ray",
	"s-curve: the leads slide on rays, the middle turn is free")
check(E.movePi(e, 2, 150, 80) and math.abs(E.polyline(e)[2].y) < 1e-12 and math.abs(E.polyline(e)[2].x - 150) < 1e-9,
	"s-curve: a lead moves only along its end's ray")
joinsSmoothly(e, "s-curve after sliding")
local ok = E.removePi(e, 2)
check(not ok and E.turnCount(e) == 3, "s-curve: a turn next to an end cannot be removed")
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

-- corner: the leads take the turn and the middle turn, between them, is free to drag
local c = E.new(endAt(0, 0, 0), endAt(500, 400, -90))
check(E.turnCount(c) == 3 and E.mobility(c, 3) == "free", "corner: the middle turn is free")
local cl = E.corners(c)
check(cl[2] ~= nil and cl[4] ~= nil and cl[3] == nil, "corner: the leads curve, the middle turn does not")
joinsSmoothly(c, "corner as laid")
check(E.movePi(c, 3, 450, 50), "corner: drag the middle turn out towards where the rays meet")
noOverlap(c, "corner after dragging")
joinsSmoothly(c, "corner after dragging")

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
local same = i == 1
for s = 0, 1000, 10 do
	local P = require("westrom_track_geometry::/track_geometry/tg_profile.script.tl")
	if math.abs(P.heightAt(before, s) - P.heightAt(after, s)) > 1e-9 then same = false end
end
check(same, "an added elevation point sits on the profile: nothing changes")
check(E.insertElevation(v, 410) == nil and E.insertElevation(v, 10) == nil, "no point within MIN_SPAN of another or an end")
check(E.insertElevation(v, 700) == 2 and #E.points(v) == 2 and E.points(v)[1].s < E.points(v)[2].s, "points stay in order")

local rev, nodes0 = v.rev, E.nodes(v)
check(E.moveElevation(v, 1, 450, E.points(v)[1].z + 1, 0.04) and v.rev > rev
	and math.abs(E.points(v)[1].s - 450) < 1e-9, "a point moves along the path and up")
check(E.nodes(v) == nodes0, "a vertical change keeps the sampled path")
E.moveElevation(v, 1, 400, E.points(v)[1].z + 100, 0.04)
local steep = E.steepest(v)
check(steep <= 0.04 + 1e-9 and steep > 0.039, "raising a point stops at the grade limit: " .. steep * 1000 .. " permille")
E.moveElevation(v, 1, 690, E.points(v)[1].z, 1.0) -- (no grade limit in the way)
check(math.abs(E.points(v)[1].s - (700 - E.MIN_SPAN)) < 1e-9, "a point stops MIN_SPAN short of its neighbour")

-- what is under the mouse while editing the vertical alignment
local pt1 = E.points(v)[1]
local vh = E.hit(v, true, pt1.x + 2, pt1.y + 1, 5)
check(vh ~= nil and vh.kind == "point" and vh.i == 1 and vh.s == pt1.s, "an elevation point within the radius is hit")
local th2 = E.hit(v, true, 200, 3, 5)
check(th2 ~= nil and th2.kind == "track" and math.abs(th2.s - 200) < 1e-6, "else the track within the radius, at its chainage")
check(E.hit(v, true, 200, 30, 5) == nil, "nothing far from the track is hit")
local sx, sy = E.chainageAt(v, 333, 4)
check(math.abs(sx - 333) < 1e-6 and math.abs(sy - 4) < 1e-6, "chainage and distance off the track")

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

-- a profile that starts over the limit: moves may not make it steeper, but may ease it
local w = assert(E.new(vend(0, 0, 0, 0, 0), vend(400, 0, 180, 30, 0)))
E.insertElevation(w, 200)
local start = E.steepest(w)
check(start > 0.04, "steep profile: over the limit to begin with")
E.moveElevation(w, 1, 200, E.points(w)[1].z - 20, 0.04)
check(E.steepest(w) <= start + 1e-9, "steep profile: a move does not make it steeper")
local z0 = E.points(w)[1].z
E.moveElevation(w, 1, 200, 15, 0.04)
check(E.steepest(w) <= start + 1e-9 and E.points(w)[1].z ~= z0, "steep profile: a move towards easing it goes through")

check(E.removeElevation(v, 2) and #E.points(v) == 1 and not E.removeElevation(v, 5), "remove a point")

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
