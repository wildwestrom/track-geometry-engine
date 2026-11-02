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
local dp = G.DEFAULT_PARAMS

-- The path still starts and ends on the ends, along their headings, with sound nodes.
local function joinsSmoothly(e, what)
	local nodes = A.sample(E.path(e, dp), 10)
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
	local ls = G.cornerLayouts(e.pis, dp, e.budgets)
	local ok = true
	for k = 1, #e.pis - 1 do
		local len = math.sqrt((e.pis[k + 1].x - e.pis[k].x) ^ 2 + (e.pis[k + 1].y - e.pis[k].y) ^ 2)
		local used = (ls[k] and ls[k].budget or 0) + (ls[k + 1] and ls[k + 1].budget or 0)
		if used > len + 1e-9 then ok = false end
	end
	check(ok, what .. ": no curves overlap")
end

-- s-curve: a lead turn next to each end, sliding on its ray, and a free turn between them
local e = E.new(endAt(0, 0, 0), endAt(600, 100, 180))
check(#e.pis == 5 and E.mobility(e, 2) == "ray" and E.mobility(e, 3) == "free" and E.mobility(e, 4) == "ray",
	"s-curve: the leads slide on rays, the middle turn is free")
check(E.movePi(e, 2, 150, 80) and math.abs(e.pis[2].y) < 1e-12 and math.abs(e.pis[2].x - 150) < 1e-9,
	"s-curve: a lead moves only along its end's ray")
joinsSmoothly(e, "s-curve after sliding")
local ok = E.removePi(e, 2)
check(not ok and #e.pis == 5, "s-curve: a turn next to an end cannot be removed")
check(E.movePi(e, 3, 420, -150) and e.pis[3].x == 420 and e.pis[3].y == -150, "a free turn moves anywhere")
noOverlap(e, "after moving the middle turn")
joinsSmoothly(e, "after moving the middle turn")
check(not E.movePi(e, 3, e.pis[2].x + 1, e.pis[2].y), "a turn cannot sit on its neighbour")

-- add a turn in a middle leg: free, and removable
local rev = e.rev
local i = E.insertOnLeg(e, 3, 500, 0, dp)
check(i == 4 and #e.pis == 6 and E.mobility(e, 4) == "free" and e.rev > rev, "add a turn on a middle leg: free")
joinsSmoothly(e, "after adding a turn")
check(E.removePi(e, 4) and #e.pis == 5, "a free turn can be removed")

-- corner: the leads take the turn and the middle turn, between them, is free to drag
local c = E.new(endAt(0, 0, 0), endAt(500, 400, -90))
check(#c.pis == 5 and E.mobility(c, 3) == "free", "corner: the middle turn is free")
local cl = G.cornerLayouts(c.pis, dp, c.budgets)
check(cl[2] ~= nil and cl[4] ~= nil and cl[3] == nil, "corner: the leads curve, the middle turn does not")
joinsSmoothly(c, "corner as laid")
check(E.movePi(c, 3, 450, 50), "corner: drag the middle turn out towards where the rays meet")
noOverlap(c, "corner after dragging")
joinsSmoothly(c, "corner after dragging")

-- straight: adding a turn adds three, the middle one free
local s = E.new(endAt(0, 0, 0), endAt(600, 0, 180))
i = E.insertOnLeg(s, 1, 300, 50, dp)
check(i == 3 and #s.pis == 5 and E.mobility(s, 3) == "free" and math.abs(s.pis[3].x - 300) < 1e-9,
	"straight: adding a turn adds three, the middle one free at the mouse")
check(math.abs(s.pis[2].x - 150) < 1e-9 and math.abs(s.pis[4].x - 450) < 1e-9,
	"straight: the turns next to the ends stop halfway to the new turn when LEAD does not fit")
local w = E.new(endAt(0, 0, 0), endAt(1000, 0, 180))
E.insertOnLeg(w, 1, 500, 0, dp)
check(math.abs(w.pis[2].x - 200) < 1e-9 and math.abs(w.pis[4].x - 800) < 1e-9,
	"straight: on a long span the turns next to the ends go LEAD out")
check(E.movePi(s, 3, 300, 120), "straight: the middle turn moves off the line")
noOverlap(s, "straight after bending")
joinsSmoothly(s, "straight after bending")

-- brackets: drag one to change the curve's budget, within its bounds
local hs = E.handles(s, dp)
local entry
for _, h in ipairs(hs) do if h.kind == "entry" and h.i == 3 then entry = h end end
check(entry ~= nil, "a curving turn has brackets")
local before = G.pathLength(E.path(s, dp))
local p3 = s.pis[3]
check(E.dragBracket(s, 3, true, p3.x + 1.5 * (entry.x - p3.x), p3.y + 1.5 * (entry.y - p3.y), dp), "drag a bracket away from its turn")
check(G.pathLength(E.path(s, dp)) < before, "a wider curve makes the path shorter")
E.dragBracket(s, 3, true, p3.x, p3.y, dp)
check(math.abs(s.budgets[3] - G.cornerLayout(s.pis[2], p3, s.pis[4], dp, nil).geometry.minBudget) < 1e-9,
	"a bracket stops at the minimum radius")
local l = G.cornerLayouts(s.pis, dp, s.budgets)[3]
E.dragBracket(s, 3, false, p3.x + 1e5 * l.geometry.uOut.x, p3.y + 1e5 * l.geometry.uOut.y, dp)
local after = G.cornerLayouts(s.pis, dp, s.budgets)
check(math.abs(s.budgets[3] - l.geometry.maxBudget) < 1e-9 and math.abs(after[3].budget - l.geometry.maxBudget) < 1e-9,
	"a bracket stops where the neighbouring curve can shrink no more")
local auto2 = G.cornerLayouts(s.pis, dp, {})[2]
check(after[2].budget < auto2.budget - 1e-9 and math.abs(after[2].budget - auto2.geometry.minBudget) < 1e-9,
	"an end curve of its own size gives way, down to its minimum radius")
noOverlap(s, "straight at the widest")
-- an end curve the player sized keeps its size, and bounds the curve beside it
local fixed = after[2].budget + 20
s.budgets[2], s.budgets[3] = fixed, nil
local l3 = G.cornerLayouts(s.pis, dp, s.budgets)[3]
E.dragBracket(s, 3, false, p3.x + 1e5 * l3.geometry.uOut.x, p3.y + 1e5 * l3.geometry.uOut.y, dp)
local sized = G.cornerLayouts(s.pis, dp, s.budgets)
check(math.abs(sized[2].budget - fixed) < 1e-9 and math.abs(sized[2].budget + sized[3].budget - math.sqrt((s.pis[3].x - s.pis[2].x) ^ 2 + (s.pis[3].y - s.pis[2].y) ^ 2)) < 1e-9,
	"a sized end curve keeps its size; the bracket stops where it begins")
noOverlap(s, "straight with a sized end curve")
joinsSmoothly(s, "straight after resizing")
-- an end curve stays automatic when a turn is added beside it, so it refills its room as its
-- turn slides along the ray
local r = E.new(endAt(0, 0, 0), endAt(600, 0, 180))
E.insertOnLeg(r, 1, 300, 0, dp)
E.movePi(r, 3, 300, 120)
E.insertOnLeg(r, 3, 375, 60, dp)
check(r.budgets[2] == nil and r.budgets[5] == nil, "adding a turn leaves the end curves automatic")
E.movePi(r, 2, 60, 0)
E.movePi(r, 2, 250, 0)
local full = G.cornerLayouts(r.pis, dp, r.budgets)[2]
check(full ~= nil and math.abs(full.budget - full.geometry.maxBudget) < 1e-9,
	"an end curve takes all its room again after its turn slides back out")
noOverlap(r, "end curves after adding a turn")
check(E.pick(hs, entry.x + 3, entry.y, 5) == entry and E.pick(hs, entry.x + 30, entry.y + 30, 5) == nil,
	"pick finds a handle within the radius only")
local leg, dist = E.nearestLeg(s, 30, 2)
check(leg == 1 and dist < 1e-6 + 2, "nearest leg")

-- The vertical profile: elevation points between the ends.
local function vend(x, y, deg, z, grade)
	local e = endAt(x, y, deg)
	e.z, e.grade = z, grade
	return e
end
local function chainages(len)
	local ss = {}
	for s = 0, len, 10 do ss[#ss + 1] = s end
	return ss
end
local v = assert(E.new(vend(0, 0, 0, 100, 0), vend(1000, 0, 180, 110, 0)))
local len, ss = 1000, chainages(1000)
local before = E.profile(v, len)
local i = E.insertElevation(v, 400, len)
local after = E.profile(v, len)
local same = i == 1
for _, s in ipairs(ss) do
	local P = require("westrom_track_geometry::/track_geometry/tg_profile.script.tl")
	if math.abs(P.heightAt(before, s) - P.heightAt(after, s)) > 1e-9 then same = false end
end
check(same, "an added elevation point sits on the profile: nothing changes")
check(E.insertElevation(v, 410, len) == nil and E.insertElevation(v, 10, len) == nil, "no point within MIN_SPAN of another or an end")
check(E.insertElevation(v, 700, len) == 2 and #v.elevations == 2 and v.elevations[1].f < v.elevations[2].f, "points stay in order")

local rev = v.rev
check(E.moveElevation(v, 1, 450, v.elevations[1].z + 1, len, ss, 0.04) and v.rev > rev
	and math.abs(v.elevations[1].f * len - 450) < 1e-9, "a point moves along the path and up")
E.moveElevation(v, 1, 400, v.elevations[1].z + 100, len, ss, 0.04)
local steep = E.steepest(v, len, ss)
check(steep <= 0.04 + 1e-9 and steep > 0.039, "raising a point stops at the grade limit: " .. steep * 1000 .. " permille")
E.moveElevation(v, 1, 690, v.elevations[1].z, len, ss, 1.0) -- (no grade limit in the way)
check(math.abs(v.elevations[1].f * len - (700 - E.MIN_SPAN)) < 1e-9, "a point stops MIN_SPAN short of its neighbour")

-- a profile that starts over the limit: moves may not make it steeper, but may ease it
local w = assert(E.new(vend(0, 0, 0, 0, 0), vend(400, 0, 180, 30, 0)))
local ss4 = chainages(400)
E.insertElevation(w, 200, 400)
local start = E.steepest(w, 400, ss4)
check(start > 0.04, "steep profile: over the limit to begin with")
E.moveElevation(w, 1, 200, w.elevations[1].z - 20, 400, ss4, 0.04)
check(E.steepest(w, 400, ss4) <= start + 1e-9, "steep profile: a move does not make it steeper")
local z0 = w.elevations[1].z
E.moveElevation(w, 1, 200, 15, 400, ss4, 0.04)
check(E.steepest(w, 400, ss4) <= start + 1e-9 and w.elevations[1].z ~= z0, "steep profile: a move towards easing it goes through")

check(E.removeElevation(v, 2) and #v.elevations == 1 and not E.removeElevation(v, 5), "remove a point")

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
