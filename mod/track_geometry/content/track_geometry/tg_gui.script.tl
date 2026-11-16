-- GUI. Three parts:
--   the tool (toolAction): the Track Geometry tool, in the drag builder's place on the game's track
--            entries while their Geometry row says Yes. Pick the start and the end (a track end, a
--            node, a point along a piece, or the ground), then edit the alignment (tg_edit, driven
--            by tg_session) under the game's ghost, and click off it to build (a window asks first).
--   TgProbe : a plugin in the bottom game bar (tg_probe.res.lua): every frame it reads the ground
--            under the mouse and places the badges for the tool (both only allowed there).
--   TgMenuPlugin : gives every track entry the "Geometry" row (tg_menu.res.lua), the only way in.

local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local styleutil = ug_require "::/gui/main/styleutil.tl" as StyleUtil
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local construction_react_util = ug_require "::/gui/construction/construction_react_util.tl" as ConstructionReactUtil
local dialog_react_util = ug_require "::/gui/menu/dialog_react_util.tl" as DialogReactUtil
local mod_entry_point = ug_require "::/gui/main/mod_entry_point.tl" as ModEntryPoint
local ends = require("westrom_track_geometry::/track_geometry/tg_ends.script.tl")
local edits = require("westrom_track_geometry::/track_geometry/tg_edit.script.tl")
local proposals = require("westrom_track_geometry::/track_geometry/tg_proposal.script.tl")
local readout = require("westrom_track_geometry::/track_geometry/tg_readout.script.tl")
local plans = require("westrom_track_geometry::/track_geometry/tg_plan.script.tl")
local sessions = require("westrom_track_geometry::/track_geometry/tg_session.script.tl")
local world = require("westrom_track_geometry::/track_geometry/tg_world.script.tl")

local TAG = "[westrom_track_geometry] "
local GHOST_TICKS = 4 -- while dragging, remake the ghost at most every this many tool ticks (50 ms)...
local GHOST_WAIT = 20 -- ...and only once the game has checked the last one, or this many ticks have passed
local GRAB = 0.02 -- grab radius for handles, as a share of the camera's distance
local LEG_STEP = 10.0 -- gizmo legs follow the ground in pieces this long (m)...
local MAX_LEG_PIECES = 60 -- ...or this many per leg, on long legs
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

------------------------------------------------------------------ tool state

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

-- The ghost: made anew whenever its key changes (and dropped when the tool starts over).
local record Ghost
	key : string
	proposal : SimpleProposal
	info : string -- its path: length and layout
	why : string -- why there is no ghost
	tick : integer -- tick it was made
	cost : integer
	errors : string
	critical : boolean -- the game refuses it
	hasErrors : boolean -- the game reports errors on it (warnings do not count)
	dataKey : string -- set when its data (cost, errors) has come
	logged : boolean -- its problems are logged
	pending : Pending -- its plan, until the game's data for it comes
end

local record ToolState
	active : boolean
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
	g : Ghost
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
end

local tool : ToolState = { g = {} }

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
	tool.g, tool.hovered, tool.vbadges, tool.line, tool.screen, tool.screenKey, tool.matchRedraws = {}, nil, nil, nil, nil, nil, nil
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

-- The game's own track builder has a "Geometry" row on every track entry (added by
-- decorate). With Yes the tool takes the builder's place (TgTrackAction) and builds the
-- picked entry's track, with the panel's bridge and tunnel types. One value for every track
-- entry; it lasts until the game is closed.
local GEO_KEY = "tg_geometry"

local record Geo
	on : boolean -- the row says Yes
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

-- What the ghost shows now: the path from the start to the end (picked, or under the mouse);
-- nothing before there are both. Remade only when its ends change.
local function updateGhost()
	local a, b : ends.End, ends.End = nil, nil
	if sess.phase == "from" then a = sess.hover
	elseif sess.phase == "to" then a, b = sess.from, sess.hover
	else a, b = sessions.ends(sess) end
	-- (the phase too: picking the hovered end makes it again once, which logs the path)
	local key = sess.phase .. ":" .. (a ~= nil and ends.key(a) or "-") .. ":" .. (b ~= nil and ends.key(b) or "-")
	if sess.phase == "done" then key = key .. ":" .. tostring(sess.edit.rev) end
	key = key .. ":" .. trackType().template
	-- (the panel's bridge and tunnel types: another pick makes the ghost again)
	key = key .. ":" .. tostring(panelValue("bridgeType")) .. ":" .. tostring(panelValue("tunnelType"))
	local g = tool.g
	if key == g.key then return end
	-- while dragging (or moving the mouse to the end, after the first click), the ghost lags behind:
	-- the game's check of each ghost (cost, collisions) is what makes a drag stutter, so a new one
	-- waits until the last is checked
	if (sessions.dragging(sess) or sess.phase == "to") and g.tick ~= nil then
		local since = (sess.ticks or 0) - g.tick
		if since < GHOST_TICKS then return end
		if g.proposal ~= nil and g.dataKey ~= g.key and since < GHOST_WAIT then return end
	end
	g = { key = key, tick = sess.ticks or 0 }
	tool.g = g
	-- (a path's line stays until the next one is read out)
	if a == nil or b == nil then tool.line = nil; return end
	-- bridges and tunnels where the track is far off the ground: their types first (without them,
	-- or when the ground cannot be read, the plan has none)
	local tt = trackType()
	local ground, water = world.ground, world.water
	local bridgeType, tunnelType = structureType("bridgeType", tt.bridgeType), structureType("tunnelType", tt.tunnelType)
	if tt.structuresWhy ~= nil then ground, water = nil, nil end -- (tg_world logged why)
	local plan, pwhy = plans.path(a, b, sess.edit, ground, water)
	if plan == nil then g.why = pwhy; tool.line = nil; return end
	if plan.note ~= nil then say("ghost: no structures: " .. plan.note) end
	local nodes, grades = plan.built.nodes, plan.grades
	local replace, runs = plans.switches(a, b, nodes, world.piecesAt, world.mergeable)
	local ok, p, why = pcall(proposals.make, nodes, { template = trackType().template, z = plan.built.z, grades = grades,
		from = a, to = b, replace = replace, runs = runs,
		kinds = plan.kinds, bridgeType = bridgeType, tunnelType = tunnelType })
	if not ok then g.why = "error: " .. tostring(p); say("ghost: " .. g.why); return end
	if p == nil then g.why = why; return end
	g.proposal = p as SimpleProposal
	g.pending = { key = key, plan = plan }
	g.info = plan.structures ~= nil and (plan.info .. "; " .. plan.structures) or plan.info
	if sess.phase == "done" and sess.drag == nil then
		say(string.format("tool: path %s: from %s (%.1f, %.1f) leaving %.2f deg, to %s (%.1f, %.1f) arriving %.2f deg, %d pieces, %d merged runs, grade %+.1f ‰ to %+.1f ‰",
			plan.info, ends.name(a), a.x, a.y, math.deg(nodes[1].heading), ends.name(b), b.x, b.y, math.deg(nodes[#nodes].heading), #nodes - 1, #runs, grades[1] * 1000, grades[#grades] * 1000))
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
	local g = tool.g
	if g.proposal == nil then return g.why or "there is no path" end
	if g.dataKey ~= g.key or g.cost == nil then return "the game is still checking it" end
	if g.critical then return "the game refuses it" end
	if g.hasErrors then return "the game reports errors on it" end
	local a, b = sessions.ends(sess)
	if not (world.joinable(a) and world.joinable(b)) then return "an end is gone or its track has changed" end
	local ok, bal = pcall(function() : integer return api.engine.util.finance.getPlayersBalance(api.engine.util.getPlayer()) end)
	-- (the game itself lets the account go negative)
	if ok and bal ~= nil and g.cost > (bal as integer) then return "not enough money" end
	return nil
end

local closeConfirm, closeModeWindow : function(), function() -- (below, with the windows)

-- Start over: close the windows, pick the start again and drop the ghost.
local function startOver()
	closeConfirm()
	closeModeWindow()
	sessions.reset(sess)
	resetTool()
end

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

local MODES : {sessions.Mode} = { "horizontal", "vertical" }

local run : function(reqs : {sessions.Request}) -- (below, with the session's adapter)

local record ModeParam -- (none: the window reads the session)
end

-- What the mode window shows changes with this: the mode, the selection, the edit and the
-- grade limit. (The window gets its params once, so it re-reads the session on a timer.)
local function modeKey() : string
	local e = sess.edit
	return table.concat({ sess.mode as string or "-", tostring(sess.selected), e ~= nil and tostring(e.rev) or "-",
		string.format("%.4f", gradeLimit()), tostring(tool.matchRedraws or 0) }, "|")
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

-- A small window to switch between editing the horizontal and the vertical alignment. Opened
-- from a click (as the confirm window; opening a window from onStep kills the game). A window
-- recipe must wrap builtin.Window (RegisterWrapperRecipe, as the game's own windows do): a plain
-- recipe returning one fails a native assertion in the window container (NodeStorage.cpp:51).
-- It sits at the bottom right of the screen, above the game bar (tg_gui.css.lua). In vertical
-- mode it has the Elevation section below the switch.
local TgModeWindow = react.RegisterWrapperRecipe("TgModeWindow", builtin.Window, function(_p : ModeParam, _ : any) : TreeNodeId
	local key = engine_react_util.useStepStateTimer(modeKey, 0.1)
	local _ = key:old()
	local isVertical = sessions.vertical(sess)
	local modes = builtin.ToggleButtonGroup{
		layout = "Horizontal", -- (each as wide as its label; "Uniform" squeezes them to nothing here)
		buttons = {
			{ content = builtin.TextView{ text = "Horizontal alignment" } },
			{ content = builtin.TextView{ text = "Vertical alignment" } },
		},
		-- (1-based, as the game's own toggle groups; from the session, not the params, as the
		-- window is drawn again on its timer)
		initialSelected = isVertical and 2 or 1,
		onValueChange = function(index : integer)
			if MODES[index] ~= nil then sessions.setMode(sess, MODES[index]) end
		end,
	}
	return builtin.Window{
		-- (no-close-button: the plain window surface, as the game's dialogs; the default one has a
		-- notch for the close button. Size and place: tg_gui.css.lua, by the id.)
		meta = { class = "no-close-button" },
		id = "tgmode",
		title = "Track Geometry",
		closable = false,
		movable = true,
		content = isVertical and builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical,
			children = { modes, elevationSection() } } or modes,
	}
end)

closeModeWindow = function()
	if not tool.modeOpen then return end
	tool.modeOpen = false
	closeWindow(TgModeWindow)
end

local function openModeWindow()
	if tool.modeOpen then return end
	if openWindow(TgModeWindow, {} as ModeParam, "mode window") then
		tool.modeOpen = true
		say("mode window: open")
	end
end

-- The ghost's path (its length and layout) and the readout l sums up, added to lines.
local function pathLines(lines : {string}, l : PlanLine)
	if tool.g.info == nil then return end
	lines[#lines + 1] = "Path: " .. tool.g.info
	if l == nil then return end
	local ok, more = pcall(plans.summary, l.readout, trackType().speed)
	if ok then for _, m in ipairs(more as {string}) do lines[#lines + 1] = m end end
end

-- What the confirm window says: the path, its readout, what the game warns about, and the cost.
local function confirmText(cost : integer) : string
	local a, b = sessions.ends(sess)
	local lines : {string} = { "New track from " .. ends.name(a) .. " to " .. ends.name(b),
		"Track: " .. trackType().name }
	local l, g = tool.line, tool.g
	pathLines(lines, l ~= nil and l.key == g.key and l or nil)
	if g.errors ~= nil then
		lines[#lines + 1] = ""
		for line in g.errors:gmatch("[^\n]+") do lines[#lines + 1] = line end
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
	local p, info, cost = tool.g.proposal, tool.g.info, tool.g.cost
	local from, to = sessions.ends(sess)
	if openWindow(dialog_react_util.DialogWindow, {
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
							sessions.refuse(sess, "Cannot build: an end is gone or its track has changed.")
							say("build: not sent: an end is gone or its track has changed")
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
		elseif r == "ghostNow" then tool.g.tick = nil
		elseif r == "restart" then resetTool()
		end
	end
end

local function backAction() run(sessions.back(sess, worldNow(false))) end

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
	run(sessions.tick(sess, worldNow(true)))
	if sess.phase == "done" and sessions.vertical(sess) then updateVBadges() else tool.vbadges = nil end
	updateGhost()
	local u, h = sess.drag, sess.hit
	return table.concat({ tostring(tool.opens or 0), sess.phase, tool.g.key or "-", tool.screenKey or "-", sess.hoverMsg or "", tostring(tool.g.cost), tool.g.errors or "",
		sess.edit ~= nil and tostring(sess.edit.rev) or "-", u ~= nil and (u.kind .. u.i) or "-", h ~= nil and (h.kind .. tostring(h.i)) or "-",
		string.format("%.0f", sess.grab or 0), sess.editMsg or "",
		sess.mode as string or "-", tostring(sess.dragEl ~= nil), cursorKey() }, "|")
end

local function tooltip() : Builtin.ActionTooltipParam<any>
	local lines : {string} = {}
	local good, bad = false, false
	local vertical, g = sessions.vertical(sess), tool.g
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
		if g.errors ~= nil then
			for line in g.errors:gmatch("[^\n]+") do lines[#lines + 1] = line end
			bad = true
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
		cost = g.cost,
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
local function curveSpeeds(data : ProposalData, m : integer) : {number}
	local out : {number} = {}
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
		if ok and v ~= nil then out[i] = v as number end
	end
	return out
end

------------------------------------------------------------------ curve badges

local BADGE_BG = { 0.16, 0.33, 0.55, 0.85 } -- as the track builder's own badges
local BADGE_SLOW = { 230 / 255, 109 / 255, 149 / 255, 0.95 } -- the slowest curve: the Speed Limit layer's "slow"
local BADGE_STEEP = { 0.8, 0.12, 0.12, 0.95 } -- a span too steep (past the grade limit)
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
	local style = styleutil.makeStyle{ backgroundColor = b.steep and BADGE_STEEP or b.slowest and BADGE_SLOW or BADGE_BG, anchorPoint = { 1.0, 1.0 } }
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

-- Every frame, from TgProbe (world2Screen is refused elsewhere): put the badges on the screen.
local function placeBadges()
	local l = tool.line
	local list, key : {readout.Badge}, string
	if sessions.vertical(sess) and sess.phase == "done" then
		list, key = tool.vbadges, "v" .. tostring(sess.edit.rev)
	elseif l ~= nil and tool.g.info ~= nil then
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
end

------------------------------------------------------------------ gizmos

local COLORS : {string : {number}} = {
	leg = { 1.0, 0.75, 0.1, 1.0 }, -- the PI polyline
	free = { 1.0, 0.75, 0.1, 1.0 }, -- turns
	ray = { 0.3, 0.8, 1.0, 1.0 },
	fixed = { 0.6, 0.6, 0.6, 1.0 },
	bracket = { 0.3, 1.0, 0.4, 1.0 },
	groundEnd = { 1.0, 0.75, 0.1, 1.0 }, -- a ground end: it moves anywhere, like a free turn
	hot = { 1.0, 1.0, 1.0, 1.0 }, -- under the mouse or dragged
	selected = { 1.0, 1.0, 0.1, 1.0 }, -- the selected elevation point (the mode window sets its height)
	tooClose = { 1.0, 0.15, 0.15, 0.4 }, -- an elevation point too close to a neighbour or an end
}

local GIZMO_STEP = 2.0 -- a gizmo is drawn in steps this long (m), unless it says otherwise

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
	g.width = width
	return paint(builtin.type.EdgeRenderable.Edge.new(g), c, width, step)
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
	return paint(builtin.type.EdgeRenderable.Edge.new(g), c, width, GIZMO_STEP)
end

-- The gizmos of the edit: the PI polyline, a circle at each turn (coloured by how it can move)
-- and a bracket at each curve's start and end, open towards its curve.
local function editEdges() : {Builtin.Type.EdgeRenderable.Edge}
	local e, r = sess.edit, sess.grab
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
			edges[#edges + 1] = circleEdge(h.x, h.y, z, r, isHot(h) and COLORS.hot or COLORS[h.mobility], w, GIZMO_STEP)
		elseif h.kind == "end" then
			edges[#edges + 1] = circleEdge(h.x, h.y, z, r, isHot(h) and COLORS.hot or COLORS.groundEnd, w, GIZMO_STEP)
		else
			-- a thin 〔: a bar across the leg, past the circles; at each end a slanted corner and
			-- then a tip along the leg, towards the curve
			local c = isHot(h) and COLORS.hot or COLORS.bracket
			local bar, tip = edits.BRACKET_BAR * r, edits.BRACKET_TIP * r
			local corner = tip / 2
			-- (a point `along` the leg towards the curve and `across` it)
			local function at(along : number, across : number) : number, number
				return h.x + h.ux * along - h.uy * across, h.y + h.uy * along + h.ux * across
			end
			local shape = { { tip, bar }, { corner, bar }, { 0, bar - corner }, { 0, corner - bar }, { corner, -bar }, { tip, -bar } }
			for k = 1, #shape - 1 do
				local x0, y0 = at(shape[k][1], shape[k][2])
				local x1, y1 = at(shape[k + 1][1], shape[k + 1][2])
				edges[#edges + 1] = straightEdge(x0, y0, z, x1, y1, z, c, w / 2)
			end
		end
	end
	return edges
end

-- The vertical gizmos: at each end and elevation point a circle on the ground (where the mouse
-- grabs it) and a post from the ground up to the track (a point's own height); grey at a track
-- end, amber at a ground end (its height can be set), white under the mouse, see-through red when
-- a point is too close (it is not in the profile).
local function verticalEdges() : {Builtin.Type.EdgeRenderable.Edge}
	local e, r = sess.edit, sess.grab
	local edges : {Builtin.Type.EdgeRenderable.Edge} = {}
	local w = math.max(0.5, r / 8)
	if edits.profile(e) == nil then return edges end
	local h, d = sess.hit, sess.dragEl
	local hot = d ~= nil and d.i or (h ~= nil and h.kind ~= "track" and h.i or nil)
	for i, pt in ipairs(edits.points(e)) do
		local c = not pt.liftable and COLORS.fixed or pt.tooClose and COLORS.tooClose or i == hot and COLORS.hot
			or i == sess.selected and COLORS.selected or pt.slides and COLORS.ray or COLORS.groundEnd
		local g = zAt(pt.x, pt.y)
		edges[#edges + 1] = circleEdge(pt.x, pt.y, g, r, c, w, GIZMO_STEP)
		if math.abs(pt.z - g) > 0.1 then
			-- (a hair off vertical: a straight with no run has no direction)
			edges[#edges + 1] = straightEdge(pt.x, pt.y, g, pt.x + 0.01, pt.y, pt.z, c, w)
		end
	end
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
	local gh = tool.g
	local viewer = false
	local a, b = sessions.ends(sess)
	if fresh and gh.proposal ~= nil and world.joinable(a) and world.joinable(b) and world.joinable(sess.hover) then
		local gk = gh.key
		viewer = true
		children[#children + 1] = builtin.ProposalViewer{
			simpleProposal = gh.proposal,
			controlPointInfo = cp,
			onCreateProposalData = function(data : ProposalData, _p : Proposal)
				local g = tool.g
				if data == nil or g.key ~= gk then return end
				g.cost = data.costs
				g.errors = proposalProblems(data)
				g.critical = data.errorState ~= nil and data.errorState.critical == true
				g.hasErrors = data.errorState ~= nil and #(data.errorState.messages or {}) > 0
				g.dataKey = gk
				local l = g.pending
				if l ~= nil and l.key == gk then
					local r, bwhy = plans.readout(l.plan, curveSpeeds(data, #l.plan.built.nodes - 1))
					if bwhy ~= nil then say("badges: " .. bwhy) end
					tool.line, g.pending = { key = gk, readout = r }, nil
				end
				if g.errors ~= nil and sess.drag == nil and not g.logged then
					g.logged = true
					say("ghost: " .. g.errors:gsub("\n", "; "))
				end
			end,
			entityForRefundableContext = api.engine.util.getPlayer(),
			proposalId = "westrom_track_geometry_ghost_" .. gk,
		}
	end
	-- no ghost: an empty proposal holds the control point
	if cp ~= nil and not viewer then
		children[#children + 1] = builtin.ProposalViewer{
			simpleProposal = api.type.SimpleProposal.new(),
			controlPointInfo = cp,
			proposalId = "westrom_track_geometry_cursor",
		}
	end
	local edges = fresh and sess.phase == "done" and guard("gizmo", sessions.vertical(sess) and verticalEdges or editEdges) or {}
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
			if sessions.backIsOurs(sess) then backAction() else closeMenu(abort) end
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
	if entry ~= tool.entry then say("track type: " .. entry) end
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
	react.useInputAction("IA_CLOSE_TOPMOST_WINDOW", react.iaHandler(backAction, function() : Gui.InputAction.InputActionState
		return sessions.backIsOurs(sess) and IAS.Enabled or IAS.Disabled
	end))
	bound:set(true)
	-- (a key per entry, as the game's own custom actions have: whether the menu would call a new
	-- entry's fn under an unchanged key is not known)
	params.setActionFn(function() : TreeNodeId return hostedAction(params, entry) end, "TgTrackAction:" .. entry)
	return nil
end)

local ENABLED : ConstructionMenuParam.CheckEnabledResult = "Enabled"
local DISABLED : ConstructionMenuParam.CheckEnabledResult = "Disabled"

-- The "Geometry" row, placed and kept as Real Track Cant's Cant row: one value in every category,
-- not reset by the menu, saved nowhere. The panel asks the row whether it is enabled with all
-- its values, on every look: that is where the tool reads them (the Replace Track tab is mode 2;
-- a custom action is given only the Settings window's values).
local function geoParam() : ConstructionMenuParam
	local p : ConstructionMenuParam = {
		key = GEO_KEY,
		group = "settings",
		name = "Geometry",
		-- (the game does not break a tooltip's lines itself)
		tooltip = "Lay the track with the Track Geometry tool instead of the built-in track builder tool.",
		values = { "No", "Yes" },
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

local function hasGeoRow(def : ConstructionDefinition) : boolean
	for _, p in ipairs(def.params or {}) do
		if p.key == GEO_KEY then return true end
	end
	return false
end

-- Give every track entry of the game's builder the Geometry row and the recipe (an entry with
-- another mod's custom action is left alone).
local function decorate(defs : {ConstructionDefinition})
	for _, def in ipairs(defs) do
		local ours = hasGeoRow(def)
		if def.action == "ACTION_TRACK_BUILDER_UPGRADER" and (ours or def.customAction == nil) then
			if not ours then
				def.params = def.params or {}
				table.insert(def.params, geoParam())
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
-- and tunnel types, Snapping and Geometry. Every other row, the game's or another mod's, belongs
-- to the drag builder.
local GEO_ROWS : {string : boolean} = { mode = true, bridgeType = true, tunnelType = true, disableSnapping = true, [GEO_KEY] = true }

-- The rows already greyed (weak: the menu makes new definitions on each opening).
local greyed : {ConstructionMenuParam : boolean} = setmetatable({}, { __mode = "k" })

-- Grey a row out while Geometry is Yes on the builder tab. A row the game or its mod hides or
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
