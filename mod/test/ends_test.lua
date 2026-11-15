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

-- Which free end the mouse snaps to.
local function fe(node, x, y) return { node = node, x = x, y = y, z = 0, dx = 1, dy = 0, grade = 0 } end
local near = { fe(1, 0, 0), fe(2, 30, 0), fe(3, 100, 0) }
local got = E.snap(near, {}, true, 25, 0)
check(got ~= nil and got.node == 2, "snap: the nearest free end within SNAP")
got = E.snap(near, {}, true, 25, 0, 2)
check(got ~= nil and got.node == 1, "snap: never the excluded node, the next nearest instead")
got = E.snap(near, { [3] = true }, true, 25, 0)
check(got ~= nil and got.node == 2, "snap: of the qualifying ends, the nearest, hovered or not")
got = E.snap(near, { [3] = true }, true, 25, 0, 2)
check(got ~= nil and got.node == 1, "snap: the hovered piece's far end does not beat a nearer one")
got = E.snap({ fe(3, 100, 0) }, { [3] = true }, true, 25, 0)
check(got ~= nil and got.node == 3, "snap: an end of the hovered piece snaps beyond SNAP")
got = E.snap({ fe(3, 100, 0) }, { [3] = true }, true, nil, nil)
check(got ~= nil and got.node == 3, "snap: over no ground, the hovered piece's end still snaps")
local none, hint = E.snap({ fe(3, 100, 0) }, {}, true, 25, 0)
check(none == nil and hint:find("No free track end") ~= nil, "snap: track there but no free end near: says so")
none, hint = E.snap({}, {}, false, 25, 0)
check(none == nil and hint:find("Point at the end of a track") ~= nil, "snap: no track at all: says to point at one")
got = E.snap({ fe(1, E.SNAP, 0) }, {}, true, 0, 0)
check(got ~= nil, "snap: exactly SNAP away still snaps")

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
