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
local alignment = require("westrom_track_geometry::/track_geometry/tg_alignment.script.tl")
local ends = require("westrom_track_geometry::/track_geometry/tg_ends.script.tl")
local edits = require("westrom_track_geometry::/track_geometry/tg_edit.script.tl")
local proposals = require("westrom_track_geometry::/track_geometry/tg_proposal.script.tl")
local readout = require("westrom_track_geometry::/track_geometry/tg_readout.script.tl")
local profiles = require("westrom_track_geometry::/track_geometry/tg_profile.script.tl")
local plans = require("westrom_track_geometry::/track_geometry/tg_plan.script.tl")
local sessions = require("westrom_track_geometry::/track_geometry/tg_session.script.tl")
local world = require("westrom_track_geometry::/track_geometry/tg_world.script.tl")

local TAG = "[westrom_track_geometry] "
local GHOST_TICKS = 4 -- while dragging, remake the ghost at most every this many tool ticks (50 ms)...
local GHOST_WAIT = 20 -- ...and only once the game has checked the last one, or this many ticks have passed
local GRAB = 0.02 -- grab radius for handles, as a share of the camera's distance
local LEG_STEP = 10.0 -- gizmo legs follow the ground in pieces this long (m)...
local MAX_LEG_PIECES = 60 -- ...or this many per leg, on long legs

-- the game runs Lua 5.2: two-argument atan is math.atan2 there
local atan2 : function(number, number) : number = (math as {string : any}).atan2 as function(number, number) : number
	or (math.atan as function(number, number) : number)

local function say(msg : string)
	print(TAG .. msg)
end

------------------------------------------------------------------ tool state

local type TrackEnd = sessions.TrackEnd

-- The ghost's plan (tg_plan), waiting for the game's proposal data: its curve speed limits.
local record Pending
	key : string -- ghost key
	plan : plans.Plan
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
	ticked : boolean -- the tool has ticked since it opened (until then its state is the last opening's)
	opens : integer -- how often the tool has closed: in the redraw key, so the first tick always redraws
	frame : integer -- frames drawn so far (counted by TgProbe, every frame)
	tickFrame : integer -- the frame of the tool's last tick
	hovered : integer -- entity under the mouse (Selector)
	terrX : number -- ground under the mouse (read every frame by TgProbe)
	terrY : number
	ghost : SimpleProposal
	ghostKey : string
	ghostInfo : string -- the ghost's path: length and layout
	ghostWhy : string -- why there is no ghost
	ghostTick : integer -- tick the ghost was last made
	vbadges : {readout.Badge} -- the profile's badges (vertical mode)
	modeOpen : boolean -- the mode window is open
	gizmoErr : string -- last gizmo error logged
	cost : integer
	errors : string
	critical : boolean -- the game refuses the ghost
	hasErrors : boolean -- the game reports errors on the ghost (warnings do not count)
	dataKey : string -- ghost key whose data (cost, errors) came last
	buildMsg : string -- how the last build went (kept when the tool starts over)
	gameCtx : GameContext -- for the confirm window
	getParams : function() : {string : number} -- the menu entry's settings (track type, electric)
	template : string -- the track template to build, from the settings (read every tick)
	errorsLogged : string -- ghost key whose problems were last logged
	pending : Pending -- the ghost's plan, until the game's data for it comes
	line : PlanLine -- the plan as last read out: badges at its curves, summed up in the tooltip
	screen : {ScreenBadge} -- the line's badges on the screen (placed by TgProbe every frame)
	screenKey : string -- changes when the badges move on the screen
	badgeErr : string -- last error placing them (logged once)
	speedsLogged : boolean
	grabNow : number -- grab radius at the last tick (m)
	camDist : number -- the camera's distance at the last tick (m); nil when unknown
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

-- Drop the ghost and what was read out (the session starts over by itself).
local function resetTool()
	tool = { active = tool.active, terrX = tool.terrX, terrY = tool.terrY, buildMsg = tool.buildMsg,
		gameCtx = tool.gameCtx, getParams = tool.getParams, template = tool.template, modeOpen = tool.modeOpen,
		grabNow = tool.grabNow, camDist = tool.camDist, frame = tool.frame, tickFrame = tool.tickFrame, ticked = tool.ticked,
		opens = tool.opens }
end

------------------------------------------------------------------ track type

-- The track template to build: the menu settings' track type, with overhead wires if Electric is
-- on (the type's wired version, its catenaryAdd). Read every tick: the settings can change while
-- the tool is open, and the ghost (its key holds the template) is then made again.
local function trackTemplate() : string
	return tool.template or world.BASE_TEMPLATE
end

-- What the tool knows about that template (tg_world caches it).
local function trackType() : world.TrackType
	return world.trackType(trackTemplate())
end

local function readTemplate()
	if tool.getParams == nil then return end
	local ok, raw = pcall(tool.getParams)
	if not ok or raw == nil then return end
	local el = raw["tg_electric"]
	-- (the Electric switch's values count from 1: 1 Off, 2 On)
	local name = world.templateFor(raw["tg_trackType"], el ~= nil and math.floor(el + 0.5) == 2)
	if name ~= tool.template then
		say("track type: " .. name)
		tool.template = name
	end
end

-- What the ghost shows now: the path from the start to the end (picked, or under the mouse), or
-- a stub at the start or the end under the mouse. Remade only when its ends change.
local function updateGhost()
	local a, b : TrackEnd, TrackEnd = nil, nil
	if sess.phase == "from" then a = sess.hover
	elseif sess.phase == "to" then a, b = sess.from, sess.hover
	else a, b = sess.from, sess.to end
	-- (the phase too: picking the hovered end makes it again once, which logs the path)
	local key = sess.phase .. ":" .. (a ~= nil and tostring(a.node) or "-") .. ":" .. (b ~= nil and tostring(b.node) or "-")
	if sess.phase == "done" and sess.edit ~= nil then key = key .. ":" .. tostring(sess.edit.rev) end
	key = key .. ":" .. trackTemplate()
	if key == tool.ghostKey then return end
	-- while dragging, the ghost lags behind the handles: the game's check of each ghost (cost,
	-- collisions) is what makes a drag stutter, so a new one waits until the last is checked
	if (sess.drag ~= nil or sess.dragEl ~= nil) and tool.ghostTick ~= nil then
		local since = (sess.ticks or 0) - tool.ghostTick
		if since < GHOST_TICKS then return end
		if tool.ghost ~= nil and tool.dataKey ~= tool.ghostKey and since < GHOST_WAIT then return end
	end
	tool.ghostTick = sess.ticks or 0
	tool.ghostKey, tool.ghost, tool.ghostInfo, tool.ghostWhy, tool.cost, tool.errors = key, nil, nil, nil, nil, nil
	tool.critical, tool.hasErrors, tool.dataKey = nil, nil, nil
	tool.pending = nil
	if a == nil or b == nil then tool.line = nil end -- (a path's line stays until the next one is read out)
	if a == nil then return end
	-- bridges and tunnels where the track is far off the ground: their types first (without them,
	-- or when the ground cannot be read, the plan has none)
	local tt = trackType()
	local ground, water = world.ground, world.water
	local bridgeType, tunnelType = tt.bridgeType, tt.tunnelType
	if tt.structuresWhy ~= nil then ground, water = nil, nil end -- (tg_world logged why)
	local plan, pwhy : plans.Plan, string
	if b == nil then plan = plans.stub(a as ends.End, ground, water)
	else plan, pwhy = plans.path(a as ends.End, b as ends.End, sess.phase == "done" and sess.edit or nil, ground, water) end
	if plan == nil then tool.ghostWhy = pwhy; tool.line = nil; return end
	if plan.note ~= nil then say("ghost: no structures: " .. plan.note) end
	local nodes, grades = plan.built.nodes, plan.grades
	local ok, p, why = pcall(proposals.make, nodes, { template = trackTemplate(), z = plan.built.z, grades = grades,
		startNode = a.node, endNode = b ~= nil and b.node or nil,
		kinds = plan.kinds, bridgeType = bridgeType, tunnelType = tunnelType })
	if not ok then tool.ghostWhy = "error: " .. tostring(p); say("ghost: " .. tool.ghostWhy); return end
	if p == nil then tool.ghostWhy = why; return end
	tool.ghost = p as SimpleProposal
	if b ~= nil then
		tool.pending = { key = key, plan = plan }
		tool.ghostInfo = plan.structures ~= nil and (plan.info .. "; " .. plan.structures) or plan.info
		if sess.phase == "done" and sess.drag == nil then
			say(string.format("tool: path %s: from node %d (%.1f, %.1f) leaving %.2f deg, to node %d (%.1f, %.1f) arriving %.2f deg, %d pieces, grade %+.1f ‰ to %+.1f ‰",
				plan.info, a.node, a.x, a.y, math.deg(nodes[1].heading), b.node, b.x, b.y, math.deg(nodes[#nodes].heading), #nodes - 1, grades[1] * 1000, grades[#grades] * 1000))
			say(string.format("tool: end headings: start %.2f deg, end %.2f deg (the ends' own directions)",
				math.deg(atan2(a.dy, a.dx)), math.deg(atan2(-b.dy, -b.dx))))
		end
	end
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
	if not (world.joinable(sess.from.node) and world.joinable(sess.to.node)) then return "an end is gone or no longer free" end
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
		sessions.refuse(sess, "Cannot build: " .. tostring(err))
		say("build: " .. tostring(err))
		return
	end
	say(string.format("build: sent %s, cost %s", info or "?", tostring(cost)))
	closeModeWindow()
	sessions.reset(sess)
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
	if not sess.confirmOpen then return end
	sessions.confirmClosed(sess)
	local wa = windowApi()
	if wa ~= nil then pcall(function() : string wa.removeAllWindows(dialog_react_util.DialogWindow); return nil end) end
end

------------------------------------------------------------------ the mode window

local MODES : {sessions.Mode} = { "horizontal", "vertical" }

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
				if MODES[index] ~= nil then sessions.setMode(sess, MODES[index]) end
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
		wa.addSingletonWindow(TgModeWindow, { selected = sess.mode == "vertical" and 2 or 1 } as ModeParam)
		return nil
	end)
	if ok and wa ~= nil then
		tool.modeOpen = true
		say("mode window: open")
	else
		say("mode window: failed: " .. tostring(wa == nil and "no window container" or err))
	end
end

-- What the confirm window says: the path, its readout, what the game warns about, and the cost.
local function confirmText(cost : integer) : string
	local lines : {string} = { string.format("New track from node %d to node %d", sess.from.node, sess.to.node),
		"Track: " .. trackType().name }
	if tool.ghostInfo ~= nil then lines[#lines + 1] = "Path: " .. tool.ghostInfo end
	local l = tool.line
	if l ~= nil and l.key == tool.ghostKey then
		local ok, more = pcall(plans.summary, l.readout, trackType().speed)
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

-- The session asks to build (a click while editing that grabbed nothing): a window shows what
-- would be built and asks first.
local function openConfirm()
	local why = cannotBuild()
	if why ~= nil then
		sessions.refuse(sess, "Cannot build: " .. why .. ".")
		say("build: not sent: " .. why)
		return
	end
	local p, info, cost = tool.ghost, tool.ghostInfo, tool.cost
	local from, to = sess.from.node, sess.to.node
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
						-- (an end may have gone, or been built on, while the window was open)
						if not (world.joinable(from) and world.joinable(to)) then
							sessions.refuse(sess, "Cannot build: an end is gone or no longer free.")
							say("build: not sent: an end is gone or no longer free")
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
		sessions.confirmOpened(sess)
		say(string.format("build: asking to confirm %s, cost %s", info or "?", tostring(cost)))
	else
		-- no window could be shown: never build without asking
		say("build: confirm window failed: " .. tostring(wa == nil and "no window container" or err))
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
	local a, b = sess.from, sess.to
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

---------------------------------------------------- editing the vertical alignment

local function vertical() : boolean
	return sessions.vertical(sess)
end

local function gradeLimit() : number
	return trackType().maxGrade
end

-- The profile's badges (grade at each point and halfway between), for the badge layer.
local function updateVBadges()
	local e = sess.edit
	if e == nil then tool.vbadges = nil; return end
	local prof = edits.profile(e)
	tool.vbadges = prof ~= nil and readout.profileBadges(edits.nodes(e), prof, plans.BADGE_EVERY) or nil
end

------------------------------------------------------------------ the session's adapter

local function snapEnd(x : number, y : number, hovered : integer, exclude : integer) : TrackEnd, string
	local near, onHovered, sawTrack = world.endsNear(x, y, hovered)
	return ends.snap(near, onHovered, sawTrack, x, y, exclude)
end
local function endFree(n : integer) : boolean
	return world.freeEnd(n) ~= nil
end
local function shiftHeld() : boolean
	return api.gui.inputAction.modifierOnlyActionIsActive("IA_PRECISION_MODE")
end

-- What the session needs from the game, as of now. fresh (the tool's tick): read the camera
-- again; else (a mouse or "back" event) as it was at the last tick.
local function worldNow(fresh : boolean) : sessions.World
	if fresh then
		tool.grabNow = grabRadius()
		local ok, cam = pcall(function() : number return api.gui.camera.getCameraData().z end)
		tool.camDist = ok and cam ~= nil and cam == cam and cam as number or nil
	end
	return { terrX = tool.terrX, terrY = tool.terrY, hovered = tool.hovered, grab = tool.grabNow, cameraDist = tool.camDist,
		shift = shiftHeld, gradeLimit = gradeLimit, snap = snapEnd, endFree = endFree }
end

-- Carry out what the session asks for.
local function run(reqs : {sessions.Request})
	for _, r in ipairs(reqs) do
		if r == "openMode" then openModeWindow()
		elseif r == "closeMode" then closeModeWindow()
		elseif r == "closeConfirm" then closeConfirm()
		elseif r == "askBuild" then openConfirm()
		elseif r == "ghostNow" then tool.ghostTick = nil
		elseif r == "restart" then resetTool()
		end
	end
end

local function backIsOurs() : boolean
	return sessions.backIsOurs(sess)
end
local function backAction()
	run(sessions.back(sess, worldNow(false)))
end

-- Every 50 ms while the tool is open: the session's tick, then keep the ghost up to date.
-- Returns a key that changes whenever the tool must draw again.
local function toolTick() : string
	tool.tickFrame, tool.ticked = tool.frame or 0, true
	readTemplate()
	run(sessions.tick(sess, worldNow(true)))
	if sess.phase == "done" and vertical() then updateVBadges() else tool.vbadges = nil end
	updateGhost()
	local u, h = sess.drag, sess.hit
	return table.concat({ tostring(tool.opens or 0), sess.phase, tool.ghostKey or "-", tool.screenKey or "-", sess.hoverMsg or "", tostring(tool.cost), tool.errors or "",
		sess.edit ~= nil and tostring(sess.edit.rev) or "-", u ~= nil and (u.kind .. u.i) or "-", h ~= nil and (h.kind .. tostring(h.i)) or "-",
		tostring(sess.drag ~= nil), string.format("%.0f", sess.grab or 0), sess.editMsg or "",
		sess.mode as string or "-", tostring(sess.dragEl ~= nil) }, "|")
end

local function tooltip() : Builtin.ActionTooltipParam<any>
	local lines : {string} = {}
	local good, bad = false, false
	local function path()
		if tool.ghostInfo ~= nil then lines[#lines + 1] = "Path: " .. tool.ghostInfo end
		local l = tool.line
		if l ~= nil and tool.ghostInfo ~= nil then
			local ok, more = pcall(plans.summary, l.readout, trackType().speed)
			if ok then for _, m in ipairs(more as {string}) do lines[#lines + 1] = m end end
		end
		if tool.ghostWhy ~= nil then lines[#lines + 1] = "No path: " .. tool.ghostWhy; bad = true end
		if tool.errors ~= nil then
			for line in tool.errors:gmatch("[^\n]+") do lines[#lines + 1] = line end
			bad = true
		end
	end
	if sess.phase == "from" then
		if sess.hover ~= nil then
			lines[1], good = "Start the new track here. Then click where it should end.", true
		else
			lines[1] = "Track Geometry: click the end of a track to start."
			if sess.hoverMsg ~= nil then lines[2] = sess.hoverMsg end
		end
		if tool.buildMsg ~= nil then lines[#lines + 1] = tool.buildMsg; bad = true end
	elseif sess.phase == "to" then
		if sess.hover ~= nil then
			lines[1], good = "Click to end the new track here.", true
			path()
		else
			lines[1] = "Now click the end of another track."
			if sess.hoverMsg ~= nil then lines[2] = sess.hoverMsg end
		end
		lines[#lines + 1] = "Right-click to go back."
	elseif vertical() then
		local d, h = sess.dragEl, sess.hit
		if d ~= nil then
			lines[1] = d.height and "Raising or lowering the elevation point (move the mouse up or down)."
				or "Sliding the elevation point along the track."
		elseif h ~= nil and h.kind == "point" then
			lines[1] = "Drag to slide this elevation point along the track; Shift-drag to raise or lower it. Right-click to remove it."
		elseif h ~= nil and h.kind == "track" then
			lines[1] = "Press to add an elevation point here (and drag it; Shift for its height)."
		else
			lines[1] = "Press on the track to add an elevation point. Drag a point to slide it; Shift-drag for its height."
		end
		lines[#lines + 1] = string.format("Grade limit: %.0f ‰ (the editor keeps within it)", gradeLimit() * 1000)
		if sess.editMsg ~= nil then lines[#lines + 1] = sess.editMsg; bad = true end
		path()
		lines[#lines + 1] = "Click elsewhere to build. Esc to go back."
	else
		local h = sess.drag or sess.hit
		if sess.drag ~= nil then
			lines[1] = "Dragging the " .. sessions.handleName(h) .. "."
		elseif h ~= nil and h.kind == "pi" then
			if h.mobility == "fixed" then lines[1] = "This turn is next to both ends and cannot move. Add another turn first."
			elseif h.mobility == "ray" then lines[1] = "Drag to slide this turn along its end's line. (Next to an end: it stays.)"
			else lines[1] = "Drag to move this turn. Right-click to remove it." end
		elseif h ~= nil and h.kind ~= "leg" then
			lines[1] = "Drag to resize the curve (the " .. sessions.handleName(h) .. ")."
		elseif h ~= nil then
			lines[1] = "Press and drag to add a turn here."
		else
			lines[1] = "Drag a turn or a curve's bracket. Press on the track to add a turn."
		end
		if sess.editMsg ~= nil then lines[#lines + 1] = sess.editMsg; bad = true end
		path()
		lines[#lines + 1] = "Click elsewhere to build. Esc to go back."
	end
	local param : ConstructionReactUtil.SimpleTooltipRecipeParams = {
		message = { message = table.concat(lines, "\n"), good = good and not bad, bad = bad },
		cost = tool.cost,
	}
	return { recipe = construction_react_util.SimpleTooltipRecipe as Recipe<any>, param = param }
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

-- A curve's badge: its speed and grade; an elevation point's: its height and grade; halfway
-- between two: the grade.
local function badgeRows(b : readout.Badge) : {TreeNodeId}
	local grade = badgeRow(slopeIcon(b.grade), string.format("%+.0f ‰", b.grade * 1000))
	if b.kind == "point" then return { builtin.TextView{ meta = { styleSheet = styleutil.makeStyle{ color = BADGE_TEXT } }, text = string.format("%.1f m", b.z) }, grade } end
	if b.kind == "span" or b.kind == "grade" then return { grade } end
	-- (the game's curve limit, but no faster than the track itself)
	local top = trackType().speed
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
	if vertical() and sess.phase == "done" then
		list, key = tool.vbadges, "v" .. (sess.edit ~= nil and tostring(sess.edit.rev) or "-")
	elseif l ~= nil and tool.ghostInfo ~= nil then
		list, key = l.readout.badges, l.key
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
	local e, r = sess.edit, sess.grab or 10.0
	local w = math.max(0.5, r / 8)
	local hot = sess.drag or sess.hit
	local function isHot(h : edits.Hit) : boolean return hot ~= nil and hot.kind == h.kind and hot.i == h.i end
	local edges : {Builtin.Type.EdgeRenderable.Edge} = {}
	local pis = edits.polyline(e)
	for i = 1, #pis - 1 do
		local a, b = pis[i], pis[i + 1]
		local c = (sess.drag == nil and hot ~= nil and hot.kind == "leg" and hot.i == i) and COLORS.hot or COLORS.leg
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
	for _, h in ipairs(edits.handles(e)) do
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
	local e, r = sess.edit, sess.grab or 10.0
	local edges : {Builtin.Type.EdgeRenderable.Edge} = {}
	if e == nil then return edges end
	local w = math.max(0.5, r / 8)
	local prof = edits.profile(e)
	if prof == nil then return edges end
	local nodes = edits.nodes(e)
	local function post(s : number, c : {number})
		local x, y = alignment.pointAt(nodes, s)
		local g, z = zAt(x, y), profiles.heightAt(prof, s)
		edges[#edges + 1] = circleEdge(x, y, g, r, c, w)
		if math.abs(z - g) > 0.1 then
			-- (a hair off vertical: a straight with no run has no direction)
			edges[#edges + 1] = straightEdge(x, y, g, x + 0.01, y, z, c, w)
		end
	end
	post(0, COLORS.fixed)
	post(edits.length(e), COLORS.fixed)
	local h = sess.hit
	local hot = sess.dragEl ~= nil and sess.dragEl.i or (h ~= nil and h.kind == "point" and h.i or nil)
	for i, pt in ipairs(edits.points(e)) do post(pt.s, i == hot and COLORS.hot or COLORS.ray) end
	return edges
end

-- The tool in the world: the selector (clicks), the ghost and the tooltip.
local function toolAction(abort : function()) : TreeNodeId
	tool.active = true
	react.onMount(function(_ : any) tool.active = true end)
	react.onUnmount(function(_ : any)
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
				run(sessions.click(sess))
				return true
			end,
			onSelectSecondary = function(_e : Engine.Entity, _i : {integer}, _d : Gui.SelectionDetails) : boolean
				if sess.phase == "done" and toolLive() then return true end -- (its "back" removes the turn)
				if not sessions.canGoBack(sess) then return false end
				backAction()
				return true
			end,
			filter = world.isTrackEdge,
			-- a left click anywhere counts (the selector alone only reports clicks on a track piece)
			onProcessMouseEvent = function(evt : Gui.Mouse.Event) : boolean
				local T = api.gui.mouse.Event.Type
				local kind : sessions.MouseKind = evt.type == T.Pressed and "pressed" or evt.type == T.Released and "released"
					or evt.type == T.Clicked and "clicked" or evt.type == T.Moved and "moved" or "other"
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
	local g = tool.ghost
	if fresh and g ~= nil and (sess.from == nil or world.joinable(sess.from.node)) and (sess.to == nil or world.joinable(sess.to.node))
		and (sess.hover == nil or world.joinable(sess.hover.node)) then
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
					local m = #l.plan.built.nodes - 1
					local speeds, found = curveSpeeds(data, m)
					local r, bwhy = plans.readout(l.plan, speeds)
					if bwhy ~= nil then say("badges: " .. bwhy) end
					tool.line, tool.pending = { key = gk, readout = r }, nil
					if not tool.speedsLogged then
						tool.speedsLogged = true
						say(string.format("ghost: the game's curve limits for %d of %d pieces, %d curve badges",
							found, m, r.badges ~= nil and #r.badges or 0))
					end
				end
				if tool.errors ~= nil and sess.drag == nil and tool.errorsLogged ~= gk then
					tool.errorsLogged = gk
					say("ghost: " .. tool.errors:gsub("\n", "; "))
				end
			end,
			entityForRefundableContext = api.engine.util.getPlayer(),
			proposalId = "westrom_track_geometry_ghost_" .. gk,
		}
	end
	if fresh and sess.phase == "done" and sess.edit ~= nil then
		local ok, edges = pcall(vertical() and verticalEdges or editEdges)
		if ok then
			children[#children + 1] = builtin.EdgeRenderable{ edges = edges as {Builtin.Type.EdgeRenderable.Edge}, ignoreDepth = true }
		elseif tool.gizmoErr ~= tostring(edges) then
			tool.gizmoErr = tostring(edges)
			say("gizmo: " .. tool.gizmoErr)
		end
	end
	if fresh and tool.screen ~= nil and #tool.screen > 0 then
		children[#children + 1] = builtin.FullScreenComponent{ recipe = TgBadges as Recipe<any>, param = { items = tool.screen } as BadgesParam }
	end
	if fresh then children[#children + 1] = builtin.ActionTooltip(tooltip()) end
	return builtin.ActionDescriptor{
		tool = "construction",
		onBack = function()
			if sess.confirmOpen then return end -- (the window takes Esc itself: Cancel)
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
			if api.res.streetTemplateRep.getName(o.id) == world.BASE_TEMPLATE then best = #out end
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
		sessions.confirmClosed(sess)
		sessions.reset(sess)
		resetTool()
		return true
	end)
	-- the ground under the mouse can only be read here: in the tool's own timer the game refuses it
	react.onStep(function()
		tool.frame = (tool.frame or 0) + 1
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
