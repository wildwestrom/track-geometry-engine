-- Port of the 1D Lean vertical alignment core (TrackGeometry/Profile.lean), which is the spec.
-- Each function keeps the Lean operations in the same order so results match the Lean RFloat
-- build bit-for-bit; test/profile_test.lua checks that against `fixtures.profiles` written by
-- `lake exe fixtures` (Fixtures.lean). Reuses `resolveSharedLegs` from tg_geometry.
-- No game API here.

local geometry = require("track_geometry_tool::/track_geometry/tg_geometry.script.tl")

-- A vertical point of intersection defining a break in grade along a profile.
local record PVI
	station : number -- horizontal distance coordinate along the alignment (m)
	elevation : number -- vertical height at this point of intersection (m)
end

local enum ProfileSegmentKind
	"grade"
	"parabola"
end

-- A single piece of a vertical alignment profile, either a constant grade or a symmetric
-- quadratic vertical parabola.
local record ProfileSegment
	kind : ProfileSegmentKind
	startStation : number
	length : number
	startElevation : number
	grade : number -- grade segments only
	startGrade : number -- parabola segments only
	endGrade : number -- parabola segments only
end

-- An ordered sequence of vertical alignment segments forming a continuous profile.
local record ProfilePath
	segments : {ProfileSegment}
end

-- Vertical design policy governing the radius of parabolic vertical curves.
local record ProfilePolicy
	maxVerticalAccel : number -- m/s^2; <= 0 disables speed-based formula
	designSpeed : number -- m/s; default speed at each PVI and upper cap on per-PVI speeds when > 0
	minVerticalRadius : number -- m; floors V^2 / maxVerticalAccel; <= 0 disables floor
end

local record ProfileMod
	PVI : PVI
	ProfileSegmentKind : ProfileSegmentKind
	ProfileSegment : ProfileSegment
	ProfilePath : ProfilePath
	ProfilePolicy : ProfilePolicy
	DEFAULT_POLICY : ProfilePolicy

	segmentEndStation : function(seg : ProfileSegment) : number
	segmentElevationAt : function(seg : ProfileSegment, u : number) : number
	segmentGradeAt : function(seg : ProfileSegment, u : number) : number
	segmentCurvatureAt : function(seg : ProfileSegment, u : number) : number
	length : function(path : ProfilePath) : number
	elevationAt : function(path : ProfilePath, s : number) : number
	gradeAt : function(path : ProfilePath, s : number) : number
	curvatureAt : function(path : ProfilePath, s : number) : number
	verticalRadius : function(policy : ProfilePolicy, speed : number) : number
	buildProfile : function(pvis : {PVI}, policy : ProfilePolicy, pviSpeeds ?: {integer : number}) : ProfilePath

	-- Mod-facing helpers (clamping tiny boundary noise and extracting segment breaks)
	elevationAtClamped : function(path : ProfilePath, s : number) : number
	gradeAtClamped : function(path : ProfilePath, s : number) : number
	sample : function(path : ProfilePath, ss : {number}) : {number}, {number}
	boundaries : function(path : ProfilePath) : {number}
end

local M : ProfileMod = {}

M.DEFAULT_POLICY = {
	maxVerticalAccel = 0.3,
	designSpeed = geometry.DEFAULT_PARAMS.maxDesignSpeed,
	minVerticalRadius = 500.0,
}

local function abs(x : number) : number
	if x < 0 then return -x end
	return x
end

---------------------------------------------------------------------- ProfileSegment

function M.segmentEndStation(seg : ProfileSegment) : number
	return seg.startStation + seg.length
end

function M.segmentElevationAt(seg : ProfileSegment, u : number) : number
	if seg.kind == "grade" then
		return seg.startElevation + seg.grade * u
	end
	return seg.startElevation + seg.startGrade * u + (seg.endGrade - seg.startGrade) / (2 * seg.length) * (u * u)
end

function M.segmentGradeAt(seg : ProfileSegment, u : number) : number
	if seg.kind == "grade" then
		return seg.grade
	end
	return seg.startGrade + (seg.endGrade - seg.startGrade) / seg.length * u
end

function M.segmentCurvatureAt(seg : ProfileSegment, _u : number) : number
	if seg.kind == "grade" then
		return 0
	end
	return (seg.endGrade - seg.startGrade) / seg.length
end

---------------------------------------------------------------------- ProfilePath

function M.length(path : ProfilePath) : number
	local acc = 0.0
	for _, seg in ipairs(path.segments) do
		acc = acc + seg.length
	end
	return acc
end

local function sampleAt(f : function(ProfileSegment, number) : number, path : ProfilePath, s : number) : number
	for _, seg in ipairs(path.segments) do
		if seg.startStation <= s and s <= M.segmentEndStation(seg) then
			return f(seg, s - seg.startStation)
		end
	end
	return nil
end

function M.elevationAt(path : ProfilePath, s : number) : number
	return sampleAt(M.segmentElevationAt, path, s)
end

function M.gradeAt(path : ProfilePath, s : number) : number
	return sampleAt(M.segmentGradeAt, path, s)
end

function M.curvatureAt(path : ProfilePath, s : number) : number
	return sampleAt(M.segmentCurvatureAt, path, s)
end

---------------------------------------------------------------------- ProfilePolicy & buildProfile

function M.verticalRadius(policy : ProfilePolicy, speed : number) : number
	if policy.maxVerticalAccel > 0 and speed > 0 then
		return math.max(policy.minVerticalRadius, speed * speed / policy.maxVerticalAccel)
	end
	return policy.minVerticalRadius
end

local function filterIncreasingPVIs(pvis : {PVI}, pviSpeeds : {integer : number}) : {PVI}, {integer : number}
	local kept : {PVI} = {}
	local keptSpeeds : {integer : number} = {}
	for i = 1, #pvis do
		local p = pvis[i]
		local spd = pviSpeeds ~= nil and pviSpeeds[i] or nil
		if #kept == 0 or kept[#kept].station < p.station then
			local idx = #kept + 1
			kept[idx] = p
			if spd ~= nil then keptSpeeds[idx] = spd end
		end
	end
	return kept, keptSpeeds
end

function M.buildProfile(pvis : {PVI}, policy : ProfilePolicy, pviSpeeds ?: {integer : number}) : ProfilePath
	local kept, keptSpeeds = filterIncreasingPVIs(pvis, pviSpeeds)
	local n = #kept
	if n < 2 then return { segments = {} } end
	local legLengths : {number} = {}
	local grades : {number} = {}
	for k = 1, n - 1 do
		local a, b = kept[k], kept[k + 1]
		legLengths[k] = b.station - a.station
		grades[k] = (b.elevation - a.elevation) / (b.station - a.station)
	end
	local asks : {integer : number} = {}
	for i = 2, n - 1 do
		local gIn = grades[i - 1]
		local gOut = grades[i]
		local spd = keptSpeeds[i]
		local effSpeed : number
		if spd ~= nil then
			effSpeed = policy.designSpeed > 0 and math.min(spd, policy.designSpeed) or spd
		else
			effSpeed = policy.designSpeed
		end
		local rV = M.verticalRadius(policy, effSpeed)
		if gOut ~= gIn and rV > 0 then
			asks[i] = rV * abs(gOut - gIn) / 2
		end
	end
	local budgets = geometry.resolveSharedLegs(legLengths, asks)
	local function budgetHalfLen(i : integer) : number
		local t = budgets[i]
		if t ~= nil and t > 0 then return t end
		return 0
	end
	local segs : {ProfileSegment} = {}
	for k = 1, n - 1 do
		local a, b = kept[k], kept[k + 1]
		local g = grades[k]
		local tStart = budgetHalfLen(k)
		local tEnd = budgetHalfLen(k + 1)
		local sStart = a.station + tStart
		local sEnd = b.station - tEnd
		local gradeLen = sEnd - sStart
		if 0 < gradeLen then
			segs[#segs + 1] = {
				kind = "grade",
				startStation = sStart,
				length = gradeLen,
				startElevation = a.elevation + g * tStart,
				grade = g,
			}
		end
		if k + 1 < n and 0 < tEnd then
			local gNext = grades[k + 1]
			segs[#segs + 1] = {
				kind = "parabola",
				startStation = b.station - tEnd,
				length = 2 * tEnd,
				startElevation = b.elevation - g * tEnd,
				startGrade = g,
				endGrade = gNext,
			}
		end
	end
	return { segments = segs }
end

---------------------------------------------------------------------- Mod-facing helpers

-- Find the segment and clamped local offset u in [0, seg.length] for station s on a non-empty
-- ProfilePath, clamping stations outside [first.startStation, last.endStation] and bridging any
-- 1-ULP gap between consecutive segments.
local function locateClamped(path : ProfilePath, s : number) : ProfileSegment, number
	local segs = path.segments
	local n = #segs
	if n == 0 then return nil, 0 end
	local s0 = segs[1].startStation
	local s1 = M.segmentEndStation(segs[n])
	s = math.max(s0, math.min(s1, s))
	for i = 1, n - 1 do
		local seg = segs[i]
		if s <= M.segmentEndStation(seg) then
			return seg, math.max(0.0, math.min(seg.length, s - seg.startStation))
		end
	end
	local last = segs[n]
	return last, math.max(0.0, math.min(last.length, s - last.startStation))
end

function M.elevationAtClamped(path : ProfilePath, s : number) : number
	local seg, u = locateClamped(path, s)
	if seg == nil then return nil end
	return M.segmentElevationAt(seg, u)
end

function M.gradeAtClamped(path : ProfilePath, s : number) : number
	local seg, u = locateClamped(path, s)
	if seg == nil then return nil end
	return M.segmentGradeAt(seg, u)
end

-- Heights and grades at the chainages ss (each node's s), clamped to the profile's span.
function M.sample(path : ProfilePath, ss : {number}) : {number}, {number}
	local z, g : {number}, {number} = {}, {}
	for i, s in ipairs(ss) do
		local seg, u = locateClamped(path, s)
		if seg ~= nil then
			z[i], g[i] = M.segmentElevationAt(seg, u), M.segmentGradeAt(seg, u)
		end
	end
	return z, g
end

-- Distinct segment boundary stations (start and end of every grade and parabola: BVC/EVC) in
-- increasing order.
function M.boundaries(path : ProfilePath) : {number}
	local out : {number} = {}
	for _, seg in ipairs(path.segments) do
		local s0, s1 = seg.startStation, M.segmentEndStation(seg)
		if #out == 0 or s0 > out[#out] then out[#out + 1] = s0 end
		if s1 > out[#out] then out[#out + 1] = s1 end
	end
	return out
end

return M
