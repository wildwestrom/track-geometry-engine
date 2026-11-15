-- The track's vertical profile: a monotone cubic in chainage through the elevation points
-- (Fritsch–Carlson, with Fritsch–Butland grades as in PCHIP). The first and last points are the
-- path's ends (the existing track nodes) and the grades there are the existing tracks' grades, so
-- the new track joins them without a kink. Between two points the profile is the cubic Hermite
-- with their heights and grades. An interior point is level where the profile turns there or a
-- span next to it is level; elsewhere its grade is a weighted harmonic mean of the two spans'
-- grades. So the profile never overshoots between interior points: two points at one height are
-- joined level, and a climb out of a level span does not dip first. The grade is continuous, its
-- rate of change (the vertical curvature) may jump at a point. A span next to an end may still
-- overshoot, when the existing track's grade points away from the next point; the end grades are
-- kept so the joins have no kink. With no interior points it is one Hermite from end to end, like
-- the game's own builder lays a drag (which fixes only the start grade and lets the curve
-- straighten out by the far end).
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
-- increasing chainage. Interior point i, between spans of length h1, h2 with chord grades d1, d2:
-- 0 if d1 and d2 differ in sign or either is 0, else the harmonic mean of d1 and d2 weighted
--   w1 = 2 h2 + h1, w2 = h2 + 2 h1:  (w1 + w2) / g = w1 / d1 + w2 / d2
-- which keeps |g| within 3 |d| on both sides, so each span between interior points is monotone.
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
	for i = 2, n - 1 do
		local d1, d2 = d[i - 1], d[i]
		if d1 * d2 <= 0 then
			g[i] = 0
		else
			local w1, w2 = 2 * h[i] + h[i - 1], h[i] + 2 * h[i - 1]
			g[i] = (w1 + w2) / (w1 / d1 + w2 / d2)
		end
	end
	g[n] = gN
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
