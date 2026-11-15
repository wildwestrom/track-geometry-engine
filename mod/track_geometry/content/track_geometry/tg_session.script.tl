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

-- The selected elevation point or ground end, read out for the mode window: its name ("Point 2",
-- "Start", "End"), what tells it apart (selectedKey), its chainage (m), height (m), and grade
-- there (nil when it is too close: it is not in the profile); and why the profile is too steep,
-- when it is (tg_edit.gradeProblem).
local record Selection
	name : string
	key : string
	s : number
	z : number
	grade : number
	tooClose : boolean
	steep : string
end

-- An elevation point being dragged: along the path, or (Shift held at the press) up and down. Or
-- a ground end's height (Shift held at the press: an end cannot slide).
local record ElevationDrag
	i : integer -- the point's index, or the end's (1 or the last turn index)
	isEnd : boolean
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
	from : End
	to : End
	hover : End -- end the mouse snaps to (while picking)
	hoverMsg : string -- why it snaps to none, or why the last click could not end the track there
	mouseX : number -- where the last snap looked
	mouseY : number
	edit : edits.Edit -- the alignment being edited (both ends picked)
	grab : number -- grab radius as of the last event (m)
	hit : edits.Hit -- what is under the mouse while editing (tg_edit.hit)
	drag : edits.Hit -- the turn, bracket or ground end being dragged
	dragEl : ElevationDrag -- the elevation point being dragged
	selected : integer -- the selected elevation point (the mode window sets its height)...
	selectedEnd : integer -- ...or ground end (1 or the last turn index); one of the two at most
	mouseSY : number -- the mouse's screen y, from its last event (px)
	editMsg : string -- why the last edit or build did not happen
	pressGrabbed : boolean -- the last left press grabbed a handle or added a turn (its click must not build)
	confirmOpen : boolean
	closedTick : integer -- tick the confirm window closed (the click that closed it must not open it again)
	ticks : integer -- ticks so far (the game's os.clock is CPU time over all threads: no use as a timer)
	rightTick : integer -- tick of a right-button click whose "back" has not come yet
	log : function(string)
	live : function() : boolean -- is the tool open and ticking (events are ignored when not)
end

local record SessionMod
	Phase : Phase
	Mode : Mode
	Request : Request
	MouseKind : MouseKind
	CursorState : CursorState
	Cursor : Cursor
	ElevationDrag : ElevationDrag
	Selection : Selection
	MatchSource : MatchSource
	World : World
	Session : Session
	CLOSED_TICKS : integer
	HEIGHT_PER_PX : number
	new : function(log : function(string), live : function() : boolean) : Session
	reset : function(s : Session)
	tick : function(s : Session, w : World) : {Request}
	mouse : function(s : Session, w : World, button : integer, kind : MouseKind, y : number) : boolean, {Request}
	click : function(s : Session, w : World) : {Request}
	backIsOurs : function(s : Session) : boolean
	back : function(s : Session, w : World) : {Request}
	canGoBack : function(s : Session) : boolean
	setMode : function(s : Session, m : Mode)
	setHeight : function(s : Session, z : number) : {Request}
	selection : function(s : Session, limit : number) : Selection
	selectedKey : function(s : Session) : string
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
	s.drag, s.hit, s.dragEl, s.selected, s.selectedEnd = nil, nil, nil, nil, nil
end

-- Select elevation point i, or (isEnd) ground end i.
local function selectHandle(s : Session, i : integer, isEnd : boolean)
	if isEnd then s.selected, s.selectedEnd = nil, i else s.selected, s.selectedEnd = i, nil end
end

-- Out of editing, back to picking the end: the one place the edit and all that hangs on it goes.
local function leaveEditing(s : Session)
	s.phase, s.to, s.edit = "to", nil, nil
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
	return s.closedTick ~= nil and s.ticks - s.closedTick <= M.CLOSED_TICKS
end

-- A click that is on nothing of the edit: ask to build, unless a press of this click grabbed
-- something, or the confirm window is open or was just closed by it. Refused (why in the
-- tooltip, which names the point and where it is too steep) while an elevation point is too
-- close or the profile is too steep.
local function askBuild(s : Session, w : World) : {Request}
	if s.phase ~= "done" or M.dragging(s) or s.pressGrabbed or s.confirmOpen or justClosed(s) then return {} end
	local e = s.edit
	local whats, whys : {string}, {string} = {}, {}
	if e ~= nil then
		local close = edits.spacingProblem(e)
		if close ~= nil then whats[#whats + 1], whys[#whys + 1] = "an elevation point is too close", close end
		local steep = edits.gradeProblem(e, w.gradeLimit())
		if steep ~= nil then whats[#whats + 1], whys[#whys + 1] = "the profile is too steep", steep end
	end
	if #whats > 0 then
		M.refuse(s, "Cannot build while " .. table.concat(whats, " and ") .. ".")
		s.log("build: not asked: " .. table.concat(whys, "; "))
		return {}
	end
	return { "askBuild" }
end

-- An end for the log: what it is, where, and its heading when it has one.
local function describe(e : End) : string
	local out = string.format("%s (%.4f, %.4f, %.2f)", ends.name(e), e.x, e.y, e.z)
	if not ends.hasHeading(e) then return out end
	return out .. string.format(" heading %.6f deg (%.9f, %.9f)", math.deg(atan2(e.dy, e.dx)), e.dx, e.dy)
end

-- A left click: pick the end the mouse snaps to; with both picked, ask to build. Ends too close
-- for an alignment are refused (why in hoverMsg, until the mouse moves on).
function M.click(s : Session, w : World) : {Request}
	if not s.live() or s.confirmOpen then return {} end
	if s.phase == "done" then return askBuild(s, w) end
	if s.hover == nil then
		s.log(string.format("tool: nothing to pick at %s: %s",
			s.mouseX ~= nil and string.format("%.0f, %.0f", s.mouseX, s.mouseY) or "?", s.hoverMsg or ""))
		return {}
	end
	local e = s.hover
	local reqs : {Request} = {}
	if s.phase == "from" then
		s.from, s.phase = e, "to"
		s.log("tool: start at " .. describe(e))
	else
		-- (a node's direction is locked here, toward the other end)
		local from = ends.aim(s.from, e.x, e.y)
		e = ends.aim(e, from.x, from.y)
		local edit, how = edits.new(from, e)
		if edit == nil then
			s.hoverMsg = "Cannot end the track here: " .. how .. "."
			s.log("tool: cannot end at " .. describe(e) .. ": " .. how)
			return {}
		end
		s.from, s.to, s.phase, s.edit = from, e, "done", edit
		s.log("tool: laid as " .. how)
		s.mode = s.mode or "horizontal"
		reqs[1] = "openMode"
		s.log("tool: end at " .. describe(e))
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
	s.hit = edits.hit(s.edit, M.vertical(s), w.terrX, w.terrY, s.grab, w.ray)
end

-- End i (1 or the last turn index) for a person, and its height (m).
local function endName(i : integer) : string
	return i == 1 and "start" or "end"
end
local function endHeight(e : edits.Edit, i : integer) : number
	local za, zb = edits.endHeights(e)
	return i == 1 and za or zb
end

-- Vertical, on a ground end: select it, and with Shift held grab its height (it never slides).
local function pressEnd(s : Session, w : World, i : integer) : boolean
	selectHandle(s, i, true)
	local height = w.shift ~= nil and w.shift() == true
	if not height then s.log("edit: select the " .. endName(i)); return true end
	s.dragEl = { i = i, isEnd = true, height = true, pressY = s.mouseSY, pressZ = endHeight(s.edit, i) }
	s.log("edit: grab the " .. endName(i) .. "'s height")
	return true
end

-- Vertical: grab the elevation point under the mouse, or add one on the track there and grab it.
-- On a ground end, pressEnd.
local function pressV(s : Session, w : World) : boolean
	local e, h = s.edit, s.hit
	local i : integer
	if h ~= nil and h.kind == "end" then return pressEnd(s, w, h.i) end
	if h ~= nil and h.kind == "point" then
		i = h.i
	elseif h ~= nil and h.kind == "track" then
		local why : string
		i, why = edits.insertElevation(e, h.s)
		if i == nil then s.editMsg = "Cannot add an elevation point here: " .. why; return true end
		local pts = edits.points(e)
		s.log(string.format("edit: add elevation point %d at %.0f m (%d points)%s", i, h.s, #pts,
			pts[i].tooClose and ", too close" or ""))
	end
	if i == nil then
		s.log(string.format("edit: press on no elevation point or track (ground %s, view ray %s)",
			w.terrX ~= nil and string.format("%.0f, %.0f", w.terrX, w.terrY) or "none", w.ray ~= nil and "known" or "unknown"))
		return false
	end
	local height = w.shift ~= nil and w.shift() == true
	s.dragEl = { i = i, height = height, pressY = s.mouseSY, pressZ = edits.points(e)[i].z }
	selectHandle(s, i, false) -- (a click, a drag or adding one selects it)
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
	s.mouseX = nil
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
		local pt = e ~= nil and not d.isEnd and edits.points(e)[d.i] or nil
		if e ~= nil and d.isEnd then
			s.log(string.format("edit: %s at height %.2f m; steepest %.1f permille", endName(d.i),
				endHeight(e, d.i), edits.steepest(e) * 1000))
		elseif pt ~= nil then
			s.log(string.format("edit: elevation point %d at %.0f m, height %.2f m; steepest %.1f permille%s", d.i,
				pt.s, pt.z, edits.steepest(e) * 1000, pt.tooClose and string.format("; too close (%.0f m)", pt.gap) or ""))
		end
		return { "ghostNow" }
	end
	if s.drag == nil then return {} end
	local h = s.drag
	s.drag = nil
	if e ~= nil then
		if h.kind == "end" then
			-- (dropped on track it is that end from here on, and a handle no more)
			edits.dropEnd(e)
			local en = h.i == 1 and s.from or s.to
			if en.kind ~= "ground" then
				if s.selectedEnd ~= nil and (s.selectedEnd == 1) == (h.i == 1) then s.selectedEnd = nil end
				s.hit = nil
				s.log("edit: the " .. (h.i == 1 and "start" or "end") .. " dropped on " .. describe(en))
			end
		end
		if h.kind == "pi" or h.kind == "end" then
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
			s.log("edit: right-click on " .. (h ~= nil and h.kind == "end" and ("the " .. M.handleName(h) .. ", which stays")
				or "no elevation point") .. ": nothing to remove")
			return false
		end
		edits.removeElevation(e, h.i)
		local sel = s.selected
		if sel == h.i then s.selected = nil elseif sel ~= nil and sel > h.i then s.selected = sel - 1 end
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

-- A ground end dragged: it becomes what the mouse snaps to, as a click picking it would (the
-- ground, or track there; never the other end). Its edit's end moves, and so does the picked end
-- the ghost is made from. (Looked up again only when the mouse has moved, like the picking snap.)
local function dragEnd(s : Session, w : World, h : edits.Hit)
	local x, y = w.terrX, w.terrY
	if w.terrZ == nil or (s.mouseX == x and s.mouseY == y) then return end
	s.mouseX, s.mouseY = x, y
	local e = s.edit
	local a, b = edits.ends(e)
	local to = w.snap(x, y, w.terrZ, w.hovered, h.i == 1 and b or a)
	if to == nil or not edits.moveEnd(e, h.i, to) then return end
	local last = edits.turnCount(e) + 2 -- (turns may have come or gone)
	if h.i ~= 1 then h.i = last end
	if s.selectedEnd ~= nil and s.selectedEnd ~= 1 then s.selectedEnd = last end
	s.from, s.to = edits.ends(e)
end

-- While dragging: move what is grabbed to the mouse.
local function dragTick(s : Session, w : World)
	local e = s.edit
	if e == nil then return end
	local d = s.dragEl
	if d ~= nil and d.isEnd then
		if d.pressY == nil or s.mouseSY == nil then return end
		local z = d.pressZ + (d.pressY - s.mouseSY) * M.HEIGHT_PER_PX * (w.cameraDist or 500.0)
		if edits.moveEndHeight(e, d.i, z, w.gradeLimit()) then s.from, s.to = edits.ends(e) end
		return
	end
	if d ~= nil then
		local pt = edits.points(e)[d.i]
		if pt == nil then return end
		local at, z = pt.s, pt.z
		if d.height then
			if d.pressY == nil or s.mouseSY == nil then return end
			z = d.pressZ + (d.pressY - s.mouseSY) * M.HEIGHT_PER_PX * (w.cameraDist or 500.0)
		else
			if w.terrX == nil then return end
			-- (along the view ray when known: the track may be far above the ground under the mouse)
			local rs = w.ray ~= nil and edits.chainageOnRay(e, w.ray) or nil
			at = rs or edits.chainageAt(e, w.terrX, w.terrY)
		end
		local _, j = edits.moveElevation(e, d.i, at, z, w.gradeLimit())
		d.i = j -- (passing a neighbour reorders the points)
		selectHandle(s, j, false)
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
	local ei = s.selectedEnd
	if e ~= nil and ei ~= nil then
		if endHeight(e, ei) == z or not edits.setEndHeight(e, ei, z) then return {} end
		s.from, s.to = edits.ends(e)
		s.log(string.format("edit: %s set to %.2f m; steepest %.1f permille", endName(ei), z,
			edits.steepest(e) * 1000))
		return { "ghostNow" }
	end
	local pt = e ~= nil and i ~= nil and edits.points(e)[i] or nil
	if pt == nil or pt.z == z then return {} end -- (the box may echo the height it was given)
	edits.setHeight(e, i, z)
	s.log(string.format("edit: elevation point %d set to %.2f m; steepest %.1f permille", i, z, edits.steepest(e) * 1000))
	return { "ghostNow" }
end

-- What tells the selection apart ("point 2", "end 1"), nil when nothing is selected: the mode
-- window's controls act only for the one they were drawn for.
function M.selectedKey(s : Session) : string
	if s.selectedEnd ~= nil then return "end " .. tostring(s.selectedEnd) end
	if s.selected ~= nil then return "point " .. tostring(s.selected) end
	return nil
end

-- The selected elevation point or ground end, read out against the grade limit; nil when none is.
function M.selection(s : Session, limit : number) : Selection
	local e = s.edit
	if e == nil or M.selectedKey(s) == nil then return nil end
	local p = edits.profile(e)
	local steep = (edits.gradeProblem(e, limit))
	local ei = s.selectedEnd
	if ei ~= nil then
		local at = ei == 1 and 0.0 or edits.length(e)
		return { name = ei == 1 and "Start" or "End", key = M.selectedKey(s), s = at, z = endHeight(e, ei),
			grade = p ~= nil and profiles.gradeAt(p, at) or nil, tooClose = false, steep = steep }
	end
	local i = s.selected
	local pt = edits.points(e)[i]
	if pt == nil then return nil end
	local grade : number = nil
	if not pt.tooClose and p ~= nil then grade = profiles.gradeAt(p, pt.s) end
	return { name = "Point " .. tostring(i), key = M.selectedKey(s), s = pt.s, z = pt.z, grade = grade,
		tooClose = pt.tooClose, steep = steep }
end

-- What the selected point's (or ground end's) height can be matched to, in order along the track:
-- the start, every other point (one too close too: its height is its own), the end; never itself.
-- Empty when none is selected.
function M.matchSources(s : Session) : {MatchSource}
	local e, sel, ei = s.edit, s.selected, s.selectedEnd
	local out : {MatchSource} = {}
	if e == nil or (sel == nil and ei == nil) then return out end
	local pts = edits.points(e)
	if ei == nil and pts[sel] == nil then return out end
	local function add(name : string, z : number)
		local shown = math.abs(z) < 0.05 and 0.0 or z -- (never "-0.0 m")
		out[#out + 1] = { label = string.format("%s · %.1f m", name, shown), z = z }
	end
	local za, zb = edits.endHeights(e)
	if ei ~= 1 then add("Start", za) end
	for i, pt in ipairs(pts) do
		if i ~= sel then add("Point " .. tostring(i), pt.z) end
	end
	if ei == nil or ei == 1 then add("End", zb) end
	return out
end

-- Set the selected point's height to that of m (an entry of matchSources, as the player saw it:
-- the list may be a redraw behind), once (it does not follow its source).
function M.match(s : Session, m : MatchSource) : {Request}
	if m == nil or m.z == nil then return {} end
	s.log("edit: match " .. (M.selectedKey(s) or "nothing") .. " to " .. m.label)
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
		-- (only marks the "back" that follows a click as a right-click; the camera keeps the button)
		if kind == "clicked" then s.rightTick = s.ticks end
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
	if s.edit == nil or M.dragging(s) then return nil end
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
	if e == nil then return nil end
	local state : CursorState = M.dragging(s) and "dragging" or "handle"
	local hit = s.hit
	local onPoint = s.drag == nil and hit ~= nil and hit.kind == "point"
	if s.dragEl ~= nil and s.dragEl.isEnd then
		local p = edits.polyline(e)[s.dragEl.i]
		return { x = p.x, y = p.y, state = state }
	end
	if s.dragEl ~= nil or onPoint then
		local pt = edits.points(e)[s.dragEl ~= nil and s.dragEl.i or hit.i]
		if pt == nil then return nil end
		return { x = pt.x, y = pt.y, state = state }
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
	s.grab = w.grab or s.grab or 10.0
	local reqs : {Request} = {}
	if s.from ~= nil and not w.endThere(s.from) then
		s.log("tool: the start end is gone")
		M.reset(s)
		reqs = { "closeConfirm", "closeMode", "restart" }
	elseif s.to ~= nil and not w.endThere(s.to) then
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
