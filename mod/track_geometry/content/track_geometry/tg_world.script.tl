-- What the tool reads from the game world: track type facts, the ground and water at a point, and
-- the track ends (is a node still there, the end at a node, the ends near a point). It
-- also holds what is known about how asking the game can crash it:
--   - asking the street system about an entity that is not a node crashes the game (no pcall
--     helps), so every node is checked first;
--   - a proposal that names a node that is gone kills the game, so callers check joinable()
--     before every ghost and build.
-- Every read is guarded; a failed read gives nil (or the defaults, for a track type) and never
-- raises. A track type's facts are cached per template and year; a failed lookup is not cached
-- (asked again next time) and is logged once per template.
-- All game API: there is no offline test. The choice of end to snap to is tg_ends.snap.

local ends = require("westrom_track_geometry::/track_geometry/tg_ends.script.tl")
local structures = require("westrom_track_geometry::/track_geometry/tg_structures.script.tl")

local TAG = "[westrom_track_geometry] "

-- What the tool needs to know about a track template.
local record TrackType
	template : string -- the template's file name
	name : string -- its name in the menu (its file name if it has none)
	speed : number -- the fastest of its lanes (m/s); 0 when unknown
	maxGrade : number -- the steepest grade it may be laid at (its maxSlopeBuild)
	bridgeType : integer -- the bridge type the game's menu would pick for it (nil: none on offer)
	tunnelType : integer -- the tunnel type
	structuresWhy : string -- why the bridge and tunnel types could not be read; nil when they were
end

local record WorldMod
	TrackType : TrackType
	BASE_TEMPLATE : string
	DEFAULT_GRADE : number
	-- track types
	trackType : function(template : string) : TrackType
	-- the ground
	ground : function(x : number, y : number) : number
	water : function(x : number, y : number) : boolean
	-- track ends
	nodeAlive : function(n : integer) : boolean
	freeEnd : function(n : integer) : ends.End
	nodeEnd : function(n : integer) : ends.End
	joinable : function(e : ends.End) : boolean
	isTrackEdge : function(e : integer) : boolean
	piecesAt : function(e : ends.End) : {integer}
	mergeable : function(joint : integer, from : integer, to : integer) : boolean
	endsNear : function(x : number, y : number, hovered : integer, skip ?: integer) : {ends.End}, ends.Piece
	piece : function(e : integer) : ends.Piece
end

local M : WorldMod = {}

M.BASE_TEMPLATE = "::/infrastructure/track/standard/standard.street_template"
M.DEFAULT_GRADE = 0.085 -- the game's own limit, when a template gives none

local function say(msg : string)
	print(TAG .. "world: " .. msg)
end

------------------------------------------------------------------ track types

local function templateOf(name : string) : StreetTemplate
	return api.res.streetTemplateRep.get(api.res.streetTemplateRep.find(name))
end

local function year() : integer
	local ok, y = pcall(function() : integer return ((api.engine.util as {string : any}).getYear as function() : integer)() end)
	return ok and y as integer or 0
end

-- The bridge or tunnel types on offer this year that carry rail.
local function offers(rep : ResTypeRep<integer, BridgeType>, y : integer) : {structures.Offer}
	local list : {structures.Offer} = {}
	for id, _ in pairs(rep.getAll()) do
		local r = rep.get(id) as {string : any}
		local menu = r.menuCategory as ModelMetadata.MenuCategory
		local av = r.availability as ModelMetadata.Availability
		local from, to = av ~= nil and av.yearFrom or 0, av ~= nil and av.yearTo or 0
		local rail = false
		for _, c in ipairs((r.carriers or {}) as {Carrier}) do
			if c == api.type["enum"].Carrier.RAIL then rail = true end
		end
		if rail and menu ~= nil and #menu.categories > 0 and (from == 0 or from <= y) and (to == 0 or y < to) then
			list[#list + 1] = { id = id, speedLimit = (r.speedLimit as number) or 0,
				autoSelectable = r.isAutoSelectable == nil or r.isAutoSelectable as boolean }
		end
	end
	return list
end

local cache : {string : TrackType} = {}
local failed : {string : boolean} = {} -- templates whose failure is already logged

-- The facts about a template (nil: standard track), cached per template and year. Where a lookup
-- fails, the defaults: its file name, speed 0, DEFAULT_GRADE, no structures.
function M.trackType(template : string) : TrackType
	template = template or M.BASE_TEMPLATE
	local y = year()
	local key = template .. "@" .. y
	local hit = cache[key]
	if hit ~= nil then return hit end
	local t : TrackType = { template = template, name = template:match("([^/]+)%.street_template$") or template,
		speed = 0.0, maxGrade = M.DEFAULT_GRADE }
	local whys : {string} = {}
	local ok, err = pcall(function() : boolean
		local tpl = templateOf(template)
		local n = (tpl as table).name as string
		if n ~= nil and n ~= "" then t.name = n end
		local speed = 0.0
		for _, lc in ipairs(tpl.laneConfigs or {}) do speed = math.max(speed, lc.speed) end
		t.speed = speed
		local g = (tpl as {string : any}).maxSlopeBuild as number
		if g ~= nil and g > 0 then t.maxGrade = g end
		return true
	end)
	if not ok then whys[#whys + 1] = tostring(err) end
	local sok, serr = pcall(function() : boolean
		t.bridgeType = structures.pickType(offers(api.res.bridgeTypeRep, y), t.speed)
		t.tunnelType = structures.pickType(offers(api.res.tunnelTypeRep, y), t.speed)
		return true
	end)
	if not sok then
		t.structuresWhy = tostring(serr)
		whys[#whys + 1] = "structures: " .. t.structuresWhy
	end
	if #whys == 0 then
		cache[key] = t
		failed[template] = nil
		say(string.format("track type %s: %.0f km/h, grade limit %.1f permille, bridge %s, tunnel %s", t.name,
			t.speed * 3.6, t.maxGrade * 1000, tostring(t.bridgeType), tostring(t.tunnelType)))
	elseif not failed[template] then
		failed[template] = true
		say("track type " .. template .. ": " .. table.concat(whys, "; ") .. " (asked again next time)")
	end
	return t
end

------------------------------------------------------------------ the ground

-- The ground's height at (x, y), or nil when it cannot be read.
function M.ground(x : number, y : number) : number
	local ok, z = pcall(function() : number return api.engine.terrain.getHeightAt(api.type.Vec2f.new(x, y)) end)
	if ok and z ~= nil and z == z then return z as number end
	return nil
end

-- Is (x, y) on water? false when it cannot be read.
function M.water(x : number, y : number) : boolean
	local ok, w = pcall(function() : boolean return api.engine.terrain.isOnWater(api.type.Vec2f.new(x, y)) end)
	return ok and w == true
end

------------------------------------------------------------------ track ends

-- Is n still a node? (nil or negative: not an existing node, nothing to check.)
function M.nodeAlive(n : integer) : boolean
	if n == nil or n < 0 then return true end
	local ok, res = pcall(function() : boolean
		return api.engine.entityExists(n) and api.engine.getComponent(n, api.type.ComponentType.BASE_NODE) ~= nil
	end)
	return ok and res == true
end

-- The pieces at a node (tracks, else streets). Only ever asked about a live node.
local function segmentsAt(n : integer, tracks : boolean) : {integer}
	if not M.nodeAlive(n) then return {} end
	local sys = api.engine.system.streetSystem
	local ok, segs = pcall(tracks and sys.getNodeTrackSegments or sys.getNodeStreetSegments, n)
	if ok and segs ~= nil then return segs as {integer} end
	return {}
end

local runningOn : function(pieces : {ends.Piece}) : {ends.Piece}

-- The unit direction along piece be at its node n, away from n, and the piece's grade that way;
-- nil when its tangent there has no horizontal length.
local function awayFrom(be : Engine.Component.BaseEdge, n : integer) : ends.Dir
	local t = be.node0 == n and be.tangent0 or be.tangent1
	local sign = be.node0 == n and 1 or -1
	local len = math.sqrt(t.x * t.x + t.y * t.y)
	if len < 1e-6 then return nil end
	return { dx = sign * t.x / len, dy = sign * t.y / len, grade = sign * t.z / len }
end

-- The free track end at node n (a node with a single track piece and no street), or nil.
function M.freeEnd(n : integer) : ends.End
	if n == nil or n < 0 or not M.nodeAlive(n) then return nil end
	local segs = segmentsAt(n, true)
	if #segs ~= 1 or #segmentsAt(n, false) > 0 then return nil end -- (no level crossings)
	local ok, e = pcall(function() : ends.End
		local be = api.engine.getComponent(segs[1], api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		local node = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
		if be == nil or node == nil or be.roadType ~= api.type["enum"].RoadType.TRACK then return nil end
		local d = awayFrom(be, n)
		if d == nil then return nil end
		-- (out of the track: against the piece)
		return ends.trackEnd(n, node.position.x, node.position.y, node.position.z, -d.dx, -d.dy, -d.grade)
	end)
	return ok and e as ends.End or nil
end

-- The node end at node n (a node with two or more track pieces and no street: track through it,
-- or a junction), with each piece's direction there in either sense, or nil.
function M.nodeEnd(n : integer) : ends.End
	if n == nil or n < 0 or not M.nodeAlive(n) then return nil end
	local segs = segmentsAt(n, true)
	if #segs < 2 or #segmentsAt(n, false) > 0 then return nil end -- (no level crossings)
	local ok, e = pcall(function() : ends.End
		local node = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
		if node == nil then return nil end
		local dirs : {ends.Dir} = {}
		local at : {ends.Piece} = {}
		for _, seg in ipairs(segs) do
			at[#at + 1] = M.piece(seg)
			local be = api.engine.getComponent(seg, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
			if be ~= nil and be.roadType == api.type["enum"].RoadType.TRACK then
				local d = awayFrom(be, n)
				if d ~= nil then
					dirs[#dirs + 1] = d
					dirs[#dirs + 1] = { dx = -d.dx, dy = -d.dy, grade = -d.grade }
				end
			end
		end
		if #dirs == 0 then return nil end
		local beside = at
		for _, pc in ipairs(runningOn(at)) do beside[#beside + 1] = pc end
		return ends.nodeEnd(n, node.position.x, node.position.y, node.position.z, dirs, beside)
	end)
	return ok and e as ends.End or nil
end

-- The track pieces running on from `pieces`, out to RUN_ON along the track (not `pieces`
-- themselves): what a switch there must stay clear of besides them (ends.clearance).
local RUN_ON, RUN_ON_PIECES = 200.0, 24
runningOn = function(pieces : {ends.Piece}) : {ends.Piece}
	local seen : {integer : boolean} = {}
	local queue : {{ends.Piece, number}} = {}
	for _, pc in ipairs(pieces) do
		seen[pc.edge] = true
		queue[#queue + 1] = { pc, 0.0 }
	end
	local out : {ends.Piece} = {}
	local i = 1
	while i <= #queue and #out < RUN_ON_PIECES do
		local pc, far = queue[i][1] as ends.Piece, queue[i][2] as number
		i = i + 1
		for _, n in ipairs({ pc.node0, pc.node1 }) do
			for _, seg in ipairs(segmentsAt(n, true)) do
				if not seen[seg] then
					seen[seg] = true
					local q = M.piece(seg)
					if q ~= nil then
						out[#out + 1] = q
						local reach = far + math.sqrt((q.p1.x - q.p0.x) ^ 2 + (q.p1.y - q.p0.y) ^ 2)
						if reach < RUN_ON then queue[#queue + 1] = { q, reach } end
					end
				end
			end
		end
	end
	return out
end

-- The track piece e as the tool reads it, or nil (not a live track piece).
function M.piece(e : integer) : ends.Piece
	local ok, pc = pcall(function() : ends.Piece
		if e == nil or e <= 0 or not api.engine.entityExists(e) then return nil end
		local be = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		if be == nil or be.roadType ~= api.type["enum"].RoadType.TRACK then return nil end
		local function p(v : Vec3f) : ends.Point return { x = v.x, y = v.y, z = v.z } end
		return { edge = e, node0 = be.node0, node1 = be.node1, p0 = p(be.position0), t0 = p(be.tangent0),
			p1 = p(be.position1), t1 = p(be.tangent1) }
	end)
	return ok and pc as ends.Piece or nil
end

-- Is piece a still the piece b was read as (the same nodes, where they were, the same shape)?
local function samePiece(a : ends.Piece, b : ends.Piece) : boolean
	if a == nil or b == nil or a.node0 ~= b.node0 or a.node1 ~= b.node1 then return false end
	for _, k in ipairs({ "p0", "t0", "p1", "t1" }) do
		local u, v = (a as {string : ends.Point})[k], (b as {string : ends.Point})[k]
		if math.abs(u.x - v.x) + math.abs(u.y - v.y) + math.abs(u.z - v.z) > 1e-3 then return false end
	end
	return M.nodeAlive(a.node0) and M.nodeAlive(a.node1)
end

-- Can a proposal still join end e? A free track end only while it is free, a node end only while
-- track still runs through it, along its heading once aimed: once that changes (or the node is
-- gone) a proposal naming the node is wrong or kills the game. A cut only while its piece and the
-- track running on from it are as they were read. A ground end names no node. (nil: no end,
-- nothing to join.)
function M.joinable(e : ends.End) : boolean
	if e == nil or e.kind == "ground" then return true end
	if e.kind == "split" then
		-- (and the track running on from it: the proposal can name those pieces too, ends.runs)
		if not samePiece(M.piece(e.piece.edge), e.piece) then return false end
		for _, pc in ipairs(e.piece.beyond or {}) do
			if not samePiece(M.piece(pc.edge), pc) then return false end
		end
		return true
	end
	if e.kind ~= "node" then return M.freeEnd(e.node) ~= nil end
	local now = M.nodeEnd(e.node)
	if now == nil then return false end
	-- (the pieces there are named in the proposal, which replaces them: the same ones, as read)
	local was = e.beside or {}
	if #(now.beside or {}) ~= #was then return false end
	for _, pc in ipairs(was) do
		if not samePiece(M.piece(pc.edge), pc) then return false end
	end
	if e.dx == nil then return true end
	for _, d in ipairs(now.dirs) do
		if d.dx * e.dx + d.dy * e.dy > 1 - 1e-6 then return true end
	end
	return false
end

-- The track pieces at a node end's node (a switch replaces them: tg_proposal); none for any
-- other end.
function M.piecesAt(e : ends.End) : {integer}
	if e == nil or e.kind ~= "node" then return {} end
	return segmentsAt(e.node, true)
end

-- Can the joint between track pieces `from` and `to` go, making them one piece (ends.runs)? Only
-- a plain joint: those two pieces and nothing else there, of one kind (ground, bridge or tunnel,
-- and its type) and one track type, and nothing standing on `to` (signals would need moving).
function M.mergeable(joint : integer, from : integer, to : integer) : boolean
	local ok, res = pcall(function() : boolean
		local segs = segmentsAt(joint, true)
		if #segs ~= 2 or #segmentsAt(joint, false) > 0 then return false end
		if not ((segs[1] == from and segs[2] == to) or (segs[1] == to and segs[2] == from)) then return false end
		local a = api.engine.getComponent(from, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		local b = api.engine.getComponent(to, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		if a == nil or b == nil or #(b.objects or {}) > 0 then return false end
		return a.type == b.type and a.typeIndex == b.typeIndex and a.roadTemplate == b.roadTemplate
	end)
	return ok and res == true
end

-- Is e a track piece?
function M.isTrackEdge(e : integer) : boolean
	local ok, res = pcall(function() : boolean
		if e == nil or not api.engine.entityExists(e) then return false end
		local be = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		return be ~= nil and be.roadType == api.type["enum"].RoadType.TRACK
	end)
	return ok and res == true
end

-- The ends (free track ends and node ends) at the nodes of the piece `hovered` and of the track
-- pieces within ends.SNAP of (x, y) (x nil: only the hovered piece's), and the piece to cut
-- (tg_ends.snap): the hovered one when it is a track piece, else the nearest within
-- ends.PIECE_SNAP of (x, y), never edge `skip`.
function M.endsNear(x : number, y : number, hovered : integer, skip ?: integer) : {ends.End}, ends.Piece
	local CT = api.type.ComponentType
	local nodes : {integer : boolean} = {}
	local around : {ends.Piece} = {}
	local function addEdge(e : integer)
		local be = api.engine.getComponent(e, CT.BASE_EDGE) as Engine.Component.BaseEdge
		if be ~= nil and be.roadType == api.type["enum"].RoadType.TRACK then
			nodes[be.node0], nodes[be.node1] = true, true
			around[#around + 1] = M.piece(e)
		end
	end
	local piece = M.piece(hovered)
	if piece ~= nil then nodes[piece.node0], nodes[piece.node1] = true, true end
	if x ~= nil then
		local r = ends.SNAP
		pcall(function()
			local box = api.type.Box3.new(api.type.Vec3f.new(x - r, y - r, -2000), api.type.Vec3f.new(x + r, y + r, 6000))
			api.engine.system.octreeSystem.findIntersectingEntities(box, function(e : Engine.Entity, _bv : Engine.Component.BoundingVolume)
				addEdge(e)
			end)
		end)
		if piece == nil then piece = ends.nearestPiece(around, x, y, skip) end
	end
	if piece ~= nil then piece.beyond = runningOn({ piece }) end
	local out : {ends.End} = {}
	for n in pairs(nodes) do
		local e = M.freeEnd(n) or M.nodeEnd(n)
		if e ~= nil then out[#out + 1] = e end
	end
	return out, piece
end

return M
