-- Offline checks for where new track crosses existing streets (tg_crossings.script.tl).
local H = dofile("test/harness.lua")
local C = H.mod("tg_crossings")
local check = H.check

local function near(a, b, eps) return math.abs(a - b) < (eps or 1e-6) end
local function pt(x, y, z) return { x = x, y = y, z = z } end
-- a straight piece from a to b (the Hermite with both tangents the chord)
local function straight(edge, a, b, node0, node1)
	local t = pt(b.x - a.x, b.y - a.y, b.z - a.z)
	return { edge = edge, node0 = node0, node1 = node1, p0 = a, t0 = t, p1 = b, t1 = t }
end

-- new track along y = 0 at 10 m, a street across it at x = 40, also at 10 m
local track = straight(-1, pt(0, 0, 10), pt(100, 0, 10))
local street = straight(500, pt(40, -20, 10), pt(40, 30, 10), 11, 12)
local xs = C.find(track, { street })
check(#xs == 1, "find: a street across the piece: one crossing (" .. #xs .. ")")
local x = xs[1]
check(x ~= nil and x.why == nil and near(x.u, 0.4) and near(x.v, 0.4) and near(x.x, 40) and near(x.y, 0) and near(x.z, 10)
	and x.street == street, "find: at 40 m along the track and 20 m along the street, at the track's height")

-- a road at grade is one within 1 m of the track's height; further off it passes over or under
local within = straight(501, pt(40, -20, 10.8), pt(40, 30, 10.8), 11, 12)
local wx = C.find(track, { within })
check(#wx == 1 and wx[1].why == nil and near(wx[1].z, 10), "find: a road 0.8 m above the track: a crossing, at the track's height")
check(#C.find(track, { straight(502, pt(40, -20, 11.5), pt(40, 30, 11.5), 11, 12) }) == 0, "find: a road 1.5 m above the track: none")
check(#C.find(track, { straight(503, pt(40, -20, 8), pt(40, 30, 8), 11, 12) }) == 0, "find: a road 2 m below the track: none")
check(#C.find(track, { straight(504, pt(40, 5, 10), pt(40, 30, 10), 11, 12) }) == 0, "find: a road that stops short of the track: none")
check(#C.find(track, { straight(505, pt(0, 10, 10), pt(100, 10, 10), 11, 12) }) == 0, "find: a road alongside: none")

-- crossings that are no level crossing of ours: they stay collisions, with the game's own message
local atNode = C.find(track, { straight(510, pt(40, -20, 10), pt(40, 0.5, 10), 11, 12) })
check(#atNode == 1 and atNode[1].why ~= nil, "find: through a road node (a junction): not to be cut (" .. tostring(atNode[1] and atNode[1].why) .. ")")
local stops = straight(511, pt(40, -20, 10), pt(40, 30, 10), 11, 12)
stops.fixed = "the road carries stops or other objects"
local sx = C.find(track, { stops })
check(#sx == 1 and sx[1].why == stops.fixed, "find: a street carrying stops or other objects: not to be cut (" .. tostring(sx[1] and sx[1].why) .. ")")
local nearEnd = C.find(track, { straight(512, pt(99.6, -20, 10), pt(99.6, 30, 10), 11, 12) })
check(#nearEnd == 1 and nearEnd[1].why ~= nil, "find: a hair from the track piece's node: not to be cut (" .. tostring(nearEnd[1] and nearEnd[1].why) .. ")")

-- near a road node a road part would be too short for the game (under 6 m): a junction's road is
-- not cut there, a road made of two pieces is cut as one, across the joint between them
local nearJunction = C.find(track, { straight(513, pt(40, -20, 10), pt(40, 4, 10), 11, 12) })
check(#nearJunction == 1 and nearJunction[1].why ~= nil, "find: 4 m from a junction: not to be cut (" .. tostring(nearJunction[1] and nearJunction[1].why) .. ")")
local nearCrossing = straight(514, pt(40, -20, 10), pt(40, 9, 10), 11, 12)
nearCrossing.kind1 = "crossing"
local ncx = C.find(track, { nearCrossing })
check(#ncx == 1 and ncx[1].why ~= nil, "find: 9 m from a level crossing: not to be cut (" .. tostring(ncx[1] and ncx[1].why) .. ")")
local nearJ3 = straight(515, pt(40, -20, 10), pt(40, 14, 10), 11, 12)
nearJ3.kind1 = "junction"
local j3 = C.find(track, { nearJ3 })
check(#j3 == 1 and j3[1].why ~= nil, "find: 14 m from a junction of three roads: not to be cut (" .. tostring(j3[1] and j3[1].why) .. ")")
nearJ3.p1 = pt(40, 17, 10)
nearJ3.t0, nearJ3.t1 = pt(0, 37, 0), pt(0, 37, 0)
j3 = C.find(track, { nearJ3 })
check(#j3 == 1 and j3[1].why == nil, "find: 17 m from it: cut (" .. tostring(j3[1] and j3[1].why) .. ")")
local shallow = straight(516, pt(10, -10, 10), pt(80, 10, 10), 11, 12) -- (about 16 degrees)
local sh = C.find(track, { shallow })
check(#sh == 1 and sh[1].why ~= nil, "find: a road crossed at 16 degrees: not to be cut (" .. tostring(sh[1] and sh[1].why) .. ")")
local nearTrackEnd = C.find(track, { straight(517, pt(95, -20, 10), pt(95, 30, 10), 11, 12) })
check(#nearTrackEnd == 1 and nearTrackEnd[1].why ~= nil, "find: 5 m from the track piece's node: not to be cut (" .. tostring(nearTrackEnd[1] and nearTrackEnd[1].why) .. ")")

local function joined(a, b, joint) -- pieces a and b of one road, meeting at node joint
	if a.node0 == joint then a.beyond0 = b else a.beyond1 = b end
	if b.node0 == joint then b.beyond0 = a else b.beyond1 = a end
end
local south, north = straight(520, pt(40, -20, 10), pt(40, 4, 10), 11, 20), straight(521, pt(40, 4, 10), pt(40, 30, 10), 20, 12)
joined(south, north, 20)
local jx = C.find(track, { south, north })
local js = jx[1] and jx[1].street
check(#jx == 1 and jx[1].why == nil and near(jx[1].x, 40) and near(jx[1].y, 0), "find: 4 m from a joint: one crossing, cut (" .. #jx .. ", " .. tostring(jx[1] and jx[1].why) .. ")")
check(js ~= nil and js.joint == 20 and js.node0 == 11 and js.node1 == 12 and js.edge0 == 520 and js.edge1 == 521
	and #js.pieces == 2 and near(js.p0.y, -20) and near(js.p1.y, 30) and near(jx[1].v, 0.4),
	"find: ...on the road as one piece across the joint, from node 11 to node 12")
check(#C.find(track, { north }) == 0, "find: the piece beyond the joint alone does not cross")
local back = straight(522, pt(40, 30, 10), pt(40, 0, 10), 12, 21) -- (ends right on the track, drawn the other way)
local front = straight(523, pt(40, 0, 10), pt(40, -20, 10), 21, 11)
joined(back, front, 21)
local bx = C.find(track, { back, front })
check(#bx == 1 and bx[1].why == nil and bx[1].street.joint == 21 and bx[1].street.node0 == 12 and bx[1].street.node1 == 11,
	"find: through the joint itself, pieces drawn either way: one crossing, cut (" .. #bx .. ")")
local rs, rn = straight(530, pt(40, -20, 10), pt(40, 4, 10), 31, 40), straight(531, pt(40, 30, 10), pt(40, 4, 10), 32, 40)
rs.track, rn.track = true, true
joined(rs, rn, 40)
local rx = C.find(track, { rn, rs })
check(#rx == 1 and rx[1].street.track == true and rx[1].street.joint == 40, "find: a track of two pieces, one drawn the other way, taken as one: still track")
local bent = straight(524, pt(40, 4, 10), pt(55, 30, 10), 20, 12) -- (turns 30 degrees at the joint)
local south2 = straight(525, pt(40, -20, 10), pt(40, 4, 10), 11, 20)
joined(south2, bent, 20)
local kx = C.find(track, { south2 })
check(#kx == 1 and kx[1].why ~= nil, "find: 4 m from a joint where the road bends: not to be cut (" .. tostring(kx[1] and kx[1].why) .. ")")

-- a curved street (as the game keeps it: a Hermite) bending across the track
local mid = { edge = 507, node0 = 11, node1 = 12, p0 = pt(20, -30, 10), t0 = pt(60, 0, 0), p1 = pt(50, 30, 10), t1 = pt(0, 60, 0) }
local mx = C.find(track, { mid })
local mp = mx[1]
check(#mx == 1 and mp ~= nil and near(mp.y, 0, 1e-6) and mp.x > 20 and mp.x < 50, "find: a bend across the track: one crossing, on the track")

H.done()
