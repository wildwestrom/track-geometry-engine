-- The tool's session: which step it is at (pick the start, pick the end, edit), the picked ends,
-- the edit and its mode, what is under the mouse and what is being dragged, and which click, right-
-- click or "back" means what. The GUI turns the game's callbacks into the events below and draws
-- from the session's fields. It reads them freely but never writes them: every change goes through
-- an event.
--
-- An event that needs something done outside returns requests, which the GUI carries out:
--   "openMode" / "closeMode" : the mode window
--   "askBuild"               : check the ghost and open the confirm window (then confirmOpened,
--                              or refuse with why not)
--   "closeConfirm"           : close the confirm window (then confirmClosed)
--   "ghostNow"               : make the ghost again at once (a drag ended)
--   "restart"                : the session started over: drop the ghost and what was read out
--
-- What only the game knows comes in as a World with each event. No game API here, so
-- test/session_test.lua runs it outside the game.

local ends = require("westrom_track_geometry::/track_geometry/tg_ends.script.tl")
local edits = require("westrom_track_geometry::/track_geometry/tg_edit.script.tl")

local enum Phase
	"from" -- pick the start
	"to" -- pick the end
	"done" -- both picked: editing
end

local enum Mode
	"horizontal" -- turns and curves
	"vertical" -- elevation points
end

local enum Request
	"openMode"
	"closeMode"
	"askBuild"
	"closeConfirm"
	"ghostNow"
	"restart"
end

local enum MouseKind
	"pressed"
	"released"
	"clicked"
	"moved"
	"other"
end

local type TrackEnd = ends.TrackEnd

-- An elevation point being dragged: along the path, or (Shift held at the press) up and down.
local record ElevationDrag
	i : integer
	height : boolean
	pressY : number -- the mouse's screen y at the press (px)
	pressZ : number -- the point's height at the press
end

-- What only the game knows, as of this event.
local record World
	terrX : number -- the ground under the mouse (nil when it is over none)
	terrY : number
	hovered : integer -- the entity under the mouse
	grab : number -- grab radius for handles (m)
	cameraDist : number -- the camera's distance (m), for a Shift-drag's height; nil when unknown
	shift : function() : boolean -- is Shift held (asked at a press)
	gradeLimit : function() : number -- the steepest grade the track type may be laid at
	snap : function(x : number, y : number, hovered : integer, exclude : integer) : TrackEnd, string -- the free end near (x, y), or nil and why
	endFree : function(node : integer) : boolean -- is this node still a free track end
end

local record Session
	phase : Phase
	mode : Mode -- while editing (kept when the session starts over)
	from : TrackEnd
	to : TrackEnd
	hover : TrackEnd -- end the mouse snaps to (while picking)
	hoverMsg : string -- why it snaps to none
	mouseX : number -- where the last snap looked
	mouseY : number
	edit : edits.Edit -- the alignment being edited (both ends picked)
	grab : number -- grab radius as of the last event (m)
	hit : edits.Hit -- what is under the mouse while editing (tg_edit.hit)
	drag : edits.Hit -- the turn or bracket being dragged
	dragEl : ElevationDrag -- the elevation point being dragged
	mouseSY : number -- the mouse's screen y, from its last event (px)
	editMsg : string -- why the last edit or build did not happen
	pressGrabbed : boolean -- the last left press grabbed a handle or added a turn (its click must not build)
	confirmOpen : boolean
	closedTick : integer -- tick the confirm window closed (the click that closed it must not open it again)
	ticks : integer -- ticks so far (the game's os.clock is CPU time over all threads: no use as a timer)
	rightTick : integer -- tick of the last right-button event
	backTick : integer -- tick of the last "back" acted on (one input's "back" arrives more than once)
	log : function(string)
	live : function() : boolean -- is the tool open and ticking (events are ignored when not)
end

local record SessionMod
	Phase : Phase
	Mode : Mode
	Request : Request
	MouseKind : MouseKind
	TrackEnd : TrackEnd
	ElevationDrag : ElevationDrag
	World : World
	Session : Session
	RIGHT_TICKS : integer
	CLOSED_TICKS : integer
	HEIGHT_PER_PX : number
	new : function(log : function(string), live : function() : boolean) : Session
	reset : function(s : Session)
	tick : function(s : Session, w : World) : {Request}
	mouse : function(s : Session, w : World, button : integer, kind : MouseKind, y : number) : boolean, {Request}
	click : function(s : Session) : {Request}
	backIsOurs : function(s : Session) : boolean
	back : function(s : Session, w : World) : {Request}
	canGoBack : function(s : Session) : boolean
	setMode : function(s : Session, m : Mode)
	confirmOpened : function(s : Session)
	confirmClosed : function(s : Session)
	refuse : function(s : Session, msg : string)
	blur : function(s : Session)
	vertical : function(s : Session) : boolean
	dragging : function(s : Session) : boolean
	handleName : function(h : edits.Hit) : string
end

local M : SessionMod = {}

M.RIGHT_TICKS = 8 -- a "back" input this many ticks (50 ms) after a right-click is that click
M.CLOSED_TICKS = 2 -- a click this many ticks after the confirm window closed is the one that closed it
M.HEIGHT_PER_PX = 0.001 -- a Shift-drag raises an elevation point this share of the camera's distance per pixel


-- the game runs Lua 5.2: two-argument atan is math.atan2 there
local atan2 : function(number, number) : number = (math as {string : any}).atan2 as function(number, number) : number
	or (math.atan as function(number, number) : number)

function M.new(logger : function(string), live : function() : boolean) : Session
	return { phase = "from", ticks = 0, log = logger, live = live }
end

function M.vertical(s : Session) : boolean
	return s.mode == "vertical"
end

function M.dragging(s : Session) : boolean
	return s.drag ~= nil or s.dragEl ~= nil
end

function M.handleName(h : edits.Hit) : string
	if h.kind == "pi" then return "turn " .. tostring(h.i - 1) end
	return (h.kind == "entry" and "start" or "end") .. " of the curve at turn " .. tostring(h.i - 1)
end

-- Out of editing, back to picking the end: the one place the edit and all that hangs on it goes.
local function leaveEditing(s : Session)
	s.phase, s.to, s.edit = "to", nil, nil
	s.drag, s.hit, s.dragEl = nil, nil, nil
	s.pressGrabbed, s.editMsg = false, nil
	s.hover, s.mouseX = nil, nil
end

-- Start over: pick the start again. The mode, the clocks and the confirm window's state stay.
function M.reset(s : Session)
	leaveEditing(s)
	s.phase, s.from, s.hoverMsg = "from", nil, nil
end

-- The mouse left the tool: it snaps to nothing.
function M.blur(s : Session)
	s.hover, s.mouseX = nil, nil
end

function M.setMode(s : Session, m : Mode)
	if s.mode == m then return end
	s.mode = m
	s.drag, s.hit, s.dragEl = nil, nil, nil
	s.editMsg = nil
	s.log("edit: " .. m .. " alignment")
end

function M.confirmOpened(s : Session)
	s.confirmOpen = true
end

function M.confirmClosed(s : Session)
	if not s.confirmOpen then return end
	s.confirmOpen = false
	s.closedTick = s.ticks
end

-- Something asked for could not be done (a build): say why in the tooltip.
function M.refuse(s : Session, msg : string)
	s.editMsg = msg
end

local function justClosed(s : Session) : boolean
	return s.closedTick ~= nil and s.ticks - s.closedTick <= M.CLOSED_TICKS
end

-- A click that is on nothing of the edit: ask to build, unless a press of this click grabbed
-- something, or the confirm window is open or was just closed by it.
local function askBuild(s : Session) : {Request}
	if s.phase ~= "done" or M.dragging(s) or s.pressGrabbed or s.confirmOpen or justClosed(s) then return {} end
	return { "askBuild" }
end

-- A left click: pick the end the mouse snaps to; with both picked, ask to build.
function M.click(s : Session) : {Request}
	if not s.live() or s.confirmOpen then return {} end
	if s.phase == "done" then return askBuild(s) end
	if s.hover == nil then
		s.log(string.format("tool: nothing to pick at %s: %s",
			s.mouseX ~= nil and string.format("%.0f, %.0f", s.mouseX, s.mouseY) or "?", s.hoverMsg or ""))
		return {}
	end
	local e = s.hover
	local reqs : {Request} = {}
	if s.phase == "from" then
		s.from, s.phase = e, "to"
		s.log(string.format("tool: start at node %d (%.1f, %.1f, %.1f) heading %.2f deg", e.node, e.x, e.y, e.z, math.deg(atan2(e.dy, e.dx))))
	else
		s.to, s.phase = e, "done"
		s.edit = edits.new(s.from as ends.End, e as ends.End)
		s.mode = s.mode or "horizontal"
		reqs[1] = "openMode"
		s.log(string.format("tool: end at node %d (%.1f, %.1f, %.1f) heading %.2f deg", e.node, e.x, e.y, e.z, math.deg(atan2(e.dy, e.dx))))
	end
	s.hover, s.mouseX = nil, nil
	return reqs
end

function M.canGoBack(s : Session) : boolean
	return s.live() and s.phase ~= "from"
end

local function stepBack(s : Session) : {Request}
	local reqs : {Request} = {}
	if s.phase == "done" then
		leaveEditing(s)
		reqs[1] = "closeMode"
	elseif s.phase == "to" then
		s.phase, s.from = "from", nil
	else
		return reqs
	end
	s.hover, s.mouseX = nil, nil
	s.log("tool: back to picking the " .. (s.phase == "to" and "end" or "start"))
	return reqs
end

------------------------------------------------------------------ editing

-- What is under the mouse now.
local function findHit(s : Session, w : World)
	s.hit = nil
	if s.edit == nil or w.terrX == nil then return end
	s.hit = edits.hit(s.edit, M.vertical(s), w.terrX, w.terrY, s.grab)
end

-- Vertical: grab the elevation point under the mouse, or add one on the track there and grab it.
local function pressV(s : Session, w : World) : boolean
	local e, h = s.edit, s.hit
	local i : integer
	if h ~= nil and h.kind == "point" then
		i = h.i
	elseif h ~= nil and h.kind == "track" then
		local why : string
		i, why = edits.insertElevation(e, h.s)
		if i == nil then s.editMsg = "Cannot add an elevation point here: " .. why; return true end
		s.log(string.format("edit: add elevation point %d at %.0f m (%d points)", i, h.s, #edits.points(e)))
	end
	if i == nil then return false end
	local height = w.shift ~= nil and w.shift() == true
	s.dragEl = { i = i, height = height, pressY = s.mouseSY, pressZ = edits.points(e)[i].z }
	s.log(string.format("edit: grab elevation point %d%s", i, height and " (height)" or ""))
	return true
end

-- Horizontal: grab the turn or bracket under the mouse, or add a turn on the leg there and grab it.
local function pressH(s : Session, w : World) : boolean
	local e, h = s.edit, s.hit
	if h ~= nil and h.kind == "leg" then
		local i, why = edits.insertOnLeg(e, h.i, w.terrX, w.terrY)
		if i == nil then s.editMsg = "Cannot add a turn here: " .. why; return true end
		s.drag = edits.turn(e, i)
		s.log(string.format("edit: add turn %d on leg %d (%d turns)", i - 1, h.i, edits.turnCount(e)))
		return true
	end
	if h == nil then return false end
	if h.kind == "pi" and h.mobility == "fixed" then
		s.editMsg = "This turn is next to both ends, so it cannot move. Add another turn first."
		return true
	end
	s.drag = h
	s.log("edit: grab " .. M.handleName(h))
	return true
end

-- Left button down: grab what is under the mouse, or add a turn (an elevation point) there and
-- grab it. false when there is nothing to grab (the press is left to the game).
local function press(s : Session, w : World) : boolean
	if s.phase ~= "done" or s.edit == nil or not s.live() then return false end
	findHit(s, w)
	s.editMsg = nil
	if M.vertical(s) then return pressV(s, w) end
	return pressH(s, w)
end

-- Left button up: let go of what is dragged.
local function release(s : Session) : {Request}
	local e = s.edit
	if s.dragEl ~= nil then
		local d = s.dragEl
		s.dragEl = nil
		local pt = e ~= nil and edits.points(e)[d.i] or nil
		if pt ~= nil then
			s.log(string.format("edit: elevation point %d at %.0f m, height %.2f m; steepest %.1f permille", d.i,
				pt.s, pt.z, edits.steepest(e) * 1000))
		end
		return { "ghostNow" }
	end
	if s.drag == nil then return {} end
	local h = s.drag
	s.drag = nil
	if e ~= nil then
		if h.kind == "pi" then
			local p = edits.polyline(e)[h.i]
			s.log(string.format("edit: %s at (%.1f, %.1f)", M.handleName(h), p.x, p.y))
		else
			s.log(string.format("edit: curve at turn %d: budget %.1f m", h.i - 1, edits.budget(e, h.i) or -1))
		end
	end
	return { "ghostNow" } -- (make the ghost of where it ended up now)
end

-- Right-click on a turn (or an elevation point) removes it; elsewhere it does nothing. true when
-- it removed one (or refused).
local function remove(s : Session, w : World) : boolean
	if s.phase ~= "done" or s.edit == nil or not s.live() or M.dragging(s) then return false end
	findHit(s, w)
	local h, e = s.hit, s.edit
	if M.vertical(s) then
		if h == nil or h.kind ~= "point" then
			s.log("edit: right-click on no elevation point: nothing to remove")
			return false
		end
		edits.removeElevation(e, h.i)
		s.log(string.format("edit: remove elevation point %d (%d left)", h.i, #edits.points(e)))
		s.hit = nil
		return true
	end
	if h == nil or h.kind ~= "pi" then
		s.log("edit: right-click on " .. (h ~= nil and h.kind ~= "leg" and M.handleName(h) or "no turn") .. ": nothing to remove")
		return false
	end
	local ok, why = edits.removePi(e, h.i)
	s.editMsg = not ok and ("Cannot remove this turn: " .. why) or nil
	if ok then s.log(string.format("edit: remove turn %d (%d left)", h.i - 1, edits.turnCount(e)))
	else s.log(string.format("edit: cannot remove turn %d: %s", h.i - 1, why)) end
	s.hit = nil
	return true
end

-- While dragging: move what is grabbed to the mouse.
local function dragTick(s : Session, w : World)
	local e = s.edit
	if e == nil then return end
	local d = s.dragEl
	if d ~= nil then
		local pt = edits.points(e)[d.i]
		if pt == nil then return end
		local at, z = pt.s, pt.z
		if d.height then
			if d.pressY == nil or s.mouseSY == nil then return end
			z = d.pressZ + (d.pressY - s.mouseSY) * M.HEIGHT_PER_PX * (w.cameraDist or 500.0)
		else
			if w.terrX == nil then return end
			at = edits.chainageAt(e, w.terrX, w.terrY)
		end
		edits.moveElevation(e, d.i, at, z, w.gradeLimit())
		return
	end
	local h, x, y = s.drag, w.terrX, w.terrY
	if h == nil or x == nil then return end
	if h.kind == "pi" then edits.movePi(e, h.i, x, y)
	else edits.dragBracket(e, h.i, h.kind == "entry", x, y) end
end

------------------------------------------------------------------ back

-- Right-click and Esc are the same "back" input. The right button shows up as a mouse event just
-- before it, so a "back" within RIGHT_TICKS of a right-click is that click. The game sends "back"
-- only for a click, not after a right-drag of the camera (and the tool never sees the right press),
-- so that "back" is the click. While editing, it removes the turn under the mouse and only Esc
-- steps back. While picking ends, right-click steps back and Esc closes the tool (as in Track
-- Connector). One input acts once, however many times its "back" arrives (selector, input action,
-- onBack).
local function rightRecent(s : Session) : boolean
	return s.rightTick ~= nil and s.ticks - s.rightTick <= M.RIGHT_TICKS
end
local function backRecent(s : Session) : boolean
	return s.backTick ~= nil and s.ticks - s.backTick <= M.RIGHT_TICKS
end

-- Is a "back" now the tool's own (else it closes the tool, or the confirm window takes it)?
function M.backIsOurs(s : Session) : boolean
	if s.confirmOpen then return false end -- (the window takes it)
	return backRecent(s) or (M.canGoBack(s) and (rightRecent(s) or s.phase == "done"))
end

-- The "back" input: Esc steps back; a right-click removes the turn under it while editing, and
-- steps back while picking ends.
function M.back(s : Session, w : World) : {Request}
	if backRecent(s) or not M.canGoBack(s) then return {} end
	s.backTick = s.ticks
	if s.phase == "done" and rightRecent(s) then
		s.grab = w.grab or s.grab or 10.0
		remove(s, w)
		return {}
	end
	return stepBack(s)
end

------------------------------------------------------------------ mouse and tick

-- A mouse event: button 0 is the left one, 2 the right one; y is its screen y (px). true when
-- the tool takes the event (else it is left to the game).
function M.mouse(s : Session, w : World, button : integer, kind : MouseKind, y : number) : boolean, {Request}
	if y ~= nil then s.mouseSY = y end -- (for a Shift-drag's height)
	if button == 2 then
		-- (only marks the "back" that follows as a right-click; the camera keeps the button)
		if kind ~= "moved" then s.rightTick = s.ticks end
		return false, {}
	end
	if button ~= 0 or not s.live() then return false, {} end
	-- (the confirm window takes the mouse; the click that closes it must do nothing here)
	if s.confirmOpen or justClosed(s) then return false, {} end
	if s.phase == "done" then
		if kind == "pressed" then
			s.grab = w.grab or s.grab or 10.0
			s.pressGrabbed = press(s, w)
			return s.pressGrabbed, {}
		end
		if kind == "released" or kind == "clicked" then
			local had = M.dragging(s) or s.pressGrabbed == true
			local reqs = release(s)
			if kind == "clicked" and not had then
				for _, r in ipairs(askBuild(s)) do reqs[#reqs + 1] = r end
				return true, reqs
			end
			return had, reqs
		end
		return false, {}
	end
	if kind ~= "clicked" then return false, {} end
	return true, M.click(s)
end

-- Every 50 ms while the tool is open: a picked end that is gone undoes its pick; while editing,
-- move what is dragged and find what is under the mouse; while picking, snap to the end there.
function M.tick(s : Session, w : World) : {Request}
	s.ticks = s.ticks + 1
	s.grab = w.grab or s.grab or 10.0
	local reqs : {Request} = {}
	if s.from ~= nil and not w.endFree(s.from.node) then
		s.log("tool: the start end is gone")
		M.reset(s)
		reqs = { "closeConfirm", "closeMode", "restart" }
	elseif s.to ~= nil and not w.endFree(s.to.node) then
		s.log("tool: the end is gone")
		leaveEditing(s)
		reqs = { "closeConfirm", "closeMode" }
	end
	if s.phase == "done" then
		if s.edit == nil then return reqs end -- (no alignment between these ends: the ghost says why)
		dragTick(s, w)
		if not M.dragging(s) then findHit(s, w) end
	else
		local x, y = w.terrX, w.terrY
		local moved = x == nil or s.mouseX == nil or math.abs(x - s.mouseX) + math.abs(y - s.mouseY) > 1.0
		if moved or s.hover == nil then
			s.mouseX, s.mouseY = x, y
			s.hover, s.hoverMsg = w.snap(x, y, w.hovered, s.phase == "to" and s.from.node or nil)
		end
	end
	return reqs
end

return M
