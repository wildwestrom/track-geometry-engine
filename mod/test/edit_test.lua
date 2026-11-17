-- Offline checks for editing the alignment (tg_edit.script.tl).
local H = dofile("test/harness.lua")
local G = H.mod("tg_geometry")
local A = H.mod("tg_alignment")
local E = H.mod("tg_edit")

local check = H.check
local function atan2(y, x) return math.atan2 and math.atan2(y, x) or math.atan(y, x) end
local function angleDiff(a, b) return math.abs(atan2(math.sin(a - b), math.cos(a - b))) end
local function endAt(x, y, deg)
	return { x = x, y = y, z = 0, dx = math.cos(math.rad(deg)), dy = math.sin(math.rad(deg)) }
end
local dp = G.DEFAULT_PARAMS
local function mobility(e, i) return E.turn(e, i).mobility end
local function length(e) local n = E.nodes(e) return n[#n].s end
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
check(E.turnCount(e) == 3 and mobility(e, 2) == "ray" and mobility(e, 3) == "free" and mobility(e, 4) == "ray",
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
check(i == 4 and E.turnCount(e) == 4 and mobility(e, 4) == "free" and e.rev > rev, "add a turn on a middle leg: free")
joinsSmoothly(e, "after adding a turn")
check(E.removePi(e, 4) and E.turnCount(e) == 3, "a free turn can be removed")

-- s-curve: one turn on each end's ray, both sliding
local sc = E.new(endAt(0, 0, 0), endAt(600, 100, 180))
check(E.turnCount(sc) == 2 and mobility(sc, 2) == "ray" and mobility(sc, 3) == "ray", "s-curve: two turns, both on rays")
check(E.movePi(sc, 3, 350, 140) and math.abs(E.polyline(sc)[3].y - 100) < 1e-9 and math.abs(E.polyline(sc)[3].x - 350) < 1e-9,
	"s-curve: the second turn slides on its end's ray")
noOverlap(sc, "s-curve after sliding")
joinsSmoothly(sc, "s-curve after sliding")

-- corner: one turn where the rays meet, fixed until a turn is added
local c = E.new(endAt(0, 0, 0), endAt(500, 400, -90))
check(E.turnCount(c) == 1 and mobility(c, 2) == "fixed", "corner: one turn, fixed")
check(not E.movePi(c, 2, 450, 50) and E.polyline(c)[2].x == 500 and E.polyline(c)[2].y == 0, "corner: the turn does not move")
check(not E.removePi(c, 2) and E.turnCount(c) == 1, "corner: the turn cannot be removed")
joinsSmoothly(c, "corner as laid")
-- adding a turn on a leg of the corner splits it in place: the track does not move
local size = E.corners(c)[2].budget
local entry2 = E.corners(c)[2].entryPoint
local before = E.nodes(c)
i = E.insertOnLeg(c, 1, entry2.x / 2, 30)
check(i == 2 and E.turnCount(c) == 2 and mobility(c, 2) == "ray" and mobility(c, 3) == "ray",
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
check(i == 3 and mobility(c2, 2) == "ray" and mobility(c2, 3) == "ray", "corner + a turn on the filled leg: both on rays")
noOverlap(c2, "corner + a turn on the filled leg")
joinsSmoothly(c2, "corner + a turn on the filled leg")
check(E.movePi(c, 2, 60, 0) and E.movePi(c, 3, 500, 100), "corner + a turn: both turns slide")
joinsSmoothly(c, "corner + a turn, slid")

-- straight: adding a turn adds three, the middle one free
local s = E.new(endAt(0, 0, 0), endAt(600, 0, 180))
i = E.insertOnLeg(s, 1, 300, 50)
check(i == 3 and E.turnCount(s) == 3 and mobility(s, 3) == "free" and math.abs(E.polyline(s)[3].x - 300) < 1e-9,
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
local before = length(s)
local p3 = E.polyline(s)[3]
check(E.budget(s, 3) == nil, "a new turn's curve sizes itself")
check(E.dragBracket(s, 3, true, p3.x + 1.5 * (entry.x - p3.x), p3.y + 1.5 * (entry.y - p3.y)), "drag a bracket away from its turn")
check(length(s) < before, "a wider curve makes the path shorter")
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

-- Ground ends: no heading of their own, so a turn next to one is held only by the other end.
local function gnd(x, y, z) return { kind = "ground", x = x, y = y, z = z or 0 } end
-- The path starts and ends on the ends, along the heading of each end that has one.
local function keepsHeadings(e, what)
	local nodes = E.nodes(e)
	local first, last = nodes[1], nodes[#nodes]
	local ok = math.abs(first.x - e.a.x) + math.abs(first.y - e.a.y) < 1e-6
		and math.abs(last.x - e.b.x) + math.abs(last.y - e.b.y) < 1e-6
	if e.a.dx ~= nil then ok = ok and angleDiff(first.heading, atan2(e.a.dy, e.a.dx)) < 1e-6 end
	if e.b.dx ~= nil then ok = ok and angleDiff(last.heading, atan2(-e.b.dy, -e.b.dx)) < 1e-6 end
	check(ok, what .. ": on both ends, along the track end's heading")
end
local tg = assert(E.new(endAt(0, 0, 0), gnd(300, 200)))
check(E.turnCount(tg) == 1 and mobility(tg, 2) == "ray", "track to ground: one turn, sliding on the track end's ray")
local leg1, leg2 = dist(E.polyline(tg)[1], E.polyline(tg)[2]), dist(E.polyline(tg)[2], E.polyline(tg)[3])
check(math.abs(E.corners(tg)[2].budget - leg1) < 1e-6 and math.abs(leg1 - leg2) < 1e-6,
	"track to ground: the curve takes all of both legs")
check(E.movePi(tg, 2, 500, 80) and math.abs(E.polyline(tg)[2].y) < 1e-9 and math.abs(E.polyline(tg)[2].x - 500) < 1e-9,
	"track to ground: the turn slides along the ray")
keepsHeadings(tg, "track to ground, turn slid")
noOverlap(tg, "track to ground, turn slid")
check(not E.removePi(tg, 2), "track to ground: the turn next to the track end cannot be removed")
local gi = E.insertOnLeg(tg, 2, 400, 150)
check(gi == 3 and mobility(tg, 2) == "ray" and mobility(tg, 3) == "free",
	"track to ground: a turn added next to the ground end is free")
check(E.movePi(tg, 3, 380, 260) and math.abs(E.polyline(tg)[3].x - 380) + math.abs(E.polyline(tg)[3].y - 260) < 1e-9,
	"track to ground: the turn next to the ground end goes anywhere")
keepsHeadings(tg, "track to ground, free turn moved")
noOverlap(tg, "track to ground, free turn moved")
check(E.removePi(tg, 3) and E.turnCount(tg) == 1, "track to ground: and can be removed")

local gt = assert(E.new(gnd(200, 400), endAt(500, 100, 90)))
check(E.turnCount(gt) == 1 and mobility(gt, 2) == "ray", "ground to track: one turn, sliding on the track end's ray")
check(E.movePi(gt, 2, 450, 300) and math.abs(E.polyline(gt)[2].x - 500) < 1e-9 and math.abs(E.polyline(gt)[2].y - 300) < 1e-9,
	"ground to track: the turn slides along the end's ray")
keepsHeadings(gt, "ground to track, turn slid")

local gg = assert(E.new(gnd(0, 0), gnd(600, 0)))
check(E.turnCount(gg) == 0, "ground to ground: no turns")
gi = E.insertOnLeg(gg, 1, 250, 30)
check(gi == 2 and E.turnCount(gg) == 1 and mobility(gg, 2) == "free" and math.abs(E.polyline(gg)[2].x - 250) < 1e-9,
	"ground to ground: adding a turn adds one, free, on the leg")
check(E.movePi(gg, 2, 300, 150) and E.removePi(gg, 2) and E.turnCount(gg) == 0, "ground to ground: it moves and is removed")

-- dragging a ground end: a handle in horizontal mode; the alignment follows it
local function endHandles(e)
	local out = {}
	for _, h in ipairs(E.handles(e)) do if h.kind == "end" then out[#out + 1] = h.i end end
	return out
end
local dg = assert(E.new(endAt(0, 0, 0), gnd(300, 200)))
local eh = endHandles(dg)
check(#eh == 1 and eh[1] == 3, "drag end: only the ground end is a handle")
local eHit = E.hit(dg, false, 302, 199, 10)
check(eHit ~= nil and eHit.kind == "end" and eHit.i == 3, "drag end: a press near the ground end hits it")
check(E.dragBracket(dg, 2, true, E.polyline(dg)[2].x - 120, 0), "drag end: set the curve's size first")
local set = E.budget(dg, 2)
local rayX, rev0 = E.polyline(dg)[2].x, dg.rev
check(E.moveEnd(dg, 3, gnd(450, 380, 7)) and dg.b.x == 450 and dg.b.y == 380 and dg.b.z == 7 and dg.b.kind == "ground"
	and dg.rev > rev0, "drag end: the ground end moves, with its height")
local pd = E.polyline(dg)
check(math.abs(pd[3].x - 450) + math.abs(pd[3].y - 380) < 1e-9 and pd[2].x == rayX and pd[2].y == 0
	and mobility(dg, 2) == "ray" and E.budget(dg, 2) == set, "drag end: the turn stays on its ray, with its curve size")
keepsHeadings(dg, "drag end")
noOverlap(dg, "drag end")
check(E.moveEnd(dg, 3, gnd(rayX + 30, 40)) and E.budget(dg, 2) == set, "drag end: close to the turn, the curve size holds")
noOverlap(dg, "drag end, close to the turn")
keepsHeadings(dg, "drag end, close to the turn")
check(not E.moveEnd(dg, 3, gnd(rayX + 2, 1)) and dg.b.x == rayX + 30, "drag end: not onto its neighbouring turn")
check(not E.moveEnd(dg, 1, gnd(-50, -50)) and dg.a.x == 0, "drag end: a track end stays")
-- dropped on track, a dragged ground end becomes that end: the path arrives along its heading
local nextNode = 100
local function trackAt(x, y, deg)
	local t = endAt(x, y, deg)
	nextNode = nextNode + 1
	t.kind, t.node, t.z, t.grade = "track", nextNode, 0, 0
	return t
end
local onto = trackAt(500, 300, -90)
check(E.moveEnd(dg, 3, onto) and dg.b == onto and E.polyline(dg)[#E.polyline(dg)].x == 500, "drop on track: the end is that track end")
joinsSmoothly(dg, "drop on track")
check(#endHandles(dg) == 1 and E.moveEnd(dg, #E.polyline(dg), gnd(450, 380, 7)) and dg.b.kind == "ground"
	and #E.polyline(dg) == 3 and E.polyline(dg)[2].x == rayX and E.budget(dg, 2) == set,
	"drop on track: until let go it moves on, and back on the ground the turns are as they were")
check(E.moveEnd(dg, 3, onto) and not E.moveEnd(dg, #E.polyline(dg), trackAt(30, 0, 0)) and dg.b == onto,
	"drop on track: not onto track too close to the other end")
E.dropEnd(dg)
check(#endHandles(dg) == 0 and not E.moveEnd(dg, #E.polyline(dg), gnd(450, 380)) and dg.b == onto,
	"drop on track: let go, it is fixed like any other track end")
local dgg = assert(E.new(gnd(0, 0), gnd(600, 0)))
check(#endHandles(dgg) == 2 and E.moveEnd(dgg, 1, gnd(-100, 200)) and dgg.a.x == -100 and E.polyline(dgg)[1].y == 200,
	"drag end: ground to ground, both ends move")
check(not E.moveEnd(dgg, 1, gnd(580, 10)) and dgg.a.x == -100, "drag end: not onto the other end")
local fi = E.insertOnLeg(dgg, 1, 250, 100)
check(E.movePi(dgg, fi, 250, 300), "drag end: bend the free turn")
check(E.dragBracket(dgg, fi, true, E.polyline(dgg)[fi].x - 60, E.polyline(dgg)[fi].y), "drag end: size a free turn's curve")
local fset = E.budget(dgg, fi)
check(E.moveEnd(dgg, 3, gnd(700, 300)) and E.budget(dgg, fi) == fset, "drag end: a free turn's curve size holds")
noOverlap(dgg, "drag end, free turn")
-- a free turn on its leg (dgg: ground to ground, one sized turn at (250, 300)) goes onto the end's ray
local up = trackAt(700, 300, 180) -- (a track coming from +x: the new track leaves it going -x)
local rev1 = dgg.rev
check(E.moveEnd(dgg, 3, up) and E.turnCount(dgg) == 1 and mobility(dgg, 2) == "ray" and E.budget(dgg, fi) == fset
	and math.abs(E.polyline(dgg)[2].x - 250) < 1e-9 and math.abs(E.polyline(dgg)[2].y - 300) < 1e-9 and dgg.rev > rev1,
	"drop on track: the turn on its leg slides on that end's ray now, with its curve size")
keepsHeadings(dgg, "drop on track, a free turn")
check(E.moveEnd(dgg, 3, trackAt(700, 500, 180)) and math.abs(E.polyline(dgg)[2].x - 250) < 1e-9 and math.abs(E.polyline(dgg)[2].y - 500) < 1e-9,
	"drop on track: the turn goes to the ray where it is nearest")
keepsHeadings(dgg, "drop on track, the turn moved onto the ray")
check(E.moveEnd(dgg, 3, trackAt(200, 500, 180)) and math.abs(E.polyline(dgg)[2].x - (200 - 20)) < 1e-9,
	"drop on track: a turn behind the end goes MIN_LEG out on the ray")
E.dropEnd(dgg)
-- no turn on its leg: one is added, as the one-turn layout
local bare = assert(E.new(gnd(0, 0), gnd(600, 0)))
check(E.moveEnd(bare, 2, trackAt(600, 200, 180)) and E.turnCount(bare) == 1 and mobility(bare, 2) == "ray"
	and math.abs(E.polyline(bare)[2].y - 200) < 1e-9 and #endHandles(bare) == 2,
	"drop on track: no turn on its leg: one is added on the end's ray")
keepsHeadings(bare, "drop on track, a turn added")
check(E.moveEnd(bare, 3, gnd(600, 100)) and E.turnCount(bare) == 0, "drop on track: back on the ground, the added turn is gone")
-- a node with track through it: it heads along the track, toward the other end
local through = { kind = "node", node = 5, x = 600, y = 200, z = 3,
	dirs = { { dx = 1, dy = 0, grade = 0.01 }, { dx = -1, dy = 0, grade = -0.01 } } }
check(E.moveEnd(bare, 2, through) and bare.b.kind == "node" and bare.b.dx == -1 and bare.b.grade == -0.01 and bare.b.z == 3,
	"drop on a node: it heads as the second click would, toward the other end")
keepsHeadings(bare, "drop on a node")
-- a turn beyond the one on its leg stays where it is
local two = assert(E.new(gnd(0, 0), gnd(900, 0)))
E.insertOnLeg(two, 1, 300, 0); E.insertOnLeg(two, 2, 600, 0)
check(E.movePi(two, 2, 300, 100) and E.movePi(two, 3, 600, -100) and E.moveEnd(two, 4, trackAt(900, 50, 180))
	and math.abs(E.polyline(two)[3].x - 600) < 1e-9 and math.abs(E.polyline(two)[3].y - 50) < 1e-9 and E.polyline(two)[2].y == 100 and mobility(two, 2) == "free",
	"drop on track: only the turn on its leg moves")
check(not E.moveEnd(two, 4, trackAt(325, 100, 180)) and two.b.y == 50, "drop on track: not where its turn would land on the next one")
keepsHeadings(two, "drop on track, two turns")
local eh2 = E.hit(dg, false, E.polyline(dg)[2].x, E.polyline(dg)[2].y, 10)
check(eh2 ~= nil and eh2.kind == "pi", "drag end: a press on the turn next to a ground end grabs the turn")

-- a ground end's height is where the profile starts (or ends)
local gz = assert(E.new(gnd(0, 0, 12), { kind = "track", x = 600, y = 0, dx = -1, dy = 0, z = 2, grade = 0 }))
local gzs = E.points(gz)
local gp = E.profile(gz)
check(gzs[1].z == 12 and gzs[2].z == 2 and gp ~= nil and math.abs(H.mod("tg_profile")
	.heightAt(gp, 0) - 12) < 1e-9, "a ground end: the profile starts at its height")

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
local Pv = H.mod("tg_profile")
local moved = 0
for s = 0, 1000, 10 do moved = math.max(moved, math.abs(Pv.heightAt(before, s) - Pv.heightAt(after, s))) end
check(i == 2 and math.abs(Pv.heightAt(after, 400) - Pv.heightAt(before, 400)) < 1e-9 and moved < 0.5,
	string.format("an added elevation point sits on the profile; the rest moves %.2f m at most", moved))
check(E.insertElevation(v, 700) == 3 and #E.points(v) == 4 and E.points(v)[2].s < E.points(v)[3].s, "points stay in order")
check(not E.points(v)[2].tooClose and not E.points(v)[3].tooClose and E.spacingProblem(v) == nil, "points 20 m clear are not too close")

local rev, nodes0 = v.rev, E.nodes(v)
check(E.movePoint(v, 2, 450, E.points(v)[2].z + 1, 0.04) and v.rev > rev
	and math.abs(E.points(v)[2].s - 450) < 1e-9, "a point moves along the path and up")
check(E.nodes(v) == nodes0, "a vertical change keeps the sampled path")
E.movePoint(v, 2, 400, E.points(v)[2].z + 100, 0.04)
local steep = E.steepest(v)
check(steep <= 0.04 + 1e-9 and steep > 0.039, "raising a point stops at the grade limit: " .. steep * 1000 .. " permille")

-- The 20 m spacing does not stop a drag: a point too close is red, left out of the profile, and
-- blocks the build.
local P = H.mod("tg_profile")
local function zs(e)
	local p = assert(E.profile(e))
	local out = {}
	for s = 0, length(e), 10 do out[#out + 1] = P.heightAt(p, s) end
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
E.movePoint(sp, 2, 300, 104, 1.0)
E.movePoint(sp, 3, 600, 108, 1.0)
local without2 = assert(E.new(vend(0, 0, 0, 100, 0), vend(1000, 0, 180, 110, 0)))
E.insertElevation(without2, 300)
E.movePoint(without2, 2, 300, 104, 1.0)
local ok2, j = E.movePoint(sp, 3, 312, 108, 1.0)
check(ok2 and j == 3 and math.abs(E.points(sp)[3].s - 312) < 1e-9, "a point dragged within MIN_SPAN of its neighbour is not stopped")
local q = E.points(sp)
check(q[3].tooClose and not q[2].tooClose and math.abs(q[3].gap - 12) < 1e-9 and q[3].near == "neighbour",
	"the dragged point is the one too close, and how close: " .. tostring(q[3].gap))
local why = E.spacingProblem(sp)
check(why == "elevation point 2 is too close to its neighbour (12 m, needs 20 m)", "why: " .. tostring(why))
check(E.profile(sp) ~= nil and sameZ(zs(sp), zs(without2)), "the profile leaves out the point too close")
-- dragged past its neighbour: the points reorder, and the profile follows the new order
ok2, j = E.movePoint(sp, 3, 250, 108, 1.0)
q = E.points(sp)
check(ok2 and j == 2 and math.abs(q[2].s - 250) < 1e-9 and q[2].z == 108 and q[3].z == 104 and q[2].s < q[3].s,
	"a point dragged past its neighbour comes before it")
check(not q[2].tooClose and not q[3].tooClose and E.spacingProblem(sp) == nil, "dragged clear: no point too close")
local swapped = assert(E.new(vend(0, 0, 0, 100, 0), vend(1000, 0, 180, 110, 0)))
E.insertElevation(swapped, 250); E.insertElevation(swapped, 300)
E.movePoint(swapped, 2, 250, 108, 1.0); E.movePoint(swapped, 3, 300, 104, 1.0)
check(sameZ(zs(sp), zs(swapped)), "the profile follows the new order")
-- near an end
ok2, j = E.movePoint(sp, 2, 8, 108, 1.0)
q = E.points(sp)
check(ok2 and q[2].tooClose and q[2].near == "end" and math.abs(q[2].gap - 8) < 1e-9, "a point dragged within MIN_SPAN of an end is too close")
check(E.spacingProblem(sp) == "elevation point 1 is too close to the end (8 m, needs 20 m)", "why: " .. tostring(E.spacingProblem(sp)))
ok2 = E.movePoint(sp, 2, -50, 108, 1.0)
check(ok2 and E.points(sp)[2].s == 0, "a point stops at the end of the path")
-- a point added within MIN_SPAN of another is added, too close, rather than refused
local k = E.insertElevation(sp, 310)
check(k == 4 and E.points(sp)[4].tooClose and not E.points(sp)[3].tooClose,
	"a point added within MIN_SPAN of another is added too close (the earlier one stays)")
check(E.removeElevation(sp, 4) and E.removeElevation(sp, 2) and E.spacingProblem(sp) == nil, "removing the points too close clears it")

-- the grade limit still stops a drag, also once the point leaves the too-close range
local gl = assert(E.new(vend(0, 0, 0, 100, 0), vend(1000, 0, 180, 100, 0)))
E.insertElevation(gl, 500)
E.insertElevation(gl, 510) -- too close to the first
ok2 = E.movePoint(gl, 3, 510, 160, 0.04) -- too close, so no grade check: its height goes through
check(ok2 and E.points(gl)[3].z == 160 and E.points(gl)[3].tooClose, "a point too close changes height freely (it is not in the profile)")
ok2, j = E.movePoint(gl, 3, 700, 160, 0.04)
local g2 = E.points(gl)[j]
check(ok2 and E.steepest(gl) <= 0.04 + 1e-9, string.format("dragged clear, the grade limit stops it (%.1f permille)", E.steepest(gl) * 1000))
check(g2.tooClose or g2.s < 700, "it does not reach where the profile would be too steep: " .. string.format("%.1f m", g2.s))
-- a point too close, slid clear and raised at once: once clear, the grade limit stops it
local gc = assert(E.new(vend(0, 0, 0, 100, 0), vend(1000, 0, 180, 100, 0)))
E.insertElevation(gc, 500)
E.insertElevation(gc, 510)
-- (at 20 ‰ it cannot clear at all: a 20 m span peaking at the point is 1.5 × its chord grade)
ok2, j = E.movePoint(gc, 3, 700, 106, 0.03)
local g3 = E.points(gc)[j]
check(ok2 and not g3.tooClose and g3.s > 520 and g3.s < 700 and E.steepest(gc) <= 0.03 + 1e-9,
	string.format("cleared, the grade limit stops it (%.1f m, %.1f m high, %.1f permille)", g3.s, g3.z, E.steepest(gc) * 1000))
local gr = assert(E.new(vend(0, 0, 0, 100, 0), vend(1000, 0, 180, 100, 0)))
E.insertElevation(gr, 500); E.insertElevation(gr, 519.6)
check(E.spacingProblem(gr) == "elevation point 2 is too close to its neighbour (19 m, needs 20 m)", "a gap is rounded down: " .. tostring(E.spacingProblem(gr)))

-- what is under the mouse while editing the vertical alignment
local pt1 = E.points(v)[2]
local vh = E.hit(v, true, pt1.x + 2, pt1.y + 1, 5)
check(vh ~= nil and vh.kind == "point" and vh.i == 2 and vh.s == pt1.s, "an elevation point within the radius is hit")
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
check(ph ~= nil and ph.kind == "point" and ph.i == 2, "an elevation point up at its height is hit along the ray")
local past = E.hit(hi, true, 800, 100, 5, { ex = 800, ey = -300, ez = 400, gx = 800, gy = 100, gz = 0 })
check(past ~= nil and past.kind == "track" and math.abs(past.s - 800) < 1, "a ray 300 m past the point hits the track there, not the point")
local low = E.hit(v, true, 200, 3, 5, { ex = 200, ey = -300, ez = 400, gx = 200, gy = 3, gz = 100 })
check(low ~= nil and low.kind == "track" and math.abs(low.s - 200) < 1, "a track on the ground is still hit at the ground point")

-- the elevation points follow the path when a turn moves; the path is sampled again
local f = E.new(vend(0, 0, 0, 100, 0), vend(1000, 0, 180, 110, 0))
E.insertOnLeg(f, 1, 500, 0)
E.insertElevation(f, 300)
local frac0, hrev0, fn0 = E.points(f)[2].s / length(f), f.hrev, E.nodes(f)
E.movePi(f, 3, 500, 150)
local fp = E.points(f)[2]
local ax, ay = A.pointAt(E.nodes(f), fp.s)
check(f.hrev > hrev0 and E.nodes(f) ~= fn0 and length(f) > 1000 + 1, "moving a turn samples the path again")
check(math.abs(fp.s / length(f) - frac0) < 1e-9 and math.abs(ax - fp.x) + math.abs(ay - fp.y) < 1e-6,
	"an elevation point keeps its place along the path and sits on it after a turn moves")

-- a profile that starts over the limit: moves may not make it steeper, but may ease it (the
-- point at 100 m sits at 4.7 m; raising it towards 7 m eases the climb after it)
local w = assert(E.new(vend(0, 0, 0, 0, 0), vend(400, 0, 180, 30, 0)))
E.insertElevation(w, 100)
local start = E.steepest(w)
check(start > 0.04, "steep profile: over the limit to begin with")
E.movePoint(w, 2, 100, E.points(w)[2].z - 20, 0.04)
check(E.steepest(w) <= start + 1e-9, "steep profile: a move does not make it steeper")
local z0 = E.points(w)[2].z
E.movePoint(w, 2, 100, 7, 0.04)
check(E.steepest(w) <= start + 1e-9 and E.points(w)[2].z ~= z0, "steep profile: a move towards easing it goes through")

-- a height set directly goes past the limit; the profile is then too steep and says where
local hs = assert(E.new(vend(0, 0, 0, 100, 0), vend(1000, 0, 180, 100, 0)))
E.insertElevation(hs, 500)
check(E.gradeProblem(hs, 0.04) == nil, "a level profile is not too steep")
local rev1 = hs.rev
check(E.setHeight(hs, 2, 160) and E.points(hs)[2].z == 160 and E.points(hs)[2].s == 500 and hs.rev > rev1,
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
check(not E.setHeight(hs, 3, 100), "no such point: nothing set")
-- a drag on it still does not make it steeper
local st = E.steepest(hs)
E.movePoint(hs, 2, 500, 200, 0.04)
check(E.steepest(hs) <= st + 1e-9 and E.points(hs)[2].z == 160, "a drag on a profile too steep does not make it steeper")
check(E.setHeight(hs, 2, 100) and E.gradeProblem(hs, 0.04) == nil, "set back level: no longer too steep")
-- a point too close is not in the profile, so its height never makes it too steep
E.insertElevation(hs, 510)
check(E.points(hs)[3].tooClose and E.setHeight(hs, 3, 300) and E.gradeProblem(hs, 0.04) == nil,
	"a point too close set very high does not make the profile too steep")

check(E.removeElevation(v, 3) and #E.points(v) == 3 and not E.removeElevation(v, 6), "remove a point")

-- a ground end's height is edited like an elevation point's (it cannot slide); a track end's stays
local ge = assert(E.new(vend(0, 0, 0, 100, 0), gnd(1000, 0, 100)))
local last = #E.points(ge)
check(not E.points(ge)[1].liftable and E.points(ge)[last].liftable and not E.points(ge)[last].slides,
	"ground end: its height can be set, a track end's cannot; it does not slide")
local geh = E.hit(ge, true, 1002, 1, 5)
check(geh ~= nil and geh.kind == "end" and geh.i == last and geh.s == length(ge) and geh.x == 1000,
	"ground end: hit in vertical mode")
check(E.hit(ge, true, 2, 1, 5).kind == "track", "track end: not hit in vertical mode (the track there is)")
local geRay = E.hit(ge, true, 1000, 100, 5, { ex = 1000, ey = -300, ez = 400, gx = 1000, gy = 100, gz = 0 })
check(E.hit(ge, true, 1000, 100, 5) == nil and geRay ~= nil and geRay.kind == "end",
	"ground end at 100 m: hit up at its height along the view ray, 100 m off on the ground")
E.insertElevation(ge, 995) -- too close to the end: the end still wins at the end
local near = E.hit(ge, true, 1000, 0, 5)
check(near ~= nil and near.kind == "end", "ground end: hit over a point too close to it")
E.removeElevation(ge, 2)
local revG = ge.rev
check(E.setHeight(ge, last, 160) and select(2, E.ends(ge)).z == 160 and ge.b.kind == "ground" and ge.rev > revG
	and E.points(ge)[last].z == 160, "ground end: a height set directly applies as asked")
check(math.abs(P.heightAt(assert(E.profile(ge)), length(ge)) - 160) < 1e-9, "ground end: the profile ends at its height")
local why = E.gradeProblem(ge, 0.04)
check(why ~= nil and E.steepest(ge) > 0.04, "ground end: too-steep checks include it: " .. tostring(why))
check(not E.setHeight(ge, 1, 120) and ge.a.z == 100, "track end: its height stays")
check(E.setHeight(ge, last, 100) and E.gradeProblem(ge, 0.04) == nil, "ground end: set back, no longer too steep")
check(E.movePoint(ge, last, 0, 200, 0.04) and ge.b.z > 100 and ge.b.z < 200 and ge.b.x == 1000 and E.points(ge)[last].s == length(ge)
	and E.steepest(ge) <= 0.04 + 1e-9 and E.steepest(ge) > 0.039,
	string.format("ground end: a height drag stops at the limit (%.1f m, %.1f permille)", ge.b.z, E.steepest(ge) * 1000))
check(not E.movePoint(ge, 1, 0, 200, 0.04), "track end: no height drag")
-- the free grade at a ground end: no overshoot in the end span
local gf = assert(E.new(gnd(0, 0, 0), gnd(1000, 0, 0)))
E.insertElevation(gf, 100)
E.setHeight(gf, 2, 1)
E.insertElevation(gf, 400)
E.setHeight(gf, 3, 20)
local gpf = assert(E.profile(gf))
local dips = false
for s = 0, 100, 1 do if P.heightAt(gpf, s) < -1e-9 or P.heightAt(gpf, s) > 1 + 1e-9 then dips = true end end
check(not dips, "ground end: no overshoot in its span")

-- brackets that show their curve: each opens towards its own curve, and is picked by its shape
-- (bk: a straight bent at turn 3, a turn added on the leg after it, curve 3 as wide as it goes:
-- curves 2 and 3 meet on their leg, and curve 3 ends on turn 4, where curve 5 starts)
local bk = E.new(endAt(0, 0, 0), endAt(600, 0, 180))
E.insertOnLeg(bk, 1, 300, 0)
E.movePi(bk, 3, 300, 120)
E.insertOnLeg(bk, 3, 375, 60)
local bl, bp = E.corners(bk)[3], E.polyline(bk)
E.dragBracket(bk, 3, false, bp[3].x + 1e5 * bl.geometry.uOut.x, bp[3].y + 1e5 * bl.geometry.uOut.y)
local function handle(e, kind, i)
	for _, h in ipairs(E.handles(e)) do if h.kind == kind and h.i == i then return h end end
end
local function is(h, kind, i) return h ~= nil and h.kind == kind and h.i == i end
local exit2, entry3, exit3, entry5 = handle(bk, "exit", 2), handle(bk, "entry", 3), handle(bk, "exit", 3), handle(bk, "entry", 5)
check(dist(exit2, entry3) < 1e-9 and dist(exit3, bp[4]) < 1e-9 and dist(entry5, bp[4]) < 1e-9,
	"brackets: two curves meet on their leg, and two more on the turn between them")
-- (the leg from turn 2 (150, 0) to turn 3 (300, 120) runs along (150, 120))
local function unit(dx, dy) return dx / math.sqrt(dx * dx + dy * dy), dy / math.sqrt(dx * dx + dy * dy) end
local lx, ly = unit(150, 120)
check(exit2.ux ~= nil and math.abs(exit2.ux + lx) + math.abs(exit2.uy + ly) < 1e-9
	and math.abs(entry3.ux - lx) + math.abs(entry3.uy - ly) < 1e-9,
	"brackets: each opens along its leg, towards its own turn")
local R = 5
check(is(hitAt(bk, exit2.x - lx * 3, exit2.y - ly * 3, R), "exit", 2), "brackets that meet: the mouse on the first curve's side picks its end")
check(is(hitAt(bk, exit2.x + lx * 3, exit2.y + ly * 3, R), "entry", 3), "brackets that meet: the mouse on the next curve's side picks its start")
-- (the leg from turn 3 (300, 120) to turn 4 (375, 60) runs along (75, -60): across it is (60, 75))
local ax, ay = unit(60, 75)
check(is(hitAt(bk, bp[4].x + ax * 2, bp[4].y + ay * 2, R), "pi", 4), "a bracket on a turn: the circle in the middle picks the turn")
-- (at a tip: 1.4 R across the leg, 0.3 R along it (ay, -ax) towards that bracket's curve)
local function tip(side, towards)
	return hitAt(bk, bp[4].x + (side * 1.4 * ax + towards * 0.3 * ay) * R, bp[4].y + (side * 1.4 * ay - towards * 0.3 * ax) * R, R)
end
check(is(tip(1, -1), "exit", 3) and is(tip(-1, -1), "exit", 3) and is(tip(1, 1), "entry", 5) and is(tip(-1, 1), "entry", 5),
	"brackets on a turn: past the circle, each one's tips pick it")
check(hitAt(bk, bp[4].x + ax * 3 * R, bp[4].y + ay * 3 * R, R) == nil, "a bracket on a turn: nothing past its tips")
-- (bg: track to ground, the end curve fills the leg up to the ground end at (300, 200); the leg
-- from turn 2 (216.67, 0) runs along (250 / 3, 200): across it is (-200, 250 / 3))
local bg = assert(E.new(endAt(0, 0, 0), gnd(300, 200)))
local gexit = handle(bg, "exit", 2)
check(dist(gexit, gnd(300, 200)) < 1e-9, "a bracket on a ground end: the end curve ends on the end")
local gx, gy = unit(-200, 250 / 3)
check(is(hitAt(bg, 300 + gx * 2, 200 + gy * 2, R), "end", 3), "a bracket on a ground end: the circle in the middle picks the end")
check(is(hitAt(bg, 300 + gx * 1.4 * R, 200 + gy * 1.4 * R, R), "exit", 2)
	and is(hitAt(bg, 300 - gx * 1.4 * R, 200 - gy * 1.4 * R, R), "exit", 2),
	"a bracket on a ground end: past the circle, either tip picks the bracket")

H.done()
