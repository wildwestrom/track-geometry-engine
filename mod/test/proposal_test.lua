-- Offline checks for the ghost's lifecycle (tg_proposal.script.tl), through its interface, against
-- a fake port: the game's side comes in as plain records.
local H = dofile("test/harness.lua")
local P = H.mod("tg_proposal")
local check = H.check

-- A fake port. Each ghost made is a new table (its proposal); a dry run answers with `game`'s
-- check of what it removes. Town building e > 1000 is a house of construction e - 1000.
local function fakePort()
	local f = { clock = 0, made = 0, gone = {}, ends = {}, runs = 0, balance = nil }
	f.footprint, f.crossed = nil, nil -- (what make says it clears and crosses)
	f.dry = function(removing, gather) return { cost = 100, critical = false, messages = {}, warnings = {}, hits = { collides = {}, buildings = {} } } end
	f.pieces, f.sections, f.sectionDry = 8, 0, nil -- (a section's token is { j =, k = }; sectionDry(j, k) is its check)
	f.port = {
		make = function(a, b, sketch)
			f.made = f.made + 1
			if a == nil or b == nil then return {} end
			return { proposal = { n = f.made, sketch = sketch }, info = "path " .. f.made, crossed = f.crossed, cleared = f.footprint, account = f.account, pieces = f.pieces }
		end,
		section = function(j, k) f.sections = f.sections + 1; return { j = j, k = k }, {} end,
		describe = function(i) return string.format("piece %d: 10.0 m at (%d.0, 0.0)", i, i) end,
		dryRun = function(p, removing, gather)
			f.runs = f.runs + 1
			if p ~= nil and p.j ~= nil then return f.sectionDry(p.j, p.k) end
			return f.dry(removing or {}, gather)
		end,
		setCleared = function() return true end,
		constructionOf = function(e) if e > 1000 then return e - 1000 end end,
		allExist = function(list) for _, e in ipairs(list) do if f.gone[e] then return false end end return true end,
		joinable = function(e) return e == nil or not f.ends[e] end,
		balance = function() return f.balance end,
		now = function() return f.clock end,
	}
	return f
end
local A, B = "A", "B" -- (the ends: plain values the module only hands back to the port)

-- a check of the ghost, as the adapter would boil the game's data down
local function chk(t)
	t = t or {}
	return { cost = t.cost or 100, critical = t.critical or false, messages = t.messages or {}, warnings = t.warnings or {},
		hits = { collides = t.collides or {}, buildings = t.buildings or {} }, detail = function() return t.lines or {} end }
end

------------------------------------------------------------------ the rest rule

-- picking the end: the mouse moves, then rests
local f = fakePort()
local G = P.new(function() end, f.port)
P.tick(G, { key = "k1", a = A, b = B, toPhase = true })
check(G.ghost.sketch == true, "tick: the mouse moving the end makes a sketch")
f.clock = 200
P.tick(G, { key = "k1", a = A, b = B, toPhase = true })
check(G.ghost.sketch == true and f.made == 1, "tick: 200 ms at rest: still the sketch, not made again")
f.clock = 300
P.tick(G, { key = "k1", a = A, b = B, toPhase = true })
check(not G.ghost.sketch and G.ghost.proposal ~= nil and f.made == 2, "tick: 300 ms at rest on the clock makes it a ghost")
P.tick(G, { key = "k1", a = A, b = B, toPhase = true })
check(f.made == 2, "tick: the ghost is not made again while its key holds")
f.clock = 310
P.tick(G, { key = "k2", a = A, b = B, toPhase = true })
check(G.ghost.sketch == true and G.ghost.key == "k2", "tick: a new key, the mouse moved: a sketch again")

-- a drag stays a sketch, even at rest; a ghost never becomes a sketch without moving
f = fakePort()
G = P.new(function() end, f.port)
P.tick(G, { key = "d", a = A, b = B, settled = true, dragging = true })
f.clock = 5000
P.tick(G, { key = "d", a = A, b = B, settled = true, dragging = true })
check(G.ghost.sketch == true, "tick: a drag at rest is still a sketch")
P.tick(G, { key = "d", a = A, b = B, settled = true })
check(not G.ghost.sketch and f.made == 2, "tick: let go, the sketch becomes the ghost")
P.tick(G, { key = "d", a = A, b = B, settled = true, dragging = true })
check(not G.ghost.sketch and f.made == 2, "tick: pressed without moving: the ghost stays")

-- without a clock, the ticks decide
f = fakePort()
f.port.now = function() return nil end
G = P.new(function() end, f.port)
for _ = 1, 6 do P.tick(G, { key = "k", a = A, b = B, toPhase = true }) end -- (the move, then 5 at rest)
check(G.ghost.sketch == true, "tick: no clock: five ticks at rest, still a sketch")
P.tick(G, { key = "k", a = A, b = B, toPhase = true })
check(not G.ghost.sketch and G.ghost.proposal ~= nil, "tick: no clock: six ticks at rest make it a ghost")

------------------------------------------------------------------ the viewer's checks

-- a settled ghost (both ends picked, no drag): made at once
local function settledGhost(f)
	local logs = {}
	local G = P.new(function(m) logs[#logs + 1] = m end, f.port)
	P.tick(G, { key = "s", a = A, b = B, settled = true })
	return G, logs
end

f = fakePort()
G = settledGhost(f)
local old = P.viewKey(G)
P.tick(G, { key = "s2", a = A, b = B, settled = true })
check(P.onData(G, old, chk({ cost = 5, critical = true })) == false and G.ghost.cost == nil and not G.ghost.critical,
	"onData: a check of an older ghost is ignored")
check(P.onData(G, P.viewKey(G), chk({ cost = 7 })) == true and G.ghost.cost == 7, "onData: the ghost's own check is taken")

-- houses alone in its way are no fault: they go
f = fakePort()
G = settledGhost(f)
P.onData(G, P.viewKey(G), chk({ messages = { "Collision" }, collides = { 1011, 1012 } }))
check(G.ghost.housesOnly == true and not G.ghost.collides and G.ghost.newHouses == 2, "onData: houses alone in the way are no fault")
check(G.ghost.errors == "The town buildings in the way will go.", "onData: the tooltip says they go (" .. tostring(G.ghost.errors) .. ")")
f = fakePort()
G = settledGhost(f)
P.onData(G, P.viewKey(G), chk({ messages = { "Collision" }, collides = { 1011, 7 } }))
check(not G.ghost.housesOnly and G.ghost.collides and G.ghost.hasErrors, "onData: a house and a road in the way: it collides")
check(G.ghost.errors == "Errors: Collision\nRuns into 2 things.", "onData: the tooltip says what it runs into")

------------------------------------------------------------------ clearing the houses

-- every check names one more house; the search's dry runs find none: the rounds stop at the limit
f = fakePort()
local logs
G, logs = settledGhost(f)
local n = 0
for _ = 1, 30 do
	n = n + 1
	P.onData(G, P.viewKey(G), chk({ messages = { "Collision" }, collides = { 1100 + n } }))
	P.tick(G, { key = "s", a = A, b = B, settled = true })
end
check(G.ghost.round == P.CLEAR_ROUNDS and G.ghost.built ~= nil, "clearing: the rounds stop after the limit (" .. tostring(G.ghost.round) .. ")")
check(not G.ghost.housesOnly and G.ghost.collides, "clearing: houses left after the last round are a fault")
local saidRounds = false
for _, l in ipairs(logs) do saidRounds = saidRounds or l:find("after " .. P.CLEAR_ROUNDS .. " rounds") ~= nil end
check(saidRounds, "clearing: running out of rounds is logged")

-- the search: the dry runs name two houses at a time until none are new; the ghost clears them all
f = fakePort()
local inWay = { 11, 12, 13, 14, 15 }
f.dry = function(removing, gather)
	if gather then return chk() end -- (what is built: the game gathers them)
	local gone, cols = {}, {}
	for _, c in ipairs(removing) do gone[c] = true end
	for _, c in ipairs(inWay) do if not gone[c] and #cols < 2 then cols[#cols + 1] = c + 1000 end end
	return chk({ collides = cols })
end
G = settledGhost(f)
P.onData(G, P.viewKey(G), chk({ messages = { "Collision" }, collides = { 1011 } }))
P.tick(G, { key = "s", a = A, b = B, settled = true })
check(G.ghost.found and #G.ghost.cleared == 5 and G.ghost.round == 1 and G.ghost.dataKey == nil, "clearing: the search clears every house, then waits for the new view's check")
P.onData(G, P.viewKey(G), chk())
f.runs = 0
P.tick(G, { key = "s", a = A, b = B, settled = true })
check(G.ghost.built ~= nil and G.ghost.built.refused == nil and f.runs == 1, "clearing: nothing more in the way: what is built is checked once")

------------------------------------------------------------------ the build gate

-- a ghost settled for good: footprint houses 801 and 802 cleared, a street 500 cut
local function ready(t)
	t = t or {}
	local f = fakePort()
	f.footprint, f.crossed, f.balance = { 801, 802 }, { 500 }, t.balance
	if t.built then f.dry = function() return t.built end end
	local G = settledGhost(f)
	P.onData(G, P.viewKey(G), chk({ cost = 100 }))
	P.tick(G, { key = "s", a = A, b = B, settled = true })
	return G, f
end
G, f = ready()
local why, offer = P.gate(G, A, B)
check(why == nil and offer ~= nil and offer.proposal == G.ghost.proposal and offer.cost == 100 and offer.info == G.ghost.info,
	"gate: a settled ghost is offered, at what is built's cost: " .. tostring(why))
f.runs = 0
local _, again = P.gate(G, A, B)
check(again ~= nil and again.proposal == offer.proposal and f.runs == 0, "gate: asked again (the Build click), the same offer, no new dry run")

G, f = ready()
f.ends[B] = true
check(P.gate(G, A, B) == "an end is gone or its track has changed", "gate: refused: a gone end")
G, f = ready()
f.gone[802] = true
check(P.gate(G, A, B) == "a building in the way has changed", "gate: refused: a gone building")
G, f = ready()
f.gone[500] = true
check(P.gate(G, A, B) == "a road or track it crosses has changed", "gate: refused: a gone crossed street")
G = ready({ balance = 99 })
check(P.gate(G, A, B) == "not enough money", "gate: refused: not enough money")
G = ready({ balance = 100 })
check(P.gate(G, A, B) == nil, "gate: just enough money")
G = ready({ built = chk({ cost = 100, critical = true, messages = { "Too steep" } }) })
local refusedWhy, none2 = P.gate(G, A, B)
check(refusedWhy == "the game refuses it" and none2 == nil, "gate: refused: the game refuses what is built")
G = ready({ built = chk({ cost = 100, collides = { 7 } }) })
check(P.gate(G, A, B) == "it still runs into something", "gate: refused: what is built still runs into something")
f = fakePort()
G = settledGhost(f)
check(P.gate(G, A, B) == "the game is still checking it", "gate: refused: no check yet")
P.onData(G, P.viewKey(G), chk({ critical = true, messages = { "Too steep" } }))
P.tick(G, { key = "s", a = A, b = B, settled = true })
check(P.gate(G, A, B) == "the game refuses it", "gate: refused: the game refuses the ghost")
f = fakePort()
G = settledGhost(f)
P.onData(G, P.viewKey(G), chk({ messages = { "Collision" }, collides = { 1011 } }))
check(P.gate(G, A, B) == "the game is still checking it", "gate: refused: houses still to be searched for")

------------------------------------------------------------------ refusals in the log

local function refusalLines(logs)
	local out = {}
	for _, l in ipairs(logs) do if l:find("^refusal#") then out[#out + 1] = l end end
	return out
end

-- a refusal is logged as numbered lines with the log point's prefix; the counter goes up per refusal
f = fakePort()
f.account = { "path 2 pieces", "road 9 crossed at (1, 2, 3): not cut: too shallow" }
G, logs = settledGhost(f)
P.onData(G, P.viewKey(G), chk({ cost = 40, critical = true, messages = { "Too steep" }, collides = { 7 },
	lines = { "messages: Too steep", "collision street 7 at (1.0, 2.0); nearest piece 3, 4.5 m" } }))
local ls = refusalLines(logs)
check(#ls == 5 and ls[1] == "refusal#1 ghost: cost 40; critical true" and ls[2] == "refusal#1 ghost: messages: Too steep"
	and ls[3] == "refusal#1 ghost: collision street 7 at (1.0, 2.0); nearest piece 3, 4.5 m"
	and ls[4] == "refusal#1 ghost: path 2 pieces" and ls[5]:find("^refusal#1 ghost: road 9 crossed"),
	"refusal: numbered lines with the log point's prefix, then our own account (" .. #ls .. " lines)")
P.tick(G, { key = "s2", a = A, b = B, settled = true })
P.onData(G, P.viewKey(G), chk({ critical = true, messages = { "Too steep" }, lines = { "messages: Too steep" } }))
ls = refusalLines(logs)
local second = false
for _, l in ipairs(ls) do second = second or l == "refusal#2 ghost: cost 100; critical true" end
check(second,
	"refusal: the counter goes up per refusal")

-- the detail is logged once per view
f = fakePort()
G, logs = settledGhost(f)
local vk = P.viewKey(G)
P.onData(G, vk, chk({ critical = true, messages = { "Too steep" }, lines = { "messages: Too steep" } }))
P.onData(G, vk, chk({ critical = true, messages = { "Too steep" }, lines = { "messages: Too steep" } }))
check(#refusalLines(logs) == 2, "refusal: the same view logs its detail once (" .. #refusalLines(logs) .. " lines)")

-- errors that are not critical, and warnings, get the full detail
f = fakePort()
G, logs = settledGhost(f)
P.onData(G, P.viewKey(G), chk({ messages = { "Too steep" }, lines = { "messages: Too steep" } }))
check(#refusalLines(logs) == 2 and refusalLines(logs)[1] == "refusal#1 ghost: cost 100; critical false", "refusal: errors that are not critical get the detail")
f = fakePort()
G, logs = settledGhost(f)
P.onData(G, P.viewKey(G), chk({ warnings = { "Buildings" }, lines = { "warnings: Buildings" } }))
check(#refusalLines(logs) == 2, "refusal: warnings get the detail")

-- houses only, and a clean ghost, keep the short line
f = fakePort()
G, logs = settledGhost(f)
P.onData(G, P.viewKey(G), chk({ messages = { "Collision" }, collides = { 1011 }, lines = { "collision" } }))
check(#refusalLines(logs) == 0 and logs[#logs] == "ghost: The town buildings in the way will go.", "refusal: houses only keep the short line")
f = fakePort()
G, logs = settledGhost(f)
P.onData(G, P.viewKey(G), chk())
check(#logs == 0 or #refusalLines(logs) == 0, "refusal: a clean ghost logs no refusal")

-- a bare refusal is tagged; one that names anything is not
f = fakePort()
G, logs = settledGhost(f)
P.onData(G, P.viewKey(G), chk({ critical = true, messages = { "Construction Not Possible" }, lines = { "messages: Construction Not Possible" } }))
check(refusalLines(logs)[1] == "refusal#1 ghost: cost 100; critical true; bare", "refusal: a bare refusal says so: " .. tostring(refusalLines(logs)[1]))
f = fakePort()
G, logs = settledGhost(f)
P.onData(G, P.viewKey(G), chk({ critical = true, messages = { "Construction Not Possible" }, collides = { 7 }, lines = { "messages: x", "collision" } }))
check(not refusalLines(logs)[1]:find("bare"), "refusal: one that names a collision is not bare")

-- the other log points
f = fakePort()
f.dry = function() return chk({ critical = true, messages = { "Too steep" }, lines = { "messages: Too steep" } }) end
G, logs = settledGhost(f)
P.onData(G, P.viewKey(G), chk({ cost = 100 }))
P.tick(G, { key = "s", a = A, b = B, settled = true })
local sawBuild = false
for _, l in ipairs(refusalLines(logs)) do sawBuild = sawBuild or l:find("^refusal#1 build check") ~= nil end
check(sawBuild, "refusal: the build check logs its detail")
P.logRefusal(G, "build", chk({ critical = true, lines = { "x" } }))
check(refusalLines(logs)[#refusalLines(logs) - 1]:find("^refusal#2 build:"), "refusal: the adapter logs a failed build through the module")

-- no line is long, and a flood is cut
f = fakePort()
G, logs = settledGhost(f)
local flood = { string.rep("x", 500) }
for i = 1, 200 do flood[#flood + 1] = "entity " .. i end
P.onData(G, P.viewKey(G), chk({ critical = true, messages = { "a" }, lines = flood }))
local longest = 0
for _, l in ipairs(refusalLines(logs)) do longest = math.max(longest, #l) end
check(longest <= 280 and #refusalLines(logs) < 100, "refusal: lines stay under 300 characters, and a flood is cut (" .. longest .. ", " .. #refusalLines(logs) .. ")")

------------------------------------------------------------------ toClear and allHouses

local houseOf = { [301] = 801, [302] = 802, [303] = 802 } -- town building -> its construction
local data = chk({ collides = { 301, 400, 302, -3 }, buildings = { 303, 301, 500 } })
local cons = P.toClear(data, function(e) return houseOf[e] end)
table.sort(cons)
check(#cons == 2 and cons[1] == 801 and cons[2] == 802, "toClear: the houses' constructions, each once")
check(#P.toClear(nil, function() return 1 end) == 0, "toClear: no check, nothing to clear")
check(#P.toClear(chk({ collides = { 400 } }), function() return nil end) == 0, "toClear: an industry in the way is not cleared")
local more, new = P.toClear(chk({ collides = { 302, 304 } }), function(e) return ({ [302] = 802, [304] = 804 })[e] end, { 801, 802 })
table.sort(more)
check(new == 1 and #more == 3 and more[1] == 801 and more[2] == 802 and more[3] == 804,
	"toClear: houses a later check lists join those already cleared")
local _, none = P.toClear(chk({ collides = { 301 } }), function(e) return houseOf[e] end, { 801 })
check(none == 0, "toClear: nothing new when the check lists only houses already cleared")
local _, _, others = P.toClear(data, function(e) return houseOf[e] end, nil)
check(others == 1, "toClear: the industry is the one other thing in the way (the new piece -3, and the buildings named, not counted)")
local _, _, onlyHouses = P.toClear(chk({ collides = { 301, 301 } }), function(e) return houseOf[e] end, nil)
check(onlyHouses == 0, "toClear: nothing else in the way when only houses are")

-- every house in the way, by checks that each name at most two of those still there
local function reveal(houses)
	local runs = 0
	return function(removing)
		runs = runs + 1
		local gone, cols = {}, {}
		for _, c in ipairs(removing or {}) do gone[c] = true end
		for _, c in ipairs(houses) do if not gone[c] and #cols < 2 then cols[#cols + 1] = c + 1000 end end
		cols[#cols + 1] = 7 -- (a road: stays in the way)
		return chk({ collides = cols })
	end, function() return runs end
end
local function sorted(t) table.sort(t) return t end
local houseCon = function(e) if e > 1000 then return e - 1000 end end
local chkH, runsN = reveal({ 11, 12, 13, 14, 15 })
local all = sorted(P.allHouses(chkH, houseCon, 8))
check(#all == 5 and all[1] == 11 and all[5] == 15 and runsN() == 4, "allHouses: every house, two a check, until a check names none new (" .. runsN() .. " checks)")
local noneIn, runs0 = reveal({})
check(#P.allHouses(noneIn, houseCon, 8) == 0 and runs0() == 1, "allHouses: none in the way: one check")
local many, runsM = reveal({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 })
check(#P.allHouses(many, houseCon, 3) == 6 and runsM() == 3, "allHouses: at most so many checks")
check(#P.allHouses(function() return nil end, houseCon, 8) == 0, "allHouses: no check from the game: none")

------------------------------------------------------------------ the search for a bare refusal's section

local function bare() return chk({ critical = true, messages = { "Construction Not Possible" } }) end

-- a settled ghost of m pieces whose build check refuses bare; the section j..k refuses bare when
-- refuses(j, k). Returns the ghost's state, its log and the fake.
local function bareGhost(m, refuses)
	local f = fakePort()
	f.pieces = m
	f.dry = function() return bare() end
	f.sectionDry = function(j, k) if refuses(j, k) then return bare() else return chk() end end
	local G, logs = settledGhost(f)
	P.onData(G, P.viewKey(G), chk())
	P.tick(G, { key = "s", a = A, b = B, settled = true })
	return G, logs, f
end
local function has(t, j, k) return j <= t and t <= k end
local function logged(logs, text)
	for _, l in ipairs(logs) do if l:find(text, 1, true) then return true end end
	return false
end

-- one bad piece: the search reports that piece alone
G, logs, f = bareGhost(8, function(j, k) return has(5, j, k) end)
check(G.ghost.offending ~= nil and G.ghost.offending.first == 5 and G.ghost.offending.last == 5, "search: one bad piece: reported alone")
check(logged(logs, "search: offending section 5..5"), "search: the section is in the log")
check(logged(logs, "search: piece 5: 10.0 m at (5.0, 0.0)"), "search: each piece is in the log, with its index, length and position")
check(logged(logs, "refusal#2 search: "), "search: its lines are numbered like the refusals' (a number after the build check's)")

-- two pieces that refuse only together: the section between them
G, logs, f = bareGhost(8, function(j, k) return has(3, j, k) and has(6, j, k) end)
check(G.ghost.offending ~= nil and G.ghost.offending.first == 3 and G.ghost.offending.last == 6, "search: two pieces that refuse together: the section between them")
check(logged(logs, "piece 3:") and logged(logs, "piece 6:") and not logged(logs, "piece 2:") and not logged(logs, "piece 7:"), "search: the log has the section's pieces only")

-- the whole path is one bad piece, and the first piece is
G = bareGhost(8, function(j, k) return has(8, j, k) end)
check(G.ghost.offending.first == 8 and G.ghost.offending.last == 8, "search: the last piece is at fault")
G = bareGhost(8, function(j, k) return has(1, j, k) end)
check(G.ghost.offending.first == 1 and G.ghost.offending.last == 1, "search: the first piece is at fault")
G, logs, f = bareGhost(1, function() return true end)
check(G.ghost.offending.first == 1 and G.ghost.offending.last == 1 and f.sections == 0, "search: a path of one piece needs no dry run")

-- about log2 n dry runs, not n
G, logs, f = bareGhost(64, function(j, k) return has(37, j, k) end)
check(G.ghost.offending.first == 37 and G.ghost.offending.last == 37, "search: 64 pieces, the bad one found")
check(f.sections <= 14 and f.sections == f.runs - 1, "search: about log2 n dry runs (" .. f.sections .. " of 64)")

-- a refusal that is not bare stops the search, with that dry run's detail in the log
f = fakePort()
f.dry = function() return bare() end
f.sectionDry = function(j, k)
	if has(5, j, k) and k >= 5 then return chk({ critical = true, messages = { "Too steep" }, lines = { "messages: Too steep" } }) end
	return chk()
end
G, logs = settledGhost(f)
P.onData(G, P.viewKey(G), chk())
P.tick(G, { key = "s", a = A, b = B, settled = true })
check(G.ghost.offending == nil and logged(logs, "inconclusive at"), "search: a refusal that names something: inconclusive, nothing highlighted")
check(logged(logs, "search: messages: Too steep"), "search: ...with that dry run's detail")
check(not logged(logs, "search: offending"), "search: ...and no section")

-- a build check that refuses, but not bare, starts no search
f = fakePort()
f.dry = function() return chk({ critical = true, messages = { "Too steep" } }) end
G = settledGhost(f)
P.onData(G, P.viewKey(G), chk())
P.tick(G, { key = "s", a = A, b = B, settled = true })
check(f.sections == 0 and G.ghost.offending == nil, "search: a refusal that is not bare starts none")
f = fakePort()
G = settledGhost(f)
P.onData(G, P.viewKey(G), chk())
P.tick(G, { key = "s", a = A, b = B, settled = true })
check(f.sections == 0, "search: a build check that passes starts none")

-- a prefix refuses that the next one does not: not monotone, and the prefixes are walked one at a time
G, logs, f = bareGhost(8, function(j, k) return (j == 1 and k == 4) or (j <= 7 and k >= 7) end)
check(logged(logs, "not monotone"), "search: a prefix that passes after one that refused is logged: not monotone")
check(G.ghost.offending ~= nil and G.ghost.offending.first == 1 and G.ghost.offending.last == 4, "search: the walk gives the first prefix that refuses, narrowed")

-- a monotone fake does not say so
G, logs = bareGhost(8, function(j, k) return has(5, j, k) end)
check(not logged(logs, "not monotone"), "search: a monotone fake is not logged as not monotone")

-- once per ghost key, however many times it is built-checked
G, logs, f = bareGhost(8, function(j, k) return has(5, j, k) end)
local sections = f.sections
G.ghost.built = nil
P.gate(G, A, B)
G.ghost.built = nil
P.gate(G, A, B)
check(sections > 0 and f.sections == sections, "search: once per ghost key, even with more build checks (" .. sections .. ", " .. f.sections .. ")")
local searches = 0
for _, l in ipairs(logs) do if l:find("search: offending", 1, true) then searches = searches + 1 end end
check(searches == 1, "search: its result is logged once")
P.tick(G, { key = "s2", a = A, b = B, settled = true })
check(G.ghost.offending == nil, "search: a new key forgets the section")

H.done()
