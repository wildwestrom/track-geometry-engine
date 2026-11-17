-- The tool's session: which step it is at (pick the start, pick the end, edit), the picked ends
-- (each a free track end, an existing node with track through it, a point along a piece, or a
-- point on the ground:
-- click, move, click; a node's direction is re-picked toward the other end until both are picked),
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
--   "ghostNow"               : make the ghost again at once (a drag ended, a height was set)
--   "restart"                : the session started over: drop the ghost and what was read out
--
-- What only the game knows comes in as a World with each event. No game API here, so
-- test/session_test.lua runs it outside the game.

local ends = require("westrom_track_geometry::/track_geometry/tg_ends.script.tl")
local edits = require("westrom_track_geometry::/track_geometry/tg_edit.script.tl")
local profiles = require("westrom_track_geometry::/track_geometry/tg_profile.script.tl")

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

local type End = ends.End

-- What the cursor (the end under the mouse) is on, which says how it is drawn (as the game's
-- builder draws its control point).
local enum CursorState
	"ground" -- picking: open ground
	"trackEnd" -- picking: snapped to a free track end, a node or a point along a piece
	"handle" -- editing: a ground end, turn or elevation point under the mouse
	"dragging" -- editing: one of those being dragged
end

-- The cursor: where it is, and how it is drawn. z nil is the ground there.
local record Cursor
	x : number
	y : number
	z : number
	state : CursorState
end

-- What the selected point's height can be matched to (the mode window's list): the start, another
-- point or the end, labelled with its height (only: where along the track read as a second
-- height), and its height (m).
local record MatchSource
	label : string
	z : number
end

-- The selected elevation point or ground end, read out for the mode window: its index
-- (tg_edit.points), its name ("Point 2", "Start", "End"), its chainage (m), height (m), and grade
-- there (nil when it is too close: it is not in the profile); and why the profile is too steep,
-- when it is (tg_edit.gradeProblem).
local record Selection
	i : integer
	name : string
	s : number
	z : number
	grade : number
	tooClose : boolean
	steep : string
end

-- A point of the profile being dragged (tg_edit.points): an elevation point along the path, or
-- (Shift held at the press) a point's or a ground end's height up and down.
local record ElevationDrag
	i : integer -- the point's index (tg_edit.points)
	height : boolean
	pressY : number -- the mouse's screen y at the press (px)
	pressZ : number -- the point's height at the press
end

-- What only the game knows, as of this event.
local record World
	terrX : number -- the ground under the mouse (nil when it is over none)
	terrY : number
	terrZ : number -- (its height)
	ray : edits.Ray -- the mouse's view ray, eye to that ground point (nil when unknown): picks the track up on its profile, over the ground
	hovered : integer -- the entity under the mouse
	grab : number -- grab radius for handles (m)
	cameraDist : number -- the camera's distance (m), for a Shift-drag's height; nil when unknown
	shift : function() : boolean -- is Shift held (asked at a press)
	gradeLimit : function() : number -- the steepest grade the track type may be laid at
	snap : function(x : number, y : number, z : number, hovered : integer, exclude : End) : End, string -- what the mouse at (x, y, z) picks (tg_ends.snap), or nil and why
	endThere : function(e : End) : boolean -- is this end still there (a free track end still free)
end

local record Session
	phase : Phase
	mode : Mode -- while editing (kept when the session starts over)
	from : End -- the picked start, until the end is picked (then the edit holds both: M.ends)
	hover : End -- end the mouse snaps to (while picking)
	hoverMsg : string -- why it snaps to none, or why the last click could not end the track there
	mouseX : number -- where the last snap looked
	mouseY : number
	edit : edits.Edit -- the alignment being edited: there exactly while phase is "done"
	grab : number -- grab radius as of the last event (m)
	hit : edits.Hit -- what is under the mouse while editing (tg_edit.hit)
	drag : edits.Hit -- the turn, bracket or ground end being dragged
	dragEl : ElevationDrag -- the elevation point being dragged
	selected : integer -- the selected elevation point or ground end (tg_edit.points; the mode window sets its height)
	mouseSY : number -- the mouse's screen y, from its last event (px)
	editMsg : string -- why the last edit or build did not happen
	pressGrabbed : boolean -- the last left press grabbed a handle or added a turn (its click must not build)
	confirmOpen : boolean
	closedTick : integer -- tick the confirm window closed (the click that closed it must not open it again)
	ticks : integer -- ticks so far (the game's os.clock is CPU time over all threads: no use as a timer)
	rightTick : integer -- tick of a right-button click whose "back" has not come yet
	lastMouse : string -- the last mouse event but a move ("button 2 clicked"), and its tick: for the log
	lastMouseTick : integer
	log : function(string)
	live : function() : boolean -- is the tool open and ticking (events are ignored when not)
end

local record SessionMod
	Session : Session
	Mode : Mode
	Request : Request
	MouseKind : MouseKind
	CursorState : CursorState
	Cursor : Cursor
	MatchSource : MatchSource
	World : World
	DEFAULT_GRAB : number
	new : function(log : function(string), live : function() : boolean) : Session
	reset : function(s : Session)
	ends : function(s : Session) : End, End
	tick : function(s : Session, w : World) : {Request}
	mouse : function(s : Session, w : World, button : integer, kind : MouseKind, y : number) : boolean, {Request}
	click : function(s : Session, w : World) : {Request}
	backIsOurs : function(s : Session) : boolean
	back : function(s : Session, w : World) : {Request}
	canGoBack : function(s : Session) : boolean
	setMode : function(s : Session, m : Mode)
	setHeight : function(s : Session, z : number) : {Request}
	selection : function(s : Session, limit : number) : Selection
	matchSources : function(s : Session) : {MatchSource}
	match : function(s : Session, m : MatchSource) : {Request}
	confirmOpened : function(s : Session)
	confirmClosed : function(s : Session)
	refuse : function(s : Session, msg : string)
	blur : function(s : Session)
	vertical : function(s : Session) : boolean
	dragging : function(s : Session) : boolean
	handleName : function(h : edits.Hit) : string
	hint : function(s : Session) : string
	cursor : function(s : Session) : Cursor
end

local M : SessionMod = {}

local CLOSED_TICKS = 2 -- a click this many ticks after the confirm window closed is the one that closed it
local HEIGHT_PER_PX = 0.001 -- a Shift-drag raises an elevation point this share of the camera's distance per pixel
M.DEFAULT_GRAB = 10.0 -- grab radius before the game gives one (m)

function M.new(logger : function(string), live : function() : boolean) : Session
	return { phase = "from", ticks = 0, grab = M.DEFAULT_GRAB, log = logger, live = live }
end

function M.vertical(s : Session) : boolean
	return s.mode == "vertical"
end

function M.dragging(s : Session) : boolean
	return s.drag ~= nil or s.dragEl ~= nil
end

-- A handle for a person: "start", "turn 2", "end of the curve at turn 1". An end hit (in either
-- mode) is "start" or "end".
function M.handleName(h : edits.Hit) : string
	if h.kind == "end" then return h.i == 1 and "start" or "end" end
	if h.kind == "pi" then return "turn " .. tostring(h.i - 1) end
	return (h.kind == "entry" and "start" or "end") .. " of the curve at turn " .. tostring(h.i - 1)
end

-- Drop what the mouse is on, holds and has selected (the mode switched, or the edit is left). A
-- dragged end stays where it is, as if let go.
local function dropHandles(s : Session)
	if s.edit ~= nil then edits.dropEnd(s.edit) end
	s.drag, s.hit, s.dragEl, s.selected = nil, nil, nil, nil
end

-- The picked ends: the start alone while picking the end, both (the edit's) while editing.
function M.ends(s : Session) : End, End
	if s.edit == nil then return s.from, nil end
	return edits.ends(s.edit)
end

-- Out of editing, back to picking the end: the one place the edit and all that hangs on it goes.
-- The start is the edit's (it may have been dragged).
local function leaveEditing(s : Session)
	if s.edit ~= nil then s.from = (edits.ends(s.edit)) end
	s.phase, s.edit = "to", nil
	dropHandles(s)
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
	dropHandles(s)
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
	return s.closedTick ~= nil and s.ticks - s.closedTick <= CLOSED_TICKS
end

-- A click that is on nothing of the edit: ask to build, unless a press of this click grabbed
-- something, or the confirm window is open or was just closed by it. Refused (why in the
-- tooltip, which names the point and where it is too steep) while an elevation point is too
-- close or the profile is too steep.
local function askBuild(s : Session, w : World) : {Request}
	if s.phase ~= "done" or M.dragging(s) or s.pressGrabbed or s.confirmOpen or justClosed(s) then return {} end
	local e = s.edit
	local whats, whys : {string}, {string} = {}, {}
	local close = edits.spacingProblem(e)
	if close ~= nil then whats[#whats + 1], whys[#whys + 1] = "an elevation point is too close", close end
	local steep = edits.gradeProblem(e, w.gradeLimit())
	if steep ~= nil then whats[#whats + 1], whys[#whys + 1] = "the profile is too steep", steep end
	if #whats > 0 then
		M.refuse(s, "Cannot build while " .. table.concat(whats, " and ") .. ".")
		s.log("build: not asked: " .. table.concat(whys, "; "))
		return {}
	end
	return { "askBuild" }
end

-- A left click: pick the end the mouse snaps to; with both picked, ask to build. Ends too close
-- for an alignment are refused (why in hoverMsg, until the mouse moves on).
function M.click(s : Session, w : World) : {Request}
	if not s.live() or s.confirmOpen then return {} end
	if s.phase == "done" then return askBuild(s, w) end
	if s.hover == nil then
		s.log("tool: nothing to pick: " .. (s.hoverMsg or ""))
		return {}
	end
	local e = s.hover
	local reqs : {Request} = {}
	if s.phase == "from" then
		s.from, s.phase = e, "to"
		s.log("tool: start at " .. ends.name(e))
	else
		-- (a node's direction is locked here, toward the other end)
		local from = ends.aim(s.from, e.x, e.y)
		e = ends.aim(e, from.x, from.y)
		local edit, how = edits.new(from, e)
		if edit == nil then
			s.hoverMsg = "Cannot end the track here: " .. how .. "."
			s.log("tool: cannot end at " .. ends.name(e) .. ": " .. how)
			return {}
		end
		s.from, s.phase, s.edit = nil, "done", edit
		s.mode = s.mode or "horizontal"
		reqs[1] = "openMode"
		s.log("tool: end at " .. ends.name(e) .. ", laid as " .. how)
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
	else
		s.phase, s.from = "from", nil
	end
	s.hover, s.mouseX = nil, nil
	s.log("tool: back to picking the " .. (s.phase == "to" and "end" or "start"))
	return reqs
end

------------------------------------------------------------------ editing

-- What is under the mouse now.
local function findHit(s : Session, w : World)
	s.hit = nil
	if w.terrX == nil then return end
	s.hit = edits.hit(s.edit, M.vertical(s), w.terrX, w.terrY, s.grab, w.ray)
end

-- Point k of the profile (tg_edit.points) for a person: "Start", "Point 2", "End".
local function pointName(e : edits.Edit, k : integer) : string
	if k == 1 then return "Start" end
	if k == #edits.points(e) then return "End" end
	return "Point " .. tostring(k - 1)
end

-- Vertical: select the point (or ground end) under the mouse and grab it, or add a point on the
-- track there and grab it. A press grabs a point's height with Shift held, else slides it along
-- the path; an end cannot slide, so without Shift it is only selected.
local function pressV(s : Session, w : World) : boolean
	local e, h = s.edit, s.hit
	local i : integer
	if h ~= nil and (h.kind == "point" or h.kind == "end") then
		i = h.i
	elseif h ~= nil and h.kind == "track" then
		local why : string
		i, why = edits.insertElevation(e, h.s)
		if i == nil then s.editMsg = "Cannot add an elevation point here: " .. why; return true end
		s.log("edit: add " .. pointName(e, i))
	end
	if i == nil then return false end
	s.selected = i -- (a click, a drag or adding one selects it)
	local height = w.shift ~= nil and w.shift() == true
	local pt = edits.points(e)[i]
	if not height and not pt.slides then return true end
	s.dragEl = { i = i, height = height, pressY = s.mouseSY, pressZ = pt.z }
	s.log("edit: grab " .. pointName(e, i))
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
	s.mouseX = nil
	s.log("edit: grab " .. M.handleName(h))
	return true
end

-- Left button down: grab what is under the mouse, or add a turn (an elevation point) there and
-- grab it. false when there is nothing to grab (the press is left to the game).
local function press(s : Session, w : World) : boolean
	findHit(s, w)
	s.editMsg = nil
	if M.vertical(s) then return pressV(s, w) end
	return pressH(s, w)
end

-- Left button up: let go of what is dragged.
local function release(s : Session) : {Request}
	local e = s.edit
	if s.dragEl ~= nil then
		s.dragEl = nil
		return { "ghostNow" }
	end
	if s.drag == nil then return {} end
	local h = s.drag
	s.drag = nil
	if h.kind == "end" then
		-- (dropped on track it is that end from here on, and a handle no more)
		edits.dropEnd(e)
		local a, b = edits.ends(e)
		local en = h.i == 1 and a or b
		if en.kind ~= "ground" then
			s.hit = nil
			s.log("edit: the " .. M.handleName(h) .. " dropped on " .. ends.name(en))
		end
	end
	return { "ghostNow" } -- (make the ghost of where it ended up now)
end

-- Right-click on a turn (or an elevation point) removes it; elsewhere it does nothing. true when
-- it removed one (or refused).
local function remove(s : Session, w : World) : boolean
	if M.dragging(s) then return false end
	findHit(s, w)
	local h, e = s.hit, s.edit
	if M.vertical(s) then
		if h == nil or h.kind ~= "point" then return false end
		s.log("edit: remove " .. pointName(e, h.i))
		edits.removeElevation(e, h.i)
		local sel = s.selected
		if sel == h.i then s.selected = nil elseif sel ~= nil and sel > h.i then s.selected = sel - 1 end
		s.hit = nil
		return true
	end
	if h == nil or h.kind ~= "pi" then return false end
	local ok, why = edits.removePi(e, h.i)
	s.editMsg = not ok and ("Cannot remove this turn: " .. why) or nil
	s.log("edit: remove " .. M.handleName(h) .. (ok and "" or ": " .. why))
	s.hit = nil
	return true
end

-- A ground end dragged: it becomes what the mouse snaps to, as a click picking it would (the
-- ground, or track there; never the other end): the edit's end moves. (Looked up again only when
-- the mouse has moved, like the picking snap.)
local function dragEnd(s : Session, w : World, h : edits.Hit)
	local x, y = w.terrX, w.terrY
	if w.terrZ == nil or (s.mouseX == x and s.mouseY == y) then return end
	s.mouseX, s.mouseY = x, y
	local e = s.edit
	local a, b = edits.ends(e)
	local to = w.snap(x, y, w.terrZ, w.hovered, h.i == 1 and b or a)
	if to == nil or not edits.moveEnd(e, h.i, to) then return end
	if h.i ~= 1 then h.i = edits.turnCount(e) + 2 end -- (turns may have come or gone)
end

-- While dragging: move what is grabbed to the mouse.
local function dragTick(s : Session, w : World)
	local e = s.edit
	local d = s.dragEl
	if d ~= nil then
		local pt = edits.points(e)[d.i]
		local at, z = pt.s, pt.z
		if d.height then
			if d.pressY == nil or s.mouseSY == nil then return end
			z = d.pressZ + (d.pressY - s.mouseSY) * HEIGHT_PER_PX * (w.cameraDist or 500.0)
		else
			if w.terrX == nil then return end
			-- (along the view ray when known: the track may be far above the ground under the mouse)
			local rs = w.ray ~= nil and edits.chainageOnRay(e, w.ray) or nil
			at = rs or edits.chainageAt(e, w.terrX, w.terrY)
		end
		local _, j = edits.movePoint(e, d.i, at, z, w.gradeLimit())
		d.i, s.selected = j, j -- (passing a neighbour reorders the points)
		return
	end
	local h, x, y = s.drag, w.terrX, w.terrY
	if h == nil or x == nil then return end
	if h.kind == "pi" then edits.movePi(e, h.i, x, y)
	elseif h.kind == "end" then dragEnd(s, w, h)
	else edits.dragBracket(e, h.i, h.kind == "entry", x, y) end
end

-- Set the selected elevation point's (or ground end's) height to z (the mode window's height box):
-- as asked, past the grade limit too (the build is then refused until it is eased). Nothing when
-- none is selected.
function M.setHeight(s : Session, z : number) : {Request}
	local e, i = s.edit, s.selected
	local pt = i ~= nil and edits.points(e)[i] or nil
	if pt == nil or pt.z == z or not edits.setHeight(e, i, z) then return {} end -- (the box may echo the height it was given)
	s.log(string.format("edit: %s set to %.2f m", pointName(e, i), z))
	return { "ghostNow" }
end

-- The selected elevation point or ground end, read out against the grade limit; nil when none is.
function M.selection(s : Session, limit : number) : Selection
	local e, i = s.edit, s.selected
	local pt = i ~= nil and edits.points(e)[i] or nil
	if pt == nil then return nil end
	local p = edits.profile(e)
	return { i = i, name = pointName(e, i), s = pt.s, z = pt.z, grade = not pt.tooClose and p ~= nil and profiles.gradeAt(p, pt.s) or nil,
		tooClose = pt.tooClose, steep = (edits.gradeProblem(e, limit)) }
end

-- What the selected point's (or ground end's) height can be matched to, in order along the track:
-- the start, every other point (one too close too: its height is its own), the end; never itself.
-- Empty when none is selected.
function M.matchSources(s : Session) : {MatchSource}
	local out : {MatchSource} = {}
	if s.selected == nil then return out end
	for k, pt in ipairs(edits.points(s.edit)) do
		local shown = math.abs(pt.z) < 0.05 and 0.0 or pt.z -- (never "-0.0 m")
		if k ~= s.selected then out[#out + 1] = { label = string.format("%s · %.1f m", pointName(s.edit, k), shown), z = pt.z } end
	end
	return out
end

-- Set the selected point's height to that of m (an entry of matchSources, as the player saw it:
-- the list may be a redraw behind), once (it does not follow its source).
function M.match(s : Session, m : MatchSource) : {Request}
	if m == nil or m.z == nil then return {} end
	return M.setHeight(s, m.z)
end

------------------------------------------------------------------ back

-- Right-click and Esc are the same "back" input, and each press brings exactly one (seen in game:
-- by the action's onBack only). A right-click's "back" comes in the frame of its right-button
-- "clicked" event, so a "back" then is that click; the game sends neither after a right-drag of
-- the camera (and the tool never sees the right press). While editing, a right-click removes the
-- turn under the mouse and only Esc steps back. After the first click, either drops the start;
-- before it, Esc closes the tool.

-- Is this "back" a right-click's? (Its mark is taken: a later Esc is Esc. The mark lasts a tick
-- at most, in case the click's "back" never comes.)
local function takeRight(s : Session) : boolean
	local right = s.rightTick ~= nil and s.ticks - s.rightTick <= 1
	if not right then
		-- (logged, to tell in the game's log a right-click taken for an Esc: its mark too old or missing)
		local h = s.hit
		s.log("back: as Esc at tick " .. s.ticks .. " (" .. s.phase .. (s.mode and ", " .. s.mode or "")
			.. (h and ", over " .. h.kind .. " " .. tostring(h.i) or ", over nothing") .. "); "
			.. (s.rightTick and "right click at tick " .. s.rightTick or "no right click") .. "; "
			.. (s.lastMouse and "last mouse: " .. s.lastMouse .. " at tick " .. s.lastMouseTick or "no mouse event"))
	end
	s.rightTick = nil
	return right
end

-- Is a "back" now the tool's own (else it closes the tool, or the confirm window takes it)?
function M.backIsOurs(s : Session) : boolean
	if s.confirmOpen then return false end -- (the window takes it)
	return M.canGoBack(s)
end

-- The "back" input: Esc steps back; a right-click removes the turn under it while editing, and
-- else steps back.
function M.back(s : Session, w : World) : {Request}
	local right = takeRight(s)
	if not M.canGoBack(s) then return {} end
	if s.phase == "done" and right then
		s.grab = w.grab or s.grab
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
	if kind ~= "moved" then s.lastMouse, s.lastMouseTick = "button " .. button .. " " .. kind, s.ticks end
	if button == 2 then
		-- (only marks the "back" that follows a click as a right-click; the camera keeps the button)
		if kind == "clicked" then s.rightTick = s.ticks end
		return false, {}
	end
	if button ~= 0 or not s.live() then return false, {} end
	-- (the confirm window takes the mouse; the click that closes it must do nothing here)
	if s.confirmOpen or justClosed(s) then return false, {} end
	if s.phase == "done" then
		if kind == "pressed" then
			s.grab = w.grab or s.grab
			s.pressGrabbed = press(s, w)
			return s.pressGrabbed, {}
		end
		if kind == "released" or kind == "clicked" then
			local had = M.dragging(s) or s.pressGrabbed == true
			local reqs = release(s)
			if kind == "clicked" and not had then
				for _, r in ipairs(askBuild(s, w)) do reqs[#reqs + 1] = r end
				return true, reqs
			end
			return had, reqs
		end
		return false, {}
	end
	if kind ~= "clicked" then return false, {} end
	return true, M.click(s, w)
end

-- The controls for what is under the mouse, as one line for the tooltip: while picking, the click
-- on the end the mouse snaps to; while editing, what the handle there does. nil while dragging, or
-- while picking over no end. Read off the same hit a press and a right-click act on (press, remove).
function M.hint(s : Session) : string
	if s.phase ~= "done" then
		if s.hover == nil then return nil end
		return s.phase == "from" and "Click: start here" or "Click: end here"
	end
	if M.dragging(s) then return nil end
	local h = s.hit
	if h == nil then return "Click: build · Esc: back" end
	if h.kind == "point" then return "Click: select · Drag: slide · Shift+drag: height · Right-click: remove" end
	if h.kind == "track" then return "Click: add point" end
	if h.kind == "leg" then return "Click: add turn" end
	if h.kind == "end" then
		if M.vertical(s) then return "Click: select · Shift+drag: height · The " .. M.handleName(h) .. " cannot slide" end
		return "Drag: move the " .. M.handleName(h)
	end
	if h.kind == "pi" then
		if h.mobility == "fixed" then return "Fixed until another turn is added" end
		if h.mobility == "ray" then return "Drag: slide along the end" end
		return "Drag: move · Right-click: remove"
	end
	return "Drag: curve size" -- (a bracket)
end

-- The cursor: while picking, on the end the mouse snaps to; while editing, on the ground end, turn
-- or elevation point under the mouse or dragged (where it is now; a ground end in vertical mode
-- too). nil on anything else (a bracket, a leg, the track, nothing): those have gizmos of their
-- own.
function M.cursor(s : Session) : Cursor
	if s.phase ~= "done" then
		local h = s.hover
		if h == nil then return nil end
		return { x = h.x, y = h.y, z = h.z, state = h.kind == "ground" and "ground" or "trackEnd" }
	end
	local e = s.edit
	local state : CursorState = M.dragging(s) and "dragging" or "handle"
	local hit = s.hit
	if M.vertical(s) then
		local k = s.dragEl ~= nil and s.dragEl.i or hit ~= nil and hit.kind ~= "track" and hit.i or nil
		local pt = k ~= nil and edits.points(e)[k] or nil
		return pt ~= nil and { x = pt.x, y = pt.y, state = state } or nil
	end
	local handle = s.drag or hit
	if handle == nil or (handle.kind ~= "pi" and handle.kind ~= "end") then return nil end
	if s.drag ~= nil and handle.kind == "end" then
		-- (a dragged end on track: shown as the picking snap shows it)
		local a, b = edits.ends(e)
		local en = handle.i == 1 and a or b
		if en.kind ~= "ground" then return { x = en.x, y = en.y, z = en.z, state = "trackEnd" } end
	end
	local p = edits.polyline(e)[handle.i]
	return { x = p.x, y = p.y, state = state }
end

-- Every 50 ms while the tool is open: a picked end that is gone undoes its pick; while editing,
-- move what is dragged and find what is under the mouse; while picking, snap to the end there
-- (so after the first click the ghost follows the mouse). After the first click, a node at either
-- end points toward the other end (the start: toward the mouse when it snaps to none).
function M.tick(s : Session, w : World) : {Request}
	s.ticks = s.ticks + 1
	s.grab = w.grab or s.grab
	local reqs : {Request} = {}
	local a, b = M.ends(s)
	if a ~= nil and not w.endThere(a) then
		s.log("tool: the start end is gone")
		M.reset(s)
		reqs = { "closeConfirm", "closeMode", "restart" }
	elseif b ~= nil and not w.endThere(b) then
		s.log("tool: the end is gone")
		leaveEditing(s)
		reqs = { "closeConfirm", "closeMode" }
	end
	if s.phase == "done" then
		dragTick(s, w)
		if not M.dragging(s) then findHit(s, w) end
	else
		local x, y = w.terrX, w.terrY
		local moved = x == nil or s.mouseX == nil or math.abs(x - s.mouseX) + math.abs(y - s.mouseY) > 1.0
		if moved or s.hover == nil then
			s.mouseX, s.mouseY = x, y
			s.hover, s.hoverMsg = w.snap(x, y, w.terrZ, w.hovered, s.phase == "to" and s.from or nil)
			if s.phase == "to" and s.hover ~= nil then s.hover = ends.aim(s.hover, s.from.x, s.from.y) end
		end
		if s.phase == "to" then
			local at = s.hover
			s.from = at ~= nil and ends.aim(s.from, at.x, at.y) or ends.aim(s.from, x, y)
		end
	end
	return reqs
end

return M
