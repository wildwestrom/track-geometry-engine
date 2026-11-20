-- The gizmos of the edit, as shapes: what is drawn, in what order, cut how, at what height and in
-- which colour role. tg_gui turns each shape into EdgeRenderable edges and picks the colours (look),
-- so no game API here, and test/gizmos_test.lua runs it outside the game.
--   horizontal: the osculating circle of every curve (first, so the rest draw on top; display
--               only, never picked), the PI polyline over the ground, a line along every
--               transition spiral (display only), a circle at each turn and ground end (coloured
--               by how it can move) and a bracket at each curve's start and end, open towards its
--               curve.
--   vertical  : at each end and elevation point a circle on the ground (where the mouse grabs it)
--               and a post from the ground up to the track (a point's own height).
-- Widths and steps are in metres. The width is GIZMO_WIDTH near the eye (Network Toolkit's
-- settings: 1.5, with the geometry 1 wide and 1 m steps) and grows with the distance from it
-- (widthAt), so the lines stay visible zoomed out; each circle is at its handle's own grab radius
-- (tg_edit.grabAt, from the eye of the session's view ray), so what is drawn is what the mouse picks.

local edits = require("track_geometry_tool::/track_geometry/tg_edit.script.tl")
local ends = require("track_geometry_tool::/track_geometry/tg_ends.script.tl")
local geometry = require("track_geometry_tool::/track_geometry/tg_geometry.script.tl")
local profiles = require("track_geometry_tool::/track_geometry/tg_profile.script.tl")
local sessions = require("track_geometry_tool::/track_geometry/tg_session.script.tl")

local enum ShapeKind
	"line" -- a polyline through pts, drawn as one straight edge per pair of points
	"circle" -- round (x, y, z), of radius r, flat
end

-- A gizmo to draw: in colour role `color` (tg_gui's COLORS), width wide, in steps `step` long (m).
local record Shape
	kind : ShapeKind
	pts : {{number}} -- line: its points, each {x, y, z}
	x : number -- circle: its centre and radius
	y : number
	z : number
	r : number
	color : string
	width : number
	step : number
end

-- An osculating circle: the full circle of one of the path's arcs, round its centre (x, y), of its
-- radius r; where the arc's midpoint is (mx, my), and the height to show it at: the track's there
-- (z; nil with no profile: the ground at the midpoint).
local record Circle
	x : number
	y : number
	r : number
	mx : number
	my : number
	z : number
end

local record GizmosMod
	Shape : Shape
	Circle : Circle
	GIZMO_STEP : number
	GIZMO_WIDTH : number
	WIDTH_SHARE : number
	WIDTH_RATIO : number
	widthAt : function(eye : ends.Point, x : number, y : number, z : number, floor : number) : number
	LEG_STEP : number
	MAX_LEG_PIECES : integer
	of : function(sess : sessions.Session, groundAt : function(x : number, y : number) : number) : {Shape}
	circles : function(e : edits.Edit) : {Circle}
end

local M : GizmosMod = {}
M.GIZMO_STEP = 1.0 -- a gizmo is drawn in steps this long (m), unless it says otherwise
M.GIZMO_WIDTH = 1.5 -- a gizmo line's width near the eye (its floor: see widthAt)
-- A line's width away from the eye: this share of its distance from it (to stay about one size
-- on the screen), in steps of WIDTH_RATIO, so a small camera move changes no width (and redraws
-- nothing). Tuned by hand in game.
M.WIDTH_SHARE = 0.002
M.WIDTH_RATIO = 1.25

-- The width of a line at (x, y, z) (m): WIDTH_SHARE of its distance from eye, rounded to a whole
-- number of WIDTH_RATIO steps up from floor; floor near the eye, or with no eye.
function M.widthAt(eye : ends.Point, x : number, y : number, z : number, floor : number) : number
	if eye == nil then return floor end
	local want = M.WIDTH_SHARE * math.sqrt((x - eye.x) ^ 2 + (y - eye.y) ^ 2 + (z - eye.z) ^ 2)
	if want <= floor then return floor end
	return floor * M.WIDTH_RATIO ^ math.floor(math.log(want / floor) / math.log(M.WIDTH_RATIO) + 0.5)
end

-- (a line's width at a point: widthAt from the session's eye)
local type Width = function(x : number, y : number, z : number) : number
M.LEG_STEP = 10.0 -- legs (and spirals) are cut into pieces this long (m)...
M.MAX_LEG_PIECES = 60 -- ...or this many per line, on long ones
local POST_GAP = 0.1 -- a point this far (m) or less off the ground gets no post

-- The osculating circle of every arc of the path, in order along it, at the profile's height at
-- the arc's midpoint. A corner whose spirals take the whole turn has an arc of no sweep: its
-- spirals meet at curvature 1/R, and the circle is there.
local function circlesOf(path : {geometry.Segment}, p : profiles.Profile) : {Circle}
	local cs : {Circle} = {}
	local s0 = 0.0 -- the chainage where seg starts
	for i, seg in ipairs(path) do
		local len = geometry.length(seg)
		local m : geometry.Vec -- the arc's midpoint
		local v : geometry.Vec -- the tangent there
		local s : number -- its chainage
		if seg.kind == "arc" then
			m, v, s = geometry.pointAt(seg, len / 2), geometry.tangentAt(seg, len / 2), s0 + len / 2
		elseif seg.kind == "out" and i > 1 and path[i - 1].kind == "in" then
			m, v, s = seg.p, seg.v, s0
		end
		if m ~= nil then
			local o = geometry.circleCenter(m, v, seg.radius, seg.B)
			cs[#cs + 1] = { x = o.x, y = o.y, r = seg.radius, mx = m.x, my = m.y, z = p and profiles.heightAt(p, s) }
		end
		s0 = s0 + len
	end
	return cs
end

function M.circles(e : edits.Edit) : {Circle}
	return circlesOf(edits.path(e), (edits.profile(e)))
end

local function circle(x : number, y : number, z : number, r : number, color : string, width : number, step : number) : Shape
	return { kind = "circle", x = x, y = y, z = z, r = r, color = color, width = width, step = step }
end

-- (as wide as at its middle point)
local function line(pts : {{number}}, color : string, w : Width) : Shape
	local mid = pts[math.floor((#pts + 1) / 2)]
	return { kind = "line", pts = pts, color = color, width = w(mid[1], mid[2], mid[3]), step = M.GIZMO_STEP }
end

-- How many pieces a line len long is cut into: each at most LEG_STEP long (longer on very long
-- lines, so at most MAX_LEG_PIECES).
local function pieces(len : number) : integer
	return math.max(1, math.ceil(len / math.max(M.LEG_STEP, len / M.MAX_LEG_PIECES)))
end

-- The leg from a to b, in pieces, each point at the height zAt gives.
local function legPoints(a : geometry.Vec, b : geometry.Vec, zAt : function(number, number) : number) : {{number}}
	local len = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
	local n = pieces(len)
	local pts : {{number}} = {}
	for k = 0, n do
		local t = k / n
		local x, y = a.x + t * (b.x - a.x), a.y + t * (b.y - a.y)
		pts[k + 1] = { x, y, zAt(x, y) }
	end
	return pts
end

-- Every transition spiral of the path (its in and out pieces), each along its piece in pieces like
-- a leg, at the profile's height at each point's chainage (with no profile p, over the ground).
local function spiralPoints(path : {geometry.Segment}, p : profiles.Profile, groundAt : function(number, number) : number) : {{{number}}}
	local out : {{{number}}} = {}
	local s0 = 0.0 -- the chainage where seg starts
	for _, seg in ipairs(path) do
		local len = geometry.length(seg)
		if seg.kind == "in" or seg.kind == "out" then
			local n = pieces(len)
			local pts : {{number}} = {}
			for k = 0, n do
				local t = len * k / n
				local q = geometry.pointAt(seg, t)
				pts[k + 1] = { q.x, q.y, p and profiles.heightAt(p, s0 + t) or groundAt(q.x, q.y) }
			end
			out[#out + 1] = pts
		end
		s0 = s0 + len
	end
	return out
end

-- A 〔 at bracket h, flat at height z: a bar across the leg, past the circles; at each end a
-- slanted corner and then a tip along the leg, towards the curve.
local function bracketPoints(h : edits.Hit, z : number, r : number) : {{number}}
	local bar, tip = edits.BRACKET_BAR * r, edits.BRACKET_TIP * r
	local corner = tip / 2
	local shape = { { tip, bar }, { corner, bar }, { 0, bar - corner }, { 0, corner - bar }, { corner, -bar }, { tip, -bar } }
	local pts : {{number}} = {}
	for k, sh in ipairs(shape) do
		local along, across = sh[1], sh[2]
		pts[k] = { h.x + h.ux * along - h.uy * across, h.y + h.uy * along + h.ux * across, z }
	end
	return pts
end

local function horizontal(sess : sessions.Session, groundAt : function(number, number) : number, w : Width) : {Shape}
	local e, r, ray = sess.edit, sess.grab, sess.ray
	local hot = sess.drag or sess.hit
	local function isHot(h : edits.Hit) : boolean return hot ~= nil and hot.kind == h.kind and hot.i == h.i end
	local out : {Shape} = {}
	local path, p = edits.path(e), edits.profile(e) -- (one profile solve for the circles and spirals)
	for _, c in ipairs(circlesOf(path, p)) do
		local z = c.z or groundAt(c.mx, c.my)
		-- (in steps that grow with the zoom, so km-wide circles stay cheap zoomed out: a quarter of
		-- GRAB of the eye's distance, with no ceiling, or of r with no eye)
		local zoom = r
		if ray ~= nil then zoom = ends.GRAB * math.sqrt((c.x - ray.ex) ^ 2 + (c.y - ray.ey) ^ 2 + (z - ray.ez) ^ 2) end
		local step = math.max(M.GIZMO_STEP, zoom / 4)
		out[#out + 1] = circle(c.x, c.y, z, c.r, "osculating", w(c.mx, c.my, z), step) -- (as wide as at its arc)
	end
	-- (the legs and handles: up at the track's height beside them, or on the ground with no profile)
	local function trackAt(x : number, y : number) : number
		return p and edits.trackHeightAt(e, p, x, y) or groundAt(x, y)
	end
	local pis = edits.polyline(e)
	for i = 1, #pis - 1 do
		local legHot = sess.drag == nil and isHot({ kind = "leg", i = i })
		out[#out + 1] = line(legPoints(pis[i], pis[i + 1], trackAt), legHot and "hot" or "leg", w)
	end
	for _, pts in ipairs(spiralPoints(path, p, groundAt)) do
		out[#out + 1] = line(pts, "spiral", w)
	end
	local hs = edits.handles(e)
	for _, h in ipairs(hs) do
		if h.kind == "pi" or h.kind == "end" then
			local role = isHot(h) and "hot" or h.kind == "pi" and h.mobility or "groundEnd"
			local z = edits.onGround(e, h) and groundAt(h.x, h.y) or trackAt(h.x, h.y)
			out[#out + 1] = circle(h.x, h.y, z, edits.grabAt(ray, h.x, h.y, z, r), role, w(h.x, h.y, z), M.GIZMO_STEP)
		end
	end
	for _, h in ipairs(hs) do
		if h.kind == "entry" or h.kind == "exit" then
			local z = trackAt(h.x, h.y)
			out[#out + 1] = line(bracketPoints(h, z, edits.grabAt(ray, h.x, h.y, z, r)), isHot(h) and "hot" or "bracket", w)
		end
	end
	return out
end

-- Roles: "fixed" at a track end (its height is the track's), "tooClose" at a point too close (it
-- is not in the profile), "hot" under the mouse or dragged, "selected", "ray" at an elevation point
-- (it slides along the path), "groundEnd" at a ground end (its height can be set).
local function vertical(sess : sessions.Session, groundAt : function(number, number) : number, w : Width) : {Shape}
	local e, r, ray = sess.edit, sess.grab, sess.ray
	local out : {Shape} = {}
	if edits.profile(e) == nil then return out end
	local h, d = sess.hit, sess.dragEl
	local hot = d ~= nil and d.i or (h ~= nil and h.kind ~= "track" and h.i or nil)
	for i, pt in ipairs(edits.points(e)) do
		local role = not pt.liftable and "fixed" or pt.tooClose and "tooClose" or i == hot and "hot"
			or i == sess.selected and "selected" or pt.slides and "ray" or "groundEnd"
		local g = groundAt(pt.x, pt.y)
		-- (its radius measured up at the point, where the mouse also picks it)
		out[#out + 1] = circle(pt.x, pt.y, g, edits.grabAt(ray, pt.x, pt.y, pt.z, r), role, w(pt.x, pt.y, g), M.GIZMO_STEP)
		if math.abs(pt.z - g) > POST_GAP then
			-- (a hair off vertical: a straight with no run has no direction)
			out[#out + 1] = line({ { pt.x, pt.y, g }, { pt.x + 0.01, pt.y, pt.z } }, role, w)
		end
	end
	return out
end

-- The gizmos of sess's edit, in draw order (later on top), for its mode; groundAt gives the height
-- of the ground at (x, y), which handles sit over (the mouse picks them where it meets the ground).
function M.of(sess : sessions.Session, groundAt : function(x : number, y : number) : number) : {Shape}
	local ray = sess.ray
	local eye : ends.Point = ray ~= nil and { x = ray.ex, y = ray.ey, z = ray.ez } or nil
	local function w(x : number, y : number, z : number) : number return M.widthAt(eye, x, y, z, M.GIZMO_WIDTH) end
	if sessions.vertical(sess) then return vertical(sess, groundAt, w) end
	return horizontal(sess, groundAt, w)
end

return M
