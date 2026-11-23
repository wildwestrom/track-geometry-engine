-- Offline checks for the speed and grade readout (tg_readout.script.tl).
local H = dofile("test/harness.lua")
local R = H.mod("tg_readout")

local check = H.check
local function near(a, b) return math.abs(a - b) < 1e-9 end

local vmax = 120 / 3.6

-- a 300 m straight line, a node every 10 m
local nodes, z = {}, {}
for i = 0, 30 do
	nodes[#nodes + 1] = { x = i * 10, y = 0, heading = 0, s = i * 10, k = 0 }
	z[#z + 1] = i * 0.2 -- +20 ‰
end

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
local function sp(kind, len, corner) return { kind = kind, len = len, corner = corner } end
local function arc(len, corner) return { kind = "arc", radius = 100, sweep = len / 100, corner = corner } end
local path = {
	st(50), sp("in", 20, 2), arc(40, 2), sp("out", 20, 2), -- curve 1: 50..130, arc middle 90
	st(0), -- (zero-length: two corners touching)
	sp("in", 10, 3), arc(20, 3), sp("out", 10, 3), -- curve 2: 130..170, arc middle 150
	st(30), arc(60, 5), st(40), -- curve 3, no spirals: 200..260, middle 230
}
local cs = R.curves(path)
check(#cs == 3, "curves: three, touching corners kept apart: " .. #cs)
check(near(cs[1].s0, 50) and near(cs[1].s1, 130) and near(cs[1].sMid, 90), "curves: first spans its spirals, badge at the arc's middle")
check(near(cs[2].s0, 130) and near(cs[2].s1, 170) and near(cs[2].sMid, 150), "curves: second starts where the first ends")
check(near(cs[3].s0, 200) and near(cs[3].s1, 260) and near(cs[3].sMid, 230), "curves: an arc with no spirals")
check(near(cs[1].radius, 100) and near(cs[3].radius, 100), "curves: the arc's radius")
check(cs[1].turn == 2 and cs[2].turn == 3 and cs[3].turn == 5, "curves: each carries the turn it is the curve of")

-- badges on the 300 m line (only chainage is used to find each curve's pieces)
local bs = R.badges(nodes, z, nil, cs)
check(#bs == 3 and bs[1].speed == nil and not bs[1].slowest, "badges: one per curve, no speed before the game's data")
check(near(bs[1].x, 90) and near(bs[1].z, 1.8), "badges: at the arc's middle, with its height")
check(near(bs[1].radius, 100), "badges: the curve's radius")
check(bs[1].turn == 2 and bs[2].turn == 3 and bs[3].turn == 5, "badges: each carries its curve's turn")
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
local P = H.mod("tg_profile")
local A = H.mod("tg_alignment")
local policy = { maxVerticalAccel = 0.3, designSpeed = 30, minVerticalRadius = 500 }
local pvis = { { station = 0, elevation = 0 }, { station = 100, elevation = 3 }, { station = 300, elevation = 7 } }
local prof = P.buildProfile(pvis, policy)
local pb = R.profileBadges(nodes, prof, pvis, 1000)
check(#pb == 5 and pb[1].kind == "point" and pb[2].kind == "span" and pb[3].kind == "point",
	"profile badges: a point, a span, a point, ...")
check(near(pb[2].x, 50) and near(pb[2].grade, P.gradeAtClamped(prof, 50))
	and near(pb[3].z, P.elevationAtClamped(prof, 100)) and near(pb[5].x, 300),
	"profile badges: on the path at their chainage, with the profile's height and grade")
local pg = R.profileBadges(nodes, prof, pvis, 40)
local kinds = {}
for _, b in ipairs(pg) do kinds[b.kind] = (kinds[b.kind] or 0) + 1 end
-- grade badges at 40..280 m, but none within 20 m of a point (0, 100, 300) or a span middle (50, 200)
check(kinds.point == 3 and kinds.span == 2 and kinds.grade == 5 and pg[6].kind == "grade" and near(pg[6].x, 80),
	"profile badges: every 40 m in the clear")
-- a span too steep: its steepest grade at the nodes over it (ends included) past the limit.
-- First leg grade is +30 ‰ (0..100 m), second leg grade is +20 ‰ (100..300 m).
local function steepSpans(limit)
	local out = {}
	for _, b in ipairs(R.profileBadges(nodes, prof, pvis, 1000, limit)) do
		if b.kind == "span" then out[#out + 1] = tostring(b.steep)
		elseif b.steep then out[#out + 1] = "not a span" end
	end
	return table.concat(out, ",")
end
check(steepSpans(0.025) == "true,false", "profile badges: the span past the limit is too steep: " .. steepSpans(0.025))
check(steepSpans(0.015) == "true,true", "profile badges: both spans past a lower limit are too steep: " .. steepSpans(0.015))
check(steepSpans(0.035) == "false,false" and steepSpans(nil) == "false,false", "profile badges: none within the limit, or with none")
local sp = {}
for i = 1, 30 do sp[i] = 1000 end
sp[12] = 25 -- one slow piece, 110..120 m
local ab = R.alongBadges(nodes, z, sp, 50)
check(#ab == 5 and near(ab[1].x, 50) and near(ab[5].x, 250), "along badges: every 50 m, none within 25 m of an end")
check(ab[2].speed == 25 and ab[1].speed == 1000 and ab[3].speed == 1000, "along badges: the slowest piece within 25 m")
local ax, ay = A.pointAt(nodes, 123)
local ps, pd = A.project(nodes, 123, 7)
check(near(ax, 123) and near(ay, 0) and near(ps, 123) and near(pd, 7), "point at a chainage, chainage nearest a point")

-- each plan piece's curve speed: the slowest of its edges (piece 2 split in two at a crossing)
local pieceOf = { [-1] = 1, [-2] = 2, [-4] = 2, [-3] = 3 }
local edgeSpeed = { [-1] = 50, [-2] = 40, [-4] = 30, [-5] = 1 } -- (-3: none known; -5: no plan piece's)
local pieceSp = R.pieceSpeeds(pieceOf, 3, function(e) return edgeSpeed[e] end)
check(pieceSp[1] == 50 and pieceSp[2] == 30 and pieceSp[3] == nil, "piece speeds: the slowest edge of each piece, none where none known")
pieceSp = R.pieceSpeeds({ [-1] = 1, [-2] = 1 }, 1, function(e) return e == -2 and 20 or nil end)
check(pieceSp[1] == 20, "piece speeds: a split piece with no speed on one edge takes the other's")

-- sketch speeds: curves 1 (30..90 m, R 200) and 2 (150..210 m, R 400) on the 300 m path; a fake probe
-- that measures at most what the budget allows
local sc = { { s0 = 30, s1 = 90, sMid = 60, radius = 200, turn = 1 }, { s0 = 150, s1 = 210, sMid = 180, radius = 400, turn = 2 } }
local known, measured = { [200] = 20 }, {}
local fake = {
	cached = function(r) return known[r] end,
	speedAt = function(r) measured[#measured + 1] = r; known[r] = r / 10; return known[r] end,
}
local sp, byTurn = R.sketchSpeeds(nodes, sc, fake.cached, fake.speedAt, {})
check(#measured == 1 and measured[1] == 400, "sketch speeds: only the radius not known is measured")
check(sp[1] == 1000 and sp[5] == 20 and sp[17] == 40 and sp[30] == 1000, "sketch speeds: curve pieces take their curve's speed, straights none")
check(byTurn[1] == 20 and byTurn[2] == 40, "sketch speeds: kept per curve")
measured, known = {}, {}
local ss, bt = R.sketchSpeeds(nodes, sc, fake.cached, fake.speedAt, { [1] = 15, [2] = 25 })
check(#measured == 1 and measured[1] == 200, "sketch speeds: at most one measurement per call")
check(ss[5] == 20 and ss[17] == 25 and bt[2] == 25, "sketch speeds: a curve not measured yet keeps its previous speed")
local none = R.sketchSpeeds(nodes, sc, function() return nil end, function() return nil end, {})
check(none[5] == nil and none[1] == 1000, "sketch speeds: nothing known, nothing made up")

-- where a badge goes on the screen: its nearest edge `gap` px off the track, square to the track's
-- direction there, on the badge's side. A camera looking straight down, north up, 2 px a metre:
-- east is (2, 0) on the screen and north (0, -2). The badge is 90 x 50 px, its point at (500, 300).
local function corner(tx, ty, lx, ly, side) return R.badgeCorner(500, 300, tx, ty, lx, ly, side, 90, 50, 40) end
local function at(x, y, ex, ey) return math.abs(x - ex) < 1e-6 and math.abs(y - ey) < 1e-6 end
local cx, cy = corner(2, 0, 0, -2, 1)
check(at(cx, cy, 455, 210), "badge corner: east, left of the track: above it, 40 px clear: " .. cx .. "," .. cy)
cx, cy = corner(2, 0, 0, -2, -1)
check(at(cx, cy, 455, 340), "badge corner: east, right of the track: below it: " .. cx .. "," .. cy)
cx, cy = corner(-2, 0, 0, 2, 0)
check(at(cx, cy, 455, 210), "badge corner: no side: toward the top of the screen: " .. cx .. "," .. cy)
cx, cy = corner(0, -3, -3, 0, 1)
check(at(cx, cy, 370, 275), "badge corner: north, left of the track: to its left: " .. cx .. "," .. cy)
-- a tilted camera: a metre across the track shows up and to the right, but the badge still goes square to the track
cx, cy = corner(2, 0, 1, -1, 1)
check(at(cx, cy, 455, 210), "badge corner: square to the track on the screen, not to the ground: " .. cx .. "," .. cy)
-- north-east, right of the track: the box's nearest corner (its top left) 40 px out along the
-- normal (1, 1)/sqrt 2, its middle on the normal
cx, cy = corner(1, -1, -1, -1, -1)
local r2 = math.sqrt(2)
check(math.abs((cx - 500 + cy - 300) / r2 - 40) < 1e-6 and math.abs((cx + 45 - 500) - (cy + 25 - 300)) < 1e-6,
	"badge corner: diagonal: nearest corner 40 px out, middle on the normal: " .. cx .. "," .. cy)
cx, cy = corner(0, 2, 2, 0, 0)
check(at(cx, cy, 370, 275), "badge corner: no side, track straight down the screen: to the left: " .. cx .. "," .. cy)
-- the track pointing at the camera (a metre along it under a tenth of one across): up, whatever the side
cx, cy = corner(0.1, 0, 0, -2, -1)
check(at(cx, cy, 455, 210), "badge corner: track toward the camera: up: " .. cx .. "," .. cy)

-- each badge's direction and side (the outside of the nearest curve): a path east 100 m, a left
-- curve (100..200 m), 100 m straight, a right curve (300..400 m), 100 m straight; a node every 10 m
local curvy, curvyZ = {}, {}
do
	local x, y, hd = 0.0, 0.0, 0.0
	local turns = { [11] = 0.05, [21] = 0, [31] = -0.05, [41] = 0 } -- the heading's change a piece, from that piece on
	local dh = 0.0
	for i = 1, 51 do
		curvy[i] = { x = x, y = y, heading = hd, s = (i - 1) * 10, k = math.abs(dh) / 10 }
		curvyZ[i] = 0
		dh = turns[i] or dh
		x, y, hd = x + 10 * math.cos(hd + dh / 2), y + 10 * math.sin(hd + dh / 2), hd + dh
	end
end
local function sides(list, on)
	local out = {}
	for _, b in ipairs(list) do out[#out + 1] = string.format("%.0f:%d", A.project(on or curvy, b.x, b.y), b.side) end
	return table.concat(out, " ")
end
local along = R.alongBadges(curvy, curvyZ, nil, 50)
-- (250 m is as near the one curve as the other: not checked)
check(sides({ along[1], along[2], along[3], along[4] }) == "50:-1 100:-1 150:-1 200:-1", "badge sides: near the left curve, on its outside (right): " .. sides(along))
check(sides({ along[6], along[7], along[8], along[9] }) == "300:1 350:1 400:1 450:1", "badge sides: near the right curve, on its outside (left): " .. sides(along))
check(near(along[1].dx, 1) and near(along[1].dy, 0), "badge direction: along the path, east on the first straight")
local heading = A.atan2(along[3].dy, along[3].dx)
check(heading > 0.2 and heading < 0.3 and near(along[3].dx ^ 2 + along[3].dy ^ 2, 1), "badge direction: along the curve, of length one: " .. heading)
local curvyCurves = { { s0 = 100, s1 = 200, sMid = 150, radius = 200, turn = 1 }, { s0 = 300, s1 = 400, sMid = 350, radius = 200, turn = 2 } }
local cb = R.badges(curvy, curvyZ, nil, curvyCurves)
check(sides(cb) == "150:1 350:-1", "badge sides: curve badges on their curve's inside: " .. sides(cb))
-- a curve with no arc (a spiral straight into another): at the middle of the whole curve, inside
local bare = R.badges(curvy, curvyZ, nil, { { s0 = 100, s1 = 200, sMid = 120, turn = 1 } })[1]
check(near(A.project(curvy, bare.x, bare.y), 150) and bare.radius == nil and bare.side == 1, "curve badges: no arc: the curve's middle, inside")

-- where a curve's badge goes on the screen: square to the track, on its side (the inside), its
-- middle as far out as the arc's centre (its radius, at the track's scale across it), but at most
-- `far` px and its nearest edge never under `gap` px off the track. The badge is 90 x 50 px, its
-- point at (500, 300), the track running east on the screen with its left up, 2 px a metre.
local function ccorner(radius, side, lx, ly) return R.curveCorner(500, 300, 2, 0, lx or 0, ly or -2, side or 1, radius, 90, 50, 160, 40) end
cx, cy = ccorner(50)
check(at(cx, cy, 455, 175), "curve corner: the centre within reach (100 px): on it: " .. cx .. "," .. cy)
cx, cy = ccorner(3488)
check(at(cx, cy, 455, 115), "curve corner: the centre far off: 160 px toward it: " .. cx .. "," .. cy)
cx, cy = ccorner(25)
check(at(cx, cy, 455, 210), "curve corner: the centre close in: still 40 px clear of the track: " .. cx .. "," .. cy)
cx, cy = ccorner(nil, 1)
check(at(cx, cy, 455, 115), "curve corner: no arc: 160 px out on its side: " .. cx .. "," .. cy)
cx, cy = ccorner(nil, -1)
check(at(cx, cy, 455, 435), "curve corner: no arc, to the right: below: " .. cx .. "," .. cy)
-- the track's direction on the screen, read over enough metres to span `span` px: world2Screen gives
-- whole pixels, and from far off a metre is a third of one. A fake camera at 0.3 px a metre, the
-- track running east-north-east, rounding as the game does.
local function proj(x, y) return math.floor(500 + 0.3 * x + 0.5), math.floor(300 - 0.3 * y + 0.5) end
local fpx, fpy, ftx, fty, flx, fly = R.screenFrame(proj, 1000.4, 200.3, 0.9578, 0.2873, 100, 1000)
local ang = math.atan2(fty, ftx) - math.atan2(-0.2873, 0.9578)
check(fpx == proj(1000.4, 200.3) and math.abs(ang) < 0.02, "screen frame: the direction to a degree, though a metre is under a pixel: " .. ang)
check(math.abs(math.sqrt(ftx ^ 2 + fty ^ 2) - 0.3) < 0.01 and math.abs(math.sqrt(flx ^ 2 + fly ^ 2) - 0.3) < 0.01,
	"screen frame: per metre: " .. ftx .. "," .. fty .. " " .. flx .. "," .. fly)
local _, _, ntx, nty = R.screenFrame(function(x, y) return math.floor(x * 40 + 0.5), math.floor(-y * 40 + 0.5) end, 0, 0, 1, 0, 100, 1000)
check(ntx == 40 and nty == 0, "screen frame: close up, a metre is enough: " .. ntx .. "," .. nty)
-- a tilted camera: a metre across shows up and to the right, sqrt 8 px long; the badge still goes square to the track
cx, cy = ccorner(50, 1, 2, -2)
check(at(cx, cy, 455, 300 - 50 * math.sqrt(8) - 25), "curve corner: tilted camera: square to the track, the centre's distance: " .. cx .. "," .. cy)
local curvyPvis = { { station = 0, elevation = 0 }, { station = 120, elevation = 3 }, { station = 500, elevation = 0 } }
local curvyProf = P.buildProfile(curvyPvis, policy)
local profSides = sides(R.profileBadges(curvy, curvyProf, curvyPvis, 1000))
check(profSides == "0:-1 60:-1 120:-1 310:1 500:1", "badge sides: profile badges the same way: " .. profSides)
check(sides(R.alongBadges(nodes, z, nil, 100), nodes) == "100:0 200:0", "badge sides: none on a path with no curve")

H.done()
