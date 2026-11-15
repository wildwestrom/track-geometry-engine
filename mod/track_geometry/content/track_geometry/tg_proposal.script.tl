-- Turns sampled nodes (tg_alignment) into a proposal: one Hermite track piece between each pair of
-- neighbouring nodes. Used by the tool's ghost, which is also what it builds (GUI).
-- New entities are numbered as the game wants: edges -1..-m, then nodes -(m+1)..-(m+n). The first
-- and last node can be the picked ends' existing nodes instead, which joins the new track to them;
-- those are not added, and their positions must be the nodes' own. A switch (new track joining a
-- node with track through it) also replaces the pieces at that node with copies of themselves,
-- as the game's own builder does (NOTES.md: Switches replace the pieces). A cut (an end
-- partway along a piece) replaces that piece with its two parts, which meet at the new track's end
-- node. Those copies and parts are edges -(m+1)..-(m+k), and the nodes come after them. A copy
-- or part can run on through the track's next joints (o.runs: ends.runs), taking the place of the
-- pieces there; those pieces and joints are removed.

local alignment = require("westrom_track_geometry::/track_geometry/tg_alignment.script.tl")
local ends = require("westrom_track_geometry::/track_geometry/tg_ends.script.tl")

local record Options
	template : string -- track template name (tg_world.templateFor)
	z : {number} -- height at each node
	grades : {number} -- grade at each node, for the tangents' z (z must follow it)
	from : ends.End -- the end at the first sample: the new track joins its node, if it has one
	to : ends.End -- the end at the last sample, likewise; nil: none (a stub)
	kinds : {string} -- each piece "ground", "bridge" or "tunnel" (tg_structures); nil: all ground
	replace : {integer} -- existing pieces at a node end to replace with copies (tg_world.piecesAt)
	runs : {ends.Run} -- existing track merged into the copies and parts at the switches; nil: none
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
	-- (the pieces cut, and the pieces at a node end that are not also cut)
	local cuts : {{ends.Piece, integer}} = {}
	local cutEdge : {integer : boolean} = {}
	for _, c in ipairs({ { o.from, 1 }, { o.to, n } }) do
		local en = c[1] as ends.End
		if en ~= nil and en.kind == "split" then
			cuts[#cuts + 1] = { en.piece, c[2] as integer }
			cutEdge[en.piece.edge] = true
		end
	end
	local replace : {integer} = {}
	for _, old in ipairs(o.replace or {}) do
		if not cutEdge[old] then replace[#replace + 1] = old end
	end
	local k = #replace + 2 * #cuts
	local function nodeId(i : integer) : integer
		if i == 1 and o.from ~= nil and o.from.node ~= nil then return o.from.node end
		if i == n and o.to ~= nil and o.to.node ~= nil then return o.to.node end
		return -(m + k + i)
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
	-- (a copy or part that runs on through the next joints: its far end moves out to the run's)
	local runOf : {string : ends.Run} = {}
	for _, r in ipairs(o.runs or {}) do runOf[r.first.edge .. (r.fromStart and "+" or "-")] = r end
	local function v3(q : ends.Point) : Vec3f return api.type.Vec3f.new(q.x, q.y, q.z) end
	local function extend(comp : Engine.Component.BaseEdge, edge : integer, fromStart : boolean)
		local r = runOf[edge .. (fromStart and "+" or "-")]
		if r == nil then return end
		if fromStart then
			comp.node1, comp.position1 = r.node, v3(r.p)
			comp.tangent0, comp.tangent1 = v3(r.t0), v3(r.t1)
		else
			comp.node0, comp.position0 = r.node, v3(r.p)
			comp.tangent0 = api.type.Vec3f.new(-r.t1.x, -r.t1.y, -r.t1.z)
			comp.tangent1 = api.type.Vec3f.new(-r.t0.x, -r.t0.y, -r.t0.z)
		end
	end
	for j, old in ipairs(replace) do
		local be = api.engine.getComponent(old, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		if be == nil then return nil, "piece " .. old .. " at the switch is gone" end
		-- (signals and other objects on it would need moving too: not yet)
		if #(be.objects or {}) > 0 then return nil, "a piece at the switch carries signals or other objects" end
		local e = api.type.SegmentAndEntity.new()
		e.entity = -(m + j)
		e.type = 1 -- track
		local comp = be:clone()
		extend(comp, old, true)
		extend(comp, old, false)
		e.comp = comp
		local own = api.engine.getComponent(old, api.type.ComponentType.PLAYER_OWNED) as Engine.Component.PlayerOwned
		if own ~= nil then e.playerOwned = own end
		edgesToAdd[m + j] = e
	end
	local removed : {integer} = {}
	for _, old in ipairs(replace) do removed[#removed + 1] = old end
	for c, cut in ipairs(cuts) do
		local pc, at = cut[1] as ends.Piece, cut[2] as integer
		local be = api.engine.getComponent(pc.edge, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		if be == nil then return nil, "the piece to cut (" .. pc.edge .. ") is gone" end
		if #(be.objects or {}) > 0 then return nil, "the piece to cut carries signals or other objects" end
		local own = api.engine.getComponent(pc.edge, api.type.ComponentType.PLAYER_OWNED) as Engine.Component.PlayerOwned
		local o2 = (at == 1 and o.from or o.to) as ends.End
		local a, b = ends.halves(pc, o2.u)
		for h, part in ipairs({ a, b }) do
			local e = api.type.SegmentAndEntity.new()
			e.entity = -(m + #replace + 2 * (c - 1) + h)
			e.type = 1 -- track
			local comp = be:clone()
			comp.node0 = h == 1 and pc.node0 or nodeId(at)
			comp.node1 = h == 1 and nodeId(at) or pc.node1
			comp.position0, comp.tangent0 = v3(part.p0), v3(part.t0)
			comp.position1, comp.tangent1 = v3(part.p1), v3(part.t1)
			extend(comp, pc.edge, h == 2)
			e.comp = comp
			if own ~= nil then e.playerOwned = own end
			edgesToAdd[#edgesToAdd + 1] = e
		end
		removed[#removed + 1] = pc.edge
	end
	local joints : {integer} = {}
	for _, r in ipairs(o.runs or {}) do
		for _, old in ipairs(r.edges) do removed[#removed + 1] = old end
		for _, j in ipairs(r.nodes) do joints[#joints + 1] = j end
	end
	local proposal = api.type.SimpleProposal.new()
	proposal.streetProposal.nodesToAdd = nodesToAdd
	proposal.streetProposal.edgesToAdd = edgesToAdd
	if #removed > 0 then proposal.streetProposal.edgesToRemove = removed end
	if #joints > 0 then proposal.streetProposal.nodesToRemove = joints end
	local held = #proposal.streetProposal.edgesToAdd
	if held ~= m + k then return nil, string.format("the proposal holds %d of %d pieces", held, m + k) end
	return proposal, nil
end

return M
