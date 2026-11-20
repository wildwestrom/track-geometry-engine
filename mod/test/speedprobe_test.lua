-- Offline checks for the game's curve speed probe (tg_speedprobe.script.tl): the game's dry run is made up.
local H = dofile("test/harness.lua")
local P = H.mod("tg_speedprobe")

local check = H.check
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-9) end

-- A made-up game: speed grows with the radius; `calls` counts its dry runs.
local calls, track, ready, broken, lines = 0, "simple", true, false, {}
local function speedOn(R) return math.sqrt(3 * (R - 50)) end
local probe = P.new{
	key = function() return track end,
	ready = function() return ready end,
	minRadius = function() return 100 end,
	top = function() return 27.5 end,
	log = function(m) lines[#lines + 1] = m end,
	measure = function(R)
		calls = calls + 1
		if broken then error("no data") end
		return speedOn(R)
	end,
}

check(near(probe.speedAt(300), speedOn(300)), "speedAt: the game's speed on the radius")
local n = calls
probe.speedAt(300.04)
check(near(probe.cached(300), speedOn(300)) and calls == n, "cached: what is known, never measuring")
check(probe.cached(777) == nil and calls == n, "cached: an unknown radius is not measured")
check(calls == n, "speedAt: asked again (to 0.1 m), it is not measured again")
check(probe.top() == 27.5, "top: the track's top speed")
check(probe.speedAt(nil) == nil and probe.speedAt(0.5) == nil and probe.speedAt(0 / 0) == nil, "speedAt: no radius, no speed")

for _, v in ipairs({ 15, 20, 30 }) do
	local R = probe.radiusFor(v)
	check(R ~= nil and near(probe.speedAt(R), v, v * 0.005), "radiusFor: the radius that gives " .. v .. " m/s (" .. tostring(R) .. ")")
end
check(probe.radiusFor(0.1) == 100, "radiusFor: a speed under the minimum radius's gives the minimum radius")
check(probe.radiusFor(1e6) == P.MAX_RADIUS, "radiusFor: a speed over the widest radius's gives the widest")

ready = false
n = calls
check(probe.speedAt(400) == nil and probe.radiusFor(20) == nil and calls == n, "ready: with nothing to measure against there is no answer, and no dry run")
ready = true

-- a track type the game gives no speed for: one failure is kept, for that type alone
track, broken, calls = "bad", true, 0
check(probe.speedAt(300) == nil and calls == 1 and #lines >= 1 and lines[#lines]:find("none for bad", 1, true) ~= nil,
	"failure: no speed, and the log says for which track")
check(probe.speedAt(500) == nil and probe.radiusFor(20) == nil and calls == 1, "failure: remembered: no more dry runs for that track")
track, broken = "simple", false
check(near(probe.speedAt(300), speedOn(300)), "failure: another track type still has its speeds")

-- the test piece
local x, y, h, R, step = 10, 20, 0.5, 250, 20
local arc = P.testArc(x, y, h, R, step, 4)
local cx, cy = x - R * math.sin(h), y + R * math.cos(h)
local onCircle = true
for _, nd in ipairs(arc) do
	if not near(math.sqrt((nd.x - cx) ^ 2 + (nd.y - cy) ^ 2), R, 1e-6) then onCircle = false end
end
check(#arc == 5 and near(arc[1].x, x) and near(arc[1].y, y) and near(arc[1].heading, h) and arc[1].s == 0, "testArc: n pieces start at the given point and heading")
check(onCircle and near(arc[5].heading, h + 4 * step / R) and near(arc[5].s, 4 * step) and near(arc[2].k, 1 / R), "testArc: the nodes lie on the circle, turning left, with its curvature")

H.done()
