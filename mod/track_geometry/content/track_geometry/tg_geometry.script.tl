-- Port of the 2D Lean geometry core (TrackGeometry/{Clothoid,Design,Planar}.lean), which is the
-- spec. Each function keeps the Lean operations in the same order, so results match the Lean
-- RFloat build to the last bits; test/geometry_test.lua checks that against fixtures written by
-- `lake exe fixtures` (Fixtures.lean).
-- No game API here.

local record Vec
	x : number
	y : number
end

local enum TurnDir
	"left"
	"right"
end

local enum Kind
	"straight"
	"arc"
	"in" -- transitionIn: clothoid from straight to the arc's curvature
	"out" -- transitionOut: clothoid from the arc's curvature to straight
end

-- Lean `Segment2D`. Which fields are set depends on `kind`, as in the Lean constructors:
-- straight: p, q; arc: radius, p, v, dir, sweep; in/out: radius, p, v, dir, len.
local record Segment
	kind : Kind
	radius : number -- unsigned
	p : Vec -- start point
	q : Vec -- end point (straights only)
	v : Vec -- start tangent (curved segments only)
	dir : TurnDir -- turn handedness (curved segments only)
	sweep : number -- arc central angle
	len : number -- transition length
	opSpeed : number -- design operating speed (m/s)
	corner : integer -- the corner (index in the path's points) a curve piece belongs to; nil on straights
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

local record CornerParams
	radius : number
	spiralAngle : number
	spiralLength : number
	arcAngle : number
	opSpeed : number
end

local record CornerGeometry
	uIn : Vec
	uOut : Vec
	turnDir : TurnDir
	sinSigned : number
	cosDelta : number
	tanHalf : number
	delta : number
	shorterLeg : number
	floorBudget : number
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
	TurnDir : TurnDir
	Segment : Segment
	DesignParams : DesignParams
	CornerParams : CornerParams
	CornerGeometry : CornerGeometry
	CornerLayout : CornerLayout
	CornerSolution : CornerSolution
	DEFAULT_PARAMS : DesignParams

	vec : function(number, number) : Vec
	clothoidOffset : function(k0 : number, kp : number, s : number) : number, number
	circleCenter : function(p : Vec, v : Vec, r : number, dir : TurnDir) : Vec
	length : function(Segment) : number
	pointAt : function(Segment, t : number) : Vec
	tangentAt : function(Segment, t : number) : Vec
	headingAt : function(Segment, t : number) : number
	curvatureAt : function(Segment, t : number) : number
	signedCurvatureAt : function(Segment, t : number) : number
	pullback : function(dp : DesignParams, tanHalf : number, delta : number, R : number) : number
	solveCornerParams : function(budget : number, tanHalf : number, delta : number, dp : DesignParams) : CornerParams
	cornerGeometry : function(a : Vec, b : Vec, c : Vec, dp : DesignParams) : CornerGeometry
	cornerLayout : function(a : Vec, b : Vec, c : Vec, dp : DesignParams, override : number) : CornerLayout
	cornerLayouts : function(pts : {Vec}, dp : DesignParams, overrides : {integer : number}) : {integer : CornerLayout}
	solveCorner : function(b : Vec, budget : number, dp : DesignParams, g : CornerGeometry) : CornerSolution
	buildPath : function(pts : {Vec}, dp : DesignParams, overrides : {integer : number}) : {Segment}
	pathLength : function({Segment}) : number
end

local M : Geometry = {}

-- The Lean UI's design parameters (TrackGeometry/UI/Config.lean), 1 unit = 1 m.
M.DEFAULT_PARAMS = {
	legBudget = 0.3, minRadius = 40.0, straightThreshold = 0.001,
	maxLateralAccel = 1.2, maxLateralJerk = 0.5, maxYawAccel = 0.2,
	maxDesignSpeed = 83.3333, -- 300 km/h
}

------------------------------------------------------------------------- Planar.lean (Vec2)

local function vec(x : number, y : number) : Vec
	return { x = x, y = y }
end
M.vec = vec

local function add(v : Vec, w : Vec) : Vec return vec(v.x + w.x, v.y + w.y) end
local function sub(v : Vec, w : Vec) : Vec return vec(v.x - w.x, v.y - w.y) end
local function scale(r : number, v : Vec) : Vec return vec(r * v.x, r * v.y) end
local function dot(v : Vec, w : Vec) : number return v.x * w.x + v.y * w.y end
local function cross(v : Vec, w : Vec) : number return v.x * w.y - v.y * w.x end
local function norm(v : Vec) : number return math.sqrt(dot(v, v)) end
local function dist(v : Vec, w : Vec) : number return norm(sub(v, w)) end

-- `v` unchanged when it has zero length.
local function normalize(v : Vec) : Vec
	local n2 = dot(v, v)
	if n2 == 0 then return v end
	return scale(1 / math.sqrt(n2), v)
end

local function rotate(phi : number, v : Vec) : Vec
	local c, s = math.cos(phi), math.sin(phi)
	return vec(c * v.x - s * v.y, s * v.x + c * v.y)
end

local function turnSign(dir : TurnDir) : number
	return dir == "left" and 1 or -1
end

local function turnNormal(dir : TurnDir, v : Vec) : Vec
	if dir == "left" then return vec(-v.y, v.x) end
	return vec(v.y, -v.x)
end

local function turnRotate(dir : TurnDir, phi : number, v : Vec) : Vec
	return rotate(turnSign(dir) * phi, v)
end

local function abs(x : number) : number
	if x < 0 then return -x end
	return x
end

---------------------------------------------------------------------- Clothoid.lean

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

-- Shift (P, K) of a unit clothoid of spiral angle theta > 0. See Lean `clothoidShift`.
local function clothoidShift(theta : number) : number, number
	local Ls1 = 2 * theta
	local X1, Y1 = M.clothoidOffset(0, 1 / Ls1, Ls1)
	return Y1 - (1 - math.cos(theta)), X1 - math.sin(theta)
end

------------------------------------------------------------------- Planar.lean (Segment2D)

-- Centre of the osculating circle through `p` with tangent `v`, radius `r`, turning `dir`.
function M.circleCenter(p : Vec, v : Vec, r : number, dir : TurnDir) : Vec
	local nUnit = turnNormal(dir, normalize(v))
	return vec(p.x + r * nUnit.x, p.y + r * nUnit.y)
end

-- Place a local offset (xL along start tangent v, yL along inward normal for dir) at world point p.
local function placeLocal(p : Vec, v : Vec, dir : TurnDir, xL : number, yL : number) : Vec
	local vUnit = normalize(v)
	local nUnit = turnNormal(dir, vUnit)
	return vec(p.x + xL * vUnit.x + yL * nUnit.x, p.y + xL * vUnit.y + yL * nUnit.y)
end

-- Point at arc length `s` on a 2D clothoid from `p` with start tangent `v`, turning `dir`,
-- curvature linear from k0 to k1 over length L. See Lean `clothoidPoint2D`.
local function clothoidPoint(p : Vec, v : Vec, dir : TurnDir, k0 : number, k1 : number, L : number, s : number) : Vec
	local xL, yL = M.clothoidOffset(k0, (k1 - k0) / L, s)
	return placeLocal(p, v, dir, xL, yL)
end

function M.length(seg : Segment) : number
	if seg.kind == "straight" then return dist(seg.p, seg.q) end
	if seg.kind == "arc" then return abs(seg.radius * seg.sweep) end
	return seg.len
end

function M.pointAt(seg : Segment, t : number) : Vec
	local k = seg.kind
	if k == "straight" then
		local len = dist(seg.p, seg.q)
		local frac = len == 0 and 0 or t / len
		return add(seg.p, scale(frac, sub(seg.q, seg.p)))
	elseif k == "arc" then
		local r = seg.radius
		local th = t / r
		return placeLocal(seg.p, seg.v, seg.dir, r * math.sin(th), r * (1 - math.cos(th)))
	elseif k == "in" then
		return clothoidPoint(seg.p, seg.v, seg.dir, 0, 1 / seg.radius, seg.len, t)
	else
		return clothoidPoint(seg.p, seg.v, seg.dir, 1 / seg.radius, 0, seg.len, t)
	end
end

-- Running unsigned turn angle at arc length `t`.
function M.headingAt(seg : Segment, t : number) : number
	local k, r, len = seg.kind, seg.radius, seg.len
	if k == "straight" then return 0 end
	if k == "arc" then return t / r end
	if k == "in" then return (1 / r) / len * t * t / 2 end
	return t / r - (1 / r) / len * t * t / 2
end

-- Unit tangent at arc length `t`.
function M.tangentAt(seg : Segment, t : number) : Vec
	local k = seg.kind
	if k == "straight" then return normalize(sub(seg.q, seg.p)) end
	return turnRotate(seg.dir, M.headingAt(seg, t), normalize(seg.v))
end

-- Unsigned curvature at arc length `t`.
function M.curvatureAt(seg : Segment, t : number) : number
	local k, r, len = seg.kind, seg.radius, seg.len
	if k == "straight" then return 0 end
	if k == "arc" then return 1 / r end
	if k == "in" then return (1 / r) / len * t end
	return 1 / r - (1 / r) / len * t
end

-- Signed curvature at arc length `t` (positive on left turns, negative on right turns).
function M.signedCurvatureAt(seg : Segment, t : number) : number
	if seg.kind == "straight" then return 0 end
	return turnSign(seg.dir) * M.curvatureAt(seg, t)
end

------------------------------------------------------------------------ Design.lean

local BISECTION_STEPS = 52 -- bisectionSteps

-- Operating speed on an arc of radius R: sqrt(a_max·R), capped at the design speed.
-- See Lean `SpeedModel.speedAt`.
local function speedAt(dp : DesignParams, R : number) : number
	if dp.maxLateralAccel <= 0 or R <= 0 then return 0 end
	local v = math.sqrt(dp.maxLateralAccel * R)
	if dp.maxDesignSpeed > 0 then return math.min(dp.maxDesignSpeed, v) end
	return v
end

-- Transition length on an arc of radius R: the larger of the jerk- and yaw-limited lengths.
-- See Lean `SpeedModel.transitionLength`.
local function transitionLength(dp : DesignParams, R : number) : number
	if dp.maxLateralAccel <= 0 or R <= 0 then return 0 end
	local V = speedAt(dp, R)
	local lsJerk = dp.maxLateralJerk > 0 and (V * V * V) / (R * dp.maxLateralJerk) or 0
	local lsYaw = dp.maxYawAccel > 0 and (V * V) / (R * dp.maxYawAccel) or 0
	return math.max(lsJerk, lsYaw)
end

-- Spiral angle Ls/(2R) of a corner of turn delta on an arc of radius R, clamped to delta/2.
-- See Lean `SpeedModel.spiralAngle`.
local function spiralAngle(dp : DesignParams, R : number, delta : number) : number
	if dp.maxLateralAccel <= 0 or R <= 0 then return 0 end
	return math.min(transitionLength(dp, R) / (2 * R), delta / 2)
end

-- Tangent pullback consumed by a corner of arc radius R. See Lean `SpeedModel.pullback`.
function M.pullback(dp : DesignParams, tanHalf : number, delta : number, R : number) : number
	if R <= 0 then return 0 end
	local th = dp.maxLateralAccel <= 0 and 0 or spiralAngle(dp, R, delta)
	if th <= 0 then return R * tanHalf end
	local P, K = clothoidShift(th)
	return R * ((1 + P) * tanHalf + K)
end

-- Minimum tangent budget needed to achieve arc radius minRadius, transitions included; 0 when
-- the floor is off. See Lean `radiusFloorBudget`.
local function radiusFloorBudget(dp : DesignParams, tanHalf : number, delta : number) : number
	return abs(M.pullback(dp, tanHalf, delta, dp.minRadius))
end

-- Solve scalar corner parameters for a standard 2D corner (tanHalf > 0) by 52-step bracketed
-- bisection with the R_cap regime split. See Lean `solveCornerParamsBisect`.
function M.solveCornerParams(budget : number, tanHalf : number, delta : number, dp : DesignParams) : CornerParams
	if dp.maxLateralAccel <= 0 then
		local R = budget / tanHalf
		return { radius = R, spiralAngle = 0, spiralLength = 0, arcAngle = delta, opSpeed = 0 }
	elseif budget <= 0 then
		return { radius = 0, spiralAngle = 0, spiralLength = 0, arcAngle = delta, opSpeed = 0 }
	end
	local rFillet = budget / tanHalf
	local lo, hi : number, number = 0.0, rFillet
	if dp.maxDesignSpeed > 0 then
		local rCap = dp.maxDesignSpeed * dp.maxDesignSpeed / dp.maxLateralAccel
		if M.pullback(dp, tanHalf, delta, rCap) >= budget then
			lo, hi = 0.0, math.min(rCap, rFillet)
		else
			lo, hi = rCap, rFillet
		end
	end
	for _ = 1, BISECTION_STEPS do
		local mid = (lo + hi) / 2
		if M.pullback(dp, tanHalf, delta, mid) <= budget then lo = mid else hi = mid end
	end
	local R = (lo + hi) / 2
	local ths = spiralAngle(dp, R, delta)
	local opSpeed = speedAt(dp, R)
	if ths <= 0 then
		return { radius = R, spiralAngle = 0, spiralLength = 0, arcAngle = delta, opSpeed = opSpeed }
	end
	local Ls = 2 * R * ths
	local phi = delta - 2 * ths
	return { radius = R, spiralAngle = ths, spiralLength = Ls, arcAngle = phi, opSpeed = opSpeed }
end

-- Shared-leg budget pipeline (Lean `desiredBudgets`, `resolveSharedLegs`, `cornerDragBounds`).
local function isAutoEndCorner(n : integer, i : integer, overrides : {integer : number}) : boolean
	return (i == 2 or i == n - 1) and overrides[i] == nil
end

local function desiredBudgets(n : integer, legLengths : {number}, geoms : {integer : CornerGeometry}, dp : DesignParams, overrides : {integer : number}) : {integer : number}
	local function clampAsk(g : CornerGeometry, cand : number) : number
		local lo = math.min(g.floorBudget, g.shorterLeg)
		return math.max(lo, math.min(g.shorterLeg, cand))
	end
	local base : {integer : number} = {}
	for i, g in pairs(geoms) do
		base[i] = clampAsk(g, overrides[i] or dp.legBudget * g.shorterLeg)
	end
	local function free(j : integer, k : integer) : number
		local len = legLengths[k] or 0
		if geoms[j] ~= nil then return len - base[j] end
		return len
	end
	local asks : {integer : number} = {}
	for i, g in pairs(geoms) do
		if isAutoEndCorner(n, i, overrides) then
			asks[i] = clampAsk(g, math.min(free(i - 1, i - 1), free(i + 1, i)))
		else
			asks[i] = base[i]
		end
	end
	return asks
end

local function resolveSharedLegs(legLengths : {number}, asks : {integer : number}) : {integer : number}
	local function share(ai : number, j : integer, k : integer) : number
		local len = legLengths[k] or 0
		local aj = asks[j]
		if aj ~= nil then
			if ai + aj <= len then return ai end
			return len * ai / (ai + aj)
		end
		return math.min(ai, len)
	end
	local budgets : {integer : number} = {}
	for i, ai in pairs(asks) do
		budgets[i] = math.min(share(ai, i - 1, i - 1), share(ai, i + 1, i))
	end
	return budgets
end

------------------------------------------------------------------ Planar.lean (corners & path)

-- Directions, turn handedness and floor budget for the 2D corner at PI `b`; nil when degenerate,
-- near-straight, or a 180-degree reversal. See Lean `cornerGeometry2D`.
function M.cornerGeometry(a : Vec, b : Vec, c : Vec, dp : DesignParams) : CornerGeometry
	local dIn, dOut = sub(b, a), sub(c, b)
	local nIn, nOut = norm(dIn), norm(dOut)
	if nIn == 0 or nOut == 0 then return nil end
	local uIn, uOut = scale(1 / nIn, dIn), scale(1 / nOut, dOut)
	local sinSigned = cross(uIn, uOut)
	local sinAbs = abs(sinSigned)
	local cosD = math.max(-1, math.min(1, dot(uIn, uOut)))
	local delta = math.acos(cosD)
	if sinAbs <= dp.straightThreshold or delta <= dp.straightThreshold then return nil end
	local dir : TurnDir = sinSigned < 0 and "right" or "left"
	local shorter = math.min(nIn, nOut)
	local tanHalf = math.sin(delta) / (1 + math.cos(delta))
	local floor = radiusFloorBudget(dp, tanHalf, delta)
	return {
		uIn = uIn, uOut = uOut, turnDir = dir, sinSigned = sinSigned,
		cosDelta = cosD, tanHalf = tanHalf, delta = delta,
		shorterLeg = shorter, floorBudget = floor,
		maxBudget = shorter, minBudget = math.min(floor, shorter),
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

-- Polyline leg lengths, interior corner geometries, and resolved non-overlapping budgets.
local function resolvePathBudgets(pts : {Vec}, dp : DesignParams, overrides : {integer : number}) : {number}, {integer : CornerGeometry}, {integer : number}
	local n = #pts
	local legLengths : {number} = {}
	for k = 1, n - 1 do legLengths[k] = dist(pts[k + 1], pts[k]) end
	local geoms : {integer : CornerGeometry} = {}
	for i = 2, n - 1 do
		local g = M.cornerGeometry(pts[i - 1], pts[i], pts[i + 1], dp)
		if g ~= nil then geoms[i] = g end
	end
	local asks = desiredBudgets(n, legLengths, geoms, dp, overrides)
	return legLengths, geoms, resolveSharedLegs(legLengths, asks)
end

-- The corners of a PI polyline, by PI index (nil at the ends and at PIs that do not curve),
-- with resolved budgets and interactive drag bounds (`cornerDragBounds`).
function M.cornerLayouts(pts : {Vec}, dp : DesignParams, overrides : {integer : number}) : {integer : CornerLayout}
	local n = #pts
	overrides = overrides or {}
	local legLengths, geoms, budgets = resolvePathBudgets(pts, dp, overrides)
	-- an auto end corner can shrink to its floor, so it leaves room down to that (Lean `cornerDragBounds`)
	local function room(j : integer, k : integer) : number
		local len = legLengths[k] or 0
		local gj = geoms[j]
		if gj == nil then return len end
		local used = isAutoEndCorner(n, j, overrides) and math.min(gj.floorBudget, gj.shorterLeg) or (budgets[j] or 0)
		return len - used
	end
	local out : {integer : CornerLayout} = {}
	for i, g in pairs(geoms) do
		local hi = math.min(room(i - 1, i - 1), room(i + 1, i))
		local lo = math.min(g.floorBudget, hi)
		local g2 : CornerGeometry = {
			uIn = g.uIn, uOut = g.uOut, turnDir = g.turnDir, sinSigned = g.sinSigned,
			cosDelta = g.cosDelta, tanHalf = g.tanHalf, delta = g.delta,
			shorterLeg = g.shorterLeg, floorBudget = g.floorBudget,
			maxBudget = hi, minBudget = lo,
		}
		local bud, b = budgets[i], pts[i]
		out[i] = { geometry = g2, budget = bud, entryPoint = sub(b, scale(bud, g.uIn)), exitPoint = add(b, scale(bud, g.uOut)) }
	end
	return out
end

-- Construct the 2D segments for a corner from solved scalar CornerParams. See Lean `buildCorner2D`.
local function buildCorner(b : Vec, budget : number, g : CornerGeometry, cp : CornerParams, straightThreshold : number) : CornerSolution
	local uIn, dir = g.uIn, g.turnDir
	local entryBase = sub(b, scale(budget, uIn))
	if cp.spiralAngle <= 0 then
		local absR = cp.radius
		local arcSeg : Segment = { kind = "arc", radius = absR, p = entryBase, v = uIn, dir = dir, sweep = cp.arcAngle, opSpeed = cp.opSpeed }
		local pt = M.pointAt(arcSeg, M.length(arcSeg))
		return { entryPoint = entryBase, exitPoint = pt, opSpeed = cp.opSpeed, radius = absR, pieces = { arcSeg } }
	end
	local absR, ths, Ls, phi, opSpeed = cp.radius, cp.spiralAngle, cp.spiralLength, cp.arcAngle, cp.opSpeed
	local ts = entryBase
	local sc = clothoidPoint(ts, uIn, dir, 0, 1 / absR, Ls, Ls)
	local tanSC = turnRotate(dir, ths, uIn)
	local entrySeg : Segment = { kind = "in", radius = absR, p = ts, v = uIn, dir = dir, len = Ls, opSpeed = opSpeed }
	if phi <= straightThreshold then
		local exitSeg : Segment = { kind = "out", radius = absR, p = sc, v = tanSC, dir = dir, len = Ls, opSpeed = opSpeed }
		return { entryPoint = ts, exitPoint = M.pointAt(exitSeg, Ls), pieces = { entrySeg, exitSeg }, opSpeed = opSpeed, radius = absR }
	end
	local arcSeg : Segment = { kind = "arc", radius = absR, p = sc, v = tanSC, dir = dir, sweep = phi, opSpeed = opSpeed }
	local cs = M.pointAt(arcSeg, M.length(arcSeg))
	local tanCS = turnRotate(dir, phi, tanSC)
	local exitSeg : Segment = { kind = "out", radius = absR, p = cs, v = tanCS, dir = dir, len = Ls, opSpeed = opSpeed }
	return { entryPoint = ts, exitPoint = M.pointAt(exitSeg, Ls), pieces = { entrySeg, arcSeg, exitSeg }, opSpeed = opSpeed, radius = absR }
end

-- The curved pieces through the corner at PI `b`: entry clothoid, arc, exit clothoid, or a plain
-- arc when the speed model is off. See Lean `solveCornerWithGeometry2D`.
function M.solveCorner(b : Vec, budget : number, dp : DesignParams, g : CornerGeometry) : CornerSolution
	local cp = M.solveCornerParams(budget, g.tanHalf, g.delta, dp)
	return buildCorner(b, budget, g, cp, dp.straightThreshold)
end

-- The 2D horizontal alignment through PIs `pts`: straights along the legs and a solved corner at
-- each interior PI. `overrides[i]` replaces the auto tangent budget (m) at PI i. See Lean `buildPath2D`.
function M.buildPath(pts : {Vec}, dp : DesignParams, overrides : {integer : number}) : {Segment}
	local n = #pts
	if n < 2 then return {} end
	overrides = overrides or {}
	local straightSpeed = dp.maxDesignSpeed > 0 and dp.maxDesignSpeed or 0
	local _, geoms, budgets = resolvePathBudgets(pts, dp, overrides)
	local out : {Segment} = {}
	local cursor = pts[1]
	for i = 2, n - 1 do
		local g, bud = geoms[i], budgets[i]
		if g ~= nil and bud ~= nil then
			local sol = M.solveCorner(pts[i], bud, dp, g)
			out[#out + 1] = { kind = "straight", p = cursor, q = sol.entryPoint, opSpeed = straightSpeed }
			for _, piece in ipairs(sol.pieces) do
				piece.corner = i
				out[#out + 1] = piece
			end
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
