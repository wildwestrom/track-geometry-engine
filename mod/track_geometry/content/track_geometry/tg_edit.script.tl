-- The alignment being edited between two picked ends: its PIs (the first and last sit on the ends)
-- and the tangent budgets the player set by dragging brackets. The edits:
--   move a turn   : free turns go anywhere; the turn next to an end only slides along that end's
--                   ray, so the new track always leaves and arrives along the ends' headings. A turn
--                   next to both ends cannot move until another is added (no starting layout has one).
--   add a turn    : on a leg, at the point nearest the mouse. On the straight layout (no turns) it
--                   adds three, so the middle one is free to move.
--   remove a turn : free turns only (removing one next to an end would kink the join).
--   resize a curve: drag the bracket where it starts or ends; sets that corner's budget, up to
--                   the room the neighbouring curves leave (tg_geometry.cornerLayouts).
-- And the vertical profile (tg_profile) through elevation points between the ends, each kept as a
-- share of the path's length, so they follow the horizontal edits:
--   add a point   : at a chainage, on the profile as it is, so adding one changes nothing.
--   move a point  : along the path and up or down, at least MIN_SPAN from its neighbours (the
--                   ends included), and only as far as the steepest grade stays within the limit
--                   (a profile already steeper than the limit may move without getting steeper).
--   remove a point: any; the ends are not elevation points and stay.
-- No game API here, so test/edit_test.lua runs it outside the game.

local geometry = require("westrom_track_geometry::/track_geometry/tg_geometry.script.tl")
local ends = require("westrom_track_geometry::/track_geometry/tg_ends.script.tl")
local profiles = require("westrom_track_geometry::/track_geometry/tg_profile.script.tl")

-- An elevation point: where along the path, as a share of its length (0..1), and its height (m).
local record Elevation
	f : number
	z : number
end

local record Edit
	a : ends.End
	b : ends.End
	pis : {geometry.Vec}
	budgets : {integer : number} -- tangent budget overrides (m), by PI index
	elevations : {Elevation} -- in order along the path, the ends not included
	rev : integer -- bumped on every change
	hrev : integer -- bumped on every change to the horizontal alignment (turns, curves)
end

-- Something the mouse can grab: a turn ("pi") or a curve's bracket ("entry"/"exit") at PI i.
local record Handle
	kind : string
	i : integer
	x : number
	y : number
	mobility : string -- turns only: "free", "ray" or "fixed"
end

local record EditMod
	Edit : Edit
	Handle : Handle
	Elevation : Elevation
	MIN_GAP : number
	MIN_SPAN : number
	new : function(a : ends.End, b : ends.End) : Edit, string
	mobility : function(e : Edit, i : integer) : string
	movePi : function(e : Edit, i : integer, x : number, y : number) : boolean
	insertOnLeg : function(e : Edit, leg : integer, x : number, y : number, dp : geometry.DesignParams) : integer, string
	removePi : function(e : Edit, i : integer) : boolean, string
	dragBracket : function(e : Edit, i : integer, isEntry : boolean, x : number, y : number, dp : geometry.DesignParams) : boolean
	handles : function(e : Edit, dp : geometry.DesignParams) : {Handle}
	pick : function(handles : {Handle}, x : number, y : number, r : number) : Handle
	nearestLeg : function(e : Edit, x : number, y : number) : integer, number
	path : function(e : Edit, dp : geometry.DesignParams) : {geometry.Segment}
	profile : function(e : Edit, len : number) : profiles.Profile, string
	steepest : function(e : Edit, len : number, ss : {number}) : number
	insertElevation : function(e : Edit, s : number, len : number) : integer, string
	moveElevation : function(e : Edit, i : integer, s : number, z : number, len : number, ss : {number}, limit : number) : boolean
	removeElevation : function(e : Edit, i : integer) : boolean
end

local M : EditMod = {}

-- Closest two neighbouring PIs may get (m).
M.MIN_GAP = 10.0
-- Closest two elevation points may get along the path, the ends included (m).
M.MIN_SPAN = 20.0

local function d2(ax : number, ay : number, bx : number, by : number) : number
	return (ax - bx) ^ 2 + (ay - by) ^ 2
end

function M.new(a : ends.End, b : ends.End) : Edit, string
	local pis, why = ends.initialPis(a, b)
	if pis == nil then return nil, why end
	return { a = a, b = b, pis = pis, budgets = {}, elevations = {}, rev = 0, hrev = 0 }, why
end

-- "end" (the picked ends), "fixed" (next to both ends), "ray" (next to one end) or "free".
function M.mobility(e : Edit, i : integer) : string
	local n = #e.pis
	if i <= 1 or i >= n then return "end" end
	if i == 2 and i == n - 1 then return "fixed" end
	if i == 2 or i == n - 1 then return "ray" end
	return "free"
end

-- The ray a "ray" turn slides on: from the end, along its direction out of the existing track.
local function rayOf(e : Edit, i : integer) : ends.End
	if i == 2 then return e.a end
	return e.b
end

-- Is (x, y) at least MIN_GAP from PI i's neighbours?
local function roomAt(e : Edit, i : integer, x : number, y : number) : boolean
	local g2 = M.MIN_GAP * M.MIN_GAP
	local p, q = e.pis[i - 1], e.pis[i + 1]
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
	local p = e.pis[i]
	if p.x == x and p.y == y then return true end
	e.pis[i] = geometry.vec(x, y, 0)
	e.rev, e.hrev = e.rev + 1, e.hrev + 1
	return true
end

local function layouts(e : Edit, dp : geometry.DesignParams) : {integer : geometry.CornerLayout}
	return geometry.cornerLayouts(e.pis, dp, e.budgets)
end

-- Shift the budget overrides from PI index `from` on by `by`.
local function shiftBudgets(e : Edit, from : integer, by : integer)
	local moved : {integer : number} = {}
	for k, v in pairs(e.budgets) do
		if k >= from then moved[k + by] = v else moved[k] = v end
	end
	e.budgets = moved
end

-- Add a turn on leg `leg` (between PI leg and leg + 1) at the point nearest (x, y). The new turn
-- splits the leg without bending it, and the corners on either side keep their budgets (as far as
-- the shorter legs allow), except an automatic end curve, which keeps filling its room. Returns the index of the turn to drag next, or nil and why not.
function M.insertOnLeg(e : Edit, leg : integer, x : number, y : number, dp : geometry.DesignParams) : integer, string
	local n = #e.pis
	if leg < 1 or leg >= n then return nil, "no such leg" end
	local p, q = e.pis[leg], e.pis[leg + 1]
	local lx, ly = q.x - p.x, q.y - p.y
	local len = math.sqrt(lx * lx + ly * ly)
	local fits = n == 2 and 4 * M.MIN_GAP or 2 * M.MIN_GAP
	if len < fits then return nil, "the leg is too short" end
	local ux, uy = lx / len, ly / len
	local lo, hi = M.MIN_GAP, len - M.MIN_GAP
	if n == 2 then lo, hi = 2 * M.MIN_GAP, len - 2 * M.MIN_GAP end
	local t = math.max(lo, math.min(hi, (x - p.x) * ux + (y - p.y) * uy))
	local function at(s : number) : geometry.Vec return geometry.vec(p.x + s * ux, p.y + s * uy, 0) end
	if n == 2 then
		-- the straight layout: a turn next to each end (on the line, sliding along it; ends.LEAD out
		-- when the room allows) and a free one
		e.pis = { p, at(math.min(ends.LEAD, t / 2)), at(t), at(len - math.min(ends.LEAD, (len - t) / 2)), q }
		e.rev, e.hrev = e.rev + 1, e.hrev + 1
		return 3, nil
	end
	-- (an automatic end curve that is still next to an end afterwards stays automatic, so it
	-- keeps taking all its room)
	local now = layouts(e, dp)
	for _, i in ipairs({ leg, leg + 1 }) do
		local after = i == leg and i or i + 1
		local staysEnd = e.budgets[i] == nil and (i == 2 or i == n - 1) and (after == 2 or after == n)
		if now[i] ~= nil and not staysEnd then e.budgets[i] = now[i].budget end
	end
	shiftBudgets(e, leg + 1, 1)
	table.insert(e.pis, leg + 1, at(t))
	e.rev, e.hrev = e.rev + 1, e.hrev + 1
	return leg + 1, nil
end

function M.removePi(e : Edit, i : integer) : boolean, string
	local mob = M.mobility(e, i)
	if mob == "end" then return false, "the ends stay" end
	if mob ~= "free" then return false, "a turn next to an end cannot be removed" end
	e.budgets[i] = nil
	table.remove(e.pis, i)
	shiftBudgets(e, i + 1, -1)
	e.rev, e.hrev = e.rev + 1, e.hrev + 1
	return true, nil
end

-- Drag the bracket where the curve at PI i starts (entry) or ends (exit) to (x, y): its distance
-- back from the PI along the leg becomes the corner's budget, from the minimum radius up to the
-- room its neighbours leave.
function M.dragBracket(e : Edit, i : integer, isEntry : boolean, x : number, y : number, dp : geometry.DesignParams) : boolean
	local l = layouts(e, dp)[i]
	if l == nil then return false end
	local g, b = l.geometry, e.pis[i]
	local d : number
	if isEntry then d = (b.x - x) * g.uIn.x + (b.y - y) * g.uIn.y
	else d = (x - b.x) * g.uOut.x + (y - b.y) * g.uOut.y end
	d = math.max(g.minBudget, math.min(g.maxBudget, d))
	if e.budgets[i] == d then return true end
	e.budgets[i] = d
	e.rev, e.hrev = e.rev + 1, e.hrev + 1
	return true
end

-- The turns (not the ends) and the brackets of every corner that curves.
function M.handles(e : Edit, dp : geometry.DesignParams) : {Handle}
	local hs : {Handle} = {}
	local ls = layouts(e, dp)
	for i = 2, #e.pis - 1 do
		local b = e.pis[i]
		hs[#hs + 1] = { kind = "pi", i = i, x = b.x, y = b.y, mobility = M.mobility(e, i) }
		local l = ls[i]
		if l ~= nil then
			hs[#hs + 1] = { kind = "entry", i = i, x = l.entryPoint.x, y = l.entryPoint.y }
			hs[#hs + 1] = { kind = "exit", i = i, x = l.exitPoint.x, y = l.exitPoint.y }
		end
	end
	return hs
end

-- The handle nearest (x, y) within r, or nil.
function M.pick(handles : {Handle}, x : number, y : number, r : number) : Handle
	local best : Handle = nil
	local bestD = r * r
	for _, h in ipairs(handles) do
		local d = d2(x, y, h.x, h.y)
		if d <= bestD then best, bestD = h, d end
	end
	return best
end

-- The leg nearest (x, y), and how far it is.
function M.nearestLeg(e : Edit, x : number, y : number) : integer, number
	local best, bestD = 1, math.huge
	for i = 1, #e.pis - 1 do
		local p, q = e.pis[i], e.pis[i + 1]
		local lx, ly = q.x - p.x, q.y - p.y
		local l2 = lx * lx + ly * ly
		local t = l2 > 0 and math.max(0, math.min(1, ((x - p.x) * lx + (y - p.y) * ly) / l2)) or 0
		local d = math.sqrt(d2(x, y, p.x + t * lx, p.y + t * ly))
		if d < bestD then best, bestD = i, d end
	end
	return best, bestD
end

function M.path(e : Edit, dp : geometry.DesignParams) : {geometry.Segment}
	return geometry.buildPath(e.pis, dp, e.budgets)
end

-- The profile along a path len long: from end a at its track's grade, through the elevation
-- points, to end b (the path arrives against b's direction, so its grade there is the opposite).
local function profileWith(e : Edit, els : {Elevation}, len : number) : profiles.Profile, string
	local pts : {profiles.Point} = { { s = 0, z = e.a.z } }
	for _, el in ipairs(els) do pts[#pts + 1] = { s = el.f * len, z = el.z } end
	pts[#pts + 1] = { s = len, z = e.b.z }
	return profiles.solve(pts, e.a.grade, -e.b.grade)
end

function M.profile(e : Edit, len : number) : profiles.Profile, string
	return profileWith(e, e.elevations, len)
end

local function steepestOf(p : profiles.Profile, ss : {number}) : number
	local worst = 0.0
	for _, s in ipairs(ss) do worst = math.max(worst, math.abs(profiles.gradeAt(p, s))) end
	return worst
end

-- The steepest grade at the chainages ss (the nodes'), as a magnitude; huge if there is no profile.
function M.steepest(e : Edit, len : number, ss : {number}) : number
	local p = M.profile(e, len)
	if p == nil then return math.huge end
	return steepestOf(p, ss)
end

-- Where elevation point i may go along the path: MIN_SPAN from its neighbours (m).
local function spanRoom(e : Edit, i : integer, len : number) : number, number
	local els = e.elevations
	local lo = i > 1 and els[i - 1].f * len or 0.0
	local hi = i < #els and els[i + 1].f * len or len
	return lo + M.MIN_SPAN, hi - M.MIN_SPAN
end

-- Add an elevation point at chainage s on the profile as it is. Its index, or nil and why not.
function M.insertElevation(e : Edit, s : number, len : number) : integer, string
	local p, why = M.profile(e, len)
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
-- and the move stops where the steepest grade at the chainages ss would pass the limit (or, on a
-- profile already past it, would get steeper). false when it cannot move at all.
function M.moveElevation(e : Edit, i : integer, s : number, z : number, len : number, ss : {number}, limit : number) : boolean
	local el = e.elevations[i]
	if el == nil then return false end
	local lo, hi = spanRoom(e, i, len)
	if lo > hi then return false end
	s = math.max(lo, math.min(hi, s))
	local s0, z0 = el.f * len, el.z
	local allowed = math.max(limit, M.steepest(e, len, ss))
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
