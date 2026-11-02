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

-- Each case: the ends, and the layout expected.
local cases = {
	{ "corner", endAt(0, 0, 0), endAt(500, 400, -90), "corner" },
	{ "straight", endAt(0, 0, 0), endAt(600, 0, 180), "straight" },
	{ "parallel, offset", endAt(0, 0, 0), endAt(600, 100, 180), "s-curve" },
	{ "rays meet behind", endAt(0, 0, 0), endAt(400, 300, 90), "s-curve" },
	{ "rays meet too far", endAt(0, 0, 0), endAt(300, 20, 179), "s-curve" },
	{ "diagonal corner", endAt(100, -50, 45), endAt(-200, 700, 0), "corner" },
}

for _, c in ipairs(cases) do
	local name, a, b, want = c[1], c[2], c[3], c[4]
	local pis, how = E.initialPis(a, b)
	check(how == want, string.format("%s: laid as %s", name, tostring(how)))
	if pis ~= nil then
		local path = G.buildPath(pis, G.DEFAULT_PARAMS, nil)
		local nodes = A.sample(path, 10)
		local first, last = nodes[1], nodes[#nodes]
		local leave, arrive = atan2(a.dy, a.dx), atan2(-b.dy, -b.dx)
		check(math.abs(first.x - a.x) + math.abs(first.y - a.y) < 1e-9
			and math.abs(last.x - b.x) + math.abs(last.y - b.y) < 1e-6, name .. ": starts and ends on the ends")
		check(angleDiff(first.heading, leave) < 1e-9 and angleDiff(last.heading, arrive) < 1e-9,
			string.format("%s: leaves at %.1f deg, arrives at %.1f deg", name, math.deg(first.heading), math.deg(last.heading)))
		local bad = false
		for _, nd in ipairs(nodes) do
			if nd.x ~= nd.x or nd.y ~= nd.y or nd.heading ~= nd.heading then bad = true end
		end
		check(not bad and #nodes >= 2, string.format("%s: %d sound nodes over %.0f m", name, #nodes, last.s))
	end
end

-- Turned layouts lay a lead turn LEAD out on each end's ray and a free turn halfway between them,
-- so the middle leg runs near the straight line between the ends and the player can drag it.
local function d(p, x, y) return math.sqrt((p.x - x) ^ 2 + (p.y - y) ^ 2) end
local function leadsAt(name, a, b, wantA, wantB)
	local pis = E.initialPis(a, b)
	check(#pis == 5, name .. ": five turns")
	local la, lb = pis[2], pis[4]
	check(math.abs(d(la, a.x, a.y) - wantA) < 1e-9 and d(la, a.x + wantA * a.dx, a.y + wantA * a.dy) < 1e-9,
		string.format("%s: first lead %.1f m out along the ray", name, d(la, a.x, a.y)))
	check(math.abs(d(lb, b.x, b.y) - wantB) < 1e-9 and d(lb, b.x + wantB * b.dx, b.y + wantB * b.dy) < 1e-9,
		string.format("%s: last lead %.1f m out along the ray", name, d(lb, b.x, b.y)))
	return pis
end
local pc = leadsAt("corner", endAt(0, 0, 0), endAt(500, 400, -90), E.LEAD, E.LEAD)
check(d(pc[3], 350, 100) < 1e-9, "corner: the middle turn is halfway between the leads, not where the rays meet")
check(G.cornerGeometry(pc[2], pc[3], pc[4], G.DEFAULT_PARAMS) == nil
	and G.cornerGeometry(pc[1], pc[2], pc[3], G.DEFAULT_PARAMS) ~= nil
	and G.cornerGeometry(pc[3], pc[4], pc[5], G.DEFAULT_PARAMS) ~= nil, "corner: the leads curve, the middle turn does not")
local ps = leadsAt("s-curve", endAt(0, 0, 0), endAt(600, 100, 180), E.LEAD, E.LEAD)
check(d(ps[3], 300, 50) < 1e-9, "s-curve: the middle turn is halfway between the leads")
-- a short corner: each lead stops halfway to the corner
leadsAt("short corner", endAt(0, 0, 0), endAt(30, 60, -90), 15, 30)
-- a short s-curve: each lead a third of the distance between the ends
local short = math.sqrt(60 ^ 2 + 20 ^ 2)
leadsAt("short s-curve", endAt(0, 0, 0), endAt(60, 20, 180), short / 3, short / 3)

local pis, why = E.initialPis(endAt(0, 0, 0), endAt(30, 0, 180))
check(pis == nil and why ~= nil, "ends 30 m apart refused: " .. tostring(why))

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
