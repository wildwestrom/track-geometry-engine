-- The game's curve speed on a radius, for the mode window's Curve section. Only the game knows it
-- (the mod keeps no model of its own: a guess would be wrong), and only a dry run of a piece of
-- that radius gives it, so the GUI hands in the dry run (`measure`) and this module caches its
-- answers, remembers when it cannot answer, and finds the radius a speed needs by search. No game
-- API here, so test/speedprobe_test.lua runs it outside the game.

local alignment = require("track_geometry_tool::/track_geometry/tg_alignment.script.tl")

-- What the module needs from the game.
local record Source
	key : function() : string -- the track type's identity: answers are kept per key
	ready : function() : boolean -- false when there is nothing to measure against (no edit)
	minRadius : function() : number -- the smallest radius the tool lays (m)
	top : function() : number -- the track type's top speed (m/s); 0 when unknown
	measure : function(R : number) : number -- the game's speed on radius R (m/s); nil: no data; may throw
	log : function(msg : string)
end

local record Probe
	speedAt : function(R : number) : number -- nil when the game cannot say
	radiusFor : function(v : number) : number -- nil when the game cannot say
	top : function() : number
end

local record SpeedProbe
	Source : Source
	Probe : Probe
	MAX_RADIUS : number
	new : function(src : Source) : Probe
	testArc : function(x : number, y : number, heading : number, R : number, step : number, n : integer) : {alignment.Sample}
end

local M : SpeedProbe = {}

M.MAX_RADIUS = 20000.0 -- the widest radius searched for (m)

-- Where the search stops: the radius known to a quarter of a percent.
local PRECISION = 1.0025

-- n pieces of `step` m of a left-hand arc of radius R that starts at (x, y) going along `heading`:
-- the nodes of a short test piece.
function M.testArc(x : number, y : number, heading : number, R : number, step : number, n : integer) : {alignment.Sample}
	local cx, cy = x - R * math.sin(heading), y + R * math.cos(heading)
	local nodes : {alignment.Sample} = {}
	for i = 0, n do
		local h = heading + i * step / R
		nodes[i + 1] = { x = cx + R * math.sin(h), y = cy - R * math.cos(h), heading = h, s = i * step, k = 1 / R }
	end
	return nodes
end

function M.new(src : Source) : Probe
	local cache : {string : number} = {}
	local failed : {string : boolean} = {} -- track types the game gave no speed for (a failing call costs ~300 ms)
	local probe : Probe = { top = src.top }

	-- Cached by track type and radius (to 0.1 m).
	probe.speedAt = function(R : number) : number
		if R == nil or R ~= R or R < 1 or not src.ready() then return nil end
		local type = src.key()
		if failed[type] then return nil end
		local key = string.format("%s|%.1f", type, R)
		if cache[key] ~= nil then return cache[key] end
		local ok, v = pcall(src.measure, R)
		if not ok or v == nil then
			failed[type] = true
			src.log(string.format("curve speed probe: none for %s (%s)", type, ok and "no speed in the data" or tostring(v)))
			return nil
		end
		src.log(string.format("curve speed probe: %s R %.1f m -> %.1f km/h", type, R, (v as number) * 3.6))
		cache[key] = v as number
		return v as number
	end

	-- Bisection on the radius (the speed grows with it), from the minimum radius to MAX_RADIUS.
	probe.radiusFor = function(v : number) : number
		if not src.ready() then return nil end
		local lo, hi = src.minRadius(), M.MAX_RADIUS
		local sLo, sHi = probe.speedAt(lo), probe.speedAt(hi)
		if sLo == nil or sHi == nil then return nil end
		if v <= sLo then return lo end
		if v >= sHi then return hi end
		while hi / lo >= PRECISION do
			local mid = math.sqrt(lo * hi)
			local s = probe.speedAt(mid)
			if s == nil then return nil end
			if s < v then lo = mid else hi = mid end
		end
		return math.sqrt(lo * hi)
	end

	return probe
end

return M
