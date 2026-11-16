-- Offline checks for the vertical profile (tg_profile.script.tl).
local H = dofile("test/harness.lua")
local P = H.mod("tg_profile")

local check = H.check
local function near(a, b, tol) return math.abs(a - b) < (tol or 1e-9) end

-- two points: one Hermite, from the start grade to the end grade
local p = assert(P.solve({ { s = 0, z = 100 }, { s = 400, z = 110 } }, 0.02, -0.01))
check(near(P.heightAt(p, 0), 100) and near(P.heightAt(p, 400), 110), "two points: through both ends")
check(near(P.gradeAt(p, 0), 0.02) and near(P.gradeAt(p, 400), -0.01), "two points: the end grades")
-- the Hermite at t = 1/2: (z0 + z1) / 2 + h (g0 - g1) / 8
check(near(P.heightAt(p, 200), 105 + 400 * 0.03 / 8), "two points: the cubic Hermite between them")

-- points on one line, end grades on it: the line itself
local line = {}
for i, s in ipairs({ 0, 120, 150, 400, 700 }) do line[i] = { s = s, z = 50 + 0.012 * s } end
p = assert(P.solve(line, 0.012, 0.012))
local straight = true
for s = 0, 700, 7 do
	if not near(P.heightAt(p, s), 50 + 0.012 * s) or not near(P.gradeAt(p, s), 0.012) then straight = false end
end
check(straight, "a straight grade stays straight")

-- a hump and a dip: through every point, the end grades, the grade continuous at the points
local pts = { { s = 0, z = 0 }, { s = 200, z = 6 }, { s = 350, z = 2 }, { s = 600, z = 9 }, { s = 800, z = 10 } }
p = assert(P.solve(pts, -0.005, 0.03))
local through = true
for _, q in ipairs(pts) do through = through and near(P.heightAt(p, q.s), q.z) end
check(through, "through every point")
check(near(P.gradeAt(p, 0), -0.005) and near(P.gradeAt(p, 800), 0.03), "the end grades")
local smooth = true
for i = 2, #pts - 1 do
	local gl, gr = P.gradeAt(p, pts[i].s - 1e-9), P.gradeAt(p, pts[i].s + 1e-9)
	if not near(gl, gr, 1e-6) then
		smooth = false
		print(string.format("  at %g: grade %g / %g", pts[i].s, gl, gr))
	end
end
check(smooth, "grade continuous at the interior points")
-- a point where the profile turns (the hump at 200 m, the dip at 350 m) is level there
check(near(P.gradeAt(p, 200), 0) and near(P.gradeAt(p, 350), 0), "level at a hump or a dip")

local z, g = P.sample(p, { 0, 200, 800 })
check(#z == 3 and near(z[2], 6) and near(g[3], 0.03), "sample: height and grade at each chainage")
check(near(P.heightAt(p, -1e-9), 0) and near(P.heightAt(p, 800 + 1e-9), 10), "outside the profile counts as its end")

-- no overshoot: between two interior points the profile stays between their heights
local function within(prof, a, b)
	local lo, hi = math.min(a.z, b.z) - 1e-9, math.max(a.z, b.z) + 1e-9
	for k = 0, 100 do
		local z = P.heightAt(prof, a.s + (b.s - a.s) * k / 100)
		if z < lo or z > hi then return false end
	end
	return true
end
local wild = { { s = 0, z = 0 }, { s = 30, z = 0.5 }, { s = 330, z = 1 }, { s = 360, z = 20 },
	{ s = 380, z = 21 }, { s = 700, z = 21 }, { s = 900, z = 0 } }
p = assert(P.solve(wild, 0, 0))
local inside = true
for i = 2, #wild - 2 do inside = inside and within(p, wild[i], wild[i + 1]) end
check(inside, "no overshoot between interior points")

-- two points at one height next to a steep climb: the span between them stays level (it used to
-- dip, -6 ‰ at its lowest, because the climb gave the second point +18 ‰)
local climb = { { s = 0, z = 1.9 }, { s = 300, z = 1.9 }, { s = 500, z = 9 }, { s = 800, z = 22 } }
p = assert(P.solve(climb, 0, 0.05))
local level = true
for s = 0, 300, 5 do level = level and near(P.heightAt(p, s), 1.9) and near(P.gradeAt(p, s), 0) end
check(level, "a span between two equal heights stays level")
check(within(p, climb[2], climb[3]), "a climb out of a level span does not dip first")

-- a free end grade (a ground end): the one-sided three-point formula from its first span,
--   g = ((2 h1 + h2) d1 - h1 d2) / (h1 + h2)
-- set to 0 when it points away from the span, and kept within 3 d1 when the next span turns back
local free = { { s = 0, z = 0 }, { s = 100, z = 2 }, { s = 300, z = 8 } } -- d1 = 0.02, d2 = 0.03
p = assert(P.solve(free, nil, nil))
check(near(P.gradeAt(p, 0), (400 * 0.02 - 100 * 0.03) / 300), "free start: the one-sided formula")
check(near(P.gradeAt(p, 300), (500 * 0.03 - 200 * 0.02) / 300), "free end: the one-sided formula, from the end")
p = assert(P.solve({ { s = 0, z = 0 }, { s = 100, z = 1 }, { s = 200, z = -4 } }, nil, 0)) -- d1 = 0.01, d2 = -0.05
check(near(P.gradeAt(p, 0), 0.03), "free start: kept within 3 d1 when the profile turns back")
-- d1 = 0.01, d2 = 0.95: the formula points down, away from the span; it would dip below the start
local kink = { { s = 0, z = 0 }, { s = 100, z = 1 }, { s = 120, z = 20 } }
p = assert(P.solve(kink, nil, 0))
check(near(P.gradeAt(p, 0), 0), "free start: level when the formula points away from its span")
check(within(p, kink[1], kink[2]), "free start: no overshoot in the end span")
p = assert(P.solve({ { s = 0, z = 0 }, { s = 100, z = 0 }, { s = 300, z = 8 } }, nil, nil))
check(near(P.gradeAt(p, 0), 0), "free start next to a level span: level")
p = assert(P.solve({ { s = 0, z = 3 }, { s = 250, z = 8 } }, nil, nil))
check(near(P.gradeAt(p, 0), 0.02) and near(P.gradeAt(p, 125), 0.02), "two free ends: a straight grade")

-- what cannot be solved
check(P.solve({ { s = 0, z = 0 } }, 0, 0) == nil, "one point: no profile")
check(P.solve({ { s = 0, z = 0 }, { s = 100, z = 1 }, { s = 100, z = 2 } }, 0, 0) == nil, "two points at one chainage: no profile")

H.done()
