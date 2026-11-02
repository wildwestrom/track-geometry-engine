-- GUI. Two parts:
--   TgTool : "Track Geometry" in the construction menu, Tracks -> Tools (tg_tool.res.lua). Click a
--            free track end, then another one. The new track leaves the first end along its
--            heading and arrives at the second along its heading (tg_ends); the game's
--            see-through ghost shows it and its cost. Then edit it (tg_edit): drag a turn (circle)
--            or a curve's bracket (tick), press on the track to add a turn and drag it, right-click
--            a turn to remove it (right-click does nothing elsewhere). Click anywhere else to build it:
--            a window shows what will be built and its cost, and asks first. Esc steps back. A badge at each curve shows the game's curve speed limit and the grade
--            there, and the tooltip sums them up (tg_readout).
--   TgProbe : an invisible-ish plugin in the bottom game bar (tg_probe.res.lua). It reads the
--            ground under the mouse and places the curve badges on the screen every frame for the
--            tool (both only allowed there).

local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local styleutil = ug_require "::/gui/main/styleutil.tl" as StyleUtil
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local construction_react_util = ug_require "::/gui/construction/construction_react_util.tl" as ConstructionReactUtil
local dialog_react_util = ug_require "::/gui/menu/dialog_react_util.tl" as DialogReactUtil
local menu_category_util = ug_require "::/gui/main/menu_category_util.tl" as MenuCategoryUtil
local geometry = require("westrom_track_geometry::/track_geometry/tg_geometry.script.tl")
local alignment = require("westrom_track_geometry::/track_geometry/tg_alignment.script.tl")
local ends = require("westrom_track_geometry::/track_geometry/tg_ends.script.tl")
local edits = require("westrom_track_geometry::/track_geometry/tg_edit.script.tl")
local proposals = require("westrom_track_geometry::/track_geometry/tg_proposal.script.tl")
local readout = require("westrom_track_geometry::/track_geometry/tg_readout.script.tl")
local profiles = require("westrom_track_geometry::/track_geometry/tg_profile.script.tl")
local structures = require("westrom_track_geometry::/track_geometry/tg_structures.script.tl")

local TAG = "[westrom_track_geometry] "
local SNAP = 40.0 -- a free track end this close to the mouse snaps to it (m)
local STUB = 30.0 -- length of the ghost stub that marks a hovered or picked end (m)
local STEP = 10.0 -- the path is read this finely (m): for the ground under it, the readout, picking...
local MAX_TURN = math.rad(15) -- ...but built in pieces turning at most this much (straights: one piece)
local RIGHT_TICKS = 8 -- a "back" input this many tool ticks (50 ms) after a right-click is that click
local GHOST_TICKS = 4 -- while dragging, remake the ghost at most every this many tool ticks (50 ms)...
local GHOST_WAIT = 20 -- ...and only once the game has checked the last one, or this many ticks have passed
local GRAB = 0.02 -- grab radius for handles, as a share of the camera's distance
local LEG_STEP = 10.0 -- gizmo legs follow the ground in pieces this long (m)...
local MAX_LEG_PIECES = 60 -- ...or this many per leg, on long legs
local DP = geometry.DEFAULT_PARAMS
local BADGE_EVERY = 50.0 -- a speed or grade badge this often along the path (m), where there is room on the screen
local HEIGHT_PER_PX = 0.001 -- a Shift-drag raises an elevation point this share of the camera's distance per pixel

-- the game runs Lua 5.2: two-argument atan is math.atan2 there
local atan2 : function(number, number) : number = (math as {string : any}).atan2 as function(number, number) : number
	or (math.atan as function(number, number) : number)

local function say(msg : string)
	print(TAG .. msg)
end

------------------------------------------------------------------ tool state

-- A free track end: an existing node with a single track piece, and the unit direction pointing
-- out of that piece.
local record TrackEnd
	node : integer
	x : number
	y : number
	z : number
	dx : number
	dy : number
	grade : number -- the existing track's grade at the node, going out along (dx, dy)
end

-- The ghost's path with what the readout needs; speeds (m/s per piece, the game's curve limits)
-- arrive with the ghost's proposal data.
local record PathLine
	key : string -- ghost key
	pieces : {alignment.Sample} -- the ghost's nodes, as built
	nodes : {alignment.Sample} -- the path every STEP, and its heights: what the readout reads
	z : {number}
	minRadius : number
	curves : {readout.Curve}
	speeds : {number}
	badges : {readout.Badge}
end

-- A curve badge on the screen: where it sits, as a share of the screen's width and height.
local record ScreenBadge
	h : number
	v : number
	badge : readout.Badge
end

-- An elevation point being dragged: along the path, or (Shift held at the press) up and down.
local record ElevationDrag
	i : integer
	height : boolean
	pressY : number -- the mouse's screen y at the press (px)
	pressZ : number -- the point's height at the press
end

-- The edited path, sampled, for the vertical editing: its nodes, length and the nodes' chainages.
local record VPath
	nodes : {alignment.Sample}
	len : number
	ss : {number}
	edit : edits.Edit -- the alignment it was made from...
	hrev : integer -- ...at this horizontal revision
end

local record ToolState
	phase : string -- "from": pick the start, "to": pick the end, "done": both picked
	mode : string -- while editing: "horizontal" (turns and curves) or "vertical" (elevation points)
	active : boolean
	lastTick : number
	hovered : integer -- entity under the mouse (Selector)
	terrX : number -- ground under the mouse (read every frame by TgProbe)
	terrY : number
	mouseX : number -- where the last snap looked
	mouseY : number
	hover : TrackEnd -- end the mouse snaps to
	hoverMsg : string
	from : TrackEnd
	to : TrackEnd
	ghost : SimpleProposal
	ghostKey : string
	ghostInfo : string -- the ghost's path: length and layout
	ghostWhy : string -- why there is no ghost
	ghostTick : integer -- tick the ghost was last made
	edit : edits.Edit -- the alignment being edited (both ends picked)
	grab : number -- grab radius now (m)
	under : edits.Handle -- handle under the mouse
	underLeg : integer -- else the leg under the mouse, where a press adds a turn
	drag : edits.Handle -- handle being dragged
	underEl : integer -- vertical mode: the elevation point under the mouse
	underS : number -- else the chainage of the track under the mouse, where a press adds one
	dragEl : ElevationDrag -- the elevation point being dragged
	vpath : VPath -- the path the vertical editing works on (vertical mode)
	vbadges : {readout.Badge} -- the profile's badges (vertical mode)
	mouseSY : number -- the mouse's screen y, from its last event (px)
	modeOpen : boolean -- the mode window is open
	editMsg : string -- why the last edit did not happen
	gizmoErr : string -- last gizmo error logged
	cost : integer
	errors : string
	critical : boolean -- the game refuses the ghost
	hasErrors : boolean -- the game reports errors on the ghost (warnings do not count)
	dataKey : string -- ghost key whose data (cost, errors) came last
	pressGrabbed : boolean -- the last left press grabbed a handle or added a turn (its click must not build)
	buildMsg : string -- how the last build went (kept when the tool starts over)
	gameCtx : GameContext -- for the confirm window
	getParams : function() : {string : number} -- the menu entry's settings (track type, electric)
	template : string -- the track template to build, from the settings (read every tick)
	confirmOpen : boolean
	closedTick : integer -- tick the confirm window closed (the click that closed it must not open it again)
	errorsLogged : string -- ghost key whose problems were last logged
	pending : PathLine -- the ghost's path, until the game's data for it comes
	line : PathLine -- the path as last read out: badges at its curves, summed up in the tooltip
	screen : {ScreenBadge} -- the line's badges on the screen (placed by TgProbe every frame)
	screenKey : string -- changes when the badges move on the screen
	badgeErr : string -- last error placing them (logged once)
	speedsLogged : boolean
	ticks : integer -- tool ticks so far (os.clock is CPU time over all threads: no use as a timer)
	rightTick : integer -- tick of the last right-button event
	backTick : integer -- tick of the last step back (one input's "back" arrives more than once)
end

local tool : ToolState = { phase = "from" }

local function resetTool()
	tool = { phase = "from", active = tool.active, terrX = tool.terrX, terrY = tool.terrY, buildMsg = tool.buildMsg,
		gameCtx = tool.gameCtx, getParams = tool.getParams, template = tool.template, mode = tool.mode, modeOpen = tool.modeOpen }
end

------------------------------------------------------------------ the world

-- Is n still a node? A proposal that names a node that is gone kills the game (no pcall helps).
local function nodeAlive(n : integer) : boolean
	if n == nil or n < 0 then return true end
	local ok, res = pcall(function() : boolean
		return api.engine.entityExists(n) and api.engine.getComponent(n, api.type.ComponentType.BASE_NODE) ~= nil
	end)
	return ok and res == true
end

-- The pieces at a node; asking about an entity that is not a node crashes the game.
local function segmentsAt(n : integer, tracks : boolean) : {integer}
	if not nodeAlive(n) then return {} end
	local sys = api.engine.system.streetSystem
	local ok, segs = pcall(tracks and sys.getNodeTrackSegments or sys.getNodeStreetSegments, n)
	if ok and segs ~= nil then return segs as {integer} end
	return {}
end

-- The free track end at node n, or nil.
local function freeEndAt(n : integer) : TrackEnd
	if n == nil or n < 0 or not nodeAlive(n) then return nil end
	local segs = segmentsAt(n, true)
	if #segs ~= 1 or #segmentsAt(n, false) > 0 then return nil end -- (no level crossings)
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
end

-- The free end the mouse snaps to: an end of the piece under the mouse, else the nearest within
-- SNAP of (x, y). Never the node `exclude`. nil and a hint when there is none.
local function snapNear(x : number, y : number, hovered : integer, exclude : integer) : TrackEnd, string
	local CT = api.type.ComponentType
	local nodes : {integer : boolean} = {}
	local preferred : {integer : boolean} = {}
	local sawTrack = false
	local function addEdge(e : integer, pref : boolean)
		local be = api.engine.getComponent(e, CT.BASE_EDGE) as Engine.Component.BaseEdge
		if be ~= nil and be.roadType == api.type["enum"].RoadType.TRACK then
			sawTrack = true
			nodes[be.node0], nodes[be.node1] = true, true
			if pref then preferred[be.node0], preferred[be.node1] = true, true end
		end
	end
	if hovered ~= nil and hovered > 0 and api.engine.entityExists(hovered) then addEdge(hovered, true) end
	if x ~= nil then
		local box = api.type.Box3.new(api.type.Vec3f.new(x - SNAP, y - SNAP, -2000), api.type.Vec3f.new(x + SNAP, y + SNAP, 6000))
		pcall(function()
			api.engine.system.octreeSystem.findIntersectingEntities(box, function(e : Engine.Entity, _bv : Engine.Component.BoundingVolume)
				addEdge(e, false)
			end)
		end)
	end
	local best : TrackEnd = nil
	local bestD = math.huge
	for n in pairs(nodes) do
		if n ~= exclude then
			local e = freeEndAt(n)
			if e ~= nil then
				local d = x ~= nil and math.sqrt((e.x - x) ^ 2 + (e.y - y) ^ 2) or 0.0
				if (d <= SNAP or preferred[n]) and d < bestD then best, bestD = e, d end
			end
		end
	end
	if best ~= nil then return best, nil end
	if sawTrack then return nil, "No free track end here. Point at the last piece of a line, near its end." end
	return nil, "Point at the end of a track."
end

------------------------------------------------------------------ the ghost

-- A short straight stub out of end e, marking it.
local function stubNodes(e : TrackEnd) : {alignment.Sample}, string
	local h = atan2(e.dy, e.dx)
	return { { x = e.x, y = e.y, heading = h, s = 0, k = 0 },
		{ x = e.x + STUB * e.dx, y = e.y + STUB * e.dy, heading = h, s = STUB, k = 0 } }, nil
end

-- The end nodes moved exactly onto the existing nodes, so the ghost joins them.
local function pinEnds(nodes : {alignment.Sample}, a : TrackEnd, b : TrackEnd)
	nodes[1].x, nodes[1].y = a.x, a.y
	nodes[#nodes].x, nodes[#nodes].y = b.x, b.y
end

-- The new track from a to b (the edited alignment, else the starting one): its nodes every STEP,
-- its length and number of turns, its smallest radius, its curves and the path itself.
local function pathNodes(a : TrackEnd, b : TrackEnd, e : edits.Edit) : {alignment.Sample}, string, number, {readout.Curve}, {geometry.Segment}
	local how : string
	if e == nil then
		e, how = edits.new(a as ends.End, b as ends.End)
		if e == nil then return nil, how end
	else
		how = string.format("%d turn%s", #e.pis - 2, #e.pis == 3 and "" or "s")
	end
	local path = edits.path(e, DP)
	local nodes = alignment.sample(path, STEP)
	if #nodes < 2 then return nil, "the path is too short" end
	pinEnds(nodes, a, b)
	local minRadius = math.huge
	for _, s in ipairs(path) do
		if s.kind == "arc" and geometry.length(s) > 1e-6 then minRadius = math.min(minRadius, s.radius) end
	end
	return nodes, string.format("%.0f m, %s", nodes[#nodes].s, how), minRadius, readout.curves(path), path
end

------------------------------------------------------------------ track type

-- The track template to build: the menu settings' track type, with overhead wires if Electric is
-- on (the type's wired version, its catenaryAdd). Read every tick: the settings can change while
-- the tool is open, and the ghost (its key holds the template) is then made again.
local function trackTemplate() : string
	return tool.template or proposals.BASE_TEMPLATE
end

local function readTemplate()
	if tool.getParams == nil then return end
	local ok, raw = pcall(tool.getParams)
	if not ok or raw == nil then return end
	local tr, el = raw["tg_trackType"], raw["tg_electric"]
	local name = proposals.BASE_TEMPLATE
	if tr ~= nil and tr >= 0 then
		local id = math.floor(tr + 0.5)
		local okN, n = pcall(api.res.streetTemplateRep.getName, id)
		if okN and n ~= nil and n ~= "" then name = n as string end
	end
	if el ~= nil and math.floor(el + 0.5) == 2 then
		local okT, t = pcall(function() : table return api.res.streetTemplateRep.get(api.res.streetTemplateRep.find(name)) as table end)
		local wired = okT and t ~= nil and t.catenaryAdd as string or nil
		if wired ~= nil and wired ~= "" then name = wired end
	end
	if name ~= tool.template then
		say("track type: " .. name)
		tool.template = name
	end
end

-- The template's name in the menu (its file name if it has none).
local function templateName(name : string) : string
	local ok, n = pcall(function() : string
		return (api.res.streetTemplateRep.get(api.res.streetTemplateRep.find(name)) as table).name as string
	end)
	if ok and n ~= nil and n ~= "" then return n end
	return name:match("([^/]+)%.street_template$") or name
end

-- What the ghost shows now: the path from the start to the end (picked, or under the mouse), or
-- a stub at the start or the end under the mouse. Remade only when its ends change.
local function updateGhost()
	local a, b : TrackEnd, TrackEnd = nil, nil
	if tool.phase == "from" then a = tool.hover
	elseif tool.phase == "to" then a, b = tool.from, tool.hover
	else a, b = tool.from, tool.to end
	-- (the phase too: picking the hovered end makes it again once, which logs the path)
	local key = tool.phase .. ":" .. (a ~= nil and tostring(a.node) or "-") .. ":" .. (b ~= nil and tostring(b.node) or "-")
	if tool.phase == "done" and tool.edit ~= nil then key = key .. ":" .. tostring(tool.edit.rev) end
	key = key .. ":" .. trackTemplate()
	if key == tool.ghostKey then return end
	-- while dragging, the ghost lags behind the handles: the game's check of each ghost (cost,
	-- collisions) is what makes a drag stutter, so a new one waits until the last is checked
	if (tool.drag ~= nil or tool.dragEl ~= nil) and tool.ghostTick ~= nil then
		local since = (tool.ticks or 0) - tool.ghostTick
		if since < GHOST_TICKS then return end
		if tool.ghost ~= nil and tool.dataKey ~= tool.ghostKey and since < GHOST_WAIT then return end
	end
	tool.ghostTick = tool.ticks or 0
	tool.ghostKey, tool.ghost, tool.ghostInfo, tool.ghostWhy, tool.cost, tool.errors = key, nil, nil, nil, nil, nil
	tool.critical, tool.hasErrors, tool.dataKey = nil, nil, nil
	tool.pending = nil
	if a == nil or b == nil then tool.line = nil end -- (a path's line stays until the next one is read out)
	if a == nil then return end
	local nodes, info, minRadius, curves, path : {alignment.Sample}, string, number, {readout.Curve}, {geometry.Segment}
	if b == nil then nodes, info = stubNodes(a)
	else nodes, info, minRadius, curves, path = pathNodes(a, b, tool.phase == "done" and tool.edit or nil) end
	if nodes == nil then tool.ghostWhy = info; tool.line = nil; return end
	-- the vertical profile: from each end at its existing track's grade (the path arrives at b
	-- going against b's direction, so its grade there is the opposite of b's)
	local len = nodes[#nodes].s
	local ss : {number} = {}
	for i, nd in ipairs(nodes) do ss[i] = nd.s end
	local z, grades : {number}, {number}
	local prof : profiles.Profile
	if b == nil then
		z, grades = {}, {}
		for i, s in ipairs(ss) do z[i], grades[i] = a.z + a.grade * s, a.grade end
	else
		local pwhy : string
		if tool.phase == "done" and tool.edit ~= nil then prof, pwhy = edits.profile(tool.edit, len)
		else prof, pwhy = profiles.solve({ { s = 0, z = a.z }, { s = len, z = b.z } }, a.grade, -b.grade) end
		if prof == nil then tool.ghostWhy = pwhy; tool.line = nil; return end
		z, grades = profiles.sample(prof, ss)
	end
	-- bridges and tunnels where the track is far off the ground (without them, nothing on failure)
	local sok, kinds, bridgeType, tunnelType, structs = pcall(proposals.structuresFor, nodes, z, trackTemplate())
	if not sok then
		say("ghost: no structures: " .. tostring(kinds))
		kinds, bridgeType, tunnelType, structs = nil, nil, nil, nil
	end
	-- the pieces to build: long, with a node wherever the track changes (a bridge or tunnel starts
	-- or ends, an elevation point), so each piece is one kind and one span of the profile; the
	-- readout stays on the dense nodes, which follow the profile
	local dense, denseZ = nodes, z
	if path ~= nil then
		local breaks = kinds ~= nil and structures.changes(nodes, kinds as {string}) or {}
		for _, pt in ipairs(prof.points) do breaks[#breaks + 1] = pt.s end
		local long = alignment.sample(path, math.huge, MAX_TURN, breaks)
		pinEnds(long, a, b)
		if kinds ~= nil then kinds = alignment.carry(nodes, kinds as {string}, long) end
		nodes, ss = long, {}
		for i, nd in ipairs(nodes) do ss[i] = nd.s end
		z, grades = profiles.sample(prof, ss)
	end
	local ok, p, why = pcall(proposals.make, nodes, { template = trackTemplate(), z = z, grades = grades,
		startNode = a.node, endNode = b ~= nil and b.node or nil,
		kinds = kinds as {string}, bridgeType = bridgeType as integer, tunnelType = tunnelType as integer })
	if not ok then tool.ghostWhy = "error: " .. tostring(p); say("ghost: " .. tool.ghostWhy); return end
	if p == nil then tool.ghostWhy = why; return end
	tool.ghost = p as SimpleProposal
	if b ~= nil then
		tool.pending = { key = key, pieces = nodes, nodes = dense, z = denseZ, minRadius = minRadius, curves = curves }
		tool.ghostInfo = structs ~= nil and (info .. "; " .. (structs as string)) or info
		if tool.phase == "done" and tool.drag == nil then
			say(string.format("tool: path %s: from node %d (%.1f, %.1f) leaving %.2f deg, to node %d (%.1f, %.1f) arriving %.2f deg, %d pieces, grade %+.1f ‰ to %+.1f ‰",
				info, a.node, a.x, a.y, math.deg(nodes[1].heading), b.node, b.x, b.y, math.deg(nodes[#nodes].heading), #nodes - 1, grades[1] * 1000, grades[#grades] * 1000))
			say(string.format("tool: end headings: start %.2f deg, end %.2f deg (the ends' own directions)",
				math.deg(atan2(a.dy, a.dx)), math.deg(atan2(-b.dy, -b.dx))))
		end
	end
end

------------------------------------------------------------------ the tool's steps

local function toolLive() : boolean
	return tool.active == true and tool.lastTick ~= nil and os.clock() - tool.lastTick <= 3
end

local function makeContext() : Context
	local c = api.type.Context.new()
	c.player = api.engine.util.getPlayer()
	c.gatherBuildings = false
	c.gatherFields = true
	return c
end

-- Why the ghost cannot be built now, or nil when it can.
local function cannotBuild() : string
	if tool.ghost == nil then return tool.ghostWhy or "there is no path" end
	if tool.dataKey ~= tool.ghostKey or tool.cost == nil then return "the game is still checking it" end
	if tool.critical then return "the game refuses it" end
	if tool.hasErrors then return "the game reports errors on it" end
	if not (nodeAlive(tool.from.node) and nodeAlive(tool.to.node)) then return "an end is gone" end
	local ok, bal = pcall(function() : integer return api.engine.util.finance.getPlayersBalance(api.engine.util.getPlayer()) end)
	-- (the game itself lets the account go negative)
	if ok and bal ~= nil and tool.cost > (bal as integer) then return "not enough money" end
	return nil
end

local closeModeWindow : function() -- (below, with the mode window)

-- Builds the proposal p (the ghost when the confirm window opened), and starts over.
local function build(p : SimpleProposal, info : string, cost : integer)
	local ok, err : boolean, any = pcall(function()
		local cmd = api.cmd.makeWorldBuildProposalCmd(p, makeContext(), false, true)
		api.cmd.sendCommand(cmd, function(r : WorldBuildProposalCommandData, success : boolean, _ : {{Engine.Entity, Engine.Revision}})
			if success then
				tool.buildMsg = nil
				say(string.format("build: built %s for %s", info or "?", tostring(r ~= nil and r.resultProposalData ~= nil and r.resultProposalData.costs or cost)))
			else
				tool.buildMsg = "The last build failed."
				say("build: FAILED")
			end
		end)
	end)
	if not ok then
		tool.editMsg = "Cannot build: " .. tostring(err)
		say("build: " .. tostring(err))
		return
	end
	say(string.format("build: sent %s, cost %s", info or "?", tostring(cost)))
	closeModeWindow()
	resetTool()
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

local function closeConfirm()
	if not tool.confirmOpen then return end
	tool.confirmOpen = false
	tool.closedTick = tool.ticks or 0
	local wa = windowApi()
	if wa ~= nil then pcall(function() : string wa.removeAllWindows(dialog_react_util.DialogWindow); return nil end) end
end

------------------------------------------------------------------ the mode window

local MODES = { "horizontal", "vertical" }

local function setMode(m : string)
	if tool.mode == m then return end
	tool.mode = m
	tool.drag, tool.under, tool.underLeg, tool.dragEl, tool.underEl, tool.underS = nil, nil, nil, nil, nil, nil
	tool.editMsg = nil
	say("edit: " .. m .. " alignment")
end

local record ModeParam
	selected : integer
end

-- A small window to switch between editing the horizontal and the vertical alignment. Opened
-- from a click (as the confirm window; opening a window from onStep kills the game). A window
-- recipe must wrap builtin.Window (RegisterWrapperRecipe, as the game's own windows do): a plain
-- recipe returning one fails a native assertion in the window container (NodeStorage.cpp:51).
-- It sits at the bottom right of the screen, above the game bar (tg_gui.css.lua).
local TgModeWindow = react.RegisterWrapperRecipe("TgModeWindow", builtin.Window, function(p : ModeParam, _ : any) : TreeNodeId
	return builtin.Window{
		-- (no-close-button: the plain window surface, as the game's dialogs; the default one has a
		-- notch for the close button. Size and place: tg_gui.css.lua, by the id.)
		meta = { class = "no-close-button" },
		id = "tgmode",
		title = "Track Geometry",
		closable = false,
		movable = true,
		content = builtin.ToggleButtonGroup{
			layout = "Horizontal", -- (each as wide as its label; "Uniform" squeezes them to nothing here)
			buttons = {
				{ content = builtin.TextView{ text = "Horizontal alignment" } },
				{ content = builtin.TextView{ text = "Vertical alignment" } },
			},
			initialSelected = p.selected, -- (the group keeps its own state: the window is not re-made on a click)
			-- (1-based, as the game's own toggle groups)
			onValueChange = function(index : integer)
				say(string.format("mode window: button %d", index))
				if MODES[index] ~= nil then setMode(MODES[index]) end
			end,
		},
	}
end)

closeModeWindow = function()
	if not tool.modeOpen then return end
	tool.modeOpen = false
	local wa = windowApi()
	if wa ~= nil then pcall(function() : string wa.removeAllWindows(TgModeWindow); return nil end) end
end

local function openModeWindow()
	if tool.modeOpen then return end
	local wa = windowApi()
	local ok, err = pcall(function() : string
		wa.addSingletonWindow(TgModeWindow, { selected = tool.mode == "vertical" and 2 or 1 } as ModeParam)
		return nil
	end)
	if ok and wa ~= nil then
		tool.modeOpen = true
		say("mode window: open")
	else
		say("mode window: failed: " .. tostring(wa == nil and "no window container" or err))
	end
end

-- The track's top speed (m/s), 0 when unknown.
local trackSpeedNow, trackSpeedOf : number, string = nil, nil
local function trackSpeed() : number
	if trackSpeedOf ~= trackTemplate() then
		local ok, v = pcall(proposals.trackSpeed, trackTemplate())
		trackSpeedNow, trackSpeedOf = ok and v as number or 0.0, trackTemplate()
	end
	return trackSpeedNow
end

-- What the confirm window says: the path, its readout, what the game warns about, and the cost.
local function confirmText(cost : integer) : string
	local lines : {string} = { string.format("New track from node %d to node %d", tool.from.node, tool.to.node),
		"Track: " .. templateName(trackTemplate()) }
	if tool.ghostInfo ~= nil then lines[#lines + 1] = "Path: " .. tool.ghostInfo end
	local l = tool.line
	if l ~= nil and l.key == tool.ghostKey then
		local ok, more = pcall(readout.summary, l.nodes, l.z, l.speeds, trackSpeed(), l.minRadius)
		if ok then for _, m in ipairs(more as {string}) do lines[#lines + 1] = m end end
	end
	if tool.errors ~= nil then
		lines[#lines + 1] = ""
		for line in tool.errors:gmatch("[^\n]+") do lines[#lines + 1] = line end
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "Cost: " .. fmtMoney(cost)
	return wrapText(table.concat(lines, "\n"), 80)
end

-- A click while editing that grabbed nothing: a window shows what would be built and asks first.
local function openConfirm()
	if tool.phase ~= "done" or tool.drag ~= nil or tool.dragEl ~= nil or tool.pressGrabbed or tool.confirmOpen then return end
	-- (the click outside that just closed the window must not open it again)
	if tool.closedTick ~= nil and (tool.ticks or 0) - tool.closedTick <= 2 then return end
	local why = cannotBuild()
	if why ~= nil then
		tool.editMsg = "Cannot build: " .. why .. "."
		say("build: not sent: " .. why)
		return
	end
	local p, info, cost = tool.ghost, tool.ghostInfo, tool.cost
	local from, to = tool.from.node, tool.to.node
	local wa = windowApi()
	local ok, err = pcall(function() : string
		wa.addSingletonWindow(dialog_react_util.DialogWindow, {
			windowTitle = "Build this track?",
			displayText = confirmText(cost),
			x = 0.5,
			y = 0.5,
			closable = true,
			onClose = closeConfirm,
			choices = {
				{
					text = "Build",
					onClick = function()
						closeConfirm()
						-- (an end may have gone while the window was open; a proposal naming it kills the game)
						if not (nodeAlive(from) and nodeAlive(to)) then
							tool.editMsg = "Cannot build: an end is gone."
							say("build: not sent: an end is gone")
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
		} as DialogReactUtil.DialogWindowParam)
		return nil
	end)
	if ok and wa ~= nil then
		tool.confirmOpen = true
		say(string.format("build: asking to confirm %s, cost %s", info or "?", tostring(cost)))
	else
		-- no window could be shown: never build without asking
		say("build: confirm window failed: " .. tostring(wa == nil and "no window container" or err))
		tool.editMsg = "The confirm window could not be opened, so nothing was built."
	end
end

local function applyClick()
	if not toolLive() or tool.confirmOpen then return end
	if tool.phase == "done" then openConfirm(); return end
	if tool.hover == nil then
		say(string.format("tool: nothing to pick at %s: %s",
			tool.mouseX ~= nil and string.format("%.0f, %.0f", tool.mouseX, tool.mouseY) or "?", tool.hoverMsg or ""))
		return
	end
	local e = tool.hover
	if tool.phase == "from" then
		tool.from, tool.phase = e, "to"
		say(string.format("tool: start at node %d (%.1f, %.1f, %.1f) heading %.2f deg", e.node, e.x, e.y, e.z, math.deg(atan2(e.dy, e.dx))))
	else
		tool.to, tool.phase = e, "done"
		tool.edit = edits.new(tool.from as ends.End, e as ends.End)
		tool.mode = tool.mode or "horizontal"
		openModeWindow()
		say(string.format("tool: end at node %d (%.1f, %.1f, %.1f) heading %.2f deg", e.node, e.x, e.y, e.z, math.deg(atan2(e.dy, e.dx))))
	end
	tool.hover, tool.mouseX = nil, nil
end

local function canGoBack() : boolean
	return toolLive() and tool.phase ~= "from"
end

local function stepBack()
	if tool.phase == "done" then
		tool.phase, tool.to, tool.edit, tool.drag, tool.under, tool.underLeg = "to", nil, nil, nil, nil, nil
		tool.dragEl, tool.underEl, tool.underS, tool.vpath, tool.vbadges = nil, nil, nil, nil, nil
		closeModeWindow()
	elseif tool.phase == "to" then
		tool.phase, tool.from = "from", nil
	else
		return
	end
	tool.hover, tool.mouseX = nil, nil
	say("tool: back to picking the " .. (tool.phase == "to" and "end" or "start"))
end

-- Right-click and Esc are the same "back" input. The right button shows up as a mouse event just
-- before it, so a "back" within RIGHT_TICKS of a right-click is that click. The game sends "back"
-- only for a click, not after a right-drag of the camera (and the tool never sees the right press),
-- so that "back" is the click. While editing, it removes the turn under the mouse (removeAt) and
-- only Esc steps back. While picking ends, right-click steps back and Esc closes the tool (as in Track
-- Connector). One input steps back once, however many times its "back" arrives (selector, input
-- action, onBack).
local function rightRecent() : boolean
	return tool.rightTick ~= nil and (tool.ticks or 0) - tool.rightTick <= RIGHT_TICKS
end
local function backRecent() : boolean
	return tool.backTick ~= nil and (tool.ticks or 0) - tool.backTick <= RIGHT_TICKS
end
local function backIsOurs() : boolean
	if tool.confirmOpen then return false end -- (the window takes it)
	return backRecent() or (canGoBack() and (rightRecent() or tool.phase == "done"))
end

------------------------------------------------------------------ editing

-- Height to draw a gizmo at (x, y): the ground there, so it sits over the spot the mouse grabs it
-- at (handles are picked by where the mouse meets the ground). Else the ends' heights, blended
-- along the line between them.
local function zAt(x : number, y : number) : number
	local ok, z = pcall(function() : number return api.engine.terrain.getHeightAt(api.type.Vec2f.new(x, y)) end)
	if ok and z ~= nil and z == z then return z end
	local a, b = tool.from, tool.to
	if a == nil or b == nil then return 0 end
	local lx, ly = b.x - a.x, b.y - a.y
	local l2 = lx * lx + ly * ly
	local t = l2 > 0 and math.max(0, math.min(1, ((x - a.x) * lx + (y - a.y) * ly) / l2)) or 0
	return a.z + t * (b.z - a.z)
end

-- Grab radius: a fixed share of the screen, whatever the zoom.
local function grabRadius() : number
	local ok, d = pcall(function() : number return api.gui.camera.getCameraData().z end)
	if not ok or d == nil or d ~= d then return 10.0 end
	return math.max(3.0, GRAB * (d as number))
end

local function handleName(h : edits.Handle) : string
	if h.kind == "pi" then return "turn " .. tostring(h.i - 1) end
	return (h.kind == "entry" and "start" or "end") .. " of the curve at turn " .. tostring(h.i - 1)
end

---------------------------------------------------- editing the vertical alignment

local function vertical() : boolean
	return tool.mode == "vertical"
end

-- The edited path, every STEP (made again in vertical mode only when the turns or
-- curves change: sampling a long path takes milliseconds, too long for every tick of a drag).
local function makeVPath() : VPath
	local vp = tool.vpath
	if vp ~= nil and vp.edit == tool.edit and vp.hrev == tool.edit.hrev then return vp end
	local nodes = alignment.sample(edits.path(tool.edit, DP), STEP)
	if #nodes < 2 then return nil end
	local ss : {number} = {}
	for i, nd in ipairs(nodes) do ss[i] = nd.s end
	return { nodes = nodes, len = nodes[#nodes].s, ss = ss, edit = tool.edit, hrev = tool.edit.hrev }
end

local gradeLimitNow, gradeLimitOf : number, string = nil, nil
local function gradeLimit() : number
	if gradeLimitOf ~= trackTemplate() then
		local ok, v = pcall(proposals.maxGrade, trackTemplate())
		gradeLimitNow, gradeLimitOf = ok and v as number or 0.085, trackTemplate()
		say(string.format("edit: grade limit %.1f permille", gradeLimitNow * 1000))
	end
	return gradeLimitNow
end

-- Where elevation point i is on the ground.
local function elevationXY(i : integer) : number, number
	local vp = tool.vpath
	return alignment.pointAt(vp.nodes, tool.edit.elevations[i].f * vp.len)
end

-- What is under the mouse in vertical mode: an elevation point, else the track (where a press adds one).
local function findUnderV()
	tool.underEl, tool.underS = nil, nil
	local x, y, vp = tool.terrX, tool.terrY, tool.vpath
	if x == nil or vp == nil then return end
	local best = tool.grab * tool.grab
	for i = 1, #tool.edit.elevations do
		local ex, ey = elevationXY(i)
		local d = (ex - x) ^ 2 + (ey - y) ^ 2
		if d <= best then tool.underEl, best = i, d end
	end
	if tool.underEl ~= nil then return end
	local s, d = alignment.project(vp.nodes, x, y)
	if d <= tool.grab then tool.underS = s end
end

local function pressAtV() : boolean
	local e, vp = tool.edit, tool.vpath
	if vp == nil then return false end
	findUnderV()
	tool.editMsg = nil
	local i = tool.underEl
	if i == nil and tool.underS ~= nil then
		local why : string
		i, why = edits.insertElevation(e, tool.underS, vp.len)
		if i == nil then tool.editMsg = "Cannot add an elevation point here: " .. why; return true end
		say(string.format("edit: add elevation point %d at %.0f m (%d points)", i, tool.underS, #e.elevations))
	end
	if i == nil then return false end
	local height = api.gui.inputAction.modifierOnlyActionIsActive("IA_PRECISION_MODE")
	tool.dragEl = { i = i, height = height, pressY = tool.mouseSY, pressZ = e.elevations[i].z }
	say(string.format("edit: grab elevation point %d%s", i, height and " (height)" or ""))
	return true
end

local function dragTickV()
	local d, e, vp = tool.dragEl, tool.edit, tool.vpath
	if d == nil or vp == nil or e.elevations[d.i] == nil then return end
	local el = e.elevations[d.i]
	local s, z = el.f * vp.len, el.z
	if d.height then
		if d.pressY == nil or tool.mouseSY == nil then return end
		local ok, cam = pcall(function() : number return api.gui.camera.getCameraData().z end)
		local dist = ok and cam ~= nil and cam == cam and cam as number or 500.0
		z = d.pressZ + (d.pressY - tool.mouseSY) * HEIGHT_PER_PX * dist
	else
		if tool.terrX == nil then return end
		s = alignment.project(vp.nodes, tool.terrX, tool.terrY)
	end
	edits.moveElevation(e, d.i, s, z, vp.len, vp.ss, gradeLimit())
end

local function releaseV()
	local d, e = tool.dragEl, tool.edit
	tool.dragEl = nil
	tool.ghostTick = nil
	if d == nil or e == nil or e.elevations[d.i] == nil or tool.vpath == nil then return end
	local el = e.elevations[d.i]
	say(string.format("edit: elevation point %d at %.0f m, height %.2f m; steepest %.1f permille", d.i,
		el.f * tool.vpath.len, el.z, edits.steepest(e, tool.vpath.len, tool.vpath.ss) * 1000))
end

local function removeAtV() : boolean
	findUnderV()
	local i = tool.underEl
	if i == nil then
		say("edit: right-click on no elevation point: nothing to remove")
		return false
	end
	edits.removeElevation(tool.edit, i)
	say(string.format("edit: remove elevation point %d (%d left)", i, #tool.edit.elevations))
	tool.underEl = nil
	return true
end

-- The profile's badges (grade at each point and halfway between), for the badge layer.
local function updateVBadges()
	local vp = tool.vpath
	if vp == nil then tool.vbadges = nil; return end
	local prof = edits.profile(tool.edit, vp.len)
	tool.vbadges = prof ~= nil and readout.profileBadges(vp.nodes, prof, BADGE_EVERY) or nil
end

-- What is under the mouse: a handle, else a leg (or the track along it) to add a turn on.
local function findUnder()
	tool.under, tool.underLeg = nil, nil
	local e, x, y = tool.edit, tool.terrX, tool.terrY
	if e == nil or x == nil then return end
	tool.under = edits.pick(edits.handles(e, DP), x, y, tool.grab)
	if tool.under ~= nil then return end
	local leg, d = edits.nearestLeg(e, x, y)
	if d <= tool.grab then tool.underLeg = leg; return end
	-- (or the track itself, which leaves the legs at the curves)
	local path = edits.path(e, DP)
	local nodes = alignment.sample(path, math.max(2.0, tool.grab))
	for _, nd in ipairs(nodes) do
		if (nd.x - x) ^ 2 + (nd.y - y) ^ 2 <= tool.grab * tool.grab then
			tool.underLeg = edits.nearestLeg(e, nd.x, nd.y)
			return
		end
	end
end

-- Left button down: grab the handle under the mouse, or add a turn on the leg there and grab it.
-- false when there is nothing to grab (the press is left to the game).
local function pressAt() : boolean
	if tool.phase ~= "done" or tool.edit == nil or not toolLive() then return false end
	if vertical() then return pressAtV() end
	findUnder()
	local h, e = tool.under, tool.edit
	tool.editMsg = nil
	if h ~= nil then
		if h.kind == "pi" and h.mobility == "fixed" then
			tool.editMsg = "This turn is next to both ends, so it cannot move. Add another turn first."
			return true
		end
		tool.drag = h
		say("edit: grab " .. handleName(h))
		return true
	end
	if tool.underLeg ~= nil then
		local i, why = edits.insertOnLeg(e, tool.underLeg, tool.terrX, tool.terrY, DP)
		if i == nil then tool.editMsg = "Cannot add a turn here: " .. why; return true end
		tool.drag = { kind = "pi", i = i, x = e.pis[i].x, y = e.pis[i].y, mobility = edits.mobility(e, i) }
		say(string.format("edit: add turn %d on leg %d (%d turns)", i - 1, tool.underLeg, #e.pis - 2))
		return true
	end
	return false
end

local function release()
	if tool.dragEl ~= nil then releaseV(); return end
	if tool.drag == nil then return end
	local h, e = tool.drag, tool.edit
	tool.drag = nil
	tool.ghostTick = nil -- (make the ghost of where it ended up now)
	if e == nil then return end
	if h.kind == "pi" then
		local p = e.pis[h.i]
		say(string.format("edit: %s at (%.1f, %.1f)", handleName(h), p.x, p.y))
	else
		say(string.format("edit: curve at turn %d: budget %.1f m", h.i - 1, e.budgets[h.i] or -1))
	end
end

-- Right-click on a turn removes it; elsewhere it does nothing. true when it removed one (or refused).
local function removeAt() : boolean
	if tool.phase ~= "done" or tool.edit == nil or not toolLive() or tool.drag ~= nil or tool.dragEl ~= nil then return false end
	if vertical() then return removeAtV() end
	findUnder()
	local h = tool.under
	if h == nil or h.kind ~= "pi" then
		say("edit: right-click on " .. (h ~= nil and handleName(h) or "no turn") .. ": nothing to remove")
		return false
	end
	local ok, why = edits.removePi(tool.edit, h.i)
	tool.editMsg = not ok and ("Cannot remove this turn: " .. why) or nil
	if ok then say(string.format("edit: remove turn %d (%d left)", h.i - 1, #tool.edit.pis - 2))
	else say(string.format("edit: cannot remove turn %d: %s", h.i - 1, why)) end
	tool.under = nil
	return true
end

-- The "back" input (see backIsOurs): Esc steps back; a right-click removes the turn under it while
-- editing, and steps back while picking ends.
local function backAction()
	if backRecent() or not canGoBack() then return end
	tool.backTick = tool.ticks or 0
	if tool.phase == "done" and rightRecent() then removeAt() else stepBack() end
end

-- While dragging: move the grabbed handle to the mouse.
local function dragTick()
	local h, e, x, y = tool.drag, tool.edit, tool.terrX, tool.terrY
	if h == nil or e == nil or x == nil then return end
	if h.kind == "pi" then edits.movePi(e, h.i, x, y)
	else edits.dragBracket(e, h.i, h.kind == "entry", x, y, DP) end
end

-- Every 50 ms while the tool is open: snap to the end under the mouse, keep the ghost up to date.
-- Returns a key that changes whenever the tool must draw again.
local function toolTick() : string
	tool.lastTick = os.clock()
	tool.ticks = (tool.ticks or 0) + 1
	readTemplate()
	if tool.from ~= nil and freeEndAt(tool.from.node) == nil then
		say("tool: the start end is gone")
		closeModeWindow()
		resetTool()
	elseif tool.to ~= nil and freeEndAt(tool.to.node) == nil then
		say("tool: the end is gone")
		closeModeWindow()
		tool.phase, tool.to = "to", nil
	end
	if tool.phase == "done" and vertical() then
		tool.grab = grabRadius()
		tool.vpath = makeVPath()
		dragTickV()
		if tool.dragEl == nil then findUnderV() end
		updateVBadges()
	elseif tool.phase == "done" then
		tool.grab = grabRadius()
		tool.vpath, tool.vbadges = nil, nil
		dragTick()
		if tool.drag == nil then findUnder() end
	else
		local x, y = tool.terrX, tool.terrY
		local moved = x == nil or tool.mouseX == nil or math.abs(x - tool.mouseX) + math.abs(y - tool.mouseY) > 1.0
		if moved or tool.hover == nil then
			tool.mouseX, tool.mouseY = x, y
			local exclude = tool.phase == "to" and tool.from.node or nil
			local ok, e, msg = pcall(snapNear, x, y, tool.hovered, exclude)
			if not ok then e, msg = nil, "error: " .. tostring(e) end
			tool.hover, tool.hoverMsg = e as TrackEnd, msg as string
		end
	end
	updateGhost()
	local u = tool.drag or tool.under
	return table.concat({ tool.phase, tool.ghostKey or "-", tool.screenKey or "-", tool.hoverMsg or "", tostring(tool.cost), tool.errors or "",
		tool.edit ~= nil and tostring(tool.edit.rev) or "-", u ~= nil and (u.kind .. u.i) or "-", tostring(tool.underLeg),
		tostring(tool.drag ~= nil), string.format("%.0f", tool.grab or 0), tool.editMsg or "",
		tool.mode or "-", tostring(tool.underEl), tool.underS ~= nil and "s" or "-", tostring(tool.dragEl ~= nil) }, "|")
end

local function tooltip() : Builtin.ActionTooltipParam<any>
	local lines : {string} = {}
	local good, bad = false, false
	local function path()
		if tool.ghostInfo ~= nil then lines[#lines + 1] = "Path: " .. tool.ghostInfo end
		local l = tool.line
		if l ~= nil and tool.ghostInfo ~= nil then
			local ok, more = pcall(readout.summary, l.nodes, l.z, l.speeds, trackSpeed(), l.minRadius)
			if ok then for _, m in ipairs(more as {string}) do lines[#lines + 1] = m end end
		end
		if tool.ghostWhy ~= nil then lines[#lines + 1] = "No path: " .. tool.ghostWhy; bad = true end
		if tool.errors ~= nil then
			for line in tool.errors:gmatch("[^\n]+") do lines[#lines + 1] = line end
			bad = true
		end
	end
	if tool.phase == "from" then
		if tool.hover ~= nil then
			lines[1], good = "Start the new track here. Then click where it should end.", true
		else
			lines[1] = "Track Geometry: click the end of a track to start."
			if tool.hoverMsg ~= nil then lines[2] = tool.hoverMsg end
		end
		if tool.buildMsg ~= nil then lines[#lines + 1] = tool.buildMsg; bad = true end
	elseif tool.phase == "to" then
		if tool.hover ~= nil then
			lines[1], good = "Click to end the new track here.", true
			path()
		else
			lines[1] = "Now click the end of another track."
			if tool.hoverMsg ~= nil then lines[2] = tool.hoverMsg end
		end
		lines[#lines + 1] = "Right-click to go back."
	elseif vertical() then
		local d = tool.dragEl
		if d ~= nil then
			lines[1] = d.height and "Raising or lowering the elevation point (move the mouse up or down)."
				or "Sliding the elevation point along the track."
		elseif tool.underEl ~= nil then
			lines[1] = "Drag to slide this elevation point along the track; Shift-drag to raise or lower it. Right-click to remove it."
		elseif tool.underS ~= nil then
			lines[1] = "Press to add an elevation point here (and drag it; Shift for its height)."
		else
			lines[1] = "Press on the track to add an elevation point. Drag a point to slide it; Shift-drag for its height."
		end
		lines[#lines + 1] = string.format("Grade limit: %.0f ‰ (the editor keeps within it)", gradeLimit() * 1000)
		if tool.editMsg ~= nil then lines[#lines + 1] = tool.editMsg; bad = true end
		path()
		lines[#lines + 1] = "Click elsewhere to build. Esc to go back."
	else
		local h = tool.drag or tool.under
		if tool.drag ~= nil then
			lines[1] = "Dragging the " .. handleName(h) .. "."
		elseif h ~= nil and h.kind == "pi" then
			if h.mobility == "fixed" then lines[1] = "This turn is next to both ends and cannot move. Add another turn first."
			elseif h.mobility == "ray" then lines[1] = "Drag to slide this turn along its end's line. (Next to an end: it stays.)"
			else lines[1] = "Drag to move this turn. Right-click to remove it." end
		elseif h ~= nil then
			lines[1] = "Drag to resize the curve (the " .. handleName(h) .. ")."
		elseif tool.underLeg ~= nil then
			lines[1] = "Press and drag to add a turn here."
		else
			lines[1] = "Drag a turn or a curve's bracket. Press on the track to add a turn."
		end
		if tool.editMsg ~= nil then lines[#lines + 1] = tool.editMsg; bad = true end
		path()
		lines[#lines + 1] = "Click elsewhere to build. Esc to go back."
	end
	local param : ConstructionReactUtil.SimpleTooltipRecipeParams = {
		message = { message = table.concat(lines, "\n"), good = good and not bad, bad = bad },
		cost = tool.cost,
	}
	return { recipe = construction_react_util.SimpleTooltipRecipe as Recipe<any>, param = param }
end

local function isTrackEdge(entity : Engine.Entity) : boolean
	if entity == nil or not api.engine.entityExists(entity) then return false end
	local be = api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	return be ~= nil and be.roadType == api.type["enum"].RoadType.TRACK
end

-- What the game says is wrong with the ghost: its errors and warnings, and what it runs into.
-- nil when nothing is.
local function proposalProblems(data : ProposalData) : string
	local lines : {string} = {}
	local es = data.errorState
	if es ~= nil then
		local msgs = table.concat(es.messages or {}, ", ")
		if msgs ~= "" then lines[#lines + 1] = (es.critical and "The game refuses it: " or "Errors: ") .. msgs
		elseif es.critical then lines[#lines + 1] = "The game refuses it." end
		local warns = table.concat(es.warnings or {}, ", ")
		if warns ~= "" then lines[#lines + 1] = "Warnings: " .. warns end
	end
	local cols = data.collisionInfo ~= nil and data.collisionInfo.collisionEntities or {}
	if #cols > 0 then lines[#lines + 1] = string.format("Runs into %d thing%s.", #cols, #cols > 1 and "s" or "") end
	if #lines == 0 then return nil end
	return table.concat(lines, "\n")
end

-- The game's own curve speed limit of each of the ghost's m pieces (m/s; nil where it gives none):
-- the slowest edge of the transport network the piece would make. ProposalData.entity2tn is keyed
-- by the proposal's entity ids, and the pieces are -1..-m (tg_proposal). This is the limit from
-- the curve alone, before the track type caps it; the Speed Limit layer only paints built track.
-- (Found in the Gleis- und Straßenbauanzeige mod, mod.io 6418902.)
local function curveSpeeds(data : ProposalData, m : integer) : {number}, integer
	local out : {number} = {}
	local found = 0
	for i = 1, m do
		local ok, v = pcall(function() : number
			local tn = data.entity2tn[-i]
			if tn == nil then return nil end
			local best = math.huge
			for k = 1, #tn.edges do
				local lim = tn.edges[k].curveSpeedLimit
				if lim ~= nil and lim == lim and lim > 0 and lim < best then best = lim end
			end
			return best < math.huge and best or nil
		end)
		if ok and v ~= nil then out[i], found = v as number, found + 1 end
	end
	return out, found
end

------------------------------------------------------------------ curve badges

local BADGE_BG = { 0.16, 0.33, 0.55, 0.85 } -- as the track builder's own badges
local BADGE_SLOW = { 230 / 255, 109 / 255, 149 / 255, 0.95 } -- the slowest curve: the Speed Limit layer's "slow"
local BADGE_TEXT = { 1, 1, 1, 1 }
local ICONS = "::/gui/construction/build_control/"
local BADGE_W = 90 -- a badge's size on the screen, about (px): width, and height with two rows or one
local BADGE_H2 = 50
local BADGE_H1 = 28
local BADGE_GAP = 10 -- the badge sits this far (px) up and left of its curve, clear of the handles

-- The track builder's slope icon for grade g: symbol_slope_-4 .. 4, a step per percent.
local function slopeIcon(g : number) : string
	local n = math.floor(math.abs(g) * 100 + 0.5)
	if n == 0 and math.abs(g) >= 0.001 then n = 1 end
	n = math.min(4, n)
	if g < 0 then n = -n end
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

-- A curve's badge: its speed and grade; an elevation point's: its height and grade; halfway
-- between two: the grade.
local function badgeRows(b : readout.Badge) : {TreeNodeId}
	local grade = badgeRow(slopeIcon(b.grade), string.format("%+.0f ‰", b.grade * 1000))
	if b.kind == "point" then return { builtin.TextView{ meta = { styleSheet = styleutil.makeStyle{ color = BADGE_TEXT } }, text = string.format("%.1f m", b.z) }, grade } end
	if b.kind == "span" or b.kind == "grade" then return { grade } end
	-- (the game's curve limit, but no faster than the track itself)
	local top = trackSpeed()
	local v = b.speed ~= nil and top > 0 and math.min(b.speed, top) or b.speed
	return { badgeRow(ICONS .. "symbol_speed_16.tga", v ~= nil and string.format("%.0f", v * 3.6) or "..."), grade }
end

local function badgeView(b : readout.Badge) : TreeNodeId
	local style = styleutil.makeStyle{ backgroundColor = b.slowest and BADGE_SLOW or BADGE_BG, anchorPoint = { 1.0, 1.0 } }
	style.padding = api.type.Vec4f.new(4, 2, 4, 2)
	return builtin.Component{
		meta = { styleSheet = style },
		mouseTransparent = true, -- (the recipe's own setMouseTransparent doesn't reach its children)
		layout = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Vertical,
			children = badgeRows(b),
		},
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

local badgesLogged = false
-- Every frame, from TgProbe (world2Screen is refused elsewhere): put the badges on the screen.
local function placeBadges()
	local l = tool.line
	local list, key : {readout.Badge}, string
	if vertical() and tool.phase == "done" then
		list, key = tool.vbadges, "v" .. (tool.edit ~= nil and tostring(tool.edit.rev) or "-")
	elseif l ~= nil and tool.ghostInfo ~= nil then
		list, key = l.badges, l.key
	end
	if list == nil or #list == 0 then
		tool.screen, tool.screenKey = nil, nil
		return
	end
	local size = api.gui.camera.getSize()
	local w, h = size.x, size.y
	if w <= 0 or h <= 0 then return end
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
		local bh = (b.kind == "span" or b.kind == "grade") and BADGE_H1 or BADGE_H2
		if p ~= nil and p.x >= 0 and p.x <= w and p.y >= 0 and p.y <= h and free(p.x, p.y, bh) then
			taken[#taken + 1] = { p.x, p.y, bh }
			out[#out + 1] = { h = (p.x - BADGE_GAP) / w, v = (p.y - BADGE_GAP) / h, badge = b }
			keys[#keys + 1] = tostring(p.x) .. "," .. tostring(p.y)
		end
	end
	end
	tool.screen, tool.screenKey = out, key .. ":" .. table.concat(keys, ";")
	if not badgesLogged and #out > 0 then
		badgesLogged = true
		say(string.format("badges: screen %d x %d, first at %s (h %.3f, v %.3f)", w, h, keys[1], out[1].h, out[1].v))
	end
end

------------------------------------------------------------------ gizmos

local COLORS : {string : {number}} = {
	leg = { 1.0, 0.75, 0.1, 1.0 }, -- the PI polyline
	free = { 1.0, 0.75, 0.1, 1.0 }, -- turns
	ray = { 0.3, 0.8, 1.0, 1.0 },
	fixed = { 0.6, 0.6, 0.6, 1.0 },
	bracket = { 0.3, 1.0, 0.4, 1.0 },
	hot = { 1.0, 1.0, 1.0, 1.0 }, -- under the mouse or dragged
}

local function paint(e : Builtin.Type.EdgeRenderable.Edge, c : {number}, width : number) : Builtin.Type.EdgeRenderable.Edge
	e.colors = { api.type.Vec4f.new(c[1], c[2], c[3], c[4]), api.type.Vec4f.new(c[1], c[2], c[3], c[4]) }
	e.width = width
	e.offsetZ = 1.0
	e.stepSize = 2.0
	return e
end

-- A gizmo circle of radius r around (x, y, z).
local function circleEdge(x : number, y : number, z : number, r : number, c : {number}, width : number) : Builtin.Type.EdgeRenderable.Edge
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
	g.width = width
	return paint(builtin.type.EdgeRenderable.Edge.new(g), c, width)
end

-- A straight gizmo line from (x0, y0, z0) to (x1, y1, z1).
local function straightEdge(x0 : number, y0 : number, z0 : number, x1 : number, y1 : number, z1 : number, c : {number}, width : number) : Builtin.Type.EdgeRenderable.Edge
	local g = api.type.EdgeGeometry.new()
	g.type = api.type.EdgeGeometry.Type.STRAIGHT
	local st = api.type.EdgeGeometry.Straight.new()
	st.pos = { api.type.Vec2f.new(x0, y0), api.type.Vec2f.new(x1, y1) }
	g.straight = st
	g.height = api.type.Vec2f.new(z0, z1)
	g.tangent = api.type.Vec2f.new(0, 0)
	g.length = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2 + (z1 - z0) ^ 2)
	g.width = width
	return paint(builtin.type.EdgeRenderable.Edge.new(g), c, width)
end

-- The gizmos of the edit: the PI polyline, a circle at each turn (coloured by how it can move)
-- and a tick across the leg at each curve's start and end (its brackets).
local function editEdges() : {Builtin.Type.EdgeRenderable.Edge}
	local e, r = tool.edit, tool.grab or 10.0
	local w = math.max(0.5, r / 8)
	local hot = tool.drag or tool.under
	local function isHot(h : edits.Handle) : boolean return hot ~= nil and hot.kind == h.kind and hot.i == h.i end
	local edges : {Builtin.Type.EdgeRenderable.Edge} = {}
	local pis = e.pis
	for i = 1, #pis - 1 do
		local a, b = pis[i], pis[i + 1]
		local c = (tool.drag == nil and tool.under == nil and tool.underLeg == i) and COLORS.hot or COLORS.leg
		-- in pieces at most LEG_STEP long (more on very long legs), each over the ground
		local len = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
		local n = math.max(1, math.ceil(len / math.max(LEG_STEP, len / MAX_LEG_PIECES)))
		local px, py, pz = a.x, a.y, zAt(a.x, a.y)
		for k = 1, n do
			local t = k / n
			local qx, qy = a.x + t * (b.x - a.x), a.y + t * (b.y - a.y)
			local qz = zAt(qx, qy)
			edges[#edges + 1] = straightEdge(px, py, pz, qx, qy, qz, c, w)
			px, py, pz = qx, qy, qz
		end
	end
	for _, h in ipairs(edits.handles(e, DP)) do
		local z = zAt(h.x, h.y)
		if h.kind == "pi" then
			edges[#edges + 1] = circleEdge(h.x, h.y, z, r, isHot(h) and COLORS.hot or COLORS[h.mobility], w)
		else
			-- across the leg the bracket sits on
			local p, q = pis[h.i], h.kind == "entry" and pis[h.i - 1] or pis[h.i + 1]
			local lx, ly = q.x - p.x, q.y - p.y
			local len = math.sqrt(lx * lx + ly * ly)
			if len > 0 then
				local nx, ny = -ly / len * r, lx / len * r
				edges[#edges + 1] = straightEdge(h.x - nx, h.y - ny, z, h.x + nx, h.y + ny, z,
					isHot(h) and COLORS.hot or COLORS.bracket, 2 * w)
			end
		end
	end
	return edges
end

-- The vertical gizmos: at each end and elevation point a circle on the ground (where the mouse
-- grabs it) and a post from the ground up to the track; grey at the ends, white under the mouse.
local function verticalEdges() : {Builtin.Type.EdgeRenderable.Edge}
	local e, vp, r = tool.edit, tool.vpath, tool.grab or 10.0
	local edges : {Builtin.Type.EdgeRenderable.Edge} = {}
	if vp == nil then return edges end
	local w = math.max(0.5, r / 8)
	local prof = edits.profile(e, vp.len)
	if prof == nil then return edges end
	local function post(s : number, c : {number})
		local x, y = alignment.pointAt(vp.nodes, s)
		local g, z = zAt(x, y), profiles.heightAt(prof, s)
		edges[#edges + 1] = circleEdge(x, y, g, r, c, w)
		if math.abs(z - g) > 0.1 then
			-- (a hair off vertical: a straight with no run has no direction)
			edges[#edges + 1] = straightEdge(x, y, g, x + 0.01, y, z, c, w)
		end
	end
	post(0, COLORS.fixed)
	post(vp.len, COLORS.fixed)
	local hot = tool.dragEl ~= nil and tool.dragEl.i or tool.underEl
	for i, el in ipairs(e.elevations) do post(el.f * vp.len, i == hot and COLORS.hot or COLORS.ray) end
	return edges
end

-- The tool in the world: the selector (clicks), the ghost and the tooltip.
local function toolAction(abort : function()) : TreeNodeId
	tool.active = true
	react.onMount(function(_ : any) tool.active = true end)
	react.onUnmount(function(_ : any)
		closeConfirm()
		closeModeWindow()
		tool.active = false
		tool.hover, tool.mouseX = nil, nil
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
				applyClick()
				return true
			end,
			onSelectSecondary = function(_e : Engine.Entity, _i : {integer}, _d : Gui.SelectionDetails) : boolean
				if tool.phase == "done" and toolLive() then return true end -- (its "back" removes the turn)
				if not canGoBack() then return false end
				backAction()
				return true
			end,
			filter = isTrackEdge,
			-- a left click anywhere counts (the selector alone only reports clicks on a track piece)
			onProcessMouseEvent = function(evt : Gui.Mouse.Event) : boolean
				local T = api.gui.mouse.Event.Type
				if evt.y ~= nil then tool.mouseSY = evt.y end -- (for a Shift-drag's height)
				if evt.button == 2 then
					-- (only marks the "back" that follows as a right-click; the camera keeps the button)
					if evt.type ~= T.Moved then tool.rightTick = tool.ticks or 0 end
					return false
				end
				if evt.button ~= 0 or not toolLive() then return false end
				-- (the confirm window takes the mouse; the click that closes it must do nothing here)
				if tool.confirmOpen or (tool.closedTick ~= nil and (tool.ticks or 0) - tool.closedTick <= 2) then return false end
				if tool.phase == "done" then
					if evt.type == T.Pressed then
						tool.pressGrabbed = pressAt()
						return tool.pressGrabbed
					end
					if evt.type == T.Released or evt.type == T.Clicked then
						local had = tool.drag ~= nil or tool.dragEl ~= nil or tool.pressGrabbed
						release()
						if evt.type == T.Clicked and not had then openConfirm(); return true end
						return had
					end
					return false
				end
				if evt.type ~= T.Clicked then return false end
				applyClick()
				return true
			end,
		},
	}
	-- never hand the game a ghost that names a node that is gone; only one ProposalViewer at a time
	local g = tool.ghost
	if g ~= nil and (tool.from == nil or nodeAlive(tool.from.node)) and (tool.to == nil or nodeAlive(tool.to.node))
		and (tool.hover == nil or nodeAlive(tool.hover.node)) then
		local gk = tool.ghostKey
		children[#children + 1] = builtin.ProposalViewer{
			simpleProposal = g,
			onCreateProposalData = function(data : ProposalData, _p : Proposal)
				if data == nil or tool.ghostKey ~= gk then return end
				tool.cost = data.costs
				tool.errors = proposalProblems(data)
				tool.critical = data.errorState ~= nil and data.errorState.critical == true
				tool.hasErrors = data.errorState ~= nil and #(data.errorState.messages or {}) > 0
				tool.dataKey = gk
				local l = tool.pending
				if l ~= nil and l.key == gk then
					local found : integer
					l.speeds, found = curveSpeeds(data, #l.pieces - 1)
					l.speeds = alignment.carry(l.pieces, l.speeds, l.nodes)
					local bok, bs = pcall(function() : {readout.Badge}
						local out = readout.badges(l.nodes, l.z, l.speeds, l.curves)
						for _, b in ipairs(readout.alongBadges(l.nodes, l.z, l.speeds, BADGE_EVERY)) do out[#out + 1] = b end
						return out
					end)
					l.badges = bok and bs as {readout.Badge} or nil
					if not bok then say("badges: " .. tostring(bs)) end
					tool.line, tool.pending = l, nil
					if not tool.speedsLogged then
						tool.speedsLogged = true
						say(string.format("ghost: the game's curve limits for %d of %d pieces, %d curve badges",
							found, #l.pieces - 1, l.badges ~= nil and #l.badges or 0))
					end
				end
				if tool.errors ~= nil and tool.drag == nil and tool.errorsLogged ~= gk then
					tool.errorsLogged = gk
					say("ghost: " .. tool.errors:gsub("\n", "; "))
				end
			end,
			entityForRefundableContext = api.engine.util.getPlayer(),
			proposalId = "westrom_track_geometry_ghost_" .. gk,
		}
	end
	if tool.phase == "done" and tool.edit ~= nil then
		local ok, edges = pcall(vertical() and verticalEdges or editEdges)
		if ok then
			children[#children + 1] = builtin.EdgeRenderable{ edges = edges as {Builtin.Type.EdgeRenderable.Edge}, ignoreDepth = true }
		elseif tool.gizmoErr ~= tostring(edges) then
			tool.gizmoErr = tostring(edges)
			say("gizmo: " .. tool.gizmoErr)
		end
	end
	if tool.screen ~= nil and #tool.screen > 0 then
		children[#children + 1] = builtin.FullScreenComponent{ recipe = TgBadges as Recipe<any>, param = { items = tool.screen } as BadgesParam }
	end
	children[#children + 1] = builtin.ActionTooltip(tooltip())
	return builtin.ActionDescriptor{
		tool = "construction",
		onBack = function()
			if tool.confirmOpen then return end -- (the window takes Esc itself: Cancel)
			if backIsOurs() then backAction() else abort() end
		end,
		terrainCirclePolicy = "Never",
		children = children,
	}
end

-- An input action that is not ours must say Disabled (a plain false keeps the key and does nothing).
local function iaState(fn : function() : boolean) : function() : Gui.InputAction.InputActionState
	return function() : Gui.InputAction.InputActionState
		if fn() then return api.gui.inputAction.InputActionState.Enabled end
		return api.gui.inputAction.InputActionState.Disabled
	end
end

-- The menu entry's recipe: while the tool is the active menu item, put the tool into the world.
local TgToolAction = react.RegisterRecipe("TgToolAction", function(params : ConstructionCustomActionParams<any>) : TreeNodeId
	react.setRestrictMouseFocus(true)
	if not params.isActive then return nil end
	-- (right-click: the construction menu would close itself on the "back" input; while there is
	-- a step to go back, take it first)
	react.useInputAction("IA_CLOSE_TOPMOST_WINDOW", react.iaHandler(backAction, iaState(backIsOurs)))
	tool.gameCtx = params.gameCtx
	tool.getParams = params.getCurrentParams
	params.setActionFn(function() : TreeNodeId return toolAction(params.abort) end, "TgToolAction")
	return nil
end)

-- The track types on offer this year, without overhead wires (Electric picks each one's wired
-- version); default: standard. The picker's value is the picked template's id.
local function trackObjects() : {MenuCategoryUtil.FilterObject}, integer
	local out : {MenuCategoryUtil.FilterObject} = {}
	local best : integer = nil
	for _, o in ipairs(menu_category_util.getAvailableObjectsSorted(api.res.streetTemplateRep as ResTypeRep<integer, table>, api.engine.util.getYear())) do
		local ok, t = pcall(api.res.streetTemplateRep.get, o.id)
		local wired = ok and t ~= nil and (t as table).catenaryRemove ~= nil and (t as table).catenaryRemove ~= ""
		if ok and t ~= nil and (t as StreetTemplate).roadType == api.type["enum"].RoadType.TRACK and not wired then
			out[#out + 1] = o
			if api.res.streetTemplateRep.getName(o.id) == proposals.BASE_TEMPLATE then best = #out end
		end
	end
	return out, best or 1
end

-- The menu entry's settings (in its Settings window: a custom tool's getCurrentParams only
-- returns those, as Track Connector found).
local function toolParams() : {ConstructionMenuParam}
	return {
		{
			key = "tg_trackType",
			name = "Track",
			tooltip = "Track type to build",
			defaultIndex = 1,
			yearFrom = 0,
			yearTo = 0,
			location = api.type["enum"].ScriptParamLocation.Default,
			getFilterObjectsFn = trackObjects,
			resetOnDefinitionChange = false,
			resetOnCategoryChange = false,
			resetOnMenuClose = false,
		},
		{
			key = "tg_electric",
			name = "Electric",
			tooltip = "Build with overhead wires (the track type's electric version)",
			values = { "Off", "On" },
			defaultIndex = 1,
			uiType = api.type["enum"].ScriptParamType.Button,
			location = api.type["enum"].ScriptParamLocation.Default,
			yearFrom = 0,
			yearTo = 0,
		},
	}
end

-- The menu entry (the construction menu calls this through tg_tool.res.lua).
local function TgToolDefinition(resName : ResName, _repository : ConstructionActionRepository, _params : table) : ConstructionDefinition
	return {
		resName = resName,
		icon = { icon = "::/gui/construction/tools/track_switch.tga" },
		previewIcon = { icon = "::/gui/construction/tools/electrify_preview.tga" },
		name = "Track Geometry",
		description = "Lay new track between two track ends with clothoid transitions. Click a track end, then another one, then edit the path and click off it to build (you are asked first). A small window switches to the vertical alignment: press on the track to add an elevation point, drag it along the track, Shift-drag it up or down. Right-click a turn or point removes it; Esc goes back. The track type and Electric are in the Settings.",
		action = "ACTION_CUSTOM",
		availability = { yearFrom = 0, yearTo = 0 },
		params = toolParams(),
		menuCategory = { categories = { { category = "rail_tools", order = 6100 } } },
		customAction = { recipe = TgToolAction as Recipe<ConstructionCustomActionParams<any>>, customParam = nil },
	}
end

------------------------------------------------------------------ bottom bar

local TgProbe = react.RegisterRecipe("TgProbe", function() : TreeNodeId
	react.useRefLazy(function() : boolean
		resetTool()
		return true
	end)
	-- the ground under the mouse can only be read here: in the tool's own timer the game refuses it
	react.onStep(function()
		if not tool.active then return end
		local ok, pos = pcall(function() : Vec3f
			if not api.gui.mouse.hasTerrainPosition() then return nil end
			return api.gui.mouse.getTerrainPosition()
		end)
		if ok and pos ~= nil then tool.terrX, tool.terrY = pos.x, pos.y else tool.terrX, tool.terrY = nil, nil end
		local bok, err = pcall(placeBadges as function() : string)
		if not bok and tool.badgeErr ~= tostring(err) then
			tool.badgeErr = tostring(err)
			say("badges: " .. tool.badgeErr)
		end
	end)
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Horizontal, children = {} }
end)

return {
	TgProbe = TgProbe,
	TgToolDefinition = TgToolDefinition,
}
