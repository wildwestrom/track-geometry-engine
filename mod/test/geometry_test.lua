-- Checks the Teal port (tg_geometry.script.tl) against the Lean core, using the fixtures that
-- `lake exe fixtures` writes to test/fixtures.lua.
local H = dofile("test/harness.lua")
local G = H.mod("tg_geometry")
local fixtures = dofile("test/fixtures.lua")

local TOL = 1e-9 -- m, rad, 1/m, m/s

local check = H.check

-- IEEE-754 double from its 16-digit hex bit pattern (Lua 5.2 has no string.unpack).
local ldexp = math.ldexp or function(m, e) return m * 2.0 ^ e end -- gone in 5.3+; exact either way
local function f64(h)
	local hi, lo = tonumber(h:sub(1, 8), 16), tonumber(h:sub(9, 16), 16)
	local sign = 1
	if hi >= 0x80000000 then sign, hi = -1, hi - 0x80000000 end
	local e, m = math.floor(hi / 0x100000), (hi % 0x100000) * 2 ^ 32 + lo
	if e == 0x7ff then return m == 0 and sign * math.huge or 0 / 0 end
	if e == 0 then return sign * ldexp(m, -1074) end
	return sign * ldexp(m + 2 ^ 52, e - 1075)
end

for _, fx in ipairs(fixtures) do
	local dp = {}
	for k, v in pairs(fx.params) do dp[k] = f64(v) end
	local pts = {}
	for i, p in ipairs(fx.pis) do pts[i] = G.vec(f64(p[1]), f64(p[2])) end
	local overrides = {}
	for i, v in pairs(fx.overrides) do overrides[i] = f64(v) end
	local path = G.buildPath(pts, dp, overrides)

	local worst, worstWhat, values, exact = 0, "", 0, 0
	local function cmp(got, want, what)
		values = values + 1
		local d = math.abs(got - want)
		if got == want then exact = exact + 1 end
		if not (d <= worst) then worst, worstWhat = d, what end -- `not <=` catches NaN
	end

	local kindsOk = #path == #fx.segments
	for i, want in ipairs(fx.segments) do
		local seg = path[i]
		if seg == nil or seg.kind ~= want.kind then kindsOk = false; break end
		local name = string.format("segment %d (%s)", i, want.kind)
		cmp(G.length(seg), f64(want.length), name .. " length")
		cmp(seg.radius or 0, f64(want.radius), name .. " radius")
		cmp(seg.opSpeed, f64(want.opSpeed), name .. " opSpeed")
		for _, s in ipairs(want.samples) do
			local t = f64(s.t)
			local p, tan = G.pointAt(seg, t), G.tangentAt(seg, t)
			local at = string.format("%s at t = %.3f", name, t)
			cmp(p.x, f64(s.x), at .. " x"); cmp(p.y, f64(s.y), at .. " y")
			cmp(tan.x, f64(s.tx), at .. " tx"); cmp(tan.y, f64(s.ty), at .. " ty")
			cmp(G.curvatureAt(seg, t), f64(s.k), at .. " curvature")
		end
	end
	if kindsOk then cmp(G.pathLength(path), f64(fx.length), "path length") end

	local kinds = {}
	for i, s in ipairs(path) do kinds[i] = s.kind end
	check(kindsOk, string.format("%s: segments %s", fx.name, table.concat(kinds, " ")))
	check(kindsOk and worst <= TOL, string.format("%s: %d values, %d bit-exact, worst diff %.3g%s",
		fx.name, values, exact, worst, worst > 0 and (" (" .. worstWhat .. ")") or ""))
end

-- a path's curve pieces say which corner they are the curve of
local cornerPath = G.buildPath({ G.vec(0, 0), G.vec(1000, 0), G.vec(1000, 1000), G.vec(2000, 1000) }, G.DEFAULT_PARAMS, {})
local corners, straightsPlain = {}, true
for _, seg in ipairs(cornerPath) do
	if seg.kind == "straight" then straightsPlain = straightsPlain and seg.corner == nil
	else corners[seg.corner or 0] = true end
end
check(straightsPlain and corners[2] and corners[3] and not corners[0], "corner: curve pieces carry their corner's index, straights none")

-- pullback inverts solveCornerParams, and signedCurvatureAt / circleCenter respect TurnDir
do
	local gL = G.cornerGeometry(G.vec(0, 0), G.vec(400, 0), G.vec(700, 300), G.DEFAULT_PARAMS)
	local cp = G.solveCornerParams(200, gL.tanHalf, gL.delta, G.DEFAULT_PARAMS)
	local pb = G.pullback(G.DEFAULT_PARAMS, gL.tanHalf, gL.delta, cp.radius)
	check(math.abs(pb - 200) < 1e-9, string.format("pullback inverts solveCornerParams (diff %.3g)", math.abs(pb - 200)))

	local leftPath = G.buildPath({ G.vec(0, 0), G.vec(400, 0), G.vec(700, 300) }, G.DEFAULT_PARAMS, {})
	local rightPath = G.buildPath({ G.vec(0, 0), G.vec(400, 0), G.vec(700, -300) }, G.DEFAULT_PARAMS, {})
	local leftArc, rightArc = leftPath[3], rightPath[3]
	check(G.signedCurvatureAt(leftArc, 0) > 0 and G.signedCurvatureAt(rightArc, 0) < 0,
		"signedCurvatureAt: positive on left turns, negative on right turns")
	local cL = G.circleCenter(G.vec(0, 0), G.vec(1, 0), 100, "left")
	local cR = G.circleCenter(G.vec(0, 0), G.vec(1, 0), 100, "right")
	check(math.abs(cL.x) < 1e-12 and math.abs(cL.y - 100) < 1e-12 and math.abs(cR.x) < 1e-12 and math.abs(cR.y + 100) < 1e-12,
		"circleCenter: left is +y, right is -y from +x tangent")
end

H.done()
