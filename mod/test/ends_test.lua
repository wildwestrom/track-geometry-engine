-- Offline checks for the starting alignment between two picked ends (tg_ends.script.tl). Run from
-- mod/ after check.sh builds .tlpath/:
--   lua test/ends_test.lua
local tl = require("tl")
tl.loader()
package.path = ".tlpath/?.tl;" .. package.path
local G = require("westrom_track_geometry::/track_geometry/tg_geometry.script.tl")
local A = require("westrom_track_geometry::/track_geometry/tg_alignment.script.tl")
local E = require("westrom_track_geometry::/track_geometry/tg_ends.script.tl")

local failures = 0
local function check(ok, what)
	print((ok and "ok   " or "FAIL ") .. what)
	if not ok then failures = failures + 1 end
end
local function atan2(y, x) return math.atan2 and math.atan2(y, x) or math.atan(y, x) end
local function angleDiff(a, b) return math.abs(atan2(math.sin(a - b), math.cos(a - b))) end
local function eq(a, b) return math.abs(a - b) < 1e-9 end

local function endAt(x, y, deg)
	return { x = x, y = y, dx = math.cos(math.rad(deg)), dy = math.sin(math.rad(deg)) }
end

-- Each case: the ends, the layout expected and how many turns it has. Ends off by a hair are laid
-- with turns, but each turn is below straightThreshold, so buildPath runs one straight between
-- them: their headings are only as close as that threshold. Ends in line to float noise are laid
-- straight, so their headings are only as close as that noise.
local cases = {
	{ "straight", endAt(0, 0, 0), endAt(600, 0, 180), "straight", 0 },
	{ "straight, diagonal", endAt(0, 0, 45), endAt(300, 300, 225), "straight", 0 },
	{ "in line but off by a hair", endAt(0, 0, 0), endAt(600, 0.005, 180), "s-curve", 2 },
	{ "facing but angled by a hair", endAt(0, 0, 0), endAt(600, 0, 180 + math.deg(1e-5)), "s-curve", 2 },
	{ "in line to float noise", endAt(0, 0, 0), endAt(600, 0.001, 180 + math.deg(5e-7)), "straight", 0 },
	-- two ends of one straight line in game (float32 data): 1.4e-7 rad and 0.086 mm apart
	{ "in line in game", { x = 2131.8533, y = -1847.1685, dx = -0.984807737, dy = 0.173648271 },
		{ x = 1363.1891, y = -1711.6321, dx = 0.984807761, dy = -0.173648132 }, "straight", 0 },
	{ "corner", endAt(0, 0, 0), endAt(500, 400, -90), "corner", 1 },
	{ "diagonal corner", endAt(100, -50, 45), endAt(-200, 600, 0), "corner", 1 },
	{ "parallel, offset", endAt(0, 0, 0), endAt(600, 100, 180), "s-curve", 2 },
	{ "rays meet behind", endAt(0, 0, 0), endAt(400, 300, 90), "s-curve", 2 },
	{ "rays meet over 1 km out", endAt(0, 0, 0), endAt(100, 300, -10), "s-curve", 2 },
	{ "rays meet under MIN_LEG out", endAt(0, 0, 0), endAt(10, 300, -90), "s-curve", 2 },
	{ "over 800 m apart", endAt(0, 0, 0), endAt(900, 100, 180), "long s-curve", 3 },
	{ "over 800 m apart, rays meet ahead", endAt(0, 0, 0), endAt(700, 500, -90), "long s-curve", 3 },
}

for _, c in ipairs(cases) do
	local name, a, b, want, turns = c[1], c[2], c[3], c[4], c[5]
	local tol = name:find("by a hair") and G.DEFAULT_PARAMS.straightThreshold
		or (name:find("float noise") or name:find("in game")) and 1e-5 or 1e-9
	local pis, how = E.initialPis(a, b)
	check(how == want and pis ~= nil and #pis == turns + 2,
		string.format("%s: laid as %s with %d turns", name, tostring(how), pis and #pis - 2 or -1))
	if pis ~= nil then
		local path = G.buildPath(pis, G.DEFAULT_PARAMS, nil)
		local nodes = A.sample(path, 10)
		local first, last = nodes[1], nodes[#nodes]
		local leave, arrive = atan2(a.dy, a.dx), atan2(-b.dy, -b.dx)
		check(math.abs(first.x - a.x) + math.abs(first.y - a.y) < 1e-9
			and math.abs(last.x - b.x) + math.abs(last.y - b.y) < 1e-6, name .. ": starts and ends on the ends")
		check(angleDiff(first.heading, leave) < tol and angleDiff(last.heading, arrive) < tol,
			string.format("%s: leaves at %.1f deg, arrives at %.1f deg", name, math.deg(first.heading), math.deg(last.heading)))
		local bad = false
		for _, nd in ipairs(nodes) do
			if nd.x ~= nd.x or nd.y ~= nd.y or nd.heading ~= nd.heading then bad = true end
		end
		check(not bad and #nodes >= 2, string.format("%s: %d sound nodes over %.0f m", name, #nodes, last.s))
	end
end

local function d(p, x, y) return math.sqrt((p.x - x) ^ 2 + (p.y - y) ^ 2) end
-- Is turn p want out along end e's ray?
local function onRay(p, e, want)
	return d(p, e.x + want * e.dx, e.y + want * e.dy) < 1e-9
end

-- One turn: where the rays meet, next to both ends.
local pc = E.initialPis(endAt(0, 0, 0), endAt(500, 400, -90))
check(d(pc[2], 500, 0) < 1e-9, "corner: the turn is where the rays meet")
local pd = E.initialPis(endAt(0, 0, 0), endAt(500, 50, math.deg(atan2(-50, 480))))
check(#pd == 3 and d(pd[2], 980, 0) < 1e-6, "corner: rays meeting 980 m from an end still make one turn")
pd = E.initialPis(endAt(0, 0, 0), endAt(21, 300, -90))
check(#pd == 3, "corner: rays meeting just over MIN_LEG out make one turn")

-- Two turns: each on its end's ray at min(LEAD, dist/3).
local a, b = endAt(0, 0, 0), endAt(600, 100, 180)
local ps = E.initialPis(a, b)
check(onRay(ps[2], a, E.LEAD) and onRay(ps[3], b, E.LEAD), "s-curve: a turn LEAD out on each ray")
a, b = endAt(0, 0, 0), endAt(60, 20, 180)
local short = math.sqrt(60 ^ 2 + 20 ^ 2)
ps = E.initialPis(a, b)
check(onRay(ps[2], a, short / 3) and onRay(ps[3], b, short / 3), "short s-curve: each turn a third of the distance out")
a, b = endAt(0, 0, 0), endAt(100, 300, -10)
ps = E.initialPis(a, b)
local third = math.sqrt(100 ^ 2 + 300 ^ 2) / 3
check(onRay(ps[2], a, third) and onRay(ps[3], b, third), "rays meeting over 1 km out: two turns on the rays")

-- Three turns: a lead LEAD out on each ray and a free turn halfway between them.
a, b = endAt(0, 0, 0), endAt(700, 500, -90)
local pl = E.initialPis(a, b)
check(onRay(pl[2], a, E.LEAD) and onRay(pl[4], b, E.LEAD), "long: a lead LEAD out on each ray")
check(d(pl[3], 450, 150) < 1e-9, "long: the middle turn is halfway between the leads, not where the rays meet")

local pis, why = E.initialPis(endAt(0, 0, 0), endAt(30, 0, 180))
check(pis == nil and why ~= nil, "ends 30 m apart refused: " .. tostring(why))

-- Ground ends: no heading, so each takes its leg's direction.
local function ground(x, y) return E.groundEnd(x, y, 5) end
local g = ground(10, 20)
check(g.kind == "ground" and g.x == 10 and g.y == 20 and g.z == 5 and g.dx == nil and g.grade == nil and g.node == nil,
	"a ground end has a place and a height, no heading, grade or node")
local gp, ghow = E.initialPis(ground(0, 0), ground(300, 400))
check(ghow == "straight" and #gp == 2 and d(gp[1], 0, 0) < 1e-9 and d(gp[2], 300, 400) < 1e-9,
	"two ground ends: straight, no turns")
-- One heading end: a turn on its ray, as far from both ends (a symmetric curve).
local function arcCase(name, h, gx, gy, first)
	local ge = ground(gx, gy)
	local pis, how = E.initialPis(first and h or ge, first and ge or h)
	local t = pis and pis[2]
	local dh, dg = t and d(t, h.x, h.y), t and d(t, gx, gy)
	check(how == "arc" and #pis == 3 and onRay(t, h, dh) and math.abs(dh - dg) < 1e-9,
		string.format("%s: one turn on the ray, %.1f m from both ends", name, dh or -1))
	local nodes = A.sample(G.buildPath(pis, G.DEFAULT_PARAMS, nil), 10)
	local at = first and nodes[1] or nodes[#nodes]
	local want = first and atan2(h.dy, h.dx) or atan2(-h.dy, -h.dx)
	check(angleDiff(at.heading, want) < 1e-9, name .. ": the path keeps the heading end's heading")
	check(d(nodes[1], pis[1].x, pis[1].y) < 1e-9 and d(nodes[#nodes], pis[3].x, pis[3].y) < 1e-6,
		name .. ": starts and ends on the ends")
end
arcCase("track to ground", endAt(0, 0, 0), 300, 200, true)
arcCase("ground to track", endAt(500, 100, 90), 200, 400, false)
arcCase("ground dead ahead", endAt(0, 0, 0), 300, 0, true)
-- The ground end behind or beside the ray (no such turn, or one closer than MIN_LEG or further
-- than MAX_REACH): the turn goes min(LEAD, dist/3) out on the ray.
local function leadCase(name, h, gx, gy)
	local pis, how = E.initialPis(h, ground(gx, gy))
	local L = math.min(E.LEAD, math.sqrt((gx - h.x) ^ 2 + (gy - h.y) ^ 2) / 3)
	check(how == "turn on the ray" and #pis == 3 and onRay(pis[2], h, L),
		string.format("%s: laid as %s, the turn %.0f m out on the ray", name, tostring(how), L))
end
leadCase("ground behind", endAt(0, 0, 0), -300, 50)
leadCase("ground beside", endAt(0, 0, 0), 0, 300)
leadCase("ground far beside", endAt(0, 0, 0), 900, 1400) -- (the turn would be 1.5 km out)
local close, cwhy = E.initialPis(endAt(0, 0, 0), ground(30, 10))
check(close == nil and cwhy ~= nil, "a ground end 32 m from a track end refused: " .. tostring(cwhy))
close, cwhy = E.initialPis(ground(0, 0), ground(0, 39))
check(close == nil and cwhy ~= nil, "two ground ends 39 m apart refused")

-- A free track end is an end of kind "track", with its node, heading and grade.
local te = E.trackEnd(7, 10, 20, 3, 0, 1, 0.01)
check(te.kind == "track" and te.node == 7 and te.x == 10 and te.y == 20 and te.z == 3
	and te.dx == 0 and te.dy == 1 and te.grade == 0.01, "a free track end is an end of kind track, with its node")

-- Which end the mouse picks.
local function fe(node, x, y) return { kind = "track", node = node, x = x, y = y, z = 0, dx = 1, dy = 0, grade = 0 } end
local function ne(node, x, y) return E.nodeEnd(node, x, y, 0, { { dx = 1, dy = 0, grade = 0 }, { dx = -1, dy = 0, grade = 0 } }) end
local function P(x, y, z) return { x = x, y = y, z = z } end
-- a straight piece 200 m along x from node 11 at (0, 0, 10) to node 12, climbing 2 m
local straightPiece = { edge = 40, node0 = 11, node1 = 12, p0 = P(0, 0, 10), t0 = P(200, 0, 2), p1 = P(200, 0, 12), t1 = P(200, 0, 2) }
local near = { fe(1, 0, 0), fe(2, 30, 0), fe(3, 100, 0) }
local got = E.snap(near, nil, 25, 0, 0)
check(got ~= nil and got.node == 2, "snap: the nearest free end within SNAP")
got = E.snap(near, nil, 25, 0, 0, fe(2, 30, 0))
check(got ~= nil and got.node == 1, "snap: never the excluded node, the next nearest instead")
got = E.snap({ fe(1, E.SNAP, 0) }, nil, 0, 0, 0)
check(got ~= nil and got.node == 1, "snap: exactly SNAP away still snaps")
got = E.snap({ fe(3, 100, 0) }, nil, 25, 0, 7)
check(got ~= nil and got.kind == "ground" and got.x == 25 and got.y == 0 and got.z == 7,
	"snap: no end near, off track: the ground under the mouse, at its height")
got = E.snap({ fe(2, 30, 0) }, nil, 25, 0, 7, fe(2, 30, 0))
check(got ~= nil and got.kind == "ground", "snap: only the excluded node near: the ground")
got = E.snap({ ne(11, 0, 0), ne(12, 200, 0) }, straightPiece, 4, 1, 0)
check(got ~= nil and got.node == 11, "snap: a node within NODE_SNAP")
got = E.snap({ ne(11, 0, 0), ne(12, 200, 0) }, straightPiece, 8, 1, 0)
check(got ~= nil and got.kind == "split", "snap: 8 m from a node: a cut")
got = E.snap({ ne(11, 0, 0), ne(12, 200, 0) }, straightPiece, 4, 6, 0)
check(got ~= nil and got.node == 11, "snap: past NODE_SNAP but too near the node to cut: the node")
got = E.snap({ ne(11, 0, 0), ne(12, 200, 0) }, straightPiece, 15, 3, 0)
check(got ~= nil and got.kind == "split" and got.piece.edge == 40 and math.abs(got.x - 15) < 1e-6 and eq(got.y, 0) and math.abs(got.z - 10.15) < 1e-6,
	"snap: further from a node, on the piece: the point on it nearest the mouse, at its height")
got = E.snap({ ne(12, 200, 0) }, straightPiece, 3, 0, 0)
local none, hint = got, select(2, E.snap({ ne(12, 200, 0) }, straightPiece, 3, 0, 0))
check(none == nil and hint ~= nil, "snap: a cut leaving under MIN_HALF: nothing, and why")
got = E.snap({}, straightPiece, 100, 2, 0, E.splitEnd(straightPiece, 0.25))
check(got == nil, "snap: never a second cut of the start's piece")
none, hint = E.snap({}, nil, nil, nil, nil)
check(none == nil and hint:find("Point at the ground") ~= nil, "snap: over no ground: says where to point")

-- A piece cut in two: the parts meet at the cut, keep the piece's ends, and follow its curve.
local curved = { edge = 41, node0 = 21, node1 = 22, p0 = P(0, 0, 0), t0 = P(300, 0, 3), p1 = P(200, 200, 6), t1 = P(0, 300, 3) }
local u = E.nearestOnPiece(curved, 150, 60)
local cp = E.pieceAt(curved, u)
local cut = true
for k = 0, 20 do
	local q = E.pieceAt(curved, k / 20)
	if (q.x - 150) ^ 2 + (q.y - 60) ^ 2 < (cp.x - 150) ^ 2 + (cp.y - 60) ^ 2 - 1e-9 then cut = false end
end
check(cut and u > 0 and u < 1, "piece: the nearest point on it")
local a, b = E.halves(curved, u)
check(a.node0 == 21 and a.node1 == nil and b.node0 == nil and b.node1 == 22 and a.p0 == curved.p0 and b.p1 == curved.p1,
	"cut: the parts keep the piece's nodes at its ends")
check(eq(a.p1.x, cp.x) and eq(b.p0.y, cp.y) and eq(a.p1.z, b.p0.z), "cut: the parts meet at the cut")
local same = true
for k = 0, 10 do
	local s0 = k / 10
	local qa, qb = E.pieceAt(a, s0), E.pieceAt(b, s0)
	local ra, rb = E.pieceAt(curved, u * s0), E.pieceAt(curved, u + (1 - u) * s0)
	same = same and math.abs(qa.x - ra.x) + math.abs(qa.y - ra.y) + math.abs(qa.z - ra.z) < 1e-9
		and math.abs(qb.x - rb.x) + math.abs(qb.y - rb.y) + math.abs(qb.z - rb.z) < 1e-9
end
check(same, "cut: the parts follow the piece's own curve")
-- (halfway along `curved` its Hermite's derivative is 1.5 (p1 - p0) - 0.25 (t0 + t1) = (225, 225, 7.5))
local mid = E.splitEnd(curved, 0.5)
check(math.abs(mid.x - 137.5) < 1e-9 and math.abs(mid.y - 62.5) < 1e-9 and math.abs(mid.z - 3) < 1e-9
	and math.abs(mid.dirs[1].dx - math.sqrt(0.5)) < 1e-9 and math.abs(mid.dirs[1].dy - math.sqrt(0.5)) < 1e-9
	and math.abs(mid.dirs[1].grade - 7.5 / (225 * math.sqrt(2))) < 1e-9
	and mid.dirs[2].dx == -mid.dirs[1].dx and mid.dirs[2].grade == -mid.dirs[1].grade,
	"a cut end on a curve: heading and grade from the piece's tangent there, in either sense")
local sp = E.splitEnd(straightPiece, 0.5)
local spAim = E.aim(sp, 300, 50)
check(sp.kind == "split" and sp.node == nil and not E.hasHeading(sp) and eq(spAim.dx, 1) and eq(spAim.grade, 0.01)
	and spAim.piece == straightPiece and spAim.u == 0.5, "a cut end: aimed like a node end, along the piece at its grade")
check(E.aim(sp, -300, 50).dx == -1 and E.key(sp) ~= E.key(E.splitEnd(straightPiece, 0.6)), "a cut end: the other sense; its key is where it cuts")

-- Ends for a person and for telling them apart.
check(E.name(te) == "node 7" and E.name(E.groundEnd(120.4, -45.2, 0)) == "the ground at (120, -45)", "an end's name")
check(E.key(te) ~= E.key(E.groundEnd(10, 20, 3)) and E.key(E.groundEnd(10, 20, 3)) == E.key(E.groundEnd(10, 20, 9))
	and E.key(E.groundEnd(10, 20, 3)) ~= E.key(E.groundEnd(10.1, 20, 3)), "an end's key: its node, else where it is")

-- Existing-node ends (a switch): a node with track through it, or a junction. Its directions are
-- every piece's at the node, in either sense; aimed at the other end, it takes the one pointing
-- most toward it, with that direction's grade.
local function dir(deg, grade) return { dx = math.cos(math.rad(deg)), dy = math.sin(math.rad(deg)), grade = grade } end
local function both(deg, grade) return dir(deg, grade), dir(deg + 180, -grade) end
local function headingOf(e) return math.deg(atan2(e.dy, e.dx)) % 360 end
-- through a straight line along x, climbing 1 % towards +x
local through = E.nodeEnd(5, 0, 0, 2, { both(0, 0.01) })
check(through.kind == "node" and through.node == 5 and not E.hasHeading(through), "a node end: its node, no heading until aimed")
local fwd = E.aim(through, 300, 50)
check(fwd.kind == "node" and fwd.node == 5 and eq(headingOf(fwd), 0) and eq(fwd.grade, 0.01),
	"through node, other end ahead on the left: along the line, at its grade")
local fwdR = E.aim(through, 300, -50)
check(eq(headingOf(fwdR), 0) and eq(fwdR.grade, 0.01), "through node, other end ahead on the right: the same direction")
local back = E.aim(through, -300, 50)
check(eq(headingOf(back), 180) and eq(back.grade, -0.01), "through node, other end behind: the other sense, its grade too")
check(eq(headingOf(E.aim(fwd, -300, -50)), 180), "an aimed node end aims again")
check(E.key(fwd) ~= E.key(back) and E.key(fwd) == E.key(E.aim(through, 600, 10)), "a node end's key: its node and its heading")
check(E.aim(through, 0, 0) == through, "aimed at itself: left as it is")
-- a junction: the line along x and a branch leaving at 20 deg
local junction = E.nodeEnd(6, 0, 0, 0, { dir(0, 0), dir(180, 0), dir(20, 0.02), dir(200, -0.02) })
check(eq(headingOf(E.aim(junction, 500, -100)), 0), "junction, other end on the right of the line: along the line")
local branch = E.aim(junction, 500, 300)
check(eq(headingOf(branch), 20) and eq(branch.grade, 0.02), "junction, other end on the branch's side: along the branch")
check(eq(headingOf(E.aim(junction, -500, 30)), 180), "junction, other end behind on the left: back along the line")
check(eq(headingOf(E.aim(junction, -500, -300)), 200), "junction, other end behind on the right: back along the branch")
local tr = E.trackEnd(7, 0, 0, 0, 1, 0, 0)
check(E.aim(tr, -100, 0) == tr and E.aim(E.groundEnd(0, 0, 0), 9, 9).dx == nil, "aiming a free track end or the ground: no change")
-- the layouts treat an aimed node end as a free track end with that heading
-- (a corner close enough that a switch's turn may go there too)
local other = E.trackEnd(9, 100, 400, 0, 0, -1, 0)
local nodeL = { E.initialPis(E.aim(through, other.x, other.y), other) }
local trackL = { E.initialPis(E.trackEnd(5, 0, 0, 2, 1, 0, 0.01), other) }
local same = nodeL[2] == trackL[2] and #nodeL[1] == #trackL[1]
for i, p in ipairs(nodeL[1]) do same = same and eq(p.x, trackL[1][i].x) and eq(p.y, trackL[1][i].y) end
check(same and nodeL[2] == "corner", "layouts: an aimed node end lays out as a free track end with its heading")
local g = E.groundEnd(-400, 100, 0)
local toG = { E.initialPis(g, E.aim(through, g.x, g.y)) }
check(toG[2] == "switch" and eq(toG[1][2].y, 0) and toG[1][2].x < 0, "layouts: a ground end to a node end: the turn on the node's ray")

-- A switch (a node or cut end) leaves on a curve no wider than SWITCH_RADIUS: where an arc would
-- be wider (its radius is dist^2 / (2 offset): the other end nearly ahead), the turn goes out on
-- the ray only as far as that curve needs, t = R tan(deflection / 2). (A wider curve runs within a
-- track's width of the existing track for hundreds of metres, and the game refuses the overlap.)
local function deflection(a, pis)
	local p, q = pis[2], pis[3]
	local vx, vy = q.x - p.x, q.y - p.y
	return math.acos((vx * a.dx + vy * a.dy) / math.sqrt(vx * vx + vy * vy))
end
local function aimedNode(x, y) return E.aim(E.nodeEnd(5, 0, 0, 0, { both(0, 0) }), x, y) end
local gA = E.groundEnd(700, 300, 0) -- (an arc there: radius 967 m)
local swPis, swHow = E.initialPis(aimedNode(gA.x, gA.y), gA)
local t1 = swPis[2].x
check(swHow == "switch" and eq(swPis[2].y, 0) and t1 < 414 and math.abs(t1 - E.SWITCH_RADIUS * math.tan(deflection(aimedNode(1, 0), swPis) / 2)) < 0.01,
	"switch to the ground nearly ahead: the turn where the curve's radius is SWITCH_RADIUS (" .. tostring(t1) .. ")")
local trPis, trHow = E.initialPis(E.trackEnd(5, 0, 0, 0, 1, 0, 0), gA)
check(trHow == "arc" and math.abs(trPis[2].x - 580000 / 1400) < 1e-9, "a free track end there: the arc as before")
local backPis = E.initialPis(gA, aimedNode(gA.x, gA.y))
check(eq(backPis[#backPis - 1].x, t1) and eq(backPis[#backPis - 1].y, 0), "switch as the end: the same turn, laid backwards")
local gB = E.groundEnd(100, 300, 0) -- (an arc there: radius 167 m)
local besidePis, besideHow = E.initialPis(aimedNode(gB.x, gB.y), gB)
check(besideHow == "arc" and eq(besidePis[2].x, 500), "switch to the ground beside it: the arc, already tighter")
-- with headings at both ends: no corner far out along the switch's ray
local tb = E.trackEnd(9, 700, 300, 0, 0, -1, 0) -- (a corner at (700, 0) for a free track end)
local bothPis, bothHow = E.initialPis(aimedNode(tb.x, tb.y), tb)
check(bothHow == "s-curve" and bothPis[2].x < 300 and eq(bothPis[2].y, 0), "switch to a track end: no corner far out on its ray, its turn kept near it (" .. bothHow .. ")")


-- near pieces: the nearest within PIECE_SNAP, never the skipped one
local function line(edge, y)
	return { edge = edge, node0 = 1, node1 = 2, p0 = { x = 0, y = y, z = 0 }, t0 = { x = 100, y = 0, z = 0 },
		p1 = { x = 100, y = y, z = 0 }, t1 = { x = 100, y = 0, z = 0 } }
end
local two = { line(31, 0), line(32, 5) }
check(E.nearestPiece(two, 50, 3).edge == 32, "near pieces: the nearer of two")
check(E.nearestPiece(two, 50, 3, 32).edge == 31, "near pieces: not the skipped one")
check(E.nearestPiece(two, 50, -E.PIECE_SNAP - 0.5) == nil, "near pieces: none past PIECE_SNAP")

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
