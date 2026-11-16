-- Offline checks for placing bridges and tunnels (tg_structures.script.tl).
local H = dofile("test/harness.lua")
local S = H.mod("tg_structures")
local A = H.mod("tg_alignment")

local check = H.check

-- A straight track along x at height 0, a node every 10 m, over ground given by f(x).
local function line(len)
	local nodes, z = {}, {}
	for i = 0, len / 10 do
		nodes[#nodes + 1] = { x = i * 10, y = 0, heading = 0, s = i * 10, k = 0 }
		z[#z + 1] = 0
	end
	return nodes, z
end
local function kindAt(nodes, kinds, x)
	for i = 1, #kinds do
		if nodes[i].x <= x and x < nodes[i + 1].x then return kinds[i] end
	end
end
local function none() return false end

local nodes, z = line(1000)

-- a valley from 300 to 600, 30 m deep: a bridge over it
local kinds = S.classify(nodes, z, function(x) return (x > 300 and x < 600) and -30 or 0 end, none)
check(kindAt(nodes, kinds, 100) == "ground" and kindAt(nodes, kinds, 450) == "bridge" and kindAt(nodes, kinds, 800) == "ground",
	"valley: a bridge across it, ground either side")
check(S.summary(nodes, kinds) == "1 bridge (300 m)", "valley: summary " .. tostring(S.summary(nodes, kinds)))

-- a hill 40 m high: a tunnel through it
kinds = S.classify(nodes, z, function(x) return (x > 200 and x < 700) and 40 or 0 end, none)
check(kindAt(nodes, kinds, 450) == "tunnel" and kindAt(nodes, kinds, 100) == "ground", "hill: a tunnel through it")

-- shallow cuts and fills stay on the ground
kinds = S.classify(nodes, z, function(x) return 8 * math.sin(x / 50) end, none)
check(S.summary(nodes, kinds) == nil, "rolling ground within the thresholds: no structures")

-- a short dip (10 m) is not worth a bridge, but a river is
kinds = S.classify(nodes, z, function(x) return (x >= 500 and x < 510) and -30 or 0 end, none)
check(kindAt(nodes, kinds, 505) == "ground", "a 10 m dip: no bridge")
kinds = S.classify(nodes, z, function() return -2 end, function(x) return x >= 500 and x < 508 end)
check(kindAt(nodes, kinds, 505) == "bridge", "a narrow river: bridged anyway")

-- two valleys with a 20 m hump between: one bridge
kinds = S.classify(nodes, z, function(x) return (x > 300 and x < 600 and not (x > 440 and x < 460)) and -30 or 0 end, none)
check(kindAt(nodes, kinds, 450) == "bridge" and S.summary(nodes, kinds) == "1 bridge (300 m)", "a short hump inside a valley: one bridge")
-- ...but with a long stretch of ground between: two
kinds = S.classify(nodes, z, function(x) return ((x > 100 and x < 300) or (x > 600 and x < 800)) and -30 or 0 end, none)
check(S.summary(nodes, kinds) == "2 bridges (400 m)", "two valleys far apart: two bridges")

-- picking a type as the game's menu does
local offers = {
	{ id = 1, speedLimit = 25, autoSelectable = true },
	{ id = 2, speedLimit = 78, autoSelectable = true },
	{ id = 3, speedLimit = 39, autoSelectable = true },
	{ id = 4, speedLimit = 50, autoSelectable = false },
}
check(S.pickType(offers, 33) == 3, "type: the slowest at least as fast as the track")
check(S.pickType(offers, 90) == 2, "type: else the fastest")
check(S.pickType({}, 30) == nil, "type: none on offer")

-- carried over to long pieces: a node at each change, and each long piece takes its kind
do
	local ground = function(x) return (x > 300 and x < 600) and -30 or 0 end
	local ks = S.classify(nodes, z, ground, none)
	local ch = S.changes(nodes, ks)
	check(#ch == 2 and ch[1] == 300 and ch[2] == 600, "changes: where the bridge starts and ends")
	local long = {}
	for _, s in ipairs({ 0, 50, 100, 150, 200, 250, 300, 350, 400, 450, 500, 550, 600, 650, 1000 }) do
		long[#long + 1] = { x = s, y = 0, heading = 0, s = s, k = 0 }
	end
	local lk = A.carry(nodes, ks, long)
	local ok = #lk == #long - 1
	for j = 1, #lk do
		if lk[j] ~= kindAt(nodes, ks, (long[j].s + long[j + 1].s) / 2) then ok = false end
	end
	check(ok and lk[6] == "ground" and lk[7] == "bridge" and lk[12] == "bridge" and lk[13] == "ground",
		"carry: each long piece takes the kind under it")
end

H.done()
