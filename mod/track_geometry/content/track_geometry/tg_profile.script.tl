-- The track's vertical profile: a clamped cubic spline in chainage through the elevation points.
-- The first and last points are the path's ends (the existing track nodes) and the grades there
-- are the existing tracks' grades, so the new track joins them without a kink. Between two points
-- the profile is the cubic Hermite with their heights and grades; the grades at interior points
-- are solved so the grade changes smoothly through them (continuous second derivative). With no
-- interior points it is one Hermite from end to end, like the game's own builder lays a drag
-- (which fixes only the start grade and lets the curve straighten out by the far end).
-- The cubic may overshoot a point a little; that is accepted.
-- No game API here, so test/profile_test.lua runs it outside the game.

local record Point
	s : number -- chainage (m)
	z : number -- height (m)
end

local record Profile
	points : {Point}
	grades : {number} -- dz/ds at each point
end

local record ProfileMod
	Point : Point
	Profile : Profile
	solve : function(points : {Point}, g0 : number, gN : number) : Profile, string
	heightAt : function(p : Profile, s : number) : number
	gradeAt : function(p : Profile, s : number) : number
	sample : function(p : Profile, ss : {number}) : {number}, {number}
end

local M : ProfileMod = {}

-- The grades at the points, or nil and why not. Needs two points or more with strictly
-- increasing chainage. Each interior point i gives a row of the tridiagonal system
--   h[i] g[i-1] + 2 (h[i-1] + h[i]) g[i] + h[i-1] g[i+1] = 3 (h[i] d[i-1] + h[i-1] d[i])
-- (h the span lengths, d their chord grades), with the end grades moved to the right-hand side,
-- solved by the Thomas algorithm.
function M.solve(points : {Point}, g0 : number, gN : number) : Profile, string
	local n = #points
	if n < 2 then return nil, "a profile needs two points" end
	local h, d : {number}, {number} = {}, {}
	for i = 1, n - 1 do
		h[i] = points[i + 1].s - points[i].s
		if not (h[i] > 0) then return nil, "elevation points out of order at " .. i end
		d[i] = (points[i + 1].z - points[i].z) / h[i]
	end
	local g : {number} = { g0 }
	g[n] = gN
	if n > 2 then
		-- rows 2..n-1: sub a, diagonal b, super c, right-hand side r
		local c, r : {number}, {number} = {}, {}
		for i = 2, n - 1 do
			local a, b = h[i], 2 * (h[i - 1] + h[i])
			c[i] = h[i - 1]
			r[i] = 3 * (h[i] * d[i - 1] + h[i - 1] * d[i])
			if i == 2 then r[i] = r[i] - a * g0 end
			if i == n - 1 then r[i] = r[i] - c[i] * gN; c[i] = 0 end
			if i > 2 then
				-- eliminate the sub-diagonal with the previous row (already divided through)
				b = b - a * c[i - 1]
				r[i] = r[i] - a * r[i - 1]
			end
			c[i] = c[i] / b
			r[i] = r[i] / b
		end
		g[n - 1] = r[n - 1]
		for i = n - 2, 2, -1 do g[i] = r[i] - c[i] * g[i + 1] end
	end
	return { points = points, grades = g }, nil
end

-- The span s falls in: the last one starting at or before s (the first before the start).
local function span(p : Profile, s : number) : integer
	local i = 1
	while i < #p.points - 1 and s >= p.points[i + 1].s do i = i + 1 end
	return i
end

-- Where s sits in its span: the span, t in [0, 1] and the span's length. s outside the profile
-- counts as its end (only float noise puts a node there).
local function locate(p : Profile, s : number) : integer, number, number
	local pts = p.points
	s = math.max(pts[1].s, math.min(pts[#pts].s, s))
	local i = span(p, s)
	local h = pts[i + 1].s - pts[i].s
	return i, (s - pts[i].s) / h, h
end

function M.heightAt(p : Profile, s : number) : number
	local i, t, h = locate(p, s)
	local a, b = p.points[i], p.points[i + 1]
	local t2, t3 = t * t, t * t * t
	return (2 * t3 - 3 * t2 + 1) * a.z + (t3 - 2 * t2 + t) * h * p.grades[i]
		+ (-2 * t3 + 3 * t2) * b.z + (t3 - t2) * h * p.grades[i + 1]
end

function M.gradeAt(p : Profile, s : number) : number
	local i, t, h = locate(p, s)
	local a, b = p.points[i], p.points[i + 1]
	local t2 = t * t
	return (6 * t2 - 6 * t) * (a.z - b.z) / h + (3 * t2 - 4 * t + 1) * p.grades[i] + (3 * t2 - 2 * t) * p.grades[i + 1]
end

-- Heights and grades at the chainages ss (each node's s).
function M.sample(p : Profile, ss : {number}) : {number}, {number}
	local z, g : {number}, {number} = {}, {}
	for i, s in ipairs(ss) do
		z[i], g[i] = M.heightAt(p, s), M.gradeAt(p, s)
	end
	return z, g
end

return M
