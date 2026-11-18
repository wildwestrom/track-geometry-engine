-- The ghost: the proposal the tool shows under the edit, which is also what it builds. This owns
-- its lifecycle: when it is made again, what the game's check of it says, the rounds that clear
-- the town buildings in its way, and the build gate. The GUI is its adapter: it passes in what the
-- session says each tick, hands over the viewer's checks, and gives the game's side as a Port. It
-- reads the state's fields freely, but only these calls change them. No game API here (nor
-- tg_session), so test/proposal_test.lua runs it outside the game.
--
-- While the mouse moves the path the ghost is only a sketch (no proposal, only the path as a
-- line): the game's check and drawing of each new ghost hold up a frame for 90-160 ms (NOTES.md).

local ends = require("track_geometry_tool::/track_geometry/tg_ends.script.tl")

-- Remake a settled ghost at most this many times to clear the town buildings in its way.
local CLEAR_ROUNDS = 8
-- Dry runs at most to find the town buildings in a settled ghost's way.
local CLEAR_CHECKS = 12
-- A refusal's log lines are cut to this many bytes (tflog cuts a line at 300), and a refusal to
-- this many lines.
local LINE_BYTES = 280
local REFUSAL_LINES = 60
-- Picking the end: the path is a sketch until the mouse has rested this long (ms)...
local SKETCH_REST_MS = 300.0
-- ...or this many ticks, without a clock.
local SKETCH_REST_TICKS = 6

-- What the game's check of a proposal says (the adapter boils its ProposalData down to this).
local record Hits
	collides : {integer} -- the entities it runs into
	buildings : {integer} -- the entities it names as buildings
end

local record Check
	cost : integer
	critical : boolean -- the game refuses it
	messages : {string} -- its errors; nil: the game gave no error state
	warnings : {string}
	hits : Hits
	-- everything the game said besides the cost and critical, a line for each non-empty message
	-- list and for each entity it names, with where it is (only called to log a refusal)
	detail : function() : {string}
end

-- A ghost as the port makes it.
local record Made
	proposal : SimpleProposal -- nil: no ghost (a sketch, no path, or why)
	info : string -- its path: length and layout
	why : string -- why there is no ghost
	crossed : {integer} -- the street and track pieces it cuts for its level and diamond crossings
	cleared : {integer} -- the town buildings' constructions it removes from the start (its footprint)
	account : {string} -- our own account of the track (its path, the roads it crosses and why not), logged with a refusal
end

-- The game's side.
local record Port
	-- the ghost (or the sketch) of the path from a to b; never fails (the adapter catches)
	make : function(a : ends.End, b : ends.End, sketch : boolean) : Made
	-- the game's check of what is built for the proposal, removing `removing` itself, the game
	-- gathering the town buildings in the way when `gather`; nil and why when there is none
	dryRun : function(proposal : SimpleProposal, removing : {integer}, gather : boolean) : Check, string
	-- the proposal removes the constructions in list itself; false and why when it cannot
	setCleared : function(proposal : SimpleProposal, list : {integer}) : boolean, string
	constructionOf : function(entity : integer) : integer -- a town building's construction; nil for anything else
	allExist : function(list : {integer}) : boolean
	joinable : function(e : ends.End) : boolean -- the end is still there as picked
	balance : function() : integer -- nil when it can't be read
	now : function() : number -- ms; nil without a clock
end

-- What is built for a settled ghost, as the game checks it: the ghost's track without the town
-- buildings it clears itself (the game gathers them), and one dry run of it.
local record Built
	check : Check -- nil when the game could not check it
	refused : string -- why the game will not build it; nil when it will
end

-- The ghost: made anew whenever its key changes.
local record Ghost
	key : string
	sketch : boolean -- no proposal, only the path as a line, while the mouse moves it: never built
	proposal : SimpleProposal
	info : string
	why : string
	cost : integer
	errors : string -- what is wrong with it, for the tooltip (problems)
	critical : boolean -- the game refuses it
	hasErrors : boolean -- the game reports errors on it (warnings do not count)
	collides : boolean -- its check lists collisions (other than town buildings it is yet to clear)
	housesOnly : boolean -- all its check runs into is town buildings it is yet to clear: no fault
	houses : {integer} -- what its last check says to clear: those it clears and those the check ran into
	newHouses : integer -- how many of those the check added
	found : boolean -- the search for the town buildings in its way is done (once it has settled)
	crossed : {integer}
	cleared : {integer} -- the town buildings' constructions it removes; nil: none yet
	account : {string}
	round : integer -- bumped each time it is made again in place (more houses cleared): a new view, a new check
	dataKey : string -- set to its view key when its check has come
	logged : boolean -- its problems are logged
	refusalLogged : boolean -- the game's refusal of it is logged
	searchRefusalLogged : boolean -- a refusal in its house search is logged (this round)
	roundsLogged : boolean -- running out of clearing rounds is logged
	built : Built -- checked once it has settled for good (this round)
end

local record State
	ghost : Ghost -- never nil ({} before the first, or when dropped)
	port : Port
	say : function(string)
	refusals : integer -- refusals logged so far (their numbers)
	ticks : integer
	dragging : boolean -- as of the last tick
	movedKey : string -- the last key seen, and when it changed (the mouse moved the path)
	movedMs : number
	movedTick : integer
end

-- What the session says each tick.
local record Tick
	key : string -- what the ghost is made from
	a : ends.End
	b : ends.End
	settled : boolean -- both ends picked: editing
	dragging : boolean -- a drag is on
	toPhase : boolean -- picking the end
end

-- What the confirm window offers to build.
local record Offer
	proposal : SimpleProposal -- the ghost's (what is built is the same, gathering the houses)
	info : string
	cost : integer
	problems : string
end

local record ProposalMod
	Check : Check
	Hits : Hits
	Made : Made
	Port : Port
	Ghost : Ghost
	State : State
	Tick : Tick
	Offer : Offer
	CLEAR_ROUNDS : integer
	new : function(say : function(string), port : Port) : State
	tick : function(G : State, t : Tick)
	viewKey : function(G : State) : string
	onData : function(G : State, viewKey : string, check : Check) : boolean
	logRefusal : function(G : State, point : string, check : Check, note ?: string, account ?: {string})
	gate : function(G : State, a : ends.End, b : ends.End) : string, Offer
	problems : function(check : Check, houses ?: boolean) : string
	toClear : function(check : Check, constructionOf : function(integer) : integer, cleared : {integer}) : {integer}, integer, integer
	allHouses : function(check : function({integer}) : Check, constructionOf : function(integer) : integer, maxChecks : integer) : {integer}, integer
end

local M : ProposalMod = { CLEAR_ROUNDS = CLEAR_ROUNDS }

function M.new(say : function(string), port : Port) : State
	return { ghost = {}, port = port, say = say, refusals = 0, ticks = 0 }
end

-- Does the game's check report something worth the full detail in the log? Not when all it runs
-- into is town buildings that go (housesOnly).
local function reports(check : Check, housesOnly : boolean) : boolean
	if housesOnly then return false end
	return check.critical == true or #(check.messages or {}) > 0 or #(check.warnings or {}) > 0
		or (check.hits ~= nil and #(check.hits.collides or {}) > 0)
end

-- The game's refusal of a proposal, in the log, as lines that all start `refusal#<n> <point>:`
-- (tflog 'refusal#' shows all of it): the cost and critical (and `bare` when the game names
-- nothing), what the game said (check.detail), then our own account of the track (the ghost's
-- unless given). note: more for the header.
function M.logRefusal(G : State, point : string, check : Check, note ?: string, account ?: {string})
	G.refusals = (G.refusals or 0) + 1
	local prefix = string.format("refusal#%d %s: ", G.refusals, point)
	local ok, d = pcall(function() : {string} return check.detail ~= nil and check.detail() or {} end)
	local detail : {string} = ok and d or { "detail failed: " .. tostring(d) }
	local msgs = #(check.messages or {})
	local named = check.hits ~= nil and (#(check.hits.collides or {}) > 0 or #(check.hits.buildings or {}) > 0)
	-- bare: refused as "Construction Not Possible" and nothing else named (the text or its key)
	local only = msgs == 1 and (check.messages[1]:lower():gsub("[^%w]", "")) == "constructionnotpossible"
	local bare = check.critical == true and not named and (msgs == 0 or only) and #(check.warnings or {}) == 0 and #detail <= msgs
	local lines : {string} = { string.format("cost %s; critical %s%s%s", tostring(check.cost), tostring(check.critical == true), bare and "; bare" or "", note ~= nil and ("; " .. note) or "") }
	for _, l in ipairs(detail) do lines[#lines + 1] = l end
	for _, l in ipairs(account or G.ghost.account or {}) do lines[#lines + 1] = l end
	for i, l in ipairs(lines) do
		if i > REFUSAL_LINES then
			G.say(prefix .. string.format("... %d more lines", #lines - REFUSAL_LINES + 1))
			break
		end
		G.say((prefix .. l):sub(1, LINE_BYTES))
	end
end

-- The ghost's view as the game sees it: its key, and the round it is in (each round is a new
-- ProposalViewer and a new check); its kind too: a sketch and the ghost of one key are each a new view.
function M.viewKey(G : State) : string
	local g = G.ghost
	return tostring(g.key) .. "#" .. tostring(g.round or 0) .. (g.sketch and "s" or "")
end

-- The constructions to remove so the proposal can run through the town buildings in its way, how
-- many of them are new, and how many other things it runs into: those already `cleared`, then each
-- further house's, once, from a check's collisions and the buildings it names. A check lists only
-- some of the houses in the way, and the next check of the proposal with those cleared lists more
-- (NOTES.md, Town buildings in the way), so this is asked again after each check. constructionOf
-- gives a town building's construction and nil for anything else, which stays in the way: only
-- what the game's own builder removes goes (fields it removes itself, with Context.gatherFields).
-- The others are counted among the collisions only.
function M.toClear(check : Check, constructionOf : function(integer) : integer, cleared : {integer}) : {integer}, integer, integer
	local out, seen, new, others = {} as {integer}, {} as {integer : boolean}, 0, 0
	local other : {integer : boolean} = {}
	for _, con in ipairs(cleared or {}) do
		if not seen[con] then seen[con], out[#out + 1] = true, con end
	end
	local hits = check ~= nil and check.hits or nil
	if hits == nil then return out, 0, 0 end
	local function add(e : integer)
		if e == nil or e < 0 then return end
		local con = constructionOf(e)
		if con == nil then
			if not other[e] then other[e], others = true, others + 1 end
		elseif not seen[con] then seen[con], out[#out + 1], new = true, con, new + 1 end
	end
	for _, e in ipairs(hits.collides or {}) do add(e) end
	local collided = others
	for _, e in ipairs(hits.buildings or {}) do add(e) end
	return out, new, collided
end

-- What the game says is wrong with a proposal: its errors and warnings, and what it runs into.
-- nil when nothing is. houses: it runs into town buildings and nothing else, and they go once it
-- settles, so its collision is no fault: a line saying they go stands in for the game's lone error
-- (Collision) and what it runs into. (No count: a check names only some.)
function M.problems(check : Check, houses ?: boolean) : string
	local lines : {string} = {}
	local msgs = check.messages
	local housesOnly = houses == true and msgs ~= nil and not check.critical and #msgs <= 1
	if housesOnly then lines[#lines + 1] = "The town buildings in the way will go." end
	if msgs ~= nil then
		local text = housesOnly and "" or table.concat(msgs, ", ")
		if text ~= "" then lines[#lines + 1] = (check.critical and "The game refuses it: " or "Errors: ") .. text
		elseif check.critical then lines[#lines + 1] = "The game refuses it." end
		local warns = table.concat(check.warnings or {}, ", ")
		if warns ~= "" then lines[#lines + 1] = "Warnings: " .. warns end
	end
	local cols = check.hits ~= nil and #(check.hits.collides or {}) or 0
	if cols > 0 and not housesOnly then lines[#lines + 1] = string.format("Runs into %d thing%s.", cols, cols > 1 and "s" or "") end
	if #lines == 0 then return nil end
	return table.concat(lines, "\n")
end

-- The constructions of every town building in the proposal's way, and how many checks found them.
-- check(A) is the game's check of the proposal removing A itself (a dry run without
-- Context.gatherBuildings, nil if there is none), which names only some of the houses still in the
-- way (NOTES.md), so it is asked again with those removed too, until it names none new, at most
-- maxChecks times. constructionOf as in toClear.
function M.allHouses(check : function({integer}) : Check, constructionOf : function(integer) : integer, maxChecks : integer) : {integer}, integer
	local found : {integer} = {}
	local checks = 0
	while checks < maxChecks do
		checks = checks + 1
		local data = check(found)
		if data == nil then break end
		local more, new = M.toClear(data, constructionOf, found)
		if new == 0 then break end
		found = more
	end
	return found, checks
end

-- The ghost's check from the viewer, for view viewKey (taken: true; a check of an older view is
-- ignored).
function M.onData(G : State, viewKey : string, check : Check) : boolean
	local g = G.ghost
	if check == nil or g.key == nil or M.viewKey(G) ~= viewKey then return false end
	g.cost = check.cost
	local others : integer
	g.houses, g.newHouses, others = M.toClear(check, G.port.constructionOf, g.cleared)
	-- (only houses in the way, and rounds left to clear them: no fault)
	g.housesOnly = others == 0 and g.newHouses > 0 and (g.round or 0) < CLEAR_ROUNDS
	g.collides = not g.housesOnly and #(check.hits ~= nil and check.hits.collides or {}) > 0
	g.errors = M.problems(check, g.housesOnly)
	g.critical = check.critical == true
	g.hasErrors = #(check.messages or {}) > 0
	g.dataKey = viewKey
	-- every refusal, mid-drag too, once per view
	if reports(check, g.housesOnly) and not g.refusalLogged then
		g.refusalLogged = true
		M.logRefusal(G, "ghost" .. (G.dragging and " mid-drag" or ""), check)
	end
	if g.errors ~= nil and not G.dragging and not g.logged then
		g.logged = true
		G.say("ghost: " .. g.errors:gsub("\n", "; "))
	end
	return true
end

-- Make the ghost of key again, from scratch.
local function make(G : State, key : string, a : ends.End, b : ends.End, sketch : boolean)
	local m = G.port.make(a, b, sketch) or {}
	G.ghost = { key = key, sketch = sketch or nil, proposal = m.proposal, info = m.info, why = m.why,
		crossed = m.crossed, cleared = m.cleared, account = m.account }
end

-- The ghost was made again in place: a new round, so a new view, and its check is to come.
local function recheck(g : Ghost)
	g.round = (g.round or 0) + 1
	g.cost, g.errors, g.critical, g.hasErrors, g.collides, g.housesOnly, g.dataKey, g.logged, g.refusalLogged, g.searchRefusalLogged = nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
	g.houses, g.newHouses, g.built = nil, nil, nil
end

-- The ghost removes the constructions in list itself from now on; false when it cannot (logged).
local function setCleared(G : State, list : {integer}) : boolean
	local ok, done, why = pcall(G.port.setCleared, G.ghost.proposal, list)
	if ok and done then
		G.ghost.cleared = list
		return true
	end
	G.say("ghost: cannot clear the buildings: " .. tostring(ok and why or done))
	return false
end

-- What is built for the ghost, checked by the game (one dry run, the game gathering the town
-- buildings in the way): its warning (the buildings it knocks down) and its cost are the game's
-- own, unlike the ghost's check (NOTES.md).
local function checkBuilt(G : State) : Built
	local ok, c, why = pcall(G.port.dryRun, G.ghost.proposal, nil, true)
	if not ok then c, why = nil, "the game could not check it (" .. tostring(c) .. ")" end
	local b : Built = { check = c }
	if c == nil then b.refused = why or "the game could not check it"
	elseif c.critical or #(c.messages or {}) > 0 then b.refused = "the game refuses it"
	elseif #(c.hits ~= nil and c.hits.collides or {}) > 0 then b.refused = "it still runs into something" end
	if b.refused ~= nil then
		if c ~= nil then M.logRefusal(G, "build check", c, b.refused) else G.say("build check: refused: " .. b.refused) end
	end
	return b
end

-- The game's check of the ghost removing `cleared` itself, nil if there is none.
local function checkRemoving(G : State, cleared : {integer}) : Check
	local g = G.ghost
	local ok, c, why = pcall(G.port.dryRun, g.proposal, cleared, false)
	if not ok or c == nil then
		G.say("ghost: finding the town buildings: " .. tostring(ok and why or c))
		return nil
	end
	if reports(c, false) and not g.searchRefusalLogged then
		g.searchRefusalLogged = true
		M.logRefusal(G, "house search", c, string.format("removing %d constructions", #cleared))
	end
	return c
end

-- Find every town building in the settled ghost's way with the game's own checks (dry runs without
-- gathering, each naming only some: allHouses) and clear just those, so that the ghost shows as
-- going exactly what the game knocks down (the lookup on the map takes in a few more: boxes cover
-- whole lots). All its dry runs at once, in the tick its own check came: each blocks the frame,
-- and coroutines would not help (they share the game's thread, NOTES.md).
local function findHouses(G : State)
	local g = G.ghost
	local ok, h, n = pcall(M.allHouses, function(cleared : {integer}) : Check
		return checkRemoving(G, cleared)
	end, G.port.constructionOf, CLEAR_CHECKS)
	if not ok then
		G.say("ghost: finding the town buildings: " .. tostring(h))
		h, n = {}, 0
	end
	local houses, checks = h as {integer}, n as integer
	g.found = true
	G.say(string.format("ghost: %d town building%s in the way (%d checks; %d on its footprint)", #houses, #houses == 1 and "" or "s", checks, g.cleared ~= nil and #g.cleared or 0))
	if setCleared(G, houses) then recheck(g) end
end

-- Is a street piece the ghost cuts for a level crossing gone (a town rebuilds its roads)? Naming
-- a gone piece may kill the game, as a gone node does.
local function crossedGone(G : State) : boolean
	local c = G.ghost.crossed
	return c ~= nil and #c > 0 and not G.port.allExist(c)
end

-- Is a town building the ghost knocks down gone (the town rebuilt it)?
local function clearedGone(G : State) : boolean
	local c = G.ghost.cleared
	return c ~= nil and not G.port.allExist(c)
end

-- Town buildings in the way go, as with the game's own builder. The ghost (a ProposalViewer)
-- takes no Context, so its check lists them as collisions and leaves their demolition out of the
-- cost; once it settles (no drag, the ends picked) and its check has come, the ghost is made again
-- with their constructions in its own constructionsToRemove, so that the ghost, the build gate,
-- the cost and the build all see the same proposal. A check lists only some of the houses in the
-- way, so this repeats after each check while it lists new ones (at most CLEAR_ROUNDS times).
-- If a building it clears or a street it crosses is gone, the ghost is made anew from scratch.
local function clearHouses(G : State, t : Tick)
	local g = G.ghost
	if g.proposal == nil or g.key == nil then return end
	if clearedGone(G) then
		G.say("ghost: a building it clears is gone: making it anew")
		G.ghost = {}
		return
	end
	if crossedGone(G) then
		G.say("ghost: a road or track it crosses has changed: making it anew")
		G.ghost = {}
		return
	end
	if not t.settled or t.dragging or g.sketch then return end
	-- (settled: its own check has come; no dry run before, as each blocks a frame)
	if g.dataKey ~= M.viewKey(G) then return end
	if not g.found then
		-- (no town buildings in the way by its own check: nothing to search for; the clearing
		-- rounds below take the same for done)
		if (g.newHouses or 0) > 0 then findHouses(G) return end
		g.found = true
	end
	if (g.newHouses or 0) == 0 or (g.round or 0) >= CLEAR_ROUNDS then
		if (g.newHouses or 0) > 0 and not g.roundsLogged then
			g.roundsLogged = true
			G.say("ghost: still more town buildings in the way after " .. CLEAR_ROUNDS .. " rounds")
		end
		-- settled for good: what is built, checked once (its warning and cost are shown)
		if g.built == nil then g.built = checkBuilt(G) end
		return
	end
	if not setCleared(G, g.houses) then g.cleared = {}; return end
	G.say(string.format("ghost: clearing %d more town building%s in the way (%d in all)", g.newHouses, g.newHouses > 1 and "s" or "", #g.cleared))
	recheck(g)
end

-- The one build gate: why the ghost cannot be built now (from a to b, the picked ends), or what
-- to offer. Asked when the confirm window would open, and again by its Build click: that builds
-- only the same offer's proposal.
function M.gate(G : State, a : ends.End, b : ends.End) : string, Offer
	local g = G.ghost
	if g.proposal == nil then return g.why or "there is no path" end
	if g.sketch or g.dataKey ~= M.viewKey(G) or g.cost == nil or not g.found then return "the game is still checking it" end
	if clearedGone(G) then return "a building in the way has changed" end
	if crossedGone(G) then return "a road or track it crosses has changed" end
	if g.critical then return "the game refuses it" end
	if g.housesOnly then return "the town buildings in the way are still being cleared" end
	if g.hasErrors then return "the game reports errors on it" end
	if not (G.port.joinable(a) and G.port.joinable(b)) then return "an end is gone or its track has changed" end
	-- (the game itself lets the account go negative: an unknown balance passes; the ghost's cost
	-- first, which needs no dry run)
	local bal = G.port.balance()
	if bal ~= nil and g.cost > bal then return "not enough money" end
	-- what is built is the ghost's track without the town buildings it clears itself, the game
	-- gathering them (checked when the ghost settled for good, else now)
	if g.built == nil then g.built = checkBuilt(G) end
	local bt = g.built
	if bt.refused ~= nil then return bt.refused end
	if bal ~= nil and bt.check.cost > bal then return "not enough money" end
	return nil, { proposal = g.proposal, info = g.info, cost = bt.check.cost, problems = M.problems(bt.check) }
end

-- Every tick: make the ghost again, in one go, when what it shows has changed. While the mouse
-- moves the path it is only a sketch: a drag's until it is let go, even when it pauses; picking the
-- end, until the mouse has rested on it SKETCH_REST_MS (SKETCH_REST_TICKS without a clock).
function M.tick(G : State, t : Tick)
	G.ticks = G.ticks + 1
	G.dragging = t.dragging == true
	local now = G.port.now()
	if t.key ~= G.movedKey then G.movedKey, G.movedMs, G.movedTick = t.key, now, G.ticks end
	local moving : boolean
	if now ~= nil and G.movedMs ~= nil then moving = now - G.movedMs < SKETCH_REST_MS
	else moving = G.ticks - G.movedTick < SKETCH_REST_TICKS end
	local sketch = G.dragging or (t.toPhase == true and moving)
	-- (made again though nothing moved since: a sketch once the mouse rests or the drag ends; not a
	-- ghost into a sketch, as a press that grabs and lets go without moving would)
	local g = G.ghost
	if t.key ~= g.key or (g.sketch and not sketch) then make(G, t.key, t.a, t.b, sketch) end
	clearHouses(G, t)
end

return M
