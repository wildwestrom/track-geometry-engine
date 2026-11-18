-- What the ghost reads off the map, kept from one ghost to the next (tg_gui).
--
-- The map is looked up in square cells CELL wide (tg_world.areaIn), and what a cell holds is kept
-- while the ghost follows a drag (or the mouse, before the end is picked): most of a long track
-- stays where it was from one ghost to the next, and each look at the octree visits every tree and
-- asset there. A ghost made at rest looks again (drop), so what it shows and builds is the map as
-- it is now.
-- The ground and water are kept at each point the plan reads them (tg_structures probes a long
-- track a few thousand times; each piece's last probe is the next one's first, and in a drag the
-- path before the dragged turn is read at the very same points again), and dropped with the cells.
-- Each lookup may end the ghost job's slice (tg_timing).

local crossings = require("westrom_track_geometry::/track_geometry/tg_crossings.script.tl")
local timing = require("westrom_track_geometry::/track_geometry/tg_timing.script.tl")
local world = require("westrom_track_geometry::/track_geometry/tg_world.script.tl")

local record Cell
	houses : {integer : {number}}
	streets : {integer : crossings.Street}
end

local record KeptMod
	Cell : Cell
	drop : function()
	cellsIn : function(x0 : number, y0 : number, x1 : number, y1 : number) : {Cell}
	ground : function(x : number, y : number) : number
	water : function(x : number, y : number) : boolean
	counts : function() : integer, integer
end

local M : KeptMod = {}

local CELL = 64.0
local MAX_CELLS = 4000 -- kept at most (then all dropped)
local MAX_TERRAIN = 50000

local cells : {string : Cell} = {}
local cellCount = 0
local groundAt : {string : number} = {}
local waterAt : {string : boolean} = {}
local terrainCount = 0

-- How many cells and terrain points are kept.
function M.counts() : integer, integer
	return cellCount, terrainCount
end

function M.drop()
	if cellCount > 0 then cells, cellCount = {}, 0 end
	if terrainCount > 0 then groundAt, waterAt, terrainCount = {}, {}, 0 end
end

local function pointKey(x : number, y : number) : string
	return string.format("%.3f,%.3f", x, y)
end

local function dropTerrain()
	groundAt, waterAt, terrainCount = {}, {}, 0
end

-- The ground's height at (x, y) (tg_world.ground), kept.
function M.ground(x : number, y : number) : number
	local k = pointKey(x, y)
	local z = groundAt[k]
	if z == nil then
		timing.probed()
		z = world.ground(x, y)
		if z ~= nil then
			if terrainCount >= MAX_TERRAIN then dropTerrain() end
			groundAt[k], terrainCount = z, terrainCount + 1
		end
	end
	return z
end

-- Is (x, y) on water (tg_world.water), kept.
function M.water(x : number, y : number) : boolean
	local k = pointKey(x, y)
	local w = waterAt[k]
	if w == nil then
		timing.probed()
		w = world.water(x, y)
		if terrainCount >= MAX_TERRAIN then dropTerrain() end
		waterAt[k], terrainCount = w, terrainCount + 1
	end
	return w
end

-- The cells covering the area, each looked up once while kept; nil when the map cannot be read.
function M.cellsIn(x0 : number, y0 : number, x1 : number, y1 : number) : {Cell}
	local out : {Cell} = {}
	for cx = math.floor(x0 / CELL), math.floor(x1 / CELL) do
		for cy = math.floor(y0 / CELL), math.floor(y1 / CELL) do
			local k = tostring(cx) .. "," .. tostring(cy)
			local c = cells[k]
			if c == nil then
				timing.slice()
				local houses, streets = world.areaIn(cx * CELL, cy * CELL, (cx + 1) * CELL, (cy + 1) * CELL)
				if houses == nil then return nil end
				if cellCount >= MAX_CELLS then M.drop() end
				c = { houses = houses, streets = streets }
				cells[k], cellCount = c, cellCount + 1
			end
			out[#out + 1] = c
		end
	end
	return out
end

return M
