-- What the tool reads from the game world: track type facts, the ground and water at a point, and
-- the track ends (is a node still there, the free end at a node, the free ends near a point). It
-- also holds what is known about how asking the game can crash it:
--   - asking the street system about an entity that is not a node crashes the game (no pcall
--     helps), so every node is checked first;
--   - a proposal that names a node that is gone kills the game, so callers check joinable().
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
	templateFor : function(trackId : number, electric : boolean) : string
	-- the ground
	ground : function(x : number, y : number) : number
	water : function(x : number, y : number) : boolean
	-- track ends
	nodeAlive : function(n : integer) : boolean
	freeEnd : function(n : integer) : ends.TrackEnd
	joinable : function(n : integer) : boolean
	isTrackEdge : function(e : integer) : boolean
	endsNear : function(x : number, y : number, hovered : integer) : {ends.TrackEnd}, {integer : boolean}, boolean
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

-- The template to build from the menu's settings: the track type picked (a template id; nil or
-- negative: standard), its wired version (its catenaryAdd) when electric.
function M.templateFor(trackId : number, electric : boolean) : string
	local name = M.BASE_TEMPLATE
	if trackId ~= nil and trackId >= 0 then
		local ok, n = pcall(api.res.streetTemplateRep.getName, math.floor(trackId + 0.5))
		if ok and n ~= nil and n ~= "" then name = n as string end
	end
	if electric then
		local ok, wired = pcall(function() : string return (templateOf(name) as table).catenaryAdd as string end)
		if ok and wired ~= nil and wired ~= "" then name = wired end
	end
	return name
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

-- The free track end at node n (a node with a single track piece and no street), or nil.
function M.freeEnd(n : integer) : ends.TrackEnd
	if n == nil or n < 0 or not M.nodeAlive(n) then return nil end
	local segs = segmentsAt(n, true)
	if #segs ~= 1 or #segmentsAt(n, false) > 0 then return nil end -- (no level crossings)
	local ok, e = pcall(function() : ends.TrackEnd
		local be = api.engine.getComponent(segs[1], api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		local node = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
		if be == nil or node == nil or be.roadType ~= api.type["enum"].RoadType.TRACK then return nil end
		local tx, ty, tz : number, number, number
		if be.node0 == n then
			tx, ty, tz = -be.tangent0.x, -be.tangent0.y, -be.tangent0.z
		else
			tx, ty, tz = be.tangent1.x, be.tangent1.y, be.tangent1.z
		end
		local len = math.sqrt(tx * tx + ty * ty)
		if len < 1e-6 then return nil end
		return { node = n, x = node.position.x, y = node.position.y, z = node.position.z, dx = tx / len, dy = ty / len, grade = tz / len }
	end)
	return ok and e as ends.TrackEnd or nil
end

-- Can a proposal still join node n? Only while it is a free end: once track is built on it (or
-- it is gone) a proposal naming it is wrong or kills the game. (nil or negative: no node.)
function M.joinable(n : integer) : boolean
	return n == nil or n < 0 or M.freeEnd(n) ~= nil
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

-- The free ends of the piece `hovered` and of the track pieces within ends.SNAP of (x, y) (x nil:
-- only the hovered piece's), which of them are the hovered piece's, and whether any track piece
-- was there at all.
function M.endsNear(x : number, y : number, hovered : integer) : {ends.TrackEnd}, {integer : boolean}, boolean
	local CT = api.type.ComponentType
	local nodes : {integer : boolean} = {}
	local onHovered : {integer : boolean} = {}
	local sawTrack = false
	local function addEdge(e : integer, hov : boolean)
		local be = api.engine.getComponent(e, CT.BASE_EDGE) as Engine.Component.BaseEdge
		if be ~= nil and be.roadType == api.type["enum"].RoadType.TRACK then
			sawTrack = true
			nodes[be.node0], nodes[be.node1] = true, true
			if hov then onHovered[be.node0], onHovered[be.node1] = true, true end
		end
	end
	pcall(function()
		if hovered ~= nil and hovered > 0 and api.engine.entityExists(hovered) then addEdge(hovered, true) end
	end)
	if x ~= nil then
		local r = ends.SNAP
		pcall(function()
			local box = api.type.Box3.new(api.type.Vec3f.new(x - r, y - r, -2000), api.type.Vec3f.new(x + r, y + r, 6000))
			api.engine.system.octreeSystem.findIntersectingEntities(box, function(e : Engine.Entity, _bv : Engine.Component.BoundingVolume)
				addEdge(e, false)
			end)
		end)
	end
	local out : {ends.TrackEnd} = {}
	for n in pairs(nodes) do
		local e = M.freeEnd(n)
		if e ~= nil then out[#out + 1] = e end
	end
	return out, onHovered, sawTrack
end

return M
