-- The starting alignment between two picked ends. A free track end is a point and the unit
-- direction pointing out of the existing track, away from it; the new track leaves the first end
-- along its direction and arrives at the second against its direction. The PIs put the first leg
-- along the first end's direction and the last leg along the second end's, so buildPath keeps both
-- headings. A ground end has no heading: it takes its leg's direction (a path end with no curve
-- at it). An existing node with track through it (or a junction) has a direction for each piece
-- there, in either sense; aimed at the other end, it takes the one pointing most toward it (as a
-- switch diverges) and is then laid like a free track end. A layout uses only as many turns as
-- the ends' geometry needs (initialPis): none, one where the rays meet, one on each end's ray, or
-- (ends far apart) a lead on each ray and a free turn between; with one ground end, one turn on
-- the other end's ray.
-- Also what the mouse picks (snap): a free end or node tg_world finds near it, else the ground
-- there.
-- No game API here, so test/ends_test.lua runs it outside the game.

local geometry = require("westrom_track_geometry::/track_geometry/tg_geometry.script.tl")

-- What an end of the alignment is: "track", a free track end, where a line of track stops (a node
-- with a single track piece); "node", an existing node with track through it or a junction (the
-- new track leaves it as a switch); "ground", a point on open ground, with no heading, grade or
-- node; "split", a point partway along a track piece (the build cuts the piece there and the new
-- track leaves the cut as a switch, as from a node).
local enum Kind
	"track"
	"node"
	"split"
	"ground"
end

-- A point in the world (m).
local record Point
	x : number
	y : number
	z : number
end

-- An existing track piece: the cubic Hermite from p0 to p1 with tangents t0, t1 (as the game
-- keeps them: the curve is h00 p0 + h10 t0 + h01 p1 + h11 t1 over u in [0, 1]), between its nodes.
local record Piece
	edge : integer
	node0 : integer
	node1 : integer
	p0 : Point
	t0 : Point
	p1 : Point
	t1 : Point
	beyond : {Piece} -- the track running on past its ends (tg_world.piece reads it when asked); nil: not read
end

-- A direction along a piece at a node: unit (dx, dy), and the piece's grade going that way.
local record Dir
	dx : number
	dy : number
	grade : number
end

-- An end of the alignment: where it is, and what it is. The layouts, profile, plan, proposal and
-- session read an end only through this.
local record End
	kind : Kind
	x : number
	y : number
	z : number -- height (m)
	dx : number -- unit direction out of the existing track, away from it; nil when it has none
	dy : number -- (nil with dx)
	grade : number -- the existing track's grade, going out along (dx, dy); nil when it has none
	node : integer -- the existing node at the end; nil when there is none
	dirs : {Dir} -- a node or split end: every direction along a piece there, in either sense (aim picks one)
	piece : Piece -- a split end: the piece it cuts...
	u : number -- ...and where along it (its curve parameter, 0 to 1)
	beside : {Piece} -- a node or split end: the existing track there and on past it, which the new track must clear
end

-- Existing track merged into one piece from a switch outward (M.runs).
local record Run
	first : Piece -- the piece at the switch: a piece at the node, or a half of the cut piece
	fromStart : boolean -- it leaves the switch from its start (else from its end)
	edges : {integer} -- the pieces it takes in, outward
	nodes : {integer} -- the joints between them, which go
	node : integer -- the node the merged piece ends on
	p : Point -- ...and where that is
	t0 : Point -- the merged piece's tangent at the switch, pointing away from it
	t1 : Point -- ...and at its far end, likewise
end

local record Ends
	Kind : Kind
	Run : Run
	Dir : Dir
	Point : Point
	Piece : Piece
	End : End
	SNAP : number
	SWITCH_RADIUS : number
	CLEAR : number
	NEAR : number
	RUN_TURN : number
	NODE_SNAP : number
	PIECE_SNAP : number
	MIN_HALF : number
	MIN_LEG : number
	MAX_REACH : number
	LEAD : number
	FAR : number
	STRAIGHT_ANGLE : number
	STRAIGHT_OFFSET : number
	trackEnd : function(node : integer, x : number, y : number, z : number, dx : number, dy : number,
		grade : number) : End
	groundEnd : function(x : number, y : number, z : number) : End
	nodeEnd : function(node : integer, x : number, y : number, z : number, dirs : {Dir}, beside ?: {Piece}) : End
	clearance : function(e : End, x : number, y : number) : number
	runs : function(e : End, branch : Piece, mayGo : function(joint : integer, from : integer, to : integer) : boolean) : {Run}
	aim : function(e : End, x : number, y : number) : End
	pieceAt : function(pc : Piece, u : number) : Point, Point
	nearestOnPiece : function(pc : Piece, x : number, y : number) : number
	nearestPiece : function(pieces : {Piece}, x : number, y : number, skip ?: integer) : Piece
	halves : function(pc : Piece, u : number) : Piece, Piece
	splitEnd : function(pc : Piece, u : number) : End
	hasHeading : function(e : End) : boolean
	name : function(e : End) : string
	key : function(e : End) : string
	initialPis : function(a : End, b : End) : {geometry.Vec}, string
	snap : function(near : {End}, piece : Piece, x : number, y : number, z : number, exclude : End) : End, string
end

local M : Ends = {}

-- Shortest leg from an end to its PI (m).
M.MIN_LEG = 20.0
-- Furthest the rays may meet from an end for a "corner" (m). Rays that meet further away (nearly
-- parallel) make an "s-curve".
M.MAX_REACH = 1000.0
-- How far out of each end its lead PI goes (m), when the room allows.
M.LEAD = 200.0
-- Ends further apart than this (m) get the "long s-curve" layout, unless they are in line.
M.FAR = 800.0
-- Float noise: ends this close to one line are exactly in line. The game keeps positions and
-- tangents in single precision: two ends of one straight line came out 1.4e-7 rad and 0.086 mm
-- apart, and a position on an 8 km map is only good to about 0.5 mm. Anything more is a kink a
-- straight would hide. (Sine of the angle between the directions; offset across the line, m.)
M.STRAIGHT_ANGLE = 1e-6
M.STRAIGHT_OFFSET = 0.002
-- A free end this close to the mouse snaps to it (m).
M.SNAP = 40.0
-- The radius a switch (a node or cut end) leaves on, as its starting layout puts it (m): the
-- game's own builder branched off a straight at 182 m (and builds them as gentle as 4 km).
M.SWITCH_RADIUS = 180.0
-- A new piece may overlap the existing track only where it shares a node with it: the game
-- refuses one that does not ("Construction Not Possible"). So the first piece out of a switch runs
-- on to the first node this far from the track beside it (m, centre to centre: parallel tracks'
-- spacing), as the game's own builder lays the whole branch out of a switch as one piece.
M.CLEAR = 5.0
-- A node with track through it this close to the mouse snaps to it (m); further, a click on track
-- cuts the piece there. (MIN_HALF: as near a node as a cut can be.)
M.NODE_SNAP = 5.0
-- Shortest part of a piece a cut may leave (m): nearer its end, the node there is picked instead.
M.MIN_HALF = 5.0

-- The free track end at node, at (x, y, z), with (dx, dy) the unit direction out of its piece and
-- grade the piece's grade going out along it.
function M.trackEnd(node : integer, x : number, y : number, z : number, dx : number, dy : number, grade : number) : End
	return { kind = "track", node = node, x = x, y = y, z = z, dx = dx, dy = dy, grade = grade }
end

-- The point (x, y) on the ground, z the terrain's height there.
function M.groundEnd(x : number, y : number, z : number) : End
	return { kind = "ground", x = x, y = y, z = z }
end

-- The existing node `node` at (x, y, z) with track through it, its directions dirs. It has no
-- heading until aimed.
function M.nodeEnd(node : integer, x : number, y : number, z : number, dirs : {Dir}, beside ?: {Piece}) : End
	return { kind = "node", node = node, x = x, y = y, z = z, dirs = dirs, beside = beside }
end

-- A node or split end aimed at (x, y): heading along the direction there pointing most toward it,
-- at that direction's grade. Any other end, or (x, y) on the end, as it is.
function M.aim(e : End, x : number, y : number) : End
	if e.dirs == nil or x == nil then return e end
	local ex, ey = x - e.x, y - e.y
	if ex * ex + ey * ey < 1e-12 then return e end
	local best : Dir = nil
	local bestDot = -math.huge
	for _, d in ipairs(e.dirs) do
		local dot = d.dx * ex + d.dy * ey
		if dot > bestDot then best, bestDot = d, dot end
	end
	if best == nil then return e end
	return { kind = e.kind, node = e.node, piece = e.piece, u = e.u, x = e.x, y = e.y, z = e.z, dirs = e.dirs,
		beside = e.beside, dx = best.dx, dy = best.dy, grade = best.grade }
end

local function pt(x : number, y : number, z : number) : Point return { x = x, y = y, z = z } end

-- The point at u along piece pc, and the curve's derivative there (d/du).
function M.pieceAt(pc : Piece, u : number) : Point, Point
	local u2, u3 = u * u, u * u * u
	local h00, h10, h01, h11 = 2 * u3 - 3 * u2 + 1, u3 - 2 * u2 + u, -2 * u3 + 3 * u2, u3 - u2
	local d00, d10, d01, d11 = 6 * u2 - 6 * u, 3 * u2 - 4 * u + 1, -6 * u2 + 6 * u, 3 * u2 - 2 * u
	local p0, m0, p1, m1 = pc.p0, pc.t0, pc.p1, pc.t1
	return pt(h00 * p0.x + h10 * m0.x + h01 * p1.x + h11 * m1.x, h00 * p0.y + h10 * m0.y + h01 * p1.y + h11 * m1.y,
			h00 * p0.z + h10 * m0.z + h01 * p1.z + h11 * m1.z),
		pt(d00 * p0.x + d10 * m0.x + d01 * p1.x + d11 * m1.x, d00 * p0.y + d10 * m0.y + d01 * p1.y + d11 * m1.y,
			d00 * p0.z + d10 * m0.z + d01 * p1.z + d11 * m1.z)
end

-- The curve parameter of the point on piece pc nearest (x, y), in plan.
function M.nearestOnPiece(pc : Piece, x : number, y : number) : number
	local function d2(u : number) : number
		local p = M.pieceAt(pc, u)
		return (p.x - x) ^ 2 + (p.y - y) ^ 2
	end
	local N = 64
	local bu, bd = 0.0, d2(0)
	for i = 1, N do
		local d = d2(i / N)
		if d < bd then bu, bd = i / N, d end
	end
	-- (then golden-section search in the samples on either side)
	local lo, hi = math.max(0, bu - 1 / N), math.min(1, bu + 1 / N)
	local g = (math.sqrt(5) - 1) / 2
	for _ = 1, 40 do
		local a, b = hi - g * (hi - lo), lo + g * (hi - lo)
		if d2(a) < d2(b) then hi = b else lo = a end
	end
	return (lo + hi) / 2
end

-- The mouse need not be on a track to cut it: a piece this close to it is picked (m, in plan; the
-- piece under the mouse comes first).
M.PIECE_SNAP = 8.0

-- The piece of `pieces` nearest (x, y) in plan, within PIECE_SNAP (nil: none); never edge `skip`.
function M.nearestPiece(pieces : {Piece}, x : number, y : number, skip ?: integer) : Piece
	local best : Piece = nil
	local bestD = M.PIECE_SNAP
	for _, pc in ipairs(pieces) do
		if pc.edge ~= skip then
			local p = M.pieceAt(pc, M.nearestOnPiece(pc, x, y))
			local d = math.sqrt((p.x - x) ^ 2 + (p.y - y) ^ 2)
			if d <= bestD then best, bestD = pc, d end
		end
	end
	return best
end

-- Piece pc cut at u: the part before and the part after, each a Hermite of its own (the tangents
-- scale with the part's share), meeting at the cut with no kink.
function M.halves(pc : Piece, u : number) : Piece, Piece
	local p, d = M.pieceAt(pc, u)
	local function scaled(v : Point, k : number) : Point return pt(v.x * k, v.y * k, v.z * k) end
	return { edge = pc.edge, node0 = pc.node0, p0 = pc.p0, t0 = scaled(pc.t0, u), p1 = p, t1 = scaled(d, u) },
		{ edge = pc.edge, node1 = pc.node1, p0 = p, t0 = scaled(d, 1 - u), p1 = pc.p1, t1 = scaled(pc.t1, 1 - u) }
end

-- The point at u along piece pc as an end: its directions are the piece's there, in either sense.
function M.splitEnd(pc : Piece, u : number) : End
	local p, d = M.pieceAt(pc, u)
	local len = math.sqrt(d.x * d.x + d.y * d.y)
	if len < 1e-9 then return nil end
	local fx, fy, fg = d.x / len, d.y / len, d.z / len
	local a, b = M.halves(pc, u)
	local beside : {Piece} = { a, b }
	for _, q in ipairs(pc.beyond or {}) do beside[#beside + 1] = q end
	return { kind = "split", piece = pc, u = u, x = p.x, y = p.y, z = p.z, beside = beside,
		dirs = { { dx = fx, dy = fy, grade = fg }, { dx = -fx, dy = -fy, grade = -fg } } }
end

-- How far (x, y) is from the existing track beside end e, in plan (math.huge: none there).
function M.clearance(e : End, x : number, y : number) : number
	local best = math.huge
	for _, pc in ipairs(e.beside or {}) do
		local p = M.pieceAt(pc, M.nearestOnPiece(pc, x, y))
		best = math.min(best, math.sqrt((p.x - x) ^ 2 + (p.y - y) ^ 2))
	end
	return best
end

-- A shallow switch runs beside the track it leaves for a long way, past that track's joints, and
-- the game refuses the new piece where it overlaps a piece it shares no node with (a crossover
-- between tracks 5 m apart built with the next joint 1.7 m off its centre line and was refused
-- with one 0.4 m off). So the track's pieces are merged through every joint within NEAR of the
-- new piece (m, in plan), while the merged piece turns no more than RUN_TURN.
M.NEAR = 2.5
M.RUN_TURN = math.rad(15)

-- The existing track at switch end e to merge, given the new piece there (`branch`): from each
-- piece at the switch outward through the joints within NEAR of the branch. mayGo(joint, from,
-- to) says whether the joint between pieces `from` and `to` (edges) can go. Only runs that take
-- in a piece.
function M.runs(e : End, branch : Piece, mayGo : function(joint : integer, from : integer, to : integer) : boolean) : {Run}
	local out : {Run} = {}
	local beside = e.beside or {}
	local function length(v : Point) : number return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end
	local function scaled(v : Point, k : number) : Point return pt(v.x * k, v.y * k, v.z * k) end
	for _, first in ipairs(beside) do
		-- (which way the piece leaves the switch: from its start, from its end, or not at all)
		local fromStart : boolean = nil
		if e.kind == "split" then
			if first.edge == e.piece.edge then fromStart = first.node0 == nil end
		elseif e.node ~= nil then
			if first.node0 == e.node then fromStart = true elseif first.node1 == e.node then fromStart = false end
		end
		if fromStart ~= nil then
			local start = fromStart and first.t0 or scaled(first.t1, -1)
			local run : Run = { first = first, fromStart = fromStart, edges = {}, nodes = {} }
			local cur, forward, len = first, fromStart, length(start)
			local taken : {integer : boolean} = { [first.edge] = true }
			while true do
				local joint = forward and cur.node1 or cur.node0
				local at = forward and cur.p1 or cur.p0
				run.node, run.p = joint, at
				run.t1 = forward and cur.t1 or scaled(cur.t0, -1)
				local on = M.pieceAt(branch, M.nearestOnPiece(branch, at.x, at.y))
				if joint == nil or math.sqrt((on.x - at.x) ^ 2 + (on.y - at.y) ^ 2) >= M.NEAR then break end
				local nxt : Piece = nil
				local count = 0
				for _, q in ipairs(beside) do
					if not taken[q.edge] and (q.node0 == joint or q.node1 == joint) then nxt, count = q, count + 1 end
				end
				if count ~= 1 then break end
				local nextForward = nxt.node0 == joint
				local far = nextForward and nxt.t1 or scaled(nxt.t0, -1)
				local cosTurn = (start.x * far.x + start.y * far.y)
					/ math.max(1e-9, math.sqrt((start.x ^ 2 + start.y ^ 2) * (far.x ^ 2 + far.y ^ 2)))
				if cosTurn < math.cos(M.RUN_TURN) or not mayGo(joint, cur.edge, nxt.edge) then break end
				taken[nxt.edge] = true
				run.edges[#run.edges + 1], run.nodes[#run.nodes + 1] = nxt.edge, joint
				len = len + length(nextForward and nxt.t0 or nxt.t1)
				cur, forward = nxt, nextForward
			end
			if #run.edges > 0 then
				run.t0 = scaled(start, len / math.max(1e-9, length(start)))
				run.t1 = scaled(run.t1, len / math.max(1e-9, length(run.t1)))
				out[#out + 1] = run
			end
		end
	end
	return out
end

-- Does the new track have to leave (or arrive at) e along a direction of its own?
function M.hasHeading(e : End) : boolean
	return e.dx ~= nil
end

-- e for a person: "node 7", "piece 12", "the ground at (120, -45)".
function M.name(e : End) : string
	if e.piece ~= nil then return "piece " .. tostring(e.piece.edge) end
	if e.node ~= nil then return "node " .. tostring(e.node) end
	return string.format("the ground at (%.0f, %.0f)", e.x, e.y)
end

-- What tells e apart from another end: a cut's piece and where along it, else its node, else where
-- it is (to the centimetre); and a node or cut end's heading once aimed.
function M.key(e : End) : string
	if e.piece ~= nil then
		return string.format("p%d@%.4f", e.piece.edge, e.u) .. (e.dx ~= nil and string.format("@%.6f,%.6f", e.dx, e.dy) or "")
	end
	if e.kind == "node" and e.dx ~= nil then return string.format("n%d@%.6f,%.6f", e.node, e.dx, e.dy) end
	if e.node ~= nil then return "n" .. tostring(e.node) end
	return string.format("g%.2f,%.2f", e.x, e.y)
end

-- Is e a switch: an end on existing track that runs on past it (a node end or a cut)?
local function isSwitch(e : End) : boolean
	return e.dirs ~= nil
end

-- How far out on switch a's ray its turn goes so that the curve there, taking the whole leg from
-- a, has radius SWITCH_RADIUS toward (x, y): t = R tan(d / 2), d the turn's deflection (which
-- grows with t), found by bisection on [MIN_LEG, dist]. nil when no t there fits (the curve at
-- dist is still tighter: any layout leaves on a tighter curve).
local function switchLead(a : End, x : number, y : number) : number
	local function gap(t : number) : number
		local vx, vy = x - (a.x + t * a.dx), y - (a.y + t * a.dy)
		local l = math.sqrt(vx * vx + vy * vy)
		if l < 1e-9 then return t end
		local c = math.max(-1.0, math.min(1.0, (vx * a.dx + vy * a.dy) / l))
		return t - M.SWITCH_RADIUS * math.tan(math.min(math.acos(c), math.rad(179)) / 2)
	end
	local lo, hi = M.MIN_LEG, math.sqrt((x - a.x) ^ 2 + (y - a.y) ^ 2)
	if gap(lo) >= 0 then return lo end
	if hi <= lo or gap(hi) < 0 then return nil end
	for _ = 1, 60 do
		local mid = (lo + hi) / 2
		if gap(mid) < 0 then lo = mid else hi = mid end
	end
	return (lo + hi) / 2
end

-- With b a ground end and a not: one turn on a's ray, as far from a as from b, so the curve there
-- is symmetric and takes all of both legs ("arc", like the game's own arc). That turn is at least
-- dist/2 out, so never closer than MIN_LEG; when b is behind or beside a (no such turn) or it is
-- further out than MAX_REACH, the turn goes min(LEAD, dist/3) out ("turn on the ray"). Laid from
-- a to b; the caller reverses it when the ground end comes first. A switch's turn goes no further
-- out than switchLead ("switch").
local function towardGround(a : End, b : End, dist : number) : {geometry.Vec}, string
	local ex, ey = b.x - a.x, b.y - a.y
	local along = ex * a.dx + ey * a.dy
	-- |a + t (a.dx, a.dy) - b| = t
	local t = along > 0 and dist * dist / (2 * along) or math.huge
	local how = "arc"
	if t > M.MAX_REACH then t, how = math.min(M.LEAD, dist / 3), "turn on the ray" end
	local tS = isSwitch(a) and switchLead(a, b.x, b.y) or nil
	if tS ~= nil and tS < t then t, how = tS, "switch" end
	return { geometry.vec(a.x, a.y, 0), geometry.vec(a.x + t * a.dx, a.y + t * a.dy, 0), geometry.vec(b.x, b.y, 0) }, how
end

-- The PIs from a to b, at z = 0, and how they were laid. With a ground end:
--   "straight"    : both on the ground (no turns);
--   "arc", "turn on the ray", "switch": one ground end (towardGround).
-- Between two ends with headings, in order:
--   "straight"    : b exactly in line ahead of a, facing it (no turns);
--   "long s-curve": the ends more than FAR apart: a lead LEAD out on each end's ray and a free
--                   turn halfway between the leads, so the path does not run off towards a far
--                   meeting point (three turns);
--   "corner"      : the rays meet ahead of both ends, MIN_LEG to MAX_REACH from each: one turn
--                   there, next to both ends, so it is fixed until another is added;
--   "s-curve"     : else one turn on each end's ray, min(LEAD, a third of the distance) out.
-- A switch's turn (a lead, the corner) goes no further out on its ray than switchLead toward the
-- other end: no corner further, and a lead no longer.
-- The first and last legs run along the ends' rays, so the path keeps both headings. nil and a
-- reason when the ends are too close.
function M.initialPis(a : End, b : End) : {geometry.Vec}, string
	local ex, ey = b.x - a.x, b.y - a.y
	local dist = math.sqrt(ex * ex + ey * ey)
	if dist < 2 * M.MIN_LEG then return nil, "the ends are too close" end
	local ha, hb = M.hasHeading(a), M.hasHeading(b)
	if not ha and not hb then return { geometry.vec(a.x, a.y, 0), geometry.vec(b.x, b.y, 0) }, "straight" end
	if not hb then return towardGround(a, b, dist) end
	if not ha then
		local back, how = towardGround(b, a, dist)
		return { back[3], back[2], back[1] }, how
	end
	local pa, pb = geometry.vec(a.x, a.y, 0), geometry.vec(b.x, b.y, 0)
	local function out(e : End, l : number) : geometry.Vec return geometry.vec(e.x + l * e.dx, e.y + l * e.dy, 0) end
	-- a + s (a.dx, a.dy) = b + t (b.dx, b.dy)
	local cross = a.dx * b.dy - a.dy * b.dx
	local along = ex * a.dx + ey * a.dy
	local lateral = a.dx * ey - a.dy * ex
	local facing = a.dx * b.dx + a.dy * b.dy < 0
	if facing and along > 0 and math.abs(cross) <= M.STRAIGHT_ANGLE and math.abs(lateral) <= M.STRAIGHT_OFFSET then
		return { pa, pb }, "straight"
	end
	local capA = isSwitch(a) and (switchLead(a, b.x, b.y) or math.huge) or math.huge
	local capB = isSwitch(b) and (switchLead(b, a.x, a.y) or math.huge) or math.huge
	if dist > M.FAR then
		local la, lb = out(a, math.min(M.LEAD, capA)), out(b, math.min(M.LEAD, capB))
		return { pa, la, geometry.vec((la.x + lb.x) / 2, (la.y + lb.y) / 2, 0), lb, pb }, "long s-curve"
	end
	if cross ~= 0 then
		local s = (ex * b.dy - ey * b.dx) / cross
		local t = (a.dy * ex - a.dx * ey) / cross
		if s >= M.MIN_LEG and t >= M.MIN_LEG and s <= math.min(M.MAX_REACH, capA) and t <= math.min(M.MAX_REACH, capB) then
			return { pa, out(a, s), pb }, "corner"
		end
	end
	local L = math.min(M.LEAD, dist / 3)
	return { pa, out(a, math.min(L, capA)), out(b, math.min(L, capB)), pb }, "s-curve"
end

-- What the mouse at (x, y) picks, from the ends near it (free track ends and node ends) and the
-- track piece under or near the mouse (nil: none): the nearest end within reach (SNAP for a free end,
-- NODE_SNAP for a node); else on a piece, the point on it nearest the mouse (a cut); else the
-- ground there (z its height). Never the end exclude (the start), nor a cut of its piece. A cut
-- that would leave a part under MIN_HALF picks the node there instead; nil and a hint when that
-- node cannot be picked, or the mouse is over no ground.
function M.snap(near : {End}, piece : Piece, x : number, y : number, z : number, exclude : End) : End, string
	if x == nil then return nil, "Point at the ground or at a track." end
	local best : End = nil
	local bestD = math.huge
	for _, e in ipairs(near) do
		if exclude == nil or exclude.node == nil or e.node ~= exclude.node then
			local d = math.sqrt((e.x - x) ^ 2 + (e.y - y) ^ 2)
			if d <= (e.kind == "track" and M.SNAP or M.NODE_SNAP) and d < bestD then best, bestD = e, d end
		end
	end
	if best ~= nil then return best, nil end
	if piece ~= nil then
		if exclude ~= nil and exclude.piece ~= nil and exclude.piece.edge == piece.edge then
			return nil, "The track starts on this piece. End it elsewhere."
		end
		local u = M.nearestOnPiece(piece, x, y)
		local a, b = M.halves(piece, u)
		local function chord(h : Piece) : number return math.sqrt((h.p1.x - h.p0.x) ^ 2 + (h.p1.y - h.p0.y) ^ 2 + (h.p1.z - h.p0.z) ^ 2) end
		if chord(a) < M.MIN_HALF or chord(b) < M.MIN_HALF then
			-- (too near the piece's end to cut: the node there, when it can be picked)
			local node = chord(a) < M.MIN_HALF and piece.node0 or piece.node1
			for _, e in ipairs(near) do
				if e.node == node and (exclude == nil or exclude.node ~= node) then return e, nil end
			end
			return nil, "Too near the node: point at it."
		end
		local e = M.splitEnd(piece, u)
		if e ~= nil then return e, nil end
	end
	if z == nil then return nil, "Point at the ground or at a track." end
	return M.groundEnd(x, y, z), nil
end

return M
