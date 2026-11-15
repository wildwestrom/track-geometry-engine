-- Offline checks for the vertical profile (tg_profile.script.tl). Run from mod/ after check.sh
-- builds .tlpath/:
--   lua test/profile_test.lua
local tl = require("tl")
tl.loader()
package.path = ".tlpath/?.tl;" .. package.path
local P = require("westrom_track_geometry::/track_geometry/tg_profile.script.tl")

local failures = 0
local function check(ok, what)
	print((ok and "ok   " or "FAIL ") .. what)
	if not ok then failures = failures + 1 end
end
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

-- what cannot be solved
check(P.solve({ { s = 0, z = 0 } }, 0, 0) == nil, "one point: no profile")
check(P.solve({ { s = 0, z = 0 }, { s = 100, z = 1 }, { s = 100, z = 2 } }, 0, 0) == nil, "two points at one chainage: no profile")

if failures > 0 then
	print(failures .. " failed")
	os.exit(1)
end
print("all passed")
