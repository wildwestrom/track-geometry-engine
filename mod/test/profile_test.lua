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

-- a hump and a dip: through every point, the end grades, smooth at the interior points
local pts = { { s = 0, z = 0 }, { s = 200, z = 6 }, { s = 350, z = 2 }, { s = 600, z = 9 }, { s = 800, z = 10 } }
p = assert(P.solve(pts, -0.005, 0.03))
local through = true
for _, q in ipairs(pts) do through = through and near(P.heightAt(p, q.s), q.z) end
check(through, "through every point")
check(near(P.gradeAt(p, 0), -0.005) and near(P.gradeAt(p, 800), 0.03), "the end grades")
local smooth = true
for i = 2, #pts - 1 do
	local s, e = pts[i].s, 1e-4
	local dl = (P.gradeAt(p, s - e) - P.gradeAt(p, s - 2 * e)) / e -- curvature from the left
	local dr = (P.gradeAt(p, s + 2 * e) - P.gradeAt(p, s + e)) / e -- and from the right
	local gl, gr = P.gradeAt(p, s - 1e-9), P.gradeAt(p, s + 1e-9)
	if not near(gl, gr, 1e-6) or not near(dl, dr, 1e-6) then
		smooth = false
		print(string.format("  at %g: grade %g / %g, curvature %g / %g", s, gl, gr, dl, dr))
	end
end
check(smooth, "grade and curvature continuous at the interior points")
local z, g = P.sample(p, { 0, 200, 800 })
check(#z == 3 and near(z[2], 6) and near(g[3], 0.03), "sample: height and grade at each chainage")
check(near(P.heightAt(p, -1e-9), 0) and near(P.heightAt(p, 800 + 1e-9), 10), "outside the profile counts as its end")

-- what cannot be solved
check(P.solve({ { s = 0, z = 0 } }, 0, 0) == nil, "one point: no profile")
check(P.solve({ { s = 0, z = 0 }, { s = 100, z = 1 }, { s = 100, z = 2 } }, 0, 0) == nil, "two points at one chainage: no profile")

if failures > 0 then
	print(failures .. " failed")
	os.exit(1)
end
print("all passed")
