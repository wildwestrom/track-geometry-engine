-- Where a new track piece crosses existing streets or track at grade: the level crossings and
-- diamond crossings the proposal makes (tg_layout), as the game's own builder does. The engine
-- does not split a crossed street itself (NOTES.md: Roads a proposal crosses are not split), so each
-- crossing found here becomes a node shared by both: the street (or track) is cut there, and the
-- new track piece too.
-- No game API here, so test/crossings_test.lua runs it outside the game.

local ends = require("track_geometry_tool::/track_geometry/tg_ends.script.tl")

-- An existing street edge, or track edge (track), as tg_world reads it: its curve and nodes (a
-- Piece), and what bars cutting it. Or a road of two such pieces taken as one across the joint
-- between them (merge): its curve then runs from one's far node to the other's, edge is one of
-- them, and cutting it replaces both and the joint.
local record Street
	edge : integer
	node0 : integer
	node1 : integer
	p0 : ends.Point
	t0 : ends.Point
	p1 : ends.Point
	t1 : ends.Point
	track : boolean -- a track edge (a diamond crossing), not a street
	fixed : string -- why it cannot be cut (stops, signals or other objects on it, a construction's), nil: it can
	crossing0 : integer -- the type of the level crossing at node0 (railroadCrossingTypeRep), nil: none
	crossing1 : integer -- ...and at node1
	kind0 : string -- what node0 is: "junction" (three roads or tracks or more), "crossing" (a level crossing), nil: a joint or an end
	kind1 : string -- ...and node1
	beyond0 : Street -- the road's next piece past node0 when that node is a plain joint (tg_world), nil: none
	beyond1 : Street -- ...past node1
	-- (taken as one across a joint)
	pieces : {integer} -- the pieces it replaces
	joint : integer -- the node between them, which goes
	edge0 : integer -- the piece at node0
	edge1 : integer -- the piece at node1
	box : {number} -- its curve's box in plan, and its samples (crossingsOf; kept, as the street is kept while a drag lasts)
	su : {number}
	spts : {ends.Point}
end

-- Where a track piece crosses a street: u along the track piece, v along the street (curve
-- parameters, 0 to 1), the point in plan and the track's height there; why it cannot be a level
-- crossing (nil: it can).
local record Crossing
	street : Street
	u : number
	v : number
	x : number
	y : number
	z : number
	why : string
end

local record Crossings
	Street : Street
	Crossing : Crossing
	find : function(track : ends.Piece, streets : {Street}) : {Crossing}
	asPiece : function(s : Street) : ends.Piece
	parts : function(pc : ends.Piece, us : {number}) : {ends.Piece}
	merge : function(a : Street, b : Street, joint : integer) : Street
end

local M : Crossings = {}

-- A street at most this far above or below the track where they cross is at grade there (m);
-- one further off passes over or under it, which is the bridges' and cuttings' business.
local AT_GRADE = 1.0
-- A crossing this close to a node is not cut there (m, in plan): the game refuses the piece it
-- would leave ("Construction Not Possible", in game: NOTES.md). Next to a joint or an end of a
-- road (2.0 to 6.4 m refused, 6.5 m built) or of the new track (3.2 to 3.8 m refused); next to a
-- junction of three roads or more (5.8 to 13.1 m refused, 16.1 m built); next to a level crossing
-- (10.1 m built). Near a plain joint the road is cut as one across it (merge) instead.
local MIN_PART = 7.0
local MIN_PART_AT : {string : number} = { junction = 16.0, crossing = 10.0 }
-- A road crossed at a smaller angle than this is not cut (degrees): refused at 10 to 24, built at
-- 65 and over, in game.
local MIN_ANGLE = 30.0
-- A road taken as one across a joint may stray this far from the joint at most (m): further, it
-- would no longer follow the road.
local MERGE_STRAY = 0.25
-- Chords along a curve this long at most (m), to find where two curves cross before refining it.
local CHORD = 2.0

local function planDist(p : ends.Point, q : ends.Point) : number
	return math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2)
end

-- Why a crossing of street s at p, at `angle` degrees, cannot be cut (nil: it can).
local function whyNot(track : ends.Piece, s : Street, p : ends.Point, angle : number) : string
	for _, e in ipairs({ { s.p0, s.kind0 }, { s.p1, s.kind1 } }) do
		local kind = e[2] as string
		if planDist(p, e[1] as ends.Point) < (MIN_PART_AT[kind] or MIN_PART) then
			if kind == "junction" then return "it is too near a junction" end
			if kind == "crossing" then return "it is too near a level crossing" end
			local what = s.track and "track" or "road"
			return "it is too near a " .. what .. " node (a joint the " .. what .. " bends at, or its end)"
		end
	end
	if s.fixed ~= nil then return s.fixed end
	if angle < MIN_ANGLE then return string.format("it crosses the %s at %.0f degrees, too shallow", s.track and "track" or "road", angle) end
	if planDist(p, track.p0) < MIN_PART or planDist(p, track.p1) < MIN_PART then return "it is too near a node of the new track" end
	return nil
end

function M.asPiece(s : Street) : ends.Piece
	return { edge = s.edge, node0 = s.node0, node1 = s.node1, p0 = s.p0, t0 = s.t0, p1 = s.p1, t1 = s.t1 }
end

-- The box round Hermite pc in plan ({minX, minY, maxX, maxY}): round its Bézier control points
-- (p0, p0 + t0/3, p1 - t1/3, p1), whose hull holds the whole curve.
local function hullBox(pc : ends.Piece) : {number}
	local p0, t0, p1, t1 = pc.p0, pc.t0, pc.p1, pc.t1
	local xs = { p0.x, p0.x + t0.x / 3, p1.x - t1.x / 3, p1.x }
	local ys = { p0.y, p0.y + t0.y / 3, p1.y - t1.y / 3, p1.y }
	return { math.min(xs[1], xs[2], xs[3], xs[4]), math.min(ys[1], ys[2], ys[3], ys[4]),
		math.max(xs[1], xs[2], xs[3], xs[4]), math.max(ys[1], ys[2], ys[3], ys[4]) }
end

local BOX_SLACK = 0.5 -- (m: two boxes this close count as meeting)

local function boxesMeet(a : {number}, b : {number}) : boolean
	return a[1] <= b[3] + BOX_SLACK and b[1] <= a[3] + BOX_SLACK and a[2] <= b[4] + BOX_SLACK and b[2] <= a[4] + BOX_SLACK
end

-- Points along pc at even u, at most CHORD apart (by its tangents and chord: a bound on its length).
local function samples(pc : ends.Piece) : {number}, {ends.Point}
	local chord = math.sqrt((pc.p1.x - pc.p0.x) ^ 2 + (pc.p1.y - pc.p0.y) ^ 2)
	local t = math.max(math.sqrt(pc.t0.x ^ 2 + pc.t0.y ^ 2), math.sqrt(pc.t1.x ^ 2 + pc.t1.y ^ 2))
	local n = math.max(8, math.ceil(math.max(chord, t) / CHORD))
	local us, ps : {number}, {ends.Point} = {}, {}
	for i = 0, n do
		us[#us + 1] = i / n
		ps[#ps + 1] = (ends.pieceAt(pc, i / n))
	end
	return us, ps
end

-- Where chords a0-a1 and b0-b1 cross: the share along each, or nil.
local function chordsCross(a0 : ends.Point, a1 : ends.Point, b0 : ends.Point, b1 : ends.Point) : number, number
	local ax, ay, bx, by = a1.x - a0.x, a1.y - a0.y, b1.x - b0.x, b1.y - b0.y
	local den = ax * by - ay * bx
	if math.abs(den) < 1e-12 then return nil end
	local cx, cy = b0.x - a0.x, b0.y - a0.y
	local s, t = (cx * by - cy * bx) / den, (cx * ay - cy * ax) / den
	if s < 0 or s > 1 or t < 0 or t > 1 then return nil end
	return s, t
end

-- Newton's method on P(u) = Q(v) in plan, from (u, v); nil when it leaves [0, 1] or does not settle.
local function refine(p : ends.Piece, q : ends.Piece, u : number, v : number) : number, number
	for _ = 1, 20 do
		local a, da = ends.pieceAt(p, u)
		local b, db = ends.pieceAt(q, v)
		local fx, fy = a.x - b.x, a.y - b.y
		if fx * fx + fy * fy < 1e-12 then return u, v end
		-- [da.x -db.x; da.y -db.y] (du, dv) = -(fx, fy)
		local det = -da.x * db.y + db.x * da.y
		if math.abs(det) < 1e-12 then return nil end
		local du = (-fx * -db.y + db.x * -fy) / det
		local dv = (da.x * -fy - da.y * -fx) / det
		u, v = u + du, v + dv
		if u < -1e-9 or u > 1 + 1e-9 or v < -1e-9 or v > 1 + 1e-9 then return nil end
	end
	local a, b = ends.pieceAt(p, u), ends.pieceAt(q, v)
	if (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 < 1e-6 then return u, v end
	return nil
end

-- Where track piece `track` (sampled: tu, tp) crosses street s at grade (within AT_GRADE), each with
-- why it cannot be cut (whyNot), if it cannot.
local function crossingsOf(track : ends.Piece, tu : {number}, tp : {ends.Point}, s : Street) : {Crossing}
	local out : {Crossing} = {}
	-- (none where their boxes are apart: most streets near a long track are nowhere near this piece)
	s.box = s.box or hullBox(M.asPiece(s))
	if not boxesMeet(hullBox(track), s.box) then return out end
	local sp = M.asPiece(s)
	if s.su == nil then s.su, s.spts = samples(sp) end
	local su, spts = s.su, s.spts
	local bx = s.box
	local found : {{number}} = {}
	for i = 1, #tp - 1 do
		-- (the street's chords lie in its box: a track chord clear of it crosses none of them)
		local a0, a1 = tp[i], tp[i + 1]
		if boxesMeet({ math.min(a0.x, a1.x), math.min(a0.y, a1.y), math.max(a0.x, a1.x), math.max(a0.y, a1.y) }, bx) then
		for j = 1, #spts - 1 do
			local a, b = chordsCross(tp[i], tp[i + 1], spts[j], spts[j + 1])
			if a ~= nil then
				local u, v = refine(track, sp, tu[i] + a * (tu[i + 1] - tu[i]), su[j] + b * (su[j + 1] - su[j]))
				local dup = false
				for _, f in ipairs(found) do
					if u ~= nil and math.abs(f[1] - u) < 1e-6 then dup = true end
				end
				if u ~= nil and not dup then
					found[#found + 1] = { u, v }
					local p, dt = ends.pieceAt(track, u)
					local q, ds = ends.pieceAt(sp, v)
					if math.abs(p.z - q.z) <= AT_GRADE then
						local cos = math.abs(dt.x * ds.x + dt.y * ds.y) / math.max(1e-12, math.sqrt((dt.x ^ 2 + dt.y ^ 2) * (ds.x ^ 2 + ds.y ^ 2)))
						local angle = math.deg(math.acos(math.min(1, cos)))
						out[#out + 1] = { street = s, u = u, v = v, x = p.x, y = p.y, z = p.z, why = whyNot(track, s, p, angle) }
					end
				end
			end
		end
		end
	end
	return out
end

-- Street s drawn the other way.
local function reversed(s : Street) : Street
	local function neg(t : ends.Point) : ends.Point return { x = -t.x, y = -t.y, z = -t.z } end
	return { edge = s.edge, node0 = s.node1, node1 = s.node0, p0 = s.p1, t0 = neg(s.t1), p1 = s.p0, t1 = neg(s.t0),
		track = s.track, fixed = s.fixed, crossing0 = s.crossing1, crossing1 = s.crossing0, kind0 = s.kind1, kind1 = s.kind0 }
end

-- Pieces a and b of one road, meeting at node `joint`, as one street from a's far node to b's (one
-- Hermite: the far ends' directions, tangents as long as both pieces); nil when that curve strays
-- from the joint by more than MERGE_STRAY (the road bends there) or they do not meet at it.
function M.merge(a : Street, b : Street, joint : integer) : Street
	if a.node1 ~= joint then a = reversed(a) end
	if b.node0 ~= joint then b = reversed(b) end
	if a.node1 ~= joint or b.node0 ~= joint or a.node0 == b.node1 then return nil end
	local la, lb = planDist(a.p0, a.p1), planDist(b.p0, b.p1)
	if la + lb < 1e-6 then return nil end
	local function along(t : ends.Point, len : number) : ends.Point
		local n = math.sqrt(t.x ^ 2 + t.y ^ 2)
		if n < 1e-9 then return nil end
		return { x = t.x / n * len, y = t.y / n * len, z = t.z / n * len }
	end
	local t0, t1 = along(a.t0, la + lb), along(b.t1, la + lb)
	if t0 == nil or t1 == nil then return nil end
	local m : Street = { edge = a.edge, node0 = a.node0, node1 = b.node1, p0 = a.p0, t0 = t0, p1 = b.p1, t1 = t1,
		track = a.track, fixed = a.fixed or b.fixed, crossing0 = a.crossing0, crossing1 = b.crossing1, kind0 = a.kind0, kind1 = b.kind1,
		pieces = { a.edge, b.edge }, joint = joint, edge0 = a.edge, edge1 = b.edge }
	local at = ends.pieceAt(M.asPiece(m), la / (la + lb))
	if planDist(at, a.p1) > MERGE_STRAY or math.abs(at.z - a.p1.z) > MERGE_STRAY then return nil end
	return m
end

-- Every point where track piece `track` crosses one of `streets` at grade (within AT_GRADE), in
-- order along the track, each with why it cannot be cut (whyNot), if it cannot. One within MIN_PART
-- of a plain joint (beyond0, beyond1) is on the road taken as one across it (merge), found once
-- from either piece; its pieces are taken in the order of their edge ids, so that every track
-- piece finds the same road.
function M.find(track : ends.Piece, streets : {Street}) : {Crossing}
	local out : {Crossing} = {}
	local tu, tp = samples(track)
	local joints : {integer : boolean} = {} -- joints already crossed
	for _, s in ipairs(streets) do
		for _, c in ipairs(crossingsOf(track, tu, tp, s)) do
			local p : ends.Point = { x = c.x, y = c.y, z = c.z }
			local joint, beyond : integer, Street
			if planDist(p, s.p0) < MIN_PART and s.beyond0 ~= nil then joint, beyond = s.node0, s.beyond0
			elseif planDist(p, s.p1) < MIN_PART and s.beyond1 ~= nil then joint, beyond = s.node1, s.beyond1 end
			local m : Street = nil
			if joint ~= nil then
				if s.edge < beyond.edge then m = M.merge(s, beyond, joint) else m = M.merge(beyond, s, joint) end
			end
			if m == nil then
				out[#out + 1] = c
			elseif not joints[joint] then
				-- (only the crossing there: one further along is found on its own piece)
				joints[joint] = true
				local at = joint == s.node0 and s.p0 or s.p1
				for _, mc in ipairs(crossingsOf(track, tu, tp, m)) do
					if planDist({ x = mc.x, y = mc.y, z = mc.z }, at) < MIN_PART + MERGE_STRAY + 1 then out[#out + 1] = mc end
				end
			end
		end
	end
	table.sort(out, function(a : Crossing, b : Crossing) : boolean return a.u < b.u end)
	return out
end

-- Piece pc cut at each of us (increasing, inside (0, 1)): its parts in order, Hermites of their own
-- meeting with no kink (tg_ends.halves, again on what is left).
function M.parts(pc : ends.Piece, us : {number}) : {ends.Piece}
	local out : {ends.Piece} = {}
	local rest, done = pc, 0.0
	for _, u in ipairs(us) do
		local a, b = ends.halves(rest, (u - done) / (1 - done))
		out[#out + 1] = a
		rest, done = b, u
	end
	out[#out + 1] = rest
	return out
end

return M
