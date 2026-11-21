import TrackGeometry.Design

/-! # 2D horizontal alignment (Planar)

Standalone 2D horizontal alignment built on the shared `Scalar`, `Clothoid`, and `Design`
core:

* `Vec2` — 2D planar vector operations using `perp` and 2D rotation (no `atan2` required)
* `TurnDir` — explicit horizontal turn handedness (`left | right`)
* `Segment2D` — plain unindexed 2D segments (`straight`, analytic `arc` with required
  `sweep`, and Gauss–Legendre `transitionIn` / `transitionOut`)
* `CornerGeometry2D`, `CornerSolution2D`, `cornerGeometry2D`, `buildCorner2D` — principal
  deflection corners (`0 < Δ < π`, no `winding`)
* `AlignmentPath2D`, `buildPath2D` — PI-based 2D horizontal path builder reusing
  `solveCornerParams`, `desiredBudgets`, and `resolveSharedLegs`

This module carries no Mathlib or 3D dependency so it stays compilable to C over `RFloat`
and directly usable in `ℝ` proofs.
-/

/-- Two-dimensional vector in the horizontal plane with components of scalar type `α`. -/
structure Vec2 (α : Type) where
  /-- Horizontal X coordinate. -/
  x : α
  /-- Horizontal Y coordinate. -/
  y : α

namespace Vec2

variable {α : Type}

/-- Componentwise vector addition. -/
instance [Add α] : Add (Vec2 α) := ⟨fun v w => ⟨v.x + w.x, v.y + w.y⟩⟩

/-- Componentwise vector subtraction. -/
instance [Sub α] : Sub (Vec2 α) := ⟨fun v w => ⟨v.x - w.x, v.y - w.y⟩⟩

/-- Componentwise vector negation. -/
instance [Neg α] : Neg (Vec2 α) := ⟨fun v => ⟨-v.x, -v.y⟩⟩

/-- Scalar multiplication of a 2D vector. -/
instance [Mul α] : SMul α (Vec2 α) := ⟨fun r v => ⟨r * v.x, r * v.y⟩⟩

/-- Dot product of two 2D vectors. -/
def dot [Add α] [Mul α] (v w : Vec2 α) : α :=
  v.x * w.x + v.y * w.y

/-- Signed 2D cross product (determinant) of two vectors, positive when `w` is
counterclockwise from `v`. -/
def cross [Mul α] [Sub α] (v w : Vec2 α) : α :=
  v.x * w.y - v.y * w.x

/-- Squared Euclidean length of a 2D vector. -/
def normSq [Add α] [Mul α] (v : Vec2 α) : α :=
  dot v v

/-- Euclidean length of a 2D vector. -/
def norm [TrackScalar α] (v : Vec2 α) : α :=
  TrackScalar.sqrt (normSq v)

/-- Euclidean distance between two 2D points. -/
def dist [TrackScalar α] (v w : Vec2 α) : α :=
  norm (v - w)

/-- Rotate a 2D vector 90 degrees counterclockwise. -/
def perp [Neg α] (v : Vec2 α) : Vec2 α :=
  ⟨-v.y, v.x⟩

/-- Linearly interpolate between two 2D points by fraction `t`. -/
def lerp [Add α] [Sub α] [SMul α (Vec2 α)] (p q : Vec2 α) (t : α) : Vec2 α :=
  p + t • (q - p)

/-- Return a unit vector in the direction of `v`, leaving the zero vector unchanged. -/
def normalize [TrackScalar α] (v : Vec2 α) : Vec2 α :=
  let n2 := normSq v
  if n2 = 0 then v else (1 / TrackScalar.sqrt n2) • v

/-- Rotate a 2D vector counterclockwise by angle `φ` in radians. -/
def rotate [TrackScalar α] (φ : α) (v : Vec2 α) : Vec2 α :=
  let c := TrackScalar.cos φ
  let s := TrackScalar.sin φ
  ⟨c * v.x - s * v.y, s * v.x + c * v.y⟩

end Vec2

/-- Handedness of a horizontal turn in the 2D plane. -/
inductive TurnDir where
  /-- Counterclockwise turn to the left of the travel direction. -/
  | left
  /-- Clockwise turn to the right of the travel direction. -/
  | right
  deriving DecidableEq, Repr

namespace TurnDir

/-- Return `+1` for a left (counterclockwise) turn and `-1` for a right (clockwise) turn. -/
def sign [One α] [Neg α] : TurnDir → α
  | .left => 1
  | .right => -1

/-- Compute the inward unit normal for a unit tangent `v` turning in this direction.

Returns `v.perp` for a left turn and `-v.perp` for a right turn. -/
def normal [Neg α] (dir : TurnDir) (v : Vec2 α) : Vec2 α :=
  match dir with
  | .left => v.perp
  | .right => -v.perp

/-- Rotate a 2D vector by unsigned angle `φ` in this turn direction. -/
def rotate [TrackScalar α] (dir : TurnDir) (φ : α) (v : Vec2 α) : Vec2 α :=
  Vec2.rotate (dir.sign * φ) v

end TurnDir

/-- A single 2D horizontal alignment segment.

Curved segments store an unsigned radius, start point, start tangent direction, and explicit
turn handedness (`TurnDir`), with analytic circular arcs and Gauss–Legendre clothoid
transitions. -/
inductive Segment2D (α : Type) where
  /-- Straight line segment from `startPt` to `endPt` with design operating speed `opSpeed`. -/
  | straight (startPt endPt : Vec2 α) (opSpeed : α)
  /-- Circular arc of unsigned `radius` starting at `startPt` with tangent `startTangent`,
      turning in direction `dir` through unsigned angle `sweep`, with design operating speed
      `opSpeed`. -/
  | arc (radius : α) (startPt startTangent : Vec2 α) (dir : TurnDir) (sweep : α)
      (opSpeed : α)
  /-- Entry clothoid transition ramping curvature linearly from `0` to `1 / radius` over
      `length`, with design operating speed `opSpeed`. -/
  | transitionIn (radius : α) (startPt startTangent : Vec2 α) (dir : TurnDir) (length : α)
      (opSpeed : α)
  /-- Exit clothoid transition ramping curvature linearly from `1 / radius` to `0` over
      `length`, with design operating speed `opSpeed`. -/
  | transitionOut (radius : α) (startPt startTangent : Vec2 α) (dir : TurnDir) (length : α)
      (opSpeed : α)

/-- Evaluate a point along a 2D clothoid transition at local arc-length `s`.

Integrates the local offset `(xL, yL)` with composite Gauss–Legendre quadrature
(`clothoidOffset`) and places it in the local frame `(v̂, dir.normal v̂)`. -/
def clothoidPoint2D [TrackScalar α] (p v : Vec2 α) (dir : TurnDir) (κ₀ κ₁ L s : α) : Vec2 α :=
  let κ' := (κ₁ - κ₀) / L
  let (xL, yL) := clothoidOffset κ₀ κ' s clothoidPanels
  let vUnit := Vec2.normalize v
  let nUnit := dir.normal vUnit
  p + xL • vUnit + yL • nUnit

/-- Extract the design operating speed carried by a 2D segment. -/
def Segment2D.opSpeed : Segment2D α → α
  | .straight _ _ v => v
  | .arc _ _ _ _ _ v => v
  | .transitionIn _ _ _ _ _ v => v
  | .transitionOut _ _ _ _ _ v => v

/-- Compute the total arc-length of a 2D segment. -/
def Segment2D.length [TrackScalar α] : Segment2D α → α
  | .straight startPt endPt _ => Vec2.dist startPt endPt
  | .arc radius _ _ _ sweep _ => absScalar (radius * sweep)
  | .transitionIn _ _ _ _ len _ => len
  | .transitionOut _ _ _ _ len _ => len

/-- Return the unnormalized start direction vector of a 2D segment. -/
def Segment2D.startDir [Sub α] : Segment2D α → Vec2 α
  | .straight startPt endPt _ => endPt - startPt
  | .arc _ _ v _ _ _ => v
  | .transitionIn _ _ v _ _ _ => v
  | .transitionOut _ _ v _ _ _ => v

/-- Compute the unsigned running turn angle `θ(t)` at local arc-length `t` along a 2D segment. -/
def Segment2D.headingAt [TrackScalar α] (seg : Segment2D α) (t : α) : α :=
  match seg with
  | .straight _ _ _ => 0
  | .arc r _ _ _ _ _ => t / r
  | .transitionIn r _ _ _ len _ => (1 / r) / len * t * t / natToScalar 2
  | .transitionOut r _ _ _ len _ => t / r - (1 / r) / len * t * t / natToScalar 2

/-- Sample the 2D position at local arc-length `t` along a segment.

Uses linear interpolation for straights, exact analytic trigonometry for circular arcs, and
Gauss–Legendre quadrature (`clothoidPoint2D`) for clothoid transitions. -/
def Segment2D.pointAt [TrackScalar α] (seg : Segment2D α) (t : α) : Vec2 α :=
  match seg with
  | .straight p q _ =>
    let len := Vec2.dist p q
    let frac := if len = 0 then 0 else t / len
    Vec2.lerp p q frac
  | .arc r p v dir _ _ =>
    let θ := t / r
    let xL := r * TrackScalar.sin θ
    let yL := r * (1 - TrackScalar.cos θ)
    let vUnit := Vec2.normalize v
    let nUnit := dir.normal vUnit
    p + xL • vUnit + yL • nUnit
  | .transitionIn r p v dir len _ =>
    clothoidPoint2D p v dir 0 (1 / r) len t
  | .transitionOut r p v dir len _ =>
    clothoidPoint2D p v dir (1 / r) 0 len t

/-- Sample the unit tangent vector at local arc-length `t` along a 2D segment. -/
def Segment2D.tangentAt [TrackScalar α] (seg : Segment2D α) (t : α) : Vec2 α :=
  match seg with
  | .straight p q _ => Vec2.normalize (q - p)
  | .arc r _ v dir _ _ => dir.rotate (t / r) (Vec2.normalize v)
  | .transitionIn r _ v dir len _ =>
    dir.rotate ((1 / r) / len * t * t / natToScalar 2) (Vec2.normalize v)
  | .transitionOut r _ v dir len _ =>
    dir.rotate (t / r - (1 / r) / len * t * t / natToScalar 2) (Vec2.normalize v)

/-- Sample the unsigned curvature magnitude at local arc-length `t` along a 2D segment. -/
def Segment2D.curvatureAt [TrackScalar α] (seg : Segment2D α) (t : α) : α :=
  match seg with
  | .straight _ _ _ => 0
  | .arc r _ _ _ _ _ => 1 / r
  | .transitionIn r _ _ _ len _ => (1 / r) / len * t
  | .transitionOut r _ _ _ len _ => 1 / r - (1 / r) / len * t

/-- Sample the signed curvature at local arc-length `t` along a 2D segment, positive on left
turns and negative on right turns. -/
def Segment2D.signedCurvatureAt [TrackScalar α] (seg : Segment2D α) (t : α) : α :=
  match seg with
  | .straight _ _ _ => 0
  | .arc _ _ _ dir _ _ => dir.sign * seg.curvatureAt t
  | .transitionIn _ _ _ dir _ _ => dir.sign * seg.curvatureAt t
  | .transitionOut _ _ _ dir _ _ => dir.sign * seg.curvatureAt t

/-- Directional and angular geometry for one interior 2D PI with a principal deflection in
`(0, π)`, independent of any chosen tangent budget. -/
structure CornerGeometry2D (α : Type) where
  /-- Unit direction along the incoming leg, pointing into the PI. -/
  uIn : Vec2 α
  /-- Unit direction along the outgoing leg, pointing away from the PI. -/
  uOut : Vec2 α
  /-- Turn handedness (`left` or `right`) of the principal deflection. -/
  turnDir : TurnDir
  /-- Signed `sin Δ` of the principal deflection (positive for a left turn). -/
  sinSigned : α
  /-- Cosine `cos Δ` of the principal deflection. -/
  cosDelta : α
  /-- Half-angle tangent `tan(Δ / 2)` of the principal deflection (strictly positive). -/
  tanHalf : α
  /-- Principal deflection angle `Δ` in `(0, π)`. -/
  delta : α
  /-- Length of the shorter adjacent leg. -/
  shorterLeg : α
  /-- Minimum tangent budget required to satisfy `minRadius`, before clamping to leg room. -/
  floorBudget : α

/-- Extract the scalar budget specification needed by `desiredBudgets` and `cornerDragBounds`. -/
def CornerGeometry2D.budgetSpec (g : CornerGeometry2D α) : CornerBudgetSpec α :=
  { shorterLeg := g.shorterLeg, floorBudget := g.floorBudget }

/-- Compute the entry tangent point (start of the curved corner) for `budget` at PI `b`. -/
def CornerGeometry2D.entryPoint [TrackScalar α] (g : CornerGeometry2D α) (b : Vec2 α)
    (budget : α) : Vec2 α :=
  b - budget • g.uIn

/-- Compute the exit tangent point (end of the curved corner) for `budget` at PI `b`. -/
def CornerGeometry2D.exitPoint [TrackScalar α] (g : CornerGeometry2D α) (b : Vec2 α)
    (budget : α) : Vec2 α :=
  b + budget • g.uOut

/-- Compute shared 2D corner geometry for an interior PI `b` between `a` and `c`.

Handles principal deflections `0 < Δ < π` only (no winding): returns `none` when either
adjacent leg has zero length or when the deflection is near-straight or a 180-degree
reversal (`|sin Δ| ≤ straightThreshold` or `Δ ≤ straightThreshold`). -/
def cornerGeometry2D [TrackScalar α] (a b c : Vec2 α)
    (lp : LayoutPolicy α) (sm : SpeedModel α) (straightThreshold : α) :
    Option (CornerGeometry2D α) :=
  let dIn := b - a
  let dOut := c - b
  let nIn := Vec2.norm dIn
  let nOut := Vec2.norm dOut
  if nIn = 0 ∨ nOut = 0 then none
  else
    let uIn := (1 / nIn) • dIn
    let uOut := (1 / nOut) • dOut
    let sinSigned := Vec2.cross uIn uOut
    let sinAbs := absScalar sinSigned
    let cosD := max (-1) (min 1 (Vec2.dot uIn uOut))
    let delta := TrackScalar.arccos cosD
    if sinAbs ≤ straightThreshold ∨ delta ≤ straightThreshold then none
    else
      let dir : TurnDir := if sinSigned < 0 then .right else .left
      let shorter := min nIn nOut
      let cosT := TrackScalar.cos delta
      let tanHalf := TrackScalar.sin delta / (1 + cosT)
      let floor := radiusFloorBudget lp sm tanHalf delta
      some { uIn := uIn, uOut := uOut, turnDir := dir, sinSigned := sinSigned,
             cosDelta := cosD, tanHalf := tanHalf, delta := delta,
             shorterLeg := shorter, floorBudget := floor }

/-- A solved 2D corner at one interior PI, with its tangent endpoints and ordered curved
segments. -/
structure CornerSolution2D (α : Type) where
  /-- Point where the incoming straight ends and the corner begins. -/
  entryPoint : Vec2 α
  /-- Point where the corner ends and the outgoing straight resumes. -/
  exitPoint : Vec2 α
  /-- Ordered curved segments through the corner. -/
  pieces : Array (Segment2D α)
  /-- Design operating speed for the corner (`0` when the speed model is disabled). -/
  opSpeed : α
  /-- Fitted unsigned circular arc radius. -/
  radius : α

/-- Construct the 2D segments for a corner from solved scalar `CornerParams` and
precomputed `CornerGeometry2D`, without depending on `SpeedModel`. -/
def buildCorner2D [TrackScalar α] (b : Vec2 α) (budget : α)
    (g : CornerGeometry2D α) (cp : CornerParams α) (straightThreshold : α) :
    CornerSolution2D α :=
  let uIn := g.uIn
  let dir := g.turnDir
  let entryBase := g.entryPoint b budget
  if cp.spiralAngle ≤ 0 then
    let absR := cp.radius
    let pc := entryBase
    let arcSeg := Segment2D.arc absR pc uIn dir cp.arcAngle cp.opSpeed
    let pt := arcSeg.pointAt arcSeg.length
    { entryPoint := pc, exitPoint := pt, opSpeed := cp.opSpeed, radius := absR,
      pieces := #[arcSeg] }
  else
    let absR := cp.radius
    let θs := cp.spiralAngle
    let Ls := cp.spiralLength
    let φ := cp.arcAngle
    let opSpeed := cp.opSpeed
    let ts := entryBase
    let sc := clothoidPoint2D ts uIn dir 0 (1 / absR) Ls Ls
    let tanSC := dir.rotate θs uIn
    let entrySeg := Segment2D.transitionIn absR ts uIn dir Ls opSpeed
    if φ ≤ straightThreshold then
      let exitSeg := Segment2D.transitionOut absR sc tanSC dir Ls opSpeed
      { entryPoint := ts, exitPoint := exitSeg.pointAt Ls, pieces := #[entrySeg, exitSeg],
        opSpeed := opSpeed, radius := absR }
    else
      let arcSeg := Segment2D.arc absR sc tanSC dir φ opSpeed
      let cs := arcSeg.pointAt arcSeg.length
      let tanCS := dir.rotate φ tanSC
      let exitSeg := Segment2D.transitionOut absR cs tanCS dir Ls opSpeed
      { entryPoint := ts, exitPoint := exitSeg.pointAt Ls,
        pieces := #[entrySeg, arcSeg, exitSeg], opSpeed := opSpeed, radius := absR }

/-- Solve a non-degenerate 2D corner from precomputed `CornerGeometry2D` by delegating
scalar parameter solving to `solveCornerParams` and 2D segment assembly to `buildCorner2D`. -/
def solveCornerWithGeometry2D [TrackScalar α] (b : Vec2 α) (budget : α)
    (sm : SpeedModel α) (straightThreshold : α) (g : CornerGeometry2D α) :
    CornerSolution2D α :=
  let cp := solveCornerParams budget g.tanHalf g.delta sm straightThreshold
  buildCorner2D b budget g cp straightThreshold

/-- A flat sequence of 2D horizontal alignment segments. -/
structure AlignmentPath2D (α : Type) where
  /-- Ordered segments making up the alignment path. -/
  segments : Array (Segment2D α)

/-- Compute the total arc-length of a 2D alignment path as the sum of its segment lengths. -/
def AlignmentPath2D.length [TrackScalar α] (path : AlignmentPath2D α) : α :=
  path.segments.foldl (fun acc seg => acc + seg.length) 0

/-- Walk segments to global arc-length `s` and sample with `f` at the local parameter,
returning `none` when `s` is out of range. -/
def AlignmentPath2D.sampleAt [TrackScalar α]
    (f : Segment2D α → α → β) (path : AlignmentPath2D α) (s : α) : Option β :=
  if s < 0 then none
  else
    let rec go (segs : List (Segment2D α)) (t : α) : Option β :=
      match segs with
      | [] => none
      | seg :: rest =>
        let len := seg.length
        if t ≤ len then some (f seg t) else go rest (t - len)
    go path.segments.toList s

/-- Sample the 2D position at global arc-length `s`, or `none` if out of range. -/
def AlignmentPath2D.pointAt [TrackScalar α] (path : AlignmentPath2D α) (s : α) : Option (Vec2 α) :=
  path.sampleAt (fun seg t => seg.pointAt t) s

/-- Sample the 2D unit tangent vector at global arc-length `s`, or `none` if out of range. -/
def AlignmentPath2D.tangentAt [TrackScalar α] (path : AlignmentPath2D α) (s : α) : Option (Vec2 α) :=
  path.sampleAt (fun seg t => seg.tangentAt t) s

/-- Sample the unsigned curvature magnitude at global arc-length `s`, or `none` if out of range. -/
def AlignmentPath2D.curvatureAt [TrackScalar α] (path : AlignmentPath2D α) (s : α) : Option α :=
  path.sampleAt (fun seg t => seg.curvatureAt t) s

/-- Compute the Euclidean length of each leg (`k` from PI `k` to PI `k + 1`) of a 2D polyline. -/
def polylineLegLengths2D [TrackScalar α] (pts : Array (Vec2 α)) : Array α :=
  let n := pts.size
  let z : Vec2 α := Vec2.mk 0 0
  let get := fun i => (pts[i]?).getD z
  (Array.range (n - 1)).map fun k => Vec2.norm (get (k + 1) - get k)

/-- Build a 2D horizontal `AlignmentPath2D` from a polyline of PIs.

The first and last PIs are endpoints. Each interior PI with a principal deflection in
`(0, π)` is rounded with a circular arc (and symmetric clothoid transitions when `sm` is
enabled), using `desiredBudgets`, `resolveSharedLegs`, `solveCornerParams`, and
`buildCorner2D`. Near-collinear, 180-degree, or degenerate corners pass straight through.

`overrides` optionally supplies a per-PI tangent budget in world units that replaces the
automatic budget at that corner. -/
def buildPath2D [TrackScalar α] (pts : Array (Vec2 α))
    (lp : LayoutPolicy α) (sm : SpeedModel α) (straightThreshold : α)
    (overrides : Array (Option α) := #[]) :
    AlignmentPath2D α :=
  let n := pts.size
  if n < 2 then ⟨#[]⟩
  else
    let z : Vec2 α := Vec2.mk 0 0
    let get := fun i => (pts[i]?).getD z
    let straightSpeed := if sm.maxDesignSpeed > 0 then sm.maxDesignSpeed else 0
    let legLengths := polylineLegLengths2D pts
    let geoms : Array (Option (CornerGeometry2D α)) := (Array.range n).map fun i =>
      if 1 ≤ i ∧ i + 1 < n then
        cornerGeometry2D (get (i - 1)) (get i) (get (i + 1)) lp sm straightThreshold
      else none
    let specs : Array (Option (CornerBudgetSpec α)) :=
      geoms.map (·.map CornerGeometry2D.budgetSpec)
    let asks := desiredBudgets legLengths specs lp overrides
    let budgets := resolveSharedLegs legLengths asks
    let out : Array (Segment2D α) := Id.run do
      let mut acc : Array (Segment2D α) := #[]
      let mut cursor : Vec2 α := get 0
      for i in [1 : n - 1] do
        let b := get i
        match (geoms[i]?).bind id, (budgets[i]?).bind id with
        | some g, some bud =>
          let sol := solveCornerWithGeometry2D b bud sm straightThreshold g
          acc := acc.push (Segment2D.straight cursor sol.entryPoint straightSpeed)
          for piece in sol.pieces do
            acc := acc.push piece
          cursor := sol.exitPoint
        | _, _ => pure ()
      acc := acc.push (Segment2D.straight cursor (get (n - 1)) straightSpeed)
      return acc
    ⟨out⟩
