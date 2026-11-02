-- What the tool reads out about the path: the tooltip's summary lines and a badge at each curve
-- with its speed and grade. The speeds are the game's own curve speed limits, read from the
-- ghost's proposal data by the GUI. No game API here, so test/readout_test.lua runs it outside the
-- game.

local geometry = require("westrom_track_geometry::/track_geometry/tg_geometry.script.tl")
local alignment = require("westrom_track_geometry::/track_geometry/tg_alignment.script.tl")
local profiles = require("westrom_track_geometry::/track_geometry/tg_profile.script.tl")

-- One curve of the path (entry spiral, arc, exit spiral) by chainage.
local record Curve
	s0 : number
	s1 : number
	sMid : number -- the middle of its arc
end

-- A badge: where it goes and what it says. "curve": at a curve's arc middle, with its speed;
-- "along": every so far along the path, with its speed (as the game's builder badges each piece);
-- "point": at an elevation point (or an end), with its height; "span": halfway between two;
-- "grade": every so far along the profile. All of them with the grade.
local record Badge
	kind : string
	x : number
	y : number
	z : number
	speed : number -- the game's slowest curve limit over the curve (m/s); nil while unknown
	grade : number -- rise over run at the badge
	slowest : boolean -- the path's slowest curve
end

local record Readout
	Curve : Curve
	Badge : Badge
	grades : function(nodes : {alignment.Sample}, z : {number}) : {number}
	curves : function(path : {geometry.Segment}) : {Curve}
	badges : function(nodes : {alignment.Sample}, z : {number}, speeds : {number}, curves : {Curve}) : {Badge}
	alongBadges : function(nodes : {alignment.Sample}, z : {number}, speeds : {number}, every : number) : {Badge}
	profileBadges : function(nodes : {alignment.Sample}, p : profiles.Profile, every : number) : {Badge}
	summary : function(nodes : {alignment.Sample}, z : {number}, speeds : {number}, trackSpeed : number, minRadius : number) : {string}
end

local M : Readout = {}

-- No curve limit: the game's value on straight pieces, or one this fast (m/s).
local NO_LIMIT = 1000.0
-- Segments this short or shorter count as zero-length (m), as in tg_alignment.
local ZERO = 1e-6

-- Each piece's grade: rise over horizontal run.
function M.grades(nodes : {alignment.Sample}, z : {number}) : {number}
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
		if len > ZERO then
			local k = seg.kind
			if k == "straight" then
				cur = nil
			elseif k == "in" or (k == "arc" and prev ~= "in") then
				cur = { s0 = s, s1 = s + len, sMid = s + len / 2 }
				out[#out + 1] = cur
			end
			if cur ~= nil then
				cur.s1 = s + len
				if k == "arc" then cur.sMid = s + len / 2 end
			end
			prev = k
			s = s + len
		end
	end
	return out
end

-- The piece (between nodes i and i + 1) at chainage s.
local function pieceAt(nodes : {alignment.Sample}, s : number) : integer
	for i = 1, #nodes - 1 do
		if s <= nodes[i + 1].s then return i end
	end
	return #nodes - 1
end

-- A badge at each curve's arc middle. speeds (m/s per piece, nil where unknown) is nil until the
-- game has made the ghost's data.
function M.badges(nodes : {alignment.Sample}, z : {number}, speeds : {number}, curves : {Curve}) : {Badge}
	local out : {Badge} = {}
	if #nodes < 2 then return out end
	local gs = M.grades(nodes, z)
	local slow = math.huge
	for _, c in ipairs(curves) do
		local i = pieceAt(nodes, c.sMid)
		local a, b = nodes[i], nodes[i + 1]
		local t = b.s > a.s and math.max(0, math.min(1, (c.sMid - a.s) / (b.s - a.s))) or 0.0
		local v : number = nil
		if speeds ~= nil then
			for j = 1, #nodes - 1 do
				local mid = (nodes[j].s + nodes[j + 1].s) / 2
				local sp = speeds[j]
				if mid >= c.s0 and mid <= c.s1 and sp ~= nil and sp < NO_LIMIT then
					v = v == nil and sp or math.min(v, sp)
				end
			end
		end
		if v ~= nil then slow = math.min(slow, v) end
		out[#out + 1] = { kind = "curve", x = a.x + t * (b.x - a.x), y = a.y + t * (b.y - a.y), z = z[i] + t * (z[i + 1] - z[i]),
			speed = v, grade = gs[i], slowest = false }
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
	local gs = M.grades(nodes, z)
	local len = nodes[#nodes].s
	local s = every
	while s <= len - every / 2 do
		local i = pieceAt(nodes, s)
		local a, b = nodes[i], nodes[i + 1]
		local t = b.s > a.s and math.max(0, math.min(1, (s - a.s) / (b.s - a.s))) or 0.0
		local v : number = nil
		if speeds ~= nil then
			for j = 1, #nodes - 1 do
				local mid = (nodes[j].s + nodes[j + 1].s) / 2
				local sp = speeds[j]
				if math.abs(mid - s) <= every / 2 and sp ~= nil then v = v == nil and sp or math.min(v, sp) end
			end
		end
		out[#out + 1] = { kind = "along", x = a.x + t * (b.x - a.x), y = a.y + t * (b.y - a.y), z = z[i] + t * (z[i + 1] - z[i]),
			speed = v, grade = gs[i], slowest = false }
		s = s + every
	end
	return out
end

-- The vertical profile's badges: one at every point of the profile (the ends included) with its
-- height and grade, one halfway along each span with the grade there, and one every `every` m
-- with the grade (none closer than half that to a point).
function M.profileBadges(nodes : {alignment.Sample}, p : profiles.Profile, every : number) : {Badge}
	local out : {Badge} = {}
	if #nodes < 2 then return out end
	local function at(kind : string, s : number)
		local x, y = alignment.pointAt(nodes, s)
		out[#out + 1] = { kind = kind, x = x, y = y, z = profiles.heightAt(p, s), grade = profiles.gradeAt(p, s), slowest = false }
	end
	local pts = p.points
	for i, q in ipairs(pts) do
		at("point", q.s)
		if i < #pts then at("span", (q.s + pts[i + 1].s) / 2) end
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
	local gs = M.grades(nodes, z)
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
