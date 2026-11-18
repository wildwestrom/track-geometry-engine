-- Turns sampled nodes (tg_alignment) into a proposal: one Hermite track piece between each pair of
-- neighbouring nodes. Used by the tool's ghost, which is also what it builds (GUI).
-- New entities are numbered as the game wants: edges -1..-m, then nodes -(m+1)..-(m+n). The first
-- and last node can be the picked ends' existing nodes instead, which joins the new track to them;
-- those are not added, and their positions must be the nodes' own. A switch (new track joining a
-- node with track through it) also replaces the pieces at that node with copies of themselves,
-- as the game's own builder does (NOTES.md: Switches replace the pieces). A cut (an end
-- partway along a piece) replaces that piece with its two parts, which meet at the new track's end
-- node. Those copies and parts come after the track's own edges, and the nodes after all the edges. A copy
-- or part can run on through the track's next joints (o.runs: ends.runs), taking the place of the
-- pieces there; those pieces and joints are removed.
-- A level crossing (o.streets: tg_crossings) is a new node shared by the street and the track: the
-- plan piece is laid as its parts between the crossings on it, the street piece is replaced by its
-- parts, which keep its settings and owner and ramp to the track's height at the crossing, and the
-- lane rules at the street's nodes are carried over to its parts there (a rule naming a removed
-- piece kills the game, NOTES.md). A road taken as one across a joint (tg_crossings.merge) replaces
-- both its pieces, and its joint goes, the joint's lane rules with it. The street's parts come
-- after the copies and cut parts. Existing track crossed (a Street with track set) is cut the same
-- way, into track parts, and its node is a diamond crossing, no level crossing; a piece the ends
-- already replace, cut or run on through is not crossed as well.
-- make also says which plan piece each new edge belongs to (pieceOf: edge id -> piece 1..m); the
-- copies and parts and the street's parts belong to none. And the crossings it found, each with
-- why it is not cut, if it is not.

local alignment = require("track_geometry_tool::/track_geometry/tg_alignment.script.tl")
local ends = require("track_geometry_tool::/track_geometry/tg_ends.script.tl")
local crossings = require("track_geometry_tool::/track_geometry/tg_crossings.script.tl")
local timing = require("track_geometry_tool::/track_geometry/tg_timing.script.tl")

local record Options
	template : string -- track template name (the picked track entry)
	z : {number} -- height at each node
	grades : {number} -- grade at each node, for the tangents' z (z must follow it)
	from : ends.End -- the end at the first sample: the new track joins its node, if it has one
	to : ends.End -- the end at the last sample, likewise
	kinds : {string} -- each piece "ground", "bridge" or "tunnel" (tg_structures); nil: all ground
	replace : {integer} -- existing pieces at a node end to replace with copies (tg_world.piecesAt)
	runs : {ends.Run} -- existing track merged into the copies and parts at the switches; nil: none
	bridgeType : integer -- api.res.bridgeTypeRep id for the bridges (none: they stay on the ground)
	tunnelType : integer -- api.res.tunnelTypeRep id for the tunnels
	streets : {crossings.Street} -- existing street and track edges near the track, for level and diamond crossings; nil: none
	crossingType : integer -- api.res.railroadCrossingTypeRep id for the level crossings (nil: the game's)
end

local record ProposalMod
	make : function(nodes : {alignment.Sample}, o : Options) : SimpleProposal, {integer : integer}, string, {crossings.Crossing}
	gathering : function(p : SimpleProposal) : SimpleProposal
	footprint : function(nodes : {alignment.Sample}, kinds : {string}, step : number) : {{number}}
	allHouses : function(check : function({integer}) : ProposalData, constructionOf : function(integer) : integer, maxChecks : integer) : {integer}, integer
	onFootprint : function(points : {{number}}, boxes : {integer : {number}}, halfWidth : number) : {integer}
	toClear : function(data : ProposalData, constructionOf : function(integer) : integer, cleared : {integer}) : {integer}, integer, integer
end

local M : ProposalMod = {}

-- Level crossings closer than this to each other on one piece or one street are not both cut (m):
-- the game refuses a piece between them this short (tg_crossings, NOTES.md).
local MIN_APART = 7.0
-- ...unless both are diamond crossings (m): the track piece between them may be as short as double
-- track is wide (5 m), as when the game's own builder crosses it; 3.2 to 3.8 m refused (at level
-- crossings, NOTES.md).
local MIN_APART_DIAMONDS = 4.5

local function finite(v : number) : boolean
	return v ~= nil and v == v and v ~= math.huge and v ~= -math.huge
end

-- A new track piece for the proposal: its entity id, its component (nil: the new one's), its owner.
local function segment(id : integer, comp : Engine.Component.BaseEdge, own : Engine.Component.PlayerOwned) : Proposal.SegmentAndEntity
	local e = api.type.SegmentAndEntity.new()
	e.entity, e.type = id, 1 -- track
	if comp ~= nil then e.comp = comp end
	if own ~= nil then e.playerOwned = own end
	return e
end

-- The existing piece `edge` (`what`) to replace and its owner, or nil and why it can't be.
local function existing(edge : integer, what : string) : Engine.Component.BaseEdge, Engine.Component.PlayerOwned, string
	local be = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	if be == nil then return nil, nil, what .. " (" .. edge .. ") is gone" end
	-- (signals and other objects on it would need moving too: not yet)
	if #(be.objects or {}) > 0 then return nil, nil, what .. " carries signals or other objects" end
	return be, api.engine.getComponent(edge, api.type.ComponentType.PLAYER_OWNED) as Engine.Component.PlayerOwned, nil
end

-- The proposal and the plan piece of each new edge, or nil and why not. Checks for what crashes
-- the game: NaN, pieces under 0.1 m.
function M.make(nodes : {alignment.Sample}, o : Options) : SimpleProposal, {integer : integer}, string, {crossings.Crossing}
	local n = #nodes
	if n < 2 then return nil, nil, "the path is too short" end
	local m = n - 1
	local z = o.z
	for i, nd in ipairs(nodes) do
		for _, v in ipairs({ nd.x, nd.y, nd.heading, z[i], o.grades[i] }) do
			if not finite(v) then return nil, nil, "NaN or infinite value at node " .. i end
		end
		if i > 1 and (nd.x - nodes[i - 1].x) ^ 2 + (nd.y - nodes[i - 1].y) ^ 2 + (z[i] - z[i - 1]) ^ 2 < 0.01 then
			return nil, nil, "zero-length piece before node " .. i
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
	local pieceOf : {integer : integer} = {}
	-- (the pieces cut, and the pieces at a node end that are not also cut)
	local cuts : {integer} = {} -- (the node each is cut at: 1 or n)
	local cutEdge : {integer : boolean} = {}
	for _, at in ipairs({ 1, n }) do
		local en : ends.End = nil; if at == 1 then en = o.from else en = o.to end -- (not "and/or": from may be nil)
		if en ~= nil and en.kind == "split" then
			cuts[#cuts + 1] = at
			cutEdge[en.piece.edge] = true
		end
	end
	local replace : {integer} = {}
	for _, old in ipairs(o.replace or {}) do
		if not cutEdge[old] then replace[#replace + 1] = old end
	end
	-- (the existing pieces the ends already take: not crossed as well)
	local atEnds : {integer : boolean} = {}
	for e in pairs(cutEdge) do atEnds[e] = true end
	for _, e in ipairs(replace) do atEnds[e] = true end
	for _, r in ipairs(o.runs or {}) do
		for _, e in ipairs(r.edges) do atEnds[e] = true end
	end
	local streets : {crossings.Street} = {}
	for _, st in ipairs(o.streets or {}) do
		local free = true
		for _, e in ipairs(st.pieces or { st.edge }) do free = free and not atEnds[e] end
		if free then streets[#streets + 1] = st end
	end
	-- (plan piece i as the Hermite laid for it)
	local function hermite(i : integer) : ends.Piece
		local a, b = nodes[i], nodes[i + 1]
		local T = alignment.tangentLength(a, b)
		return { edge = -i, p0 = { x = a.x, y = a.y, z = z[i] }, p1 = { x = b.x, y = b.y, z = z[i + 1] },
			t0 = { x = math.cos(a.heading) * T, y = math.sin(a.heading) * T, z = o.grades[i] * T },
			t1 = { x = math.cos(b.heading) * T, y = math.sin(b.heading) * T, z = o.grades[i + 1] * T } }
	end
	-- (the level crossings: those cut are level[j], each on one plan piece and one street)
	local found, level : {crossings.Crossing}, {crossings.Crossing} = {}, {}
	local onPiece : {integer : {integer}} = {} -- plan piece -> its crossings (j), along it
	local onStreet : {integer : {integer}} = {} -- street edge -> its crossings (j)
	local crossed : {crossings.Street} = {}
	local claimed : {integer : crossings.Street} = {} -- street piece -> the street cut there
	-- (is any of street st's pieces cut as part of another street? one across a joint, say)
	local function taken(st : crossings.Street) : boolean
		for _, e in ipairs(st.pieces or { st.edge }) do
			local by = claimed[e]
			if by ~= nil and (by.edge ~= st.edge or by.joint ~= st.joint) then return true end
		end
		return false
	end
	local function apart(list : {integer}, c : crossings.Crossing) : boolean
		for _, j in ipairs(list or {}) do
			local min = (c.street.track and level[j].street.track) and MIN_APART_DIAMONDS or MIN_APART
			if math.sqrt((level[j].x - c.x) ^ 2 + (level[j].y - c.y) ^ 2) < min then return false end
		end
		return true
	end
	-- (the job making the ghost gives the frame back between pieces: tg_timing)
	for i = 1, m do
		timing.slice()
		if #streets > 0 and (o.kinds == nil or (o.kinds[i] or "ground") == "ground") then
			for _, c in ipairs(crossings.find(hermite(i), streets)) do
				found[#found + 1] = c
				local e = c.street.edge
				if c.why == nil and (taken(c.street) or not (apart(onPiece[i], c) and apart(onStreet[e], c))) then c.why = "it is too near another crossing" end
				if c.why == nil then
					for _, pe in ipairs(c.street.pieces or { e }) do claimed[pe] = c.street end
					level[#level + 1] = c
					onPiece[i] = onPiece[i] or {}
					table.insert(onPiece[i], #level)
					if onStreet[e] == nil then onStreet[e], crossed[#crossed + 1] = {}, c.street end
					table.insert(onStreet[e], #level)
				end
			end
		end
	end
	local streetParts = 0
	for _, st in ipairs(crossed) do
		table.sort(onStreet[st.edge], function(a : integer, b : integer) : boolean return level[a].v < level[b].v end)
		streetParts = streetParts + #onStreet[st.edge] + 1
	end
	local trackEdges = m + #level -- (each crossing cuts a plan piece once more)
	local k = #replace + 2 * #cuts
	local allEdges = trackEdges + k + streetParts
	local function nodeId(i : integer) : integer
		if i == 1 and o.from ~= nil and o.from.node ~= nil then return o.from.node end
		if i == n and o.to ~= nil and o.to.node ~= nil then return o.to.node end
		return -(allEdges + i)
	end
	local function crossNode(j : integer) : integer return -(allEdges + n + j) end
	for i, nd in ipairs(nodes) do
		local id = nodeId(i)
		if id < 0 then
			local ne = api.type.NodeAndEntity.new()
			ne.entity = id
			ne.comp.position = api.type.Vec3f.new(nd.x, nd.y, z[i])
			nodesToAdd[#nodesToAdd + 1] = ne
		end
	end
	for j, c in ipairs(level) do
		local ne = api.type.NodeAndEntity.new()
		ne.entity = crossNode(j)
		ne.comp.position = api.type.Vec3f.new(c.x, c.y, c.z)
		nodesToAdd[#nodesToAdd + 1] = ne
	end
	local function v3(q : ends.Point) : Vec3f return api.type.Vec3f.new(q.x, q.y, q.z) end
	for i = 1, m do
		timing.slice()
		local js = onPiece[i] or {}
		local us : {number} = {}
		for _, j in ipairs(js) do us[#us + 1] = level[j].u end
		for h, part in ipairs(crossings.parts(hermite(i), us)) do
			local e = segment(-(#edgesToAdd + 1), nil, owned)
			e.comp.node0 = h == 1 and nodeId(i) or crossNode(js[h - 1])
			e.comp.node1 = h == #js + 1 and nodeId(i + 1) or crossNode(js[h])
			e.comp.position0, e.comp.tangent0 = v3(part.p0), v3(part.t0)
			e.comp.position1, e.comp.tangent1 = v3(part.p1), v3(part.t1)
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
			edgesToAdd[#edgesToAdd + 1] = e
			pieceOf[e.entity] = i
		end
	end
	-- (a copy or part that runs on through the next joints: its far end moves out to the run's)
	local runOf : {string : ends.Run} = {}
	for _, r in ipairs(o.runs or {}) do runOf[r.first.edge .. (r.fromStart and "+" or "-")] = r end
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
		local be, own, why = existing(old, "a piece at the switch")
		if be == nil then return nil, nil, why end
		local comp = be:clone()
		extend(comp, old, true)
		extend(comp, old, false)
		edgesToAdd[trackEdges + j] = segment(-(trackEdges + j), comp, own)
	end
	local removed : {integer} = {}
	for _, old in ipairs(replace) do removed[#removed + 1] = old end
	for c, at in ipairs(cuts) do
		local en : ends.End = nil; if at == 1 then en = o.from else en = o.to end -- (not "and/or": from may be nil)
		local pc = en.piece
		local be, own, why = existing(pc.edge, "the piece to cut")
		if be == nil then return nil, nil, why end
		local a, b = ends.halves(pc, en.u)
		for h, part in ipairs({ a, b }) do
			local comp = be:clone()
			comp.node0 = h == 1 and pc.node0 or nodeId(at)
			comp.node1 = h == 1 and nodeId(at) or pc.node1
			comp.position0, comp.tangent0 = v3(part.p0), v3(part.t0)
			comp.position1, comp.tangent1 = v3(part.p1), v3(part.t1)
			extend(comp, pc.edge, h == 2)
			edgesToAdd[#edgesToAdd + 1] = segment(-(trackEdges + #replace + 2 * (c - 1) + h), comp, own)
		end
		removed[#removed + 1] = pc.edge
	end
	-- the crossed streets' parts, and what names the street pieces at their nodes
	local remap : {integer : {integer : integer}} = {} -- street node -> old piece -> its part there
	local joints : {integer} = {} -- nodes that go: the joints of runs and of roads taken as one
	local crossingTypeAt : {integer : integer} = {} -- level crossings: node -> type
	for j, c in ipairs(level) do
		if not c.street.track then crossingTypeAt[crossNode(j)] = o.crossingType end
	end
	for _, st in ipairs(crossed) do
		timing.slice()
		local be, own, why = existing(st.edge, st.track and "a track to cross" or "a street to cross")
		if be == nil then return nil, nil, why, found end
		for _, e in ipairs(st.pieces or {}) do
			local ok, _, whyGone = existing(e, st.track and "a track to cross" or "a street to cross")
			if ok == nil then return nil, nil, whyGone, found end
		end
		local settings : Engine.Component.BaseEdgeStreet = nil
		if not st.track then settings = api.engine.getComponent(st.edge, api.type.ComponentType.BASE_EDGE_STREET) as Engine.Component.BaseEdgeStreet end
		local js = onStreet[st.edge]
		local vs : {number} = {}
		for _, j in ipairs(js) do vs[#vs + 1] = level[j].v end
		local parts = crossings.parts(crossings.asPiece(st), vs)
		local first, last : integer, integer
		-- (taken as one across a joint: the end parts keep the precedence each piece had at its far node)
		local function precedence(edge : integer, node : integer) : PrecedencePreference
			local pb = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
			local ps = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE_STREET) as Engine.Component.BaseEdgeStreet
			if pb == nil or ps == nil then return nil end
			return pb.node0 == node and ps.precedenceNode0 or ps.precedenceNode1
		end
		for h, part in ipairs(parts) do
			local comp = be:clone()
			comp.node0 = h == 1 and st.node0 or crossNode(js[h - 1])
			comp.node1 = h == #parts and st.node1 or crossNode(js[h])
			-- (at a crossing, the track's height: the part ramps to it from its far end)
			local p0, p1 = v3(part.p0), v3(part.p1)
			if h > 1 then p0.z = level[js[h - 1]].z end
			if h < #parts then p1.z = level[js[h]].z end
			comp.position0, comp.tangent0 = p0, v3(part.t0)
			comp.position1, comp.tangent1 = p1, v3(part.t1)
			local se : Proposal.SegmentAndEntity
			if st.track then
				se = segment(-(#edgesToAdd + 1), comp, nil)
			else
				se = api.type.SegmentAndEntity.new()
				se.entity, se.type, se.comp = -(#edgesToAdd + 1), 0, comp -- street
				if settings ~= nil then se.streetEdge = settings end
			end
			-- (the game's component is read-only, the segment's copy of it is not, as Parallel Tracks writes it)
			if settings ~= nil and st.joint ~= nil and h == 1 then se.streetEdge.precedenceNode0 = precedence(st.edge0, st.node0) or settings.precedenceNode0 end
			if settings ~= nil and st.joint ~= nil and h == #parts then se.streetEdge.precedenceNode1 = precedence(st.edge1, st.node1) or settings.precedenceNode1 end
			if own ~= nil then se.playerOwned = own end
			edgesToAdd[#edgesToAdd + 1] = se
			if h == 1 then first = se.entity end
			last = se.entity
		end
		remap[st.node0] = remap[st.node0] or {}
		remap[st.node0][st.edge0 or st.edge] = first
		remap[st.node1] = remap[st.node1] or {}
		remap[st.node1][st.edge1 or st.edge] = last
		-- (a level crossing already at its node names the piece too: made again, of its own type)
		if st.crossing0 ~= nil then crossingTypeAt[st.node0] = st.crossing0 end
		if st.crossing1 ~= nil then crossingTypeAt[st.node1] = st.crossing1 end
		for _, e in ipairs(st.pieces or { st.edge }) do removed[#removed + 1] = e end
		-- (its lane rules go with it: removing them as well trips the game, as Move It found)
		if st.joint ~= nil then joints[#joints + 1] = st.joint end
	end
	local configsGone : {integer} = {}
	local configs : {Proposal.BaseNodeLaneConnectionAndEntity} = {}
	local remapped : {integer} = {}
	for node in pairs(remap) do remapped[#remapped + 1] = node end
	table.sort(remapped)
	for _, node in ipairs(remapped) do
		local map = remap[node]
		local cfg = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE_CONFIG) as Engine.Component.BaseNodeConfig
		if cfg ~= nil then
			local conns : {LaneConnection} = {}
			for _, lc in ipairs(cfg.laneConnections or {}) do
				lc.segment0, lc.segment1 = map[lc.segment0] or lc.segment0, map[lc.segment1] or lc.segment1
				conns[#conns + 1] = lc
			end
			local walks : {Engine.Entity} = {}
			for _, w in ipairs(cfg.crosswalks or {}) do walks[#walks + 1] = map[w] or w end
			-- (the component read from the game is read-only: the lists are set on the proposal's)
			local ae = api.type.BaseNodeLaneConnectionAndEntity.new()
			ae.entity = node
			ae.comp = cfg
			ae.comp.laneConnections = conns
			ae.comp.crosswalks = walks
			configsGone[#configsGone + 1] = node
			configs[#configs + 1] = ae
		end
	end
	for _, r in ipairs(o.runs or {}) do
		for _, old in ipairs(r.edges) do removed[#removed + 1] = old end
		for _, j in ipairs(r.nodes) do joints[#joints + 1] = j end
	end
	timing.slice()
	local proposal = api.type.SimpleProposal.new()
	proposal.streetProposal.nodesToAdd = nodesToAdd
	proposal.streetProposal.edgesToAdd = edgesToAdd
	if #removed > 0 then proposal.streetProposal.edgesToRemove = removed end
	if #joints > 0 then proposal.streetProposal.nodesToRemove = joints end
	if #configs > 0 then
		proposal.streetProposal.nodeConfigsToRemove = configsGone
		proposal.streetProposal.nodeConfigsToAdd = configs
	end
	if next(crossingTypeAt) ~= nil then proposal.streetProposal.node2rcType = crossingTypeAt end
	-- every plan piece, with the edges the map gives it, and the k copies and parts
	local mapped, others = {} as {integer : integer}, 0
	for _, i in pairs(pieceOf) do mapped[i] = (mapped[i] or 0) + 1 end
	local edgeCount : {integer : integer} = {}
	for _, e in ipairs(edgesToAdd) do
		local i = pieceOf[e.entity]
		if i ~= nil then edgeCount[i] = (edgeCount[i] or 0) + 1 else others = others + 1 end
	end
	local pieces = 0
	for i = 1, m do
		if (mapped[i] or 0) > 0 and edgeCount[i] == mapped[i] then pieces = pieces + 1 end
	end
	if pieces ~= m or others ~= k + streetParts then
		return nil, nil, string.format("the proposal holds %d of %d pieces and %d of %d copies and street parts", pieces, m, others, k + streetParts), found
	end
	-- (read back: a list the game did not take leaves the proposal short)
	local held = #proposal.streetProposal.edgesToAdd
	if held ~= #edgesToAdd then return nil, nil, string.format("the proposal holds %d of %d edges", held, #edgesToAdd), found end
	return proposal, pieceOf, nil, found
end

-- The constructions to remove so the proposal can run through the town buildings in its way, how
-- many of them are new, and how many other things it runs into: those already `cleared`, then each further house's, once, from a
-- check's collisions and the buildings it gathered. A check lists only some of the houses in the
-- way, and the next check of the proposal with those cleared lists more (NOTES.md, Town buildings
-- in the way), so this is asked again after each check. constructionOf gives a town building's
-- construction and nil for anything else, which stays in the way: only what the game's own builder
-- removes goes (fields it removes itself, with Context.gatherFields).
function M.toClear(data : ProposalData, constructionOf : function(integer) : integer, cleared : {integer}) : {integer}, integer, integer
	local out, seen, new, others = {} as {integer}, {} as {integer : boolean}, 0, 0
	local other : {integer : boolean} = {}
	for _, con in ipairs(cleared or {}) do
		if not seen[con] then seen[con], out[#out + 1] = true, con end
	end
	local ci = data ~= nil and data.collisionInfo or nil
	if ci == nil then return out, 0, 0 end
	local function add(e : integer)
		if e == nil or e < 0 then return end
		local con = constructionOf(e)
		if con == nil then
			if not other[e] then other[e], others = true, others + 1 end
		elseif not seen[con] then seen[con], out[#out + 1], new = true, con, new + 1 end
	end
	for _, ed in ipairs(ci.collisionEntities or {}) do add(ed.entity) end
	local collided = others
	for _, e in ipairs(ci.buildingEntities or {}) do add(e) end
	return out, new, collided
end

-- What is built for proposal p: the same track, in a new proposal that removes no constructions
-- itself; the game gathers the town buildings in the way (Context.gatherBuildings), as its own
-- builder does. A build that names several houses in constructionsToRemove kills the game
-- (NOTES.md), while the ghost needs them there to show no collisions. nil if the copy came out short.
function M.gathering(p : SimpleProposal) : SimpleProposal
	local q = api.type.SimpleProposal.new()
	-- (a field read off a native proposal is a copy: each list is assigned whole, through q itself)
	local from = p.streetProposal
	q.streetProposal.nodesToAdd = from.nodesToAdd
	q.streetProposal.edgesToAdd = from.edgesToAdd
	if #(from.edgesToRemove or {}) > 0 then q.streetProposal.edgesToRemove = from.edgesToRemove end
	if #(from.nodesToRemove or {}) > 0 then q.streetProposal.nodesToRemove = from.nodesToRemove end
	if #(from.nodeConfigsToAdd or {}) > 0 then q.streetProposal.nodeConfigsToAdd = from.nodeConfigsToAdd end
	if #(from.nodeConfigsToRemove or {}) > 0 then q.streetProposal.nodeConfigsToRemove = from.nodeConfigsToRemove end
	if from.node2rcType ~= nil and next(from.node2rcType) ~= nil then q.streetProposal.node2rcType = from.node2rcType end
	-- (read back: a list the game did not take leaves the copy short)
	if #q.streetProposal.edgesToAdd ~= #from.edgesToAdd then return nil end
	return q
end

-- Points (x, y) at most `step` apart along the pieces between the nodes, as the game builds them
-- (the Hermites make() lays), on the ground only: kinds as in Options (nil: all ground); a bridge
-- passes over what is below it and a tunnel under. With onFootprint, they find the town buildings
-- in the track's way before the game's check names them (it names only some at a time).
function M.footprint(nodes : {alignment.Sample}, kinds : {string}, step : number) : {{number}}
	local out : {{number}} = {}
	for i = 1, #nodes - 1 do
		if kinds == nil or (kinds[i] or "ground") == "ground" then
			local a, b = nodes[i], nodes[i + 1]
			local T = alignment.tangentLength(a, b)
			local ax, ay = math.cos(a.heading) * T, math.sin(a.heading) * T
			local bx, by = math.cos(b.heading) * T, math.sin(b.heading) * T
			local chord = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
			-- (a Hermite is no longer than its chord plus its tangents: enough points)
			local n = math.max(1, math.ceil(math.max(chord, T) * 1.6 / step))
			for j = 0, n do
				local u = j / n
				local u2, u3 = u * u, u * u * u
				local h00, h10, h01, h11 = 2 * u3 - 3 * u2 + 1, u3 - 2 * u2 + u, -2 * u3 + 3 * u2, u3 - u2
				out[#out + 1] = { h00 * a.x + h10 * ax + h01 * b.x + h11 * bx, h00 * a.y + h10 * ay + h01 * b.y + h11 * by }
			end
		end
	end
	return out
end

-- The ids of the boxes ({minX, minY, maxX, maxY}, by id) that come within halfWidth of a point.
function M.onFootprint(points : {{number}}, boxes : {integer : {number}}, halfWidth : number) : {integer}
	local out : {integer} = {}
	for id, b in pairs(boxes) do
		for _, q in ipairs(points) do
			if q[1] >= b[1] - halfWidth and q[1] <= b[3] + halfWidth and q[2] >= b[2] - halfWidth and q[2] <= b[4] + halfWidth then
				out[#out + 1] = id
				break
			end
		end
	end
	return out
end

-- The constructions of every town building in the proposal's way, and how many checks found them.
-- check(A) is the game's check of the proposal removing A itself (a dry run without
-- Context.gatherBuildings, nil if there is none), which names only some of the houses still in the
-- way (NOTES.md), so it is asked again with those removed too, until it names none new, at most
-- maxChecks times. constructionOf as in toClear. check may yield (the GUI runs this as a coroutine,
-- a check a tool tick).
function M.allHouses(check : function({integer}) : ProposalData, constructionOf : function(integer) : integer, maxChecks : integer) : {integer}, integer
	local found : {integer} = {}
	local checks = 0
	while checks < maxChecks do
		checks = checks + 1
		local data = check(found)
		if data == nil then break end
		local more, new = M.toClear(data, constructionOf, found)
		if new == 0 then break end
		found = more
	end
	return found, checks
end

return M
