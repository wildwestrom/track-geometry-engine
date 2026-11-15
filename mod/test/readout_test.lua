-- Offline checks for the speed and grade readout (tg_readout.script.tl). Run from mod/ after
-- check.sh builds .tlpath/:
--   lua test/readout_test.lua
local tl = require("tl")
tl.loader()
package.path = ".tlpath/?.tl;" .. package.path
local R = require("westrom_track_geometry::/track_geometry/tg_readout.script.tl")

local failures = 0
local function check(ok, what)
	print((ok and "ok   " or "FAIL ") .. what)
	if not ok then failures = failures + 1 end
end
local function near(a, b) return math.abs(a - b) < 1e-9 end

local vmax = 120 / 3.6

-- a 300 m straight line, a node every 10 m
local nodes, z = {}, {}
for i = 0, 30 do
	nodes[#nodes + 1] = { x = i * 10, y = 0, heading = 0, s = i * 10, k = 0 }
	z[#z + 1] = i * 0.2 -- +20 ‰
end
local g = R.grades(nodes, z)
check(#g == 30 and near(g[1], 0.02) and near(g[30], 0.02), "grades: one per piece, rise over run")

local lines = R.summary(nodes, z, nil, vmax, nil)
check(lines[1] == "Curve limit (game): waiting for the game, track 120 km/h", "summary: no data yet: " .. lines[1])
check(lines[2] == "Grade: +20.0 ‰ throughout", "summary: constant grade: " .. lines[2])
check(#lines == 2, "summary: no radius line on a straight path")

local speeds = {}
for i = 1, 30 do speeds[i] = 5000 end
speeds[12] = 101 / 3.6
speeds[20] = 90 / 3.6
lines = R.summary(nodes, z, speeds, vmax, 312.4)
check(lines[1] == "Curve limit (game): slowest 90 km/h at 190 m, track 120 km/h", "summary: slowest piece and where: " .. lines[1])
check(lines[3] == "Smallest radius: 312 m", "summary: radius: " .. tostring(lines[3]))

for i = 1, 30 do speeds[i] = 5000 end
check(R.summary(nodes, z, speeds, 0, nil)[1] == "Curve limit (game): none", "summary: straight: no limit")

check(R.summary(nodes, z, {}, 0, nil)[1] == "Curve limit (game): the game gave none", "summary: no speeds read")

-- curves: only lengths and kinds matter here
local function st(len) return { kind = "straight", p = { x = 0, y = 0, z = 0 }, q = { x = len, y = 0, z = 0 } } end
local function sp(kind, len) return { kind = kind, len = len } end
local function arc(len) return { kind = "arc", radius = 100, sweep = len / 100 } end
local path = {
	st(50), sp("in", 20), arc(40), sp("out", 20), -- curve 1: 50..130, arc middle 90
	st(0), -- (zero-length: two corners touching)
	sp("in", 10), arc(20), sp("out", 10), -- curve 2: 130..170, arc middle 150
	st(30), arc(60), st(40), -- curve 3, no spirals: 200..260, middle 230
}
local cs = R.curves(path)
check(#cs == 3, "curves: three, touching corners kept apart: " .. #cs)
check(near(cs[1].s0, 50) and near(cs[1].s1, 130) and near(cs[1].sMid, 90), "curves: first spans its spirals, badge at the arc's middle")
check(near(cs[2].s0, 130) and near(cs[2].s1, 170) and near(cs[2].sMid, 150), "curves: second starts where the first ends")
check(near(cs[3].s0, 200) and near(cs[3].s1, 260) and near(cs[3].sMid, 230), "curves: an arc with no spirals")

-- badges on the 300 m line (only chainage is used to find each curve's pieces)
local bs = R.badges(nodes, z, nil, cs)
check(#bs == 3 and bs[1].speed == nil and not bs[1].slowest, "badges: one per curve, no speed before the game's data")
check(near(bs[1].x, 90) and near(bs[1].z, 1.8) and near(bs[1].grade, 0.02), "badges: at the arc's middle, with its height and grade")
for i = 1, 30 do speeds[i] = 5000 end
for i = 6, 13 do speeds[i] = 110 / 3.6 end -- curve 1: pieces 6..13 (mid 55..125)
speeds[9] = 104 / 3.6
for i = 14, 17 do speeds[i] = 95 / 3.6 end -- curve 2
for i = 21, 26 do speeds[i] = 130 / 3.6 end -- curve 3
bs = R.badges(nodes, z, speeds, cs)
check(near(bs[1].speed, 104 / 3.6) and near(bs[2].speed, 95 / 3.6) and near(bs[3].speed, 130 / 3.6),
	"badges: each curve's slowest piece")
check(not bs[1].slowest and bs[2].slowest and not bs[3].slowest, "badges: the slowest curve is marked")
check(not R.badges(nodes, z, speeds, { cs[1] })[1].slowest, "badges: a lone curve is not marked")
check(#R.badges(nodes, z, speeds, {}) == 0, "badges: none on a straight path")

z[16] = z[16] - 1.0 -- a dip: -80 ‰ into it, +120 ‰ out
lines = R.summary(nodes, z, speeds, vmax, nil)
check(lines[2] == "Grade: -80.0 ‰ to +120.0 ‰, steepest +120.0 ‰ at 150 m",
	"summary: varying grade: " .. lines[2])

-- the profile's badges: at each point (ends too) and halfway along each span
local P = require("westrom_track_geometry::/track_geometry/tg_profile.script.tl")
local A = require("westrom_track_geometry::/track_geometry/tg_alignment.script.tl")
local prof = assert(P.solve({ { s = 0, z = 0 }, { s = 100, z = 3 }, { s = 300, z = 7 } }, 0.02, 0))
local pb = R.profileBadges(nodes, prof, 1000)
check(#pb == 5 and pb[1].kind == "point" and pb[2].kind == "span" and pb[3].kind == "point",
	"profile badges: a point, a span, a point, ...")
check(near(pb[2].x, 50) and near(pb[2].grade, P.gradeAt(prof, 50)) and near(pb[3].z, 3) and near(pb[5].x, 300),
	"profile badges: on the path at their chainage, with the profile's height and grade")
local pg = R.profileBadges(nodes, prof, 40)
local kinds = {}
for _, b in ipairs(pg) do kinds[b.kind] = (kinds[b.kind] or 0) + 1 end
-- grade badges at 40..280 m, but none within 20 m of a point (0, 100, 300) or a span middle (50, 200)
check(kinds.point == 3 and kinds.span == 2 and kinds.grade == 5 and pg[6].kind == "grade" and near(pg[6].x, 80),
	"profile badges: every 40 m in the clear")
-- a span too steep: its steepest grade at the nodes over it (ends included) past the limit. This
-- profile peaks at +33.9 ‰ (50 m) on the first span; the second starts at +24.5 ‰ (100 m) and
-- peaks at +27.1 ‰ (140 m).
local function steepSpans(limit)
	local out = {}
	for _, b in ipairs(R.profileBadges(nodes, prof, 1000, limit)) do
		if b.kind == "span" then out[#out + 1] = tostring(b.steep)
		elseif b.steep then out[#out + 1] = "not a span" end
	end
	return table.concat(out, ",")
end
check(steepSpans(0.03) == "true,false", "profile badges: the span past the limit is too steep: " .. steepSpans(0.03))
check(steepSpans(0.02) == "true,true", "profile badges: a span past it at its first node is too steep: " .. steepSpans(0.02))
check(steepSpans(0.04) == "false,false" and steepSpans(nil) == "false,false", "profile badges: none within the limit, or with none")
local sp = {}
for i = 1, 30 do sp[i] = 1000 end
sp[12] = 25 -- one slow piece, 110..120 m
local ab = R.alongBadges(nodes, z, sp, 50)
check(#ab == 5 and near(ab[1].x, 50) and near(ab[5].x, 250), "along badges: every 50 m, none within 25 m of an end")
check(ab[2].speed == 25 and ab[1].speed == 1000 and ab[3].speed == 1000, "along badges: the slowest piece within 25 m")
local ax, ay = A.pointAt(nodes, 123)
local ps, pd = A.project(nodes, 123, 7)
check(near(ax, 123) and near(ay, 0) and near(ps, 123) and near(pd, 7), "point at a chainage, chainage nearest a point")

if failures > 0 then
	print(failures .. " failed")
	os.exit(1)
end
print("all passed")
