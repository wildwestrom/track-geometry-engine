-- Timing for the GUI (tg_gui): a wall clock, the "perf:" line's sums, and the job that makes the
-- ghost in slices across frames.
--
-- The ghost is made by a job that gives the frame back every SLICE_MS (a coroutine resumed every
-- frame): on a long track its plan, map lookups and proposal take tens of ms, and in one go they
-- held up the frame they ran in (the mouse, the camera). Only when the game's Lua can yield inside
-- a pcall (the plan reads the ground under one): else each is made in one go (canSlice).

-- What the tool's work costs, summed since the last "perf:" line (ms; nil without a clock).
local record Perf
	since : number -- when these sums began
	frames : integer
	worstFrame : number -- the longest frame
	ghosts : integer -- ghosts made
	ghostMs : number -- time spent making them (the plan, the map lookups, the proposal)
	mapMs : number -- of which the map lookups (houses and streets)
	makeMs : number -- and the proposal (with the search for level crossings)
	stages : {string : number} -- the proposal's stages (lap), by name: their time
	stageWorst : {string : number} -- ...and each one's longest
	planMs : number -- and the plan (with the ground and water under it)
	pieces : integer -- the pieces in the ghosts made
	partials : integer -- ghosts of only the stretch a drag changes
	sketches : integer -- ...and of the path only as a line (no proposal)
	ticks : integer -- the tool's ticks (every 50 ms), and their time, ghosts left out
	tickMs : number
	slowWaiting : integer -- frames over SLOW_FRAME ms while a ghost waited for the game's check
	slowOther : integer -- ...and at other times
	dryRuns : integer -- the game's dry runs of a settled ghost (house search, build check), and their time
	dryMs : number
	worstDry : number
	worstSlice : number -- the longest slice of a ghost's making (what it held one frame up)
	worstGhost : number
	renders : integer -- the tool drawn again
	renderMs : number
	gizmoBuilds : integer -- gizmo edges made anew (else reused)
	badgeMs : number -- placing the badges, every frame
end

local record TimingMod
	Perf : Perf
	SLOW_FRAME : number
	PERF_EVERY : number
	SLICE_MS : number
	perf : Perf
	now : function() : number
	resetPerf : function(since : number)
	-- the job
	canSlice : function() : boolean
	start : function(fn : function())
	step : function() : boolean, string
	busy : function() : boolean
	drop : function()
	gen : function() : integer
	slice : function()
	probed : function()
	paused : function() : number
	worked : function(t0 : number, p0 : number) : number
	lapStart : function()
	lap : function(name : string)
	stagesText : function(ghosts : integer) : string
end

local M : TimingMod = {}

M.SLOW_FRAME = 50.0 -- a frame this long (ms) is a stall, for the "perf:" line
M.PERF_EVERY = 5000.0 -- a "perf:" line at most this often (ms), while the tool makes ghosts or draws
M.SLICE_MS = 4.0 -- a slice of the job's work at most this long (ms), then the frame goes on

------------------------------------------------------------------ the clock

-- Wall-clock time (ms), from the game's api.type.Clock (microseconds since it was made; os.clock()
-- is CPU time summed over threads, NOTES.md); nil when there is no such clock. Made at first use.
local clock : Clock = nil
local noClock = false
function M.now() : number
	if noClock then return nil end
	if clock == nil then
		local ok, c = pcall(function() : Clock return api.type.Clock.new() end)
		if not ok or c == nil then noClock = true; return nil end
		clock = c
	end
	local ok, us = pcall(function() : integer return clock:getTime() end)
	if not ok or us == nil then noClock = true; return nil end
	return (us as number) / 1000
end

------------------------------------------------------------------ the sums

M.perf = {}

-- Start the sums again (in place: the GUI holds M.perf).
function M.resetPerf(since : number)
	local p = M.perf
	p.since, p.frames, p.worstFrame = since, 0, nil
	p.ghosts, p.ghostMs, p.mapMs, p.makeMs, p.planMs, p.worstGhost, p.worstSlice = 0, 0, 0, 0, 0, nil, nil
	p.stages, p.stageWorst, p.pieces, p.partials, p.sketches = {}, {}, 0, 0, 0
	p.ticks, p.tickMs, p.slowWaiting, p.slowOther = 0, 0, 0, 0
	p.dryRuns, p.dryMs, p.worstDry = 0, 0, nil
	p.renders, p.renderMs, p.gizmoBuilds, p.badgeMs = 0, 0, 0, 0
end

M.resetPerf(nil)

------------------------------------------------------------------ the job

local yieldInPcall : boolean = nil
local job : thread = nil -- the ghost being made
local jobGen = 0 -- bumped when it is dropped (the tool starts over or closes): a job begun before then is stale
local sliceStart : number = nil -- when the job's slice in this frame began
local pausedMs = 0.0 -- time the job has spent given back (for its stages' own times)
local probes = 0

-- Can the job give the frame back inside a pcall (Lua 5.2 and on)? Asked once.
function M.canSlice() : boolean
	if yieldInPcall == nil then
		yieldInPcall = false
		pcall(function()
			local co = coroutine.create(function() pcall(function() coroutine.yield() end) end)
			coroutine.resume(co)
			yieldInPcall = coroutine.status(co) == "suspended"
		end)
	end
	return yieldInPcall
end

function M.busy() : boolean return job ~= nil end
function M.gen() : integer return jobGen end
function M.paused() : number return pausedMs end

function M.drop()
	job, jobGen = nil, jobGen + 1
end

-- Run the job's next slice: false and why when it failed (it is then dropped).
function M.step() : boolean, string
	if job == nil then return true, nil end
	sliceStart = M.now()
	local t0 = sliceStart
	local ok, err = coroutine.resume(job)
	sliceStart = nil
	local t1 = M.now()
	if t0 ~= nil and t1 ~= nil then M.perf.worstSlice = math.max(M.perf.worstSlice or 0, t1 - t0) end
	if not ok or coroutine.status(job) == "dead" then job = nil end
	return ok, not ok and tostring(err) or nil
end

-- Begin the job fn (its first slice runs at the next step).
function M.start(fn : function())
	job = coroutine.create(fn)
end

-- In the job: give the frame back once this slice's share of it is used.
function M.slice()
	if job == nil or sliceStart == nil or coroutine.running() ~= job then return end
	local now = M.now()
	if now == nil or now - sliceStart < M.SLICE_MS then return end
	coroutine.yield()
	local back = M.now()
	if back ~= nil then pausedMs = pausedMs + (back - now) end
end

-- (every so many reads of the ground: a slice ends there if its time is up)
function M.probed()
	probes = probes + 1
	if probes % 64 == 0 then M.slice() end
end

-- The time since t0 (ms) that the job worked, its pauses since p0 left out; nil without a clock.
function M.worked(t0 : number, p0 : number) : number
	local t1 = M.now()
	if t0 == nil or t1 == nil then return nil end
	return (t1 - t0) - (pausedMs - p0)
end

-- Laps: the time worked since the last lap (or lapStart) goes to the stage named (perf.stages).
-- A stage the Lua heap shrank in by over a MB (a collection finished there) is marked "(gc)".
local lapT : number = nil
local lapP = 0.0
local lapKb : number = nil
local function heapKb() : number
	local ok, kb = pcall(collectgarbage, "count")
	return ok and kb as number or nil
end
function M.lapStart()
	lapT, lapP, lapKb = M.now(), pausedMs, heapKb()
end
function M.lap(name : string)
	local t = M.worked(lapT, lapP)
	local kb = heapKb()
	if t ~= nil then
		if kb ~= nil and lapKb ~= nil and kb < lapKb - 1024 then name = name .. " (gc)" end
		local p = M.perf
		p.stages[name] = (p.stages[name] or 0) + t
		p.stageWorst[name] = math.max(p.stageWorst[name] or 0, t)
	end
	lapT, lapP, lapKb = M.now(), pausedMs, kb
end

-- The stages that took 1 ms or more, the longest first: each one's time per ghost, and its longest.
function M.stagesText(ghosts : integer) : string
	local names : {string} = {}
	for k in pairs(M.perf.stages) do names[#names + 1] = k end
	table.sort(names, function(a : string, b : string) : boolean return M.perf.stages[a] > M.perf.stages[b] end)
	local out : {string} = {}
	for _, k in ipairs(names) do
		local each = M.perf.stages[k] / math.max(ghosts, 1)
		if each >= 1 or M.perf.stageWorst[k] >= 5 then
			out[#out + 1] = string.format("%s %.1f (longest %.0f)", k, each, M.perf.stageWorst[k])
		end
	end
	return #out > 0 and table.concat(out, ", ") or "none over 1 ms"
end

return M
