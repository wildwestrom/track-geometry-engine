-- Offline checks for the sampler (tg_alignment.script.tl) and the shape of the ported paths
-- (tg_geometry.script.tl).
local H = dofile("test/harness.lua")
local G = H.mod("tg_geometry")
local A = H.mod("tg_alignment")

local check = H.check
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

-- A test path: 350 m legs, 40° left turn at the middle PI.
local TURN = math.rad(40)
local pis = { G.vec(0, 0), G.vec(350, 0), G.vec(350 + 350 * math.cos(TURN), 350 * math.sin(TURN)) }
local path = G.buildPath(pis, G.DEFAULT_PARAMS, nil)
local step = 10
local nodes = A.sample(path, step)

-- 1. The path itself: spiral, arc, spiral, joined smoothly.
do
	local kinds = {}
	for i, s in ipairs(path) do kinds[i] = s.kind end
	check(table.concat(kinds, " ") == "straight in arc out straight", "smoke path is " .. table.concat(kinds, " "))
	local worstP, worstT = 0, 0
	-- (zero-length segments, like the straights where the curve fills a leg, have no direction:
	-- skip them, as the sampler does)
	local segs = {}
	for _, seg in ipairs(path) do if G.length(seg) > 1e-6 then segs[#segs + 1] = seg end end
	for i = 1, #segs - 1 do
		local a, b = segs[i], segs[i + 1]
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
	local p = G.buildPath({ G.vec(0, 0), G.vec(300, 0), G.vec(300, 300), G.vec(600, 300) }, dp, nil)
	local zero = false
	for _, seg in ipairs(p) do if G.length(seg) < 1e-6 then zero = true end end
	local ns = A.sample(p, step)
	local shortest = math.huge
	for i = 2, #ns do shortest = math.min(shortest, d2(ns[i], ns[i - 1])) end
	check(zero and shortest >= A.MIN_PIECE,
		string.format("zero-length straight between corners dropped (shortest piece %.3f m)", shortest))
end

-- How far point h is from the path, against a polyline through it every 5 cm (its chords are off
-- the curve by under a micrometre).
local function offPath(path)
	local pts = {}
	for _, seg in ipairs(path) do
		local L = G.length(seg)
		local n = math.max(1, math.ceil(L / 0.05))
		for j = 0, n do pts[#pts + 1] = G.pointAt(seg, L * j / n) end
	end
	return function(h)
		local best = math.huge
		for j = 1, #pts - 1 do
			local p, q = pts[j], pts[j + 1]
			if math.abs(p.x - h.x) < 5 and math.abs(p.y - h.y) < 5 then
				local lx, ly = q.x - p.x, q.y - p.y
				local l2 = lx * lx + ly * ly
				local u = l2 > 0 and math.max(0, math.min(1, ((h.x - p.x) * lx + (h.y - p.y) * ly) / l2)) or 0
				best = math.min(best, (p.x + u * lx - h.x) ^ 2 + (p.y + u * ly - h.y) ^ 2)
			end
		end
		return math.sqrt(best)
	end
end

-- 6. Long pieces (as the ghost builds): a tight 90° corner between 400 m legs, no length limit and
--    at most 15° a piece, with a node at each break. The straights are one piece from break to
--    break, and the Hermite pieces still follow the curve within a millimetre.
do
	local p = G.buildPath({ G.vec(0, 0), G.vec(400, 0), G.vec(400, 400) }, G.DEFAULT_PARAMS, nil)
	local maxTurn, breaks = math.rad(15), { 123.4, 7.5 }
	local ns = A.sample(p, math.huge, maxTurn, breaks)
	local sharpest = 0
	for i = 2, #ns do
		local dh = math.abs(ns[i].heading - ns[i - 1].heading)
		sharpest = math.max(sharpest, math.min(dh, 2 * math.pi - dh))
	end
	check(sharpest <= maxTurn + 1e-9, string.format("pieces turn at most 15° (sharpest %.1f°)", math.deg(sharpest)))
	-- (nodes inside the straights: only the breaks)
	local inside, s0 = 0, 0
	for _, seg in ipairs(p) do
		local L = G.length(seg)
		if seg.kind == "straight" then
			for _, nd in ipairs(ns) do
				if nd.s > s0 + 1e-6 and nd.s < s0 + L - 1e-6 and not (near(nd.s, 7.5, 1e-9) or near(nd.s, 123.4, 1e-9)) then
					inside = inside + 1
				end
			end
		end
		s0 = s0 + L
	end
	check(inside == 0, string.format("straights not cut but at breaks (%d pieces instead of %d)", #ns - 1, #A.sample(p, step) - 1))
	local missing = 0
	for _, b in ipairs(breaks) do
		local found = false
		for _, nd in ipairs(ns) do if near(nd.s, b, 1e-9) then found = true end end
		if not found then missing = missing + 1 end
	end
	check(missing == 0, "a node at every break")
	check(near(ns[#ns].s, G.pathLength(p), 1e-9) and near(ns[#ns].heading, math.pi / 2, 1e-12), "the end node and heading are kept")
	local off, worst, at = offPath(p), 0, 0
	for i = 1, #ns - 1 do
		local a, b = ns[i], ns[i + 1]
		local T = A.tangentLength(a, b)
		for k = 1, 9 do
			local d = off(hermite(a, b, T, k / 10))
			if d > worst then worst, at = d, a.s end
		end
	end
	check(worst < 0.001, string.format("long Hermite pieces within 1 mm of the curve (worst %.3f mm at s = %.0f m)", worst * 1000, at))
end

-- 7. A break just past a segment boundary keeps its node (the boundary's node moves onto it);
--    of two breaks closer than MIN_PIECE, the first keeps its node. No piece is shorter for it.
do
	local p = G.buildPath({ G.vec(0, 0), G.vec(400, 0), G.vec(400, 400) }, G.DEFAULT_PARAMS, nil)
	local first = G.length(p[1]) + G.length(p[2]) -- where the entry spiral meets the arc
	local function has(ns, s)
		for _, nd in ipairs(ns) do if near(nd.s, s, 1e-9) then return true end end
		return false
	end
	local function shortest(ns)
		local m = math.huge
		for i = 2, #ns do m = math.min(m, ns[i].s - ns[i - 1].s) end
		return m
	end
	local ns = A.sample(p, math.huge, math.rad(15), { first + 0.5 })
	check(has(ns, first + 0.5) and not has(ns, first) and shortest(ns) >= A.MIN_PIECE,
		"a break 0.5 m past a segment boundary has the node")
	ns = A.sample(p, math.huge, math.rad(15), { 100, 100.5 })
	check(has(ns, 100) and not has(ns, 100.5) and shortest(ns) >= A.MIN_PIECE,
		"of two breaks 0.5 m apart, the first has the node")
	ns = A.sample(p, math.huge, math.rad(15), { 0.5 })
	check(not has(ns, 0.5) and ns[1].s == 0 and shortest(ns) >= A.MIN_PIECE,
		"a break 0.5 m from the start: the first node stays")
end

H.done()
