/-! ## Scalar typeclass for track geometry

`TrackScalar α` captures everything we need from a scalar type to do track geometry:
basic arithmetic, order, trig functions, and square roots. Clothoid offsets are
obtained by Gauss–Legendre quadrature over these primitives, so no special
integral functions are needed in the interface.

We deliberately extend only the individual operation typeclasses that both `ℝ` and
`Float` satisfy, avoiding `Field` and `LinearOrder` (which `Float` doesn't satisfy).

`Zero`/`One` give us `0`/`1` literals. We avoid `2` in generic code (use `1+1` instead)
because `OfNat α 2` can't be a superclass (value parameter).

`DecidableEq`/`DecidableRel` are NOT superclasses (they're `abbrev`s, not `class`es),
but we provide them as fields and derive global instances below.
-/

class TrackScalar (α : Type) extends
  Add α, Sub α, Mul α, Div α, Neg α,
  Zero α, One α,
  LT α, LE α, Max α, Min α where
  cos : α → α
  sin : α → α
  arccos : α → α
  sqrt : α → α
  pi : α
  beq : α → α → Bool
  decEq : (a b : α) → Decidable (a = b)
  decLe : (a b : α) → Decidable (a ≤ b)
  decLt : (a b : α) → Decidable (a < b)

/-- Every `TrackScalar` carries decidability of equality and order. -/
instance [h : TrackScalar α] : DecidableEq α := h.decEq
instance [h : TrackScalar α] : DecidableRel (· ≤ · : α → α → Prop) := h.decLe
instance [h : TrackScalar α] : DecidableRel (· < · : α → α → Prop) := h.decLt

/-! ## 3D vector type

`Vec3 α` is `Fin 3 → α` — three components of scalar type `α`.
Use `Vec3.mk x y z` to construct vectors.
All arithmetic (`+`, `-`, `•`, etc.) comes from the `Pi` instances automatically.
-/

def Vec3 (α : Type) := Fin 3 → α

namespace Vec3

variable {α : Type}

-- Explicit instances: `Vec3 α` is reducible to `Fin 3 → α`, but Pi instances for
-- `HAdd`/`HSub`/`HSMul` aren't reliably found, so we provide our own.
instance [Add α] : Add (Vec3 α) := ⟨λ v w i => v i + w i⟩
instance [Sub α] : Sub (Vec3 α) := ⟨λ v w i => v i - w i⟩
instance [Neg α] : Neg (Vec3 α) := ⟨λ v i => -v i⟩
instance [Mul α] : SMul α (Vec3 α) := ⟨λ r v i => r * v i⟩

/-- Construct a vector from three components. -/
def mk (x y z : α) : Vec3 α := fun i => if i = 0 then x else if i = 1 then y else z

/-- Dot product. -/
def dot [Add α] [Mul α] (v w : Vec3 α) : α := (v 0 * w 0) + (v 1 * w 1) + (v 2 * w 2)

/-- Squared Euclidean norm (avoids sqrt when not needed). -/
def normSq [Add α] [Mul α] (v : Vec3 α) : α := dot v v

/-- Euclidean norm. -/
def norm [TrackScalar α] (v : Vec3 α) : α := TrackScalar.sqrt (normSq v)

/-- Euclidean distance. -/
def dist [TrackScalar α] (v w : Vec3 α) : α := norm (v - w)

/-- Rotate 90° counterclockwise in the XY-plane, preserving Z. -/
def perp [Neg α] (v : Vec3 α) : Vec3 α := mk (-v 1) (v 0) (v 2)

/-- Full 3D cross product. -/
def cross [Mul α] [Add α] [Sub α] (v w : Vec3 α) : Vec3 α :=
  mk (v 1 * w 2 - v 2 * w 1) (v 2 * w 0 - v 0 * w 2) (v 0 * w 1 - v 1 * w 0)

/-- Z-component of the 3D cross product (signed magnitude of the 2D cross product).
    Positive when `w` is counterclockwise from `v` in the XY-plane. -/
def crossZ [Mul α] [Add α] [Sub α] (v w : Vec3 α) : α := (cross v w) 2

/-- Linear interpolation: `lerp p q t = p + t • (q - p)`. -/
def lerp [Add α] [Sub α] [SMul α (Vec3 α)] (p q : Vec3 α) (t : α) : Vec3 α := p + t • (q - p)

end Vec3

/-! ## Geometric helpers -/

/-- Determine whether three points are (approximately) collinear, within a threshold.
    Checks if the 2D cross product `(q-p) × (r-p)` (z-component) is within `[-threshold, threshold]`. -/
def collinear [TrackScalar α] (p q r : Vec3 α) (threshold : α) : Bool :=
  let a := Vec3.crossZ (q - p) (r - p)
  decide (-threshold ≤ a) && decide (a ≤ threshold)

/-! ## Track geometry types

All types are parametric in the scalar type `α`. The `[TrackScalar α]` constraint is
only needed on functions that do arithmetic; the data types themselves carry no constraint.
-/

inductive TransitionCurveType where
  | clothoid
  -- | cubicParabola
  -- | cubicParabolaJP
  -- | bloss
  -- | sinusoidal
  -- | viennese
  -- | custom
deriving Repr

/- Geometric continuity classifies how smoothly two curves meet at a joint.
  G^0: positional continuity (no gap)
  G^1: tangent continuity
  G^2: curvature continuity (same osculating circle)
  G^3: continuity of the derivative of curvature
  G^∞: infinite continuity (e.g. two straight lines meeting) -/
inductive GeometricContinuity : Type where
  | gn : Nat → GeometricContinuity
  | gInf : GeometricContinuity

/- Curvature at a point along an alignment.
  `straight` means zero curvature (infinite radius).
  `curved r` means the track follows a circular arc of radius `r` at this point.
  Storing radius (not curvature κ = 1/r) because it's more natural for railway design. -/
inductive Curvature (α : Type) where
  | straight
  | curved (radius : α)

/- A segment connects two points in the alignment, classified by the curvatures at
  its start and end. The type indices enforce that only valid curvature transitions exist.

  Geometry is derived from essential parameters:
  - `straight`: defined by startPt and endPt (length is computed as distance)
  - `arc`: defined by radius, startPt, endPt, and startTangent (center is derived)
  - `transitionIn`: defined by radius, startPt, startTangent, and length
  - `transitionOut`: defined by radius, startPt, startTangent, and length -/
inductive Segment (α : Type) : Curvature α → Curvature α → Type where
  | straight (startPt endPt : Vec3 α) : Segment α .straight .straight
  | arc (radius : α) (startPt endPt : Vec3 α) (startTangent : Vec3 α) :
      Segment α (.curved radius) (.curved radius)
  | transitionIn (radius : α) (continuity : GeometricContinuity := .gn 2)
      (startPt startTangent : Vec3 α) (length : α)
      (curveType : TransitionCurveType := .clothoid) :
      Segment α .straight (.curved radius)
  | transitionOut (radius : α) (continuity : GeometricContinuity := .gn 2)
      (startPt startTangent : Vec3 α) (length : α)
      (curveType : TransitionCurveType := .clothoid) :
      Segment α (.curved radius) .straight

/-! ## Tangent direction after a segment -/

/-- Tangent direction at the end of a straight segment from `p` to `q`.
    Simply `q - p`. -/
def straightEndTangent {α : Type} [Sub α] (p q : Vec3 α) : Vec3 α := q - p

/-- Tangent direction at the end of a circular arc.
    Given the center, endpoint, and radius, the tangent is perpendicular
    to the radius vector, oriented consistently with the arc direction. -/
def arcEndTangent [TrackScalar α] (center q : Vec3 α) (r : α) : Vec3 α :=
  let radial := q - center
  if r > 0 then
    Vec3.perp radial
  else
    Vec3.mk (radial 1) (-radial 0) (radial 2)

/-- Compute the center of the circle through `p` with tangent `v` at `p`
    and given signed radius `r`. -/
def circleCenter [TrackScalar α] (p v : Vec3 α) (r : α) : Vec3 α :=
  let n := Vec3.perp v
  p + (r / Vec3.norm v) • n

/-- Rotate a vector by angle `φ` in the XY-plane (counterclockwise for `φ > 0`),
    preserving the Z component. -/
def Vec3.rotateXY [TrackScalar α] (φ : α) (v : Vec3 α) : Vec3 α :=
  let c := TrackScalar.cos φ
  let s := TrackScalar.sin φ
  Vec3.mk (c * v 0 - s * v 1) (s * v 0 + c * v 1) (v 2)

/-- Arc length given center, endpoints, and radius. Uses arccos of the angle between
    radial vectors. -/
def arcLength [TrackScalar α] (center startPt endPt : Vec3 α) (r : α) : α :=
  let v1 := startPt - center
  let v2 := endPt - center
  let absR := if r > 0 then r else -r
  let dotProd := Vec3.dot v1 v2
  let normSq := Vec3.normSq v1
  let cosθ := if normSq = 0 then 1 else dotProd / normSq
  let cosθ' := max (-1) (min 1 cosθ)
  absR * TrackScalar.arccos cosθ'

/-- Extract the length of any segment. -/
def Segment.length [TrackScalar α] {cA cB : Curvature α} : Segment α cA cB → α
  | .straight startPt endPt => Vec3.dist startPt endPt
  | .arc radius startPt endPt startTangent =>
    -- Derive the center and compute arc length
    let center := circleCenter startPt startTangent radius
    arcLength center startPt endPt radius
  | .transitionIn _ _ _ _ len _ => len
  | .transitionOut _ _ _ _ len _ => len

/- An alignment is a non-empty sequence of segments with matching curvature types
  at the joins. `RailwayAlignment α cA cB` starts with curvature `cA` and ends with `cB`.
  Every segment carries its own geometry, so the alignment is ready to sample from. -/
inductive RailwayAlignment (α : Type) : Curvature α → Curvature α → Type where
  | single : Segment α cA cB → RailwayAlignment α cA cB
  | append : RailwayAlignment α cA cB → Segment α cB cC → RailwayAlignment α cA cC

/-- Total arc-length of an alignment (recursively sum segment lengths). -/
def RailwayAlignment.length {α : Type} [TrackScalar α] {cA cB : Curvature α} :
    RailwayAlignment α cA cB → α
  | .single seg => seg.length
  | .append al seg => al.length + seg.length

/-! ## Transition curve evaluation -/

/-- `natToScalar` injects a `Nat` into `α` by repeated addition from `Zero`/`One`.
    O(n), but only ever called on small constants (quadrature orders, panel counts).
    Lets generic `[TrackScalar α]` code use integer literals beyond `0`/`1` without an
    `OfNat` superclass. -/
def natToScalar [TrackScalar α] : Nat → α
  | 0 => 0
  | n + 1 => natToScalar n + 1

/-! ### Gauss–Legendre quadrature

We evaluate clothoid offsets by integrating the unit tangent `(cos θ(u), sin θ(u))`
directly, rather than reducing to Fresnel integrals. The heading is the running
turn angle `θ(u) = κ₀·u + ½·κ'·u²` of a linearly-varying-curvature transition.

The integrator is a **composite 3-point Gauss–Legendre rule**: `[0, s]` is split into
`clothoidPanels` equal panels and the 3-point rule (exact for quintics) is applied on
each. The 3-point data — nodes `±√(3/5)`, `0` with weights `5/9, 8/9, 5/9` — is built
from `0`, `1`, division and `sqrt`, so the whole thing stays generic over any
`TrackScalar` (no decimal literals required) and needs no Fresnel primitives. -/

/-- Number of equal panels used by the composite Gauss–Legendre clothoid integrator.
    16 panels of a quintic-exact rule resolve any realistic transition (total turn
    angle well under a full turn) to far better than float precision. -/
def clothoidPanels : Nat := 16

/-- Integrate `(cos θ(u), sin θ(u))` over `u ∈ [0, s]` with composite 3-point
    Gauss–Legendre quadrature, where `θ(u) = κ₀·u + ½·κ'·u²`. Returns the local
    offset `(xLocal, yLocal)` — displacement along and perpendicular to the start
    tangent. -/
def clothoidOffset [TrackScalar α] (κ₀ κ' s : α) (panels : Nat) : α × α :=
  let two   : α := natToScalar 2
  let node  : α := TrackScalar.sqrt (natToScalar 3 / natToScalar 5)  -- √(3/5)
  let wSide : α := natToScalar 5 / natToScalar 9                     -- 5/9
  let wMid  : α := natToScalar 8 / natToScalar 9                     -- 8/9
  let h     : α := s / natToScalar panels
  let half  : α := h / two
  let heading : α → α := fun u => κ₀ * u + (κ' * u * u) / two
  Id.run do
    let mut sumC : α := 0
    let mut sumS : α := 0
    for k in [0:panels] do
      let m  : α := natToScalar k * h + half          -- panel midpoint
      let u0 : α := m - half * node
      let u2 : α := m + half * node
      sumC := sumC + wSide * TrackScalar.cos (heading u0)
                   + wMid  * TrackScalar.cos (heading m)
                   + wSide * TrackScalar.cos (heading u2)
      sumS := sumS + wSide * TrackScalar.sin (heading u0)
                   + wMid  * TrackScalar.sin (heading m)
                   + wSide * TrackScalar.sin (heading u2)
    return (half * sumC, half * sumS)

/-- Evaluate a point along a clothoid transition at arc-length `s` (0 ≤ s ≤ L).

    - `p`: start point
    - `v`: start tangent direction
    - `κ₀`: start curvature
    - `κ₁`: end curvature
    - `L`: total length of the transition
    - `s`: arc-length parameter

    Curvature varies linearly: κ(s) = κ₀ + (κ₁ - κ₀)·s/L, so the heading at distance
    `u` is θ(u) = κ₀·u + ½·κ'·u² with κ' = (κ₁ - κ₀)/L. The position is the integral
    ∫₀ˢ (cos θ(u), sin θ(u)) du in the local frame `(v̂, n̂)`, evaluated by
    Gauss–Legendre quadrature. This single expression covers the straight (κ ≡ 0),
    circular (κ' = 0) and genuine-clothoid cases without special-casing — the heading
    integral degenerates correctly on its own. -/
def clothoidPoint [TrackScalar α] (p v : Vec3 α) (κ₀ κ₁ L s : α) : Vec3 α :=
  let κ' := (κ₁ - κ₀) / L
  let (xLocal, yLocal) := clothoidOffset κ₀ κ' s clothoidPanels
  let vNormSq := Vec3.normSq v
  let vUnit := if vNormSq = 0 then v else (1 / TrackScalar.sqrt vNormSq) • v
  let nUnit := Vec3.perp vUnit
  p + xLocal • vUnit + yLocal • nUnit

/-- Evaluate a point along a transition curve at arc-length `s` (0 ≤ s ≤ L). -/
def transitionPoint [TrackScalar α]
    (p v : Vec3 α) (κ₀ κ₁ L s : α) (type : TransitionCurveType) : Vec3 α :=
  match type with
  | .clothoid => clothoidPoint p v κ₀ κ₁ L s

/-- Sample a point at arc-length `t` along a single segment.
    Assumes `0 ≤ t ≤ seg.length`. -/
def Segment.pointAt [TrackScalar α] {cA cB : Curvature α}
    (seg : Segment α cA cB) (t : α) : Vec3 α :=
  match seg with
  | .straight p q =>
    let len := Vec3.dist p q
    let frac := if len = 0 then 0 else t / len
    Vec3.lerp p q frac
  | .arc r p q v =>
    -- Derive the center from the start point, tangent, and radius
    let center := circleCenter p v r
    let absR := if r > 0 then r else -r
    let theta := if absR = 0 then 0 else t / absR
    let angle := if r > 0 then theta else -theta
    let radialStart := p - center
    let cosA := TrackScalar.cos angle
    let sinA := TrackScalar.sin angle
    let rotated : Vec3 α :=
      Vec3.mk (cosA * radialStart 0 - sinA * radialStart 1)
              (sinA * radialStart 0 + cosA * radialStart 1)
              (radialStart 2)
    center + rotated
  | .transitionIn r _ p v len cType =>
    transitionPoint p v 0 (1 / r) len t cType
  | .transitionOut r _ p v len cType =>
    transitionPoint p v (1 / r) 0 len t cType

/-- Sample a point at arc-length `s` along a `RailwayAlignment`.

    Returns `none` if `s` is out of range (s < 0 or s > totalLength).
    Walks the alignment recursively. -/
def RailwayAlignment.pointAt [TrackScalar α] {cA cB : Curvature α}
    (align : RailwayAlignment α cA cB) (s : α) : Option (Vec3 α) :=
  if s < 0 then none else go align s
where
  go {cA cB : Curvature α} (al : RailwayAlignment α cA cB) (t : α) : Option (Vec3 α) :=
    match al with
    | .single seg =>
      if t ≤ seg.length then some (seg.pointAt t) else none
    | .append al' seg =>
      let prevLen := al'.length
      if t ≤ prevLen then
        go al' t
      else
        let localT := t - prevLen
        if localT ≤ seg.length then some (seg.pointAt localT) else none

/-! ## PI-based (Point of Intersection) construction

The user places PIs — vertices of a tangent polyline. The alignment runs straight
along the legs and rounds each *interior* corner with a circular arc tangent to both
legs. The first and last PI are true endpoints (on the alignment); interior PIs are
cut (the arc misses them).

Radius is not supplied. Each corner gets a tangent *budget* — a fraction of the
shorter adjacent leg. Since the tangent pullback is `T = R·tan(Δ/2)`, the radius is
whatever fits the budget: `R = T / tan(Δ/2)`. Sharp corners get a small radius,
gentle corners a large one; near-straight corners are skipped entirely.

This produces an `AlignmentPath`: a flat array of type-correct segments with the
*join* continuity erased. Transitions/clothoids — and graduation back to the fully
join-indexed `RailwayAlignment` — come in a later step. -/

/-- A single geometry piece with its curvature indices hidden, so heterogeneous
    segments can share one array. -/
structure AnySegment (α : Type) where
  cA : Curvature α
  cB : Curvature α
  seg : Segment α cA cB

/-- Wrap a segment, inferring its curvature indices. -/
def AnySegment.of {α : Type} {cA cB : Curvature α} (s : Segment α cA cB) : AnySegment α :=
  ⟨cA, cB, s⟩

/-- Arc-length of the underlying segment. -/
def AnySegment.length [TrackScalar α] (e : AnySegment α) : α := e.seg.length

/-- Sample the underlying segment at local arc-length `t`. -/
def AnySegment.pointAt [TrackScalar α] (e : AnySegment α) (t : α) : Vec3 α := e.seg.pointAt t

/-- A flat sequence of geometry pieces (straights and arcs), join continuity erased. -/
structure AlignmentPath (α : Type) where
  segments : Array (AnySegment α)

/-- Total arc-length: sum of the piece lengths. -/
def AlignmentPath.length [TrackScalar α] (path : AlignmentPath α) : α :=
  path.segments.foldl (fun acc e => acc + e.length) 0

/-- Sample at global arc-length `s`, walking the pieces. `none` if out of range. -/
def AlignmentPath.pointAt [TrackScalar α] (path : AlignmentPath α) (s : α) : Option (Vec3 α) :=
  if s < 0 then none
  else
    let rec go (segs : List (AnySegment α)) (t : α) : Option (Vec3 α) :=
      match segs with
      | [] => none
      | e :: rest =>
        let len := e.length
        if t ≤ len then some (e.pointAt t) else go rest (t - len)
    go path.segments.toList s

/-- Design parameters for auto-radius PI construction. -/
structure DesignParams (α : Type) where
  /-- Fraction (≤ 0.5) of the shorter adjacent leg a single corner may consume. -/
  legBudget : α
  /-- Corners whose `|sin Δ|` is below this are treated as straight (no arc). -/
  straightThreshold : α
  /-- Spiral (clothoid) length per unit radius, the `c` in `Ls = c·R`. Equivalently
      the spiral angle is `θs = c/2`, constant across corners (clamped to `Δ/2` on
      sharp corners so a non-negative circular arc always remains). `0` disables
      transitions, recovering a pure straight→arc→straight corner.

      This is a geometric stand-in for the eventual design criterion: at speed `V` a
      clothoid imposes jerk ≈ `V³/(R·Ls)`, so a jerk-limited policy would replace this
      constant with a speed-dependent ratio — the construction below is unchanged. -/
  transitionLengthRatio : α

/-- A solved corner at one interior PI: where the incoming straight ends
    (`entryPoint`), where the outgoing straight resumes (`exitPoint`), and the curved
    `pieces` between them (a circular arc, optionally bracketed by entry/exit clothoids). -/
structure CornerSolution (α : Type) where
  /-- Where the straight leading into the corner ends (start of the first piece). -/
  entryPoint : Vec3 α
  /-- Where the straight leaving the corner begins (end of the last piece). -/
  exitPoint : Vec3 α
  /-- Curved geometry through the corner, in order. -/
  pieces : Array (AnySegment α)

/-- Solve the corner at interior PI `b`, between prev PI `a` and next PI `c`, consuming
    `budget` of tangent length along each leg. Returns `none` when the legs are (near)
    collinear — the corner is straight and contributes nothing.

    With `dp.transitionLengthRatio = 0` this is the classic circular fillet: the tangent
    points sit `budget` back from `b` along each leg and `R = budget / tan(Δ/2)`, so the
    arc is exactly tangent to both legs.

    Otherwise the corner is the standard symmetric spiral: an entry clothoid, a circular
    arc, and an exit clothoid. The spiral angle is `θs = min(c/2, Δ/2)` (`c =
    transitionLengthRatio`). Using the clothoid's shift `p = R·P` and abscissa offset
    `k = R·K` — where `(P, K)` come from a unit clothoid of spiral angle `θs` — the total
    tangent distance is `T = (R + p)·tan(Δ/2) + k`. Holding `T = budget` (so the corner
    fits the leg exactly as before) gives `R = budget / ((1+P)·tan(Δ/2) + K)`, and the
    spiral length is `Ls = 2·R·θs` (= `c·R` when unclamped). -/
def solveCorner [TrackScalar α] (a b c : Vec3 α) (budget : α) (dp : DesignParams α) :
    Option (CornerSolution α) :=
  let dIn := b - a
  let dOut := c - b
  let nIn := Vec3.norm dIn
  let nOut := Vec3.norm dOut
  if nIn = 0 ∨ nOut = 0 then none
  else
    let uIn := (1 / nIn) • dIn
    let uOut := (1 / nOut) • dOut
    let sinSigned := Vec3.crossZ uIn uOut          -- signed sin Δ
    let sinAbs := if sinSigned > 0 then sinSigned else -sinSigned
    if sinAbs ≤ dp.straightThreshold then none
    else
      let two : α := natToScalar 2
      let leftTurn := sinSigned > 0
      let signOf := fun (x : α) => if leftTurn then x else -x
      let cosD := Vec3.dot uIn uOut                 -- cos Δ
      let tanHalf := (1 - cosD) / sinAbs            -- tan(Δ/2) = (1 - cos Δ)/sin Δ
      let Δ := TrackScalar.arccos (max (-1) (min 1 cosD))
      let θs := min (dp.transitionLengthRatio / two) (Δ / two)
      if θs ≤ 0 then
        -- No transitions: classic circular fillet (straight → arc → straight).
        let absR := budget / tanHalf
        let r := signOf absR
        let pc := b - budget • uIn
        let pt := b + budget • uOut
        some { entryPoint := pc, exitPoint := pt,
               pieces := #[AnySegment.of (Segment.arc r pc pt uIn)] }
      else
        -- Symmetric spiral corner. Shift constants from a unit clothoid (R = 1).
        let Ls1 := two * θs
        let (X1, Y1) := clothoidOffset 0 (1 / Ls1) Ls1 clothoidPanels
        let P := Y1 - (1 - TrackScalar.cos θs)
        let K := X1 - TrackScalar.sin θs
        let absR := budget / ((1 + P) * tanHalf + K)
        let r := signOf absR
        let Ls := two * absR * θs
        let ts := b - budget • uIn                    -- entry tangent→spiral point
        let sc := clothoidPoint ts uIn 0 (1 / r) Ls Ls -- entry spiral end = arc start
        let tanSC := Vec3.rotateXY (signOf θs) uIn     -- tangent at sc
        let φ := Δ - two * θs                          -- circular arc central angle (≥ 0)
        let o := circleCenter sc tanSC r               -- arc center
        let cs := o + Vec3.rotateXY (signOf φ) (sc - o) -- arc end = exit spiral start
        let tanCS := Vec3.rotateXY (signOf φ) tanSC     -- tangent at cs
        let entrySeg := AnySegment.of
          (Segment.transitionIn (radius := r) (startPt := ts) (startTangent := uIn)
            (length := Ls))
        let exitSeg := AnySegment.of
          (Segment.transitionOut (radius := r) (startPt := cs) (startTangent := tanCS)
            (length := Ls))
        let pieces :=
          if φ ≤ dp.straightThreshold then #[entrySeg, exitSeg]
          else #[entrySeg, AnySegment.of (Segment.arc r sc cs tanSC), exitSeg]
        some { entryPoint := ts, exitPoint := exitSeg.pointAt Ls, pieces := pieces }

/-- Build an `AlignmentPath` from a polyline of PIs.

    The first and last PIs are endpoints. Each interior PI is rounded with a circular
    arc whose radius fits a tangent budget = `legBudget × (shorter adjacent leg)`.
    Near-collinear corners pass straight through. -/
def buildPath [TrackScalar α] (pts : Array (Vec3 α)) (dp : DesignParams α) : AlignmentPath α :=
  let n := pts.size
  if n < 2 then ⟨#[]⟩
  else
    let z : Vec3 α := Vec3.mk 0 0 0
    let get := fun i => (pts[i]?).getD z
    let out : Array (AnySegment α) := Id.run do
      let mut acc : Array (AnySegment α) := #[]
      let mut cursor : Vec3 α := get 0
      for i in [1 : n - 1] do
        let a := get (i - 1)
        let b := get i
        let c := get (i + 1)
        let budget := dp.legBudget * min (Vec3.dist a b) (Vec3.dist b c)
        match solveCorner a b c budget dp with
        | none => pure ()
        | some sol =>
          acc := acc.push (AnySegment.of (Segment.straight cursor sol.entryPoint))
          for piece in sol.pieces do
            acc := acc.push piece
          cursor := sol.exitPoint
      acc := acc.push (AnySegment.of (Segment.straight cursor (get (n - 1))))
      return acc
    ⟨out⟩

/-- Computable `Float` wrapper. `RFloat` is a newtype around `Float` with structural
    `DecidableEq` (treating `NaN = NaN`), making `TrackScalar RFloat` fully computable
    (unlike raw `Float` which lacks `DecidableEq`).

    Use `⟨x⟩` to wrap a `Float` literal, e.g. `⟨2.0⟩`. -/
structure RFloat where
  val : Float
  deriving Repr

namespace RFloat

/-- `Float.toBits` is injective: a `Float` is uniquely determined by its 64-bit
    IEEE-754 representation (`toBits`/`ofBits` are a bijection). This is true by
    construction, but unprovable in-kernel because `Float`'s payload type is
    `opaque` (see `FloatSpec` in `Init.Data.Float`) — Lean exposes decidable `<`/`≤`
    for `Float` but deliberately no decidable `=`. -/
axiom Float.toBits_inj {a b : Float} (h : a.toBits = b.toBits) : a = b

/-- Computable `DecidableEq` for `RFloat`, deciding propositional equality via the
    underlying bit pattern. Unlike a `Float.beq`-based version, this matches `=`
    exactly: bitwise-identical NaNs are equal, and `+0.0`/`-0.0` are distinct. -/
instance : DecidableEq RFloat := λ a b =>
  if h : a.val.toBits = b.val.toBits then
    isTrue (by cases a; cases b; exact congrArg RFloat.mk (Float.toBits_inj h))
  else
    isFalse (λ hab => h (by rw [hab]))

instance : Add RFloat := ⟨λ a b => ⟨a.val + b.val⟩⟩
instance : Sub RFloat := ⟨λ a b => ⟨a.val - b.val⟩⟩
instance : Mul RFloat := ⟨λ a b => ⟨a.val * b.val⟩⟩
instance : Div RFloat := ⟨λ a b => ⟨a.val / b.val⟩⟩
instance : Neg RFloat := ⟨λ a => ⟨-a.val⟩⟩
instance : Zero RFloat := ⟨⟨0⟩⟩
instance : One RFloat := ⟨⟨1⟩⟩
instance : LT RFloat := ⟨λ a b => a.val < b.val⟩
instance : LE RFloat := ⟨λ a b => a.val ≤ b.val⟩
instance : Max RFloat := ⟨λ a b => ⟨max a.val b.val⟩⟩
instance : Min RFloat := ⟨λ a b => ⟨min a.val b.val⟩⟩

end RFloat

/-- Computable `TrackScalar` instance for `RFloat`. All operations delegate to `Float`.
    Clothoid offsets come from Gauss–Legendre quadrature over these primitives, so no
    Fresnel functions are needed here. -/
instance : TrackScalar RFloat where
  cos x := ⟨Float.cos x.val⟩
  sin x := ⟨Float.sin x.val⟩
  arccos x := ⟨Float.acos x.val⟩
  sqrt x := ⟨Float.sqrt x.val⟩
  pi := ⟨2 * Float.acos 0⟩
  beq a b := Float.beq a.val b.val
  decEq a b := inferInstanceAs (Decidable (a = b))
  decLe a b := Float.decLe a.val b.val
  decLt a b := Float.decLt a.val b.val
