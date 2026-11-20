-- Offline checks for the gizmos (tg_gizmos.script.tl): what is drawn, in what order, where, and in
-- which colour role, read from a made-up session.
local H = dofile("test/harness.lua")
local G = H.mod("tg_geometry")
local E = H.mod("tg_edit")
local P = H.mod("tg_profile")
local Gz = H.mod("tg_gizmos")

local check = H.check
local function endAt(x, y, deg)
	return { x = x, y = y, z = 0, dx = math.cos(math.rad(deg)), dy = math.sin(math.rad(deg)) }
end
local function gnd(x, y, z) return { kind = "ground", x = x, y = y, z = z or 0 } end
local function vend(x, y, deg, z, grade)
	local e = endAt(x, y, deg)
	e.z, e.grade = z, grade
	return e
end
local function dist(a, b) return math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2) end
local function near(a, b) return math.abs(a - b) < 1e-9 end

local R = 10 -- the grab radius
local W = Gz.GIZMO_WIDTH -- the gizmos' width, whatever the zoom
local function slope(x, y) return 0.01 * x + 0.02 * y end -- a made-up ground
local function session(e, fields)
	local s = { phase = "done", mode = "horizontal", edit = e, grab = R }
	for k, v in pairs(fields or {}) do s[k] = v end
	return s
end
local function shapes(e, fields, ground) return Gz.of(session(e, fields), ground or slope) end
local function ofColor(ss, color)
	local out = {}
	for _, s in ipairs(ss) do if s.color == color then out[#out + 1] = s end end
	return out
end
-- fn's result with no profile (the stub stands in for a profile that cannot be solved)
local function withoutProfile(fn)
	local profile = E.profile
	E.profile = function() return nil, "no profile" end
	local ok, out = pcall(fn)
	E.profile = profile
	return assert(ok and out, out)
end
local function groundShapes(e) return withoutProfile(function() return shapes(e) end) end -- (as drawn with no profile)
local function turnRole(s) return s.kind == "circle" and (s.color == "free" or s.color == "ray" or s.color == "fixed" or s.color == "groundEnd" or s.color == "hot") end

-- bg: track to ground, one turn (a curve with its two brackets) and the ground end
local bg = assert(E.new(endAt(0, 0, 0), gnd(300, 200)))

-- Horizontal draw order: circles, legs, turn and end circles, brackets.
do
	local groups = {}
	for _, s in ipairs(shapes(bg)) do
		local g = turnRole(s) and "handle" or s.color
		if groups[#groups] ~= g then groups[#groups + 1] = g end
	end
	check(table.concat(groups, " ") == "osculating leg spiral handle bracket",
		"horizontal: osculating circles, legs, spirals, turn and end circles, brackets: " .. table.concat(groups, " "))
end

-- A leg is cut into pieces at most 10 m long (60 at most), each point over the ground (with no profile).
local function legCut(e, pieces, what)
	local legs, pis = ofColor(groundShapes(e), "leg"), E.polyline(e)
	local ok = #legs == #pis - 1
	for k, l in ipairs(legs) do
		local a, b = pis[k], pis[k + 1]
		ok = ok and l.kind == "line" and #l.pts == pieces + 1 and l.width == W and l.step == Gz.GIZMO_STEP
			and near(l.pts[1][1], a.x) and near(l.pts[1][2], a.y) and near(l.pts[#l.pts][1], b.x) and near(l.pts[#l.pts][2], b.y)
		for j, p in ipairs(l.pts) do
			ok = ok and near(p[3], slope(p[1], p[2]))
			if j > 1 then ok = ok and dist({ x = p[1], y = p[2] }, { x = l.pts[j - 1][1], y = l.pts[j - 1][2] }) <= math.max(10, dist(a, b) / 60) + 1e-9 end
		end
	end
	check(ok, what)
end
legCut(E.new(endAt(0, 0, 0), endAt(500, 0, 180)), 50, "a 500 m leg: 50 pieces of 10 m, each point at the ground's height")
legCut(E.new(endAt(0, 0, 0), endAt(5000, 0, 180)), 60, "a 5 km leg: 60 pieces, the most a leg gets")
legCut(E.new(endAt(0, 0, 0), endAt(45, 0, 180)), 5, "a 45 m leg: 5 pieces, none past 10 m")

-- Legs are drawn at the track's profile height at the nearest chainage; with no profile, on the ground.
do
	local st = assert(E.new(vend(0, 0, 0, 100, 0), vend(500, 0, 180, 130, 0))) -- (straight: chainage = x)
	local prof = assert(E.profile(st))
	local legs = ofColor(shapes(st), "leg")
	local ok = #legs == 1
	for _, p in ipairs(legs[1].pts) do ok = ok and near(p[3], P.heightAt(prof, p[1])) end
	check(ok and near(legs[1].pts[1][3], 100) and near(legs[1].pts[#legs[1].pts][3], 130),
		"a leg is drawn at the profile's height along the track")
	local g = ofColor(groundShapes(st), "leg")[1]
	local gok = true
	for _, p in ipairs(g.pts) do gok = gok and near(p[3], slope(p[1], p[2])) end
	check(gok, "with no profile, a leg is drawn on the ground")
end

-- Turn circles, end circles and brackets lift with the legs: a turn at the leg's height at its PI,
-- a bracket at the track's at its tangent point, a ground end on the ground, a track end at its own.
do
	local sl = assert(E.new(vend(0, 0, 0, 100, 0), vend(500, 400, -90, 130, 0)))
	local prof = assert(E.profile(sl))
	local function trackZ(x, y) return P.heightAt(prof, (E.chainageAt(sl, x, y))) end
	local ss = shapes(sl)
	local turn = E.turn(sl, 2)
	local tc = ofColor(ss, turn.mobility)[1]
	check(tc ~= nil and near(tc.z, trackZ(turn.x, turn.y)) and tc.z > 100 and tc.z < 130,
		"a turn's circle sits at the leg's height at its PI")
	local ok, n = true, 0
	for _, h in ipairs(E.handles(sl)) do
		if h.kind == "entry" or h.kind == "exit" then
			n = n + 1
			for _, b in ipairs(ofColor(ss, "bracket")) do
				if near(b.pts[3][1] + b.pts[4][1], 2 * h.x) and near(b.pts[3][2] + b.pts[4][2], 2 * h.y) then
					for _, q in ipairs(b.pts) do ok = ok and near(q[3], trackZ(h.x, h.y)) end
				end
			end
		end
	end
	check(ok and n == 2, "a bracket sits at the track's height at its tangent point")
	-- a ground end stays on the ground; a track end being dragged (held) at the track's height
	local tg = assert(E.new(vend(0, 0, 0, 100, 0), gnd(300, 200, 104)))
	local ge = ofColor(shapes(tg), "groundEnd")[1]
	check(ge ~= nil and near(ge.z, slope(300, 200)), "a ground end's circle stays on the ground")
	local onto = vend(500, 400, -90, 130, 0)
	onto.kind, onto.node = "track", 1
	assert(E.moveEnd(tg, 3, onto))
	local held = ofColor(shapes(tg), "groundEnd")[1]
	check(held ~= nil and near(held.z, 130), "a held track end's circle sits at the track's height")
end

-- The hot or dragged handle is "hot"; other turns their mobility; ground ends "groundEnd".
do
	local turn = E.turn(bg, 2)
	local idle = shapes(bg)
	local function roles(ss) local out = {} for _, s in ipairs(ss) do if turnRole(s) then out[#out + 1] = s.color end end return table.concat(out, " ") end
	check(roles(idle) == "groundEnd " .. turn.mobility, "idle: the turn in its mobility colour, the ground end groundEnd: " .. roles(idle))
	check(roles(shapes(bg, { hit = turn })) == "groundEnd hot", "the turn under the mouse is hot")
	check(roles(shapes(bg, { drag = { kind = "end", i = 3 }, hit = turn })) == "hot " .. turn.mobility, "the dragged end is hot, over the one under the mouse")
	local turnCircle = ofColor(idle, turn.mobility)[1]
	local groundCircle = ofColor(groundShapes(bg), turn.mobility)[1]
	check(turnCircle.r == R and near(turnCircle.x, turn.x) and near(groundCircle.z, slope(turn.x, turn.y)) and turnCircle.step == Gz.GIZMO_STEP,
		"a turn's circle: a grab radius round it, at the ground's height with no profile")
	local leg = { kind = "leg", i = 1 }
	check(#ofColor(shapes(bg, { hit = leg }), "hot") == 1 and ofColor(shapes(bg, { hit = leg }), "hot")[1].kind == "line",
		"the leg under the mouse is hot")
	check(#ofColor(shapes(bg, { hit = leg, drag = turn }), "hot") == 1 and ofColor(shapes(bg, { hit = leg, drag = turn }), "hot")[1].kind == "circle",
		"...but not while something is dragged")
	local entry = nil
	for _, h in ipairs(E.handles(bg)) do if h.kind == "entry" then entry = h end end
	local hotBracket = ofColor(shapes(bg, { hit = entry }), "hot")
	check(#hotBracket == 1 and hotBracket[1].kind == "line" and #ofColor(shapes(bg, { hit = entry }), "bracket") == 1,
		"the bracket under the mouse is hot, the other stays a bracket")
end

-- A bracket's points open towards its curve: tips along the leg, the bar across it.
do
	local hs = {}
	for _, h in ipairs(E.handles(bg)) do if h.kind == "entry" or h.kind == "exit" then hs[#hs + 1] = h end end
	local bs = ofColor(groundShapes(bg), "bracket")
	local ok = #bs == #hs and #bs == 2
	for k, b in ipairs(bs) do
		local h = hs[k]
		local function along(p) return (p[1] - h.x) * h.ux + (p[2] - h.y) * h.uy end
		local function across(p) return -(p[1] - h.x) * h.uy + (p[2] - h.y) * h.ux end
		local z = slope(h.x, h.y)
		ok = ok and #b.pts == 6 and b.width == W
			and near(along(b.pts[1]), E.BRACKET_TIP * R) and near(along(b.pts[6]), E.BRACKET_TIP * R)
			and near(along(b.pts[3]), 0) and near(along(b.pts[4]), 0)
			and near(across(b.pts[1]), E.BRACKET_BAR * R) and near(across(b.pts[6]), -E.BRACKET_BAR * R)
		for _, p in ipairs(b.pts) do ok = ok and near(p[3], z) end
	end
	check(ok, "a bracket: a bar across the leg, its tips along it towards its curve, flat at the ground's height with no profile")
end

-- With the eye known (the mouse's view ray), each handle is drawn at its own grab radius (what
-- is drawn is what is clicked): far off, the 50 m ceiling; a bracket's bar and tips with it.
do
	local turn = E.turn(bg, 2)
	local farRay = { ex = turn.x, ey = turn.y - 8000, ez = 6000, gx = turn.x, gy = turn.y, gz = 0 }
	local ss = shapes(bg, { ray = farRay })
	local c = ofColor(ss, turn.mobility)[1]
	check(c ~= nil and near(c.r, 50), "far from the eye, a turn's circle at the 50 m ceiling")
	local b = ofColor(ss, "bracket")[1]
	local h = nil
	for _, hh in ipairs(E.handles(bg)) do if hh.kind == "entry" or hh.kind == "exit" then h = h or hh end end
	local across = -(b.pts[1][1] - h.x) * h.uy + (b.pts[1][2] - h.y) * h.ux
	local along = (b.pts[1][1] - h.x) * h.ux + (b.pts[1][2] - h.y) * h.uy
	check(near(across, E.BRACKET_BAR * 50) and near(along, E.BRACKET_TIP * 50), "...and a bracket's bar and tips at its own radius")
	local osc = ofColor(ss, "osculating")[1]
	check(osc ~= nil and osc.step > 50 / 4, "zoomed far out, an osculating circle's steps grow past the grab ceiling: " .. tostring(osc and osc.step))
	-- the eye 300 m from the turn: its circle smaller than the ground end's, further off
	local nearRay = { ex = turn.x, ey = turn.y, ez = 300, gx = turn.x, gy = turn.y, gz = 0 }
	local s2 = shapes(bg, { ray = nearRay })
	local tc, gc = ofColor(s2, turn.mobility)[1], ofColor(s2, "groundEnd")[1]
	check(tc.r < gc.r and tc.r >= 3 and tc.r < 10, string.format("nearer the eye, a smaller circle (%.1f m, %.1f m)", tc.r, gc.r))
end

-- Vertical mode: a circle on the ground per point, and a post up to it when off the ground.
do
	local v = assert(E.new(vend(0, 0, 0, 100, 0), gnd(1000, 0, 3)))
	E.insertElevation(v, 400)
	E.insertElevation(v, 410) -- (too close to the one before)
	E.insertElevation(v, 700)
	local pts = E.points(v)
	local function flat() return 3 end -- the ground: at the ground end's height
	local function vshapes(fields) fields = fields or {} fields.mode = "vertical" return shapes(v, fields, flat) end
	local function roles(ss) local out = {} for _, s in ipairs(ss) do if s.kind == "circle" then out[#out + 1] = s.color end end return table.concat(out, " ") end
	local idle = vshapes()
	check(roles(idle) == "fixed ray tooClose ray groundEnd", "vertical: a track end fixed, elevation points slide, one too close, the ground end: " .. roles(idle))
	check(roles(vshapes({ hit = { kind = "point", i = 2 } })) == "fixed hot tooClose ray groundEnd", "the point under the mouse is hot")
	check(roles(vshapes({ hit = { kind = "track", i = 1 } })) == "fixed ray tooClose ray groundEnd", "...but not the track")
	check(roles(vshapes({ dragEl = { i = 4 }, hit = { kind = "point", i = 2 } })) == "fixed ray tooClose hot groundEnd", "the dragged point is hot, over the one under the mouse")
	check(roles(vshapes({ selected = 4 })) == "fixed ray tooClose selected groundEnd", "the selected point")
	check(roles(vshapes({ selected = 4, hit = { kind = "point", i = 4 } })) == "fixed ray tooClose hot groundEnd", "hot over selected")
	check(roles(vshapes({ hit = { kind = "point", i = 1 } })) == "fixed ray tooClose ray groundEnd", "a track end stays fixed under the mouse")
	-- a post per point more than 0.1 m off the ground (the ground end is on it), from the ground up
	local ok, k, posts, last = true, 0, 0, nil
	for _, s in ipairs(idle) do
		if s.kind == "circle" then
			k, last = k + 1, s
			ok = ok and near(s.x, pts[k].x) and near(s.y, pts[k].y) and s.z == 3 and s.r == R
		else
			posts = posts + 1
			ok = ok and s.color == last.color and s.width == last.width
				and #s.pts == 2 and s.pts[1][3] == 3 and near(s.pts[2][3], pts[k].z) and near(s.pts[1][1], pts[k].x)
		end
	end
	check(ok and k == #pts and posts == #pts - 1, "vertical: a circle on the ground at each point, a post up to each one off the ground")
	check(#ofColor(idle, "leg") == 0 and #ofColor(idle, "osculating") == 0, "vertical: no legs, no osculating circles")
	-- with no profile, nothing (the stub stands in for a profile that cannot be solved)
	check(#withoutProfile(vshapes) == 0, "vertical with no profile: nothing")
	-- with the eye known, each circle at its point's own grab radius: 1 km over point 2, 20 m
	local p2 = pts[2]
	local above = { ex = p2.x, ey = p2.y, ez = p2.z + 1000, gx = p2.x, gy = p2.y, gz = 3 }
	local sized = {}
	for _, s in ipairs(vshapes({ ray = above })) do if s.kind == "circle" then sized[#sized + 1] = s end end
	check(near(sized[2].r, 20) and sized[1].r > 20 and sized[5].r > 20,
		"vertical: with the eye known, each circle at its own radius: 20 m 1 km under the eye, more further off")
end

-- Osculating circles: one per arc, round its centre, of its radius.
-- circle c osculates piece seg at point p (tangent v): R from p, square to v, on side (1: left)
local function osculatesAt(c, seg, p, v, side)
	local dx, dy = c.x - p.x, c.y - p.y
	return math.abs(c.r - seg.radius) < 1e-9 and math.abs(math.sqrt(dx * dx + dy * dy) - seg.radius) < 1e-6
		and math.abs(v.x * dx + v.y * dy) < 1e-6 * seg.radius and (v.x * dy - v.y * dx) * side > 0
end
local function arcsOf(e)
	local as = {}
	for _, seg in ipairs(E.path(e)) do if seg.kind == "arc" then as[#as + 1] = seg end end
	return as
end
-- the circle is centred R from the arc's start and end, on the side the curve turns to
local function osculates(e, side, what)
	local cs, as = Gz.circles(e), arcsOf(e)
	local a = as[1]
	check(#cs == 1 and #as == 1 and osculatesAt(cs[1], a, a.p, a.v, side)
		and math.abs(math.sqrt((a.q.x - cs[1].x) ^ 2 + (a.q.y - cs[1].y) ^ 2) - a.radius) < 1e-6,
		what .. ": one circle, centred inside the curve, of the arc's radius")
end
osculates(E.new(endAt(0, 0, 0), endAt(500, 400, -90)), 1, "a left turn")
osculates(E.new(endAt(0, 0, 0), endAt(500, -400, 90)), -1, "a right turn")
check(#Gz.circles(E.new(endAt(0, 0, 0), endAt(500, 0, 180))) == 0, "a straight path: no circles")
-- a 2° corner: its spirals take the whole turn and meet with no arc between, at curvature 1/R
local zs = E.new(endAt(0, 0, 0), endAt(150 + 150 * math.cos(math.rad(2)), 150 * math.sin(math.rad(2)), 182))
local zpath, kinds = E.path(zs), {}
for _, seg in ipairs(zpath) do kinds[#kinds + 1] = seg.kind end
local out, zc = zpath[3], Gz.circles(zs)
check(table.concat(kinds, " ") == "straight in out straight" and #zc == 1
	and osculatesAt(zc[1], out, out.p, out.v, 1)
	and math.abs(zc[1].mx - out.p.x) + math.abs(zc[1].my - out.p.y) < 1e-9,
	"a corner of no sweep: one circle where its spirals meet, of their radius")
-- on a sloped profile a circle sits at the track's height at its arc's midpoint, not the ground's
local sl = assert(E.new(vend(0, 0, 0, 100, 0), vend(500, 400, -90, 130, 0)))
local slc = Gz.circles(sl)[1]
local slz = P.heightAt(assert(E.profile(sl)), (E.chainageAt(sl, slc.mx, slc.my)))
check(slc.z ~= nil and math.abs(slc.z - slz) < 1e-3 and slz > 101 and slz < 129,
	"a sloped profile: the circle sits at the profile's height at its arc's midpoint")
-- ...and a corner of no sweep, at the profile's height where its spirals meet
local zsl = assert(E.new(vend(0, 0, 0, 100, 0), vend(150 + 150 * math.cos(math.rad(2)), 150 * math.sin(math.rad(2)), 182, 110, 0)))
local zsp = E.path(zsl)
local meet = G.length(zsp[1]) + G.length(zsp[2])
local zslz = Gz.circles(zsl)[1].z
check(zsp[3].kind == "out" and zslz ~= nil and math.abs(zslz - P.heightAt(assert(E.profile(zsl)), meet)) < 1e-9
	and zslz > 100 and zslz < 110,
	"a sloped corner of no sweep: the circle sits at the profile's height where its spirals meet")
-- drawn: at that height, as wide as the other gizmos, in steps that grow with the zoom
do
	local c = ofColor(shapes(sl), "osculating")[1]
	check(c ~= nil and c.kind == "circle" and near(c.z, slc.z) and c.r == slc.r and c.width == W
		and c.step == math.max(Gz.GIZMO_STEP, R / 4), "an osculating circle is drawn at the track's height, as wide as the rest")
	local wide = Gz.of(session(sl, { grab = 400 }), slope)
	check(ofColor(wide, "osculating")[1].step == 100, "zoomed out, its steps grow: a quarter of the grab radius")
	-- with no profile, at the ground at its arc's midpoint (the stub stands in for one that cannot be solved)
	local g = ofColor(withoutProfile(function() return shapes(sl) end), "osculating")[1]
	check(g ~= nil and near(g.z, slope(slc.mx, slc.my)), "with no profile, an osculating circle sits on the ground at its arc's midpoint")
end

-- Transition spirals: a line along every in and out piece, display only.
local function spiralsOf(e) return ofColor(shapes(e), "spiral") end
local function close(p, v, tol) return math.abs(p[1] - v.x) + math.abs(p[2] - v.y) < (tol or 1e-6) end
-- the line runs from its piece's start to the next piece's start, and every point is on the track
local function alongSpirals(e, what)
	local path, ls = E.path(e), spiralsOf(e)
	local ok, k, worst, s0 = true, 0, 0, 0
	for i, seg in ipairs(path) do
		local len = G.length(seg)
		if seg.kind == "in" or seg.kind == "out" then
			k = k + 1
			local l = ls[k]
			local nextStart = path[i + 1].p
			ok = ok and l ~= nil and l.kind == "line" and l.width == W and l.step == Gz.GIZMO_STEP
				and close(l.pts[1], seg.p) and close(l.pts[#l.pts], nextStart, 1e-3)
			for j, p in ipairs(l and l.pts or {}) do
				local s, off = E.chainageAt(e, p[1], p[2])
				worst = math.max(worst, off)
				ok = ok and s >= s0 - 1e-3 and s <= s0 + len + 1e-3 -- (on its own piece, not the next)
				if j > 1 then ok = ok and dist({ x = p[1], y = p[2] }, { x = l.pts[j - 1][1], y = l.pts[j - 1][2] }) <= 10 + 1e-6 end
			end
		end
		s0 = s0 + len
	end
	check(ok and k == 2 and #ls == 2 and worst < 0.05,
		string.format("%s: 2 spiral lines, each from its spiral's start to its end, pieces of 10 m at most, on its piece (%.3f m off)", what, worst))
end
alongSpirals(E.new(endAt(0, 0, 0), endAt(500, 400, -90)), "a left turn")
alongSpirals(E.new(endAt(0, 0, 0), endAt(500, -400, 90)), "a right turn")
check(#spiralsOf(E.new(endAt(0, 0, 0), endAt(500, 0, 180))) == 0, "a straight path: no spiral lines")
do
	local zl = spiralsOf(zs)
	check(#zl == 2 and close(zl[1].pts[#zl[1].pts], { x = zl[2].pts[1][1], y = zl[2].pts[1][2] }, 1e-3),
		"a corner of no sweep: 2 spiral lines that meet")
	check(#ofColor(shapes(bg, { hit = { kind = "leg", i = 1 } }), "spiral") == 2 and #ofColor(shapes(bg, { mode = "vertical" }), "spiral") == 0,
		"spirals: never hot, none in vertical mode")
	-- on a sloped route, at the profile's height; with no profile, on the ground
	local prof, ok, n = assert(E.profile(sl)), true, 0
	for _, l in ipairs(spiralsOf(sl)) do
		for _, p in ipairs(l.pts) do
			n = n + 1
			ok = ok and math.abs(p[3] - P.heightAt(prof, (E.chainageAt(sl, p[1], p[2])))) < 1e-2
		end
	end
	check(ok and n > 4, "a sloped route: every spiral point at the profile's height")
	local flat, okg = withoutProfile(function() return spiralsOf(sl) end), true
	for _, l in ipairs(flat) do for _, p in ipairs(l.pts) do okg = okg and near(p[3], slope(p[1], p[2])) end end
	check(#flat == 2 and okg, "with no profile, spiral points on the ground")
end

H.done()
