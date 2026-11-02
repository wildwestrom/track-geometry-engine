-- Turns sampled nodes (tg_alignment) into a proposal: one Hermite track piece between each pair of
-- neighbouring nodes. Used by the tool's ghost, which is also what it builds (GUI).
-- New entities are numbered as the game wants: edges -1..-m, then nodes -(m+1)..-(m+n). The first
-- and last node can be existing track nodes instead (the picked ends), which joins the new track to
-- them; those are not added, and their positions must be the nodes' own.

local alignment = require("westrom_track_geometry::/track_geometry/tg_alignment.script.tl")
local structures = require("westrom_track_geometry::/track_geometry/tg_structures.script.tl")

local record Options
	template : string -- track template name
	z : {number} -- height at each node
	grades : {number} -- grade at each node, for the tangents' z (z must follow it)
	startNode : integer -- existing node at the first sample, or nil
	endNode : integer -- existing node at the last sample, or nil
	kinds : {string} -- each piece "ground", "bridge" or "tunnel" (tg_structures); nil: all ground
	bridgeType : integer -- api.res.bridgeTypeRep id for the bridges (none: they stay on the ground)
	tunnelType : integer -- api.res.tunnelTypeRep id for the tunnels
end

local record ProposalMod
	Options : Options
	BASE_TEMPLATE : string
	finite : function(number) : boolean
	make : function(nodes : {alignment.Sample}, o : Options) : SimpleProposal, string
	trackSpeed : function(template : string) : number
	maxGrade : function(template : string) : number
	structureTypes : function(template : string) : integer, integer
	ground : function(x : number, y : number) : number
	water : function(x : number, y : number) : boolean
	structuresFor : function(nodes : {alignment.Sample}, z : {number}, template : string) : {string}, integer, integer, string
end

local M : ProposalMod = {}

M.BASE_TEMPLATE = "::/infrastructure/track/standard/standard.street_template"

function M.finite(v : number) : boolean
	return v ~= nil and v == v and v ~= math.huge and v ~= -math.huge
end

-- The bridge and tunnel types for a track template, as the game's menu would auto-select them: on
-- offer this year, carrying rail, the speed limit closest above the track's (else the fastest).
-- Either can be nil when none is on offer.
local function offers(rep : ResTypeRep<integer, BridgeType>, year : integer) : {structures.Offer}
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
		if rail and menu ~= nil and #menu.categories > 0 and (from == 0 or from <= year) and (to == 0 or year < to) then
			list[#list + 1] = { id = id, speedLimit = (r.speedLimit as number) or 0,
				autoSelectable = r.isAutoSelectable == nil or r.isAutoSelectable as boolean }
		end
	end
	return list
end

-- The track's top speed (m/s): the fastest of its lanes.
function M.trackSpeed(template : string) : number
	local tpl = api.res.streetTemplateRep.get(api.res.streetTemplateRep.find(template or M.BASE_TEMPLATE))
	local speed = 0.0
	for _, lc in ipairs(tpl.laneConfigs or {}) do speed = math.max(speed, lc.speed) end
	return speed
end

-- The steepest grade the track may be laid at: the template's maxSlopeBuild (the limit of the
-- game's own incline slider; grade mods such as Realistic Track Gradients set it). The game's
-- default when it is missing.
function M.maxGrade(template : string) : number
	local tpl = api.res.streetTemplateRep.get(api.res.streetTemplateRep.find(template or M.BASE_TEMPLATE))
	local v = (tpl as {string : any}).maxSlopeBuild as number
	if v == nil or not (v > 0) then return 0.085 end
	return v
end

function M.structureTypes(template : string) : integer, integer
	local speed = M.trackSpeed(template)
	local year = 0
	pcall(function() year = ((api.engine.util as {string : any}).getYear as function() : integer)() end)
	return structures.pickType(offers(api.res.bridgeTypeRep, year), speed),
		structures.pickType(offers(api.res.tunnelTypeRep, year), speed)
end

function M.ground(x : number, y : number) : number
	return api.engine.terrain.getHeightAt(api.type.Vec2f.new(x, y))
end

function M.water(x : number, y : number) : boolean
	return api.engine.terrain.isOnWater(api.type.Vec2f.new(x, y))
end

-- Where the track at heights z needs bridges and tunnels, the types to build them with, and a
-- summary for the player ("1 bridge (300 m)", or nil).
function M.structuresFor(nodes : {alignment.Sample}, z : {number}, template : string) : {string}, integer, integer, string
	local kinds = structures.classify(nodes, z, M.ground, M.water, structures.DEFAULT)
	local bridgeType, tunnelType = M.structureTypes(template)
	return kinds, bridgeType, tunnelType, structures.summary(nodes, kinds)
end

-- The proposal, or nil and why not. Checks for what crashes the game: NaN, pieces under 0.1 m.
function M.make(nodes : {alignment.Sample}, o : Options) : SimpleProposal, string
	local n = #nodes
	if n < 2 then return nil, "the path is too short" end
	local m = n - 1
	local z = o.z
	for i, nd in ipairs(nodes) do
		for _, v in ipairs({ nd.x, nd.y, nd.heading, z[i], o.grades[i] }) do
			if not M.finite(v) then return nil, "NaN or infinite value at node " .. i end
		end
		if i > 1 and (nd.x - nodes[i - 1].x) ^ 2 + (nd.y - nodes[i - 1].y) ^ 2 + (z[i] - z[i - 1]) ^ 2 < 0.01 then
			return nil, "zero-length piece before node " .. i
		end
	end

	local tplName = o.template or M.BASE_TEMPLATE
	local template = api.res.streetTemplateRep.get(api.res.streetTemplateRep.find(tplName))
	local trackDistance = 0.0
	pcall(function() trackDistance = (template as {string : any}).trackDistance as number or 0.0 end)
	local owned : Engine.Component.PlayerOwned = nil
	pcall(function()
		owned = ((api.type as {string : any})["PlayerOwned"] as {string : function() : Engine.Component.PlayerOwned}).new()
		owned.player = api.engine.util.getPlayer()
	end)

	-- Fill plain tables and assign them whole: reading a list field off the native proposal gives
	-- a copy, so writing proposal.streetProposal.nodesToAdd[i] is lost and the proposal stays empty.
	local nodesToAdd : {Proposal.NodeAndEntity} = {}
	local edgesToAdd : {Proposal.SegmentAndEntity} = {}
	local function nodeId(i : integer) : integer
		if i == 1 and o.startNode ~= nil then return o.startNode end
		if i == n and o.endNode ~= nil then return o.endNode end
		return -(m + i)
	end
	for i, nd in ipairs(nodes) do
		local id = nodeId(i)
		if id < 0 then
			local ne = api.type.NodeAndEntity.new()
			ne.entity = id
			ne.comp.position = api.type.Vec3f.new(nd.x, nd.y, z[i])
			nodesToAdd[#nodesToAdd + 1] = ne
		end
	end
	for i = 1, m do
		local a, b = nodes[i], nodes[i + 1]
		local T = alignment.tangentLength(a, b)
		local e = api.type.SegmentAndEntity.new()
		e.entity = -i
		e.type = 1 -- track
		e.comp.node0 = nodeId(i)
		e.comp.node1 = nodeId(i + 1)
		e.comp.position0 = api.type.Vec3f.new(a.x, a.y, z[i])
		e.comp.position1 = api.type.Vec3f.new(b.x, b.y, z[i + 1])
		e.comp.tangent0 = api.type.Vec3f.new(math.cos(a.heading) * T, math.sin(a.heading) * T, o.grades[i] * T)
		e.comp.tangent1 = api.type.Vec3f.new(math.cos(b.heading) * T, math.sin(b.heading) * T, o.grades[i + 1] * T)
		local kind = o.kinds ~= nil and o.kinds[i] or "ground"
		if kind == "bridge" and o.bridgeType ~= nil then
			e.comp.type = api.type["enum"].BaseEdgeType.BRIDGE
			e.comp.typeIndex = o.bridgeType
		elseif kind == "tunnel" and o.tunnelType ~= nil then
			e.comp.type = api.type["enum"].BaseEdgeType.TUNNEL
			e.comp.typeIndex = o.tunnelType
		else
			e.comp.type = api.type["enum"].BaseEdgeType.NORMAL
			e.comp.typeIndex = -1
		end
		e.comp.laneConfigs = template.laneConfigs
		e.comp.roadTemplate = tplName
		e.comp.roadStyle = template.streetStyle
		e.comp.roadType = api.type["enum"].RoadType.TRACK
		e.comp.distance = trackDistance
		if owned ~= nil then e.playerOwned = owned end
		edgesToAdd[i] = e
	end
	local proposal = api.type.SimpleProposal.new()
	proposal.streetProposal.nodesToAdd = nodesToAdd
	proposal.streetProposal.edgesToAdd = edgesToAdd
	local held = #proposal.streetProposal.edgesToAdd
	if held ~= m then return nil, string.format("the proposal holds %d of %d pieces", held, m) end
	return proposal, nil
end

return M
