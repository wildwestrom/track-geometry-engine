-- What the tool reads out about the path: the tooltip's summary lines, a badge at each curve with
-- its radius and speed, and badges along the path with their speed and grade. The speeds are the
-- game's own curve speed limits, read from the ghost's proposal data by the GUI. No game API here,
-- so test/readout_test.lua runs it outside the game.

local geometry = require("track_geometry_tool::/track_geometry/tg_geometry.script.tl")
local alignment = require("track_geometry_tool::/track_geometry/tg_alignment.script.tl")
local profiles = require("track_geometry_tool::/track_geometry/tg_profile.script.tl")

-- One curve of the path (entry spiral, arc, exit spiral) by chainage.
local record Curve
	s0 : number
	s1 : number
	sMid : number -- the middle of its arc
	radius : number -- its arc's radius (m); nil with no arc
	turn : integer -- the edit's turn it is the curve of (tg_edit's index)
end

-- A badge: where it goes and what it says. "curve": at a curve's arc middle (the middle of the
-- curve, with no arc), with its radius and speed; "along": every so far along the path, with its
-- speed and grade (as the game's builder badges each piece); "point": at an elevation point (or an
-- end), with its height and grade; "span": halfway between two, and "grade": every so far along
-- the profile, with the grade.
local record Badge
	kind : string
	x : number
	y : number
	z : number
	speed : number -- the game's slowest curve limit over the curve (m/s); nil while unknown
	radius : number -- curves: the arc's radius (m); nil with no arc
	turn : integer -- curves: the edit's turn it is the curve of (tg_edit's index)
	grade : number -- rise over run at the badge
	slowest : boolean -- the path's slowest curve
	steep : boolean -- spans: too steep (past the grade limit at a node over it)
	dx : number -- the path's direction at the badge (a unit vector, on the ground)
	dy : number
	side : number -- where it goes off the path: 1 to its left, -1 to its right (a curve's: its
	              -- inside; the others: the outside of the nearest curve along the path), 0 either (no curve)
end


local record Readout
	Curve : Curve
	Badge : Badge
	curves : function(path : {geometry.Segment}) : {Curve}
	badges : function(nodes : {alignment.Sample}, z : {number}, speeds : {number}, curves : {Curve}) : {Badge}
	alongBadges : function(nodes : {alignment.Sample}, z : {number}, speeds : {number}, every : number) : {Badge}
	profileBadges : function(nodes : {alignment.Sample}, p : profiles.Profile, every : number, limit ?: number) : {Badge}
	summary : function(nodes : {alignment.Sample}, z : {number}, speeds : {number}, trackSpeed : number, minRadius : number) : {string}
	pieceSpeeds : function(pieceOf : {integer : integer}, m : integer, edgeSpeed : function(edge : integer) : number) : {number}
	sketchSpeeds : function(nodes : {alignment.Sample}, curves : {Curve}, cached : function(R : number) : number, measure : function(R : number) : number, prev : {integer : number}) : {number}, {integer : number}
	badgeCorner : function(px : number, py : number, tx : number, ty : number, lx : number, ly : number, side : number, bw : number, bh : number, gap : number) : number, number
	curveCorner : function(px : number, py : number, tx : number, ty : number, lx : number, ly : number, side : number, radius : number, bw : number, bh : number, far : number, gap : number) : number, number
	screenFrame : function(screenAt : function(x : number, y : number) : number, number, x : number, y : number, dx : number, dy : number, span : number, maxLen : number) : number, number, number, number, number, number
end

local M : Readout = {}

-- No curve limit: the game's value on straight pieces, or one this fast (m/s).
local NO_LIMIT = 1000.0

-- Each piece's grade: rise over horizontal run.
local function grades(nodes : {alignment.Sample}, z : {number}) : {number}
	local out : {number} = {}
	for i = 1, #nodes - 1 do
		local run = math.sqrt((nodes[i + 1].x - nodes[i].x) ^ 2 + (nodes[i + 1].y - nodes[i].y) ^ 2)
		out[i] = run > 0 and (z[i + 1] - z[i]) / run or 0.0
	end
	return out
end

-- The path's curves. A curve starts at an entry spiral, or at an arc not entered by one, and runs
-- to the end of its exit spiral (or arc); two corners with no straight between are two curves.
function M.curves(path : {geometry.Segment}) : {Curve}
	local out : {Curve} = {}
	local s, cur, prev = 0.0, nil as Curve, nil as string
	for _, seg in ipairs(path) do
		local len = geometry.length(seg)
		if len > alignment.ZERO then
			local k = seg.kind
			if k == "straight" then
				cur = nil
			elseif k == "in" or (k == "arc" and prev ~= "in") then
				cur = { s0 = s, s1 = s + len, sMid = s + len / 2, turn = seg.corner }
				out[#out + 1] = cur
			end
			if cur ~= nil then
				cur.s1 = s + len
				if k == "arc" then cur.sMid, cur.radius = s + len / 2, math.abs(seg.radius) end
			end
			prev = k
			s = s + len
		end
	end
	return out
end

-- A turning stretch of the path: a run of pieces turning the same way.
local record Stretch
	s0 : number -- its chainage from and to
	s1 : number
	way : number -- 1 left, -1 right
end

-- The path's turning stretches.
local function turning(nodes : {alignment.Sample}) : {Stretch}
	local out : {Stretch} = {}
	for i = 1, #nodes - 1 do
		local d = (nodes[i + 1].heading - nodes[i].heading + math.pi) % (2 * math.pi) - math.pi
		local way = d > 1e-6 and 1 or d < -1e-6 and -1 or 0
		local last = out[#out]
		if way ~= 0 and last ~= nil and last.way == way and last.s1 >= nodes[i].s - 1e-9 then
			last.s1 = nodes[i + 1].s
		elseif way ~= 0 then
			out[#out + 1] = { s0 = nodes[i].s, s1 = nodes[i + 1].s, way = way }
		end
	end
	return out
end

-- The side (Badge.side) of a badge at chainage s: the outside of the nearest turning stretch.
local function outside(turns : {Stretch}, s : number) : number
	local best, side = math.huge, 0.0
	for _, r in ipairs(turns) do
		local d = s < r.s0 and r.s0 - s or s > r.s1 and s - r.s1 or 0.0
		if d < best then best, side = d, -r.way end
	end
	return side
end

-- A badge at chainage s: its point, the path's direction there and its side (turns: turning(nodes)).
local function badgeAt(kind : string, nodes : {alignment.Sample}, turns : {Stretch}, s : number) : Badge, integer, number
	local i, t = alignment.locate(nodes, s)
	local a, b = nodes[i], nodes[i + 1] or nodes[i]
	local lx, ly = b.x - a.x, b.y - a.y
	local l = math.sqrt(lx * lx + ly * ly)
	local dx, dy = l > 0 and lx / l or math.cos(a.heading), l > 0 and ly / l or math.sin(a.heading)
	return { kind = kind, x = a.x + t * lx, y = a.y + t * ly, dx = dx, dy = dy, side = outside(turns, s), slowest = false }, i, t
end

-- A badge at chainage s, with the grade of the piece there and speed v.
local function badge(kind : string, nodes : {alignment.Sample}, turns : {Stretch}, z : {number}, gs : {number}, s : number, v : number) : Badge
	local bd, i, t = badgeAt(kind, nodes, turns, s)
	bd.z, bd.speed, bd.grade = z[i] + t * (z[i + 1] - z[i]), v, gs[i]
	return bd
end

-- The slowest of the speeds (m/s per piece; nil: none known) on the pieces whose middle `keep` takes.
local function slowest(nodes : {alignment.Sample}, speeds : {number}, keep : function(mid : number, sp : number) : boolean) : number
	local v : number = nil
	for j = 1, speeds ~= nil and #nodes - 1 or 0 do
		local sp = speeds[j]
		if sp ~= nil and keep((nodes[j].s + nodes[j + 1].s) / 2, sp) then v = v == nil and sp or math.min(v, sp) end
	end
	return v
end

-- A badge at each curve's arc middle (with no arc, the curve's middle), on its inside, with its
-- radius and its arc's centre. speeds (m/s per piece, nil where unknown) is nil until the game has
-- made the ghost's data.
function M.badges(nodes : {alignment.Sample}, z : {number}, speeds : {number}, curves : {Curve}) : {Badge}
	local out : {Badge} = {}
	if #nodes < 2 then return out end
	local gs = grades(nodes, z)
	local turns = turning(nodes)
	local slow = math.huge
	for _, c in ipairs(curves) do
		local v = slowest(nodes, speeds, function(mid : number, sp : number) : boolean return mid >= c.s0 and mid <= c.s1 and sp < NO_LIMIT end)
		if v ~= nil then slow = math.min(slow, v) end
		local bd = badge("curve", nodes, turns, z, gs, c.radius ~= nil and c.sMid or (c.s0 + c.s1) / 2, v)
		bd.radius, bd.turn, bd.side = c.radius, c.turn, -bd.side
		out[#out + 1] = bd
	end
	-- (only when there is a choice: one curve is the slowest of one)
	if #out > 1 and slow < math.huge then
		for _, bd in ipairs(out) do bd.slowest = bd.speed ~= nil and bd.speed <= slow + 1e-6 end
	end
	return out
end

-- A badge every `every` m along the path (none closer than half that to an end), with the grade
-- of the piece there and the slowest curve limit within half `every` of it. speeds as for badges.
function M.alongBadges(nodes : {alignment.Sample}, z : {number}, speeds : {number}, every : number) : {Badge}
	local out : {Badge} = {}
	if #nodes < 2 then return out end
	local gs = grades(nodes, z)
	local turns = turning(nodes)
	local len = nodes[#nodes].s
	local s = every
	while s <= len - every / 2 do
		local v = slowest(nodes, speeds, function(mid : number) : boolean return math.abs(mid - s) <= every / 2 end)
		out[#out + 1] = badge("along", nodes, turns, z, gs, s, v)
		s = s + every
	end
	return out
end

-- The vertical profile's badges: one at every point of the profile (the ends included) with its
-- height and grade, one halfway along each span with the grade there, and one every `every` m
-- with the grade (none closer than half that to a point). A span whose grade at any of the
-- nodes over it (its ends included) is past limit is marked too steep (none without a limit).
function M.profileBadges(nodes : {alignment.Sample}, p : profiles.Profile, every : number, limit ?: number) : {Badge}
	local out : {Badge} = {}
	if #nodes < 2 then return out end
	local turns = turning(nodes)
	local function at(kind : string, s : number) : Badge
		local b = badgeAt(kind, nodes, turns, s)
		b.z, b.grade, b.steep = profiles.heightAt(p, s), profiles.gradeAt(p, s), false
		out[#out + 1] = b
		return b
	end
	local function steep(s0 : number, s1 : number) : boolean
		if limit == nil then return false end
		for _, nd in ipairs(nodes) do
			if nd.s >= s0 and nd.s <= s1 and math.abs(profiles.gradeAt(p, nd.s)) > limit then return true end
		end
		return false
	end
	local pts = p.points
	for i, q in ipairs(pts) do
		at("point", q.s)
		if i < #pts then at("span", (q.s + pts[i + 1].s) / 2).steep = steep(q.s, pts[i + 1].s) end
	end
	local len = pts[#pts].s
	local s = every
	while s <= len - every / 2 do
		local clear = true
		for i, q in ipairs(pts) do
			local mid = i < #pts and (q.s + pts[i + 1].s) / 2 or nil
			if math.abs(q.s - s) < every / 2 or (mid ~= nil and math.abs(mid - s) < every / 2) then clear = false end
		end
		if clear then at("grade", s) end
		s = s + every
	end
	return out
end

-- Each of the m plan pieces' curve speed (m/s; nil where none is known): the slowest of its
-- edges' (edgeSpeed, nil where unknown), the edges found through pieceOf (tg_layout).
function M.pieceSpeeds(pieceOf : {integer : integer}, m : integer, edgeSpeed : function(edge : integer) : number) : {number}
	local out : {number} = {}
	for edge, i in pairs(pieceOf) do
		local v = edgeSpeed(edge)
		if i >= 1 and i <= m and v ~= nil and (out[i] == nil or v < out[i]) then out[i] = v end
	end
	return out
end

-- A sketch has no game check, so its curve speeds come from the speed probe's lookup on each
-- curve's radius (cached: what it knows; measure: a dry run). The pieces of a curve take its speed,
-- the others none (NO_LIMIT). At most one radius is measured per call (the dry run costs); a curve
-- not known yet keeps its speed from `prev` (by turn, the last call's second result), or has none.
-- Approximate: the game's own check of the settled ghost replaces it.
function M.sketchSpeeds(nodes : {alignment.Sample}, curves : {Curve}, cached : function(R : number) : number, measure : function(R : number) : number, prev : {integer : number}) : {number}, {integer : number}
	local byTurn : {integer : number} = {}
	local budget = 1
	local ofCurve : {number} = {}
	for i, c in ipairs(curves) do
		local v : number = nil
		if c.radius ~= nil then
			v = cached(c.radius)
			if v == nil and budget > 0 then
				budget = budget - 1
				v = measure(c.radius)
			end
		end
		if v == nil and c.turn ~= nil and prev ~= nil then v = prev[c.turn] end
		ofCurve[i] = v
		if v ~= nil and c.turn ~= nil then byTurn[c.turn] = v end
	end
	local out : {number} = {}
	for j = 1, #nodes - 1 do
		local mid = (nodes[j].s + nodes[j + 1].s) / 2
		out[j] = NO_LIMIT
		for i, c in ipairs(curves) do
			if mid >= c.s0 and mid <= c.s1 then out[j] = ofCurve[i]; break end
		end
	end
	return out, byTurn
end

-- Where a badge's top left corner goes on the screen (px, y down). (px, py): its point on the track;
-- (tx, ty): a metre along the track, on the screen; (lx, ly): a metre across it to the left; side:
-- the badge's (Badge.side). The badge (bw x bh) goes square to the track on the screen, on its side,
-- its nearest edge gap px off; with no side, on the one toward the top of the screen (the left,
-- where the track runs straight up or down it). Where the
-- track points at the camera (a metre along it under a tenth of one across) its direction on the
-- screen means little: the badge goes straight up.
-- The screen direction square to the track, on the side (badgeCorner's arguments).
local function across(tx : number, ty : number, lx : number, ly : number, side : number) : number, number
	local len = math.sqrt(tx * tx + ty * ty)
	local nx, ny = 0.0, -1.0
	if len > 0 and len >= math.sqrt(lx * lx + ly * ly) / 10 then
		nx, ny = ty / len, -tx / len
		local onSide = side ~= 0 and (nx * lx + ny * ly) * side or ny ~= 0 and -ny or -nx -- (positive: on the side wanted)
		if onSide < 0 then nx, ny = -nx, -ny end
	end
	return nx, ny
end

-- The top left corner of a bw x bh box whose middle is r px from (px, py) along (nx, ny), but
-- never so close that its nearest edge is under gap px off.
local function boxCorner(px : number, py : number, nx : number, ny : number, r : number, bw : number, bh : number, gap : number) : number, number
	-- (the box's middle as far out as its own half reaches along the direction, then the gap)
	local reach = math.max(r, gap + math.abs(nx) * bw / 2 + math.abs(ny) * bh / 2)
	return px + nx * reach - bw / 2, py + ny * reach - bh / 2
end

function M.badgeCorner(px : number, py : number, tx : number, ty : number, lx : number, ly : number, side : number, bw : number, bh : number, gap : number) : number, number
	local nx, ny = across(tx, ty, lx, ly, side)
	return boxCorner(px, py, nx, ny, 0, bw, bh, gap)
end

-- A badge's point (x, y) on the screen (screenAt: the game's world2Screen there), and a metre along
-- the track (dx, dy: its direction there) and a metre across it to the left, on the screen: the
-- (tx, ty), (lx, ly) badgeCorner takes. world2Screen gives whole pixels, and from far off a metre
-- is a fraction of one, so both are read over enough metres (at most maxLen) to span about span
-- px, then scaled back to one. (A straight line stays straight on the screen: its direction is
-- the same read over any length.)
function M.screenFrame(screenAt : function(x : number, y : number) : number, number, x : number, y : number, dx : number, dy : number, span : number, maxLen : number) : number, number, number, number, number, number
	local px, py = screenAt(x, y)
	local L, ax, ay, lx, ly = 1.0, 0.0, 0.0, 0.0, 0.0
	for _ = 1, 4 do
		ax, ay = screenAt(x + dx * L, y + dy * L)
		lx, ly = screenAt(x - dy * L, y + dx * L)
		local m = math.max(math.sqrt((ax - px) ^ 2 + (ay - py) ^ 2), math.sqrt((lx - px) ^ 2 + (ly - py) ^ 2))
		if m >= span or L >= maxLen then break end
		L = math.min(maxLen, L * span / math.max(m, 1))
	end
	return px, py, (ax - px) / L, (ay - py) / L, (lx - px) / L, (ly - py) / L
end

-- Where a curve's badge's top left corner goes on the screen: as badgeCorner (side: the curve's
-- inside), but its middle as far out as the arc's centre, the radius (m; nil with no arc) at the
-- track's scale across it (lx, ly), and at most far px. Its nearest edge stays gap px off the track.
-- (The centre itself is not put on the screen: on a wide curve it is kilometres off, near or behind
-- the camera, where the slightest move swings it all over the screen.)
function M.curveCorner(px : number, py : number, tx : number, ty : number, lx : number, ly : number, side : number, radius : number, bw : number, bh : number, far : number, gap : number) : number, number
	local nx, ny = across(tx, ty, lx, ly, side)
	local r = radius ~= nil and math.min(radius * math.sqrt(lx * lx + ly * ly), far) or far
	return boxCorner(px, py, nx, ny, r, bw, bh, gap)
end

local function kmh(v : number) : string
	return string.format("%.0f km/h", v * 3.6)
end

local function permille(g : number) : string
	return string.format("%+.1f ‰", g * 1000)
end

-- The tooltip lines: the slowest curve limit and where, the grades, the smallest radius. speeds
-- (m/s per piece, nil where unknown) is nil until the game has made the ghost's data.
function M.summary(nodes : {alignment.Sample}, z : {number}, speeds : {number}, trackSpeed : number, minRadius : number) : {string}
	local lines : {string} = {}
	local top = trackSpeed ~= nil and trackSpeed > 0 and (", track " .. kmh(trackSpeed)) or ""
	if speeds == nil then
		lines[#lines + 1] = "Curve limit (game): waiting for the game" .. top
	else
		local slow, at, known = math.huge, 0.0, 0
		for i = 1, #nodes - 1 do
			local v = speeds[i]
			if v ~= nil then known = known + 1 end
			if v ~= nil and v < slow then slow, at = v, nodes[i].s end
		end
		if known == 0 then
			lines[#lines + 1] = "Curve limit (game): the game gave none" .. top
		elseif slow >= NO_LIMIT then
			lines[#lines + 1] = "Curve limit (game): none" .. top
		else
			lines[#lines + 1] = string.format("Curve limit (game): slowest %s at %.0f m%s", kmh(slow), at, top)
		end
	end
	local gs = grades(nodes, z)
	local lo, hi, steep, steepAt : number, number, number, number = math.huge, -math.huge, 0.0, 0.0
	for i, g in ipairs(gs) do
		lo, hi = math.min(lo, g), math.max(hi, g)
		if math.abs(g) > math.abs(steep) then steep, steepAt = g, nodes[i].s end
	end
	if #gs > 0 then
		if hi - lo < 1e-4 then
			lines[#lines + 1] = "Grade: " .. permille(hi) .. " throughout"
		else
			lines[#lines + 1] = string.format("Grade: %s to %s, steepest %s at %.0f m", permille(lo), permille(hi), permille(steep), steepAt)
		end
	end
	if minRadius ~= nil and minRadius < math.huge then
		lines[#lines + 1] = string.format("Smallest radius: %.0f m", minRadius)
	end
	return lines
end

return M
