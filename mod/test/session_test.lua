-- Offline checks for the tool's session (tg_session.script.tl): the game's events are played to it
-- by hand, with a made-up world. Run from mod/ after check.sh builds .tlpath/:
--   lua test/session_test.lua
local tl = require("tl")
tl.loader()
package.path = ".tlpath/?.tl;" .. package.path
local S = require("westrom_track_geometry::/track_geometry/tg_session.script.tl")
local E = require("westrom_track_geometry::/track_geometry/tg_edit.script.tl")
local Ends = require("westrom_track_geometry::/track_geometry/tg_ends.script.tl")

local failures = 0
local LIMIT = 0.085 -- the made-up track type's grade limit
local function check(ok, what)
	print((ok and "ok   " or "FAIL ") .. what)
	if not ok then failures = failures + 1 end
end

-- Two free ends: the new track leaves a going +x and arrives at b going +y.
local endA = Ends.trackEnd(1, 0, 0, 0, 1, 0, 0)
local endB = Ends.trackEnd(2, 1500, 800, 0, 0, -1, 0)

-- A tool on a made-up world: the session, the world it is shown, and every request it made. The
-- free ends are a and b while t.free says so; t.piece is the track piece under the mouse (nil:
-- none); the ground is at height t.groundZ.
local function newTool(a, b)
	a, b = a or endA, b or endB
	local t = { live = true, free = { [1] = true, [2] = true }, shift = false, asked = {}, groundZ = 0 }
	t.w = {
		grab = 10, cameraDist = 1000,
		shift = function() return t.shift end,
		gradeLimit = function() return LIMIT end,
		snap = function(x, y, z, _, exclude)
			local near = {}
			for _, e in ipairs({ a, b }) do
				if x ~= nil and t.free[e.node] then near[#near + 1] = e end -- (over no ground: none near)
			end
			for _, e in ipairs(t.others or {}) do near[#near + 1] = e end -- (t.others: more ends on the map)
			return Ends.snap(near, t.piece, x, y, z, exclude)
		end,
		endThere = function(e) return e.node == nil or t.free[e.node] == true end,
	}
	t.s = S.new(function() end, function() return t.live end)
	return t
end
local function note(t, reqs)
	for _, r in ipairs(reqs or {}) do t.asked[#t.asked + 1] = r end
end
-- How often the tool asked for r since the last call of asked() for it.
local function asked(t, r)
	local n, rest = 0, {}
	for _, v in ipairs(t.asked) do
		if v == r then n = n + 1 else rest[#rest + 1] = v end
	end
	t.asked = rest
	return n
end
local function tick(t, n)
	for _ = 1, n or 1 do note(t, S.tick(t.s, t.w)) end
end
local function moveTo(t, x, y)
	t.w.terrX, t.w.terrY, t.w.terrZ = x, y, x ~= nil and t.groundZ or nil
	tick(t)
end
local function mouse(t, button, kind, y)
	local took, reqs = S.mouse(t.s, t.w, button, kind, y)
	note(t, reqs)
	return took
end
local function press(t) return mouse(t, 0, "pressed") end
local function letGo(t) mouse(t, 0, "released"); return mouse(t, 0, "clicked") end
local function click(t) press(t); return letGo(t) end
local function rightClick(t) mouse(t, 2, "released"); note(t, S.back(t.s, t.w)) end
local function esc(t) note(t, S.back(t.s, t.w)) end
-- Both ends picked.
local function editing(a, b)
	local t = newTool(a, b)
	a, b = a or endA, b or endB
	moveTo(t, a.x + 5, a.y + 5); click(t)
	moveTo(t, b.x - 5, b.y - 5); click(t)
	return t
end
-- The middle of the edit's longest leg, and a spot far from all of it.
local function onLeg(e)
	local best, bx, by = -1, 0, 0
	local pis = E.polyline(e)
	for i = 1, #pis - 1 do
		local p, q = pis[i], pis[i + 1]
		local d = (q.x - p.x) ^ 2 + (q.y - p.y) ^ 2
		if d > best then best, bx, by = d, (p.x + q.x) / 2, (p.y + q.y) / 2 end
	end
	return bx, by
end
local FAR_X, FAR_Y = 200, 3000

------------------------------------------------------------------ picking the ends
local t = newTool()
-- (a piece too short to cut where the mouse is)
t.piece = { edge = 98, node0 = 91, node1 = 92, p0 = { x = 698, y = 700, z = 0 }, t0 = { x = 10, y = 0, z = 0 },
	p1 = { x = 708, y = 700, z = 0 }, t1 = { x = 10, y = 0, z = 0 } }
moveTo(t, 700, 700)
check(t.s.phase == "from" and t.s.hover == nil and t.s.hoverMsg ~= nil, "picking: over track with nothing to pick, nothing, and why")
click(t)
check(t.s.phase == "from" and t.s.from == nil, "picking: a click on nothing picks nothing")
t.piece = nil
moveTo(t, nil, nil)
check(t.s.hover == nil and t.s.hoverMsg ~= nil, "picking: over no ground, nothing, and why")
moveTo(t, 5, 5)
check(t.s.hover == endA, "picking: the mouse snaps to the end near it")
click(t)
check(t.s.phase == "to" and t.s.from == endA and t.s.hover == nil and asked(t, "openMode") == 0, "picking: a click picks the start")
moveTo(t, 5, 5)
check(t.s.hover ~= endA and t.s.hover.kind == "ground", "picking: the start is not offered as the end")
moveTo(t, 1495, 795); click(t)
check(t.s.phase == "done" and t.s.to == endB and t.s.edit ~= nil and t.s.mode == "horizontal" and asked(t, "openMode") == 1,
	"picking: the second click picks the end, starts the edit and opens the mode window once")

------------------------------------------------------------------ building
moveTo(t, FAR_X, FAR_Y)
check(click(t) == true and asked(t, "askBuild") == 1, "build: a click on nothing asks to build, once")
S.confirmOpened(t.s)
check(click(t) == false and asked(t, "askBuild") == 0, "build: with the confirm window open, clicks are the window's")
check(not S.backIsOurs(t.s), "build: with the confirm window open, back is the window's")
S.confirmClosed(t.s)
check(click(t) == false and asked(t, "askBuild") == 0, "build: the click that closed the window does not open it again")
tick(t, S.CLOSED_TICKS + 1)
click(t)
check(asked(t, "askBuild") == 1, "build: a later click asks again")
S.refuse(t.s, "Cannot build: the game is still checking it.")
check(t.s.editMsg ~= nil, "build: a refusal is kept for the tooltip")

------------------------------------------------------------------ ground ends
-- the ground: either click may land on open ground, a ground end at the terrain's height there
t = newTool()
t.groundZ = 12
moveTo(t, 700, 700)
local h = t.s.hover
check(h ~= nil and h.kind == "ground" and h.x == 700 and h.y == 700 and h.z == 12 and t.s.hoverMsg == nil,
	"ground: off track, the mouse is on a ground end at the terrain's height")
click(t)
check(t.s.phase == "to" and t.s.from == h, "ground: a click there starts the track")
tick(t, 5)
check(t.s.phase == "to" and t.s.from == h, "ground: a ground start stays (there is no node to lose)")
moveTo(t, 900, 700)
local h1 = t.s.hover
moveTo(t, 900.5, 700)
check(t.s.hover == h1, "ground: a move under a metre keeps the end the mouse is on")
moveTo(t, 950, 720)
check(t.s.hover ~= h1 and t.s.hover.kind == "ground" and t.s.hover.x == 950, "ground: further, the end follows the mouse")
moveTo(t, 720, 710)
click(t)
check(t.s.phase == "to" and t.s.edit == nil and asked(t, "openMode") == 0 and t.s.hoverMsg ~= nil
	and t.s.hoverMsg:find("too close") ~= nil, "ground: ends under 40 m apart are refused, and why: " .. tostring(t.s.hoverMsg))
moveTo(t, 950, 720)
check(t.s.hoverMsg == nil, "ground: moving on, the refusal is gone")
click(t)
check(t.s.phase == "done" and t.s.to.kind == "ground" and t.s.edit ~= nil and E.turnCount(t.s.edit) == 0
	and asked(t, "openMode") == 1, "ground: the second click enters editing, ground to ground straight")
-- track to ground, ground to track
t = editing(endA, Ends.groundEnd(300, 200, 0))
check(t.s.phase == "done" and t.s.from == endA and t.s.to.kind == "ground" and E.turnCount(t.s.edit) == 1
	and E.mobility(t.s.edit, 2) == "ray", "ground: track to ground, one turn sliding on the track end's ray")
t = newTool()
moveTo(t, 1200, 300); click(t)
moveTo(t, 1495, 795); click(t)
check(t.s.phase == "done" and t.s.from.kind == "ground" and t.s.to == endB and E.turnCount(t.s.edit) == 1,
	"ground: ground to track, one turn")
-- right-click or Esc after the first click drops the start; before it, Esc is not the tool's
t = newTool()
moveTo(t, 700, 700)
check(not S.backIsOurs(t.s), "ground: before the first click, Esc is not the tool's (it closes the tool)")
click(t)
check(S.backIsOurs(t.s), "ground: after the first click, Esc is the tool's")
esc(t)
check(t.s.phase == "from" and t.s.from == nil, "ground: Esc drops the start")
tick(t, S.RIGHT_TICKS + 1)
moveTo(t, 700, 700); click(t)
rightClick(t)
check(t.s.phase == "from" and t.s.from == nil, "ground: so does a right-click")

------------------------------------------------------------------ dragging a ground end
t = editing(endA, Ends.groundEnd(300, 200, 0))
moveTo(t, 301, 201)
check(t.s.hit ~= nil and t.s.hit.kind == "end" and S.hint(t.s) ~= nil and S.hint(t.s):find("Drag") ~= nil,
	"drag end: the hint names the drag")
check(press(t) == true and t.s.drag ~= nil and t.s.drag.kind == "end", "drag end: a press on a ground end grabs it")
t.groundZ = 6
moveTo(t, 420, 350)
check(t.s.to.kind == "ground" and t.s.to.x == 420 and t.s.to.y == 350 and t.s.to.z == 6 and t.s.edit.b == t.s.to
	and t.s.from == endA, "drag end: the end follows the mouse, at the ground's height")
letGo(t)
check(t.s.drag == nil and t.s.to.x == 420 and asked(t, "ghostNow") == 1 and asked(t, "askBuild") == 0,
	"drag end: the drop leaves it there, and does not ask to build")
-- dropped on track it becomes that end, heading as the second click would give it
t.piece = { edge = 50, node0 = 61, node1 = 62, p0 = { x = -1000, y = 500, z = 4 }, t0 = { x = 2000, y = 0, z = 0 },
	p1 = { x = 1000, y = 500, z = 4 }, t1 = { x = 2000, y = 0, z = 0 } }
moveTo(t, 421, 351); press(t)
moveTo(t, 400, 503)
check(t.s.drag ~= nil and t.s.to.kind == "split" and math.abs(t.s.to.x - 400) < 1e-6 and t.s.to.y == 500 and t.s.to.dx == -1
	and t.s.edit.b == t.s.to, "drop on track: over a piece the dragged end is a cut there, heading toward the start")
local cur = S.cursor(t.s)
check(cur.state == "trackEnd" and cur.y == 500 and cur.z == 4, "drop on track: the cursor shows the snap")
t.piece = nil
moveTo(t, 400, 520)
check(t.s.drag ~= nil and t.s.to.kind == "ground" and t.s.to.y == 520 and S.cursor(t.s).state == "dragging",
	"drop on track: dragged on in the same drag, it is a ground end again")
t.others = { Ends.trackEnd(7, 430, 540, 2, 0, -1, 0.01) }
t.free[7] = true
moveTo(t, 400, 530)
check(t.s.to.node == 7 and t.s.to.dy == -1, "drop on track: within SNAP of a free end, it is that end")
letGo(t)
moveTo(t, 431, 541)
check(t.s.drag == nil and t.s.to.node == 7 and asked(t, "ghostNow") == 1 and (t.s.hit == nil or t.s.hit.kind ~= "end"),
	"drop on track: let go, it is that end and a handle no more")
press(t)
check(t.s.drag == nil or t.s.drag.kind ~= "end", "drop on track: a press on it grabs it no more")
letGo(t)
t.free[7] = false
tick(t)
check(t.s.phase == "to" and t.s.edit == nil, "drop on track: the end it became is checked like a picked one")
-- no turn on its leg: one is added, and the grab follows the end's new index; a node
t = editing(Ends.groundEnd(0, 0, 0), Ends.groundEnd(600, 0, 0))
t.others = { Ends.nodeEnd(8, 600, 200, 3, { { dx = 1, dy = 0, grade = 0 }, { dx = -1, dy = 0, grade = 0 } }) }
t.free[8] = true
moveTo(t, 601, 1); press(t)
moveTo(t, 602, 203)
check(t.s.to.kind == "node" and t.s.to.dx == -1 and E.turnCount(t.s.edit) == 1 and t.s.drag.i == 3,
	"drop on a node: it heads toward the start, on a turn added on its ray")
moveTo(t, 700, 300)
check(t.s.to.kind == "ground" and t.s.to.x == 700 and E.turnCount(t.s.edit) == 0 and t.s.drag.i == 2,
	"drop on a node: dragged on, the turn is gone again")
moveTo(t, 602, 203); letGo(t)
check(t.s.to.kind == "node" and E.turnCount(t.s.edit) == 1, "drop on a node: let go there, it stays")
-- a drag that ends without the button let go (a mode switch) drops the end where it is too
t = editing(Ends.groundEnd(0, 0, 0), Ends.groundEnd(600, 0, 0))
t.others = { Ends.nodeEnd(8, 600, 200, 3, { { dx = 1, dy = 0, grade = 0 }, { dx = -1, dy = 0, grade = 0 } }) }
t.free[8] = true
moveTo(t, 601, 1); press(t)
moveTo(t, 602, 203)
note(t, S.setMode(t.s, "vertical")); note(t, S.setMode(t.s, "horizontal"))
check(t.s.drag == nil and t.s.to.kind == "node" and not E.draggableEnd(t.s.edit, 3),
	"drop on a node: a mode switch in the middle of the drag fixes it there")

t = editing(endA, Ends.groundEnd(300, 200, 0))
moveTo(t, 3, 2)
check(t.s.hit == nil or t.s.hit.kind ~= "end", "drag end: a track end is no handle")
press(t)
check(t.s.drag == nil or t.s.drag.kind ~= "end", "drag end: a press on a track end does not grab it")
letGo(t)

------------------------------------------------------------------ editing the horizontal alignment
t = editing()
local e = t.s.edit
local turns, rev = E.turnCount(e), e.rev
local lx, ly = onLeg(e)
moveTo(t, lx, ly)
check(t.s.hit ~= nil and t.s.hit.kind == "leg", "edit: over a leg, a turn can be added")
check(press(t) == true and t.s.drag ~= nil and E.turnCount(e) == turns + 1, "edit: a press on a leg adds a turn and grabs it")
local grabbed = t.s.drag.i
moveTo(t, lx + 60, ly - 80)
check(e.rev > rev + 1 and math.abs(E.polyline(e)[grabbed].x - (lx + 60)) < 1e-9, "edit: the grabbed turn follows the mouse")
mouse(t, 0, "released")
check(t.s.drag == nil and asked(t, "ghostNow") == 1, "edit: letting go ends the drag and asks for the ghost at once")
check(mouse(t, 0, "clicked") == true and asked(t, "askBuild") == 0, "edit: the click of a drag does not ask to build")
moveTo(t, FAR_X, FAR_Y)
click(t)
check(asked(t, "askBuild") == 1, "edit: the next click on nothing asks to build once")

-- right-click on the turn removes it; one input's "back" arriving again does nothing more
moveTo(t, E.polyline(e)[grabbed].x, E.polyline(e)[grabbed].y)
check(t.s.hit ~= nil and t.s.hit.kind == "pi" and t.s.hit.i == grabbed, "edit: over the turn")
tick(t, S.RIGHT_TICKS + 1)
rightClick(t)
check(E.turnCount(e) == turns and t.s.phase == "done", "back: a right-click on a turn removes it and stays in the edit")
esc(t); esc(t)
check(t.s.phase == "done" and t.s.edit == e, "back: the same input's back arriving again does nothing")
-- right-click on nothing does nothing
tick(t, S.RIGHT_TICKS + 1)
moveTo(t, FAR_X, FAR_Y)
tick(t, S.RIGHT_TICKS + 1)
rightClick(t)
check(E.turnCount(e) == turns and t.s.phase == "done", "back: a right-click on nothing does nothing")

-- Esc steps back, once per input, while editing and while picking the end
tick(t, S.RIGHT_TICKS + 1)
check(S.backIsOurs(t.s), "back: while editing, Esc is the tool's")
esc(t); esc(t); esc(t)
check(t.s.phase == "to" and t.s.edit == nil and t.s.to == nil and t.s.from == endA and asked(t, "closeMode") == 1,
	"back: Esc leaves the edit, once, however often it arrives, and closes the mode window")
tick(t, S.RIGHT_TICKS + 1)
check(S.backIsOurs(t.s), "back: while picking the end, Esc is the tool's")
esc(t)
check(t.s.phase == "from" and t.s.from == nil, "back: it steps back to picking the start")
tick(t, S.RIGHT_TICKS + 1)
mouse(t, 2, "released")
check(not S.backIsOurs(t.s), "back: nothing to go back to at the start")

-- a mode switch in the middle of a drag drops the drag
t = editing()
e = t.s.edit
moveTo(t, onLeg(e)); press(t)
S.setMode(t.s, "vertical")
check(t.s.drag == nil and t.s.hit == nil and t.s.mode == "vertical", "mode: switching in the middle of a drag drops it")
mouse(t, 0, "released"); mouse(t, 0, "clicked")

------------------------------------------------------------------ editing the vertical alignment
tick(t)
local nodes = E.nodes(e)
local mid = nodes[math.floor(#nodes / 2)]
moveTo(t, mid.x, mid.y)
check(t.s.hit ~= nil and t.s.hit.kind == "track" and math.abs(t.s.hit.s - mid.s) < 1, "vertical: over the track, a point can be added")
check(press(t) == true and #E.points(e) == 1 and t.s.dragEl ~= nil and not t.s.dragEl.height, "vertical: a press adds an elevation point and grabs it")
local f = E.points(e)[1].s
local further = nodes[math.floor(#nodes / 2) + 10]
moveTo(t, further.x, further.y)
check(E.points(e)[1].s > f, "vertical: the point slides along the track with the mouse")
letGo(t)
check(t.s.dragEl == nil and asked(t, "ghostNow") == 1 and asked(t, "askBuild") == 0, "vertical: letting go ends the drag; its click does not build")
-- Shift-drag: its height follows the mouse up the screen
t.shift = true
mouse(t, 0, "moved", 500)
check(press(t) == true and t.s.dragEl ~= nil and t.s.dragEl.height, "vertical: Shift at the press grabs the point's height")
mouse(t, 0, "moved", 499)
tick(t)
check(math.abs(E.points(e)[1].z - 1) < 1e-6, string.format("vertical: a pixel up raises it 1 m at 1000 m (%.3f m)", E.points(e)[1].z))
letGo(t)
t.shift = false
tick(t, S.RIGHT_TICKS + 1)
rightClick(t)
check(#E.points(e) == 0 and t.s.phase == "done", "vertical: a right-click on the point removes it")

-- too close: a drag is not stopped by the 20 m spacing; the build waits until the point is clear
local n1, n2 = nodes[math.floor(#nodes / 2)], nodes[math.floor(#nodes / 2) + 20]
moveTo(t, n1.x, n1.y); press(t); letGo(t)
moveTo(t, n2.x, n2.y); press(t)
check(#E.points(e) == 2 and t.s.dragEl ~= nil and t.s.dragEl.i == 2, "too close: a second point, grabbed")
local n3 = nodes[math.floor(#nodes / 2) + 1]
moveTo(t, n3.x, n3.y)
check(E.points(e)[2].tooClose and math.abs(E.points(e)[2].s - n3.s) < 1, "too close: the drag goes within 20 m of the neighbour")
letGo(t)
check(t.s.dragEl == nil and E.points(e)[2].tooClose, "too close: let go there, it stays too close")
moveTo(t, FAR_X, FAR_Y)
check(click(t) == true and asked(t, "askBuild") == 0 and t.s.editMsg ~= nil
	and t.s.editMsg:find("too close", 1, true) ~= nil, "too close: the build is refused: " .. tostring(t.s.editMsg))
-- dragged past its neighbour, the grab follows the point to its new place in the order
moveTo(t, n3.x, n3.y); press(t)
local n4 = nodes[math.floor(#nodes / 2) - 5]
moveTo(t, n4.x, n4.y)
check(t.s.dragEl ~= nil and t.s.dragEl.i == 1 and math.abs(E.points(e)[1].s - n4.s) < 1 and E.points(e)[2].s > E.points(e)[1].s,
	"too close: dragged past its neighbour, it is point 1 now and still grabbed")
local n5 = nodes[math.floor(#nodes / 2) - 10]
moveTo(t, n5.x, n5.y)
check(math.abs(E.points(e)[1].s - n5.s) < 1 and not E.points(e)[1].tooClose, "too close: the drag goes on with the new index, clear")
letGo(t)
moveTo(t, FAR_X, FAR_Y)
check(click(t) == true and asked(t, "askBuild") == 1, "too close: once clear, a click asks to build")
note(t, S.confirmOpened(t.s)); S.confirmClosed(t.s); tick(t, S.CLOSED_TICKS + 1)
tick(t, S.RIGHT_TICKS + 1)
moveTo(t, E.points(e)[1].x, E.points(e)[1].y); rightClick(t)
tick(t, S.RIGHT_TICKS + 1)
moveTo(t, E.points(e)[1].x, E.points(e)[1].y); rightClick(t)
check(#E.points(e) == 0, "too close: both points removed again")

-- too steep: a height set directly passes the limit, and the build waits until it is eased
tick(t, S.RIGHT_TICKS + 1)
moveTo(t, n1.x, n1.y); press(t); letGo(t)
check(E.setHeight(e, 1, 200) and E.steepest(e) > LIMIT, "too steep: a height set directly passes the limit")
moveTo(t, FAR_X, FAR_Y)
check(click(t) == true and asked(t, "askBuild") == 0 and t.s.editMsg ~= nil
	and t.s.editMsg:find("too steep", 1, true) ~= nil and t.s.editMsg:find("too close", 1, true) == nil,
	"too steep: the build is refused: " .. tostring(t.s.editMsg))
-- too steep and too close at once: the refusal names both
E.insertElevation(e, E.points(e)[1].s + 15)
check(#E.points(e) == 2 and E.points(e)[2].tooClose, "too steep: and a point too close")
moveTo(t, FAR_X, FAR_Y)
check(click(t) == true and asked(t, "askBuild") == 0 and t.s.editMsg:find("too steep", 1, true) ~= nil
	and t.s.editMsg:find("too close", 1, true) ~= nil, "too steep and too close: the refusal names both: " .. tostring(t.s.editMsg))
tick(t, S.RIGHT_TICKS + 1)
moveTo(t, E.points(e)[2].x, E.points(e)[2].y); rightClick(t)
E.setHeight(e, 1, E.points(e)[1].z - 190)
check(E.steepest(e) <= LIMIT, "too steep: eased")
moveTo(t, FAR_X, FAR_Y)
check(click(t) == true and asked(t, "askBuild") == 1, "too steep: once eased, a click asks to build")

-- the track up on a bridge: the ground under the mouse is behind it, so it is picked along the
-- view ray (the eye through the ground point), as is a slide
t = editing()
e = t.s.edit
S.setMode(t.s, "vertical")
nodes = E.nodes(e)
-- (the track is at 0; here the ground is 100 m below it, so the mouse's ground point is 100 m on)
local function lookAt(nd)
	local gx, gy = nd.x + 100, nd.y + 100
	t.w.ray = { ex = nd.x - 300, ey = nd.y - 300, ez = 300, gx = gx + 0.0, gy = gy + 0.0, gz = -100 }
	moveTo(t, gx, gy)
end
local bm = math.floor(#nodes / 2)
lookAt(nodes[bm])
check(t.s.hit ~= nil and t.s.hit.kind == "track" and math.abs(t.s.hit.s - nodes[bm].s) < 1,
	"bridge: the raised track is under the mouse along its view ray")
check(press(t) == true and #E.points(e) == 1 and math.abs(E.points(e)[1].s - nodes[bm].s) < 1,
	"bridge: a press on it adds a point there (not a build)")
lookAt(nodes[bm + 10])
check(math.abs(E.points(e)[1].s - nodes[bm + 10].s) < 1, "bridge: the point slides along the ray: " .. string.format("%.1f m", E.points(e)[1].s))
letGo(t)
check(asked(t, "askBuild") == 0, "bridge: the press and its click do not ask to build")
t.w.ray = nil

------------------------------------------------------------------ selecting a point and setting its height
t = editing()
e = t.s.edit
S.setMode(t.s, "vertical")
nodes = E.nodes(e)
local m = math.floor(#nodes / 2)
check(S.selection(t.s, LIMIT) == nil, "select: nothing selected at first")
-- a press on the track adds a point, selected
moveTo(t, nodes[m].x, nodes[m].y); press(t); letGo(t)
check(t.s.selected == 1, "select: a point just added is selected")
local sel = S.selection(t.s, LIMIT)
check(sel ~= nil and sel.name == "Point 1" and sel.key == "point 1" and math.abs(sel.s - nodes[m].s) < 1 and sel.grade ~= nil and not sel.tooClose and sel.steep == nil,
	"select: the selection reads out its name, chainage, height and grade")
-- a click on another point selects it; a click on nothing keeps the selection and asks to build
moveTo(t, nodes[m + 20].x, nodes[m + 20].y); press(t); letGo(t)
check(t.s.selected == 2, "select: a second point added is selected")
moveTo(t, E.points(e)[1].x, E.points(e)[1].y); press(t); letGo(t)
check(t.s.selected == 1 and #E.points(e) == 2, "select: a click on a point selects it (and adds none)")
moveTo(t, FAR_X, FAR_Y)
check(click(t) == true and asked(t, "askBuild") == 1 and t.s.selected == 1, "select: a click on nothing keeps it and asks to build")
-- setting its height applies at once, past the limit too
asked(t, "ghostNow")
note(t, S.setHeight(t.s, 200))
check(E.points(e)[1].z == 200 and asked(t, "ghostNow") == 1, "select: a height set applies as asked, and the ghost is made at once")
local rev2 = e.rev
check(#S.setHeight(t.s, 200) == 0 and e.rev == rev2, "select: the height it has already asks nothing (the box echoing its value)")
sel = S.selection(t.s, LIMIT)
check(sel.z == 200 and sel.steep ~= nil and sel.steep:find("too steep", 1, true) ~= nil, "select: the selection says it is too steep: " .. tostring(sel.steep))
-- a drag past its neighbour: the selection follows the point
moveTo(t, E.points(e)[1].x, E.points(e)[1].y); press(t)
moveTo(t, nodes[m + 30].x, nodes[m + 30].y)
check(t.s.selected == t.s.dragEl.i and E.points(e)[t.s.selected].z == 200, "select: the dragged point is selected and the selection follows it")
letGo(t)
local held = t.s.selected
-- a Shift-drag selects the point it grabs, and the selection reads its height live
moveTo(t, E.points(e)[3 - held].x, E.points(e)[3 - held].y)
t.shift = true
mouse(t, 0, "moved", 500); press(t)
check(t.s.selected == 3 - held, "select: a Shift-drag selects the point it grabs")
mouse(t, 0, "moved", 490); tick(t)
check(math.abs(S.selection(t.s, LIMIT).z - E.points(e)[t.s.selected].z) < 1e-9, "select: the selection follows a Shift-drag's height")
letGo(t)
t.shift = false
-- a point too close: no grade, but its height can be set
local closeAt = E.points(e)[t.s.selected].s + 5
E.insertElevation(e, closeAt)
local ci
for k, p in ipairs(E.points(e)) do if p.tooClose then ci = k end end
moveTo(t, E.points(e)[ci].x, E.points(e)[ci].y); press(t); letGo(t)
sel = S.selection(t.s, LIMIT)
check(t.s.selected == ci and sel.tooClose and sel.grade == nil, "select: a point too close has no grade")
note(t, S.setHeight(t.s, 50))
check(E.points(e)[ci].z == 50, "select: a point too close can still have its height set")
-- removing a point before the selected one keeps the same point selected; removing it clears it
local keep = E.points(e)[3]
t.s.selected = 3
tick(t, S.RIGHT_TICKS + 1)
moveTo(t, E.points(e)[1].x, E.points(e)[1].y); rightClick(t)
check(#E.points(e) == 2 and t.s.selected == 2 and E.points(e)[2].s == keep.s, "select: removing a point before it keeps it selected")
tick(t, S.RIGHT_TICKS + 1)
moveTo(t, E.points(e)[2].x, E.points(e)[2].y); rightClick(t)
check(#E.points(e) == 1 and t.s.selected == nil and S.selection(t.s, LIMIT) == nil, "select: removing the selected point clears it")
check(#S.setHeight(t.s, 10) == 0, "select: with nothing selected, a height does nothing")
-- the mode switching to horizontal, and leaving the edit, clear it
moveTo(t, E.points(e)[1].x, E.points(e)[1].y); press(t); letGo(t)
check(t.s.selected == 1, "select: selected again")
S.setMode(t.s, "horizontal")
check(t.s.selected == nil, "select: switching to horizontal clears it")
S.setMode(t.s, "vertical")
moveTo(t, E.points(e)[1].x, E.points(e)[1].y); press(t); letGo(t)
tick(t, S.RIGHT_TICKS + 1)
esc(t)
check(t.s.phase == "to" and t.s.selected == nil, "select: leaving the edit clears it")

------------------------------------------------------------------ matching another point's height
-- ends at different heights: the start 36.4 m up, the end 1.9 m
local hiA = { kind = "track", node = 1, x = 0, y = 0, dx = 1, dy = 0, z = 36.4, grade = 0 }
local loB = { kind = "track", node = 2, x = 1500, y = 800, dx = 0, dy = -1, z = 1.9, grade = 0 }
t = editing(hiA, loB)
e = t.s.edit
S.setMode(t.s, "vertical")
nodes = E.nodes(e)
check(#S.matchSources(t.s) == 0, "match: nothing to match with no point selected")
for _, k in ipairs({ 30, 60, 90 }) do
	local nd = nodes[math.floor(#nodes * k / 100)]
	moveTo(t, nd.x, nd.y); press(t); letGo(t)
end
note(t, S.setHeight(t.s, 18.94)) -- point 3 (the last added, selected)
moveTo(t, E.points(e)[1].x, E.points(e)[1].y); press(t); letGo(t)
note(t, S.setHeight(t.s, 25))
moveTo(t, E.points(e)[2].x, E.points(e)[2].y); press(t); letGo(t)
check(t.s.selected == 2, "match: point 2 selected")
local src = S.matchSources(t.s)
-- (the height only: where along the track read as a second height)
local want = { "Start · 36.4 m", "Point 1 · 25.0 m", "Point 3 · 18.9 m", "End · 1.9 m" }
local labels = {}
for k, m in ipairs(src) do labels[k] = m.label end
check(table.concat(labels, " | ") == table.concat(want, " | "),
	"match: Start, the other points and End, in order, labelled: " .. table.concat(labels, " | "))
-- picking one sets the selected point's height at once
asked(t, "ghostNow")
local function pick(k) note(t, S.match(t.s, S.matchSources(t.s)[k])) end
pick(3)
check(E.points(e)[2].z == 18.94 and asked(t, "ghostNow") == 1, "match: point 3's height, at once")
pick(1)
check(E.points(e)[2].z == 36.4, "match: the start's height")
pick(4)
check(E.points(e)[2].z == 1.9 and t.s.selected == 2, "match: the end's height; still selected")
-- one-off: the point does not follow its source
note(t, S.setHeight(t.s, 10))
moveTo(t, E.points(e)[1].x, E.points(e)[1].y); press(t); letGo(t)
note(t, S.setHeight(t.s, 30))
check(E.points(e)[2].z == 10, "match: one-off, the point does not follow its source")
-- past the grade limit too: the build is then refused
moveTo(t, E.points(e)[2].x, E.points(e)[2].y); press(t); letGo(t)
note(t, S.setHeight(t.s, 300))
moveTo(t, E.points(e)[3].x, E.points(e)[3].y); press(t); letGo(t)
pick(3) -- point 2, 300 m up
check(E.points(e)[3].z == 300 and S.selection(t.s, LIMIT).steep ~= nil, "match: past the limit too, and then too steep")
-- a too-close point is listed like any other, with its own height
E.insertElevation(e, E.points(e)[1].s + 5)
local tc
for k, p in ipairs(E.points(e)) do if p.tooClose then tc = k end end
E.setHeight(e, tc, 44)
local listed = false
for _, m in ipairs(S.matchSources(t.s)) do if m.label:find(string.format("Point %d ", tc), 1, true) and m.z == 44 then listed = true end end
check(listed, "match: a point too close is listed with its own height")
check(#S.match(t.s, nil) == 0, "match: no entry does nothing")
-- an entry as it was drawn applies its own height, even after the points reorder
local drawn = S.matchSources(t.s)[1] -- the start
moveTo(t, E.points(e)[1].x, E.points(e)[1].y); press(t)
moveTo(t, nodes[#nodes - 5].x, nodes[#nodes - 5].y); letGo(t)
moveTo(t, E.points(e)[2].x, E.points(e)[2].y); press(t); letGo(t)
note(t, S.match(t.s, drawn))
check(E.points(e)[2].z == 36.4, "match: an entry drawn before a reorder applies the height it showed")
E.setHeight(e, 1, -0.01)
local shownZero = false
for _, m in ipairs(S.matchSources(t.s)) do if m.label:find("Point 1 ", 1, true) and m.label == "Point 1 · 0.0 m" then shownZero = true end end
check(shownZero, "match: a height just below zero shows as 0.0 m, not -0.0")

------------------------------------------------------------------ a ground end's height
t = editing(endA, Ends.groundEnd(600, 300, 0))
e = t.s.edit
local gx, gy = t.s.to.x, t.s.to.y -- (the ground under the second click)
S.setMode(t.s, "vertical")
local gi = #E.polyline(e)
moveTo(t, gx + 2, gy + 1)
check(t.s.hit ~= nil and t.s.hit.kind == "end" and t.s.hit.i == gi, "ground end: under the mouse in vertical mode")
local gh = S.hint(t.s)
check(gh ~= nil and gh:find("Shift+drag: height", 1, true) ~= nil and gh:find("cannot slide", 1, true) ~= nil,
	"ground end: the hint says Shift-drag sets its height and it cannot slide: " .. tostring(gh))
local cur = S.cursor(t.s)
check(cur ~= nil and cur.x == gx and cur.y == gy and cur.state == "handle", "ground end: the cursor is on it")
-- a press selects it and never slides it
check(press(t) == true and t.s.selectedEnd == gi and t.s.selected == nil, "ground end: a press selects it")
moveTo(t, 500, 250)
check(t.s.to.x == gx and t.s.to.y == gy and t.s.to.z == 0 and #E.points(e) == 0, "ground end: a drag without Shift never slides it")
letGo(t)
check(asked(t, "askBuild") == 0 and t.s.selectedEnd == gi, "ground end: the click that selects it does not build")
local sel = S.selection(t.s, LIMIT)
check(sel ~= nil and sel.name == "End" and sel.z == 0 and sel.s == E.length(e) and sel.grade ~= nil and not sel.tooClose,
	"ground end: the selection reads it out")
-- the height box
asked(t, "ghostNow")
note(t, S.setHeight(t.s, 9))
check(t.s.to.z == 9 and t.s.edit.b == t.s.to and asked(t, "ghostNow") == 1, "ground end: the height box sets its height")
-- the match list: the start and the points, not itself
moveTo(t, E.nodes(e)[20].x, E.nodes(e)[20].y); press(t); letGo(t)
note(t, S.setHeight(t.s, 2.5))
moveTo(t, gx, gy); press(t); letGo(t)
local glabels = {}
for k, m in ipairs(S.matchSources(t.s)) do glabels[k] = m.label end
check(table.concat(glabels, " | ") == "Start · 0.0 m | Point 1 · 2.5 m", "ground end: match list without itself: " .. table.concat(glabels, " | "))
note(t, S.match(t.s, S.matchSources(t.s)[2]))
check(t.s.to.z == 2.5 and t.s.selectedEnd == gi, "ground end: matched to a point's height; still selected")
-- selecting a point clears the end's selection, and back
moveTo(t, E.points(e)[1].x, E.points(e)[1].y); press(t); letGo(t)
check(t.s.selected == 1 and t.s.selectedEnd == nil, "ground end: selecting a point unselects the end")
moveTo(t, gx, gy); press(t); letGo(t)
-- Shift-drag: its height, stopping at the limit
t.shift = true
mouse(t, 0, "moved", 500)
check(press(t) == true and t.s.dragEl ~= nil and t.s.dragEl.isEnd and t.s.dragEl.height, "ground end: Shift at the press grabs its height")
check(S.cursor(t.s).state == "dragging", "ground end: the cursor shows the drag")
mouse(t, 0, "moved", 499)
tick(t)
check(math.abs(t.s.to.z - 3.5) < 1e-6 and t.s.to.x == gx, string.format("ground end: a pixel up raises it 1 m (%.3f m)", t.s.to.z))
mouse(t, 0, "moved", 0)
tick(t)
check(t.s.to.z < 500 and E.steepest(e) <= LIMIT + 1e-9, string.format("ground end: a Shift-drag stops at the limit (%.1f m)", t.s.to.z))
letGo(t)
t.shift = false
check(t.s.dragEl == nil and asked(t, "ghostNow") >= 1 and asked(t, "askBuild") == 0, "ground end: letting go ends the drag")
-- set past the limit: too steep, so no build
note(t, S.setHeight(t.s, 400))
moveTo(t, 300, -400)
click(t)
check(asked(t, "askBuild") == 0 and t.s.editMsg ~= nil and t.s.editMsg:find("too steep") ~= nil, "ground end: too high, the build is refused")
note(t, S.setHeight(t.s, 0))
-- a right-click on it removes nothing
tick(t, S.RIGHT_TICKS + 1)
moveTo(t, gx, gy); rightClick(t)
check(t.s.phase == "done" and t.s.to.kind == "ground", "ground end: a right-click does not remove it")
-- a track end is no vertical handle
moveTo(t, 3, 2)
check(t.s.hit == nil or t.s.hit.kind ~= "end", "ground end: a track end stays fixed")
-- switching mode clears it
S.setMode(t.s, "horizontal")
check(t.s.selectedEnd == nil, "ground end: switching mode clears its selection")

------------------------------------------------------------------ ends that go away
-- the end is removed in the middle of a drag: back to picking it, nothing of the edit left
t = editing()
moveTo(t, onLeg(t.s.edit)); press(t)
S.confirmOpened(t.s)
t.free[2] = false
tick(t)
check(t.s.phase == "to" and t.s.to == nil and t.s.edit == nil and t.s.drag == nil and t.s.hit == nil
	and t.s.from == endA, "end gone: back to picking the end, with no edit and no drag left")
check(asked(t, "closeMode") == 1 and asked(t, "closeConfirm") == 1 and asked(t, "restart") == 0,
	"end gone: closes the mode window and the confirm window")

-- the start is removed with the confirm window open: the window is closed, the tool starts over
t = editing()
S.confirmOpened(t.s)
t.free[1] = false
tick(t)
check(t.s.phase == "from" and t.s.from == nil and t.s.to == nil and t.s.edit == nil and t.s.mode == "horizontal",
	"start gone: the tool starts over (the mode is kept)")
check(asked(t, "closeConfirm") == 1 and asked(t, "closeMode") == 1 and asked(t, "restart") == 1,
	"start gone: closes the confirm window too, and asks to drop the ghost")
check(t.s.confirmOpen == true, "start gone: the window counts as open until the GUI says it closed")
S.confirmClosed(t.s)
check(t.s.confirmOpen == false, "start gone: then it is closed")

------------------------------------------------------------------ the hint line
-- The hint names a gesture only where that gesture does something there.
local function says(line, what) return line ~= nil and line:find(what, 1, true) ~= nil end
-- A corner: one turn where the ends' rays meet, fixed until a turn is added.
local cornerB = { kind = "track", node = 2, x = 500, y = 400, dx = 0, dy = -1, z = 0, grade = 0 }
-- The edit for trying a turn of mobility mob: the corner for a fixed one, the corner with one turn
-- added for ray turns, the s-curve (three turns) for a free one.
local function withTurns(mob)
	local t = editing(endA, mob ~= "free" and cornerB or nil)
	for _ = 1, (mob == "ray" and 1 or 0) do
		local x, y = onLeg(t.s.edit); moveTo(t, x, y); click(t)
	end
	return t
end
-- Over handle hd of withTurns(mob): the hint, and what a press and a right-click there do.
local function tryHandle(mob, hd)
	local t = withTurns(mob)
	local e = t.s.edit
	moveTo(t, hd.x, hd.y)
	local over = t.s.hit ~= nil and t.s.hit.kind == hd.kind and t.s.hit.i == hd.i
	local hint = S.hint(t.s)
	press(t)
	local grabbed = t.s.drag ~= nil
	letGo(t)
	local turns = E.turnCount(e)
	moveTo(t, hd.x, hd.y); rightClick(t)
	return over, hint, grabbed, E.turnCount(e) < turns
end

t = editing()
e = t.s.edit
moveTo(t, FAR_X, FAR_Y)
check(S.hint(t.s) == "Click: build · Esc: back", "hint: over nothing: " .. tostring(S.hint(t.s)))
lx, ly = onLeg(e)
moveTo(t, lx, ly)
local hint = S.hint(t.s)
turns = E.turnCount(e)
press(t)
check(says(hint, "Click: add turn") and E.turnCount(e) == turns + 1, "hint: over a leg: " .. tostring(hint))
check(S.hint(t.s) == nil, "hint: none while dragging")
letGo(t)
local seen = {}
for _, mob in ipairs({ "fixed", "ray", "free" }) do
	for _, hd in ipairs(E.handles(withTurns(mob).s.edit)) do
		local key = hd.kind == "pi" and hd.mobility or "bracket"
		if not seen[key] and (hd.kind ~= "pi" or hd.mobility == mob) then
			local over, hint, grabbed, removed = tryHandle(mob, hd)
			if over then
				seen[key] = true
				check(says(hint, "Drag") == grabbed and says(hint, "Right-click") == removed,
					string.format("hint: %s: %s (press grabs: %s, right-click removes: %s)", key, tostring(hint),
						tostring(grabbed), tostring(removed)))
			end
		end
	end
end
check(seen.fixed and seen.ray and seen.free and seen.bracket, "hint: every kind of turn and a bracket was tried")

-- vertical: the track, and a point
t = editing()
e = t.s.edit
S.setMode(t.s, "vertical")
nodes = E.nodes(e)
m = math.floor(#nodes / 2)
moveTo(t, nodes[m].x, nodes[m].y)
hint = S.hint(t.s)
press(t); letGo(t)
check(says(hint, "Click: add point") and #E.points(e) == 1, "hint: over the track (vertical): " .. tostring(hint))
t.s.selected = nil
moveTo(t, nodes[m].x, nodes[m].y)
hint = S.hint(t.s)
press(t); letGo(t)
check(says(hint, "Click: select") and says(hint, "Shift+drag: height") and t.s.selected == 1 and #E.points(e) == 1,
	"hint: over a point: " .. tostring(hint))
rightClick(t)
check(says(hint, "Right-click: remove") and #E.points(e) == 0, "hint: a point's right-click removes it")
moveTo(t, FAR_X, FAR_Y)
check(S.hint(t.s) == "Click: build · Esc: back", "hint: over nothing (vertical)")

------------------------------------------------------------------ the cursor
-- the end under the mouse, drawn the way the game's builder draws it: where it is, and how
t = newTool()
moveTo(t, nil, nil)
check(S.cursor(t.s) == nil and S.hint(t.s) == nil, "cursor: over no ground, none and no hint")
t.groundZ = 3
moveTo(t, 600, 400)
local c = S.cursor(t.s)
check(c ~= nil and c.x == 600 and c.y == 400 and c.z == 3 and c.state == "ground",
	"cursor: before the first click, on the ground under the mouse")
check(S.hint(t.s) == "Click: start here", "cursor: before the first click, the hint: " .. tostring(S.hint(t.s)))
moveTo(t, endA.x + 5, endA.y + 5)
c = S.cursor(t.s)
check(c ~= nil and c.x == endA.x and c.y == endA.y and c.state == "trackEnd", "cursor: on a free track end, it snaps there")
click(t)
moveTo(t, 900, 300)
c = S.cursor(t.s)
check(c ~= nil and c.x == 900 and c.state == "ground" and S.hint(t.s) == "Click: end here",
	"cursor: after the first click, it follows the mouse to the end: " .. tostring(S.hint(t.s)))
-- while editing: on the end, turn or point under the mouse, and the ring while it is dragged
t = editing(endA, Ends.groundEnd(300, 200, 0))
moveTo(t, 301, 201)
c = S.cursor(t.s)
check(c ~= nil and c.x == t.s.to.x and c.y == t.s.to.y and c.state == "handle", "cursor: on a ground end under the mouse")
press(t)
moveTo(t, 420, 350)
c = S.cursor(t.s)
check(c ~= nil and c.x == 420 and c.y == 350 and c.state == "dragging", "cursor: dragging a ground end, it follows the end")
letGo(t)
moveTo(t, FAR_X, FAR_Y)
check(S.cursor(t.s) == nil, "cursor: while editing, over nothing, none")
t = editing()
e = t.s.edit
moveTo(t, onLeg(e))
check(S.cursor(t.s) == nil, "cursor: over a leg, none (it adds a turn)")
press(t)
local gi = t.s.drag.i
moveTo(t, 700, 100)
c = S.cursor(t.s)
check(c ~= nil and c.state == "dragging" and math.abs(c.x - E.polyline(e)[gi].x) < 1e-9
	and math.abs(c.y - E.polyline(e)[gi].y) < 1e-9, "cursor: dragging a turn, on the turn")
letGo(t)
S.setMode(t.s, "vertical")
tick(t)
nodes = E.nodes(e)
mid = nodes[math.floor(#nodes / 2)]
moveTo(t, mid.x, mid.y)
press(t)
local on = nodes[math.floor(#nodes / 2) + 10]
moveTo(t, on.x, on.y)
c = S.cursor(t.s)
local pt = E.points(e)[t.s.dragEl.i]
check(c ~= nil and c.state == "dragging" and c.x == pt.x and c.y == pt.y and c.z == nil,
	"cursor: dragging an elevation point, on the ground under it")
letGo(t)

------------------------------------------------------------------ odd moments
-- a press right after the second pick, before any tick of the edit and with no grab radius known
t = newTool()
moveTo(t, 5, 5); click(t)
moveTo(t, 1495, 795)
t.w.grab = nil
t.s.grab = nil
click(t)
local ok, err = pcall(press, t)
check(ok, "press before the edit's first tick: no error (" .. tostring(err) .. ")")
letGo(t)

-- a tool that is not live takes nothing
t = editing()
t.live = false
moveTo(t, FAR_X, FAR_Y)
check(click(t) == false and asked(t, "askBuild") == 0 and not S.backIsOurs(t.s) and not S.canGoBack(t.s),
	"not live: clicks and back are not the tool's")

------------------------------------------------------------------ existing-node ends (a switch)
-- node 1 has track through it along x (climbing 1 % towards +x); node 2 along y
local function dirs(dx, dy, grade)
	return { { dx = dx, dy = dy, grade = grade }, { dx = -dx, dy = -dy, grade = -grade } }
end
local nodeA = Ends.nodeEnd(1, 0, 0, 0, dirs(1, 0, 0.01))
local nodeB = Ends.nodeEnd(2, 1500, 800, 0, dirs(0, 1, 0))
t = newTool(nodeA, endB)
moveTo(t, 3, 3)
check(t.s.hover ~= nil and t.s.hover.node == 1 and S.cursor(t.s).state == "trackEnd", "node: the mouse snaps to a node with track through it")
click(t)
check(t.s.phase == "to" and t.s.from.node == 1, "node: a click picks it as the start")
moveTo(t, -600, 100)
check(t.s.from.dx == -1 and t.s.from.grade == -0.01, "node: before the second click, it leaves toward the mouse (behind)")
moveTo(t, 600, -100)
check(t.s.from.dx == 1 and t.s.from.grade == 0.01, "node: re-picked live as the mouse moves (ahead)")
click(t)
check(t.s.phase == "done" and t.s.from.node == 1 and t.s.from.dx == 1 and t.s.edit ~= nil, "node: the second click locks its direction")
moveTo(t, -600, 100)
local ea = (E.ends(t.s.edit))
check(t.s.from.dx == 1 and ea.dx == 1 and ea.node == 1, "node: locked once editing, the mouse moves it no more")
check(not E.draggableEnd(t.s.edit, 1) and not E.liftableEnd(t.s.edit, 1), "node: a node end neither moves nor lifts")
-- a node as the second end: aimed at the start
t = newTool(endA, nodeB)
moveTo(t, 3, 3); click(t)
moveTo(t, 1497, 797)
check(t.s.hover ~= nil and t.s.hover.node == 2 and t.s.hover.dy == -1, "node: as the end, it points toward the start")
click(t)
check(t.s.phase == "done" and t.s.to.node == 2 and t.s.to.dy == -1 and t.s.edit ~= nil, "node: the second click ends the track there")
-- a point along a piece: cut there, aimed like a node
t = newTool()
t.piece = { edge = 50, node0 = 61, node1 = 62, p0 = { x = -1000, y = 300, z = 0 }, t0 = { x = 2000, y = 0, z = 0 },
	p1 = { x = 1000, y = 300, z = 0 }, t1 = { x = 2000, y = 0, z = 0 } }
moveTo(t, 100, 303)
check(t.s.hover ~= nil and t.s.hover.kind == "split" and math.abs(t.s.hover.x - 100) < 1e-6 and S.cursor(t.s).state == "trackEnd",
	"cut: over a piece, the point on it under the mouse")
click(t)
t.piece = nil
moveTo(t, -700, 600)
check(t.s.from.kind == "split" and t.s.from.dx == -1, "cut: before the second click, it leaves toward the mouse")
moveTo(t, 700, 600); click(t)
check(t.s.phase == "done" and t.s.from.kind == "split" and t.s.from.dx == 1 and t.s.edit ~= nil, "cut: the second click locks it")

-- gone: the pick is undone
t = newTool(nodeA, endB)
moveTo(t, 3, 3); click(t); moveTo(t, 600, 0)
t.free[1] = nil
tick(t)
check(t.s.phase == "from" and t.s.from == nil, "node: a picked node that is gone undoes its pick")

if failures > 0 then
	print(failures .. " FAILED")
	os.exit(1)
end
print("all passed")
