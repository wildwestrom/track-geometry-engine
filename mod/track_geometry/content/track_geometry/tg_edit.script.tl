-- The alignment being edited between two picked ends: its turns (PIs; the first and last sit on the
-- ends), each with the curve size (tangent budget) the player set by dragging a bracket. The edits:
--   move a turn   : free turns go anywhere; the turn next to an end only slides along that end's
--                   ray, so the new track always leaves and arrives along the ends' headings. A turn
--                   next to both ends cannot move until another is added (no starting layout has one).
--   add a turn    : on a leg, at the point nearest the mouse. On the straight layout (no turns) it
--                   adds three, so the middle one is free to move.
--   remove a turn : free turns only (removing one next to an end would kink the join).
--   resize a curve: drag the bracket where it starts or ends; sets that turn's curve size, up to
--                   the room the neighbouring curves leave (tg_geometry.cornerLayouts).
-- And the vertical profile (tg_profile) through elevation points between the ends, each kept as a
-- share of the path's length, so they follow the horizontal edits:
--   add a point   : at a chainage, on the profile as it is, so adding one changes nothing.
--   move a point  : along the path and up or down, at least MIN_SPAN from its neighbours (the
--                   ends included), and only as far as the steepest grade stays within the limit
--                   (a profile already steeper than the limit may move without getting steeper).
--   remove a point: any; the ends are not elevation points and stay.
--
-- The edit keeps its own design params, and its path sampled every STEP (made again only when the
-- turns or curves change), so callers work in metres of chainage and never pass either in. Its
-- fields are its own: callers read it through the functions below (rev and hrev excepted).
-- No game API here, so test/edit_test.lua runs it outside the game.

local geometry = require("westrom_track_geometry::/track_geometry/tg_geometry.script.tl")
local alignment = require("westrom_track_geometry::/track_geometry/tg_alignment.script.tl")
local ends = require("westrom_track_geometry::/track_geometry/tg_ends.script.tl")
local profiles = require("westrom_track_geometry::/track_geometry/tg_profile.script.tl")

-- A turn (Lean: PI): where it is, and the size of its curve, attached to it.
local record Turn
	pos : geometry.Vec
	budget : number -- the curve's tangent budget the player set (m); nil: automatic
end

-- An elevation point: where along the path, as a share of its length (0..1), and its height (m).
local record Elevation
	f : number
	z : number
end

-- The path, sampled every STEP, as of a horizontal revision.
local record Sampled
	hrev : integer
	path : {geometry.Segment}
	nodes : {alignment.Sample}
	len : number
	ss : {number}
end

local record Edit
	a : ends.End
	b : ends.End
	dp : geometry.DesignParams
	turns : {Turn}
	elevations : {Elevation} -- in order along the path, the ends not included
	rev : integer -- bumped on every change
	hrev : integer -- bumped on every change to the horizontal alignment (turns, curves)
	sampled : Sampled
end

local enum HitKind
	"pi" -- a turn
	"entry" -- the bracket where turn i's curve starts
	"exit" -- ...or ends
	"leg" -- the leg from turn i to i + 1 (or the track along it), where a press adds a turn
	"point" -- elevation point i
	"track" -- the track at chainage s, where a press adds an elevation point
end

-- What the mouse is on.
local record Hit
	kind : HitKind
	i : integer
	x : number -- turns and brackets: where they are
	y : number
	mobility : string -- turns only: "free", "ray" or "fixed"
	s : number -- elevation points and the track: the chainage (m)
end

-- An elevation point, read out: its chainage (m), height (m), and where it is on the ground.
local record Point
	s : number
	z : number
	x : number
	y : number
end

local record EditMod
	Edit : Edit
	Hit : Hit
	HitKind : HitKind
	Point : Point
	MIN_GAP : number
	MIN_SPAN : number
	STEP : number
	PARAMS : geometry.DesignParams
	new : function(a : ends.End, b : ends.End, dp ?: geometry.DesignParams) : Edit, string
	-- the horizontal alignment
	turnCount : function(e : Edit) : integer
	polyline : function(e : Edit) : {geometry.Vec}
	mobility : function(e : Edit, i : integer) : string
	turn : function(e : Edit, i : integer) : Hit
	budget : function(e : Edit, i : integer) : number
	corners : function(e : Edit) : {integer : geometry.CornerLayout}
	handles : function(e : Edit) : {Hit}
	movePi : function(e : Edit, i : integer, x : number, y : number) : boolean
	insertOnLeg : function(e : Edit, leg : integer, x : number, y : number) : integer, string
	removePi : function(e : Edit, i : integer) : boolean, string
	dragBracket : function(e : Edit, i : integer, isEntry : boolean, x : number, y : number) : boolean
	-- the path
	path : function(e : Edit) : {geometry.Segment}
	nodes : function(e : Edit) : {alignment.Sample}
	length : function(e : Edit) : number
	chainageAt : function(e : Edit, x : number, y : number) : number, number
	hit : function(e : Edit, vertical : boolean, x : number, y : number, r : number) : Hit
	-- the vertical profile
	profile : function(e : Edit) : profiles.Profile, string
	steepest : function(e : Edit) : number
	points : function(e : Edit) : {Point}
	insertElevation : function(e : Edit, s : number) : integer, string
	moveElevation : function(e : Edit, i : integer, s : number, z : number, limit : number) : boolean
	removeElevation : function(e : Edit, i : integer) : boolean
end

local M : EditMod = {}

-- Closest two neighbouring turns may get (m).
M.MIN_GAP = 10.0
-- Closest two elevation points may get along the path, the ends included (m).
M.MIN_SPAN = 20.0
-- The path is read this finely (m): for the ground under it, the readout, picking...
M.STEP = 10.0
M.PARAMS = geometry.DEFAULT_PARAMS

local function d2(ax : number, ay : number, bx : number, by : number) : number
	return (ax - bx) ^ 2 + (ay - by) ^ 2
end

local function bumpH(e : Edit)
	e.rev, e.hrev = e.rev + 1, e.hrev + 1
end

function M.new(a : ends.End, b : ends.End, dp ?: geometry.DesignParams) : Edit, string
	local pis, why = ends.initialPis(a, b)
	if pis == nil then return nil, why end
	local turns : {Turn} = {}
	for i, p in ipairs(pis) do turns[i] = { pos = p } end
	return { a = a, b = b, dp = dp or M.PARAMS, turns = turns, elevations = {}, rev = 0, hrev = 0 }, why
end

------------------------------------------------------------------ the horizontal alignment

-- The turns as the geometry takes them: the PI polyline, and the curve sizes by index.
local function pisOf(e : Edit) : {geometry.Vec}, {integer : number}
	local pts : {geometry.Vec} = {}
	local budgets : {integer : number} = {}
	for i, t in ipairs(e.turns) do pts[i], budgets[i] = t.pos, t.budget end
	return pts, budgets
end

function M.turnCount(e : Edit) : integer
	return #e.turns - 2
end

-- The PI polyline, the ends included (a copy).
function M.polyline(e : Edit) : {geometry.Vec}
	return (pisOf(e))
end

-- The curve size the player set at turn i (m), or nil when it is automatic.
function M.budget(e : Edit, i : integer) : number
	local t = e.turns[i]
	return t ~= nil and t.budget or nil
end

-- The curves as laid, by turn index.
function M.corners(e : Edit) : {integer : geometry.CornerLayout}
	local pts, budgets = pisOf(e)
	return geometry.cornerLayouts(pts, e.dp, budgets)
end

-- "end" (the picked ends), "fixed" (next to both ends), "ray" (next to one end) or "free".
function M.mobility(e : Edit, i : integer) : string
	local n = #e.turns
	if i <= 1 or i >= n then return "end" end
	if i == 2 and i == n - 1 then return "fixed" end
	if i == 2 or i == n - 1 then return "ray" end
	return "free"
end

-- Turn i, as something the mouse can grab.
function M.turn(e : Edit, i : integer) : Hit
	local p = e.turns[i].pos
	return { kind = "pi", i = i, x = p.x, y = p.y, mobility = M.mobility(e, i) }
end

-- The ray a "ray" turn slides on: from the end, along its direction out of the existing track.
local function rayOf(e : Edit, i : integer) : ends.End
	if i == 2 then return e.a end
	return e.b
end

-- Is (x, y) at least MIN_GAP from turn i's neighbours?
local function roomAt(e : Edit, i : integer, x : number, y : number) : boolean
	local g2 = M.MIN_GAP * M.MIN_GAP
	local p, q = e.turns[i - 1].pos, e.turns[i + 1].pos
	return d2(x, y, p.x, p.y) >= g2 and d2(x, y, q.x, q.y) >= g2
end

-- Move turn i towards (x, y), as far as its mobility allows. false when it cannot move there.
function M.movePi(e : Edit, i : integer, x : number, y : number) : boolean
	local mob = M.mobility(e, i)
	if mob == "end" or mob == "fixed" then return false end
	if mob == "ray" then
		local r = rayOf(e, i)
		local t = math.max(M.MIN_GAP, (x - r.x) * r.dx + (y - r.y) * r.dy)
		x, y = r.x + t * r.dx, r.y + t * r.dy
	end
	if not roomAt(e, i, x, y) then return false end
	local p = e.turns[i].pos
	if p.x == x and p.y == y then return true end
	e.turns[i].pos = geometry.vec(x, y, 0)
	bumpH(e)
	return true
end

-- Add a turn on leg `leg` (between turn leg and leg + 1) at the point nearest (x, y). The new turn
-- splits the leg without bending it, and the corners on either side keep their curve sizes (as far
-- as the shorter legs allow), except an automatic end curve, which keeps filling its room. Returns
-- the index of the turn to drag next, or nil and why not.
function M.insertOnLeg(e : Edit, leg : integer, x : number, y : number) : integer, string
	local n = #e.turns
	if leg < 1 or leg >= n then return nil, "no such leg" end
	local p, q = e.turns[leg].pos, e.turns[leg + 1].pos
	local lx, ly = q.x - p.x, q.y - p.y
	local len = math.sqrt(lx * lx + ly * ly)
	local fits = n == 2 and 4 * M.MIN_GAP or 2 * M.MIN_GAP
	if len < fits then return nil, "the leg is too short" end
	local ux, uy = lx / len, ly / len
	local lo, hi = M.MIN_GAP, len - M.MIN_GAP
	if n == 2 then lo, hi = 2 * M.MIN_GAP, len - 2 * M.MIN_GAP end
	local t = math.max(lo, math.min(hi, (x - p.x) * ux + (y - p.y) * uy))
	local function at(s : number) : Turn return { pos = geometry.vec(p.x + s * ux, p.y + s * uy, 0) } end
	if n == 2 then
		-- the straight layout: a turn next to each end (on the line, sliding along it; ends.LEAD out
		-- when the room allows) and a free one
		e.turns = { e.turns[1], at(math.min(ends.LEAD, t / 2)), at(t), at(len - math.min(ends.LEAD, (len - t) / 2)), e.turns[2] }
		bumpH(e)
		return 3, nil
	end
	-- (an automatic end curve that is still next to an end afterwards stays automatic, so it
	-- keeps taking all its room)
	local now = M.corners(e)
	for _, i in ipairs({ leg, leg + 1 }) do
		local after = i == leg and i or i + 1
		local staysEnd = e.turns[i].budget == nil and (i == 2 or i == n - 1) and (after == 2 or after == n)
		if now[i] ~= nil and not staysEnd then e.turns[i].budget = now[i].budget end
	end
	table.insert(e.turns, leg + 1, at(t))
	bumpH(e)
	return leg + 1, nil
end

function M.removePi(e : Edit, i : integer) : boolean, string
	local mob = M.mobility(e, i)
	if mob == "end" then return false, "the ends stay" end
	if mob ~= "free" then return false, "a turn next to an end cannot be removed" end
	table.remove(e.turns, i)
	bumpH(e)
	return true, nil
end

-- Drag the bracket where the curve at turn i starts (entry) or ends (exit) to (x, y): its distance
-- back from the turn along the leg becomes the curve's size, from the minimum radius up to the
-- room its neighbours leave.
function M.dragBracket(e : Edit, i : integer, isEntry : boolean, x : number, y : number) : boolean
	local l = M.corners(e)[i]
	if l == nil then return false end
	local g, b = l.geometry, e.turns[i].pos
	local d : number
	if isEntry then d = (b.x - x) * g.uIn.x + (b.y - y) * g.uIn.y
	else d = (x - b.x) * g.uOut.x + (y - b.y) * g.uOut.y end
	d = math.max(g.minBudget, math.min(g.maxBudget, d))
	if e.turns[i].budget == d then return true end
	e.turns[i].budget = d
	bumpH(e)
	return true
end

-- The turns (not the ends) and the brackets of every curve.
function M.handles(e : Edit) : {Hit}
	local hs : {Hit} = {}
	local ls = M.corners(e)
	for i = 2, #e.turns - 1 do
		hs[#hs + 1] = M.turn(e, i)
		local l = ls[i]
		if l ~= nil then
			hs[#hs + 1] = { kind = "entry", i = i, x = l.entryPoint.x, y = l.entryPoint.y }
			hs[#hs + 1] = { kind = "exit", i = i, x = l.exitPoint.x, y = l.exitPoint.y }
		end
	end
	return hs
end

-- The leg nearest (x, y), and how far it is.
local function nearestLeg(e : Edit, x : number, y : number) : integer, number
	local best, bestD = 1, math.huge
	for i = 1, #e.turns - 1 do
		local p, q = e.turns[i].pos, e.turns[i + 1].pos
		local lx, ly = q.x - p.x, q.y - p.y
		local l2 = lx * lx + ly * ly
		local t = l2 > 0 and math.max(0, math.min(1, ((x - p.x) * lx + (y - p.y) * ly) / l2)) or 0
		local d = math.sqrt(d2(x, y, p.x + t * lx, p.y + t * ly))
		if d < bestD then best, bestD = i, d end
	end
	return best, bestD
end

------------------------------------------------------------------ the path

local function sampled(e : Edit) : Sampled
	local c = e.sampled
	if c ~= nil and c.hrev == e.hrev then return c end
	local pts, budgets = pisOf(e)
	local path = geometry.buildPath(pts, e.dp, budgets)
	local nodes = alignment.sample(path, M.STEP)
	local ss : {number} = {}
	for i, nd in ipairs(nodes) do ss[i] = nd.s end
	c = { hrev = e.hrev, path = path, nodes = nodes, len = #nodes > 0 and nodes[#nodes].s or 0.0, ss = ss }
	e.sampled = c
	return c
end

-- The path as built from the turns.
function M.path(e : Edit) : {geometry.Segment}
	return sampled(e).path
end

-- The path's nodes every STEP (shared: copy before changing them).
function M.nodes(e : Edit) : {alignment.Sample}
	return sampled(e).nodes
end

-- The path's length (m).
function M.length(e : Edit) : number
	return sampled(e).len
end

-- The chainage of the track nearest (x, y) (m), and how far off it is.
function M.chainageAt(e : Edit, x : number, y : number) : number, number
	return alignment.project(sampled(e).nodes, x, y)
end

-- What is at (x, y) within r. Horizontal: a turn or a bracket, else a leg (or the track along it,
-- which leaves the legs at the curves). Vertical: an elevation point, else the track. nil: nothing.
function M.hit(e : Edit, vertical : boolean, x : number, y : number, r : number) : Hit
	local c = sampled(e)
	if vertical then
		local best : Hit = nil
		local bestD = r * r
		for i, el in ipairs(e.elevations) do
			local s = el.f * c.len
			local px, py = alignment.pointAt(c.nodes, s)
			local d = d2(x, y, px, py)
			if d <= bestD then best, bestD = { kind = "point", i = i, s = s, x = px, y = py }, d end
		end
		if best ~= nil then return best end
		local s, d = alignment.project(c.nodes, x, y)
		if d <= r then return { kind = "track", s = s } end
		return nil
	end
	local best : Hit = nil
	local bestD = r * r
	for _, h in ipairs(M.handles(e)) do
		local d = d2(x, y, h.x, h.y)
		if d <= bestD then best, bestD = h, d end
	end
	if best ~= nil then return best end
	local leg, d = nearestLeg(e, x, y)
	if d <= r then return { kind = "leg", i = leg } end
	local s, off = alignment.project(c.nodes, x, y)
	if off <= r then
		local px, py = alignment.pointAt(c.nodes, s)
		return { kind = "leg", i = (nearestLeg(e, px, py)), s = s }
	end
	return nil
end

------------------------------------------------------------------ the vertical profile

-- The profile through the elevation points els: from end a at its track's grade to end b (the path
-- arrives against b's direction, so its grade there is the opposite).
local function profileWith(e : Edit, els : {Elevation}, len : number) : profiles.Profile, string
	local pts : {profiles.Point} = { { s = 0, z = e.a.z } }
	for _, el in ipairs(els) do pts[#pts + 1] = { s = el.f * len, z = el.z } end
	pts[#pts + 1] = { s = len, z = e.b.z }
	return profiles.solve(pts, e.a.grade, -e.b.grade)
end

function M.profile(e : Edit) : profiles.Profile, string
	return profileWith(e, e.elevations, sampled(e).len)
end

local function steepestOf(p : profiles.Profile, ss : {number}) : number
	local worst = 0.0
	for _, s in ipairs(ss) do worst = math.max(worst, math.abs(profiles.gradeAt(p, s))) end
	return worst
end

-- The steepest grade at the path's nodes, as a magnitude; huge if there is no profile.
function M.steepest(e : Edit) : number
	local p = M.profile(e)
	if p == nil then return math.huge end
	return steepestOf(p, sampled(e).ss)
end

-- The elevation points in metres, in order along the path.
function M.points(e : Edit) : {Point}
	local c = sampled(e)
	local out : {Point} = {}
	for i, el in ipairs(e.elevations) do
		local s = el.f * c.len
		local x, y = alignment.pointAt(c.nodes, s)
		out[i] = { s = s, z = el.z, x = x, y = y }
	end
	return out
end

-- Where elevation point i may go along the path: MIN_SPAN from its neighbours (m).
local function spanRoom(e : Edit, i : integer, len : number) : number, number
	local els = e.elevations
	local lo = i > 1 and els[i - 1].f * len or 0.0
	local hi = i < #els and els[i + 1].f * len or len
	return lo + M.MIN_SPAN, hi - M.MIN_SPAN
end

-- Add an elevation point at chainage s on the profile as it is. Its index, or nil and why not.
function M.insertElevation(e : Edit, s : number) : integer, string
	local len = sampled(e).len
	local p, why = M.profile(e)
	if p == nil then return nil, why end
	local i = 1
	while i <= #e.elevations and e.elevations[i].f * len < s do i = i + 1 end
	local lo = i > 1 and e.elevations[i - 1].f * len or 0.0
	local hi = i <= #e.elevations and e.elevations[i].f * len or len
	if s - lo < M.MIN_SPAN or hi - s < M.MIN_SPAN then return nil, "too close to the next point" end
	table.insert(e.elevations, i, { f = s / len, z = profiles.heightAt(p, s) })
	e.rev = e.rev + 1
	return i, nil
end

-- Move elevation point i towards chainage s and height z: s stays MIN_SPAN from the neighbours,
-- and the move stops where the steepest grade at the path's nodes would pass the limit (or, on a
-- profile already past it, would get steeper). false when it cannot move at all.
function M.moveElevation(e : Edit, i : integer, s : number, z : number, limit : number) : boolean
	local el = e.elevations[i]
	if el == nil then return false end
	local c = sampled(e)
	local len, ss = c.len, c.ss
	local lo, hi = spanRoom(e, i, len)
	if lo > hi then return false end
	s = math.max(lo, math.min(hi, s))
	local s0, z0 = el.f * len, el.z
	local allowed = math.max(limit, M.steepest(e))
	local function at(t : number) : {Elevation}
		local els : {Elevation} = {}
		for k, v in ipairs(e.elevations) do els[k] = v end
		els[i] = { f = (s0 + t * (s - s0)) / len, z = z0 + t * (z - z0) }
		return els
	end
	local function fits(t : number) : boolean
		local p = profileWith(e, at(t), len)
		return p ~= nil and steepestOf(p, ss) <= allowed
	end
	-- the furthest fitting share of the way (bisection: the steepest grade grows with the move)
	local t = 1.0
	if not fits(1.0) then
		local good, bad = 0.0, 1.0
		for _ = 1, 30 do
			local mid = (good + bad) / 2
			if fits(mid) then good = mid else bad = mid end
		end
		t = good
	end
	local moved = at(t)[i]
	if moved.f == el.f and moved.z == el.z then return t > 0 end
	e.elevations[i] = moved
	e.rev = e.rev + 1
	return true
end

function M.removeElevation(e : Edit, i : integer) : boolean
	if e.elevations[i] == nil then return false end
	table.remove(e.elevations, i)
	e.rev = e.rev + 1
	return true
end

return M
