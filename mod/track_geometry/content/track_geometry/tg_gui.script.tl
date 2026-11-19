-- GUI. Three parts:
--   the tool (toolAction): the Track Geometry tool, in the drag builder's place on the game's track
--            entries while their Track Geometry row says On. Pick the start and the end (a track end, a
--            node, a point along a piece, or the ground), then edit the alignment (tg_edit, driven
--            by tg_session) under the game's ghost, and click off it to build (a window asks first).
--   TgProbe : a plugin in the bottom game bar (tg_probe.res.lua): every frame it reads the ground
--            under the mouse and places the badges for the tool (both only allowed there).
--   TgMenuPlugin : gives every track entry the "Track Geometry" row (tg_menu.res.lua), the only way in,
--            and the "Alignment" row (horizontal or vertical) beside it.

local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local styleutil = ug_require "::/gui/main/styleutil.tl" as StyleUtil
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local construction_react_util = ug_require "::/gui/construction/construction_react_util.tl" as ConstructionReactUtil
local dialog_react_util = ug_require "::/gui/menu/dialog_react_util.tl" as DialogReactUtil
local mod_entry_point = ug_require "::/gui/main/mod_entry_point.tl" as ModEntryPoint
local ends = require("track_geometry_tool::/track_geometry/tg_ends.script.tl")
local edits = require("track_geometry_tool::/track_geometry/tg_edit.script.tl")
local gizmos = require("track_geometry_tool::/track_geometry/tg_gizmos.script.tl")
local layouts = require("track_geometry_tool::/track_geometry/tg_layout.script.tl")
local ghosts = require("track_geometry_tool::/track_geometry/tg_proposal.script.tl")
local crossings = require("track_geometry_tool::/track_geometry/tg_crossings.script.tl")
local readout = require("track_geometry_tool::/track_geometry/tg_readout.script.tl")
local plans = require("track_geometry_tool::/track_geometry/tg_plan.script.tl")
local alignment = require("track_geometry_tool::/track_geometry/tg_alignment.script.tl")
local sessions = require("track_geometry_tool::/track_geometry/tg_session.script.tl")
local world = require("track_geometry_tool::/track_geometry/tg_world.script.tl")
local speedprobes = require("track_geometry_tool::/track_geometry/tg_speedprobe.script.tl")

local TAG = "[track_geometry_tool] "
local HOUSE_REACH = 3.0 -- a town building this close to the track's centre line is in its way (m; its box, seen from above)
local GRAB = 0.02 -- grab radius for handles, as a share of the camera's distance
local RAIL_CURSOR = 1024 -- the track builder's mouse cursor ("Rail" in the game's gui_react_util.tl)

local function say(msg : string)
	print(TAG .. msg)
end

local logged : {string : string} = {} -- the last error logged under each label

-- fn's result; nil when it fails, and then its error is logged once (again only when it changes).
local function guard<T>(label : string, fn : function() : T) : T
	local ok, v = pcall(fn)
	if ok then return v end
	if logged[label] ~= tostring(v) then
		logged[label] = tostring(v)
		say(label .. ": " .. logged[label])
	end
	return nil
end

local function cap(s : string) : string
	return s:sub(1, 1):upper() .. s:sub(2)
end

------------------------------------------------------------------ the clock

-- Wall-clock time (ms), from the game's api.type.Clock (microseconds since it was made; os.clock()
-- is CPU time summed over threads, NOTES.md); nil when there is no such clock. Made at first use.
local clock : Clock = nil
local noClock = false
local function nowMs() : number
	if noClock then return nil end
	if clock == nil then
		local ok, c = pcall(function() : Clock return api.type.Clock.new() end)
		if not ok or c == nil then noClock = true; return nil end
		clock = c
	end
	local ok, us = pcall(function() : integer return clock:getTime() end)
	if not ok or us == nil then noClock = true; return nil end
	return (us as number) / 1000
end

------------------------------------------------------------------ tool state

-- The line drawn over the section a bare refusal comes from, kept while it is the same.
local record HighlightCache
	key : string
	edges : {Builtin.Type.EdgeRenderable.Edge}
end

-- The ghost's plan (tg_plan), waiting for the game's proposal data: its curve speed limits. Each
-- ghost made sets it anew (none for a sketch).
local record Pending
	key : string -- ghost key
	plan : plans.Plan
	pieceOf : {integer : integer} -- the plan piece of each of the proposal's new edges (tg_layout)
end

-- The plan read out with those speeds.
local record PlanLine
	key : string -- ghost key
	readout : plans.Readout
end

-- A curve badge on the screen: where it sits, as a share of the screen's width and height.
local record ScreenBadge
	h : number
	v : number
	badge : readout.Badge
end

local record ToolState
	active : boolean
	mounted : integer -- the tools open (two for a moment when another track entry is picked)
	takeFocus : function(why : string) -- give TgProbe the keyboard focus, so "back" reaches the tool (set by TgProbe)
	wantFocus : string -- take it at the next tick, and why (a track entry was picked in the menu)
	ticked : boolean -- the tool has ticked since it opened (until then its state is the last opening's)
	opens : integer -- how often the tool has closed: in the redraw key, so the first tick always redraws
	matchRedraws : integer -- bumped on each pick in the mode window's match list: in its redraw key, so the list shows its placeholder again
	frame : integer -- frames drawn so far (counted by TgProbe, every frame)
	tickFrame : integer -- the frame of the tool's last tick
	hovered : integer -- entity under the mouse (Selector)
	terrX : number -- ground under the mouse (read every frame by TgProbe)
	terrY : number
	terrZ : number
	eye : Vec3f -- the camera, as of that frame (the view ray runs from it through the ground point)
	pending : Pending -- the ghost's plan, until the game's check of it comes
	vbadges : {readout.Badge} -- the profile's badges (vertical mode)
	modeOpen : boolean -- the mode window is open
	buildMsg : string -- how the last build went (kept when the tool starts over)
	gameCtx : GameContext -- for the confirm window
	entry : string -- the track entry picked in the game's builder: the track to build (nil until the tool first runs)
	line : PlanLine -- the plan as last read out: badges at its curves, summed up in the tooltip
	screen : {ScreenBadge} -- the line's badges on the screen (placed by TgProbe every frame)
	screenKey : string -- changes when the badges move on the screen
	grabNow : number -- grab radius at the last tick (m)
	camDist : number -- the camera's distance at the last tick (m); nil when unknown
	vbadgesKey : string -- the edit and grade limit the profile's badges were made for
	placedView : string -- the camera, screen and badges the badges were last placed for
	sketchEdges : {Builtin.Type.EdgeRenderable.Edge} -- the sketch's line: the whole path, while the mouse moves it
	ghostKey : string -- the key of the ghost being made (for its readout)
	nearest : function(x : number, y : number) : integer, number -- the ghost's piece nearest a point and its distance (m), for the refusal log
	section : function(j : integer, k : integer) : SimpleProposal, {integer}, string -- the ghost's pieces j..k laid out as a proposal of their own, for the search for a bare refusal's section
	describe : function(i : integer) : string -- piece i of the ghost's plan, for the log
	sectionEdges : function(j : integer, k : integer) : {Builtin.Type.EdgeRenderable.Edge} -- pieces j..k of the ghost's plan as a line
	hl : HighlightCache -- the highlighted section's line, as last drawn
end

local tool : ToolState = {}

-- The tool counts as ticking while its last tick was at most this many frames ago. Its timer
-- ticks every 50 ms, a few frames apart; counted in frames, not os.clock() (CPU time, see GUI
-- pitfalls in NOTES.md).
local LIVE_FRAMES = 60

-- Is the tool open and ticking?
local function toolLive() : boolean
	return tool.active == true and tool.tickFrame ~= nil and (tool.frame or 0) - tool.tickFrame <= LIVE_FRAMES
end

-- Which step the tool is at, the picked ends, the edit, what is under the mouse and what is
-- dragged (tg_session). Read here, changed only through its events.
local sess = sessions.new(say, toolLive)

-- The ghost (tg_proposal): the GUI reads its fields, and this script is the game's side of it
-- (port, below, with the ghost). Made anew when the tool starts over.
local port : ghosts.Port
local G : ghosts.State

-- Drop the ghost and what was read out (the session starts over by itself).
local function resetTool()
	G = ghosts.new(say, port)
	tool.pending, tool.hovered, tool.vbadges, tool.line, tool.screen, tool.screenKey, tool.matchRedraws = nil, nil, nil, nil, nil, nil, nil
	tool.sketchEdges, tool.section, tool.describe, tool.sectionEdges, tool.hl = nil, nil, nil, nil, nil
end

------------------------------------------------------------------ track type

-- What the tool knows about the track to build, the track entry picked in the game's builder
-- (tg_world caches it; standard track before the first entry is read). Read every tick: the entry
-- can change while the tool is open, and the ghost (its key holds the template) is then made again.
local function trackType() : world.TrackType
	return world.trackType(tool.entry)
end

-- The steepest grade the track type may be laid at.
local function gradeLimit() : number
	return trackType().maxGrade
end

------------------------------------------------------------------ geometry mode

-- The game's own track builder has a "Track Geometry" row on every track entry (added by
-- decorate). With On the tool takes the builder's place (TgTrackAction) and builds the
-- picked entry's track, with the panel's bridge and tunnel types. One value for every track
-- entry; it lasts until the game is closed.
local GEO_KEY = "tg_geometry"
-- And an "Alignment" row beside it: edit the horizontal or the vertical alignment.
local ALIGN_KEY = "tg_alignment"
local MODES : {sessions.Mode} = { "horizontal", "vertical" }

local record Geo
	on : boolean -- the row says On
	panel : {string : number} -- the track panel's values, as its last look at the row gave them
	hosted : boolean -- the tool ran since its alignment was last dropped (by No or the wand tab)
end

local geo : Geo = { on = false, hosted = false }

-- Is the panel on its Replace Track (wand) tab? (Its `mode` row counts tabs from 1.)
local function onWandTab(ps : {string : number}) : boolean
	return ps ~= nil and ps["mode"] == 2
end

-- Does the tool take the builder's place now? Never on the Replace Track tab.
local function geoWanted() : boolean
	return geo.on and not onWandTab(geo.panel)
end

-- A value of the track panel (nil: not known yet).
local function panelValue(key : string) : number
	if geo.panel == nil then return nil end
	return geo.panel[key]
end

-- A bridge or tunnel type: the one picked in the panel, else `auto`, the one the game's menu
-- would pick itself. The panel's value is the type's id, as the game's builder takes it
-- (bridgeTypeId), and "None" is -1 (menu_category_util.createNoObject): nil, on the ground.
local function structureType(key : string, auto : integer) : integer
	local v = panelValue(key)
	if v == nil then return auto end
	if v < 0 then return nil end
	return math.floor(v + 0.5)
end

-- What the map holds along the track's footprint (pts: tg_layout.footprint), from one look at
-- each stretch of it (tg_world.areaIn), with no check by the game:
--   the constructions of the town buildings on it. The ghost clears them from the start, so they
--   show as going (as with the game's own builder), not as collisions found a few at a time
--   (tg_proposal's clearing rounds mop up the rest);
--   the street and track edges near it, for its level and diamond crossings (tg_crossings finds
--   where it crosses them).
-- What was found before the map could not be read.
local function mapAlong(pts : {{number}}) : {integer}, {crossings.Street}
	local CHUNK = 16
	local houses, streets = {} as {integer}, {} as {crossings.Street}
	local seenH, seenS = {} as {integer : boolean}, {} as {integer : boolean}
	for c = 1, #pts, CHUNK do
		local part : {{number}} = {}
		local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
		for j = c, math.min(c + CHUNK, #pts) do -- (one point of overlap: no gap between chunks)
			local q = pts[j]
			part[#part + 1] = q
			x0, y0, x1, y1 = math.min(x0, q[1]), math.min(y0, q[2]), math.max(x1, q[1]), math.max(y1, q[2])
		end
		-- (one box for both, HOUSE_REACH past the chunk: a street that crosses the track meets its footprint)
		local boxes, sts = world.areaIn(x0 - HOUSE_REACH, y0 - HOUSE_REACH, x1 + HOUSE_REACH, y1 + HOUSE_REACH)
		if boxes == nil then break end
		for _, e in ipairs(layouts.onFootprint(part, boxes, HOUSE_REACH)) do
			local con = world.townBuildingConstruction(e)
			if con ~= nil and not seenH[con] then seenH[con], houses[#houses + 1] = true, con end
		end
		for e, st in pairs(sts) do
			if not seenS[e] then seenS[e], streets[#streets + 1] = true, st end
		end
	end
	return houses, streets
end

local sketchLine : function(plan : plans.Plan) : {Builtin.Type.EdgeRenderable.Edge} -- (with the gizmos)
local pieceLine : function(nodes : {alignment.Sample}, z : {number}, j : integer, k : integer) : {Builtin.Type.EdgeRenderable.Edge} -- (likewise)

-- What the ghost shows now: the path from the start to the end (picked, or under the mouse);
-- nothing before there are both. Remade only when its ends change.

-- The ghost's key: what it is made from (the phase too: picking the hovered end makes it again
-- once, which logs the path; the panel's bridge and tunnel types: another pick makes it again).
local function ghostKey(a : ends.End, b : ends.End) : string
	local key = sess.phase .. ":" .. (a ~= nil and ends.key(a) or "-") .. ":" .. (b ~= nil and ends.key(b) or "-")
	if sess.phase == "done" then key = key .. ":" .. tostring(sess.edit.rev) end
	key = key .. ":" .. trackType().template
	return key .. ":" .. tostring(panelValue("bridgeType")) .. ":" .. tostring(panelValue("tunnelType"))
end

-- The piece of the path (nodes: its plan's) nearest the point, and how far (m): the index of the
-- chord from node i to node i + 1.
local function nearestPiece(nodes : {alignment.Sample}, x : number, y : number) : integer, number
	local best, bestD = nil as integer, math.huge
	for i = 1, #nodes - 1 do
		local ax, ay, bx, by = nodes[i].x, nodes[i].y, nodes[i + 1].x, nodes[i + 1].y
		local dx, dy = bx - ax, by - ay
		local len2 = dx * dx + dy * dy
		local t = len2 > 0 and math.max(0, math.min(1, ((x - ax) * dx + (y - ay) * dy) / len2)) or 0
		local d = math.sqrt((x - ax - t * dx) ^ 2 + (y - ay - t * dy) ^ 2)
		if d < bestD then best, bestD = i, d end
	end
	return best, bestD
end

-- Make the ghost of the path from a to b (none without both): the port's make. sketch: the mouse
-- is moving the path, so no proposal, only the path as a line (tool.sketchEdges). A sketch plans
-- the path without the ground and water (no bridges or tunnels): its line needs only the plan's
-- dense nodes and their heights, which do not depend on them.
local function makeGhost(a : ends.End, b : ends.End, sketch : boolean) : ghosts.Made
	local g : ghosts.Made = {}
	tool.sketchEdges, tool.pending, tool.nearest = nil, nil, nil
	tool.section, tool.describe, tool.sectionEdges, tool.hl = nil, nil, nil, nil
	-- (a path's line stays until the next ghost of it is read out; a sketch has none)
	if a == nil or b == nil then tool.line = nil; return g end
	-- bridges and tunnels where the track is far off the ground: their types first (without them,
	-- or when the ground cannot be read, the plan has none)
	local tt = trackType()
	local ground, water = world.ground, world.water
	local bridgeType, tunnelType = structureType("bridgeType", tt.bridgeType), structureType("tunnelType", tt.tunnelType)
	if sketch or tt.structuresWhy ~= nil then ground, water = nil, nil end -- (tg_world logged why)
	local plan, pwhy = plans.path(a, b, sess.edit, ground, water)
	if plan == nil then g.why = pwhy; tool.line = nil; return g end
	if plan.note ~= nil then say("ghost: no structures: " .. plan.note) end
	g.info = plan.structures ~= nil and (plan.info .. "; " .. plan.structures) or plan.info
	if sketch then
		local okL, l = pcall(sketchLine, plan)
		if okL then tool.sketchEdges = l as {Builtin.Type.EdgeRenderable.Edge} else say("ghost: the path's line: " .. tostring(l)) end
		tool.line = nil
		return g
	end
	local nodes, grades, zs, kinds = plan.built.nodes, plan.grades, plan.built.z, plan.kinds
	local replace, runs = plans.switches(a, b, nodes, world.piecesAt, world.mergeable)
	local pts = layouts.footprint(nodes, kinds, 4.0)
	local okM, houses, streets = pcall(mapAlong, pts)
	if not okM then say("ghost: the map along it: " .. tostring(houses)); houses, streets = nil, nil end
	local crossingType = world.crossingType()
	local ok, p, pieceOf, why, crossed = pcall(layouts.make, nodes, { template = tt.template, z = zs, grades = grades,
		from = a, to = b, replace = replace, runs = runs,
		kinds = kinds, bridgeType = bridgeType, tunnelType = tunnelType,
		streets = streets as {crossings.Street}, crossingType = crossingType })
	if not ok then g.why = "error: " .. tostring(p); say("ghost: " .. g.why); return g end
	if p == nil then g.why = why; return g end
	g.proposal = p as SimpleProposal
	g.crossed = {}
	for _, c in ipairs((crossed or {}) as {crossings.Crossing}) do
		if c.why == nil then
			for _, e in ipairs(c.street.pieces or { c.street.edge }) do g.crossed[#g.crossed + 1] = e end
		end
	end
	local hs = houses as {integer}
	if hs ~= nil and #hs > 0 then
		local okC, err = pcall(function() : string g.proposal.constructionsToRemove = hs; return nil end)
		if okC then g.cleared = hs else say("ghost: cannot clear the buildings: " .. tostring(err)) end
	end
	tool.pending = { key = tool.ghostKey, plan = plan, pieceOf = pieceOf as {integer : integer} }
	tool.nearest = function(x : number, y : number) : integer, number return nearestPiece(nodes, x, y) end
	-- pieces j..k of the plan on their own, for the search for a bare refusal's section: laid out
	-- again by tg_layout, as the whole is, from the map along them (so their crossings are found and
	-- cut anew), joined to the picked ends where they are the path's ends. The switches' copies and
	-- merged runs only belong to the whole path.
	local m = #nodes - 1
	g.pieces = m
	tool.section = function(j : integer, k : integer) : SimpleProposal, {integer}, string
		local sub, sz, sg : {alignment.Sample}, {number}, {number} = {}, {}, {}
		for i = j, k + 1 do sub[#sub + 1], sz[#sz + 1], sg[#sg + 1] = nodes[i], zs[i], grades[i] end
		local sk : {string} = nil
		if kinds ~= nil then
			sk = {}
			for i = j, k do sk[#sk + 1] = kinds[i] end
		end
		local okS, sh, ss = pcall(mapAlong, layouts.footprint(sub, sk, 4.0))
		if not okS then return nil, nil, "the map along it: " .. tostring(sh) end
		local whole = j == 1 and k == m
		local from, to : ends.End, ends.End = nil, nil
		if j == 1 then from = a end
		if k == m then to = b end
		local okL, q, _, whyL = pcall(layouts.make, sub, { template = tt.template, z = sz, grades = sg,
			from = from, to = to, replace = whole and replace or nil, runs = whole and runs or nil,
			kinds = sk, bridgeType = bridgeType, tunnelType = tunnelType,
			streets = ss as {crossings.Street}, crossingType = crossingType })
		if not okL then return nil, nil, "error: " .. tostring(q) end
		if q == nil then return nil, nil, whyL end
		local gone = sh as {integer}
		if #gone > 0 then
			local okC, err = pcall(function() : string (q as SimpleProposal).constructionsToRemove = gone; return nil end)
			if not okC then return nil, nil, "cannot clear the buildings: " .. tostring(err) end
		end
		return q as SimpleProposal, gone, nil
	end
	tool.describe = function(i : integer) : string
		local n0, n1 = nodes[i], nodes[i + 1]
		return string.format("piece %d: %.1f m, from (%.1f, %.1f, %.1f) to (%.1f, %.1f, %.1f)", i,
			math.sqrt((n1.x - n0.x) ^ 2 + (n1.y - n0.y) ^ 2 + (zs[i + 1] - zs[i]) ^ 2), n0.x, n0.y, zs[i], n1.x, n1.y, zs[i + 1])
	end
	tool.sectionEdges = function(j : integer, k : integer) : {Builtin.Type.EdgeRenderable.Edge} return pieceLine(nodes, zs, j, k) end
	-- our own account of the track: said when it is made settled, and logged with a refusal of it
	local account : {string} = {}
	account[#account + 1] = string.format("path %s: from %s (%.1f, %.1f) leaving %.2f deg, to %s (%.1f, %.1f) arriving %.2f deg, %d pieces, %d merged runs, grade %+.1f ‰ to %+.1f ‰",
		plan.info, ends.name(a), a.x, a.y, math.deg(nodes[1].heading), ends.name(b), b.x, b.y, math.deg(nodes[#nodes].heading), #nodes - 1, #runs, grades[1] * 1000, grades[#grades] * 1000)
	if g.cleared ~= nil then account[#account + 1] = string.format("%d town building%s on its footprint (within %.1f m)", #g.cleared, #g.cleared > 1 and "s" or "", HOUSE_REACH) end
	for _, c in ipairs((crossed or {}) as {crossings.Crossing}) do
		account[#account + 1] = string.format("%s %d%s crossed at (%.1f, %.1f, %.1f): %s", c.street.track and "track" or "road", c.street.edge,
			c.street.joint ~= nil and string.format(" (with %d, across their joint %d)", c.street.edge1 == c.street.edge and c.street.edge0 or c.street.edge1, c.street.joint) or "",
			c.x, c.y, c.z, c.why == nil and (c.street.track and "a diamond crossing" or "a level crossing") or ("not cut: " .. c.why))
	end
	g.account = account
	if sess.phase == "done" then
		say("tool: " .. account[1])
		for i = 2, #account do say("ghost: " .. account[i]) end
	end
	return g
end

-- Every tool tick: the ghost of what the session shows now (tg_proposal makes it again when it
-- has changed, and clears the town buildings in its way once it has settled).
local function updateGhost()
	local a, b : ends.End, ends.End = nil, nil
	if sess.phase == "from" then a = sess.hover
	elseif sess.phase == "to" then a, b = sess.from, sess.hover
	else a, b = sessions.ends(sess) end
	tool.ghostKey = ghostKey(a, b)
	ghosts.tick(G, { key = tool.ghostKey, a = a, b = b, settled = sess.phase == "done", dragging = sessions.dragging(sess), toPhase = sess.phase == "to" })
end

-- What kind of entity e is, for the log.
local function entityKind(e : integer) : string
	local ok, k = pcall(function() : string
		if e == nil or e < 0 then return "new " .. tostring(e) end
		if not api.engine.entityExists(e) then return "gone " .. tostring(e) end
		local CT = api.type.ComponentType
		local is = function(t : any) : boolean return api.engine.getComponent(e, t as Engine.ComponentType) ~= nil end
		if is(CT.BASE_EDGE) then return (is(CT.BASE_EDGE_STREET) and "street " or "track ") .. tostring(e) end
		if is(CT.BASE_NODE) then return "node " .. tostring(e) end
		if is(CT.TOWN_BUILDING) then return "townbuilding " .. tostring(e) end
		if is(CT.FIELD) then return "field " .. tostring(e) end
		if is(CT.CONSTRUCTION) then return "construction " .. tostring(e) end
		if is(CT.SUBCONSTRUCTION) then return "subconstruction " .. tostring(e) end
		-- (none of those: say which components it has, to tell what it is)
		local has : {string} = {}
		for _, name in ipairs({ "AIRCRAFT", "ANIMAL", "BASE_PARALLEL_STRIP", "EDGE_OBJECT", "FIELD", "STATION", "STATION_GROUP", "TOWN", "INDUSTRY",
			"TRAIN", "VEHICLE_DEPOT", "BOUNDING_VOLUME", "CONSTRUCTION", "SUBCONSTRUCTION", "WAREHOUSE", "RAILROAD_CROSSING", "BRIDGE",
			"LAND_VEHICLE", "SHIP", "NAME", "PLAYER_OWNED", "TRANSPORT_NETWORK", "MODEL_INSTANCE_LIST", "STOCK_LIST", "SIGNAL_LIST", "TERRAIN" }) do
			local okc, hit = pcall(function() : boolean return is((CT as {string : any})[name]) end)
			if okc and hit then has[#has + 1] = name end
		end
		return "other " .. tostring(e) .. " [" .. table.concat(has, ",") .. "]"
	end)
	return ok and k or ("? " .. tostring(e))
end

-- Where entity e is (x, y), for the log: an edge at the midpoint of its nodes, a node, a town
-- building or construction at its construction's position; nil for anything else or when gone.
local function entityXY(e : integer) : number, number
	local ok, x, y = pcall(function() : number, number
		if e == nil or e < 0 or not api.engine.entityExists(e) then return nil, nil end
		local CT = api.type.ComponentType
		local function nodeAt(n : integer) : Vec3f
			local bn = api.engine.getComponent(n, CT.BASE_NODE) as Engine.Component.BaseNode
			return bn ~= nil and bn.position or nil
		end
		local be = api.engine.getComponent(e, CT.BASE_EDGE) as Engine.Component.BaseEdge
		if be ~= nil then
			local p0, p1 = nodeAt(be.node0), nodeAt(be.node1)
			if p0 == nil or p1 == nil then return nil, nil end
			return (p0.x + p1.x) / 2, (p0.y + p1.y) / 2
		end
		local p = nodeAt(e)
		if p ~= nil then return p.x, p.y end
		local con = e
		local tb = api.engine.getComponent(e, CT.TOWN_BUILDING) as Engine.Component.TownBuilding
		if tb ~= nil then con = tb.construction as integer end
		local c = con ~= nil and con >= 0 and api.engine.getComponent(con, CT.CONSTRUCTION) as Engine.Component.Construction or nil
		if c == nil then
			-- anything else with a box (what the game removes by itself): the box's centre
			local bv = api.engine.getComponent(e, CT.BOUNDING_VOLUME) as Engine.Component.BoundingVolume
			if bv == nil or bv.bbox == nil then return nil, nil end
			return (bv.bbox.min.x + bv.bbox.max.x) / 2, (bv.bbox.min.y + bv.bbox.max.y) / 2
		end
		local t = c.transf:getTransl()
		return t.x, t.y
	end)
	if ok then return x, y end
	return nil, nil
end

-- One line about an entity the game names in a refusal: what it is, where, and our nearest piece
-- (near: the ghost's lookup as it was when the check came).
local function entityLine(label : string, e : integer, suffix : string, near : function(number, number) : integer, number) : string
	local s = label .. " " .. entityKind(e) .. (suffix or "")
	-- (its box, when it has one: a big box's centre says little)
	local okB, box = pcall(function() : string
		if e == nil or e < 0 or not api.engine.entityExists(e) then return nil end
		local bv = api.engine.getComponent(e, api.type.ComponentType.BOUNDING_VOLUME) as Engine.Component.BoundingVolume
		if bv == nil or bv.bbox == nil then return nil end
		local a, b = bv.bbox.min, bv.bbox.max
		return string.format(" box (%.1f, %.1f)-(%.1f, %.1f) z %.1f..%.1f", a.x, a.y, b.x, b.y, a.z, b.z)
	end)
	if okB and box ~= nil then s = s .. box end
	local x, y = entityXY(e)
	if x == nil then return s end
	s = s .. string.format(" at (%.1f, %.1f)", x, y)
	if near ~= nil then
		local i, d = near(x, y)
		if i ~= nil then s = s .. string.format("; nearest piece %d, %.1f m", i, d) end
	end
	return s
end

-- Everything the game says about a proposal it refuses, beyond its cost and critical, as log lines:
-- each non-empty message list, then each entity it names with its position and our nearest piece.
local function refusalLines(data : ProposalData, near : function(number, number) : integer, number) : {string}
	local ok, lines = pcall(function() : {string}
		local out : {string} = {}
		local es = data.errorState
		if es ~= nil then
			local function list(name : string, l : {string})
				if l ~= nil and #l > 0 then out[#out + 1] = name .. ": " .. table.concat(l, ", ") end
			end
			list("messages", es.messages)
			list("warnings", es.warnings)
			list("infos", es.infos)
		end
		local ci = data.collisionInfo
		if ci ~= nil then
			for _, ed in ipairs(ci.collisionEntities or {}) do out[#out + 1] = entityLine("collision", ed.entity, nil, near) end
			for _, e in ipairs(ci.buildingEntities or {}) do out[#out + 1] = entityLine("building", e, nil, near) end
			for e, ms in pairs(ci.autoRemovalEntity2models or {}) do out[#out + 1] = entityLine("auto-removal", e, " x" .. tostring(#ms), near) end
			for _, e in ipairs(ci.removableModules or {}) do out[#out + 1] = entityLine("removable module", e, nil, near) end
		end
		local add = data.toAddData
		if add ~= nil and #add > 0 then out[#out + 1] = "toAddData: " .. tostring(#add) end
		-- the game names one entity once per piece it meets: one line, counted
		local counts, order : {string : integer}, {string} = {}, {}
		for _, l in ipairs(out) do
			if counts[l] == nil then order[#order + 1] = l end
			counts[l] = (counts[l] or 0) + 1
		end
		local merged : {string} = {}
		for _, l in ipairs(order) do merged[#merged + 1] = counts[l] > 1 and (l .. " (x" .. tostring(counts[l]) .. ")") or l end
		return merged
	end)
	if ok then return lines as {string} end
	return { "detail failed: " .. tostring(lines) }
end

-- The context of a dry run or a build, for the player's company. gather: the game gathers the town
-- buildings in the way itself, as its own builder does (without, its check names them as
-- collisions); fields it always gathers.
local function makeContext(gather : boolean) : Context
	local c = api.type.Context.new()
	c.player = api.engine.util.getPlayer()
	c.gatherBuildings = gather
	c.gatherFields = true
	return c
end

-- The game's check of a proposal (from the viewer or a dry run), boiled down for tg_proposal.
local function checkOf(data : ProposalData, near : function(number, number) : integer, number) : ghosts.Check
	local es, ci = data.errorState, data.collisionInfo
	near = near or tool.nearest
	local c : ghosts.Check = { cost = data.costs, critical = es ~= nil and es.critical == true, hits = { collides = {}, buildings = {} },
		detail = function() : {string} return refusalLines(data, near) end }
	if es ~= nil then
		c.messages, c.warnings = {}, {}
		for _, m in ipairs(es.messages or {}) do c.messages[#c.messages + 1] = m end
		for _, w in ipairs(es.warnings or {}) do c.warnings[#c.warnings + 1] = w end
	end
	if ci ~= nil then
		for _, ed in ipairs(ci.collisionEntities or {}) do c.hits.collides[#c.hits.collides + 1] = ed.entity end
		for _, e in ipairs(ci.buildingEntities or {}) do c.hits.buildings[#c.hits.buildings + 1] = e end
	end
	return c
end

-- The ghost's side in the game (tg_proposal.Port).
port = {
	make = function(a : ends.End, b : ends.End, sketch : boolean) : ghosts.Made
		local m = guard("ghost", function() : ghosts.Made return makeGhost(a, b, sketch) end)
		if m == nil then
			tool.sketchEdges, tool.line, tool.pending = nil, nil, nil
			return { why = "the ghost could not be made" }
		end
		return m
	end,
	-- (what is built: the ghost's track, the town buildings it clears left out unless `removing`
	-- names them; makeProposalData blocks the frame, a few hundred ms for a long track)
	dryRun = function(p : SimpleProposal, removing : {integer}, gather : boolean) : ghosts.Check, string
		local okQ, q = pcall(layouts.gathering, p)
		if not okQ then return nil, "the game could not check it (" .. tostring(q) .. ")" end
		if q == nil then return nil, "the proposal to build came out short" end
		local ok, d = pcall(function() : ProposalData
			if removing ~= nil and #removing > 0 then q.constructionsToRemove = removing end
			return api.engine.util.proposal.makeProposalData(q as any as Proposal, makeContext(gather))
		end)
		if not ok then return nil, "the game could not check it (" .. tostring(d) .. ")" end
		if d == nil then return nil, "the game could not check it" end
		return checkOf(d as ProposalData, nil), nil
	end,
	section = function(j : integer, k : integer) : SimpleProposal, {integer}, string
		if tool.section == nil then return nil, nil, "there is no plan" end
		return tool.section(j, k)
	end,
	describe = function(i : integer) : string
		if tool.describe == nil then return "piece " .. i end
		return tool.describe(i)
	end,
	setCleared = function(p : SimpleProposal, list : {integer}) : boolean, string
		local ok, err = pcall(function() : string p.constructionsToRemove = list; return nil end)
		if ok then return true, nil end
		return false, tostring(err)
	end,
	constructionOf = world.townBuildingConstruction,
	allExist = world.allExist,
	joinable = world.joinable,
	balance = function() : integer
		local ok, bal = pcall(function() : integer return api.engine.util.finance.getPlayersBalance(api.engine.util.getPlayer()) end)
		if ok then return bal as integer end
		return nil
	end,
	now = nowMs,
}
G = ghosts.new(say, port)

local closeConfirm, closeModeWindow : function(), function() -- (below, with the windows)

-- Start over: close the windows, pick the start again and drop the ghost.
local function startOver()
	closeConfirm()
	closeModeWindow()
	sessions.reset(sess)
	resetTool()
end

-- Builds the ghost's proposal p (the confirm window's offer), and starts over. What is built is
-- its track without the town buildings it clears itself, the game gathering them, as its own
-- builder does: a build that names several houses in constructionsToRemove kills the game (NOTES.md).
local function build(p : SimpleProposal, info : string, cost : integer)
	local near, account = tool.nearest, G.ghost.account -- (the ghost is gone when the game answers)
	local ok, err : boolean, any = pcall(function()
		local q = layouts.gathering(p)
		if q == nil then error("the proposal to build came out short", 0) end
		local cmd = api.cmd.makeWorldBuildProposalCmd(q, makeContext(true), false, true)
		api.cmd.sendCommand(cmd, function(r : WorldBuildProposalCommandData, success : boolean, _ : {{Engine.Entity, Engine.Revision}})
			local rd = r ~= nil and r.resultProposalData or nil
			if success then
				tool.buildMsg = nil
				say(string.format("build: built %s for %s", info or "?", tostring(rd ~= nil and rd.costs or cost)))
			else
				tool.buildMsg = "The last build failed."
				if rd ~= nil then ghosts.logRefusal(G, "build", checkOf(rd, near), nil, account) else say("build: refused: no data") end
			end
		end)
	end)
	if not ok then
		sessions.refuse(sess, "Cannot build: " .. tostring(err))
		say("build: " .. tostring(err))
		return
	end
	say(string.format("build: sent %s, cost %s", info or "?", tostring(cost)))
	startOver()
end

local function fmtMoney(v : integer) : string
	local ok, txt = pcall(api.util.formatMoney, v)
	if ok and txt ~= nil then return txt end
	return string.format("$%d", math.floor(v))
end

-- s with its lines broken at spaces to at most w bytes where they can be.
local function wrapText(s : string, w : integer) : string
	local out : {string} = {}
	for line in (s .. "\n"):gmatch("(.-)\n") do
		local cur = ""
		for word in (line as string):gmatch("%S+") do
			if cur ~= "" and #cur + 1 + #word > w then out[#out + 1], cur = cur, word
			else cur = cur == "" and word or cur .. " " .. word end
		end
		out[#out + 1] = cur
	end
	return table.concat(out, "\n")
end

local function windowApi() : Builtin.WindowAPI
	local ctx = tool.gameCtx
	if ctx == nil or ctx.windowContainer == nil then return nil end
	local ok, res = pcall(function() : Builtin.WindowAPI return ctx.windowContainer:get():getApi() end)
	if ok then return res end
	return nil
end

-- Open a window (only ever from a click: from onStep it kills the game). false when it could not
-- be opened, and then `what` logs why.
local function openWindow(recipe : any, param : any, what : string) : boolean
	local wa = windowApi()
	local ok, err = pcall(function() : string wa.addSingletonWindow(recipe as Recipe<any>, param); return nil end)
	if ok and wa ~= nil then return true end
	say(what .. " failed: " .. tostring(wa == nil and "no window container" or err))
	return false
end

local function closeWindow(recipe : any)
	local wa = windowApi()
	if wa ~= nil then pcall(function() : string wa.removeAllWindows(recipe as Recipe<any>); return nil end) end
end

closeConfirm = function()
	if not sess.confirmOpen then return end
	sessions.confirmClosed(sess)
	closeWindow(dialog_react_util.DialogWindow)
end

------------------------------------------------------------------ the mode window

local run : function(reqs : {sessions.Request}) -- (below, with the session's adapter)
local gameSpeeds : speedprobes.Probe -- the game's curve speed on a radius, on the track type (made below)

local record ModeParam -- (none: the window reads the session)
end

-- What the mode window shows changes with this: the mode, the selection, the edit and the
-- grade limit. (The window gets its params once, so it re-reads the session on a timer.)
local function modeKey() : string
	local e = sess.edit
	return table.concat({ sess.mode as string or "-", tostring(sess.selected), tostring(sessions.selectedTurnIndex(sess)), e ~= nil and tostring(e.rev) or "-",
		string.format("%.4f", gradeLimit()), string.format("%.1f", trackType().speed), tostring(tool.matchRedraws or 0) }, "|")
end

local HEIGHT_STEP = 0.1 -- the height box's arrows step this (m)

local function line(text : string) : TreeNodeId
	return builtin.TextView{ text = text }
end

-- The match list: "Match the height of…" (value 0, always shown: the box has no placeholder of
-- its own), then the start, the other points and the end (sessions.matchSources). A pick sets the
-- selection to that height, once, and the window is drawn again with the placeholder.
local function matchList(sources : {sessions.MatchSource}, forKey : integer) : TreeNodeId
	local items : {TreeNodeId} = { builtin.ComboBoxItem{ value = 0, content = line("Match the height of…") } }
	for k, m in ipairs(sources) do items[#items + 1] = builtin.ComboBoxItem{ value = k, content = line(m.label) } end
	return builtin.ComboBox{
		value = 0,
		items = items,
		onValueChange = function(v : integer|number|string)
			local k = math.floor(tonumber(v) or 0)
			-- (the placeholder, or the box echoing it; and the list is for the selection it was drawn
			-- for, and applies the entry as it was drawn)
			if k < 1 or sources[k] == nil or sessions.dragging(sess) or sess.selected ~= forKey then return end
			tool.matchRedraws = (tool.matchRedraws or 0) + 1
			run(sessions.match(sess, sources[k]))
		end,
	}
end

-- The Elevation section, in vertical mode: the selected point or ground end, its height (set at
-- once, past the grade limit too: the build is then refused), the list to match it to another
-- height, its grade, and why the build waits. Greyed out with nothing selected.
local function elevationSection() : TreeNodeId
	local sel = sessions.selection(sess, gradeLimit())
	if sel == nil then
		return builtin.WithComponentParams{
			enabled = false,
			item = builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical,
				children = { line("Elevation"), line("Select an elevation point or a ground end."), matchList({}, nil) } },
		}
	end
	local rows : {TreeNodeId} = {
		line("Elevation: " .. sel.name),
		builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				line("Height (m) "),
				builtin.DoubleSpinBox{
					step = HEIGHT_STEP, -- (no min or max: the box's own clamp is only the UI's)
					value = sel.z,
					onValueChange = function(v : number)
						-- (a drag owns the height while it lasts; the box only follows it. Within half a
						-- step of the height it was given is the box echoing it, maybe rounded to its
						-- step: taking that would move the point by itself. And the box is for the selection
						-- it was drawn for.)
						if sessions.dragging(sess) or v == nil or v ~= v or sess.selected ~= sel.i then return end
						if math.abs(v - sel.z) < HEIGHT_STEP / 2 then return end
						run(sessions.setHeight(sess, v))
					end,
				},
			},
		},
		matchList(sessions.matchSources(sess), sel.i),
		line(sel.grade ~= nil and string.format("Grade: %+.1f ‰", sel.grade * 1000) or "Grade: —"),
	}
	if sel.steep ~= nil then rows[#rows + 1] = line(cap(sel.steep)) end
	if sel.tooClose then
		rows[#rows + 1] = line(string.format("Too close: not in the profile until %.0f m clear.", edits.MIN_SPAN))
	end
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = rows }
end

local RADIUS_STEP = 1.0 -- the radius box's arrows step this (m)
local SPEED_STEP = 1.0 -- the speed box's arrows step this (km/h)

-- The Curve section, in horizontal mode: the selected curve's radius (m) and speed (km/h), either
-- of which sets the radius (the speed through the game's own curve speed, at most the track's top
-- speed; with no speed from the game the box says so). A radius out of reach is laid as near as the legs and the minimum radius allow, and
-- the boxes then show what was laid. Greyed out with nothing selected.
local function curveSection() : TreeNodeId
	local sel = sessions.curveSelection(sess, gameSpeeds)
	if sel == nil then
		return builtin.WithComponentParams{
			enabled = false,
			item = line("Curve: click a curve's badge to set its radius or speed."),
		}
	end
	local top = trackType().speed
	local function box(label : string, value : number, step : number, apply : function(v : number)) : TreeNodeId
		return builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				line(label),
				builtin.DoubleSpinBox{
					step = step,
					value = value,
					onValueChange = function(v : number)
						-- (as the height box: a drag owns the curve while it lasts, an echo of the value it was given
						-- is no edit, and the box is for the selection it was drawn for)
						if sessions.dragging(sess) or v == nil or v ~= v or sessions.selectedTurnIndex(sess) ~= sel.i then return end
						if math.abs(v - value) < step / 2 then return end
						apply(v)
					end,
				},
			},
		}
	end
	local speedLabel = top > 0 and string.format("Speed (km/h; asks max %.0f) ", top * 3.6) or "Speed (km/h) "
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Vertical,
		children = {
			line("Curve: " .. sel.name),
			box("Radius (m) ", sel.radius, RADIUS_STEP, function(v : number) run(sessions.setRadius(sess, v)) end),
			sel.speed ~= nil
				and box(speedLabel, sel.speed * 3.6, SPEED_STEP, function(v : number) run(sessions.setSpeed(sess, v / 3.6, gameSpeeds)) end)
				or line("Speed: the game gave no curve speed for this track."),
			line(string.format("Radius %.0f to %.0f m here.", sel.minRadius, sel.maxRadius)),
		},
	}
end

-- A small window with the Elevation section (Profile mode) or the Curve section (Path mode). It opens
-- when the Alignment row switches to Profile, or a curve's badge is clicked in Path mode, and stays
-- open until the tool closes or the path is left. Opened from a click (the badge's, or the row's;
-- opening a window from onStep kills the game). A window recipe must wrap builtin.Window
-- (RegisterWrapperRecipe, as the game's own windows do): a plain recipe returning one fails a
-- native assertion in the window container (NodeStorage.cpp:51). It sits at the bottom right of
-- the screen, above the game bar (tg_gui.css.lua).
local TgModeWindow = react.RegisterWrapperRecipe("TgModeWindow", builtin.Window, function(_p : ModeParam, _ : any) : TreeNodeId
	local key = engine_react_util.useStepStateTimer(modeKey, 0.1)
	local _ = key:old()
	return builtin.Window{
		-- (no-close-button: the plain window surface, as the game's dialogs; the default one has a
		-- notch for the close button. Size and place: tg_gui.css.lua, by the id.)
		meta = { class = "no-close-button" },
		id = "tgmode",
		title = "Track Geometry",
		closable = false,
		movable = true,
		content = sessions.vertical(sess) and elevationSection() or curveSection(),
	}
end)

closeModeWindow = function()
	if not tool.modeOpen then return end
	tool.modeOpen = false
	closeWindow(TgModeWindow)
end

-- (while the profile is edited, or a curve is selected in Path mode)
local function openModeWindow()
	if tool.modeOpen or sess.phase ~= "done" or not (sessions.vertical(sess) or sess.selectedTurn ~= nil) then return end
	if openWindow(TgModeWindow, {} as ModeParam, "mode window") then
		tool.modeOpen = true
		say("mode window: open")
	end
end

-- The ghost's path (its length and layout) and the readout l sums up, added to lines.
local function pathLines(lines : {string}, l : PlanLine)
	if G.ghost.info == nil then return end
	lines[#lines + 1] = "Path: " .. G.ghost.info
	if l == nil then return end
	local ok, more = pcall(plans.summary, l.readout, trackType().speed)
	if ok then for _, m in ipairs(more as {string}) do lines[#lines + 1] = m end end
end

-- What the confirm window says: the path, its readout, what the game warns about, and the cost.
local function confirmText(cost : integer, problems : string) : string
	local a, b = sessions.ends(sess)
	local lines : {string} = { "New track from " .. ends.name(a) .. " to " .. ends.name(b),
		"Track: " .. trackType().name }
	local l = tool.line
	pathLines(lines, l ~= nil and l.key == G.ghost.key and l or nil)
	if problems ~= nil then
		lines[#lines + 1] = ""
		for line in problems:gmatch("[^\n]+") do lines[#lines + 1] = line end
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "Cost: " .. fmtMoney(cost)
	return wrapText(table.concat(lines, "\n"), 80)
end

-- The session asks to build (a click while editing that grabbed nothing): a window shows what
-- would be built and asks first.
local function openConfirm()
	local from, to = sessions.ends(sess)
	local why, offer = ghosts.gate(G, from, to)
	if why ~= nil then
		sessions.refuse(sess, "Cannot build: " .. why .. ".")
		say("build: not sent: " .. why)
		return
	end
	local p, info, cost, problems = offer.proposal, offer.info, offer.cost, offer.problems
	if openWindow(dialog_react_util.DialogWindow, {
			windowTitle = "Build this track?",
			displayText = confirmText(cost, problems),
			x = 0.5,
			y = 0.5,
			closable = true,
			onClose = closeConfirm,
			choices = {
				{
					text = "Build",
					onClick = function()
						closeConfirm()
						-- (asked again: an end may have gone, or a building it clears been rebuilt,
						-- while the window was open; only the ghost offered is built)
						local whyNow, now = ghosts.gate(G, from, to)
						if whyNow == nil and now.proposal ~= p then whyNow = "the track has changed" end
						if whyNow ~= nil then
							sessions.refuse(sess, "Cannot build: " .. whyNow .. ".")
							say("build: not sent: " .. whyNow)
							return
						end
						build(p, info, cost)
					end,
					isSecondary = false,
					enabled = true,
				},
				{
					text = "Cancel",
					onClick = closeConfirm,
					isSecondary = true,
					enabled = true,
				},
			},
			onBackChoiceIndex = 2,
		} as DialogReactUtil.DialogWindowParam, "build: confirm window") then
		sessions.confirmOpened(sess)
		say(string.format("build: asking to confirm %s, cost %s", info or "?", tostring(cost)))
	else
		-- no window could be shown: never build without asking
		sessions.refuse(sess, "The confirm window could not be opened, so nothing was built.")
	end
end

------------------------------------------------------------------ editing

-- Height to draw a gizmo at (x, y): the ground there, so it sits over the spot the mouse grabs it
-- at (handles are picked by where the mouse meets the ground). Else the ends' heights, blended
-- along the line between them.
local function zAt(x : number, y : number) : number
	local z = world.ground(x, y)
	if z ~= nil then return z end
	local a, b = sessions.ends(sess)
	if a == nil or b == nil then return 0 end
	local lx, ly = b.x - a.x, b.y - a.y
	local l2 = lx * lx + ly * ly
	local t = l2 > 0 and math.max(0, math.min(1, ((x - a.x) * lx + (y - a.y) * ly) / l2)) or 0
	return a.z + t * (b.z - a.z)
end

---------------------------------------------------- editing the vertical alignment

-- The profile's badges (grade at each point and halfway between, the spans too steep marked), for
-- the badge layer.
local function updateVBadges()
	local e = sess.edit
	-- (only when the edit or the limit has changed: else every tick read the whole profile again)
	local key = tostring(e) .. "|" .. tostring(e.rev) .. "|" .. tostring(gradeLimit())
	if key == tool.vbadgesKey and tool.vbadges ~= nil then return end
	tool.vbadgesKey = key
	local prof = edits.profile(e)
	tool.vbadges = prof ~= nil and readout.profileBadges(edits.nodes(e), prof, plans.BADGE_EVERY, gradeLimit()) or nil
end

------------------------------------------------------------------ the session's adapter

local function shiftHeld() : boolean
	return api.gui.inputAction.modifierOnlyActionIsActive("IA_PRECISION_MODE")
end

-- Does Geometry mode join existing track now? Not with the panel's Snapping on No (its value is
-- the row's index: 1 Yes, 2 No), nor while Shift is held, as in the game's builder (which greys
-- the row then).
local function geoSnaps() : boolean
	return panelValue("disableSnapping") ~= 2 and not shiftHeld()
end

-- The end the mouse picks: what it snaps to (tg_ends.snap) on the track and nodes near it, or
-- the ground there when Geometry mode does not snap now. Ends already picked stay.
local function snapEnd(x : number, y : number, z : number, hovered : integer, exclude : ends.End) : ends.End, string
	if not geoSnaps() then return ends.snap({}, nil, x, y, z, exclude) end
	-- (near the start's piece, not under the mouse: the ground, not a refusal)
	local near, piece = world.endsNear(x, y, hovered, exclude ~= nil and exclude.piece ~= nil and exclude.piece.edge or nil)
	return ends.snap(near, piece, x, y, z, exclude)
end
-- What the session needs from the game, as of now. fresh (the tool's tick): read the camera
-- again; else (a mouse or "back" event) as it was at the last tick.
local function worldNow(fresh : boolean) : sessions.World
	if fresh then
		local ok, cam = pcall(function() : number return api.gui.camera.getCameraData().z end)
		tool.camDist = ok and cam ~= nil and cam == cam and cam as number or nil
		-- (the grab radius: a fixed share of the screen, whatever the zoom)
		tool.grabNow = tool.camDist ~= nil and math.max(3.0, GRAB * tool.camDist) or sessions.DEFAULT_GRAB
	end
	local eye, ray = tool.eye, nil as edits.Ray
	if eye ~= nil and tool.terrX ~= nil and tool.terrZ ~= nil then
		ray = { ex = eye.x, ey = eye.y, ez = eye.z, gx = tool.terrX, gy = tool.terrY, gz = tool.terrZ }
	end
	return { terrX = tool.terrX, terrY = tool.terrY, terrZ = tool.terrZ, ray = ray, hovered = tool.hovered, grab = tool.grabNow,
		cameraDist = tool.camDist, shift = shiftHeld, gradeLimit = gradeLimit, snap = snapEnd, endThere = world.joinable }
end

-- Carry out what the session asks for.
run = function(reqs : {sessions.Request})
	for _, r in ipairs(reqs) do
		if r == "openMode" then openModeWindow()
		elseif r == "closeMode" then closeModeWindow()
		elseif r == "closeConfirm" then closeConfirm()
		elseif r == "askBuild" then openConfirm()
		elseif r == "restart" then resetTool()
		end
	end
end

-- (a press counts once a frame, should it come both by onBack and by an IA_CLOSE_TOPMOST_WINDOW handler)
local backFrame : integer = nil
local function backAction(from : string)
	if backFrame ~= nil and backFrame == tool.frame then
		say("back: again by " .. from .. " in frame " .. tostring(tool.frame) .. ": ignored")
		return
	end
	backFrame = tool.frame
	run(sessions.back(sess, worldNow(false)))
end

-- Where the cursor is and how it is drawn, so the tool draws again when it moves.
local function cursorKey() : string
	local c = sessions.cursor(sess)
	if c == nil then return "-" end
	return string.format("%.1f,%.1f,%s", c.x, c.y, c.state)
end

-- Every 50 ms while the tool is open: the session's tick, then keep the ghost up to date.
-- Returns a key that changes whenever the tool must draw again.
local function toolTick() : string
	tool.tickFrame, tool.ticked = tool.frame or 0, true
	if tool.wantFocus ~= nil and tool.takeFocus ~= nil then
		local why = tool.wantFocus
		tool.wantFocus = nil
		tool.takeFocus(why)
	end
	run(sessions.tick(sess, worldNow(true)))
	if sess.phase == "done" and sessions.vertical(sess) then updateVBadges() else tool.vbadges = nil end
	updateGhost()
	local u, h = sess.drag, sess.hit
	return table.concat({ tostring(tool.opens or 0), sess.phase, G.ghost.key ~= nil and ghosts.viewKey(G) or "-", tool.screenKey or "-", sess.hoverMsg or "", tostring(G.ghost.cost), G.ghost.errors or "", tostring(G.ghost.built ~= nil),
		G.ghost.offending ~= nil and (G.ghost.offending.first .. ":" .. G.ghost.offending.last) or "-",
		sess.edit ~= nil and tostring(sess.edit.rev) or "-", u ~= nil and (u.kind .. u.i) or "-", h ~= nil and (h.kind .. tostring(h.i)) or "-",
		string.format("%.0f", sess.grab or 0), sess.editMsg or "",
		sess.mode as string or "-", tostring(sess.dragEl ~= nil), cursorKey() }, "|")
end

local function tooltip() : Builtin.ActionTooltipParam<any>
	local lines : {string} = {}
	local good, bad = false, false
	local vertical, g = sessions.vertical(sess), G.ghost
	local function path()
		local spacing = sess.edit ~= nil and edits.spacingProblem(sess.edit) or nil
		if spacing ~= nil then
			lines[#lines + 1] = cap(spacing)
				.. (vertical and "; drag it clear or right-click it away." or "; in vertical mode, drag it clear or right-click it away.")
			bad = true
		end
		local steep = sess.edit ~= nil and edits.gradeProblem(sess.edit, gradeLimit()) or nil
		if steep ~= nil then
			lines[#lines + 1] = cap(steep) .. (vertical and "; ease the red spans." or "; in vertical mode, ease the red spans.")
			bad = true
		end
		pathLines(lines, tool.line)
		if g.why ~= nil then lines[#lines + 1] = "No path: " .. g.why; bad = true end
		local bt = g.built
		if bt ~= nil and bt.check ~= nil then
			-- settled: what the game says of what is built (its warning: the buildings that go)
			local problems = ghosts.problems(bt.check)
			if problems ~= nil then for line in problems:gmatch("[^\n]+") do lines[#lines + 1] = line end end
			if bt.refused ~= nil then bad = true end
		elseif g.errors ~= nil then
			for line in g.errors:gmatch("[^\n]+") do lines[#lines + 1] = line end
			-- (a warning alone, such as the buildings that will go, is no fault)
			if g.critical or (g.hasErrors and not g.housesOnly) or g.collides then bad = true end
		end
	end
	if sess.phase == "from" then
		if sess.hover ~= nil then
			lines[1], good = "The new track starts here; then click where it should end.", true
		else
			lines[1] = "Track Geometry: click the ground or the end of a track to start."
			if sess.hoverMsg ~= nil then lines[2] = sess.hoverMsg end
		end
		if tool.buildMsg ~= nil then lines[#lines + 1] = tool.buildMsg; bad = true end
	elseif sess.phase == "to" then
		if sess.hover ~= nil then
			lines[1], good = "The new track ends here.", true
			path()
			if sess.hoverMsg ~= nil then lines[#lines + 1] = sess.hoverMsg; bad = true end -- (the last click, refused)
		else
			lines[1] = "Now click where the track should end."
			if sess.hoverMsg ~= nil then lines[2] = sess.hoverMsg end
		end
		lines[#lines + 1] = "Right-click or Esc to go back."
	elseif vertical then
		local d, h = sess.dragEl, sess.hit
		if d ~= nil then
			lines[1] = d.height and "Raising or lowering the elevation point (move the mouse up or down)."
				or "Sliding the elevation point along the track."
		elseif h == nil then
			lines[1] = "Press on the track to add an elevation point. Drag a point to slide it; Shift-drag for its height."
		end
		lines[#lines + 1] = string.format("Grade limit: %.0f ‰ (a drag keeps within it)", gradeLimit() * 1000)
		if sess.editMsg ~= nil then lines[#lines + 1] = sess.editMsg; bad = true end
		path()
	else
		local h = sess.drag or sess.hit
		if sess.drag ~= nil then
			lines[1] = "Dragging the " .. sessions.handleName(h) .. "."
		elseif h == nil then
			lines[1] = "Drag a turn, a curve's bracket or a ground end. Press on the track to add a turn."
			lines[2] = "The small window switches to the vertical profile."
			lines[3] = "Click off the track to build (you are asked first)."
		end
		if sess.editMsg ~= nil then lines[#lines + 1] = sess.editMsg; bad = true end
		path()
	end
	-- last: the controls for what is under the mouse
	local hint = sessions.hint(sess)
	if hint ~= nil then lines[#lines + 1] = hint end
	local param : ConstructionReactUtil.SimpleTooltipRecipeParams = {
		message = { message = table.concat(lines, "\n"), good = good and not bad, bad = bad },
		cost = g.built ~= nil and g.built.check ~= nil and g.built.check.cost or g.cost,
	}
	return { recipe = construction_react_util.SimpleTooltipRecipe as Recipe<any>, param = param }
end

-- The game's own curve speed limit of each of the ghost's m plan pieces (m/s; nil where it gives
-- none): the slowest edge of the transport network its edges would make. ProposalData.entity2tn is
-- keyed by the proposal's entity ids, and pieceOf says which plan piece each new edge belongs to
-- (tg_layout). This is the limit from the curve alone, before the track type caps it; the Speed
-- Limit layer only paints built track. (Found in the Gleis- und Straßenbauanzeige mod, mod.io 6418902.)
local function curveSpeeds(data : ProposalData, pieceOf : {integer : integer}, m : integer) : {number}
	return readout.pieceSpeeds(pieceOf, m, function(edge : integer) : number
		local ok, v = pcall(function() : number
			local tn = data.entity2tn[edge]
			if tn == nil then return nil end
			local best = math.huge
			for k = 1, #tn.edges do
				local lim = tn.edges[k].curveSpeedLimit
				if lim ~= nil and lim == lim and lim > 0 and lim < best then best = lim end
			end
			return best < math.huge and best or nil
		end)
		return ok and v as number or nil
	end)
end

-- The game's curve speed on a radius, for the Curve section (tg_speedprobe): a dry run of a short test
-- piece of that radius (4 pieces of 20 m, at the edit's start, turning left): the slowest
-- curveSpeedLimit of its edges, as the ghost's readout reads them. A failure (no data, or the call
-- throwing) is remembered per track type: the section then says the game gave no speed.
local PROBE_PIECES, PROBE_PIECE_LENGTH = 4, 20.0
gameSpeeds = speedprobes.new{
	key = function() : string return trackType().template end,
	ready = function() : boolean return sess.edit ~= nil end,
	minRadius = function() : number return sess.edit.dp.minRadius end,
	top = function() : number return trackType().speed end,
	log = say,
	measure = function(R : number) : number
		local a = sess.edit.a
		local nodes = speedprobes.testArc(a.x, a.y, alignment.atan2(a.dy or 0, a.dx or 1), R, PROBE_PIECE_LENGTH, PROBE_PIECES)
		local zs : {number} = {}
		local grades : {number} = {}
		for i = 1, #nodes do zs[i], grades[i] = a.z or 0, 0 end
		local p, pieceOf = layouts.make(nodes, { template = trackType().template, z = zs, grades = grades })
		if p == nil then return nil end
		local q = layouts.gathering(p as SimpleProposal)
		if q == nil then return nil end
		local d = api.engine.util.proposal.makeProposalData(q as any as Proposal, makeContext(false)) as ProposalData
		local best = math.huge
		for _, v in ipairs(curveSpeeds(d, pieceOf, PROBE_PIECES)) do
			if v ~= nil and v < best then best = v end
		end
		return best < math.huge and best or nil
	end,
}

------------------------------------------------------------------ curve badges

local BADGE_BG = { 0.16, 0.33, 0.55, 0.85 } -- as the track builder's own badges
local BADGE_SLOW = { 230 / 255, 109 / 255, 149 / 255, 0.95 } -- the slowest curve: the Speed Limit layer's "slow"
local BADGE_STEEP = { 0.8, 0.12, 0.12, 0.95 } -- a span too steep (past the grade limit)
local BADGE_TEXT = { 1, 1, 1, 1 }
local ICONS = "::/gui/construction/build_control/"
local RADIUS_ICON = "track_geometry_tool::/gui/icons/tg_radius.tga" -- our own: the game has a curved road icon, not a track one
local BADGE_W = 90 -- a badge's size on the screen, about (px): width, and height with three rows, two or one
local BADGE_H3 = 72
local BADGE_H2 = 50
local BADGE_H1 = 28
local BADGE_GAP = 10 -- the badge sits this far (px) up and left of its curve, clear of the handles

-- The track builder's slope icon for grade g: symbol_slope_-4 .. 4, a step per percent.
local function slopeIcon(g : number) : string
	local n = math.floor(math.abs(g) * 100 + 0.5)
	if n == 0 and math.abs(g) >= 0.001 then n = 1 end
	n = math.min(4, n)
	if g < 0 and n > 0 then n = -n end -- (never -0: Lua 5.2 prints it "-0", and there's no such icon)
	return ICONS .. "symbol_slope_" .. tostring(n) .. "_20.tga"
end

local function badgeRow(icon : string, text : string) : TreeNodeId
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			builtin.ImageView{ path = icon },
			builtin.TextView{ meta = { styleSheet = styleutil.makeStyle{ color = BADGE_TEXT } }, text = text },
		},
	}
end

-- A curve's badge: its radius (as Network Toolkit labels one), speed and grade; an elevation point's: its height and grade; halfway
-- between two: the grade.
local function badgeRows(b : readout.Badge) : {TreeNodeId}
	local grade = badgeRow(slopeIcon(b.grade), string.format("%+.0f ‰", b.grade * 1000))
	if b.kind == "point" then return { builtin.TextView{ meta = { styleSheet = styleutil.makeStyle{ color = BADGE_TEXT } }, text = string.format("%.1f m", b.z) }, grade } end
	if b.kind == "span" or b.kind == "grade" then return { grade } end
	-- (the game's curve limit, but no faster than the track itself)
	local top = trackType().speed
	local v = b.speed ~= nil and top > 0 and math.min(b.speed, top) or b.speed
	local speed = badgeRow(ICONS .. "symbol_speed_16.tga", v ~= nil and string.format("%.0f", v * 3.6) or "...")
	if b.radius == nil then return { speed, grade } end
	return { badgeRow(RADIUS_ICON, string.format("R %.0f m", b.radius)), speed, grade }
end

local function badgeView(b : readout.Badge) : TreeNodeId
	local style = styleutil.makeStyle{ backgroundColor = b.steep and BADGE_STEEP or b.slowest and BADGE_SLOW or BADGE_BG, anchorPoint = { 1.0, 1.0 } }
	style.padding = api.type.Vec4f.new(4, 2, 4, 2)
	local rows = builtin.BoxLayout{
		orientation = builtin.type.Orientation.Vertical,
		children = badgeRows(b),
	}
	-- (a curve's badge is a button, which takes the click over its whole area: it selects the curve and
	-- pops out the window. The others, and the curve badges of the profile, let the mouse through.)
	if b.kind == "curve" and b.turn ~= nil and not sessions.vertical(sess) then
		return builtin.Button{
			meta = { styleSheet = style },
			content = rows,
			onClick = function() run(sessions.pickCurve(sess, b.turn)) end,
		}
	end
	return builtin.Component{
		meta = { styleSheet = style },
		mouseTransparent = true, -- (the recipe's own setMouseTransparent doesn't reach its children)
		layout = rows,
	}
end

local record BadgesParam
	items : {ScreenBadge}
end

-- The curve badges over the whole screen, each at its curve (the mouse goes through them). The
-- full-screen recipe must return a layout (a Component here kills the GUI, v29). On its own the
-- layout shrinks to its badges, which then all sit at the left middle of the screen (v28), and a
-- size in its own meta is ignored (v30): tg_gui.css.lua stretches it over the screen (gravity).
local TgBadges = react.RegisterRecipe("TgBadges", function(p : BadgesParam) : TreeNodeId
	react.setMouseTransparent(true)
	react.setDisableFocusable(true)
	local children : {TreeNodeId} = {}
	for i, sb in ipairs(p.items or {}) do
		children[#children + 1] = builtin.FloatingLayoutChild{ h = sb.h, v = sb.v, localKey = tostring(i), item = badgeView(sb.badge) }
	end
	return builtin.FloatingLayout{ children = children }
end)

-- Every frame, from TgProbe (world2Screen is refused elsewhere): put the badges on the screen.
local function placeBadges()
	local l = tool.line
	local list, key : {readout.Badge}, string
	if sessions.vertical(sess) and sess.phase == "done" then
		list, key = tool.vbadges, "v" .. tostring(sess.edit.rev)
	elseif l ~= nil and G.ghost.info ~= nil then
		list, key = l.readout.badges, l.key
	end
	if list == nil or #list == 0 then
		tool.screen, tool.screenKey = nil, nil
		return
	end
	local size = api.gui.camera.getSize()
	local w, h = size.x, size.y
	if w <= 0 or h <= 0 then return end
	-- (where they go on the screen changes only with the camera, the screen or the badges: about
	-- a hundred world2Screen calls a frame on a long track are kept for when one of them does)
	local cam = api.gui.camera.getCameraData()
	local view = string.format("%s|%d|%.4f,%.4f,%.4f,%.5f,%.5f|%.0fx%.0f", key, #list, cam.x, cam.y, cam.z, cam.w, cam.q, w, h)
	if view == tool.placedView and tool.screen ~= nil then return end
	tool.placedView = view
	local out : {ScreenBadge} = {}
	local keys : {string} = {}
	local taken : {{number}} = {} -- screen boxes of the badges placed so far: x, y (their corner), height
	local function free(x : number, y : number, bh : number) : boolean
		for _, t in ipairs(taken) do
			if math.abs(x - t[1]) < BADGE_W and y > t[2] - t[3] and y - bh < t[2] then return false end
		end
		return true
	end
	-- (the curves and points first; the badges along the path only where they do not cover one)
	for pass = 1, 3 do
	for _, b in ipairs(list) do
		local prio = (b.kind == "curve" or b.kind == "point") and 1 or b.kind == "span" and 2 or 3
		local p = prio == pass and api.gui.camera.world2Screen(api.type.Vec3f.new(b.x, b.y, b.z)) or nil
		local bh = (b.kind == "span" or b.kind == "grade") and BADGE_H1 or b.radius ~= nil and BADGE_H3 or BADGE_H2
		if p ~= nil and p.x >= 0 and p.x <= w and p.y >= 0 and p.y <= h and free(p.x, p.y, bh) then
			taken[#taken + 1] = { p.x, p.y, bh }
			out[#out + 1] = { h = (p.x - BADGE_GAP) / w, v = (p.y - BADGE_GAP) / h, badge = b }
			-- (to the pixel: a fraction of one is no reason to draw the tool again)
			keys[#keys + 1] = string.format("%.0f,%.0f", p.x, p.y)
		end
	end
	end
	tool.screen, tool.screenKey = out, key .. ":" .. table.concat(keys, ";")
end

------------------------------------------------------------------ gizmos

local COLORS : {string : {number}} = {
	leg = { 0.949, 0.663, 0.0, 0.5 }, -- the PI polyline (#f2a900, the thumbnail's amber)
	free = { 0.949, 0.663, 0.0, 1.0 }, -- turns
	ray = { 0.3, 0.8, 1.0, 1.0 },
	fixed = { 0.635, 0.663, 0.675, 1.0 }, -- the thumbnail's grey (#a2a9ac)
	bracket = { 0.3, 1.0, 0.4, 1.0 },
	groundEnd = { 0.949, 0.663, 0.0, 1.0 }, -- a ground end: it moves anywhere, like a free turn
	hot = { 1.0, 1.0, 1.0, 1.0 }, -- under the mouse or dragged
	selected = { 1.0, 1.0, 0.1, 1.0 }, -- the selected elevation point (the mode window sets its height)
	tooClose = { 1.0, 0.15, 0.15, 0.4 }, -- an elevation point too close to a neighbour or an end
	osculating = { 0.32, 0.72, 0.92, 0.5 }, -- a curve's osculating circle, the blue of its arc (#52b8ea)
	spiral = { 0.902, 0.435, 0.784, 0.5 }, -- a transition spiral (#e66fc8, the thumbnail's pink)
	sketch = { 0.55, 0.85, 1.0, 0.9 }, -- the path while the mouse moves it (no ghost)
	refused = { 1.0, 0.15, 0.15, 0.9 }, -- the section a bare refusal comes from (the game's error colour)
}

-- e in colour c, width wide, drawn in steps `step` long (m).
local function paint(e : Builtin.Type.EdgeRenderable.Edge, c : {number}, width : number, step : number) : Builtin.Type.EdgeRenderable.Edge
	e.colors = { api.type.Vec4f.new(c[1], c[2], c[3], c[4]), api.type.Vec4f.new(c[1], c[2], c[3], c[4]) }
	e.width = width
	e.offsetZ = 1.0
	e.stepSize = step
	return e
end

-- A gizmo circle of radius r around (x, y, z), drawn in steps `step` long (m).
local function circleEdge(x : number, y : number, z : number, r : number, c : {number}, width : number, step : number) : Builtin.Type.EdgeRenderable.Edge
	local g = api.type.EdgeGeometry.new()
	g.type = api.type.EdgeGeometry.Type.ARC
	local arc = api.type.EdgeGeometry.Arc.new()
	arc.center = api.type.Vec2f.new(x, y)
	arc.radius = r
	arc.startAngle = 0
	arc.angle = 2 * math.pi
	g.arc = arc
	g.height = api.type.Vec2f.new(z, z)
	g.tangent = api.type.Vec2f.new(0, 0)
	g.length = 2 * math.pi * r
	g.width = 1.0
	return paint(builtin.type.EdgeRenderable.Edge.new(g), c, width, step)
end

-- A straight gizmo line from (x0, y0, z0) to (x1, y1, z1).
local function straightEdge(x0 : number, y0 : number, z0 : number, x1 : number, y1 : number, z1 : number, c : {number}, width : number, step : number) : Builtin.Type.EdgeRenderable.Edge
	local g = api.type.EdgeGeometry.new()
	g.type = api.type.EdgeGeometry.Type.STRAIGHT
	local st = api.type.EdgeGeometry.Straight.new()
	st.pos = { api.type.Vec2f.new(x0, y0), api.type.Vec2f.new(x1, y1) }
	g.straight = st
	g.height = api.type.Vec2f.new(z0, z1)
	g.tangent = api.type.Vec2f.new(0, 0)
	g.length = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2 + (z1 - z0) ^ 2)
	g.width = 1.0
	return paint(builtin.type.EdgeRenderable.Edge.new(g), c, width, step)
end

-- A circle is drawn in at least this many steps' worth of its length, at most: an osculating
-- circle is kilometres round, and in 1 m steps it alone made tens of thousands (360 steps of a
-- 3 km circle stray 0.1 m from it, under the line's width).
local CIRCLE_STEPS = 360

-- What the gizmos are drawn from (tg_gizmos.of): they are made again only when it changes, not on
-- every redraw (the badges moving with the camera, the tooltip), as each is several game objects.
local function gizmoKey() : string
	local e = sess.edit
	if e == nil then return "-" end
	local h, d, el = sess.hit, sess.drag, sess.dragEl
	return table.concat({ tostring(e), tostring(e.rev), sess.mode as string or "-", string.format("%.2f", sess.grab or 0),
		h ~= nil and (h.kind .. tostring(h.i)) or "-", d ~= nil and (d.kind .. tostring(d.i)) or "-",
		el ~= nil and tostring(el.i) or "-", tostring(sess.selected) }, "|")
end


-- From one build of the gizmos to the next, each shape's edges and the ground at each point it
-- was read at are kept: a drag moves one turn, so only its legs, curve and brackets change, and
-- the other legs (60 pieces each on a long one, each point over the ground) are as they were.
local record GizmoCache
	last : {string : {Builtin.Type.EdgeRenderable.Edge}} -- the last build's edges, by its gizmoKey
	shapes : {string : {Builtin.Type.EdgeRenderable.Edge}} -- each shape's edges, by its shapeKey
	ground : {string : number} -- the ground read at each point, last build
	groundNow : {string : number} -- ...and this one
end
local gz : GizmoCache = { last = {}, shapes = {}, ground = {}, groundNow = {} }

local function keptGround(x : number, y : number) : number
	local k = string.format("%.3f,%.3f", x, y)
	local z = gz.groundNow[k] or gz.ground[k]
	if z == nil then z = zAt(x, y) end
	gz.groundNow[k] = z
	return z
end

local function shapeKey(s : gizmos.Shape) : string
	local head = string.format("%s|%s|%g|%g", s.kind as string, s.color, s.width, s.step)
	if s.kind == "circle" then return head .. string.format("|%.3f,%.3f,%.3f,%.3f", s.x, s.y, s.z, s.r) end
	local parts : {string} = { head }
	for _, p in ipairs(s.pts) do parts[#parts + 1] = string.format("%.3f,%.3f,%.3f", p[1], p[2], p[3]) end
	return table.concat(parts, "|")
end

-- The edges of shape s: a circle as one, a line as one straight per pair of its points (each in one
-- step: a straight drawn in finer steps looks the same).
local function edgesOf(s : gizmos.Shape) : {Builtin.Type.EdgeRenderable.Edge}
	local c = COLORS[s.color]
	if s.kind == "circle" then
		return { circleEdge(s.x, s.y, s.z, s.r, c, s.width, math.max(s.step, 2 * math.pi * s.r / CIRCLE_STEPS)) }
	end
	local out : {Builtin.Type.EdgeRenderable.Edge} = {}
	for k = 1, #s.pts - 1 do
		local p, q = s.pts[k], s.pts[k + 1]
		local len = math.sqrt((q[1] - p[1]) ^ 2 + (q[2] - p[2]) ^ 2 + (q[3] - p[3]) ^ 2)
		out[#out + 1] = straightEdge(p[1], p[2], p[3], q[1], q[2], q[3], c, s.width, math.max(s.step, len))
	end
	return out
end

local SKETCH_EVERY = 50.0 -- the sketch is drawn in straights this long (m): 0.3 m off a 1 km curve
local SKETCH_WIDTH = 2.5

-- The whole path of plan as a line (a sketch): straights through its dense nodes every
-- SKETCH_EVERY, and its last, at the track's height.
sketchLine = function(plan : plans.Plan) : {Builtin.Type.EdgeRenderable.Edge}
	local dn, dz = plan.dense.nodes, plan.dense.z
	local out : {Builtin.Type.EdgeRenderable.Edge} = {}
	local last : {number} = nil
	local lastS = -math.huge
	for i, nd in ipairs(dn) do
		if i == 1 or i == #dn or nd.s - lastS >= SKETCH_EVERY then
			local q = { nd.x, nd.y, dz[i] }
			if last ~= nil then
				local len = math.sqrt((q[1] - last[1]) ^ 2 + (q[2] - last[2]) ^ 2 + (q[3] - last[3]) ^ 2)
				if len > 0.01 then out[#out + 1] = straightEdge(last[1], last[2], last[3], q[1], q[2], q[3], COLORS.sketch, SKETCH_WIDTH, len) end
			end
			last, lastS = q, nd.s
		end
	end
	return out
end

-- Pieces j..k of a plan's nodes as a line in the error colour, at the track's height.
pieceLine = function(nodes : {alignment.Sample}, z : {number}, j : integer, k : integer) : {Builtin.Type.EdgeRenderable.Edge}
	local out : {Builtin.Type.EdgeRenderable.Edge} = {}
	for i = j, k do
		local p, q = nodes[i], nodes[i + 1]
		local len = math.sqrt((q.x - p.x) ^ 2 + (q.y - p.y) ^ 2 + (z[i + 1] - z[i]) ^ 2)
		if len > 0.01 then out[#out + 1] = straightEdge(p.x, p.y, z[i], q.x, q.y, z[i + 1], COLORS.refused, SKETCH_WIDTH, len) end
	end
	return out
end

-- The gizmos of the edit (tg_gizmos), as edges.
local function gizmoEdges() : {Builtin.Type.EdgeRenderable.Edge}
	local key = gizmoKey()
	local cached = gz.last[key]
	if cached ~= nil then return cached end
	gz.groundNow = {}
	local shapes = gizmos.of(sess, keptGround)
	gz.ground = gz.groundNow -- (only what this build read: the rest is not drawn now)
	local made : {string : {Builtin.Type.EdgeRenderable.Edge}} = {}
	local edges : {Builtin.Type.EdgeRenderable.Edge} = {}
	for _, s in ipairs(shapes) do
		local k = shapeKey(s)
		local es = made[k] or gz.shapes[k] or edgesOf(s)
		made[k] = es
		for _, ed in ipairs(es) do edges[#edges + 1] = ed end
	end
	gz.shapes = made
	gz.last = { [key] = edges } -- (only the last: the old ones are not drawn again)
	return edges
end

-- The cursor as the game's track builder draws its control point (a ProposalViewer holds one): a
-- white dot on ground, a blue dot over a track end, a white dot ringed blue while dragging. Idle
-- and IdleOverEdge shrink their dot as the radius grows on screen, so radius 0 keeps it whole (NOTES).
-- At its own height, else the ground's there.
local function controlPoint(c : sessions.Cursor) : Builtin.Type.ControlPointInfo
	local S = builtin.type.ControlPointInfo.State
	local states : {sessions.CursorState : Builtin.Type.ControlPointInfo.State} = {
		ground = S.Idle, trackEnd = S.IdleOverEdge, handle = S.Hover, dragging = S.Dragging,
	}
	return builtin.type.ControlPointInfo.new(api.type.Vec3f.new(c.x, c.y, c.z or zAt(c.x, c.y)), 1.0, 0.0, states[c.state])
end

-- Esc that is not the tool's own: close the construction menu, as Esc does for the game's builder.
-- The menu's abort alone does not: in mouse mode it only picks the same entry again, which opens
-- the tool again, and leaves Esc to the menu's own IA_MENU_BACK, which sees it only while the
-- keyboard focus is in the menu (not after a click in the world). So also raise the event the
-- menu's quit raises (construction.tl), which pops the construction tool.
local fireReactEvent = ((api.gui as {string : any}).fireReactEvent) as function(string, any)
local function closeMenu(abort : function())
	abort()
	if fireReactEvent == nil then
		say("esc: no api.gui.fireReactEvent: the menu stays open")
		return
	end
	local ok, err = pcall(function() : boolean fireReactEvent("constructionMenuQuit", nil); return true end)
	if not ok then say("esc: closing the menu: " .. tostring(err)) end
end

-- The tool in the world: the selector (clicks), the ghost, the gizmos, the cursor and the tooltip.
local function toolAction(abort : function()) : TreeNodeId
	tool.active = true
	-- Picking another track entry opens that entry's tool before the last one's closes (seen in
	-- game: the new entry's tool ran, then the old one unmounted). The tool's state is shared, so
	-- only the last one open to close puts it away: else the open one counts as closed, and
	-- every "back" (Esc, right-click) is left to the menu, which quits.
	react.onMount(function(_ : any)
		tool.active, tool.mounted = true, (tool.mounted or 0) + 1
		if tool.takeFocus ~= nil then tool.takeFocus("open") end
	end)
	react.onUnmount(function(_ : any)
		tool.mounted = math.max((tool.mounted or 1) - 1, 0)
		if tool.mounted > 0 then return end
		closeConfirm()
		closeModeWindow()
		tool.active, tool.ticked, tool.opens = false, false, (tool.opens or 0) + 1
		sessions.blur(sess)
	end)
	local key = engine_react_util.useStepStateTimer(toolTick, 0.05)
	local _ = key:old()
	local children : {TreeNodeId} = {
		builtin.Selector{
			onHover = function(entity : Engine.Entity, _i : {integer}, _d : Gui.SelectionDetails)
				tool.hovered = entity
			end,
			onSelect = function(entity : Engine.Entity, _i : {integer}, _d : Gui.SelectionDetails) : boolean
				tool.hovered = entity
				run(sessions.click(sess, worldNow(false)))
				return true
			end,
			onSelectSecondary = function(_e : Engine.Entity, _i : {integer}, _d : Gui.SelectionDetails) : boolean
				-- (claims the click but never acts: the click's one "back" does, by onBack; acting here
				-- too would take that "back" for an Esc)
				return sessions.canGoBack(sess)
			end,
			filter = world.isTrackEdge,
			-- a left click anywhere counts (the selector alone only reports clicks on a track piece)
			onProcessMouseEvent = function(evt : Gui.Mouse.Event) : boolean
				local T = api.gui.mouse.Event.Type
				local kind : sessions.MouseKind = evt.type == T.Pressed and "pressed" or evt.type == T.Released and "released"
					or evt.type == T.Clicked and "clicked" or evt.type == T.Moved and "moved" or "other"
				if evt.button == 0 and kind == "pressed" and tool.takeFocus ~= nil then tool.takeFocus("press") end
				local took, reqs = sessions.mouse(sess, worldNow(false), evt.button, kind, evt.y)
				run(reqs)
				return took
			end,
		},
	}
	-- until the first tick, what the tool holds is from when it was last open: draw none of it
	-- (no ghost, gizmos, badges or tooltip for that one frame)
	local fresh = tool.ticked == true
	-- never hand the game a ghost that names a node that is gone or no longer a free end (on
	-- reopening, the first render comes before the tick that drops such an end); only one
	-- ProposalViewer at a time
	-- the cursor: the control point (none when making it fails)
	local cur = fresh and sessions.cursor(sess) or nil
	local cp = cur ~= nil and guard("cursor", function() : Builtin.Type.ControlPointInfo return controlPoint(cur) end) or nil
	local gh = G.ghost
	local viewer = false
	local a, b = sessions.ends(sess)
	if fresh and gh.proposal ~= nil and world.joinable(a) and world.joinable(b) and world.joinable(sess.hover) then
		local gk = ghosts.viewKey(G)
		viewer = true
		children[#children + 1] = builtin.ProposalViewer{
			simpleProposal = gh.proposal,
			controlPointInfo = cp,
			onCreateProposalData = function(data : ProposalData, _p : Proposal)
				if data == nil or not ghosts.onData(G, gk, checkOf(data, nil)) then return end
				-- (the readout: the ghost's own first check gives its curve speeds)
				local l = tool.pending
				if l ~= nil and l.key == G.ghost.key then
					local r, bwhy = plans.readout(l.plan, curveSpeeds(data, l.pieceOf, #l.plan.built.nodes - 1))
					if bwhy ~= nil then say("badges: " .. bwhy) end
					tool.line, tool.pending = { key = G.ghost.key, readout = r }, nil
				end
			end,
			entityForRefundableContext = api.engine.util.getPlayer(),
			proposalId = "track_geometry_tool_ghost_" .. gk,
		}
	end
	-- no ghost: an empty proposal holds the control point
	if cp ~= nil and not viewer then
		children[#children + 1] = builtin.ProposalViewer{
			simpleProposal = api.type.SimpleProposal.new(),
			controlPointInfo = cp,
			proposalId = "track_geometry_tool_cursor",
		}
	end
	local edges = fresh and sess.phase == "done" and guard("gizmo", gizmoEdges) or {}
	if fresh and tool.sketchEdges ~= nil and #tool.sketchEdges > 0 and G.ghost.sketch then
		-- (the gizmos' own list is kept between builds: a new one, the sketch first, under them)
		local all : {Builtin.Type.EdgeRenderable.Edge} = {}
		for _, ed in ipairs(tool.sketchEdges) do all[#all + 1] = ed end
		for _, ed in ipairs(edges) do all[#all + 1] = ed end
		edges = all
	end
	local off = gh.offending
	if fresh and off ~= nil and tool.sectionEdges ~= nil and not gh.sketch then
		-- (the section a bare refusal comes from, over the ghost)
		local hk = string.format("%s|%d:%d|%s", tostring(gh.key), off.first, off.last, tostring(tool.sectionEdges)) -- (a ghost made again in place has new closures)
		if tool.hl == nil or tool.hl.key ~= hk then
			local okH, hl = pcall(tool.sectionEdges, off.first, off.last)
			tool.hl = { key = hk, edges = okH and hl as {Builtin.Type.EdgeRenderable.Edge} or {} }
			if not okH then say("ghost: the highlight: " .. tostring(hl)) end
		end
		local all : {Builtin.Type.EdgeRenderable.Edge} = {}
		for _, ed in ipairs(edges) do all[#all + 1] = ed end
		for _, ed in ipairs(tool.hl.edges) do all[#all + 1] = ed end
		edges = all
	end
	if #edges > 0 then
		children[#children + 1] = builtin.EdgeRenderable{ edges = edges, ignoreDepth = true }
	end
	if fresh and tool.screen ~= nil and #tool.screen > 0 then
		children[#children + 1] = builtin.FullScreenComponent{ recipe = TgBadges as Recipe<any>, param = { items = tool.screen } as BadgesParam }
	end
	if fresh then children[#children + 1] = builtin.ActionTooltip(tooltip()) end
	local param : Builtin.ActionDescriptorParam = {
		tool = "construction",
		onBack = function()
			if sess.confirmOpen then return end -- (the window takes Esc itself: Cancel)
			if sessions.backIsOurs(sess) then backAction("onBack") return end
			say("back: not the tool's (" .. sess.phase .. "): closing the menu")
			closeMenu(abort)
		end,
		terrainCirclePolicy = "Never",
		children = children,
	}
	-- (mouseCursor is missing from the game's ActionDescriptorParam def; its own tools pass it)
	;(param as {string : any}).mouseCursor = RAIL_CURSOR
	return builtin.ActionDescriptor(param)
end

-- The tool as a track entry's action. The menu calls this only for the picked entry, so here is
-- where the tool learns which track to build.
local function hostedAction(params : ConstructionCustomActionParams<any>, entry : string) : TreeNodeId
	tool.gameCtx = params.gameCtx
	if entry ~= tool.entry then
		say("track type: " .. entry)
		-- (the click on the entry left the focus in the menu)
		if tool.entry ~= nil then tool.wantFocus = "track type picked" end
	end
	tool.entry = entry
	geo.hosted = true
	return toolAction(params.abort)
end

------------------------------------------------------------------ the game's track builder

local function geoKey() : string
	return geoWanted() and "on" or "off"
end

-- A track entry's recipe (decorate gives it to every track entry of the game's builder).
-- The menu runs it for every entry it shows, each with `isActive` (construction.tl), and keeps
-- an action per entry; only the picked entry's is used. With Geometry on, the tool is bound as
-- the entry's action; with it off, or on the Replace Track tab, the binding is taken away and
-- the menu falls back to the game's own action (construction.tl, propagateActionFn).
local TgTrackAction = react.RegisterRecipe("TgTrackAction", function(params : ConstructionCustomActionParams<any>) : TreeNodeId
	-- (the row is read every 100 ms: flipping it binds or unbinds without another click)
	local key = engine_react_util.useStepStateTimer(geoKey, 0.1)
	local _ = key:old()
	local bound = react.useRef(false) as ReactRefT<boolean>
	local function unbind()
		if not bound:get() then return end
		bound:set(false)
		-- (the menu's list may be gone already when this entry unmounts)
		local ok, err = pcall(function() : boolean params.setActionFn(nil); return true end)
		if not ok then say("geometry mode: unbind: " .. tostring(err)) end
	end
	react.onUnmount(function(_ : any) unbind() end)
	if not (params.isActive and geoWanted()) then
		-- (Geometry flipped to No, or the Replace Track tab: an alignment being edited is
		-- dropped, unasked, once for all the entries. Not on unmount: picking another entry
		-- keeps it.)
		if bound:get() and geo.hosted and not geoWanted() then
			geo.hosted = false
			startOver()
		end
		unbind()
		return nil
	end
	react.setRestrictMouseFocus(true)
	local entry = params.definition.resName as string
	-- (a "back" that is not ours must say Disabled: a plain false keeps the key and does nothing)
	local IAS = api.gui.inputAction.InputActionState
	react.useInputAction("IA_CLOSE_TOPMOST_WINDOW", react.iaHandler(function() backAction("IA_CLOSE_TOPMOST_WINDOW") end, function() : Gui.InputAction.InputActionState
		return sessions.backIsOurs(sess) and IAS.Enabled or IAS.Disabled
	end))
	bound:set(true)
	-- (one key for every entry: the tool stack keeps the action's node and only swaps the fn while
	-- the key stays (ToolStackEntryWrap, builtin.lua). A key per entry, as the game's own custom
	-- actions have, makes a new node on each switch of track type: the new tool mounts before the
	-- old one unmounts, and the old one's unmount puts away the state they share.)
	params.setActionFn(function() : TreeNodeId return hostedAction(params, entry) end, "TgTrackAction")
	return nil
end)

local ENABLED : ConstructionMenuParam.CheckEnabledResult = "Enabled"
local DISABLED : ConstructionMenuParam.CheckEnabledResult = "Disabled"

-- The "Track Geometry" row, placed and kept as Real Track Cant's Cant row: one value in every category,
-- not reset by the menu, saved nowhere. The panel asks the row whether it is enabled with all
-- its values, on every look: that is where the tool reads them (the Replace Track tab is mode 2;
-- a custom action is given only the Settings window's values).
local function geoParam() : ConstructionMenuParam
	local p : ConstructionMenuParam = {
		key = GEO_KEY,
		group = "settings",
		name = "Track Geometry",
		-- (the game does not break a tooltip's lines itself)
		tooltip = "Lay the track with the Track Geometry tool instead of the built-in track builder tool.",
		values = { "Off", "On" },
		numbers = { 0, 1 },
		defaultIndex = geo.on and 2 or 1,
		yearFrom = 0,
		yearTo = 0,
		uiType = api.type["enum"].ScriptParamType.Button,
		location = api.type["enum"].ScriptParamLocation.Toolbar,
		preserveValueInAllCategories = true,
		resetOnCategoryChange = false,
		resetOnMenuClose = false,
		resetOnDefinitionChange = false,
		checkEnabledFn = function(ps : {string : number}) : ConstructionMenuParam.CheckEnabledResult
			geo.panel = ps
			if ps[GEO_KEY] ~= nil then geo.on = ps[GEO_KEY] == 1 end
			return onWandTab(ps) and DISABLED or ENABLED
		end,
		onChangeFn = function(v : number, _a : ConstructionMenuParamsAPI, _o : number)
			geo.on = v == 1
		end,
	}
	-- (`id` is missing from the game's ConstructionMenuParam def; its own rows pass it)
	;(p as {string : any}).id = GEO_KEY
	return p
end

-- The "Alignment" row, kept as the Track Geometry row: which alignment the tool edits (the session's
-- mode). Greyed out unless the tool has the builder's place. A switch to Profile while editing opens
-- the mode window (from the row's click: never from onStep); a switch to Path changes its section.
local function alignParam() : ConstructionMenuParam
	local p : ConstructionMenuParam = {
		key = ALIGN_KEY,
		group = "settings",
		name = "Alignment",
		tooltip = "Path: edit the horizontal alignment (curves and straights).\nProfile: edit the vertical alignment (heights and grades).",
		values = { "Path", "Profile" }, -- (the row is too narrow for "Horizontal")
		numbers = { 0, 1 },
		defaultIndex = sessions.vertical(sess) and 2 or 1,
		yearFrom = 0,
		yearTo = 0,
		uiType = api.type["enum"].ScriptParamType.Button,
		location = api.type["enum"].ScriptParamLocation.Toolbar,
		preserveValueInAllCategories = true,
		resetOnCategoryChange = false,
		resetOnMenuClose = false,
		resetOnDefinitionChange = false,
		checkEnabledFn = function(ps : {string : number}) : ConstructionMenuParam.CheckEnabledResult
			return (ps[GEO_KEY] == 1 and not onWandTab(ps)) and ENABLED or DISABLED
		end,
		onChangeFn = function(v : number, _a : ConstructionMenuParamsAPI, _o : number)
			local m = MODES[math.floor(v + 0.5) + 1]
			if m == nil then return end
			sessions.setMode(sess, m)
			if sessions.vertical(sess) then openModeWindow() end
		end,
	}
	;(p as {string : any}).id = ALIGN_KEY
	return p
end

local function hasGeoRow(def : ConstructionDefinition) : boolean
	for _, p in ipairs(def.params or {}) do
		if p.key == GEO_KEY then return true end
	end
	return false
end

-- Give every track entry of the game's builder the Track Geometry row and the recipe (an entry with
-- another mod's custom action is left alone).
local function decorate(defs : {ConstructionDefinition})
	for _, def in ipairs(defs) do
		local ours = hasGeoRow(def)
		if def.action == "ACTION_TRACK_BUILDER_UPGRADER" and (ours or def.customAction == nil) then
			if not ours then
				def.params = def.params or {}
				table.insert(def.params, geoParam())
				table.insert(def.params, alignParam())
			end
			def.customAction = { recipe = TgTrackAction as Recipe<ConstructionCustomActionParams<any>>, customParam = nil }
		end
	end
end

-- Wrap construction_react_util's `name` once: wrap(orig, call) makes the wrapper, where call(x)
-- runs whichever hook was stored last under `slot` (an error is logged), so a reloaded copy of
-- this file takes over. true when it wrapped now.
local function wrapOnce(name : string, slot : string, hook : any, wrap : function(orig : any, call : function(any)) : any) : boolean
	local cru = construction_react_util as {string : any}
	local orig = cru[name]
	if orig == nil then say("geometry mode: no " .. name .. " to hook"); return false end
	local first = cru[slot] == nil
	cru[slot] = hook
	if not first then return false end
	cru[name] = wrap(orig, function(x : any)
		local ok, err = pcall(function() : boolean (cru[slot] as function(any))(x); return true end)
		if not ok then say("geometry mode: " .. name .. ": " .. tostring(err)) end
	end)
	return true
end

-- The track panel's rows that stay usable in Geometry mode: the builder / wand tabs, the bridge
-- and tunnel types, Snapping, Geometry and Alignment. Every other row, the game's or another mod's, belongs
-- to the drag builder.
local GEO_ROWS : {string : boolean} = { mode = true, bridgeType = true, tunnelType = true, disableSnapping = true, [GEO_KEY] = true, [ALIGN_KEY] = true }

-- The rows already greyed (weak: the menu makes new definitions on each opening).
local greyed : {ConstructionMenuParam : boolean} = setmetatable({}, { __mode = "k" })

-- Grey a row out while Track Geometry is On on the builder tab. A row the game or its mod hides or
-- greys stays so; with Geometry on No, or on the wand tab, the row says what it said before.
local function greyInGeometry(p : ConstructionMenuParam)
	if greyed[p] then return end
	greyed[p] = true
	local orig = p.checkEnabledFn
	p.checkEnabledFn = function(ps : {string : number}) : ConstructionMenuParam.CheckEnabledResult
		local r = ENABLED
		if orig ~= nil then r = orig(ps) end
		if r == ENABLED and ps[GEO_KEY] == 1 and not onWandTab(ps) then return DISABLED end
		return r
	end
end

local function greyDragRows(def : ConstructionDefinition)
	if not hasGeoRow(def) then return end
	for _, p in ipairs(def.params) do
		if not GEO_ROWS[p.key] then greyInGeometry(p) end
	end
end

-- Loaded with the game's GUI (tg_menu.res.lua); draws nothing. It decorates the game's list of
-- track entries (as Real Track Cant adds its Cant row), and greys the drag builder's rows as the
-- menu gathers its entries (forEachDefinition), after every mod's getTrackDefinitions wrapper has
-- run, so the rows other mods add are reached whatever the load order.
local TgMenuPlugin = react.RegisterPluginRecipe(mod_entry_point.ModEntryPointExtension, "TgMenuPlugin", function() : TreeNodeId
	if wrapOnce("getTrackDefinitions", "__tgDecorate", decorate, function(orig : any, call : function(any)) : any
		return function() : {ConstructionDefinition}
			local defs = (orig as function() : {ConstructionDefinition})()
			call(defs)
			return defs
		end
	end) then say("geometry mode: row added to the track entries") end
	wrapOnce("forEachDefinition", "__tgGrey", greyDragRows, function(orig : any, call : function(any)) : any
		return function(fn : function(ConstructionDefinition), repository : ConstructionActionRepository)
			(orig as function(function(ConstructionDefinition), ConstructionActionRepository))(function(def : ConstructionDefinition)
				call(def)
				fn(def)
			end, repository)
		end
	end)
	return builtin.FloatingLayout{ children = {} }
end)

------------------------------------------------------------------ bottom bar

local TgProbe = react.RegisterRecipe("TgProbe", function() : TreeNodeId
	-- (as startOver, but it touches no window: it only marks the confirm window closed)
	react.useRefLazy(function() : boolean sessions.confirmClosed(sess); sessions.reset(sess); resetTool(); return true end)
	-- The keyboard focus. "Back" (Esc, and a right-click) goes from the focused node up; left on
	-- the menu (after a click on a track entry in its list) it reaches the menu's IA_MENU_BACK,
	-- which quits the menu, and onBack never comes (seen in game: every right-click and Esc after
	-- picking another track type quit it, also after reopening the tool). The tool's own node
	-- cannot take the focus (focus() on it did nothing, seen in game; the tool stack is not
	-- focusable), so this node takes it when the tool opens, on each left press, and after
	-- another entry is picked, and takes "back" here while it is the tool's.
	react.setForceFocusable(true)
	local selfRef = react.useSelfRef()
	tool.takeFocus = function(why : string)
		local ok, err = pcall(function() : boolean
			local n = selfRef:get()
			if n == nil then return false end
			n:focus()
			return true
		end)
		if not ok then say("focus: on " .. why .. ": " .. tostring(err)) end
	end
	local IAS = api.gui.inputAction.InputActionState
	local function ours() : Gui.InputAction.InputActionState
		return sessions.backIsOurs(sess) and IAS.Enabled or IAS.Disabled
	end
	-- (IA_CLOSE_TOPMOST_WINDOW has the same keys as IA_MENU_BACK and comes first: seen in game,
	-- every Esc and right-click came by it here)
	react.useInputAction("IA_CLOSE_TOPMOST_WINDOW", react.iaHandler(function() backAction("probe") end, ours))
	-- the ground under the mouse can only be read here: in the tool's own timer the game refuses it
	react.onStep(function()
		tool.frame = (tool.frame or 0) + 1
		if not tool.active then return end
		local ok, pos = pcall(function() : Vec3f
			if not api.gui.mouse.hasTerrainPosition() then return nil end
			return api.gui.mouse.getTerrainPosition()
		end)
		if ok and pos ~= nil then tool.terrX, tool.terrY, tool.terrZ = pos.x, pos.y, pos.z else tool.terrX, tool.terrY, tool.terrZ = nil, nil, nil end
		local eok, eye = pcall(function() : Vec3f return api.gui.camera.getEye() end)
		tool.eye = eok and eye or nil
		guard("badges", placeBadges as function() : any)
	end)
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Horizontal, children = {} }
end)

return {
	TgProbe = TgProbe,
	TgMenuPlugin = TgMenuPlugin,
}
