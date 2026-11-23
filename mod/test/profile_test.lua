-- Offline checks for the vertical profile core (tg_profile.script.tl) against the Lean core
-- fixtures written by `lake exe fixtures` (Fixtures.lean), plus mod-facing helpers.
local H = dofile("test/harness.lua")
local G = H.mod("tg_geometry")
local P = H.mod("tg_profile")
local fixtures = dofile("test/fixtures.lua")

local check = H.check
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-9) end

-- IEEE-754 double from its 16-digit hex bit pattern (Lua 5.2 has no string.unpack).
local ldexp = math.ldexp or function(m, e) return m * 2.0 ^ e end
local function f64(h)
	local hi, lo = tonumber(h:sub(1, 8), 16), tonumber(h:sub(9, 16), 16)
	local sign = 1
	if hi >= 0x80000000 then sign, hi = -1, hi - 0x80000000 end
	local e, m = math.floor(hi / 0x100000), (hi % 0x100000) * 2 ^ 32 + lo
	if e == 0x7ff then return m == 0 and sign * math.huge or 0 / 0 end
	if e == 0 then return sign * ldexp(m, -1074) end
	return sign * ldexp(m + 2 ^ 52, e - 1075)
end

-- 1. Bit-for-bit parity against every exported Lean profile fixture.
check(fixtures.profiles ~= nil and #fixtures.profiles > 0, "fixtures: profiles table present")
for _, fx in ipairs(fixtures.profiles) do
	local policy = {}
	for k, v in pairs(fx.policy) do policy[k] = f64(v) end
	local pvis = {}
	for i, p in ipairs(fx.pvis) do pvis[i] = { station = f64(p[1]), elevation = f64(p[2]) } end
	local pviSpeeds = {}
	for i, v in pairs(fx.pviSpeeds) do pviSpeeds[i] = f64(v) end

	local path = P.buildProfile(pvis, policy, pviSpeeds)

	local values, exact, worst, worstWhat = 0, 0, 0, ""
	local function cmp(got, want, what)
		values = values + 1
		local d = math.abs(got - want)
		if got == want then exact = exact + 1 end
		if not (d <= worst) then worst, worstWhat = d, what end
	end

	local kindsOk = #path.segments == #fx.segments
	for i, want in ipairs(fx.segments) do
		local seg = path.segments[i]
		if seg == nil or seg.kind ~= want.kind then kindsOk = false; break end
		local name = string.format("segment %d (%s)", i, want.kind)
		cmp(seg.startStation, f64(want.startStation), name .. " startStation")
		cmp(P.segmentEndStation(seg), f64(want.endStation), name .. " endStation")
		cmp(seg.length, f64(want.length), name .. " length")
		for _, s in ipairs(want.samples) do
			local u = f64(s.u)
			local at = string.format("%s at u = %.3f", name, u)
			cmp(P.segmentElevationAt(seg, u), f64(s.elevation), at .. " elevation")
			cmp(P.segmentGradeAt(seg, u), f64(s.grade), at .. " grade")
			cmp(P.segmentCurvatureAt(seg, u), f64(s.curvature), at .. " curvature")
		end
	end
	if kindsOk then cmp(P.length(path), f64(fx.length), "path length") end

	local kinds = {}
	for i, s in ipairs(path.segments) do kinds[i] = s.kind end
	check(kindsOk, string.format("%s: segments [%s]", fx.name, table.concat(kinds, " ")))
	check(kindsOk and exact == values, string.format("%s: %d/%d bit-exact (worst diff %.3g%s)",
		fx.name, exact, values, worst, worst > 0 and (" " .. worstWhat) or ""))

	-- ProfilePath global queries at segment midpoints match segment queries bit-for-bit,
	-- and out-of-range stations return nil.
	if kindsOk and #path.segments > 0 then
		local midOk = true
		for _, seg in ipairs(path.segments) do
			local sMid = seg.startStation + seg.length / 2
			local u = sMid - seg.startStation
			if P.elevationAt(path, sMid) ~= P.segmentElevationAt(seg, u)
				or P.gradeAt(path, sMid) ~= P.segmentGradeAt(seg, u)
				or P.curvatureAt(path, sMid) ~= P.segmentCurvatureAt(seg, u) then
				midOk = false
			end
		end
		check(midOk, fx.name .. ": ProfilePath global queries match segment queries at midpoints")
		local s0 = path.segments[1].startStation
		local s1 = P.segmentEndStation(path.segments[#path.segments])
		check(P.elevationAt(path, s0 - 1) == nil and P.elevationAt(path, s1 + 1) == nil
			and P.gradeAt(path, s0 - 1) == nil and P.curvatureAt(path, s1 + 1) == nil,
			fx.name .. ": out-of-range global queries return nil")
	elseif kindsOk then
		check(P.elevationAt(path, 0) == nil and P.gradeAt(path, 0) == nil and P.curvatureAt(path, 0) == nil,
			fx.name .. ": empty path queries return nil")
	end
end

-- 2. Default policy and verticalRadius edge cases
check(P.DEFAULT_POLICY.maxVerticalAccel == 0.3
	and P.DEFAULT_POLICY.minVerticalRadius == 500.0
	and P.DEFAULT_POLICY.designSpeed == G.DEFAULT_PARAMS.maxDesignSpeed,
	"DEFAULT_POLICY: maxVerticalAccel=0.3, minVerticalRadius=500, designSpeed=maxDesignSpeed")
check(P.verticalRadius({ maxVerticalAccel = 0.3, designSpeed = 30, minVerticalRadius = 500 }, 30) == 3000,
	"verticalRadius: V^2 / a_v when above floor")
check(P.verticalRadius({ maxVerticalAccel = 0.3, designSpeed = 30, minVerticalRadius = 500 }, 10) == 500,
	"verticalRadius: floored at minVerticalRadius")
check(P.verticalRadius({ maxVerticalAccel = 0, designSpeed = 30, minVerticalRadius = 500 }, 30) == 500,
	"verticalRadius: non-positive accel falls back to minVerticalRadius")
check(P.verticalRadius({ maxVerticalAccel = 0.3, designSpeed = 30, minVerticalRadius = 500 }, 0) == 500,
	"verticalRadius: non-positive speed falls back to minVerticalRadius")

-- 3. Mod-facing helpers: boundaries, sample, clamped queries
local crest = P.buildProfile(
	{ { station = 0, elevation = 0 }, { station = 200, elevation = 4 }, { station = 400, elevation = 0 } },
	{ maxVerticalAccel = 0.3, designSpeed = 30, minVerticalRadius = 500 }
)
-- R_v = 3000, |dg| = 0.04, T = 3000 * 0.04 / 2 = 60 -> BVC = 140, EVC = 260
local bs = P.boundaries(crest)
check(#bs == 4 and near(bs[1], 0) and near(bs[2], 140) and near(bs[3], 260) and near(bs[4], 400),
	"boundaries: start, BVC, EVC, end (not PVI station)")
local zs, gs = P.sample(crest, { -1e-9, 0, 140, 200, 260, 400, 400 + 1e-9 })
check(#zs == 7 and near(zs[1], 0) and near(zs[2], 0) and near(gs[3], 0.02) and near(gs[4], 0)
	and near(gs[5], -0.02) and near(zs[6], 0) and near(zs[7], 0),
	"sample: clamps boundary noise and evaluates heights and grades")
check(near(P.elevationAtClamped(crest, -1), 0) and near(P.elevationAtClamped(crest, 401), 0)
	and near(P.gradeAtClamped(crest, -1), 0.02) and near(P.gradeAtClamped(crest, 401), -0.02),
	"clamped queries: clamp outside path to ends")

H.done()
