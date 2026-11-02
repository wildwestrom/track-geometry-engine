-- Offline checks for the sampler (tg_alignment.script.tl) and the shape of the ported paths
-- (tg_geometry.script.tl). Run from mod/ after check.sh builds .tlpath/:
--   lua test/alignment_test.lua
local tl = require("tl")
tl.loader()
package.path = ".tlpath/?.tl;" .. package.path
local G = require("westrom_track_geometry::/track_geometry/tg_geometry.script.tl")
local A = require("westrom_track_geometry::/track_geometry/tg_alignment.script.tl")

local failures = 0
local function check(ok, what)
	print((ok and "ok   " or "FAIL ") .. what)
	if not ok then failures = failures + 1 end
end
local function near(a, b, tol) return math.abs(a - b) <= tol end
local function d2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

local function hermite(a, b, T, t)
	local t2, t3 = t * t, t * t * t
	local h00, h10, h01, h11 = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2
	return { x = h00 * a.x + h10 * T * math.cos(a.heading) + h01 * b.x + h11 * T * math.cos(b.heading),
		y = h00 * a.y + h10 * T * math.sin(a.heading) + h01 * b.y + h11 * T * math.sin(b.heading) }
end

-- Point at chainage s on a path.
local function pointAtS(path, s)
	for _, seg in ipairs(path) do
		local len = G.length(seg)
		if s <= len then return G.pointAt(seg, s) end
		s = s - len
	end
end

-- The engine's smoke-test path: 350 m legs, 40° left turn at the middle PI.
local TURN = math.rad(40)
local pis = { G.vec(0, 0, 0), G.vec(350, 0, 0), G.vec(350 + 350 * math.cos(TURN), 350 * math.sin(TURN), 0) }
local path = G.buildPath(pis, G.DEFAULT_PARAMS, nil)
local step = 10
local nodes = A.sample(path, step)

-- 1. The path itself: spiral, arc, spiral, joined smoothly.
do
	local kinds = {}
	for i, s in ipairs(path) do kinds[i] = s.kind end
	check(table.concat(kinds, " ") == "straight in arc out straight", "smoke path is " .. table.concat(kinds, " "))
	local worstP, worstT = 0, 0
	for i = 1, #path - 1 do
		local a, b = path[i], path[i + 1]
		local L = G.length(a)
		local pa, pb, ta, tb = G.pointAt(a, L), G.pointAt(b, 0), G.tangentAt(a, L), G.tangentAt(b, 0)
		worstP = math.max(worstP, d2(pa, pb))
		worstT = math.max(worstT, math.sqrt((ta.x - tb.x) ^ 2 + (ta.y - tb.y) ^ 2))
	end
	check(worstP < 1e-6 and worstT < 1e-9,
		string.format("segments join in position (%.1g m) and tangent (%.1g)", worstP, worstT))
	check(near(G.curvatureAt(path[2], G.length(path[2])), 1 / path[3].radius, 1e-15)
		and near(G.curvatureAt(path[4], 0), 1 / path[3].radius, 1e-15), "curvature continuous into and out of the arc")
end

-- 2. The entry spiral's end matches the clothoid series x = L(1 - L²/40R² + L⁴/3456R⁴),
--    y = L²/6R (1 - L²/56R² + L⁴/7040R⁴), in the frame of its start tangent.
do
	local sp = path[2]
	local L, R = sp.len, sp.radius
	local p0, p1 = G.pointAt(sp, 0), G.pointAt(sp, L)
	local u = G.tangentAt(sp, 0)
	local dx, dy = p1.x - p0.x, p1.y - p0.y
	local along, across = dx * u.x + dy * u.y, -dx * u.y + dy * u.x
	local q = L * L / (R * R)
	local x = L * (1 - q / 40 + q * q / 3456)
	local y = L * L / (6 * R) * (1 - q / 56 + q * q / 7040)
	check(near(along, x, 1e-6) and near(across, y, 1e-6),
		string.format("spiral end matches the clothoid series (%.6f, %.6f) vs (%.6f, %.6f), L = %.2f, R = %.2f", along, across, x, y, L, R))
end

-- 3. The sampled nodes: sound, the right ends, pieces between MIN_PIECE and step.
do
	local bad, shortest, longest = false, math.huge, 0
	for i, nd in ipairs(nodes) do
		for _, v in ipairs({ nd.x, nd.y, nd.heading, nd.k }) do
			if v ~= v or v == math.huge or v == -math.huge then bad = true end
		end
		if i > 1 then
			local d = d2(nd, nodes[i - 1])
			shortest, longest = math.min(shortest, d), math.max(longest, d)
		end
	end
	local first, last = nodes[1], nodes[#nodes]
	check(not bad, "no NaN or infinite values")
	check(shortest >= A.MIN_PIECE, string.format("no piece shorter than %g m (shortest %.3f m)", A.MIN_PIECE, shortest))
	check(longest <= step + 1e-9, string.format("no piece longer than %d m (longest %.3f m)", step, longest))
	check(near(last.s, G.pathLength(path), 1e-9), string.format("chainage reaches the path length %.3f m", last.s))
	check(d2(first, pis[1]) < 1e-9 and d2(last, pis[3]) < 1e-9, "first and last nodes on the end PIs")
	check(near(first.heading, 0, 1e-12) and near(last.heading, TURN, 1e-12), "end headings along the first and last legs")
	local s, missing = 0, 0
	for _, seg in ipairs(path) do
		s = s + G.length(seg)
		local found = false
		for _, nd in ipairs(nodes) do if near(nd.s, s, 1e-9) then found = true end end
		if not found then missing = missing + 1 end
	end
	check(missing == 0, "a node at every segment boundary")
end

-- 4. A Hermite piece with these tangents stays close to the true curve at its middle.
do
	local worst, at = 0, 0
	for i = 1, #nodes - 1 do
		local a, b = nodes[i], nodes[i + 1]
		local d = d2(hermite(a, b, A.tangentLength(a, b), 0.5), pointAtS(path, (a.s + b.s) / 2))
		if d > worst then worst, at = d, a.s end
	end
	check(worst < 0.005, string.format("Hermite midpoints within 5 mm of the curve (worst %.2f mm at s = %.0f m)", worst * 1000, at))
end

-- 5. Two corners that take half of their shared leg each meet with a zero-length straight, which
--    the sampler drops instead of making a zero-length piece.
do
	local dp = {}
	for k, v in pairs(G.DEFAULT_PARAMS) do dp[k] = v end
	dp.legBudget = 0.5
	local p = G.buildPath({ G.vec(0, 0, 0), G.vec(300, 0, 0), G.vec(300, 300, 0), G.vec(600, 300, 0) }, dp, nil)
	local zero = false
	for _, seg in ipairs(p) do if G.length(seg) < 1e-6 then zero = true end end
	local ns = A.sample(p, step)
	local shortest = math.huge
	for i = 2, #ns do shortest = math.min(shortest, d2(ns[i], ns[i - 1])) end
	check(zero and shortest >= A.MIN_PIECE,
		string.format("zero-length straight between corners dropped (shortest piece %.3f m)", shortest))
end

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
