-- Offline checks for the proposal builder (tg_proposal.script.tl), against a stub of the game's api
-- that keeps only what make() touches.
local H = dofile("test/harness.lua")

local function vec(x, y, z) return { x = x, y = y, z = z } end
local function baseEdge() -- (cloneable, as the game's)
	local c = {}
	function c.clone(self) local o = {} for k, v in pairs(self) do o[k] = v end return o end
	return c
end
local existing = {} -- edge id -> its BaseEdge
local comps = { [3] = {}, [4] = {}, [2] = {} } -- component type -> entity -> component (BASE_NODE_CONFIG, BASE_EDGE_STREET, PLAYER_OWNED)
api = {
	type = {
		Vec3f = { new = vec },
		NodeAndEntity = { new = function() return { comp = {} } end },
		BaseNodeLaneConnectionAndEntity = { new = function() return {} end },
		SegmentAndEntity = { new = function() return { comp = {} } end },
		SimpleProposal = { new = function() return { streetProposal = {} } end },
		PlayerOwned = { new = function() return {} end },
		ComponentType = { BASE_EDGE = 1, PLAYER_OWNED = 2, BASE_NODE_CONFIG = 3, BASE_EDGE_STREET = 4 },
		enum = { BaseEdgeType = { NORMAL = 0, BRIDGE = 1, TUNNEL = 2 }, RoadType = { STREET = 0, TRACK = 1 } },
	},
	res = { streetTemplateRep = { find = function() return 1 end, get = function() return { laneConfigs = {}, streetStyle = "s" } end } },
	engine = {
		util = { getPlayer = function() return 7 end },
		getComponent = function(e, t)
			if t == 1 then return existing[e] end
			if t == 2 then return comps[2][e] or {} end
			if t == 4 and comps[4][e] ~= nil then -- (each read a copy, as the game's)
				local o = {} for k, v in pairs(comps[4][e]) do o[k] = v end return o
			end
			return comps[t][e]
		end,
	},
}

local P = H.mod("tg_proposal")
local check = H.check

-- a straight path of 3 pieces from ground to ground
local nodes, z, grades = {}, {}, {}
for i = 0, 3 do
	nodes[#nodes + 1] = { x = i * 50, y = 0, heading = 0, s = i * 50, k = 0 }
	z[#z + 1], grades[#grades + 1] = 0, 0
end
local p, pieceOf, why = P.make(nodes, { template = "t", z = z, grades = grades })
check(p ~= nil and why == nil, "make: a plain path: " .. tostring(why))
local edges = p.streetProposal.edgesToAdd
check(#edges == 3, "make: one edge per piece")
local ok = true
for _, e in ipairs(edges) do
	local i = pieceOf[e.entity]
	ok = ok and i ~= nil and e.comp.position0.x == nodes[i].x and e.comp.position1.x == nodes[i + 1].x
end
check(ok, "make: each new edge maps to the plan piece it runs along")

-- a switch at the far end: its node's piece is replaced by a copy, which is no plan piece
local be = baseEdge()
be.objects = {}
existing[900] = be
local to = { kind = "node", node = 55, x = 150, y = 0 }
p, pieceOf, why = P.make(nodes, { template = "t", z = z, grades = grades, to = to, replace = { 900 } })
check(p ~= nil and #p.streetProposal.edgesToAdd == 4, "make: three pieces and a copy: " .. tostring(why))
local mapped, copies = 0, 0
for _, e in ipairs(p.streetProposal.edgesToAdd) do
	if pieceOf[e.entity] ~= nil then mapped = mapped + 1 else copies = copies + 1 end
end
check(mapped == 3 and copies == 1, "make: the copy at the switch belongs to no plan piece")

-- a street across the second piece at grade: a level crossing, a node shared by the street's two
-- parts and the piece's two
local street = baseEdge()
street.objects, street.laneConfigs, street.roadType, street.node0, street.node1 = {}, { "lane" }, 0, 11, 12
street.position0, street.position1, street.tangent0, street.tangent1 = vec(75, -20, 0.5), vec(75, 30, 0.5), vec(0, 50, 0), vec(0, 50, 0)
existing[500] = street
local streetComp, streetOwner = { precedence = "p" }, { player = 3 }
comps[4][500], comps[2][500] = streetComp, streetOwner
-- (lane rules at node 11 name the street piece: they must name its part there instead)
comps[3][11] = { laneConnections = { { segment0 = 500, segment1 = 600 }, { segment0 = 600, segment1 = 601 } }, crosswalks = { 500 } }
local S = { edge = 500, node0 = 11, node1 = 12, p0 = vec(75, -20, 0.5), t0 = vec(0, 50, 0), p1 = vec(75, 30, 0.5), t1 = vec(0, 50, 0) }
p, pieceOf, why = P.make(nodes, { template = "t", z = z, grades = grades, streets = { S }, crossingType = 4 })
check(p ~= nil, "make: a level crossing: " .. tostring(why))
local sp = p.streetProposal
local track, roads = {}, {}
for _, e in ipairs(sp.edgesToAdd) do
	if e.type == 0 then roads[#roads + 1] = e else track[#track + 1] = e end
end
check(#track == 4 and #roads == 2 and #sp.edgesToAdd == 6, "make: the crossed piece in two parts, the street in two")
local X = nil
for _, ne in ipairs(sp.nodesToAdd) do
	local q = ne.comp.position
	if math.abs(q.x - 75) < 1e-6 and math.abs(q.y) < 1e-6 then X = ne end
end
check(X ~= nil and math.abs(X.comp.position.z) < 1e-9, "make: a new node where they cross, at the track's height (0 m, not the street's 0.5 m)")
local ids = {}
for _, e in ipairs(sp.edgesToAdd) do ids[#ids + 1] = e.entity end
table.sort(ids, function(a, b) return a > b end)
local contiguous = true
for i, id in ipairs(ids) do contiguous = contiguous and id == -i end
for _, ne in ipairs(sp.nodesToAdd) do contiguous = contiguous and ne.entity < -#ids end
check(contiguous, "make: edges -1..-6, then the nodes")
local onX = 0
for _, e in ipairs(track) do
	if e.comp.node0 == X.entity or e.comp.node1 == X.entity then onX = onX + 1 end
end
local p2 = 0
for _, e in ipairs(track) do if pieceOf[e.entity] == 2 then p2 = p2 + 1 end end
check(onX == 2 and p2 == 2, "make: both parts of the crossed piece meet at the node and belong to plan piece 2")
local a, b = roads[1], roads[2]
if a.comp.node0 ~= 11 then a, b = b, a end
check(a.comp.node0 == 11 and a.comp.node1 == X.entity and b.comp.node0 == X.entity and b.comp.node1 == 12,
	"make: the street's parts run from its nodes to the crossing")
check(a.comp.position1.z == 0 and b.comp.position0.z == 0 and a.comp.position0.z == 0.5 and b.comp.position1.z == 0.5,
	"make: the street's parts keep their far ends and ramp to the track's height")
check(a.comp.laneConfigs[1] == "lane" and b.comp.roadType == 0 and a.streetEdge ~= nil and a.streetEdge.precedence == streetComp.precedence and b.playerOwned == streetOwner,
	"make: the street's parts keep its lanes, type, street settings and owner")
check(#(sp.edgesToRemove or {}) == 1 and sp.edgesToRemove[1] == 500, "make: the street piece goes")
check(sp.node2rcType ~= nil and sp.node2rcType[X.entity] == 4, "make: the node is a level crossing, of the type given")
local cfg = sp.nodeConfigsToAdd and sp.nodeConfigsToAdd[1]
check(#(sp.nodeConfigsToRemove or {}) == 1 and sp.nodeConfigsToRemove[1] == 11 and cfg ~= nil and cfg.entity == 11
	and cfg.comp.laneConnections[1].segment0 == a.entity and cfg.comp.laneConnections[2].segment0 == 600 and cfg.comp.crosswalks[1] == a.entity,
	"make: the lane rules at the street's node name its part there")

-- no level crossing where find says it cannot be one: the street stays, a collision
local S2 = { edge = 500, node0 = 11, node1 = 12, p0 = vec(75, -20, 0.5), t0 = vec(0, 50, 0), p1 = vec(75, 30, 0.5), t1 = vec(0, 50, 0), fixed = "the road carries stops or other objects" }
p, pieceOf, why = P.make(nodes, { template = "t", z = z, grades = grades, streets = { S2 }, crossingType = 4 })
check(p ~= nil and #p.streetProposal.edgesToAdd == 3 and #(p.streetProposal.edgesToRemove or {}) == 0 and p.streetProposal.node2rcType == nil,
	"make: a street with stops on it is not cut: " .. tostring(why))
local S3 = { edge = 500, node0 = 11, node1 = 12, p0 = vec(75, -20, 0.5), t0 = vec(0, 20.5, 0), p1 = vec(75, 0.5, 0.5), t1 = vec(0, 20.5, 0) }
p = P.make(nodes, { template = "t", z = z, grades = grades, streets = { S3 }, crossingType = 4 })
check(p ~= nil and #p.streetProposal.edgesToAdd == 3, "make: a crossing through a road node is not cut")

-- a street whose node is already a level crossing (a second track beside the first): that crossing
-- is made again, of its own type, or it would go on naming the street piece that goes
local S4 = { edge = 500, node0 = 11, node1 = 12, p0 = vec(75, -20, 0.5), t0 = vec(0, 50, 0), p1 = vec(75, 30, 0.5), t1 = vec(0, 50, 0), crossing1 = 2 }
p = P.make(nodes, { template = "t", z = z, grades = grades, streets = { S4 }, crossingType = 4 })
check(p ~= nil and p.streetProposal.node2rcType[12] == 2, "make: the level crossing at the street's far node is made again")

-- a road of two pieces cut as one across their joint (tg_crossings): both pieces and the joint go,
-- and the lane rules at its far ends name its parts
local piece2 = baseEdge()
piece2.objects, piece2.laneConfigs, piece2.roadType, piece2.node0, piece2.node1 = {}, { "lane" }, 0, 20, 12
existing[501] = piece2
comps[4][501] = { precedenceNode0 = "joint side", precedenceNode1 = "give way at 12" }
comps[3][12] = { laneConnections = { { segment0 = 501, segment1 = 700 } }, crosswalks = {} }
local SJ = { edge = 500, node0 = 11, node1 = 12, p0 = vec(75, -20, 0.5), t0 = vec(0, 50, 0), p1 = vec(75, 30, 0.5), t1 = vec(0, 50, 0),
	pieces = { 500, 501 }, joint = 20, edge0 = 500, edge1 = 501 }
p, pieceOf, why = P.make(nodes, { template = "t", z = z, grades = grades, streets = { SJ }, crossingType = 4 })
sp = p and p.streetProposal
local gone, configured = {}, {}
for _, e in ipairs(sp and sp.edgesToRemove or {}) do gone[e] = true end
for _, n in ipairs(sp and sp.nodeConfigsToRemove or {}) do configured[n] = true end
local last
for _, e in ipairs(sp and sp.edgesToAdd or {}) do if e.type == 0 and e.comp.node1 == 12 then last = e end end
check(sp ~= nil and gone[500] and gone[501] and #(sp.nodesToRemove or {}) == 1 and sp.nodesToRemove[1] == 20,
	"make: across a joint: both pieces and the joint go: " .. tostring(why))
check(last ~= nil and configured[12] and not configured[20] and sp.nodeConfigsToAdd ~= nil,
	"make: across a joint: lane rules at both far ends carried over, none at the joint (it goes with its node)")
local farCfg
for _, c in ipairs(sp and sp.nodeConfigsToAdd or {}) do if c.entity == 12 then farCfg = c end end
check(farCfg ~= nil and last ~= nil and farCfg.comp.laneConnections[1].segment0 == last.entity, "make: across a joint: the far end's rules name the part there")
check(last ~= nil and last.streetEdge ~= nil and last.streetEdge.precedenceNode1 == "give way at 12",
	"make: across a joint: the part at the far end keeps that piece's precedence there (" .. tostring(last and last.streetEdge and last.streetEdge.precedenceNode1) .. ")")
-- a piece of that road crossed again elsewhere is not cut twice
local SP = { edge = 501, node0 = 20, node1 = 12, p0 = vec(125, -20, 0.5), t0 = vec(0, 50, 0), p1 = vec(125, 30, 0.5), t1 = vec(0, 50, 0) }
local _, _, _, found2 = P.make(nodes, { template = "t", z = z, grades = grades, streets = { SJ, SP }, crossingType = 4 })
local cutOf = {}
for _, c in ipairs(found2 or {}) do cutOf[c.street.edge] = c.why == nil end
check(cutOf[500] == true and cutOf[501] == false, "make: a piece already cut across a joint is not cut again")

-- a track across the second piece at grade: a diamond crossing, a node shared by the track's two
-- parts and the piece's two; no level crossing there
local rail = baseEdge()
rail.objects, rail.roadType, rail.roadTemplate, rail.node0, rail.node1 = {}, 1, "old.lua", 31, 32
existing[520] = rail
local railOwner = { player = 5 }
comps[2][520] = railOwner
local R = { edge = 520, node0 = 31, node1 = 32, p0 = vec(75, -20, 0.5), t0 = vec(0, 50, 0), p1 = vec(75, 30, 0.5), t1 = vec(0, 50, 0), track = true }
p, pieceOf, why = P.make(nodes, { template = "t", z = z, grades = grades, streets = { R }, crossingType = 4 })
check(p ~= nil, "make: a diamond crossing: " .. tostring(why))
sp = p and p.streetProposal or { edgesToAdd = {}, nodesToAdd = {} }
local ours, theirs = {}, {}
for _, e in ipairs(sp.edgesToAdd) do
	if pieceOf[e.entity] ~= nil then ours[#ours + 1] = e else theirs[#theirs + 1] = e end
end
check(#ours == 4 and #theirs == 2, "make: across a track: the crossed piece in two parts, the track in two (" .. #ours .. ", " .. #theirs .. ")")
local D = nil
for _, ne in ipairs(sp.nodesToAdd) do
	local q = ne.comp.position
	if math.abs(q.x - 75) < 1e-6 and math.abs(q.y) < 1e-6 then D = ne end
end
local ta, tb = theirs[1], theirs[2]
if ta and ta.comp.node0 ~= 31 then ta, tb = tb, ta end
check(D ~= nil and ta ~= nil and ta.comp.node0 == 31 and ta.comp.node1 == D.entity and tb.comp.node0 == D.entity and tb.comp.node1 == 32,
	"make: across a track: its parts run from its nodes to the shared node")
check(ta ~= nil and ta.type == 1 and tb.type == 1 and ta.streetEdge == nil and ta.comp.roadTemplate == "old.lua" and tb.playerOwned == railOwner,
	"make: across a track: its parts are track, keeping its template and owner")
check(#(sp.edgesToRemove or {}) == 1 and sp.edgesToRemove[1] == 520, "make: across a track: the track piece goes")
check(sp.node2rcType == nil, "make: across a track: no level crossing at the shared node")
local RS = { edge = 520, node0 = 31, node1 = 32, p0 = vec(75, -20, 0.5), t0 = vec(0, 50, 0), p1 = vec(75, 30, 0.5), t1 = vec(0, 50, 0), track = true,
	fixed = "the track carries signals or other objects" }
p = P.make(nodes, { template = "t", z = z, grades = grades, streets = { RS }, crossingType = 4 })
check(p ~= nil and #p.streetProposal.edgesToAdd == 3 and #(p.streetProposal.edgesToRemove or {}) == 0,
	"make: a track carrying signals is not cut")
-- double track (5 m apart) across the piece: both are cut, the game's own builder crosses it so
local rail2 = baseEdge()
rail2.objects, rail2.roadType, rail2.node0, rail2.node1 = {}, 1, 33, 34
existing[521] = rail2
local R2 = { edge = 521, node0 = 33, node1 = 34, p0 = vec(80, -20, 0.5), t0 = vec(0, 50, 0), p1 = vec(80, 30, 0.5), t1 = vec(0, 50, 0), track = true }
local _, _, whyDouble, foundDouble = P.make(nodes, { template = "t", z = z, grades = grades, streets = { R, R2 }, crossingType = 4 })
local cutDouble = 0
for _, c in ipairs(foundDouble or {}) do if c.why == nil then cutDouble = cutDouble + 1 end end
check(cutDouble == 2, "make: double track 5 m apart: both cut (" .. cutDouble .. ", " .. tostring(whyDouble) .. ")")
-- a road and a track 5 m apart: not both (the game refuses a road piece that short, NOTES.md)
local _, _, _, foundMixed = P.make(nodes, { template = "t", z = z, grades = grades, streets = { S, R2 }, crossingType = 4 })
local cutMixed = 0
for _, c in ipairs(foundMixed or {}) do if c.why == nil then cutMixed = cutMixed + 1 end end
check(cutMixed == 1, "make: a road and a track 5 m apart: only one cut (" .. cutMixed .. ")")
-- a piece the new track already replaces at its end (a switch's copy) is not crossed as well
existing[900] = rail
local RE = { edge = 900, node0 = 31, node1 = 32, p0 = vec(75, -20, 0.5), t0 = vec(0, 50, 0), p1 = vec(75, 30, 0.5), t1 = vec(0, 50, 0), track = true }
p, _, why = P.make(nodes, { template = "t", z = z, grades = grades, to = to, replace = { 900 }, streets = { RE } })
check(p ~= nil and #p.streetProposal.edgesToAdd == 4 and #p.streetProposal.edgesToRemove == 1,
	"make: a piece replaced at the switch is not crossed too: " .. tostring(why))

-- the town buildings in the way: each one's construction, once, from both of the dry run's lists;
-- anything else (an industry, a station, track, a field) stays in the way
local houseOf = { [301] = 801, [302] = 802, [303] = 802 } -- town building -> its construction
local data = { collisionInfo = {
	collisionEntities = { { entity = 301 }, { entity = 400 }, { entity = 302 }, { entity = -3 } },
	buildingEntities = { 303, 301, 500 },
} }
local cons = P.toClear(data, function(e) return houseOf[e] end)
table.sort(cons)
check(#cons == 2 and cons[1] == 801 and cons[2] == 802, "toClear: the houses' constructions, each once")
check(#P.toClear({}, function() return 1 end) == 0, "toClear: no collision info, nothing to clear")
check(#P.toClear({ collisionInfo = { collisionEntities = { { entity = 400 } } } }, function() return nil end) == 0,
	"toClear: an industry in the way is not cleared")

-- a check lists only some of the houses in the way; once those are cleared the next check lists
-- more: those join the ones already cleared
local more, new = P.toClear({ collisionInfo = { collisionEntities = { { entity = 302 }, { entity = 304 } } } },
	function(e) return ({ [302] = 802, [304] = 804 })[e] end, { 801, 802 })
table.sort(more)
check(new == 1 and #more == 3 and more[1] == 801 and more[2] == 802 and more[3] == 804,
	"toClear: houses a later check lists join those already cleared")
local _, none = P.toClear({ collisionInfo = { collisionEntities = { { entity = 301 } } } }, function(e) return houseOf[e] end, { 801 })
check(none == 0, "toClear: nothing new when the check lists only houses already cleared")

-- what else is in the way: the collisions that are no town building (each entity once)
local _, _, others = P.toClear(data, function(e) return houseOf[e] end, nil)
check(others == 1, "toClear: the industry is the one other thing in the way (the new piece -3 is not counted)")
local _, _, onlyHouses = P.toClear({ collisionInfo = { collisionEntities = { { entity = 301 }, { entity = 301 } } } },
	function(e) return houseOf[e] end, nil)
check(onlyHouses == 0, "toClear: nothing else in the way when only houses are")

-- what is built: the same track, with the town buildings left for the game to gather
local ghost = { streetProposal = { nodesToAdd = { "n" }, edgesToAdd = { "e1", "e2" }, edgesToRemove = { 9 }, nodesToRemove = { 8 } },
	constructionsToRemove = { 801, 802 } }
local built = P.gathering(ghost)
local sp = built.streetProposal
check(built ~= ghost and #sp.nodesToAdd == 1 and #sp.edgesToAdd == 2 and sp.edgesToRemove[1] == 9 and sp.nodesToRemove[1] == 8,
	"gathering: the same track")
check(built.constructionsToRemove == nil or #built.constructionsToRemove == 0, "gathering: no constructions removed by the proposal")
check(#ghost.constructionsToRemove == 2, "gathering: the ghost keeps its own")
local crossingGhost = { streetProposal = { nodesToAdd = {}, edgesToAdd = { "e" }, nodeConfigsToRemove = { 11 },
	nodeConfigsToAdd = { "cfg" }, node2rcType = { [-9] = 4 } } }
local cb = P.gathering(crossingGhost).streetProposal
check(cb.nodeConfigsToRemove[1] == 11 and cb.nodeConfigsToAdd[1] == "cfg" and cb.node2rcType[-9] == 4,
	"gathering: the level crossings and the lane rules carried over")

-- the track's footprint: points along its pieces (the Hermites the game builds), on the ground only
local straight = { { x = 0, y = 0, heading = 0, s = 0, k = 0 }, { x = 40, y = 0, heading = 0, s = 40, k = 0 },
	{ x = 80, y = 0, heading = 0, s = 80, k = 0 } }
local pts = P.footprint(straight, nil, 4)
local okPts = #pts >= 21
for _, q in ipairs(pts) do okPts = okPts and math.abs(q[2]) < 1e-9 and q[1] >= -1e-9 and q[1] <= 80 + 1e-9 end
check(okPts, "footprint: points every 4 m or closer along a straight, on it (" .. #pts .. ")")
local onBridge = P.footprint(straight, { "ground", "bridge" }, 4)
local maxX = 0
for _, q in ipairs(onBridge) do maxX = math.max(maxX, q[1]) end
check(#onBridge > 0 and maxX <= 40 + 1e-9, "footprint: none along a bridge")
-- a quarter turn of radius 50: its middle point lies near the arc, not on the chord
local r = 50
local arc = { { x = 0, y = 0, heading = 0, s = 0, k = 1 / r }, { x = r, y = r, heading = math.pi / 2, s = math.pi * r / 2, k = 1 / r } }
local mid, best = nil, math.huge
for _, q in ipairs(P.footprint(arc, nil, 2)) do
	local d = math.abs(q[1] - q[2]) -- (on the line y = x: the turn's middle)
	if d < best then best, mid = d, q end
end
local off = math.abs(math.sqrt(mid[1] ^ 2 + (mid[2] - r) ^ 2) - r)
check(off < 0.5, string.format("footprint: follows the curve (%.2f m off the arc at its middle)", off))

-- the town buildings on it: those whose box comes within the half width of a point
local boxes = {
	[1] = { 10, 2, 20, 12 }, -- 2 m off the track
	[2] = { 10, 5, 20, 12 }, -- 5 m off
	[3] = { 30, -8, 36, 8 }, -- across it
	[4] = { 100, -5, 110, 5 }, -- past its end
}
local hit = P.onFootprint(pts, boxes, 3)
table.sort(hit)
check(#hit == 2 and hit[1] == 1 and hit[2] == 3, "onFootprint: the boxes within 3 m of the track")

-- every house in the way, by checks that each name only some: check(A) is a dry run with the
-- proposal removing A itself, naming at most two of the houses still in the way
local function reveal(inWay)
	local runs = 0
	return function(A)
		runs = runs + 1
		local gone = {}
		for _, c in ipairs(A or {}) do gone[c] = true end
		local cols = {}
		for _, c in ipairs(inWay) do
			if not gone[c] and #cols < 2 then cols[#cols + 1] = { entity = c + 1000 } end -- (a house; its construction is c)
		end
		cols[#cols + 1] = { entity = 7 } -- (a road: stays in the way)
		return { collisionInfo = { collisionEntities = cols } }
	end, function() return runs end
end
local function sorted(t) table.sort(t) return t end
local houseCon = function(e) if e > 1000 then return e - 1000 end end
local chk, runsN = reveal({ 11, 12, 13, 14, 15 })
local all = sorted(P.allHouses(chk, houseCon, 8))
check(#all == 5 and all[1] == 11 and all[5] == 15 and runsN() == 4, "allHouses: every house, two a check, until a check names none new (" .. runsN() .. " checks)")
local none, runs0 = reveal({})
check(#P.allHouses(none, houseCon, 8) == 0 and runs0() == 1, "allHouses: none in the way: one check")
local many, runsM = reveal({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 })
local some = P.allHouses(many, houseCon, 3)
check(#some == 6 and runsM() == 3, "allHouses: at most so many checks")
check(#P.allHouses(function() return nil end, houseCon, 8) == 0, "allHouses: no check from the game: none")

-- the same, a check at a time: check may yield, and allHouses carries on when resumed
local chkY, runsY = reveal({ 11, 12, 13, 14, 15 })
local co = coroutine.create(function()
	return P.allHouses(function(A) local d = chkY(A); coroutine.yield(); return d end, houseCon, 8)
end)
local resumes, ys, yn = 0
repeat
	local _, h, n = coroutine.resume(co)
	resumes = resumes + 1
	ys, yn = h, n
until coroutine.status(co) == "dead"
ys = sorted(ys)
check(#ys == 5 and ys[1] == 11 and ys[5] == 15 and yn == 4 and runsY() == 4 and resumes == 5, "allHouses: in a coroutine, a check a resume, the same houses (" .. resumes .. " resumes)")

H.done()
