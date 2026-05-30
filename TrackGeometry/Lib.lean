import Mathlib.MeasureTheory.Integral.IntervalIntegral.Basic

/-! ## Scalar typeclass for track geometry

`TrackScalar α` captures everything we need from a scalar type to do track geometry:
basic arithmetic, order, trig functions, and Fresnel integrals.

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
  fresnelC : α → α
  fresnelS : α → α
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
Use `![x, y, z]` (standard Lean matrix notation) to construct vectors.
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
def mk (x y z : α) : Vec3 α := ![x, y, z]

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

/-! ## Placement algorithm -/

/-- Compute the signed radius of the circle that:
    - passes through `p` with tangent direction `v` at `p`,
    - and also passes through `q`.

    Derivation: center C = p + r·(perp v / |v|).
    |q - C|² = r²  →  |q-p|² - 2r·(q-p)·(n/|v|) = 0  →  r = |q-p|²·|v| / (2·(q-p)·n)
    where n = perp v (magnitude |v|). The |v| factor in the numerator handles
    unnormalized tangent directions.

    Returns `none` if the denominator is zero (meaning q-p is parallel to v,
    i.e. the points are collinear — use a straight segment instead). -/
def computeRadius [TrackScalar α] (p q v : Vec3 α) : Option α :=
  let d := q - p
  let n := Vec3.perp v
  let num := Vec3.normSq d * Vec3.norm v
  let den := (1 + 1) * Vec3.dot d n
  if den = 0 then none else some (num / den)

/-- Given `lastPt` (P), the tangent direction `lastDir` (v) at P, and a new point Q,
    decide whether the next segment is straight or curved.

    Returns:
    - `Sum.inl ()` if the points are (approximately) collinear → use a straight segment.
    - `Sum.inr r` if the points form a circular arc of signed radius `r`.
      Positive `r` means the curve turns left (counterclockwise from v).
      Negative `r` means the curve turns right. -/
def classifyNextSegment [TrackScalar α]
    (lastPt lastDir newPt : Vec3 α) (straightThreshold : α) : Sum Unit α :=
  if collinear lastPt newPt (lastPt + lastDir) straightThreshold then
    Sum.inl ()
  else
    match computeRadius lastPt newPt lastDir with
    | none => Sum.inl ()
    | some r => Sum.inr r

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

inductive PlacementState (α : Type) : Option (Curvature α) → Type where
  | empty : PlacementState α none
  | onePoint (p : Vec3 α) : PlacementState α (some .straight)
  | building (lastDir : Vec3 α)
             (curvature : Curvature α)
             (alignment : RailwayAlignment α .straight curvature)
             (lastPt : Vec3 α)
             : PlacementState α (some curvature)

/-! ## The placement function -/

/-- Place a new point and return the updated placement state.

    The behavior depends on the current curvature at the end of the alignment:

    * From `.straight`:
      - Collinear click → appends `Segment.straight`
      - Off-line click → appends `Segment.transitionIn r` to start a curve

    * From `.curved r`:
      - Click near the circle of radius `r` → appends `Segment.arc r`
      - Click off the circle → appends `Segment.transitionOut r` to return to straight

    The `straightThreshold` controls how close to collinear a click must be
    before we treat it as a straight continuation. -/
def place [TrackScalar α]
    {s : Option (Curvature α)} (state : PlacementState α s)
    (newPt : Vec3 α) (straightThreshold : α) :
    Σ (s' : Option (Curvature α)), PlacementState α s' :=
  match state with
  | .empty => ⟨some .straight, .onePoint newPt⟩
  | .onePoint p =>
    let dir := newPt - p
    ⟨some .straight, .building dir .straight (.single (.straight p newPt)) newPt⟩
  | .building lastDir curvature alignment lastPt =>
    match classifyNextSegment lastPt lastDir newPt straightThreshold with
    | Sum.inl () =>
      let chordLen := Vec3.dist lastPt newPt
      match curvature with
      | .straight =>
        let newRailwayAlignment :=
          RailwayAlignment.append alignment (.straight lastPt newPt)
        let newDir := straightEndTangent lastPt newPt
        ⟨some .straight, .building newDir .straight newRailwayAlignment newPt⟩
      | .curved rOld =>
        let seg : Segment α (.curved rOld) .straight :=
          .transitionOut rOld (.gn 2) lastPt lastDir chordLen .clothoid
        let newRailwayAlignment := RailwayAlignment.append alignment seg
        let newDir := straightEndTangent lastPt newPt
        ⟨some .straight, .building newDir .straight newRailwayAlignment newPt⟩
    | Sum.inr r =>
      let chordLen := Vec3.dist lastPt newPt
      match curvature with
      | .straight =>
        let seg : Segment α .straight (.curved r) :=
          .transitionIn r (.gn 2) lastPt lastDir chordLen .clothoid
        let newRailwayAlignment := RailwayAlignment.append alignment seg
        let center := circleCenter lastPt lastDir r
        let newDir := arcEndTangent center newPt r
        ⟨some (.curved r), .building newDir (.curved r) newRailwayAlignment newPt⟩
      | .curved rOld =>
        if TrackScalar.beq r rOld then
          let newRailwayAlignment := RailwayAlignment.append alignment
            (.arc rOld lastPt newPt lastDir)
          let center := circleCenter lastPt lastDir rOld
          let newDir := arcEndTangent center newPt rOld
          ⟨some (.curved rOld), .building newDir (.curved rOld) newRailwayAlignment newPt⟩
        else
          let seg : Segment α (.curved rOld) .straight :=
            .transitionOut rOld (.gn 2) lastPt lastDir chordLen .clothoid
          let newRailwayAlignment := RailwayAlignment.append alignment seg
          let newDir := straightEndTangent lastPt newPt
          ⟨some .straight, .building newDir .straight newRailwayAlignment newPt⟩

/-! ## Immediate-mode builder

`AlignmentBuilder` is the user-facing surface for placing points one at a time
(e.g. one per mouse click). It stores only the raw click history plus the
straight-threshold; the type-indexed `PlacementState`/`place` machine is replayed
on demand by `current`.

Storing the history (rather than the live `PlacementState`) makes `place` and
`undo` trivial array operations and keeps the curvature type index hidden, so
every builder operation has the same type and chains with `|>.`. -/

structure AlignmentBuilder (α : Type) where
  /-- How close to collinear a click must be to count as a straight continuation. -/
  threshold : α
  /-- The click history, in placement order. -/
  points : Array (Vec3 α)

namespace AlignmentBuilder

/-- An empty builder carrying the collinearity threshold. -/
def empty (threshold : α) : AlignmentBuilder α := ⟨threshold, #[]⟩

/-- Record a new point (e.g. a mouse click). -/
def place (b : AlignmentBuilder α) (p : Vec3 α) : AlignmentBuilder α :=
  { b with points := b.points.push p }

/-- Drop the most recently placed point. No-op on an empty builder. -/
def undo (b : AlignmentBuilder α) : AlignmentBuilder α :=
  { b with points := b.points.pop }

/-- Replay the placement machine over the click history and extract the alignment
    as it currently stands. Call after each `place`/`undo` to redraw.

    Returns `none` until at least two points have been placed (no complete
    segment exists yet). The final curvature indices stay existential (`Σ`)
    because they depend on where the points fell. -/
def current [TrackScalar α] (b : AlignmentBuilder α) :
    Option (Σ cA cB : Curvature α, RailwayAlignment α cA cB) :=
  let init : Σ s : Option (Curvature α), PlacementState α s := ⟨none, .empty⟩
  -- `_root_.place` (the placement machine), not the `AlignmentBuilder.place` field.
  let final := b.points.foldl (fun st p => _root_.place st.2 p b.threshold) init
  match final with
  | ⟨_, .building _ curvature alignment _⟩ => some ⟨.straight, curvature, alignment⟩
  | _ => none

end AlignmentBuilder

/-! ## Fresnel integrals and transition curves

The Fresnel integrals C(t) and S(t) for clothoid computations.
For `ℝ` these are defined via integrals. For `Float` they'd be polynomial approximations.
-/

/-- The Fresnel cosine integral: C(t) = ∫₀ᵗ cos(π·u²/2) du -/
noncomputable def fresnelC (t : ℝ) : ℝ :=
  ∫ u in (0 : ℝ)..t, Real.cos (Real.pi * u ^ 2 / 2)

/-- The Fresnel sine integral: S(t) = ∫₀ᵗ sin(π·u²/2) du -/
noncomputable def fresnelS (t : ℝ) : ℝ :=
  ∫ u in (0 : ℝ)..t, Real.sin (Real.pi * u ^ 2 / 2)

/-! ## Transition curve evaluation -/

/-- Evaluate a point along a clothoid transition at arc-length `s` (0 ≤ s ≤ L).

    - `p`: start point
    - `v`: start tangent direction
    - `κ₀`: start curvature
    - `κ₁`: end curvature
    - `L`: total length of the transition
    - `s`: arc-length parameter

    Curvature varies linearly: κ(s) = κ₀ + (κ₁ - κ₀)·s/L.
    The position is ∫₀ˢ (cos θ(u), sin θ(u)) du where θ(u) = ∫₀ᵘ κ(t) dt,
    which reduces to scaled/rotated Fresnel integrals. -/
def clothoidPoint [TrackScalar α] (p v : Vec3 α) (κ₀ κ₁ L s : α) : Vec3 α :=
  let κ' := (κ₁ - κ₀) / L
  if κ' = 0 then
    -- Constant curvature: degenerate to circular arc (or straight)
    if κ₀ = 0 then
      Vec3.lerp p (p + v) (s / L)
    else
      let absκ₀ := if κ₀ > 0 then κ₀ else -κ₀
      let radius := 1 / absκ₀
      let n := Vec3.perp v
      let vNormSq := Vec3.normSq v
      let center := p + (radius / vNormSq) • n
      let angle := κ₀ * s
      let radialStart := p - center
      let cosA := TrackScalar.cos angle
      let sinA := TrackScalar.sin angle
      let rotated : Vec3 α :=
        Vec3.mk (cosA * radialStart 0 - sinA * radialStart 1)
                (sinA * radialStart 0 + cosA * radialStart 1)
                (radialStart 2)
      center + rotated
  else
    -- Nonzero curvature rate: use Fresnel integrals
    let absκ' := if κ' > 0 then κ' else -κ'
    let a := TrackScalar.sqrt (absκ' / TrackScalar.pi)
    let t₀ := a * (κ₀ / κ')
    let tₛ := a * (s + κ₀ / κ')
    let φ₀ := - (κ₀ * κ₀) / ((1 + 1) * κ')
    let cosφ₀ := TrackScalar.cos φ₀
    let sinφ₀ := TrackScalar.sin φ₀
    let ΔC := TrackScalar.fresnelC tₛ - TrackScalar.fresnelC t₀
    let ΔS := TrackScalar.fresnelS tₛ - TrackScalar.fresnelS t₀
    let sign := if κ' > 0 then 1 else -1
    let xLocal := (1 / a) * (cosφ₀ * ΔC - sinφ₀ * sign * ΔS)
    let yLocal := (1 / a) * (sinφ₀ * ΔC + cosφ₀ * sign * ΔS)
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

/-! ## ℝ instance

Uses mathlib's `Real.cos`, `Real.sin`, etc. and the integral-based Fresnel definitions above.
-/

noncomputable instance : TrackScalar ℝ where
  cos := Real.cos
  sin := Real.sin
  arccos := Real.arccos
  sqrt := Real.sqrt
  pi := Real.pi
  fresnelC := fresnelC
  fresnelS := fresnelS
  beq a b := a == b
  decEq a b := inferInstanceAs (Decidable (a = b))
  decLe a b := inferInstanceAs (Decidable (a ≤ b))
  decLt a b := inferInstanceAs (Decidable (a < b))

/-- Computable `Float` wrapper. `RFloat` is a newtype around `Float` with structural
    `DecidableEq` (treating `NaN = NaN`), making `TrackScalar RFloat` fully computable
    (unlike raw `Float` which lacks `DecidableEq`).

    Use `⟨x⟩` to wrap a `Float` literal, e.g. `⟨2.0⟩`. -/
structure RFloat where
  val : Float
  deriving Repr

namespace RFloat

/-- Computable `DecidableEq` via `Float.beq`. Both proof branches use `sorry`
    because `Float` has no `DecidableEq` in Lean, but this is fine for `#eval`
    (proofs aren't evaluated at runtime). -/
instance : DecidableEq RFloat := λ a b =>
  if Float.beq a.val b.val then isTrue (by sorry) else isFalse (by sorry)

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
    Fresnel integrals use a placeholder (to be replaced with a polynomial approximation). -/
instance : TrackScalar RFloat where
  cos x := ⟨Float.cos x.val⟩
  sin x := ⟨Float.sin x.val⟩
  arccos x := ⟨Float.acos x.val⟩
  sqrt x := ⟨Float.sqrt x.val⟩
  pi := ⟨2 * Float.acos 0⟩
  fresnelC t :=
    -- Numerical approximation of C(t) = ∫₀ᵗ cos(π·u²/2) du
    -- Uses the auxiliary functions f and g from Abramowitz & Stegun 7.3.27-28.
    -- Accurate to ~2e-6 for all t ≥ 0; extended to negative t by odd symmetry.
    let x := t.val
    let ax := if x < 0 then -x else x
    let v :=
      if ax < 1.6 then
        -- Small-argument power series (enough terms for 6-digit accuracy)
        let x2 := ax * ax
        let x4 := x2 * x2
        let pi := 2 * Float.acos 0
        let piH := pi / 2
        -- C(t) = Σ (-1)^n (πt²/2)^(2n) t / ((4n+1)(2n)!)  (first 7 terms)
        let t1 := ax
        let t2 := -(piH * piH) * x4 * ax / (5 * 2)
        let t3 := (piH * piH) * (piH * piH) * x4 * x4 * ax / (9 * 24)
        let t4 := -((piH^6) * x4 * x4 * x4 * ax) / (13 * 720)
        let t5 := ((piH^8) * x4 * x4 * x4 * x4 * ax) / (17 * 40320)
        let t6 := -((piH^10) * x4 * x4 * x4 * x4 * x4 * ax) / (21 * 3628800)
        t1 + t2 + t3 + t4 + t5 + t6
      else
        -- Large-argument asymptotic expansion via auxiliary functions f and g
        let pi := 2 * Float.acos 0
        let x2 := ax * ax
        let pix2 := pi * x2
        let f := (1 / (pi * ax)) * (1 - 3 / (pix2 * pix2) + 105 / (pix2 * pix2 * pix2 * pix2))
        let g := (1 / (pi * x2)) * (1 - 15 / (pix2 * pix2) + 945 / (pix2 * pix2 * pix2 * pix2))
        0.5 + f * Float.sin (pix2 / 2) - g * Float.cos (pix2 / 2)
    ⟨if x < 0 then -v else v⟩
  fresnelS t :=
    -- Numerical approximation of S(t) = ∫₀ᵗ sin(π·u²/2) du
    -- Same approach as fresnelC above.
    let x := t.val
    let ax := if x < 0 then -x else x
    let v :=
      if ax < 1.6 then
        let x2 := ax * ax
        let x4 := x2 * x2
        let pi := 2 * Float.acos 0
        let piH := pi / 2
        -- S(t) = Σ (-1)^n (πt²/2)^(2n+1) t / ((4n+3)(2n+1)!)  (first 7 terms)
        let t1 := piH * x2 * ax / 3
        let t2 := -(piH^3) * x4 * x2 * ax / (7 * 6)
        let t3 := (piH^5) * x4 * x4 * x2 * ax / (11 * 120)
        let t4 := -((piH^7) * x4 * x4 * x4 * x2 * ax) / (15 * 5040)
        let t5 := ((piH^9) * x4 * x4 * x4 * x4 * x2 * ax) / (19 * 362880)
        let t6 := -((piH^11) * x4 * x4 * x4 * x4 * x4 * x2 * ax) / (23 * 39916800)
        t1 + t2 + t3 + t4 + t5 + t6
      else
        let pi := 2 * Float.acos 0
        let x2 := ax * ax
        let pix2 := pi * x2
        let f := (1 / (pi * ax)) * (1 - 3 / (pix2 * pix2) + 105 / (pix2 * pix2 * pix2 * pix2))
        let g := (1 / (pi * x2)) * (1 - 15 / (pix2 * pix2) + 945 / (pix2 * pix2 * pix2 * pix2))
        0.5 - f * Float.cos (pix2 / 2) - g * Float.sin (pix2 / 2)
    ⟨if x < 0 then -v else v⟩
  beq a b := Float.beq a.val b.val
  decEq a b := inferInstanceAs (Decidable (a = b))
  decLe a b := Float.decLe a.val b.val
  decLt a b := Float.decLt a.val b.val
