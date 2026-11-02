-- Game script. Smoke test: on the GUI's "tg_smoke" event, build the path through three PIs ahead
-- of the camera with tg_geometry, lay it as Hermite pieces between new nodes (tg_alignment),
-- dry-run it (cost, errors, collisions) and, when asked to and nothing is critical, build it.
-- Bump VERSION, sync, reload, and check the log for the new value.

local geometry = require("westrom_track_geometry::/track_geometry/tg_geometry.script.tl")
local alignment = require("westrom_track_geometry::/track_geometry/tg_alignment.script.tl")

local VERSION = "v6"
local TAG = "[westrom_track_geometry] "
local EVENT_ID = "TrackGeometry"
local EVENTS = { "tg_smoke" }
local STEP = 10.0 -- max piece length (m)
local LEG = 350.0 -- smoke-test leg length (m)
local TURN = math.rad(40) -- smoke-test turn at the middle PI (left)
local BASE_TEMPLATE = "::/infrastructure/track/standard/standard.street_template"

local function say(msg : string)
	print(TAG .. msg)
end

say("game script file loaded " .. VERSION)

local record SmokeParam
	x : number -- start, the camera centre
	y : number
	heading : number -- start heading (radians), the camera's yaw
	build : boolean -- false: dry run only
end

local function terrainZ(x : number, y : number) : number
	return api.engine.terrain.getHeightAt(api.type.Vec2f.new(x, y))
end

local function finite(v : number) : boolean
	return v ~= nil and v == v and v ~= math.huge and v ~= -math.huge
end

local function makeContext() : Context
	local c = api.type.Context.new()
	c.player = api.engine.util.getPlayer()
	c.gatherBuildings = false
	c.gatherFields = true
	return c
end

-- The smoke-test path: PIs at p, LEG metres ahead, and LEG metres further after turning TURN.
local function smokePath(p : SmokeParam) : {geometry.Segment}
	local h1, h2 = p.heading, p.heading + TURN
	local x1, y1 = p.x + LEG * math.cos(h1), p.y + LEG * math.sin(h1)
	local pis = { geometry.vec(p.x, p.y, 0), geometry.vec(x1, y1, 0),
		geometry.vec(x1 + LEG * math.cos(h2), y1 + LEG * math.sin(h2), 0) }
	return geometry.buildPath(pis, geometry.DEFAULT_PARAMS, nil)
end

-- The proposal for the smoke-test path starting at p. Nodes and pieces are all new: edges -1..-m, then
-- nodes -(m+1)..-(m+n). The grade is linear between the terrain heights at the two ends.
local function makeProposal(p : SmokeParam) : SimpleProposal, string
	local nodes = alignment.sample(smokePath(p), STEP)
	local n = #nodes
	if n < 2 then return nil, "the path is too short" end
	local m = n - 1
	local first, last = nodes[1], nodes[n]
	for _, v in ipairs({ last.x, last.y }) do
		if not finite(v) then return nil, "bad end point" end
	end
	if not (api.engine.terrain.isValidCoordinate(api.type.Vec2f.new(first.x, first.y))
		and api.engine.terrain.isValidCoordinate(api.type.Vec2f.new(last.x, last.y))) then
		return nil, "the alignment leaves the map; centre the camera elsewhere"
	end
	local z0, z1 = terrainZ(first.x, first.y), terrainZ(last.x, last.y)
	local slope = (z1 - z0) / last.s
	local z : {number} = {}
	for i, nd in ipairs(nodes) do
		z[i] = z0 + slope * nd.s
		for _, v in ipairs({ nd.x, nd.y, nd.heading, z[i] }) do
			if not finite(v) then return nil, "NaN or infinite value at node " .. i end
		end
		if i > 1 and (nd.x - nodes[i - 1].x) ^ 2 + (nd.y - nodes[i - 1].y) ^ 2 + (z[i] - z[i - 1]) ^ 2 < 0.01 then
			return nil, "zero-length piece before node " .. i
		end
	end

	local tplName = BASE_TEMPLATE
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
	local function nodeId(i : integer) : integer return -(m + i) end
	for i, nd in ipairs(nodes) do
		local ne = api.type.NodeAndEntity.new()
		ne.entity = nodeId(i)
		ne.comp.position = api.type.Vec3f.new(nd.x, nd.y, z[i])
		nodesToAdd[i] = ne
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
		e.comp.tangent0 = api.type.Vec3f.new(math.cos(a.heading) * T, math.sin(a.heading) * T, slope * T)
		e.comp.tangent1 = api.type.Vec3f.new(math.cos(b.heading) * T, math.sin(b.heading) * T, slope * T)
		e.comp.type = api.type["enum"].BaseEdgeType.NORMAL
		e.comp.typeIndex = -1
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
	say(string.format("smoke: %d pieces, %.0f m, %s, from (%.1f, %.1f, %.1f) heading %.1f deg to (%.1f, %.1f, %.1f), grade %.2f%%",
		m, last.s, tplName, first.x, first.y, z0, math.deg(p.heading), last.x, last.y, z1, slope * 100))
	return proposal, nil
end

local function report(what : string, data : ProposalData)
	if data == nil then say(what .. ": no proposal data"); return end
	local es = data.errorState
	say(string.format("%s: cost %s, critical %s", what, tostring(data.costs), tostring(es ~= nil and es.critical)))
	if es ~= nil then
		for _, msg in ipairs(es.messages or {}) do say("  error: " .. msg) end
		for _, msg in ipairs(es.warnings or {}) do say("  warning: " .. msg) end
	end
	local cols = data.collisionInfo ~= nil and data.collisionInfo.collisionEntities or {}
	if #cols > 0 then
		local ids : {string} = {}
		for k, c in ipairs(cols) do
			if k > 10 then ids[#ids + 1] = "..."; break end
			ids[#ids + 1] = tostring(c.entity)
		end
		say(string.format("  %d collision(s): %s", #cols, table.concat(ids, ", ")))
	end
end

local function smoke(p : SmokeParam)
	if p == nil or not (finite(p.x) and finite(p.y) and finite(p.heading)) then
		say("smoke: bad event param")
		return
	end
	local proposal, why = makeProposal(p)
	if proposal == nil then say("smoke: not sent: " .. why); return end
	local ok, res = pcall(api.engine.util.proposal.makeProposalData, proposal as any as Proposal, makeContext())
	if not ok then say("smoke: dry run failed: " .. tostring(res)); return end
	local data = res as ProposalData
	report("smoke dry run", data)
	if not p.build then return end
	if data == nil or (data.errorState ~= nil and data.errorState.critical) then
		say("smoke build: skipped, the dry run has critical errors")
		return
	end
	local cmd = api.cmd.makeWorldBuildProposalCmd(proposal, makeContext(), false, true)
	api.cmd.sendCommand(cmd, function(r : WorldBuildProposalCommandData, success : boolean, changed : {{Engine.Entity, Engine.Revision}})
		say(string.format("smoke build: %s, %d entities changed", success and "built" or "FAILED", changed ~= nil and #changed or -1))
		report("smoke build", r ~= nil and r.resultProposalData or nil)
	end)
end

local updated = false

local script : GameScript<any> = {
	update = function(_userParams : table, state : GameScriptState<any>, _dt : number) : any
		-- every update, as Track Connector does: a module-level "done" flag survives loading
		-- another save in the same Lua state, which would then never get the events
		for _, n in ipairs(EVENTS) do state:subscribeToEvent(n) end
		if not updated then
			updated = true
			say("game script first update " .. VERSION)
		end
		return nil
	end,

	handleEvent = function(_userParams : table, _state : GameScriptState<any>, _src : string, id : string, name : string, param : any) : any
		if id ~= EVENT_ID then return nil end
		if name == "tg_smoke" then
			local ok, err : boolean, any = pcall(smoke, param as SmokeParam)
			if not ok then say("smoke: error: " .. tostring(err)) end
		end
		return nil
	end,
}

return script
