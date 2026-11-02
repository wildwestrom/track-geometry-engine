-- Port of the Lean geometry core (TrackGeometry/{Vec,Segment,Path}.lean), which is the spec.
-- Each function keeps the Lean operations in the same order, so results match the Lean RFloat
-- build to the last bits; test/geometry_test.lua checks that against fixtures written by
-- `lake exe fixtures` (Fixtures.lean). Not ported: RMF frames, cant, loop windings.
-- No game API here.

local record Vec
	x : number
	y : number
	z : number
end

local enum Kind
	"straight"
	"arc"
	"in" -- transitionIn: clothoid from straight to the arc's curvature
	"out" -- transitionOut: clothoid from the arc's curvature to straight
end

-- Lean `Segment`. Which fields are set depends on `kind`, as in the Lean constructors:
-- straight: p, q; arc: radius, p, q, v, B, sweep; in/out: radius, p, v, B, len.
local record Segment
	kind : Kind
	radius : number -- unsigned
	p : Vec -- start point
	q : Vec -- end point
	v : Vec -- start tangent
	B : Vec -- binormal of the segment's plane; its orientation carries the turn sense
	sweep : number -- arc central angle
	len : number -- transition length
	opSpeed : number -- design operating speed (m/s)
end

local record DesignParams
	legBudget : number
	minRadius : number
	straightThreshold : number
	maxLateralAccel : number
	maxLateralJerk : number
	maxYawAccel : number
	maxDesignSpeed : number
end

local record CornerGeometry
	uIn : Vec
	uOut : Vec
	binormal : Vec
	sinSigned : number
	cosDelta : number
	turn : number
	tanHalf : number
	delta : number
	shorterLeg : number
	maxBudget : number
	minBudget : number
end

local record CornerLayout
	geometry : CornerGeometry
	budget : number
	entryPoint : Vec
	exitPoint : Vec
end

local record CornerSolution
	entryPoint : Vec
	exitPoint : Vec
	pieces : {Segment}
	opSpeed : number
	radius : number
end

local record Geometry
	Vec : Vec
	Segment : Segment
	DesignParams : DesignParams
	CornerGeometry : CornerGeometry
	CornerLayout : CornerLayout
	CornerSolution : CornerSolution
	DEFAULT_PARAMS : DesignParams

	vec : function(number, number, number) : Vec
	clothoidOffset : function(k0 : number, kp : number, s : number) : number, number
	length : function(Segment) : number
	pointAt : function(Segment, t : number) : Vec
	tangentAt : function(Segment, t : number) : Vec
	headingAt : function(Segment, t : number) : number
	curvatureAt : function(Segment, t : number) : number
	cornerGeometry : function(a : Vec, b : Vec, c : Vec, dp : DesignParams) : CornerGeometry
	cornerLayout : function(a : Vec, b : Vec, c : Vec, dp : DesignParams, override : number) : CornerLayout
	cornerLayouts : function(pts : {Vec}, dp : DesignParams, overrides : {integer : number}) : {integer : CornerLayout}
	solveCorner : function(b : Vec, budget : number, dp : DesignParams, g : CornerGeometry) : CornerSolution
	buildPath : function(pts : {Vec}, dp : DesignParams, overrides : {integer : number}) : {Segment}
	pathLength : function({Segment}) : number
end

local M : Geometry = {}

-- The Lean UI's design parameters (TrackGeometry/UI/Config.lean `designParams`), 1 unit = 1 m.
M.DEFAULT_PARAMS = {
	legBudget = 0.3, minRadius = 100.0, straightThreshold = 0.001,
	maxLateralAccel = 1.2, maxLateralJerk = 0.5, maxYawAccel = 0.2,
	maxDesignSpeed = 83.3333, -- 300 km/h
}

---------------------------------------------------------------------------- Vec.lean

local function vec(x : number, y : number, z : number) : Vec
	return { x = x, y = y, z = z }
end
M.vec = vec

local ZHAT = vec(0, 0, 1)

local function add(v : Vec, w : Vec) : Vec return vec(v.x + w.x, v.y + w.y, v.z + w.z) end
local function sub(v : Vec, w : Vec) : Vec return vec(v.x - w.x, v.y - w.y, v.z - w.z) end
local function scale(r : number, v : Vec) : Vec return vec(r * v.x, r * v.y, r * v.z) end
local function dot(v : Vec, w : Vec) : number return v.x * w.x + v.y * w.y + v.z * w.z end
local function norm(v : Vec) : number return math.sqrt(dot(v, v)) end
local function dist(v : Vec, w : Vec) : number return norm(sub(v, w)) end

local function cross(v : Vec, w : Vec) : Vec
	return vec(v.y * w.z - v.z * w.y, v.z * w.x - v.x * w.z, v.x * w.y - v.y * w.x)
end

-- `v` unchanged when it has zero length.
local function normalize(v : Vec) : Vec
	local n2 = dot(v, v)
	if n2 == 0 then return v end
	return scale(1 / math.sqrt(n2), v)
end

-- Rotate `v` about the unit axis (nx, ny, nz) by `phi` (Rodrigues).
local function rotateAxisC(nx : number, ny : number, nz : number, phi : number, v : Vec) : Vec
	local c, s = math.cos(phi), math.sin(phi)
	local d = nx * v.x + ny * v.y + nz * v.z
	local k = d * (1 - c)
	return vec(c * v.x + s * (ny * v.z - nz * v.y) + k * nx,
		c * v.y + s * (nz * v.x - nx * v.z) + k * ny,
		c * v.z + s * (nx * v.y - ny * v.x) + k * nz)
end

local function abs(x : number) : number
	if x < 0 then return -x end
	return x
end

------------------------------------------------------------------------ Segment.lean

local PANELS = 16 -- clothoidPanels

-- Offset (along, across the start tangent) after arc length `s` of a curve whose heading is
-- k0·u + ½·kp·u², by composite 3-point Gauss–Legendre quadrature.
function M.clothoidOffset(k0 : number, kp : number, s : number) : number, number
	local h = s / PANELS
	local node, wSide, wMid, half = math.sqrt(3 / 5), 5 / 9, 8 / 9, h / 2
	local function heading(u : number) : number return k0 * u + (kp * u * u) / 2 end
	local sumC, sumS = 0.0, 0.0
	for k = 0, PANELS - 1 do
		local m = k * h + half
		local u0, u2 = m - half * node, m + half * node
		sumC = sumC + wSide * math.cos(heading(u0)) + wMid * math.cos(heading(m)) + wSide * math.cos(heading(u2))
		sumS = sumS + wSide * math.sin(heading(u0)) + wMid * math.sin(heading(m)) + wSide * math.sin(heading(u2))
	end
	return half * sumC, half * sumS
end

-- Centre of the circle through `p` with tangent `v` and radius `r`, in the plane with binormal `B`.
local function circleCenter(p : Vec, v : Vec, r : number, B : Vec) : Vec
	return add(p, scale(r / norm(v), cross(B, v)))
end

-- Point at arc length `s` on a curve from `p` with start tangent `v`, curvature linear from k0
-- to k1 over length L, in the plane with binormal `B`.
local function clothoidPoint(p : Vec, v : Vec, k0 : number, k1 : number, L : number, s : number, B : Vec) : Vec
	local xL, yL = M.clothoidOffset(k0, (k1 - k0) / L, s)
	local t = normalize(v)
	local nx = B.y * t.z - B.z * t.y
	local ny = B.z * t.x - B.x * t.z
	local nz = B.x * t.y - B.y * t.x
	return vec(p.x + xL * t.x + yL * nx, p.y + xL * t.y + yL * ny, p.z + xL * t.z + yL * nz)
end

function M.length(seg : Segment) : number
	if seg.kind == "straight" then return dist(seg.p, seg.q) end
	if seg.kind == "arc" then return abs(seg.radius) * abs(seg.sweep) end
	return seg.len
end

function M.pointAt(seg : Segment, t : number) : Vec
	local k = seg.kind
	if k == "straight" then
		local len = dist(seg.p, seg.q)
		local frac = len == 0 and 0 or t / len
		return add(seg.p, scale(frac, sub(seg.q, seg.p)))
	elseif k == "arc" then
		return clothoidPoint(seg.p, seg.v, 1 / seg.radius, 1 / seg.radius, 1, t, seg.B)
	elseif k == "in" then
		return clothoidPoint(seg.p, seg.v, 0, 1 / seg.radius, seg.len, t, seg.B)
	else
		return clothoidPoint(seg.p, seg.v, 1 / seg.radius, 0, seg.len, t, seg.B)
	end
end

-- Running turn angle at arc length `t`.
function M.headingAt(seg : Segment, t : number) : number
	local k, r, len = seg.kind, seg.radius, seg.len
	if k == "straight" then return 0 end
	if k == "arc" then return t / r end
	if k == "in" then return (1 / r) / len * t * t / 2 end
	return t / r - (1 / r) / len * t * t / 2
end

-- Unit tangent at arc length `t`.
function M.tangentAt(seg : Segment, t : number) : Vec
	local straight = seg.kind == "straight"
	local B = normalize(straight and ZHAT or seg.B)
	local dir = straight and sub(seg.q, seg.p) or seg.v
	return rotateAxisC(B.x, B.y, B.z, M.headingAt(seg, t), normalize(dir))
end

-- Unsigned curvature at arc length `t`.
function M.curvatureAt(seg : Segment, t : number) : number
	local k, r, len = seg.kind, seg.radius, seg.len
	if k == "straight" then return 0 end
	if k == "arc" then return 1 / r end
	if k == "in" then return (1 / r) / len * t end
	return 1 / r - (1 / r) / len * t
end

--------------------------------------------------------------------------- Path.lean

-- Directions, turn and budget bounds for the corner at PI `b`; nil when degenerate or straight.
function M.cornerGeometry(a : Vec, b : Vec, c : Vec, dp : DesignParams) : CornerGeometry
	local dIn, dOut = sub(b, a), sub(c, b)
	local nIn, nOut = norm(dIn), norm(dOut)
	if nIn == 0 or nOut == 0 then return nil end
	local uIn, uOut = scale(1 / nIn, dIn), scale(1 / nOut, dOut)
	local cr = cross(uIn, uOut)
	local sinSigned = cr.z
	local sinAbs = norm(cr)
	local cosD = math.max(-1, math.min(1, dot(uIn, uOut)))
	local minor = math.acos(cosD)
	local principal = sinSigned < 0 and -minor or minor
	local selected = sinAbs <= dp.straightThreshold and 0 or principal
	local delta = abs(selected)
	if delta <= dp.straightThreshold then return nil end
	local shorter = math.min(nIn, nOut)
	local hi = shorter
	local tanHalf = math.sin(delta) / (1 + math.cos(delta))
	local lo = math.min(dp.minRadius * abs(tanHalf), hi)
	-- Without windings the turn is never reversed and sinAbs > straightThreshold here, so the
	-- binormal is the leg plane's normal.
	return {
		uIn = uIn, uOut = uOut, binormal = scale(1 / sinAbs, cr), sinSigned = sinSigned,
		cosDelta = cosD, turn = selected, tanHalf = tanHalf, delta = delta,
		shorterLeg = shorter, maxBudget = hi, minBudget = lo,
	}
end

-- The corner's geometry plus its tangent budget: `override` (m) if given, else
-- legBudget × the shorter leg, clamped to the geometry's bounds. The corner alone; on a path,
-- cornerLayouts also keeps it clear of its neighbours.
function M.cornerLayout(a : Vec, b : Vec, c : Vec, dp : DesignParams, override : number) : CornerLayout
	local g = M.cornerGeometry(a, b, c, dp)
	if g == nil then return nil end
	local cand = override or dp.legBudget * g.shorterLeg
	local budget = math.max(g.minBudget, math.min(g.maxBudget, cand))
	return {
		geometry = g, budget = budget,
		entryPoint = sub(b, scale(budget, g.uIn)), exitPoint = add(b, scale(budget, g.uOut)),
	}
end

-- The corners of a PI polyline, by PI index (nil at the ends and at PIs that do not curve).
-- Each corner asks for its budget (override, else auto, within its own legs) and gets it,
-- leaving room for its neighbours. The auto budget is legBudget × the shorter leg, except at a
-- corner next to a path end, which asks for all its room: the whole leg to the end, and on its
-- other leg the leg less the neighbour's own ask when the neighbour curves. Then: a leg whose far end does not curve is the corner's alone; a
-- leg shared with another curve holds both asks when they fit, else is split in proportion;
-- the budget is the lesser of the two legs' shares. maxBudget becomes the room the neighbours
-- leave (an auto end corner leaves room down to its floor, since it gives way) and minBudget the
-- minRadius floor capped to it. See Lean `cornerLayouts`.
function M.cornerLayouts(pts : {Vec}, dp : DesignParams, overrides : {integer : number}) : {integer : CornerLayout}
	local n = #pts
	overrides = overrides or {}
	local geoms : {integer : CornerGeometry} = {}
	-- what each corner asks before the end corners take their room
	local base : {integer : number} = {}
	for i = 2, n - 1 do
		local g = M.cornerGeometry(pts[i - 1], pts[i], pts[i + 1], dp)
		if g ~= nil then
			geoms[i] = g
			local cand = overrides[i] or dp.legBudget * g.shorterLeg
			base[i] = math.max(g.minBudget, math.min(g.maxBudget, cand))
		end
	end
	-- leg k runs from PI k to PI k + 1
	local function legLen(k : integer) : number return dist(pts[k + 1], pts[k]) end
	-- the room on leg k, whose far end is PI j, left by the neighbour's base ask
	local function free(j : integer, k : integer) : number
		if geoms[j] ~= nil then return legLen(k) - base[j] end
		return legLen(k)
	end
	-- an end corner with no override: it takes the room left, so it gives way to a neighbour
	local function autoEnd(i : integer) : boolean return (i == 2 or i == n - 1) and overrides[i] == nil end
	local ask : {integer : number} = {}
	for i, g in pairs(geoms) do
		if autoEnd(i) then
			local cand = math.min(free(i - 1, i - 1), free(i + 1, i))
			ask[i] = math.max(g.minBudget, math.min(g.maxBudget, cand))
		else
			ask[i] = base[i]
		end
	end
	-- what corner i may take of leg k, whose far end is PI j
	local function share(i : integer, j : integer, k : integer) : number
		local len, ai = legLen(k), ask[i]
		if geoms[j] ~= nil then
			local aj = ask[j]
			if ai + aj <= len then return ai end
			return len * ai / (ai + aj)
		end
		return math.min(ai, len)
	end
	local budget : {integer : number} = {}
	for i in pairs(geoms) do budget[i] = math.min(share(i, i - 1, i - 1), share(i, i + 1, i)) end
	-- an auto end corner can shrink to its floor, so it leaves room down to that
	local function room(j : integer, k : integer) : number
		local gj = geoms[j]
		if gj == nil then return legLen(k) end
		return legLen(k) - (autoEnd(j) and gj.minBudget or budget[j])
	end
	local out : {integer : CornerLayout} = {}
	for i, g in pairs(geoms) do
		local hi = math.min(room(i - 1, i - 1), room(i + 1, i))
		local lo = math.min(dp.minRadius * abs(g.tanHalf), hi)
		local g2 : CornerGeometry = {}
		for k, v in pairs(g as {string : any}) do (g2 as {string : any})[k] = v end
		g2.maxBudget, g2.minBudget = hi, lo
		local bud, b = budget[i], pts[i]
		out[i] = { geometry = g2, budget = bud, entryPoint = sub(b, scale(bud, g.uIn)), exitPoint = add(b, scale(bud, g.uOut)) }
	end
	return out
end

-- The curved pieces through the corner at PI `b`: entry clothoid, arc, exit clothoid, or a plain
-- arc when the speed model is off. See Lean `solveCornerWithGeometry`.
function M.solveCorner(b : Vec, budget : number, dp : DesignParams, g : CornerGeometry) : CornerSolution
	local uIn, B = g.uIn, g.binormal
	local entryBase, exitBase = sub(b, scale(budget, uIn)), add(b, scale(budget, g.uOut))
	local tanHalf, delta = g.tanHalf, g.delta
	local function safeDenom(x : number) : number
		local ax = abs(x)
		if ax <= dp.straightThreshold then return dp.straightThreshold end
		return ax
	end
	local aMax, cap = dp.maxLateralAccel, dp.maxDesignSpeed
	local function speedAt(R : number) : number
		local v = math.sqrt(aMax * R)
		if cap > 0 then return math.min(cap, v) end
		return v
	end
	local function lsOf(R : number) : number
		local V = speedAt(R)
		local lsJerk = dp.maxLateralJerk > 0 and (V * V * V) / (R * dp.maxLateralJerk) or 0
		local lsYaw = dp.maxYawAccel > 0 and (V * V) / (R * dp.maxYawAccel) or 0
		return math.max(lsJerk, lsYaw)
	end
	local function radiusOf(th : number) : number
		local Ls1 = 2 * th
		local X1, Y1 = M.clothoidOffset(0, 1 / Ls1, Ls1)
		local P = Y1 - (1 - math.cos(th))
		local K = X1 - math.sin(th)
		return budget / safeDenom((1 + P) * tanHalf + K)
	end
	local function stepTheta(R : number) : number
		return math.min(lsOf(R) / (2 * R), delta / 2)
	end
	local ths = 0.0
	if aMax > 0 then
		local R = budget / safeDenom(tanHalf)
		ths = stepTheta(R)
		for _ = 1, 4 do
			if ths > 0 then
				R = radiusOf(ths)
				ths = stepTheta(R)
			end
		end
	end

	if ths <= 0 then
		local absR = budget / safeDenom(tanHalf)
		local opSpeed = aMax > 0 and speedAt(absR) or 0
		return {
			entryPoint = entryBase, exitPoint = exitBase, opSpeed = opSpeed, radius = absR,
			pieces = { { kind = "arc", radius = absR, p = entryBase, q = exitBase, v = uIn, B = B, sweep = delta, opSpeed = opSpeed } },
		}
	end

	local absR = radiusOf(ths)
	local opSpeed = speedAt(absR)
	local Ls = 2 * absR * ths
	local bx, by, bz = B.x, B.y, B.z
	local ts = entryBase
	local sc = clothoidPoint(ts, uIn, 0, 1 / absR, Ls, Ls, B)
	local tanSC = rotateAxisC(bx, by, bz, ths, uIn)
	local phi = delta - 2 * ths
	local o = circleCenter(sc, tanSC, absR, B)
	local cs = add(o, rotateAxisC(bx, by, bz, phi, sub(sc, o)))
	local tanCS = rotateAxisC(bx, by, bz, phi, tanSC)
	local entrySeg : Segment = { kind = "in", radius = absR, p = ts, v = uIn, B = B, len = Ls, opSpeed = opSpeed }
	local exitSeg : Segment = { kind = "out", radius = absR, p = cs, v = tanCS, B = B, len = Ls, opSpeed = opSpeed }
	local pieces : {Segment}
	if phi <= dp.straightThreshold then
		pieces = { entrySeg, exitSeg }
	else
		pieces = { entrySeg, { kind = "arc", radius = absR, p = sc, q = cs, v = tanSC, B = B, sweep = phi, opSpeed = opSpeed }, exitSeg }
	end
	return { entryPoint = ts, exitPoint = M.pointAt(exitSeg, Ls), pieces = pieces, opSpeed = opSpeed, radius = absR }
end

-- The alignment through PIs `pts`: straights along the legs and a solved corner at each interior
-- PI. `overrides[i]` replaces the auto tangent budget (m) at PI i (legBudget × the shorter leg, or
-- all the room at the first and last corners); cornerLayouts resolves them.
function M.buildPath(pts : {Vec}, dp : DesignParams, overrides : {integer : number}) : {Segment}
	local n = #pts
	if n < 2 then return {} end
	overrides = overrides or {}
	local straightSpeed = dp.maxDesignSpeed > 0 and dp.maxDesignSpeed or 0
	local out : {Segment} = {}
	local cursor = pts[1]
	local layouts = M.cornerLayouts(pts, dp, overrides)
	for i = 2, n - 1 do
		local b = pts[i]
		local layout = layouts[i]
		if layout ~= nil then
			local sol = M.solveCorner(b, layout.budget, dp, layout.geometry)
			out[#out + 1] = { kind = "straight", p = cursor, q = sol.entryPoint, opSpeed = straightSpeed }
			for _, piece in ipairs(sol.pieces) do out[#out + 1] = piece end
			cursor = sol.exitPoint
		end
	end
	out[#out + 1] = { kind = "straight", p = cursor, q = pts[n], opSpeed = straightSpeed }
	return out
end

function M.pathLength(path : {Segment}) : number
	local L = 0.0
	for _, seg in ipairs(path) do L = L + M.length(seg) end
	return L
end

return M
