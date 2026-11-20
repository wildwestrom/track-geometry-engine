-- Offline checks for the plan of the new track (tg_plan.script.tl).
local H = dofile("test/harness.lua")
local P = H.mod("tg_plan")
local E = H.mod("tg_edit")
local S = H.mod("tg_structures")
local N = H.mod("tg_ends")

local check = H.check
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-6) end
local function endAt(x, y, dx, dy, z, grade)
	return { x = x, y = y, dx = dx, dy = dy, z = z, grade = grade }
end
local function flat() return 0 end
local function dry() return false end
-- a valley 30 m deep between x = 600 and x = 1000
local function valley(x) return (x > 600 and x < 1000) and -30 or 0 end

-- Whether a built node sits at chainage s.
local function nodeAt(plan, s)
	for _, nd in ipairs(plan.built.nodes) do
		if near(nd.s, s) then return true end
	end
	return false
end

-- What must hold for every plan of a path: both samplings run from end to end on the ends, the
-- built pieces are long enough for the game and have sound numbers, and the track leaves each end
-- at its existing track's grade.
local function sound(plan, a, b, what)
	local bn, dn = plan.built.nodes, plan.dense.nodes
	check(near(bn[1].x, a.x) and near(bn[1].y, a.y) and near(bn[#bn].x, b.x) and near(bn[#bn].y, b.y)
		and near(dn[1].x, a.x) and near(dn[1].y, a.y) and near(dn[#dn].x, b.x) and near(dn[#dn].y, b.y)
		and near(bn[#bn].s, dn[#dn].s), what .. ": dense and built both run from end to end")
	local bad = #plan.built.z ~= #bn or #plan.grades ~= #bn or #plan.dense.z ~= #dn
	for i, nd in ipairs(bn) do
		for _, v in ipairs({ nd.x, nd.y, nd.heading, plan.built.z[i], plan.grades[i] }) do
			if v ~= v or v == math.huge or v == -math.huge then bad = true end
		end
		if i > 1 then
			local d2 = (nd.x - bn[i - 1].x) ^ 2 + (nd.y - bn[i - 1].y) ^ 2 + (plan.built.z[i] - plan.built.z[i - 1]) ^ 2
			if d2 < 0.01 then bad = true end
		end
	end
	check(not bad, what .. ": every built piece is at least 0.1 m, with finite numbers")
	check(near(plan.built.z[1], a.z) and near(plan.built.z[#bn], b.z)
		and near(plan.grades[1], a.grade) and near(plan.grades[#bn], -b.grade),
		what .. ": leaves each end at its height and its track's grade")
end

-- Each built piece is one kind: the dense pieces inside it (classified afresh) all have its kind.
local function oneKindEach(plan, ground, what)
	local dn, bn = plan.dense.nodes, plan.built.nodes
	local dk = S.classify(dn, plan.dense.z, ground, dry)
	local bad, j = false, 1
	for i = 1, #dn - 1 do
		local mid = (dn[i].s + dn[i + 1].s) / 2
		while j < #bn - 1 and bn[j + 1].s <= mid do j = j + 1 end
		if dk[i] ~= plan.kinds[j] then bad = true end
	end
	check(not bad and #plan.kinds == #bn - 1, what .. ": each built piece is one kind")
end

------------------------------------------------------------------ a straight over a valley
local a = endAt(0, 0, 1, 0, 0, 0.005)
local b = endAt(2000, 0, -1, 0, 0, 0.004)
local plan, why = P.path(a, b, nil, valley, dry)
check(plan ~= nil, "valley: a plan (" .. tostring(why) .. ")")
sound(plan, a, b, "valley")
oneKindEach(plan, valley, "valley")
local changes = S.changes(plan.built.nodes, plan.kinds)
check(#changes == 2 and plan.structures ~= nil and plan.structures:find("1 bridge") ~= nil and plan.note == nil,
	"valley: one bridge, " .. tostring(plan.structures) .. ", with a node at each of its ends")
check(plan.info == "2000 m, straight" and plan.minRadius == math.huge and #plan.curves == 0,
	"valley: info " .. tostring(plan.info))
check(#plan.built.nodes < #plan.dense.nodes and #plan.dense.nodes == 201,
	"valley: built in " .. (#plan.built.nodes - 1) .. " long pieces, read every STEP")

-- without ground there are no structures; when reading it fails, none either, and a note
local bare = P.path(a, b, nil, nil, nil)
check(bare ~= nil and bare.kinds == nil and bare.structures == nil and bare.note == nil and #bare.built.nodes == 2,
	"no ground: no structures, a straight is one piece")
local failed = P.path(a, b, nil, function() error("no terrain") end, dry)
check(failed ~= nil and failed.kinds == nil and failed.note ~= nil and failed.note:find("no terrain") ~= nil,
	"ground fails: still a plan, no structures, a note")

------------------------------------------------------------------ an edit with an elevation point
local e = E.new(a, b)
local i = E.insertElevation(e, 1500)
assert(E.movePoint(e, i, 1500, 6, 1.0) and E.points(e)[i].z == 6)
plan = P.path(a, b, e, valley, dry)
check(plan.info == "2000 m, 0 turns", "elevation point: an edit's info counts its turns: " .. tostring(plan.info))
sound(plan, a, b, "elevation point")
oneKindEach(plan, valley, "elevation point")
check(nodeAt(plan, 1500), "elevation point: a built node at it")
local zAt
for k, nd in ipairs(plan.built.nodes) do if near(nd.s, 1500) then zAt = plan.built.z[k] end end
check(zAt ~= nil and near(zAt, 6), "elevation point: the track is at its height there")

-- an elevation point too close to a bridge's end for a node each: the elevation point has the
-- node, and the bridge ends there
e = E.new(a, b)
i = E.insertElevation(e, changes[1] + 0.5)
plan = P.path(a, b, e, valley, dry)
sound(plan, a, b, "close breaks")
oneKindEach(plan, valley, "close breaks")
check(nodeAt(plan, changes[1] + 0.5) and not nodeAt(plan, changes[1]),
	"close breaks: the elevation point 0.5 m past the bridge's end has the node")

------------------------------------------------------------------ a path with a turn
a = endAt(0, 0, 1, 0, 0, 0)
b = endAt(1500, 800, 0, -1, 10, 0)
plan, why = P.path(a, b, nil, flat, dry)
check(plan ~= nil, "turn: a plan (" .. tostring(why) .. ")")
sound(plan, a, b, "turn")
check(#plan.curves >= 1 and plan.minRadius < math.huge and plan.info == "1787 m, long s-curve",
	"turn: " .. tostring(plan.info) .. ", " .. #plan.curves .. " curve(s), smallest radius " .. string.format("%.0f m", plan.minRadius))
local worst = 0
for k = 2, #plan.built.nodes do
	local d = plan.built.nodes[k].heading - plan.built.nodes[k - 1].heading
	worst = math.max(worst, math.abs(math.atan2 and math.atan2(math.sin(d), math.cos(d)) or math.atan(math.sin(d), math.cos(d))))
end
check(worst <= math.rad(15) + 1e-9, string.format("turn: no built piece turns more than 15 deg (%.1f deg)", math.deg(worst)))

-- the game's speeds, one per built piece, land on the dense pieces inside each
local speeds = {}
for k = 1, #plan.built.nodes - 1 do speeds[k] = 10 + k end
local r, rwhy = P.readout(plan, speeds)
local bad, j = false, 1
local dn, bn = plan.dense.nodes, plan.built.nodes
for k = 1, #dn - 1 do
	local mid = (dn[k].s + dn[k + 1].s) / 2
	while j < #bn - 1 and bn[j + 1].s < mid do j = j + 1 end
	if r.speeds[k] ~= 10 + j then bad = true end
end
check(not bad and #r.speeds == #dn - 1 and r.plan == plan and rwhy == nil, "readout: each dense piece has its built piece's speed")
local curveBadges, alongBadges = 0, 0
for _, bd in ipairs(r.curves or {}) do if bd.kind == "curve" then curveBadges = curveBadges + 1 end end
for _, bd in ipairs(r.along or {}) do if bd.kind == "along" then alongBadges = alongBadges + 1 end end
check(r.curves ~= nil and curveBadges == #plan.curves and #r.curves == curveBadges, "readout: a badge at each curve, on its own (" .. curveBadges .. ")")
check(r.along ~= nil and alongBadges > 0 and #r.along == alongBadges, "readout: the badges along the path, on their own (" .. alongBadges .. ")")
local lines = P.summary(r, 40)
check(type(lines) == "table" and #lines > 0, "readout: summary: " .. table.concat(lines or {}, " | "))
-- speeds missing (the game gave none): still a readout
local r0 = P.readout(plan, {})
check(r0 ~= nil and r0.curves ~= nil and r0.along ~= nil, "readout: without speeds, still badges")

------------------------------------------------------------------ switches
-- The game refuses a new piece that overlaps the existing track without sharing a node with it, so
-- the pieces out of (and into) a switch are merged until the first node clear of the track there.
local function straightPiece(x0, x1, y)
	return { edge = 7, node0 = 1, node1 = 2, p0 = { x = x0, y = y, z = 0 }, t0 = { x = x1 - x0, y = 0, z = 0 },
		p1 = { x = x1, y = y, z = 0 }, t1 = { x = x1 - x0, y = 0, z = 0 } }
end
local function clearance(nd, pcs) return N.clearance({ beside = pcs }, nd.x, nd.y) end
local main = straightPiece(-200, 200, 0)
local cut = N.splitEnd(main, 0.5)
check(cut.beside ~= nil and #cut.beside == 2, "switch: a split end knows the two halves beside it")
local far = N.groundEnd(400, -300, 0)
local sw = N.aim(cut, far.x, far.y)
check(sw.beside == cut.beside, "switch: aiming keeps the pieces beside the end")
plan, why = P.path(sw, far, nil, flat, dry)
check(plan ~= nil, "switch out: a plan (" .. tostring(why) .. ")")
local bn = plan.built.nodes
check(clearance(bn[2], { main }) >= N.CLEAR - 1e-6,
	string.format("switch out: the first piece reaches clear of the track (%.2f m)", clearance(bn[2], { main })))
check(bn[2].s < 120, string.format("switch out: and not much further (%.1f m)", bn[2].s))
plan, why = P.path(far, N.aim(cut, far.x, far.y), nil, flat, dry)
check(plan ~= nil, "switch in: a plan (" .. tostring(why) .. ")")
bn = plan.built.nodes
check(clearance(bn[#bn - 1], { main }) >= N.CLEAR - 1e-6,
	string.format("switch in: the last piece starts clear of the track (%.2f m)", clearance(bn[#bn - 1], { main })))
-- (a short piece at the switch: the track runs on past it, so clear of the piece alone is not clear)
local stub = straightPiece(-6, 6, 0)
stub.beyond = { straightPiece(6, 200, 0), straightPiece(-200, -6, 0) }
local short = N.aim(N.splitEnd(stub, 0.5), far.x, far.y)
plan, why = P.path(short, far, nil, flat, dry)
check(plan ~= nil and math.abs(plan.built.nodes[2].y) >= N.CLEAR - 1e-6,
	string.format("switch out of a short piece: clear of the track running on past it (%.2f m off its line)",
		plan ~= nil and math.abs(plan.built.nodes[2].y) or -1))
-- (a short path into a switch: every node but the switch's own is clear of its track)
local nearby = N.groundEnd(45, -6, 0)
plan, why = P.path(nearby, N.aim(cut, nearby.x, nearby.y), nil, flat, dry)
check(plan ~= nil, "short switch in: a plan (" .. tostring(why) .. ")")
if plan ~= nil then
	local unclear = 0
	for i = 1, #plan.built.nodes - 1 do
		if clearance(plan.built.nodes[i], { main }) < N.CLEAR - 1e-6 and i > 1 then unclear = unclear + 1 end
	end
	check(unclear == 0, "short switch in: no node between the ends within CLEAR of the track (" .. unclear .. ")")
end
-- (a crossover between parallel tracks a little over CLEAR apart: a node near the far end is
-- clear of the near track but on the far one, so it may not stand)
local function through(node, x, y, pcs)
	return N.nodeEnd(node, x, y, 0, { { dx = 1, dy = 0, grade = 0 }, { dx = -1, dy = 0, grade = 0 } }, pcs)
end
local lineA, lineB = straightPiece(-300, 600, 0), straightPiece(-300, 600, 5.2)
local xa, xb = through(11, 0, 0, { lineA }), through(12, 232, 5.2, { lineB })
plan, why = P.path(N.aim(xa, xb.x, xb.y), N.aim(xb, xa.x, xa.y), nil, flat, dry)
check(plan ~= nil, "crossover: a plan (" .. tostring(why) .. ")")
if plan ~= nil then
	local onTrack = 0
	for i = 2, #plan.built.nodes - 1 do
		local nd = plan.built.nodes[i]
		if clearance(nd, { lineA, lineB }) < N.CLEAR - 1e-6 then onTrack = onTrack + 1 end
	end
	check(onTrack == 0, "crossover: no node between the ends within CLEAR of either track (" .. onTrack .. " of "
		.. #plan.built.nodes - 2 .. ")")
end
-- (a shallow switch runs beside the joints of the track it leaves: the pieces through them merge)
local function pieceOf(edge, n0, x0, n1, x1)
	local pc = straightPiece(x0, x1, 0)
	pc.edge, pc.node0, pc.node1 = edge, n0, n1
	return pc
end
local cutPiece = pieceOf(20, 1, 0, 2, 80)
-- (22 is laid the other way round)
cutPiece.beyond = { pieceOf(21, 2, 80, 3, 180), pieceOf(22, 4, 400, 3, 180), pieceOf(19, 0, -100, 1, 0) }
local shallow = N.splitEnd(cutPiece, 0.25) -- at x = 20
-- the branch: one piece to (320, 5), parallel at both ends
local branch = { edge = -1, p0 = { x = 20, y = 0, z = 0 }, t0 = { x = 300, y = 0, z = 0 },
	p1 = { x = 320, y = 5, z = 0 }, t1 = { x = 300, y = 0, z = 0 } }
local function always() return true end
local runs = N.runs(shallow, branch, always)
check(#runs == 1, "runs: only the side the branch runs along (" .. #runs .. ")")
if #runs == 1 then
	local r = runs[1]
	-- joint 2 at 60 m along is 0.5 m off the branch, joint 3 at 160 m is 2.7 m off: past NEAR
	check(r.first == shallow.beside[2] and #r.edges == 1 and r.edges[1] == 21 and r.nodes[1] == 2 and r.node == 3,
		"runs: the half ahead takes the next piece, up to the first joint clear of the branch")
	check(near(r.p.x, 180) and near(r.t0.x, 160) and near(r.t1.x, 160) and near(r.t0.y, 0),
		"runs: the merged piece runs from the cut to that joint")
end
check(#N.runs(shallow, branch, function() return false end) == 0, "runs: none through a joint that may not go")
local steep = { edge = -1, p0 = { x = 20, y = 0, z = 0 }, t0 = { x = 60, y = 0, z = 0 },
	p1 = { x = 70, y = 30, z = 0 }, t1 = { x = 0, y = 60, z = 0 } }
check(#N.runs(shallow, steep, always) == 0, "runs: none when the branch is clear at the joint")
-- (a node end, with the piece ahead laid toward the node)
local atNode = N.nodeEnd(3, 160, 0, 0, { { dx = 1, dy = 0, grade = 0 }, { dx = -1, dy = 0, grade = 0 } },
	{ pieceOf(21, 2, 80, 3, 160), pieceOf(22, 4, 200, 3, 160), pieceOf(23, 4, 200, 5, 600) })
local out = { edge = -1, p0 = { x = 160, y = 0, z = 0 }, t0 = { x = 300, y = 0, z = 0 },
	p1 = { x = 460, y = 5, z = 0 }, t1 = { x = 300, y = 0, z = 0 } }
runs = N.runs(atNode, out, always)
check(#runs == 1 and runs[1].first.edge == 22 and runs[1].edges[1] == 23 and runs[1].node == 5
	and near(runs[1].p.x, 600) and near(runs[1].t1.x, 440),
	"runs: from a node end, through a piece laid the other way")
-- (what a switch changes: the world read through fakes, the built nodes from the end straight on)
local function piecesAt(en) return ({ [3] = { 21, 22 }, [4] = { 22, 23 } })[en.kind == "node" and en.node or 0] or {} end
local function leaving(en) return { { x = en.x, y = 0, heading = 0, s = 0 }, { x = en.x + 300, y = 5, heading = 0, s = 300 } } end
local rep, rs = P.switches(atNode, far, leaving(atNode), piecesAt, always)
check(#rep == 2 and rep[1] == 21 and rep[2] == 22 and #rs == 1 and rs[1].edges[1] == 23,
	"switches: a node end replaces its pieces, and the run goes on past the one ahead")
rep, rs = P.switches(atNode, N.nodeEnd(4, 200, 0, 0, atNode.dirs, atNode.beside), leaving(atNode), piecesAt, always)
check(#rep == 3 and rep[3] == 23 and #rs == 0, "switches: a piece at both ends is replaced once, and merged into no run")
rep, rs = P.switches(shallow, far, leaving(shallow), piecesAt, always)
check(#rep == 0 and #rs == 1 and rs[1].edges[1] == 21 and rs[1].node == 3,
	"switches: a cut replaces nothing, and merges through the joint beside it")
rep, rs = P.switches(shallow, far, leaving(shallow), piecesAt, function(joint) return joint ~= 2 end)
check(#rep == 0 and #rs == 0, "switches: no run through a joint that may not go")
rep, rs = P.switches(N.trackEnd(1, 20, 0, 0, 1, 0, 0), far, leaving(shallow), piecesAt, always)
check(#rep == 0 and #rs == 0, "switches: a free end changes nothing")
local plain = P.path(N.trackEnd(1, 0, 0, 0, 1, 0, 0), far, nil, flat, dry)
check(plain ~= nil and plain.built.nodes[2].s < bn[#bn].s - bn[#bn - 1].s,
	"switch: a free end's pieces are not merged")

------------------------------------------------------------------ no path
plan, why = P.path(endAt(0, 0, 1, 0, 0, 0), endAt(1, 0, -1, 0, 0, 0), nil, flat, dry)
check(plan == nil and type(why) == "string", "ends 1 m apart: no plan, " .. tostring(why))

H.done()
