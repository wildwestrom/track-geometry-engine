import TrackGeometry.Lib

/-! # Geometry for the mod page's thumbnail

`lake env lean --run mod/thumbnail/Thumbnail.lean` (from the repo root) builds a two-turn
alignment with the engine's own `buildPath` and prints, as JSON, everything `thumbnail.py`
needs to draw it: the PIs, every segment as cubic Béziers, each arc's circle, the brackets, and the
track (rails and sleepers) along the path. No drawing and no text happen here, only coordinates.

Each segment is cut into pieces short enough to turn at most about 17° and every piece
becomes one cubic Bézier through the engine's exact `pointAt` and `tangentAt`. A piece that
turns by φ over arc length s has handles of length (4/3)·tan(φ/4)·s/φ, which is exact for a
circle and, for a clothoid's slowly changing curvature, off by far less than a pixel. -/

def rf (x : Float) : RFloat := ⟨x⟩

/-- Screen space: x right, y down, 1 unit = 1 px of the 1920 x 1080 image. -/
def pis : Array (Float × Float) :=
  let w := 1920
  let h := 1080
  let pcs := 4
  let y_mgn := 175
  let x_mgn := 175
  let x_pt := (w - x_mgn*2) / (pcs - 1) -- the PIs are one step apart, the first and last a margin from the edges
  #[
   ((x_pt * 0) + x_mgn, y_mgn),
   ((x_pt * 1) + x_mgn - 200, h-y_mgn),
   ((x_pt * 2) + x_mgn + 100, y_mgn+(h/7)),
   ((x_pt * 3) + x_mgn, h-y_mgn-(h/7))
  ]

/-- Tangent budget per PI (px of leg), so the picture, not the speed model, picks the radii. -/
def overrides : Array (Option Float) := #[none, some 250, some 320, none]

def dp : DesignParams RFloat :=
  { legBudget := rf 0.3, minRadius := rf 40.0, straightThreshold := rf 0.001,
    maxLateralAccel := rf 1.2, maxLateralJerk := rf 0.12, maxYawAccel := rf 0.2,
    maxDesignSpeed := rf 30.0 }

abbrev P := Float × Float

def pt (e : AnySegment RFloat) (t : Float) : P :=
  let v := e.pointAt ⟨t⟩
  ((v 0).val, (v 1).val)

def tan (e : AnySegment RFloat) (t : Float) : P :=
  let v := e.tangentAt ⟨t⟩
  let (x, y) := ((v 0).val, (v 1).val)
  let n := Float.sqrt (x * x + y * y)
  (x / n, y / n)

/-- One cubic Bézier: start, two control points, end. -/
structure Cubic where
  p0 : P
  c1 : P
  c2 : P
  p1 : P

def handleLength (turn s : Float) : Float :=
  if turn < 1e-9 then s / 3 else 4 / 3 * Float.tan (turn / 4) * s / turn

/-- The cubic through two points with unit tangents, `s` of arc length apart. -/
def hermite (p0 p1 t0 t1 : P) (s : Float) : Cubic :=
  let cosφ := max (-1) (min 1 (t0.1 * t1.1 + t0.2 * t1.2))
  let h := handleLength (Float.acos cosφ) s
  { p0, p1, c1 := (p0.1 + t0.1 * h, p0.2 + t0.2 * h), c2 := (p1.1 - t1.1 * h, p1.2 - t1.2 * h) }

/-- The segment as cubics, `offset` px to the left of its direction of travel (negative: right).
    The offset curve has the centre line's tangents, and a piece that turns by φ towards the side
    it is moved to is shorter by `offset·φ` (longer when it turns away), which sets the handles. -/
def segmentCubics (e : AnySegment RFloat) (radius : Float) (offset : Float := 0) : Array Cubic :=
  Id.run do
    let len := e.length.val
    let n := if radius < 1e-9 then 1 else max 1 (len / (radius * 0.3)).ceil.toUInt64.toNat
    let side (p t : P) : P := (p.1 - t.2 * offset, p.2 + t.1 * offset)
    let mut out := #[]
    for i in [0:n] do
      let a := len * i.toFloat / n.toFloat
      let b := len * (i + 1).toFloat / n.toFloat
      let (ta, tb) := (tan e a, tan e b)
      let φ := Float.acos (max (-1) (min 1 (ta.1 * tb.1 + ta.2 * tb.2)))
      let towards : Float := if ta.1 * tb.2 - ta.2 * tb.1 > 0 then 1 else -1
      out := out.push (hermite (side (pt e a) ta) (side (pt e b) tb) ta tb
        (b - a - offset * towards * φ))
    return out

/-- The track drawn along the path, in px: half the distance between the rails, half a sleeper's
    length, and the distance between sleepers to aim for (see `fitSpacing`). -/
def railOffset : Float := 36
def sleeperHalf : Float := 60
def sleeperSpacing : Float := 78

/-- The spacing actually used on a path of length `total`: `sleeperSpacing` rounded so a whole
    number of equal gaps fills the path, which puts half a gap at each end and makes the sleepers
    symmetric about the path's midpoint. -/
def fitSpacing (total : Float) : Float :=
  total / (max 1 (total / sleeperSpacing).round)

/-- The sleepers of a segment that starts `s0` along the path: a line across the track at every
    `spacing` along the whole path (the first half a spacing in), not per segment, so the
    spacing is even across the joins. -/
def sleepers (e : AnySegment RFloat) (s0 spacing : Float) : Array (P × P) := Id.run do
  let len := e.length.val
  let mut k := (s0 / spacing - 0.5).ceil
  let mut out := #[]
  while (k + 0.5) * spacing < s0 + len do
    let t := (k + 0.5) * spacing - s0
    let (p, d) := (pt e t, tan e t)
    out := out.push ((p.1 + d.2 * sleeperHalf, p.2 - d.1 * sleeperHalf),
                     (p.1 - d.2 * sleeperHalf, p.2 + d.1 * sleeperHalf))
    k := k + 1
  return out

/-- The game's grab radius, in px: the PI rings' radius, and the unit the brackets are drawn in. -/
def grab : Float := 42

/-- The game's curve handle, the 〔 of `bracketPoints` in `tg_gizmos.script.tl`, at `p` with `u`
    the unit vector along the leg towards the curve: a bar across the leg, then at each end a
    slanted corner and a tip. `bar` and `tip` are `BRACKET_BAR` and `BRACKET_TIP` in `tg_edit.script.tl`. -/
def bracketPoints (p u : P) : Array P :=
  let (bar, tip) := (1.5 * grab, 0.8 * grab)
  let corner := tip / 2
  let shape : Array P :=
    #[(tip, bar), (corner, bar), (0, bar - corner), (0, corner - bar), (corner, -bar), (tip, -bar)]
  shape.map fun (along, across) =>
    (p.1 + u.1 * along - u.2 * across, p.2 + u.2 * along + u.1 * across)

def num (x : Float) : String :=
  let s := toString (Float.round (x * 100) / 100)
  s

def pStr (p : P) : String := s!"[{num p.1}, {num p.2}]"

def cubicStr (c : Cubic) : String :=
  s!"[{pStr c.p0}, {pStr c.c1}, {pStr c.c2}, {pStr c.p1}]"

def cubicsStr (cs : Array Cubic) : String :=
  "[" ++ ", ".intercalate (cs.toList.map cubicStr) ++ "]"

/-- Radius of an arc or of the arc a spiral leads to; 0 for a straight. -/
def kindAndRadius (e : AnySegment RFloat) : String × Float :=
  match e with
  | ⟨_, _, .straight .., _⟩ => ("straight", 0)
  | ⟨_, _, .arc r .., _⟩ => ("arc", r.val)
  | ⟨_, _, .transitionIn r .., _⟩ => ("spiral", r.val)
  | ⟨_, _, .transitionOut r .., _⟩ => ("spiral", r.val)

/-- Where an arc's circle is. -/
def arcExtras (e : AnySegment RFloat) (r : Float) : String :=
  let len := e.length.val
  let (t0, t1) := (tan e 0, tan e len)
  let side : Float := if t0.1 * t1.2 - t0.2 * t1.1 > 0 then 1 else -1
  let p0 := pt e 0
  let c : P := (p0.1 - side * t0.2 * r, p0.2 + side * t0.1 * r)
  let m := pt e (len / 2)
  s!", \"circle\": \{\"center\": {pStr c}, \"r\": {num r}, \"mid\": {pStr m}}"

/-- The curve handle where a spiral meets its leg: at the spiral's start (the curve's entry) with
    the direction of travel, and at its end (the exit) with the way back, both towards the curve. -/
def bracketOf (e : AnySegment RFloat) : Option (Array P) :=
  match e with
  | ⟨_, _, .transitionIn .., _⟩ => some (bracketPoints (pt e 0) (tan e 0))
  | ⟨_, _, .transitionOut .., _⟩ =>
    let t := tan e e.length.val
    some (bracketPoints (pt e e.length.val) (-t.1, -t.2))
  | _ => none

def segmentJson (e : AnySegment RFloat) (s0 spacing : Float) : String :=
  let (kind, r) := kindAndRadius e
  let extras := if kind == "arc" then arcExtras e r else ""
  let bracket := match bracketOf e with
    | some pts => s!", \"bracket\": [{", ".intercalate (pts.toList.map pStr)}]"
    | none => ""
  let rails := s!", \"rails\": [{cubicsStr (segmentCubics e r railOffset)}, " ++
    s!"{cubicsStr (segmentCubics e r (-railOffset))}]"
  let ties := ", ".intercalate ((sleepers e s0 spacing).toList.map fun (a, b) => s!"[{pStr a}, {pStr b}]")
  s!"\{\"kind\": \"{kind}\", \"length\": {num e.length.val}, " ++
    s!"\"cubics\": {cubicsStr (segmentCubics e r)}{extras}{bracket}{rails}, \"sleepers\": [{ties}]}"

def main : IO Unit := do
  let path := buildPath (pis.map fun (x, y) => Vec3.mk (rf x) (rf y) 0) dp
    (overrides.map (·.map rf))
  let segs := path.segments.toList
  let starts := (segs.foldl (fun (acc : List Float × Float) e => (acc.1 ++ [acc.2], acc.2 + e.length.val))
    ([], 0)).1
  let segments := segs.zip starts
  let spacing := fitSpacing (segs.foldl (fun acc e => acc + e.length.val) 0)
  IO.println "{"
  IO.println s!"  \"size\": [1920, 1080],"
  IO.println s!"  \"grab\": {num grab},"
  IO.println s!"  \"pis\": [{", ".intercalate (pis.toList.map pStr)}],"
  IO.println "  \"segments\": ["
  IO.println (",\n".intercalate (segments.map fun (e, s0) => "    " ++ segmentJson e s0 spacing))
  IO.println "  ]"
  IO.println "}"
