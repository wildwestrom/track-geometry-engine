-- Offline checks for the plan of the new track (tg_plan.script.tl). Run from mod/ after check.sh
-- builds .tlpath/:
--   lua test/plan_test.lua
local tl = require("tl")
tl.loader()
package.path = ".tlpath/?.tl;" .. package.path
local P = require("westrom_track_geometry::/track_geometry/tg_plan.script.tl")
local E = require("westrom_track_geometry::/track_geometry/tg_edit.script.tl")
local S = require("westrom_track_geometry::/track_geometry/tg_structures.script.tl")
local A = require("westrom_track_geometry::/track_geometry/tg_alignment.script.tl")

local failures = 0
local function check(ok, what)
	print((ok and "ok   " or "FAIL ") .. what)
	if not ok then failures = failures + 1 end
end
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

------------------------------------------------------------------ the stub
local a = endAt(0, 0, 1, 0, 100, 0.01)
local stub = P.stub(a, flat, dry)
check(#stub.built.nodes == 2 and stub.built.nodes[2].s == P.STUB and near(stub.built.nodes[2].x, P.STUB)
	and near(stub.built.z[1], 100) and near(stub.built.z[2], 100 + 0.01 * P.STUB)
	and stub.grades[1] == 0.01 and stub.grades[2] == 0.01,
	"stub: a straight STUB long out of the end, at its track's grade")
check(stub.dense == stub.built and stub.info == nil and stub.curves == nil and stub.kinds[1] == "bridge",
	"stub: read as it is built; 100 m above the ground it is a bridge")

------------------------------------------------------------------ a straight over a valley
a = endAt(0, 0, 1, 0, 0, 0.005)
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
assert(E.moveElevation(e, i, 1500, 6, 1.0) and E.points(e)[i].z == 6)
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
check(worst <= P.MAX_TURN + 1e-9, string.format("turn: no built piece turns more than MAX_TURN (%.1f deg)", math.deg(worst)))

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
local curveBadges = 0
for _, bd in ipairs(r.badges or {}) do if bd.kind == "curve" then curveBadges = curveBadges + 1 end end
check(r.badges ~= nil and curveBadges == #plan.curves, "readout: a badge at each curve (" .. curveBadges .. ")")
local lines = P.summary(r, 40)
check(type(lines) == "table" and #lines > 0, "readout: summary: " .. table.concat(lines or {}, " | "))
-- speeds missing (the game gave none): still a readout
local r0 = P.readout(plan, {})
check(r0 ~= nil and r0.badges ~= nil, "readout: without speeds, still badges")

------------------------------------------------------------------ no path
plan, why = P.path(endAt(0, 0, 1, 0, 0, 0), endAt(1, 0, -1, 0, 0, 0), nil, flat, dry)
check(plan == nil and type(why) == "string", "ends 1 m apart: no plan, " .. tostring(why))

if failures > 0 then
	print(failures .. " FAILED")
	os.exit(1)
end
print("all passed")
