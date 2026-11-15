-- Offline checks for the tool's session (tg_session.script.tl): the game's events are played to it
-- by hand, with a made-up world. Run from mod/ after check.sh builds .tlpath/:
--   lua test/session_test.lua
local tl = require("tl")
tl.loader()
package.path = ".tlpath/?.tl;" .. package.path
local S = require("westrom_track_geometry::/track_geometry/tg_session.script.tl")
local E = require("westrom_track_geometry::/track_geometry/tg_edit.script.tl")

local failures = 0
local function check(ok, what)
	print((ok and "ok   " or "FAIL ") .. what)
	if not ok then failures = failures + 1 end
end

-- Two free ends: the new track leaves a going +x and arrives at b going +y.
local endA = { node = 1, x = 0, y = 0, dx = 1, dy = 0, z = 0, grade = 0 }
local endB = { node = 2, x = 1500, y = 800, dx = 0, dy = -1, z = 0, grade = 0 }

-- A tool on a made-up world: the session, the world it is shown, and every request it made.
local function newTool()
	local t = { live = true, free = { [1] = true, [2] = true }, shift = false, asked = {} }
	t.w = {
		grab = 10, cameraDist = 1000,
		shift = function() return t.shift end,
		gradeLimit = function() return 0.085 end,
		snap = function(x, y, _, exclude)
			for _, e in ipairs({ endA, endB }) do
				if x ~= nil and e.node ~= exclude and t.free[e.node] and (e.x - x) ^ 2 + (e.y - y) ^ 2 <= 40 ^ 2 then return e end
			end
			return nil, "Point at the end of a track."
		end,
		endFree = function(n) return t.free[n] == true end,
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
	t.w.terrX, t.w.terrY = x, y
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
local function editing()
	local t = newTool()
	moveTo(t, 5, 5); click(t)
	moveTo(t, 1495, 795); click(t)
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
moveTo(t, 700, 700)
check(t.s.phase == "from" and t.s.hover == nil and t.s.hoverMsg ~= nil, "picking: nothing near, nothing snapped, and why")
click(t)
check(t.s.phase == "from" and t.s.from == nil, "picking: a click on nothing picks nothing")
moveTo(t, 5, 5)
check(t.s.hover == endA, "picking: the mouse snaps to the end near it")
click(t)
check(t.s.phase == "to" and t.s.from == endA and t.s.hover == nil and asked(t, "openMode") == 0, "picking: a click picks the start")
moveTo(t, 5, 5)
check(t.s.hover == nil, "picking: the start is not offered as the end")
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

-- Esc steps back, once per input; while picking, only a right-click is the tool's
tick(t, S.RIGHT_TICKS + 1)
check(S.backIsOurs(t.s), "back: while editing, Esc is the tool's")
esc(t); esc(t); esc(t)
check(t.s.phase == "to" and t.s.edit == nil and t.s.to == nil and t.s.from == endA and asked(t, "closeMode") == 1,
	"back: Esc leaves the edit, once, however often it arrives, and closes the mode window")
tick(t, S.RIGHT_TICKS + 1)
check(not S.backIsOurs(t.s), "back: while picking the end, Esc is not the tool's (it closes the tool)")
mouse(t, 2, "released")
check(S.backIsOurs(t.s), "back: while picking the end, a right-click is the tool's")
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

if failures > 0 then
	print(failures .. " FAILED")
	os.exit(1)
end
print("all passed")
