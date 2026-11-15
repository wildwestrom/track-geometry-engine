-- Turns sampled nodes (tg_alignment) into a proposal: one Hermite track piece between each pair of
-- neighbouring nodes. Used by the tool's ghost, which is also what it builds (GUI).
-- New entities are numbered as the game wants: edges -1..-m, then nodes -(m+1)..-(m+n). The first
-- and last node can be the picked ends' existing nodes instead, which joins the new track to them;
-- those are not added, and their positions must be the nodes' own.

local alignment = require("westrom_track_geometry::/track_geometry/tg_alignment.script.tl")
local ends = require("westrom_track_geometry::/track_geometry/tg_ends.script.tl")

local record Options
	template : string -- track template name (tg_world.templateFor)
	z : {number} -- height at each node
	grades : {number} -- grade at each node, for the tangents' z (z must follow it)
	from : ends.End -- the end at the first sample: the new track joins its node, if it has one
	to : ends.End -- the end at the last sample, likewise; nil: none (a stub)
	kinds : {string} -- each piece "ground", "bridge" or "tunnel" (tg_structures); nil: all ground
	bridgeType : integer -- api.res.bridgeTypeRep id for the bridges (none: they stay on the ground)
	tunnelType : integer -- api.res.tunnelTypeRep id for the tunnels
end

local record ProposalMod
	Options : Options
	finite : function(number) : boolean
	make : function(nodes : {alignment.Sample}, o : Options) : SimpleProposal, string
end

local M : ProposalMod = {}

function M.finite(v : number) : boolean
	return v ~= nil and v == v and v ~= math.huge and v ~= -math.huge
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

	local tplName = o.template
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
		if i == 1 and o.from ~= nil and o.from.node ~= nil then return o.from.node end
		if i == n and o.to ~= nil and o.to.node ~= nil then return o.to.node end
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
