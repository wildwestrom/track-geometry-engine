-- The alignment being edited between two picked ends: its turns (PIs; the first and last sit on the
-- ends), each with the curve size (tangent budget) the player set by dragging a bracket. The edits:
--   move a turn   : free turns go anywhere; the turn next to an end with a heading (a track end)
--                   only slides along that end's ray, so the new track always leaves and arrives
--                   along the ends' headings. A turn next to two such ends (the corner layout)
--                   cannot move until another is added. A ground end holds no turn.
--   add a turn    : on a leg, at the point nearest the mouse. On the straight layout between two
--                   track ends it adds three, so the middle one is free to move (between two ground
--                   ends, one, free already). On the corner layout it splits the leg in place:
--                   both turns then slide on their rays and the track does not move (unless the
--                   turn lands inside the curve, which then shrinks to fit).
--   remove a turn : free turns only (removing one next to an end would kink the join).
--   move an end   : a ground end only, anywhere (at least MIN_GAP from its neighbouring turn);
--                   the turns stay, so the turn next to it still slides on the other end's ray,
--                   and the curve sizes stay with their turns. Other kinds of end stay. Moved
--                   onto track it becomes that end (a free track end, a node, a cut), heading as
--                   the second click would give it: the turn next to it goes onto its ray, and
--                   with no turn there (or one that is next to the other end's heading too) the
--                   turns are laid afresh, as a starting layout. Until it is dropped it can
--                   still move, back onto the ground too (the turns are then as they were).
--   resize a curve: drag the bracket where it starts or ends; sets that turn's curve size, up to
--                   the room the neighbouring curves leave (tg_geometry.cornerLayouts).
-- And the vertical profile (tg_profile) through elevation points between the ends, each kept as a
-- share of the path's length, so they follow the horizontal edits:
--   add a point   : at a chainage, on the profile as it is, so adding one changes nothing.
--   move a point  : along the path (past its neighbours too: the points reorder) and up or down,
--                   only as far as the steepest grade stays within the limit (a profile already
--                   steeper than the limit may move without getting steeper).
--   set a height  : as asked, past the limit too; the profile is then too steep.
--   remove a point: any; the ends are not elevation points and stay.
-- The ends are the profile's first and last points (M.points): a ground end's height is moved or
-- set like a point's, but it cannot slide; other kinds of end keep theirs.
-- A point within MIN_SPAN of an end or of another point is too close: it is left out of the
-- profile (so the spline never gets a tiny span) and the build is refused until it is clear. Of
-- two points too close to each other, the one placed (added or slid) last is the one too close.
-- A profile whose steepest grade at the path's nodes is past the limit is too steep: the build is
-- refused until it is eased.
--
-- The edit keeps its own design params, and its path sampled every STEP (made again only when the
-- turns or curves change), so callers work in metres of chainage and never pass either in. Its
-- fields are its own: callers read it through the functions below (rev and hrev excepted).
-- No game API here, so test/edit_test.lua runs it outside the game.

local geometry = require("track_geometry_tool::/track_geometry/tg_geometry.script.tl")
local alignment = require("track_geometry_tool::/track_geometry/tg_alignment.script.tl")
local ends = require("track_geometry_tool::/track_geometry/tg_ends.script.tl")
local profiles = require("track_geometry_tool::/track_geometry/tg_profile.script.tl")

-- A turn (Lean: PI): where it is, and the size of its curve, attached to it.
local record Turn
	pos : geometry.Vec
	budget : number -- the curve's tangent budget the player set (m); nil: automatic
end

-- An elevation point: where along the path, as a share of its length (0..1), its height (m), and
-- when it was last placed (added or slid; of two too close, the later one gives way).
local record Elevation
	f : number
	z : number
	seq : integer
end

-- What an elevation point too close is too close to.
local enum Near
	"end"
	"neighbour"
end

-- Why an elevation point is too close: the nearest end or neighbour in the way, gap m off.
local record Closeness
	near : Near
	gap : number
end

-- The points too close by index, as of a revision.
local record CloseCache
	rev : integer
	close : {integer : Closeness}
end

-- The path, sampled every STEP, as of a horizontal revision.
local record Sampled
	hrev : integer
	path : {geometry.Segment}
	nodes : {alignment.Sample}
	len : number
	ss : {number}
end

-- A ground end moved onto track and not dropped yet: which end, and the turns as they were on the
-- ground, so the same drag can take it elsewhere.
local record Held
	first : boolean
	turns : {Turn}
end

local record Edit
	a : ends.End
	b : ends.End
	dp : geometry.DesignParams
	turns : {Turn}
	elevations : {Elevation} -- in order along the path, the ends not included
	placed : integer -- the last elevation point placement (Elevation.seq)
	rev : integer -- bumped on every change
	hrev : integer -- bumped on every change to the horizontal alignment (turns, curves)
	sampled : Sampled
	closeCache : CloseCache
	held : Held
end

local enum HitKind
	"end" -- a ground end: turn i (1 or the last), dragged (horizontal); point i (M.points), its height set (vertical)
	"pi" -- a turn
	"entry" -- the bracket where turn i's curve starts
	"exit" -- ...or ends
	"leg" -- the leg from turn i to i + 1 (or the track along it), where a press adds a turn
	"point" -- elevation point i (M.points: the start is 1)
	"track" -- the track at chainage s, where a press adds an elevation point
end

-- What the mouse is on.
local record Hit
	kind : HitKind
	i : integer
	x : number -- turns, ends and brackets: where they are
	y : number
	ux : number -- brackets only: the direction (unit) along its leg towards its own curve
	uy : number
	mobility : string -- turns only: "free", "ray" or "fixed"
	s : number -- elevation points, ends (vertical) and the track: the chainage (m)
end

-- The mouse's view ray: from the eye (the camera) through the ground point under the mouse.
local record Ray
	ex : number
	ey : number
	ez : number
	gx : number
	gy : number
	gz : number
end

-- A point of the profile (an end or an elevation point), read out: its chainage (m), height (m),
-- and where it is on the ground; whether it slides along the path (an elevation point) and whether
-- its height can be set (not a track end's). And whether it is too close (left out of the
-- profile), to what ("neighbour" or "end") and how far.
local record Point
	s : number
	z : number
	x : number
	y : number
	slides : boolean
	liftable : boolean
	tooClose : boolean
	near : Near
	gap : number
end

local record EditMod
	Edit : Edit
	Hit : Hit
	Ray : Ray
	BRACKET_BAR : number
	BRACKET_TIP : number
	MIN_SPAN : number
	STEP : number
	new : function(a : ends.End, b : ends.End, dp ?: geometry.DesignParams) : Edit, string
	-- the horizontal alignment
	turnCount : function(e : Edit) : integer
	polyline : function(e : Edit) : {geometry.Vec}
	turn : function(e : Edit, i : integer) : Hit
	budget : function(e : Edit, i : integer) : number
	corners : function(e : Edit) : {integer : geometry.CornerLayout}
	handles : function(e : Edit) : {Hit}
	movePi : function(e : Edit, i : integer, x : number, y : number) : boolean
	insertOnLeg : function(e : Edit, leg : integer, x : number, y : number) : integer, string
	removePi : function(e : Edit, i : integer) : boolean, string
	dragBracket : function(e : Edit, i : integer, isEntry : boolean, x : number, y : number) : boolean
	ends : function(e : Edit) : ends.End, ends.End
	moveEnd : function(e : Edit, i : integer, to : ends.End) : boolean
	dropEnd : function(e : Edit)
	-- the path
	path : function(e : Edit) : {geometry.Segment}
	nodes : function(e : Edit) : {alignment.Sample}
	chainageAt : function(e : Edit, x : number, y : number) : number, number
	hit : function(e : Edit, vertical : boolean, x : number, y : number, r : number, ray ?: Ray) : Hit
	chainageOnRay : function(e : Edit, ray : Ray) : number, number
	-- the vertical profile
	profile : function(e : Edit) : profiles.Profile, string
	steepest : function(e : Edit) : number
	gradeProblem : function(e : Edit, limit : number) : string, number
	points : function(e : Edit) : {Point}
	spacingProblem : function(e : Edit) : string
	insertElevation : function(e : Edit, s : number) : integer, string
	movePoint : function(e : Edit, k : integer, s : number, z : number, limit : number) : boolean, integer
	setHeight : function(e : Edit, k : integer, z : number) : boolean
	removeElevation : function(e : Edit, k : integer) : boolean
end

local M : EditMod = {}
-- A bracket's shape, in grab radii (the radius of the turn and end circles): its bar across the
-- leg reaches BRACKET_BAR either side, past a circle under it, and each end bends BRACKET_TIP
-- along the leg towards its curve (a slanted corner, then the tip).
M.BRACKET_BAR = 1.5
M.BRACKET_TIP = 0.8

-- Closest two neighbouring turns may get (m).
local MIN_GAP = 10.0
-- Closest two elevation points may be along the path, the ends included, and both be in the
-- profile (m). A point closer than this is too close.
M.MIN_SPAN = 20.0
-- The path is read this finely (m): for the ground under it, the readout, picking...
M.STEP = 10.0

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
	return { a = a, b = b, dp = dp or geometry.DEFAULT_PARAMS, turns = turns, elevations = {}, placed = 0, rev = 0, hrev = 0 }, why
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

-- "end" (the picked ends), "fixed" (next to two ends with headings), "ray" (next to one) or
-- "free".
local function mobility(e : Edit, i : integer) : string
	local n = #e.turns
	if i <= 1 or i >= n then return "end" end
	local byA, byB = i == 2 and ends.hasHeading(e.a), i == n - 1 and ends.hasHeading(e.b)
	if byA and byB then return "fixed" end
	if byA or byB then return "ray" end
	return "free"
end

-- Turn i, as something the mouse can grab.
function M.turn(e : Edit, i : integer) : Hit
	local p = e.turns[i].pos
	return { kind = "pi", i = i, x = p.x, y = p.y, mobility = mobility(e, i) }
end

-- The ray a "ray" turn slides on: from the end with a heading next to it, along its direction out
-- of the existing track.
local function rayOf(e : Edit, i : integer) : ends.End
	if i == 2 and ends.hasHeading(e.a) then return e.a end
	return e.b
end

-- Is (x, y) at least MIN_GAP from turn i's neighbours?
local function roomAt(e : Edit, i : integer, x : number, y : number) : boolean
	local g2 = MIN_GAP * MIN_GAP
	local p, q = e.turns[i - 1].pos, e.turns[i + 1].pos
	return d2(x, y, p.x, p.y) >= g2 and d2(x, y, q.x, q.y) >= g2
end

-- Move turn i towards (x, y), as far as its mobility allows. false when it cannot move there.
function M.movePi(e : Edit, i : integer, x : number, y : number) : boolean
	local mob = mobility(e, i)
	if mob == "end" or mob == "fixed" then return false end
	if mob == "ray" then
		local r = rayOf(e, i)
		local t = math.max(MIN_GAP, (x - r.x) * r.dx + (y - r.y) * r.dy)
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
	local straightBetweenTrackEnds = n == 2 and ends.hasHeading(e.a) and ends.hasHeading(e.b)
	local fits = straightBetweenTrackEnds and 4 * MIN_GAP or 2 * MIN_GAP
	if len < fits then return nil, "the leg is too short" end
	local ux, uy = lx / len, ly / len
	local lo, hi = MIN_GAP, len - MIN_GAP
	if straightBetweenTrackEnds then lo, hi = 2 * MIN_GAP, len - 2 * MIN_GAP end
	local t = math.max(lo, math.min(hi, (x - p.x) * ux + (y - p.y) * uy))
	local function at(s : number) : Turn return { pos = geometry.vec(p.x + s * ux, p.y + s * uy, 0) } end
	if straightBetweenTrackEnds then
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
	local mob = mobility(e, i)
	if mob == "end" then return false, "the ends stay" end
	if mob ~= "free" then return false, "a turn next to a track end cannot be removed" end
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

-- The start and the end, as they are now (a ground end moves).
function M.ends(e : Edit) : ends.End, ends.End
	return e.a, e.b
end

-- Can end i (1 or the last) be dragged? A ground end can, and one moved onto track until it is
-- dropped.
local function draggableEnd(e : Edit, i : integer) : boolean
	local en = i == 1 and e.a or i == #e.turns and e.b or nil
	if en == nil then return false end
	return en.kind == "ground" or (e.held ~= nil and e.held.first == (i == 1))
end

-- The turns, each copied (so moving one leaves the original list as it was).
local function copies(turns : {Turn}) : {Turn}
	local out : {Turn} = {}
	for k, t in ipairs(turns) do out[k] = { pos = t.pos, budget = t.budget } end
	return out
end

-- Move end i (1 or the last), a ground end, to the end `to`: the ground, or track there (a node or
-- cut is aimed at the other end), which it then is. From the turns as they were on the ground:
-- onto the ground they stay; onto track the turn next to the end goes onto its ray (where it is
-- nearest, at least MIN_LEG out), and with no turn there, or one next to the other end's heading
-- too, the turns are laid afresh (tg_ends.initialPis). The last turn index changes with the turn
-- count. false when it cannot go there: not such an end, within MIN_GAP of its neighbouring turn
-- (the turn on the ray of its neighbour), or closer to the other end than ends too close to pick.
function M.moveEnd(e : Edit, i : integer, to : ends.End) : boolean
	if not draggableEnd(e, i) then return false end
	local first = i == 1
	local cur, other = e.a, e.b
	if not first then cur, other = e.b, e.a end
	if d2(to.x, to.y, other.x, other.y) < (2 * ends.MIN_LEG) ^ 2 then return false end
	to = ends.aim(to, other.x, other.y)
	local onTrack = to.kind ~= "ground"
	if onTrack and not ends.hasHeading(to) then return false end
	if onTrack and ends.key(cur) == ends.key(to) then return true end
	if not onTrack and cur.x == to.x and cur.y == to.y and cur.z == to.z then return true end
	local held = e.held
	local before = held ~= nil and held.turns or e.turns
	local turns = copies(before)
	local n = #turns
	local k, j = n, n - 1 -- (the end's turn index, and its neighbour's)
	if first then k, j = 1, 2 end
	local q = turns[j].pos
	if not onTrack then
		if d2(to.x, to.y, q.x, q.y) < MIN_GAP * MIN_GAP then return false end
		turns[k].pos = geometry.vec(to.x, to.y, 0)
	elseif n == 2 or (n == 3 and ends.hasHeading(other)) then
		local pis = ends.initialPis(first and to or other, first and other or to)
		if pis == nil then return false end
		turns = {}
		for m, p in ipairs(pis) do turns[m] = { pos = p } end
	else
		local t = math.max(ends.MIN_LEG, (q.x - to.x) * to.dx + (q.y - to.y) * to.dy)
		local x, y = to.x + t * to.dx, to.y + t * to.dy
		local r = turns[first and 3 or n - 2].pos
		if d2(x, y, r.x, r.y) < MIN_GAP * MIN_GAP then return false end
		turns[k].pos, turns[j].pos = geometry.vec(to.x, to.y, 0), geometry.vec(x, y, 0)
	end
	if not onTrack then e.held = nil
	elseif held == nil then e.held = { first = first, turns = before } end
	if first then e.a = to else e.b = to end
	e.turns = turns
	bumpH(e)
	return true
end

-- The dragged end is let go: where it is, it stays (on track, it is fixed like any other).
function M.dropEnd(e : Edit)
	e.held = nil
end

-- The bracket of turn i's curve at (x, y) on the leg to turn j: it opens towards turn i (on a
-- leg of no length, no way: never NaN).
local function bracket(e : Edit, kind : HitKind, i : integer, j : integer, x : number, y : number) : Hit
	local p, q = e.turns[i].pos, e.turns[j].pos
	local len = math.sqrt(d2(p.x, p.y, q.x, q.y))
	local k = len > 0 and 1 / len or 0
	return { kind = kind, i = i, x = x, y = y, ux = (p.x - q.x) * k, uy = (p.y - q.y) * k }
end

-- The ends that can be dragged, the turns and the brackets of every curve.
function M.handles(e : Edit) : {Hit}
	local hs : {Hit} = {}
	local ls = M.corners(e)
	for _, i in ipairs({ 1, #e.turns }) do
		if draggableEnd(e, i) then
			local p = e.turns[i].pos
			hs[#hs + 1] = { kind = "end", i = i, x = p.x, y = p.y }
		end
	end
	for i = 2, #e.turns - 1 do
		hs[#hs + 1] = M.turn(e, i)
		local l = ls[i]
		if l ~= nil then
			hs[#hs + 1] = bracket(e, "entry", i, i - 1, l.entryPoint.x, l.entryPoint.y)
			hs[#hs + 1] = bracket(e, "exit", i, i + 1, l.exitPoint.x, l.exitPoint.y)
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

-- The chainage of the track nearest (x, y) (m), and how far off it is.
function M.chainageAt(e : Edit, x : number, y : number) : number, number
	return alignment.project(sampled(e).nodes, x, y)
end

-- How far the point (px, py, pz) is from the ray (m): from the line beyond the eye.
local function offRay(ray : Ray, px : number, py : number, pz : number) : number
	local dx, dy, dz = ray.gx - ray.ex, ray.gy - ray.ey, ray.gz - ray.ez
	local wx, wy, wz = px - ray.ex, py - ray.ey, pz - ray.ez
	local dd = dx * dx + dy * dy + dz * dz
	local t = dd > 0 and math.max(0, (wx * dx + wy * dy + wz * dz) / dd) or 0
	return math.sqrt((wx - t * dx) ^ 2 + (wy - t * dy) ^ 2 + (wz - t * dz) ^ 2)
end

-- The chainage where the track, at its profile's height, passes nearest the ray (m), and how far
-- off it is; nil when there is no profile.
function M.chainageOnRay(e : Edit, ray : Ray) : number, number
	local c = sampled(e)
	local p = M.profile(e)
	if p == nil or #c.nodes == 0 then return nil, math.huge end
	local function off(s : number) : number
		local x, y = alignment.pointAt(c.nodes, s)
		return offRay(ray, x, y, profiles.heightAt(p, s))
	end
	local best, bestD = 0.0, math.huge
	for _, nd in ipairs(c.nodes) do
		local d = offRay(ray, nd.x, nd.y, profiles.heightAt(p, nd.s)) -- (a node is where it is: no lookup)
		if d < bestD then best, bestD = nd.s, d end
	end
	-- (then every 0.5 m, a STEP either side of the nearest node)
	local lo, hi = math.max(0, best - M.STEP), math.min(c.len, best + M.STEP)
	for s = lo, hi, 0.5 do
		local d = off(s)
		if d < bestD then best, bestD = s, d end
	end
	return best, bestD
end

-- How far (x, y) is from the bar of the bracket h, squared, and how far along the leg on its
-- curve's side (negative: on the other side). The bar reaches BRACKET_BAR * r either side.
local function offBar(h : Hit, x : number, y : number, r : number) : number, number
	local wx, wy = x - h.x, y - h.y
	local along = wx * h.ux + wy * h.uy
	local past = math.max(0, math.abs(wx * h.uy - wy * h.ux) - M.BRACKET_BAR * r)
	return along * along + past * past, along
end

-- What is at (x, y) within r. Horizontal: the nearest ground end, turn (within r of it) or bracket
-- (within r of its bar, so its tips reach past a circle under it), else a leg (or the track along
-- it, which leaves the legs at the curves). Vertical: the nearest point whose height can be set
-- (a ground end a hair ahead), else the track, all also up at their heights along ray (the mouse's
-- view ray), when it is given. nil: nothing.
function M.hit(e : Edit, vertical : boolean, x : number, y : number, r : number, ray ?: Ray) : Hit
	local c = sampled(e)
	if vertical then
		local best : Hit = nil
		local bestD = r
		local function consider(h : Hit, z : number, ahead : number)
			local d = math.sqrt(d2(x, y, h.x, h.y)) -- (its circle on the ground)
			if ray ~= nil then d = math.min(d, offRay(ray, h.x, h.y, z)) end -- (its top, up at its height)
			d = d - ahead
			if d <= bestD then best, bestD = h, d end
		end
		for k, p in ipairs(M.points(e)) do
			if p.liftable then
				consider({ kind = p.slides and "point" or "end", i = k, s = p.s, x = p.x, y = p.y }, p.z, p.slides and 0 or 1e-6)
			end
		end
		if best ~= nil then return best end
		local s, d = alignment.project(c.nodes, x, y)
		if ray ~= nil then
			local rs, rd = M.chainageOnRay(e, ray)
			if rs ~= nil and rd < d then s, d = rs, rd end
		end
		if d <= r then return { kind = "track", s = s } end
		return nil
	end
	local best : Hit = nil
	local bestD = math.huge
	for _, h in ipairs(M.handles(e)) do
		local d = d2(x, y, h.x, h.y)
		local off = d
		-- (where handles sit together, a hair ahead: an end or a turn, in its circle, then the
		-- bracket whose curve is on the mouse's side; so a curve that fills its leg up to an end,
		-- a turn or the next curve is resized at its bracket's tips, or from its own side)
		if h.kind == "entry" or h.kind == "exit" then
			local along : number
			off, along = offBar(h, x, y, r)
			if along > 0 then d = d - 1e-6 end
		else
			d = d - 2e-6
		end
		if off <= r * r and d <= bestD then best, bestD = h, d end
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

-- Which of the points els (in order along a path len long) are too close: of the ones placed
-- earlier, a point is in the profile when it is MIN_SPAN clear of both ends and of each one in it;
-- else it is too close.
local function closeness(els : {Elevation}, len : number) : {integer : Closeness}
	local order : {integer} = {}
	for k = 1, #els do order[k] = k end
	table.sort(order, function(p : integer, q : integer) : boolean
		local a, b = els[p], els[q]
		return a.seq < b.seq or (a.seq == b.seq and p < q)
	end)
	local close : {integer : Closeness} = {}
	local kept : {number} = {}
	for _, k in ipairs(order) do
		local s = els[k].f * len
		local near, gap : Near, number = "end", math.min(s, len - s)
		for _, o in ipairs(kept) do
			local d = math.abs(s - o)
			if d < gap then near, gap = "neighbour", d end
		end
		if gap < M.MIN_SPAN then close[k] = { near = near, gap = gap } else kept[#kept + 1] = s end
	end
	return close
end

-- The profile through the elevation points els that are not too close: from end a at its track's
-- grade to end b (the path arrives against b's direction, so its grade there is the opposite). A
-- ground end has no grade: the profile picks its own there (tg_profile.solve).
local function profileWith(a : ends.End, b : ends.End, els : {Elevation}, len : number) : profiles.Profile, string
	local close = closeness(els, len)
	local pts : {profiles.Point} = { { s = 0, z = a.z } }
	for k, el in ipairs(els) do
		if close[k] == nil then pts[#pts + 1] = { s = el.f * len, z = el.z } end
	end
	pts[#pts + 1] = { s = len, z = b.z }
	return profiles.solve(pts, a.grade, b.grade ~= nil and -b.grade or nil)
end

-- e's points too close (kept until the next change).
local function closeOf(e : Edit) : {integer : Closeness}
	local c = e.closeCache
	if c == nil or c.rev ~= e.rev then
		c = { rev = e.rev, close = closeness(e.elevations, sampled(e).len) }
		e.closeCache = c
	end
	return c.close
end

function M.profile(e : Edit) : profiles.Profile, string
	return profileWith(e.a, e.b, e.elevations, sampled(e).len)
end

-- The steepest grade of p at the chainages ss, as a magnitude, and where (the first such).
local function steepestOf(p : profiles.Profile, ss : {number}) : number, number
	local worst, at = 0.0, 0.0
	for _, s in ipairs(ss) do
		local g = math.abs(profiles.gradeAt(p, s))
		if g > worst then worst, at = g, s end
	end
	return worst, at
end

-- The steepest grade at the path's nodes, as a magnitude; huge if there is no profile.
function M.steepest(e : Edit) : number
	local p = M.profile(e)
	if p == nil then return math.huge end
	return (steepestOf(p, sampled(e).ss))
end

-- Why the build must wait while the profile is too steep (its steepest grade at the path's nodes
-- past limit: where and how much), and the chainage there; nil when it is not.
function M.gradeProblem(e : Edit, limit : number) : string, number
	local p = M.profile(e)
	if p == nil then return nil, nil end -- (no profile: the ghost says why)
	local g, at = steepestOf(p, sampled(e).ss)
	if g <= limit then return nil, nil end
	-- (rounded up: 85.4 is not "85, limit 85")
	return string.format("too steep: %d ‰ at %.0f m (limit %.0f ‰)", math.ceil(g * 1000), at, limit * 1000), at
end

-- The profile's points in order along the path: the start, the elevation points (in metres), the
-- end.
function M.points(e : Edit) : {Point}
	local c = sampled(e)
	local close = closeOf(e)
	local function atEnd(en : ends.End, s : number) : Point
		return { s = s, z = en.z, x = en.x, y = en.y, slides = false, liftable = en.kind == "ground", tooClose = false }
	end
	local out : {Point} = { atEnd(e.a, 0.0) }
	for i, el in ipairs(e.elevations) do
		local s = el.f * c.len
		local x, y = alignment.pointAt(c.nodes, s)
		local cl = close[i]
		out[i + 1] = { s = s, z = el.z, x = x, y = y, slides = true, liftable = true, tooClose = cl ~= nil, near = cl and cl.near, gap = cl and cl.gap }
	end
	out[#out + 1] = atEnd(e.b, c.len)
	return out
end

-- Why the build must wait while a point is too close (the first along the path), or nil.
function M.spacingProblem(e : Edit) : string
	local close = closeOf(e)
	for i = 1, #e.elevations do
		local cl = close[i]
		if cl ~= nil then
			-- (rounded down: 19.6 m is not "20 m, needs 20 m")
			return string.format("elevation point %d is too close to %s (%d m, needs %.0f m)", i,
				cl.near == "end" and "the end" or "its neighbour", math.floor(cl.gap), M.MIN_SPAN)
		end
	end
	return nil
end

-- The points in order along the path (of two at one spot, the one placed first comes first).
local function sortEls(els : {Elevation})
	table.sort(els, function(a : Elevation, b : Elevation) : boolean
		return a.f < b.f or (a.f == b.f and a.seq < b.seq)
	end)
end

-- e's ends and elevation points with point k (M.points) put at el: an end (a ground end) takes
-- only its height, an elevation point is put in order among the others.
local function with(e : Edit, k : integer, el : Elevation) : ends.End, ends.End, {Elevation}
	local a, b, els = e.a, e.b, e.elevations
	if k == 1 then return ends.groundEnd(a.x, a.y, el.z), b, els end
	if k == #els + 2 then return a, ends.groundEnd(b.x, b.y, el.z), els end
	local out : {Elevation} = {}
	for j, v in ipairs(els) do out[j] = v end
	out[k - 1] = el
	sortEls(out)
	return a, b, out
end

-- Put point k at el (as with), count the change, and say where it is now (the points reorder).
local function put(e : Edit, k : integer, el : Elevation) : integer
	e.a, e.b, e.elevations = with(e, k, el)
	e.rev = e.rev + 1
	for j, v in ipairs(e.elevations) do if v == el then return j + 1 end end
	return k -- (an end)
end

-- Chainage s, kept on the path (m).
local function onPath(s : number, len : number) : number
	return math.max(0, math.min(len, s))
end

-- Add an elevation point at chainage s on the profile as it is (too close, when it is within
-- MIN_SPAN of an end or another point). Its index (M.points), or nil and why not.
function M.insertElevation(e : Edit, s : number) : integer, string
	local len = sampled(e).len
	local p, why = M.profile(e)
	if p == nil then return nil, why end
	s = onPath(s, len)
	e.placed = e.placed + 1
	local el : Elevation = { f = s / len, z = profiles.heightAt(p, s), seq = e.placed }
	e.elevations[#e.elevations + 1] = el
	return put(e, #e.elevations + 1, el), nil
end

-- The furthest share of the way (0..1) that fits (bisection: the steepest grade grows with the
-- move; a share that does not fit is never taken).
local function furthest(fits : function(number) : boolean) : number
	if fits(1.0) then return 1.0 end
	local good, bad = 0.0, 1.0
	for _ = 1, 30 do
		local mid = (good + bad) / 2
		if fits(mid) then good = mid else bad = mid end
	end
	return good
end

-- Move point k (M.points) towards chainage s (an elevation point: past its neighbours too; an end
-- stays at its end) and height z. The move stops where the steepest grade at the path's nodes
-- would pass the limit (or, on a profile already past it, would get steeper); a point too close is
-- not in the profile, so only the others count until it is clear. A point slid is placed anew: of
-- two too close, it gives way. false when it cannot move at all (or its height cannot be set);
-- and the point's index after the move (the points reorder).
function M.movePoint(e : Edit, k : integer, s : number, z : number, limit : number) : boolean, integer
	local p = M.points(e)[k]
	if p == nil or not p.liftable then return false, k end
	local c = sampled(e)
	local el = e.elevations[k - 1] -- (nil: an end)
	s = p.slides and onPath(s, c.len) or p.s
	local seq = el == nil and 0 or s ~= p.s and e.placed + 1 or el.seq
	local allowed = math.max(limit, M.steepest(e))
	local function moved(t : number) : Elevation
		return { f = (p.s + t * (s - p.s)) / c.len, z = p.z + t * (z - p.z), seq = seq }
	end
	local t = furthest(function(t : number) : boolean
		local a, b, els = with(e, k, moved(t))
		local q = profileWith(a, b, els, c.len)
		return q ~= nil and steepestOf(q, c.ss) <= allowed
	end)
	if t == 0 then return false, k end
	local m = moved(t)
	if m.z == p.z and (el == nil or m.f == el.f) then return true, k end
	e.placed = math.max(e.placed, seq)
	return true, put(e, k, m)
end

-- Set point k's height to z, as asked: no limit (a profile past it refuses the build instead). An
-- elevation point stays where it is along the path, so it is not placed anew. false: no such
-- point, or its height cannot be set.
function M.setHeight(e : Edit, k : integer, z : number) : boolean
	local p = M.points(e)[k]
	if p == nil or not p.liftable then return false end
	local el = e.elevations[k - 1]
	if p.z ~= z then put(e, k, { f = el and el.f, z = z, seq = el and el.seq }) end
	return true
end

-- Remove point k (M.points), an elevation point (the ends stay).
function M.removeElevation(e : Edit, k : integer) : boolean
	if e.elevations[k - 1] == nil then return false end
	table.remove(e.elevations, k - 1)
	e.rev = e.rev + 1
	return true
end

return M
