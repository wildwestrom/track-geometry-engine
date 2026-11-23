import TrackGeometry.Lib

set_option linter.missingDocs true

/-! # Fixture dump for the Teal port

`lake exe fixtures [out]` runs `buildPath2D` over a set of horizontal PI fixtures and
`buildProfile` over a set of vertical PVI fixtures, writing both into a single Lua table
(default `mod/test/fixtures.lua`). Horizontal fixtures sit in the array part of the returned
table so existing `ipairs(fixtures)` consumers remain compatible; vertical profile fixtures
sit under the `profiles` key. Every float is written as its IEEE-754 bit pattern in hex, so
nothing is lost to decimal formatting. -/

namespace Fixtures

/-- Wrap a `Float` into the `RFloat` scalar newtype. -/
def rf (x : Float) : RFloat := ⟨x⟩

/-- A float as a quoted 16-digit hex bit pattern. -/
def hex (x : RFloat) : String :=
  let d := Nat.toDigits 16 x.val.toBits.toNat
  "\"" ++ String.join (List.replicate (16 - d.length) "0") ++ String.join (d.map Char.toString) ++ "\""

/-- Default layout policy matching `TrackGeometry.UI.Config.layoutPolicy`. -/
def lpDefault : LayoutPolicy RFloat :=
  { legBudget := rf 0.3, minRadius := rf 40.0 }

/-- Layout policy where every corner takes half of each leg, so adjacent curves meet with
    a zero-length straight between them. -/
def lpHalf : LayoutPolicy RFloat := { lpDefault with legBudget := rf 0.5 }

/-- Default speed model matching `TrackGeometry.UI.Config.speedModel`. -/
def smDefault : SpeedModel RFloat :=
  { maxLateralAccel := rf 1.2, maxLateralJerk := rf 0.5, maxYawAccel := rf 0.2,
    maxDesignSpeed := rf 83.3333 }

/-- Speed model disabled: pure circular fillets. -/
def smNoSpeed : SpeedModel RFloat := { smDefault with maxLateralAccel := rf 0 }

/-- Default collinearity threshold matching `TrackGeometry.UI.Config.straightThreshold`. -/
def straightThreshDefault : RFloat := rf 0.001

/-- One alignment test fixture exported to Lua for cross-checking the Teal port. -/
structure Fixture where
  /-- Human-readable name of the fixture case. -/
  name : String
  /-- Layout policy for automatic corner budgets and minimum radius. -/
  lp : LayoutPolicy RFloat := lpDefault
  /-- Speed and comfort model for transitions and operating speeds. -/
  sm : SpeedModel RFloat := smDefault
  /-- Collinearity threshold below which corners are treated as straight. -/
  straightThreshold : RFloat := straightThreshDefault
  /-- Planar PI coordinates `(x, y)` in world units. -/
  pis : Array (Float × Float)
  /-- Per-PI tangent budget overrides, indexed like `pis`. -/
  overrides : Array (Option Float) := #[]

/-- Standard suite of 2D alignment test fixtures exported to Lua. -/
def fixtures : Array Fixture := #[
  { name := "left corner", pis := #[(0, 0), (400, 0), (700, 300)] },
  { name := "right corner", pis := #[(0, 0), (400, 0), (700, -300)] },
  { name := "S curve", pis := #[(0, 0), (300, 0), (600, 200), (900, 100), (1200, 250)] },
  { name := "near-straight corner", pis := #[(0, 0), (500, 0), (1000, 0.1)] },
  { name := "sharp corner, short legs", pis := #[(0, 0), (100, 0), (60, 80)] },
  { name := "pure fillet", sm := smNoSpeed, pis := #[(0, 0), (400, 0), (700, 300)] },
  { name := "overrides", pis := #[(0, 0), (300, 0), (600, 200), (900, 100), (1200, 250)],
    overrides := #[none, some 20, some 500, none, none] },
  { name := "two points", pis := #[(10, 20), (310, 420)] },
  { name := "duplicate PI", pis := #[(0, 0), (200, 0), (200, 0), (400, 100)] },
  { name := "corners meet", lp := lpHalf, pis := #[(0, 0), (300, 0), (300, 300), (600, 300)] },
  { name := "wide corner between the ends", pis := #[(0, 0), (400, 0), (700, 300)],
    overrides := #[none, some 380, none] },
  { name := "neighbour leaves room", pis := #[(0, 0), (300, 0), (300, 300), (600, 300)],
    overrides := #[none, some 250, some 40, none] },
  { name := "curves squeezed on a shared leg", pis := #[(0, 0), (300, 0), (300, 300), (600, 300)],
    overrides := #[none, some 250, some 100, none] },
  { name := "first curve starts at the path's start",
    pis := #[(0, 0), (150, 0), (450, 200), (750, 100), (1050, 250)] }
]

/-- Extract the Lua segment kind tag and arc radius (`0` for straights) from a 2D segment. -/
def kindAndRadius (e : Segment2D RFloat) : String × RFloat :=
  match e with
  | .straight .. => ("straight", 0)
  | .arc r .. => ("arc", r)
  | .transitionIn r .. => ("in", r)
  | .transitionOut r .. => ("out", r)

/-- Format a 2D vector as Lua `x` and `y` fields in hex. -/
def vec (pre : String) (v : Vec2 RFloat) : String :=
  s!"{pre}x = {hex v.x}, {pre}y = {hex v.y}"

/-- Format a 2D segment sampled at five evenly spaced local arc-lengths. -/
def dumpSegment (e : Segment2D RFloat) : String :=
  let (kind, r) := kindAndRadius e
  let len := e.length
  let samples := (List.range 5).map fun k =>
    let t := len * natToScalar k / natToScalar 4
    s!"      \{ t = {hex t}, {vec "" (e.pointAt t)}, {vec "t" (e.tangentAt t)}, k = {hex (e.curvatureAt t)} },\n"
  s!"    \{ kind = \"{kind}\", radius = {hex r}, length = {hex len}, opSpeed = {hex e.opSpeed}, samples = \{\n"
    ++ String.join samples ++ "    } },\n"

/-- Serialize one fixture case by running `buildPath2D` and formatting its parameters and segments. -/
def dumpFixture (f : Fixture) : String :=
  let pts := f.pis.map fun (x, y) => Vec2.mk (rf x) (rf y)
  let path := buildPath2D pts f.lp f.sm f.straightThreshold (f.overrides.map (·.map rf))
  let lp := f.lp
  let sm := f.sm
  let params := s!"legBudget = {hex lp.legBudget}, minRadius = {hex lp.minRadius}, " ++
    s!"straightThreshold = {hex f.straightThreshold}, maxLateralAccel = {hex sm.maxLateralAccel}, " ++
    s!"maxLateralJerk = {hex sm.maxLateralJerk}, maxYawAccel = {hex sm.maxYawAccel}, " ++
    s!"maxDesignSpeed = {hex sm.maxDesignSpeed}"
  let pis := String.join (pts.toList.map fun p => s!"\{ {hex p.x}, {hex p.y} }, ")
  let overrides := String.join ((List.range f.overrides.size).filterMap fun i =>
    (f.overrides[i]?).bind id |>.map fun o => s!"[{i + 1}] = {hex (rf o)}, ")
  s!"  \{ name = \"{f.name}\",\n    params = \{ {params} },\n    pis = \{ {pis}},\n" ++
    s!"    overrides = \{ {overrides}},\n    length = {hex path.length},\n    segments = \{\n" ++
    String.join (path.segments.toList.map dumpSegment) ++ "  } },\n"

/-- Default vertical design policy for profile fixture cases. -/
def ppDefault : ProfilePolicy RFloat :=
  { maxVerticalAccel := rf 0.3, designSpeed := rf 30.0, minVerticalRadius := rf 500.0 }

/-- Vertical design policy with vertical curves disabled (`R_v ≤ 0`). -/
def ppDisabled : ProfilePolicy RFloat :=
  { maxVerticalAccel := rf 0.0, designSpeed := rf 30.0, minVerticalRadius := rf 0.0 }

/-- One vertical profile test fixture exported to Lua for cross-checking the Teal port. -/
structure ProfileFixture where
  /-- Human-readable name of the vertical profile fixture case. -/
  name : String
  /-- Vertical design policy governing curve radii. -/
  policy : ProfilePolicy RFloat := ppDefault
  /-- Ordered `(station, elevation)` pairs for vertical points of intersection. -/
  pvis : Array (Float × Float)
  /-- Optional per-point operating speeds in metres per second, indexed like `pvis`. -/
  pviSpeeds : Array (Option Float) := #[]

/-- Standard suite of 1D vertical profile test fixtures exported to Lua. -/
def profileFixtures : Array ProfileFixture := #[
  { name := "crest",
    pvis := #[(0, 0), (200, 4), (400, 0)] },
  { name := "sag",
    pvis := #[(0, 4), (200, 0), (400, 4)] },
  { name := "S profile",
    pvis := #[(0, 0), (200, 4), (500, -2), (700, 2)] },
  { name := "short-leg shared squeeze",
    pvis := #[(0, 0), (200, 4), (300, 2), (500, 10)] },
  { name := "pviSpeeds lower-speed cap",
    pvis := #[(0, 0), (200, 4), (500, -2), (700, 2)],
    pviSpeeds := #[none, some 20, some 50, none] },
  { name := "equal adjacent grades",
    pvis := #[(0, 0), (200, 4), (400, 8)] },
  { name := "disabled vertical radius",
    policy := ppDisabled,
    pvis := #[(0, 0), (200, 4), (400, 0)] },
  { name := "non-increasing and duplicate PVIs",
    pvis := #[(0, 0), (200, 4), (200, 9), (150, 1), (400, 0)],
    pviSpeeds := #[none, some 20, some 10, some 15, none] },
  { name := "single PVI",
    pvis := #[(100, 5)] },
  { name := "empty PVIs",
    pvis := #[] }
]

/-- Extract the Lua segment kind tag (`grade` or `parabola`) from a vertical segment. -/
def profileSegmentKind (seg : ProfileSegment RFloat) : String :=
  match seg with
  | .grade .. => "grade"
  | .parabola .. => "parabola"

/-- Format a vertical segment sampled at five evenly spaced local horizontal offsets. -/
def dumpProfileSegment (seg : ProfileSegment RFloat) : String :=
  let kind := profileSegmentKind seg
  let len := seg.length
  let samples := (List.range 5).map fun k =>
    let u := len * natToScalar k / natToScalar 4
    s!"        \{ u = {hex u}, elevation = {hex (seg.elevationAt u)}, " ++
      s!"grade = {hex (seg.gradeAt u)}, curvature = {hex (seg.curvatureAt u)} },\n"
  s!"      \{ kind = \"{kind}\", startStation = {hex seg.startStation}, " ++
    s!"endStation = {hex seg.endStation}, length = {hex len}, samples = \{\n" ++
    String.join samples ++ "      } },\n"

/-- Serialize one vertical profile fixture case by running `buildProfile` and formatting its inputs and segments. -/
def dumpProfileFixture (f : ProfileFixture) : String :=
  let pvis := f.pvis.map fun (s, z) => PVI.mk (rf s) (rf z)
  let speeds := f.pviSpeeds.map (·.map rf)
  let path := buildProfile pvis f.policy speeds
  let pol := f.policy
  let policy := s!"maxVerticalAccel = {hex pol.maxVerticalAccel}, " ++
    s!"designSpeed = {hex pol.designSpeed}, minVerticalRadius = {hex pol.minVerticalRadius}"
  let pviStr := String.join (pvis.toList.map fun p => s!"\{ {hex p.station}, {hex p.elevation} }, ")
  let speedStr := String.join ((List.range f.pviSpeeds.size).filterMap fun i =>
    (f.pviSpeeds[i]?).bind id |>.map fun v => s!"[{i + 1}] = {hex (rf v)}, ")
  s!"    \{ name = \"{f.name}\",\n      policy = \{ {policy} },\n      pvis = \{ {pviStr}},\n" ++
    s!"      pviSpeeds = \{ {speedStr}},\n      length = {hex path.length},\n      segments = \{\n" ++
    String.join (path.segments.toList.map dumpProfileSegment) ++ "    } },\n"

end Fixtures

/-- Entry point for `lake exe fixtures`, writing the Lua fixture table to the target path. -/
def main (args : List String) : IO Unit := do
  let out := args.headD "mod/test/fixtures.lua"
  IO.FS.writeFile out <|
    "-- Generated by `lake exe fixtures` (Fixtures.lean). Do not edit.\n" ++
    "-- Floats are IEEE-754 bit patterns in hex.\nreturn {\n" ++
    String.join (Fixtures.fixtures.toList.map Fixtures.dumpFixture) ++
    "  profiles = {\n" ++
    String.join (Fixtures.profileFixtures.toList.map Fixtures.dumpProfileFixture) ++
    "  },\n}\n"
  IO.println s!"wrote {Fixtures.fixtures.size} horizontal and {Fixtures.profileFixtures.size} profile fixtures to {out}"
