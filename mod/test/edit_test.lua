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
check(gzs[1].z == 12 and gzs[#gzs].z == 2 and gp ~= nil and math.abs(H.mod("tg_profile")
	.elevationAtClamped(gp, 0) - 12) < 1e-9, "a ground end: the profile starts at its height")

-- The vertical profile: elevation points between the ends.
local function vend(x, y, deg, z, grade)
	local e = endAt(x, y, deg)
	e.z, e.grade = z, grade
	return e
end
local v = assert(E.new(gnd(0, 0, 100), gnd(1000, 0, 110)))
local before = E.profile(v)
local i = E.insertElevation(v, 400)
local after = E.profile(v)
-- inserting an elevation point on a straight grade adds a collinear PVI, leaving the profile unchanged
local Pv = H.mod("tg_profile")
local moved = 0
for s = 0, 1000, 10 do moved = math.max(moved, math.abs(Pv.elevationAtClamped(before, s) - Pv.elevationAtClamped(after, s))) end
check(i == 2 and math.abs(Pv.elevationAtClamped(after, 400) - Pv.elevationAtClamped(before, 400)) < 1e-9 and moved < 1e-9,
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
	for s = 0, length(e), 10 do out[#out + 1] = P.elevationAtClamped(p, s) end
	return out
end
local function sameZ(a, b)
	if #a ~= #b then return false end
	for k = 1, #a do if math.abs(a[k] - b[k]) > 1e-9 then return false end end
	return true
end
local sp = assert(E.new(gnd(0, 0, 100), gnd(1000, 0, 110)))
E.insertElevation(sp, 300)
E.insertElevation(sp, 600)
E.movePoint(sp, 2, 300, 104, 1.0)
E.movePoint(sp, 3, 600, 108, 1.0)
local without2 = assert(E.new(gnd(0, 0, 100), gnd(1000, 0, 110)))
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
local swapped = assert(E.new(gnd(0, 0, 100), gnd(1000, 0, 110)))
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
local gl = assert(E.new(gnd(0, 0, 100), gnd(1000, 0, 100)))
E.insertElevation(gl, 500)
E.insertElevation(gl, 510) -- too close to the first
ok2 = E.movePoint(gl, 3, 510, 160, 0.04) -- too close, so no grade check: its height goes through
check(ok2 and E.points(gl)[3].z == 160 and E.points(gl)[3].tooClose, "a point too close changes height freely (it is not in the profile)")
ok2, j = E.movePoint(gl, 3, 700, 160, 0.04)
local g2 = E.points(gl)[j]
check(ok2 and E.steepest(gl) <= 0.04 + 1e-9, string.format("dragged clear, the grade limit stops it (%.1f permille)", E.steepest(gl) * 1000))
check(g2.tooClose or g2.s < 700, "it does not reach where the profile would be too steep: " .. string.format("%.1f m", g2.s))
-- a point too close, slid clear and raised at once: once clear, the grade limit stops it
local gc = assert(E.new(gnd(0, 0, 100), gnd(1000, 0, 100)))
E.insertElevation(gc, 500)
E.insertElevation(gc, 510)
ok2, j = E.movePoint(gc, 3, 700, 109, 0.03)
local g3 = E.points(gc)[j]
check(ok2 and not g3.tooClose and g3.s > 520 and g3.s < 700 and E.steepest(gc) <= 0.03 + 1e-9,
	string.format("cleared, the grade limit stops it (%.1f m, %.1f m high, %.1f permille)", g3.s, g3.z, E.steepest(gc) * 1000))
local gr = assert(E.new(gnd(0, 0, 100), gnd(1000, 0, 100)))
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
local hi = assert(E.new(gnd(0, 0, 100), gnd(1000, 0, 100)))
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

-- horizontal, a raised corner (its track 100 m over the ground at 0): its gizmos are drawn up at
-- the track's height, so they are picked along the view ray there
local hc = assert(E.new(vend(0, 0, 0, 100, 0), vend(500, 400, -90, 100, 0)))
-- a ray down at 45 degrees through (px, py, 100) to the ground at (px, py + 100, 0), the mouse there
local function rayAt(px, py) return { ex = px, ey = py - 300, ez = 400, gx = px, gy = py + 100, gz = 0 } end
local function hitAlong(e, px, py, r)
	local ry = rayAt(px, py)
	return E.hit(e, false, ry.gx, ry.gy, r, ry)
end
local hcTurn = E.turn(hc, 2)
check(not same(E.hit(hc, false, hcTurn.x, hcTurn.y + 100, 5), hcTurn) and same(hitAlong(hc, hcTurn.x, hcTurn.y, 5), hcTurn),
	"a raised turn: not at the ground point, but along the ray up at its height (before the legs there)")
check(same(E.hit(hc, false, hcTurn.x + 1, hcTurn.y, 5), hcTurn), "with no ray, a turn is picked on the ground under it, as before")

local hcEntry = nil
for _, h in ipairs(E.handles(hc)) do if h.kind == "entry" then hcEntry = h end end
check(same(hitAlong(hc, hcEntry.x + 2 * hcEntry.ux, hcEntry.y + 2 * hcEntry.uy, 5), hcEntry),
	"a raised bracket is picked along the ray, up at its height")
local hq = E.polyline(hc)
local hcLeg = hitAlong(hc, (hq[1].x + hcEntry.x) / 2, 2, 5)
check(hcLeg ~= nil and hcLeg.kind == "leg" and hcLeg.i == 1 and hcLeg.s == nil, "a raised leg is picked along the ray, up at its height")
local hnd, hoff = offLegs(hc)
local hct = hitAlong(hc, hnd.x, hnd.y, hoff * 0.8)
check(hoff > 5 and hct ~= nil and hct.kind == "leg" and math.abs(hct.s - hnd.s) < 1,
	"the raised track where it leaves the legs is picked along the ray: " .. tostring(hct and hct.s))
check(hitAlong(hc, 250, -200, 5) == nil, "a ray far from the raised edit picks nothing")

-- each handle's radius is measured from the eye to it (GRAB of that, 3 to 50 m): far handles
-- stay a clickable size on the screen; r is only the radius with no ray (no eye yet)
do
local fl = assert(E.new(vend(0, 0, 0, 0, 0), vend(1000, 0, 180, 0, 0))) -- (flat, on the ground at 0)
check(E.insertOnLeg(fl, 1, 400, 0) == 3 and E.insertOnLeg(fl, 3, 430, 0) == 4 and E.turn(fl, 4).x == 430,
	"flat: turns added at 400 m and 430 m")
-- the mouse at (mx, my) on the ground, the eye dist m from it (back along -y and up)
local function eyeRay(mx, my, dist)
	return { ex = mx, ey = my - dist * 0.8, ez = dist * 0.6, gx = mx, gy = my, gz = 0 }
end
check(hitAt(fl, 400, -20, 5) == nil and same(E.hit(fl, false, 400, -20, 5, eyeRay(400, -20, 1500)), E.turn(fl, 3)),
	"a turn 1.5 km from the eye is hit 20 m off, which the fallback radius misses")
check(same(E.hit(fl, false, 412, 5, 5, eyeRay(412, 5, 1500)), E.turn(fl, 3))
	and same(E.hit(fl, false, 420, 5, 5, eyeRay(420, 5, 1500)), E.turn(fl, 4)),
	"two turns in reach: the nearer one wins")
check(E.hit(fl, false, 400, 8, 50, eyeRay(400, 8, 100)) == nil, "near the eye, the radius is its floor: 3 m")
check(E.hit(fl, false, 400, 100, 5, eyeRay(400, 100, 6000)) == nil, "far from the eye, the radius is its ceiling: 50 m")
local fc = assert(E.new(vend(0, 0, 0, 0, 0), vend(500, 400, -90, 0, 0)))
local fcEntry = nil
for _, h in ipairs(E.handles(fc)) do if h.kind == "entry" then fcEntry = h end end
local bx, by = fcEntry.x - fcEntry.uy * 60, fcEntry.y + fcEntry.ux * 60 -- (60 m along its bar, off the leg)
check(hitAt(fc, bx, by, 5) == nil and same(E.hit(fc, false, bx, by, 5, eyeRay(bx, by, 3000)), fcEntry),
	"a bracket's bar scales with its own radius: 60 m out along it, 3 km from the eye")
local fv = assert(E.new(gnd(0, 0, 0), gnd(1000, 0, 0)))
E.insertElevation(fv, 500)
local fvh = E.hit(fv, true, 500, 20, 5, eyeRay(500, 20, 1500))
check(E.hit(fv, true, 500, 20, 5) == nil and fvh ~= nil and fvh.kind == "point" and fvh.i == 2,
	"vertical: an elevation point 1.5 km from the eye is hit 20 m off")
local fvt = E.hit(fv, true, 800, 20, 5, eyeRay(800, 20, 1500))
check(E.hit(fv, true, 800, 20, 5) == nil and fvt ~= nil and fvt.kind == "track" and math.abs(fvt.s - 800) < 1,
	"vertical: the track 1.5 km from the eye is hit 20 m off")
check(E.hit(fv, true, 800, 8, 50, eyeRay(800, 8, 100)) == nil, "vertical: near the eye, the floor: 3 m")
end

-- the elevation points follow the path when a turn moves; the path is sampled again
local f = E.new(vend(0, 0, 0, 100, 0), vend(1000, 0, 180, 110, 0))
E.insertOnLeg(f, 1, 500, 0)
E.insertElevation(f, 300)
local frac0, hrev0, fn0 = E.points(f)[3].s / length(f), f.hrev, E.nodes(f)
E.movePi(f, 3, 500, 150)
local fp = E.points(f)[3]
local ax, ay = A.pointAt(E.nodes(f), fp.s)
check(f.hrev > hrev0 and E.nodes(f) ~= fn0 and length(f) > 1000 + 1, "moving a turn samples the path again")
check(math.abs(fp.s / length(f) - frac0) < 1e-9 and math.abs(ax - fp.x) + math.abs(ay - fp.y) < 1e-6,
	"an elevation point keeps its place along the path and sits on it after a turn moves")

-- a profile that starts over the limit: moves may not make it steeper, but may ease it
local w = assert(E.new(gnd(0, 0, 0), gnd(400, 0, 30)))
E.insertElevation(w, 100)
E.setHeight(w, 2, 2) -- pushes the second leg past the straight chord grade
local start = E.steepest(w)
check(start > 0.04, "steep profile: over the limit to begin with")
E.movePoint(w, 2, 100, E.points(w)[2].z - 20, 0.04)
check(E.steepest(w) <= start + 1e-9, "steep profile: a move does not make it steeper")
local z0 = E.points(w)[2].z
E.movePoint(w, 2, 100, 7.5, 0.04)
check(E.steepest(w) <= start + 1e-9 and E.points(w)[2].z ~= z0, "steep profile: a move towards easing it goes through")

-- a height set directly goes past the limit; the profile is then too steep and says where
local hs = assert(E.new(gnd(0, 0, 100), gnd(1000, 0, 100)))
E.insertElevation(hs, 500)
check(E.gradeProblem(hs, 0.04) == nil, "a level profile is not too steep")
local rev1 = hs.rev
check(E.setHeight(hs, 2, 160) and E.points(hs)[2].z == 160 and E.points(hs)[2].s == 500 and hs.rev > rev1,
	"a height set directly applies as asked, past the limit")
check(E.steepest(hs) > 0.04, string.format("the profile is past the limit (%.1f permille)", E.steepest(hs) * 1000))
local gp, gs = E.gradeProblem(hs, 0.04)
local worst, worstAt = 0, 0
for _, nd in ipairs(E.nodes(hs)) do
	local g = math.abs(P.gradeAtClamped(assert(E.profile(hs)), nd.s))
	if g > worst then worst, worstAt = g, nd.s end
end
check(gs == worstAt and gp == string.format("too steep: %d ‰ at %.0f m (limit 40 ‰)", math.ceil(worst * 1000), worstAt),
	"why: " .. tostring(gp))
check(not E.setHeight(hs, 4, 100), "no such point: nothing set")
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
E.removeElevation(ge, 3)
local revG = ge.rev
check(E.setHeight(ge, last, 160) and select(2, E.ends(ge)).z == 160 and ge.b.kind == "ground" and ge.rev > revG
	and E.points(ge)[last].z == 160, "ground end: a height set directly applies as asked")
check(math.abs(P.elevationAtClamped(assert(E.profile(ge)), length(ge)) - 160) < 1e-9, "ground end: the profile ends at its height")
local why = E.gradeProblem(ge, 0.04)
check(why ~= nil and E.steepest(ge) > 0.04, "ground end: too-steep checks include it: " .. tostring(why))
check(not E.setHeight(ge, 1, 120) and ge.a.z == 100, "track end: its height stays")
check(E.setHeight(ge, last, 100) and E.gradeProblem(ge, 0.04) == nil, "ground end: set back, no longer too steep")
check(E.movePoint(ge, last, 0, 200, 0.04) and ge.b.z > 100 and ge.b.z < 200 and ge.b.x == 1000 and E.points(ge)[last].s == length(ge)
	and E.steepest(ge) <= 0.04 + 1e-9 and E.steepest(ge) > 0.039,
	string.format("ground end: a height drag stops at the limit (%.1f m, %.1f permille)", ge.b.z, E.steepest(ge) * 1000))
check(not E.movePoint(ge, 1, 0, 200, 0.04), "track end: no height drag")
-- the free grade at a ground end: monotone in the end span (never dips below start)
local gf = assert(E.new(gnd(0, 0, 0), gnd(1000, 0, 0)))
E.insertElevation(gf, 100)
E.setHeight(gf, 2, 1)
E.insertElevation(gf, 400)
E.setHeight(gf, 3, 20)
local gpf = assert(E.profile(gf))
local dips = false
for s = 0, 100, 1 do if P.elevationAtClamped(gpf, s) < -1e-9 or P.gradeAtClamped(gpf, s) < -1e-9 then dips = true end end
check(not dips, "ground end: no dip below start in its span")

-- designSpeed policy: defaults to maxDesignSpeed, uses track type top speed when set, updates curve radius
do
	local ds = assert(E.new(gnd(0, 0, 0), gnd(1000, 0, 0)))
	check(ds.policy.maxVerticalAccel == 0.3 and ds.policy.minVerticalRadius == 500
		and ds.policy.designSpeed == G.DEFAULT_PARAMS.maxDesignSpeed,
		"policy: defaults to a_v=0.3, minR=500, designSpeed=maxDesignSpeed")
	E.insertElevation(ds, 500)
	E.setHeight(ds, 2, 10)
	local pFast = assert(E.profile(ds))
	local rev0 = ds.rev
	check(E.setDesignSpeed(ds, 25) and ds.rev > rev0 and ds.policy.designSpeed == 25,
		"policy: setDesignSpeed updates policy and bumps rev")
	check(not E.setDesignSpeed(ds, 25) and ds.rev == rev0 + 1,
		"policy: setting the same designSpeed is a no-op")
	local pSlow = assert(E.profile(ds))
	-- slower design speed -> smaller R_v -> shorter parabola -> higher crest near PVI
	check(P.elevationAtClamped(pSlow, 500) > P.elevationAtClamped(pFast, 500),
		"policy: slower designSpeed produces tighter vertical curve")
	check(E.setDesignSpeed(ds, 0) and ds.policy.designSpeed == G.DEFAULT_PARAMS.maxDesignSpeed,
		"policy: non-positive designSpeed falls back to maxDesignSpeed")
end

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
local past = E.bracketAt(nil, bp[4].x, bp[4].y, 0, R).bar + R + 1 -- (past its bar's end, and its grab radius)
check(hitAt(bk, bp[4].x + ax * past, bp[4].y + ay * past, R) == nil, "a bracket on a turn: nothing past its tips")
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
-- (picked within the grab radius of what is drawn: its bar and its tips' ends, but no further
-- behind its bar than that)
do
	local gs = E.bracketAt(nil, gexit.x, gexit.y, 0, R)
	local function at(across, along)
		return hitAt(bg, gexit.x - gexit.uy * across + gexit.ux * along, gexit.y + gexit.ux * across + gexit.uy * along, R)
	end
	check(is(at(gs.bar, gs.tip + R / 2), "exit", 2) and is(at(-gs.bar, gs.tip + R / 2), "exit", 2),
		"a bracket: just past its tips' ends picks it")
	check(at(gs.bar * 0.9, -R - 1) == nil and at(gs.bar * 0.9, gs.tip + R + 1) == nil,
		"a bracket: nothing further than its grab radius behind its bar or past its tips")
end

-- setting a curve's radius: the radius laid is the one asked, within what the legs and the minimum radius allow
local sr = assert(E.new(endAt(0, 0, 0), endAt(3000, 2000, 90))) -- (one long-legged corner, turn 2)
local ti = 2
local r0 = E.curve(sr, ti).radius
check(r0 >= dp.minRadius - 1e-6, "radius: a curve reads its radius")
local lo = E.corners(sr)[ti].geometry.minBudget
for _, want in ipairs({ 120, 250, 400 }) do
	local ok = E.setRadius(sr, ti, want)
	local got = E.curve(sr, ti).radius
	local l = E.corners(sr)[ti]
	local inReach = l.budget > lo + 1e-6 and l.budget < l.geometry.maxBudget - 1e-6
	check(ok and inReach and math.abs(got - want) < 0.01, "radius: " .. want .. " m is laid as asked (" .. string.format("%.3f", got) .. ")")
	joinsSmoothly(sr, "radius " .. want)
end
E.setRadius(sr, ti, 1)
check(math.abs(E.corners(sr)[ti].budget - E.corners(sr)[ti].geometry.minBudget) < 1e-6, "radius: below the minimum gives the minimum size")
check(E.curve(sr, ti).radius >= dp.minRadius - 1e-6, "radius: never under the minimum radius")
E.setRadius(sr, ti, 1e9)
check(math.abs(E.corners(sr)[ti].budget - E.corners(sr)[ti].geometry.maxBudget) < 1e-6, "radius: above the room gives the most room")
check(not E.setRadius(sr, 1, 100), "radius: no curve at an end")
check(E.turnIndex(sr, sr.turns[ti]) == ti and E.turnIndex(sr, {}) == nil, "turnIndex: where a turn is now, nil for one that is not there")
local gone = sr.turns[ti]
sr.turns = { sr.turns[1], sr.turns[#sr.turns] }
check(E.turnIndex(sr, gone) == nil, "turnIndex: nil once the turn is gone")

-- Ray-constrained guide PVIs at track ends
;(function()
	local Ends = H.mod("tg_ends")
	-- 1. Initialization: two track ends -> 2 guide PVIs at min(LEAD, L/3); one track end -> 1; two ground ends -> 0
	local tt = assert(E.new(vend(0, 0, 0, 10, 0.02), vend(1000, 0, 180, 20, -0.01)))
	local tpts = E.points(tt)
	check(#tpts == 4, "guide init (track-track): 2 ends + 2 guide PVIs (" .. #tpts .. ")")
	check(tpts[2].guide and tpts[2].slides and not tpts[2].liftable
		and math.abs(tpts[2].s - Ends.LEAD) < 1e-6
		and math.abs(tpts[2].z - (10 + 0.02 * Ends.LEAD)) < 1e-6,
		"guide init (track-track): start guide at LEAD on start grade ray")
	check(tpts[3].guide and tpts[3].slides and not tpts[3].liftable
		and math.abs(tpts[3].s - (1000 - Ends.LEAD)) < 1e-6
		and math.abs(tpts[3].z - (20 + (-0.01) * Ends.LEAD)) < 1e-6,
		"guide init (track-track): end guide at L-LEAD on end grade ray")
	local prof = assert(E.profile(tt))
	check(math.abs(P.gradeAtClamped(prof, 0) - 0.02) < 1e-6
		and math.abs(P.gradeAtClamped(prof, 1000) - 0.01) < 1e-6,
		"guide init (track-track): exact grade continuity at both ends")

	-- short track (L = 300 < 3 * LEAD): guide PVIs at L/3 = 100 and 2L/3 = 200
	local ts = assert(E.new(vend(0, 0, 0, 0, 0.015), vend(300, 0, 180, 5, 0.01)))
	local tspts = E.points(ts)
	check(#tspts == 4 and math.abs(tspts[2].s - 100) < 1e-6 and math.abs(tspts[3].s - 200) < 1e-6,
		"guide init (short): guide PVIs at L/3 and 2L/3")

	-- one track end + one ground end -> 1 guide PVI
	local tg1 = assert(E.new(vend(0, 0, 0, 10, 0.02), gnd(1000, 0, 15)))
	local tg1pts = E.points(tg1)
	check(#tg1pts == 3 and tg1pts[2].guide and math.abs(tg1pts[2].s - Ends.LEAD) < 1e-6
		and math.abs(tg1pts[2].z - (10 + 0.02 * Ends.LEAD)) < 1e-6,
		"guide init (track-ground): one start guide PVI")

	local gt1 = assert(E.new(gnd(0, 0, 15), vend(1000, 0, 180, 10, 0.02)))
	local gt1pts = E.points(gt1)
	check(#gt1pts == 3 and gt1pts[2].guide and math.abs(gt1pts[2].s - (1000 - Ends.LEAD)) < 1e-6
		and math.abs(gt1pts[2].z - (10 + 0.02 * Ends.LEAD)) < 1e-6,
		"guide init (ground-track): one end guide PVI")

	-- two ground ends -> no guide PVIs
	local gg0 = assert(E.new(gnd(0, 0, 0), gnd(1000, 0, 10)))
	check(#E.points(gg0) == 2, "guide init (ground-ground): no guide PVIs")

	-- 2. Horizontal edits preserve grade continuity (guide elevation recomputed from ray)
	local he = assert(E.new(vend(0, 0, 0, 10, 0.02), vend(1000, 0, 180, 20, -0.01)))
	E.insertOnLeg(he, 1, 500, 0)
	E.movePi(he, 3, 500, 200)
	local newLen = length(he)
	check(newLen > 1020, "guide horizontal edit: path got longer")
	local hpts = E.points(he)
	check(math.abs(hpts[2].z - (10 + 0.02 * hpts[2].s)) < 1e-6
		and math.abs(hpts[3].z - (20 + (-0.01) * (newLen - hpts[3].s))) < 1e-6,
		"guide horizontal edit: guide elevations stay on grade rays after length change")
	local hprof = assert(E.profile(he))
	check(math.abs(P.gradeAtClamped(hprof, 0) - 0.02) < 1e-6
		and math.abs(P.gradeAtClamped(hprof, newLen) - 0.01) < 1e-6,
		"guide horizontal edit: exact grade continuity preserved at both joins")

	-- 3. Sliding guide PVI updates elevation along ray; cannot remove or setHeight; hit in vertical mode
	local okSlide, newIdx = E.movePoint(tt, 2, 300, 999, 0.085)
	local afterSlide = E.points(tt)
	check(okSlide and newIdx == 2 and math.abs(afterSlide[2].s - 300) < 1e-6
		and math.abs(afterSlide[2].z - (10 + 0.02 * 300)) < 1e-6,
		"guide slide: slides to new station and updates elevation on ray (ignoring z)")
	check(not E.setHeight(tt, 2, 50) and math.abs(E.points(tt)[2].z - (10 + 0.02 * 300)) < 1e-6,
		"guide setHeight: rejected")
	check(not E.removeElevation(tt, 2) and #E.points(tt) == 4, "guide remove: rejected")
	local gh = E.hit(tt, true, afterSlide[2].x + 1, afterSlide[2].y, 5)
	check(gh ~= nil and gh.kind == "point" and gh.i == 2, "guide hit: hit as point in vertical mode")

	-- 4. Free PVIs stay strictly between active start and end guide PVIs
	local r1, why1 = E.insertElevation(tt, 100) -- before start guide at 300
	check(r1 == nil and why1 ~= nil, "guide bounds: cannot insert before start guide")
	local r2, why2 = E.insertElevation(tt, 900) -- after end guide at 800
	check(r2 == nil and why2 ~= nil, "guide bounds: cannot insert after end guide")
	local fi = E.insertElevation(tt, 500)
	check(fi == 3 and #E.points(tt) == 5 and not E.points(tt)[3].guide, "guide bounds: insert between guides succeeds")
	-- drag free PVI past start guide -> stops strictly after start guide
	local okD1, idxD1 = E.movePoint(tt, 3, 100, E.points(tt)[3].z, 1.0)
	local ptsD1 = E.points(tt)
	check(okD1 and idxD1 == 3 and ptsD1[3].s > ptsD1[2].s and ptsD1[3].tooClose,
		"guide bounds: free PVI cannot be dragged past start guide (triggers tooClose)")
	-- drag free PVI past end guide -> stops strictly before end guide
	local okD2, idxD2 = E.movePoint(tt, 3, 950, E.points(tt)[3].z, 1.0)
	local ptsD2 = E.points(tt)
	check(okD2 and idxD2 == 3 and ptsD2[3].s < ptsD2[4].s and ptsD2[3].tooClose,
		"guide bounds: free PVI cannot be dragged past end guide (triggers tooClose)")
	-- drag start guide past free PVI -> stops strictly before free PVI
	E.movePoint(tt, 3, 500, E.points(tt)[3].z, 1.0)
	local okG, idxG = E.movePoint(tt, 2, 700, 0, 1.0)
	local ptsG = E.points(tt)
	check(okG and idxG == 2 and ptsG[2].s < ptsG[3].s and ptsG[2].tooClose,
		"guide bounds: start guide cannot be dragged past free PVI")

	-- 5. Dragging ground end onto track adds guide PVI; dragging back off restores prior PVI state
	local me = assert(E.new(gnd(0, 0, 0), gnd(1000, 0, 0)))
	E.insertElevation(me, 400)
	E.setHeight(me, 2, 5)
	check(#E.points(me) == 3, "moveEnd guide: starts with 1 free PVI")
	local trk = trackAt(1000, 0, 180)
	trk.z, trk.grade = 2, 0.015
	check(E.moveEnd(me, 2, trk), "moveEnd guide: drag ground end onto track")
	local meOn = E.points(me)
	check(#meOn == 4 and not meOn[2].guide and math.abs(meOn[2].z - 5) < 1e-6
		and meOn[3].guide and math.abs(meOn[3].z - (2 + 0.015 * (length(me) - meOn[3].s))) < 1e-6,
		"moveEnd guide: end guide PVI added cleanly, free PVI kept")
	local meProf = assert(E.profile(me))
	check(math.abs(P.gradeAtClamped(meProf, length(me)) - (-0.015)) < 1e-6,
		"moveEnd guide: exact grade continuity at newly snapped track end")
	-- drag back onto ground before dropping -> restores prior PVI state
	check(E.moveEnd(me, #E.polyline(me), gnd(1000, 50, 0)), "moveEnd guide: drag back off onto ground")
	local meBack = E.points(me)
	check(#meBack == 3 and not meBack[2].guide and math.abs(meBack[2].z - 5) < 1e-6,
		"moveEnd guide: prior PVI state restored on return to ground")
	-- drag onto track and drop -> guide PVI stays
	check(E.moveEnd(me, 2, trk), "moveEnd guide: drag back onto track")
	E.dropEnd(me)
	check(#E.points(me) == 4 and E.points(me)[3].guide, "moveEnd guide: after dropEnd, guide PVI stays")
end)()

------------------------------------------------------------------ per-PVI curve speeds
;(function()
	local function segStations(path)
		local out, s = {}, 0.0
		for _, seg in ipairs(path) do
			local len = G.length(seg)
			if len > 1e-6 then
				out[#out + 1] = { kind = seg.kind, radius = seg.radius, s0 = s, s1 = s + len }
				s = s + len
			end
		end
		return out
	end
	local function findSeg(segs, kind)
		for _, sg in ipairs(segs) do
			if sg.kind == kind then return sg end
		end
		return nil
	end
	local function parabolaRadiusAt(prof, s)
		for _, seg in ipairs(prof.segments) do
			if seg.kind == "parabola" and seg.startStation <= s and s <= seg.startStation + seg.length then
				return seg.length / math.abs(seg.endGrade - seg.startGrade)
			end
		end
		return nil
	end

	-- Ground-to-ground alignment with a 90-deg turn sized to R = 250 m: entry straight, entry spiral ("in"), arc, exit spiral ("out"), exit straight.
	local function makeTurnEdit(designSpeed, curveSpeed)
		local ce = assert(E.new(gnd(0, 0, 0), gnd(1000, 1000, 0), nil, designSpeed, curveSpeed))
		local ti = assert(E.insertOnLeg(ce, 1, 500, 500))
		assert(E.movePi(ce, ti, 1000, 0))
		assert(E.setRadius(ce, ti, 250))
		return ce
	end

	-- 1. Curve (arc) vs straight: PVI in arc uses curveSpeed; PVI on straight uses designSpeed
	local designV, curveV = 40.0, 20.0
	local expectedDesignR = designV * designV / P.DEFAULT_POLICY.maxVerticalAccel
	local expectedCurveR = curveV * curveV / P.DEFAULT_POLICY.maxVerticalAccel
	local queriedR = {}
	local ce = makeTurnEdit(designV, function(R)
		queriedR[#queriedR + 1] = R
		return curveV
	end)
	local segs = segStations(E.path(ce))
	local stSeg = assert(findSeg(segs, "straight"))
	local inSeg = assert(findSeg(segs, "in"))
	local arcSeg = assert(findSeg(segs, "arc"))
	local sStraight = (stSeg.s0 + stSeg.s1) / 2
	local sSpiral = (inSeg.s0 + inSeg.s1) / 2
	local sArc = (arcSeg.s0 + arcSeg.s1) / 2

	local iSt = assert(E.insertElevation(ce, sStraight))
	assert(E.setHeight(ce, iSt, 12))
	local iArc = assert(E.insertElevation(ce, sArc))
	assert(E.setHeight(ce, iArc, 2))
	local prof = assert(E.profile(ce))
	local rSt = parabolaRadiusAt(prof, sStraight)
	local rArc = parabolaRadiusAt(prof, sArc)
	check(rSt ~= nil and math.abs(rSt - expectedDesignR) < 1e-3,
		string.format("curve speed: PVI on straight uses designSpeed (rV=%.1f, want %.1f)", rSt or -1, expectedDesignR))
	check(rArc ~= nil and math.abs(rArc - expectedCurveR) < 1e-3,
		string.format("curve speed: PVI in arc uses curveSpeed (rV=%.1f, want %.1f)", rArc or -1, expectedCurveR))
	check(#queriedR > 0 and math.abs(queriedR[#queriedR] - arcSeg.radius) < 1e-6,
		"curve speed: lookup queried with the horizontal arc's radius")

	-- 2. PVI inside an entry spiral also uses curveSpeed for that curve's radius
	local spEdit = makeTurnEdit(designV, function() return curveV end)
	local iSp = assert(E.insertElevation(spEdit, sSpiral))
	assert(E.setHeight(spEdit, iSp, 10))
	local rSp = parabolaRadiusAt(assert(E.profile(spEdit)), sSpiral)
	check(rSp ~= nil and math.abs(rSp - expectedCurveR) < 1e-3,
		string.format("curve speed: PVI in spiral uses curveSpeed (rV=%.1f, want %.1f)", rSp or -1, expectedCurveR))

	-- 3. Curve speed higher than designSpeed is capped by designSpeed
	assert(E.setCurveSpeed(ce, function() return 80.0 end) == true, "curve speed: setCurveSpeed bumps when speed changes")
	local rCapped = parabolaRadiusAt(assert(E.profile(ce)), sArc)
	check(rCapped ~= nil and math.abs(rCapped - expectedDesignR) < 1e-3,
		string.format("curve speed: speed above designSpeed is capped (rV=%.1f, want %.1f)", rCapped or -1, expectedDesignR))

	-- 4. Unmeasured (nil), throwing, zero, NaN, and nil lookup all fall back cleanly to designSpeed
	for _, case in ipairs({
		{ name = "nil result", fn = function() return nil end },
		{ name = "throwing", fn = function() error("probe failed") end },
		{ name = "zero", fn = function() return 0 end },
		{ name = "NaN", fn = function() return 0 / 0 end },
		{ name = "nil lookup", fn = nil },
	}) do
		E.setCurveSpeed(ce, case.fn)
		local okP, p = pcall(E.profile, ce)
		local rFb = okP and p ~= nil and parabolaRadiusAt(p, sArc) or nil
		check(okP and rFb ~= nil and math.abs(rFb - expectedDesignR) < 1e-3,
			"curve speed fallback (" .. case.name .. "): falls back to designSpeed without throwing")
	end

	-- 5. setCurveSpeed bumps rev only when effective per-PVI speeds change
	local revBefore = ce.rev
	check(E.setCurveSpeed(ce, function() return 25.0 end) == true and ce.rev == revBefore + 1,
		"curve speed: setCurveSpeed returns true and bumps rev on change")
	local r25 = parabolaRadiusAt(assert(E.profile(ce)), sArc)
	local expected25 = 25.0 * 25.0 / P.DEFAULT_POLICY.maxVerticalAccel
	check(r25 ~= nil and math.abs(r25 - expected25) < 1e-3,
		"curve speed: profile recomputes with updated curve speed")
	check(E.setCurveSpeed(ce, function() return 25.0 end) == false and ce.rev == revBefore + 1,
		"curve speed: setCurveSpeed is a no-op when speeds are unchanged")

	-- 6. Resizing a horizontal curve updates the vertical curve radius for a PVI inside it
	local rsEdit = makeTurnEdit(designV, function(R) return math.sqrt(R) end)
	local rsArc0 = assert(findSeg(segStations(E.path(rsEdit)), "arc"))
	local iMid = assert(E.insertElevation(rsEdit, (rsArc0.s0 + rsArc0.s1) / 2))
	assert(E.setHeight(rsEdit, iMid, 10))
	local rBefore = parabolaRadiusAt(assert(E.profile(rsEdit)), E.points(rsEdit)[iMid].s)
	assert(E.setRadius(rsEdit, 2, 180))
	local rsArc1 = assert(findSeg(segStations(E.path(rsEdit)), "arc"))
	local ptAfter = E.points(rsEdit)[iMid]
	local rAfter = parabolaRadiusAt(assert(E.profile(rsEdit)), ptAfter.s)
	local wantAfter = rsArc1.radius / P.DEFAULT_POLICY.maxVerticalAccel -- (sqrt(R))^2 / a = R / a (> minVerticalRadius 500)
	check(rBefore ~= nil and rAfter ~= nil and rAfter < rBefore and math.abs(rAfter - wantAfter) < 1e-2,
		string.format("curve speed: resizing curve updates vertical radius (%.1f -> %.1f, want %.1f)",
			rBefore or -1, rAfter or -1, wantAfter))
end)()
H.done()
