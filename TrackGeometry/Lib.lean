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

/-- Unit vector in the direction of `v`. Returns `v` unchanged if it has zero length,
    so callers never divide by zero. -/
def normalize [TrackScalar α] (v : Vec3 α) : Vec3 α :=
  let n2 := normSq v
  if n2 = 0 then v else (1 / TrackScalar.sqrt n2) • v

/-- Rotate `v` about the **unit** axis given by *scalar* components `(nx, ny, nz)` by
    angle `φ`, via Rodrigues' formula, returning a `Vec3.mk` of scalar expressions.

    Why a scalar axis: `Vec3 α = Fin 3 → α` values are unevaluated closures, and the axis
    of `rotateAxis` is read ~6× per call (in `n·v`, `n×v`, and the `n` term). When that
    axis is itself a nested `cross`/`normalize` expression (the corner binormal), the cost
    compounds multiplicatively through nested rotations and explodes — whereas a cheap
    (literal / scalar) axis keeps a single rotation's reads `O(1)`. Callers read the
    binormal's three components into scalars *once* and pass them here, so nested rotations
    about the same tilted plane stay cheap. -/
def rotateAxisC [TrackScalar α] (nx ny nz φ : α) (v : Vec3 α) : Vec3 α :=
  let c := TrackScalar.cos φ
  let s := TrackScalar.sin φ
  let vx := v 0; let vy := v 1; let vz := v 2
  let d := nx * vx + ny * vy + nz * vz
  let k := d * (1 - c)
  mk (c * vx + s * (ny * vz - nz * vy) + k * nx)
     (c * vy + s * (nz * vx - nx * vz) + k * ny)
     (c * vz + s * (nx * vy - ny * vx) + k * nz)

/-- Rotate `v` about the **unit** axis `n` by angle `φ`, via Rodrigues' rotation
    formula `v cosφ + (n × v) sinφ + n (n·v)(1 − cosφ)`. Reads `n`'s components into
    scalars and defers to `rotateAxisC`. For `n = ẑ` and a planar `v` this reduces
    exactly to a 2D rotation in the XY-plane. -/
def rotateAxis [TrackScalar α] (n : Vec3 α) (φ : α) (v : Vec3 α) : Vec3 α :=
  rotateAxisC (n 0) (n 1) (n 2) φ v

/-- Rotate `v` by the rotation-vector (axis-angle) `ω`: the axis is `ω̂` and the angle
    is `‖ω‖`. This is the exponential map of `so(3)` applied to `v`; it is how a Frenet
    frame is advanced by an instantaneous Darboux vector `ω = τT + κB`. Returns `v`
    unchanged for `ω = 0`. -/
def rotateBy [TrackScalar α] (ω : Vec3 α) (v : Vec3 α) : Vec3 α :=
  let φ2 := normSq ω
  if φ2 = 0 then v
  else
    let φ := TrackScalar.sqrt φ2
    rotateAxis ((1 / φ) • ω) φ v

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

  Geometry is derived from essential parameters. Curved segments carry an unsigned
  `radius` plus the `binormal` of their (generally tilted) plane; the binormal's
  orientation carries the turn handedness (it is `±ẑ` for a planar `z=0` corner).
  - `straight`: defined by startPt and endPt (length is computed as distance)
  - `arc`: defined by radius, startPt, endPt, startTangent, binormal, and optionally a
    sweep angle (center is derived)
  - `transitionIn`: defined by radius, startPt, startTangent, binormal, and length
  - `transitionOut`: defined by radius, startPt, startTangent, binormal, and length -/
inductive Segment (α : Type) : Curvature α → Curvature α → Type where
  | straight (startPt endPt : Vec3 α) : Segment α .straight .straight
  | arc (radius : α) (startPt endPt : Vec3 α) (startTangent : Vec3 α)
      (binormal : Vec3 α) (sweep : Option α := none) :
      Segment α (.curved radius) (.curved radius)
  | transitionIn (radius : α) (continuity : GeometricContinuity := .gn 2)
      (startPt startTangent : Vec3 α) (binormal : Vec3 α) (length : α)
      (curveType : TransitionCurveType := .clothoid) :
      Segment α .straight (.curved radius)
  | transitionOut (radius : α) (continuity : GeometricContinuity := .gn 2)
      (startPt startTangent : Vec3 α) (binormal : Vec3 α) (length : α)
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

/-- Compute the center of the circle through `p` with tangent `v` at `p` and given
    radius `r`, in the plane with binormal `B` (default `ẑ`). The in-plane normal is
    `B × v̂`; handedness (which side the center sits) is carried by `B`'s orientation, so
    `r` is the unsigned radius. For planar `z=0` inputs with `B = ẑ` this reduces to the
    old `perp v` form. -/
def circleCenter [TrackScalar α] (p v : Vec3 α) (r : α)
    (B : Vec3 α := Vec3.mk 0 0 1) : Vec3 α :=
  let n := Vec3.cross B v
  p + (r / Vec3.norm v) • n

/-- Rotate a vector by angle `φ` in the XY-plane (counterclockwise for `φ > 0`),
    preserving the Z component. Thin shim over the general `rotateAxis` about `ẑ`;
    kept for the (planar) corner solver during the 3D migration. -/
def Vec3.rotateXY [TrackScalar α] (φ : α) (v : Vec3 α) : Vec3 α :=
  Vec3.rotateAxis (Vec3.mk 0 0 1) φ v

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
  | .arc radius startPt endPt startTangent binormal sweep =>
    match sweep with
    | some φ => (if radius > 0 then radius else -radius) * (if φ < 0 then -φ else φ)
    | none =>
      -- Derive the center and compute the minor arc length.
      let center := circleCenter startPt startTangent radius binormal
      arcLength center startPt endPt radius
  | .transitionIn _ _ _ _ _ len _ => len
  | .transitionOut _ _ _ _ _ len _ => len

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

/-- Inject an `Int` into `α`. Used for per-corner turn windings. -/
def intToScalar [TrackScalar α] : Int → α
  | .ofNat n => natToScalar n
  | .negSucc n => -natToScalar (n + 1)

/-- Absolute value using only the order operations in `TrackScalar`. -/
def absScalar [TrackScalar α] (x : α) : α := if x < 0 then -x else x

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

/-! ### Frenet–Serret moving frame

A space curve is described by its **Frenet frame** `(T, N, B)` — unit tangent, normal and
binormal — evolving by the Frenet–Serret equations

  `T' = κN`,  `N' = −κT + τB`,  `B' = −τN`,

where `κ(s)` is curvature and `τ(s)` is torsion. Equivalently each basis vector rotates
about the instantaneous **Darboux axis** `ω = τT + κB`: `X' = ω × X`. Integrating that
rotation keeps the frame orthonormal by construction, and the position follows by
quadrature of the tangent, `p(s) = p₀ + ∫₀ˢ T du`.

This subsumes the planar clothoid: with `τ ≡ 0` and `B = ẑ` the frame stays in the XY-plane
and the sampler reproduces `clothoidOffset` exactly. Torsion lets the curve leave the plane
smoothly — the foundation for torsion-continuous 3D transitions. -/

/-- An orthonormal Frenet frame: unit tangent `T`, normal `N`, binormal `B`. -/
structure Frame (α : Type) where
  T : Vec3 α
  N : Vec3 α
  B : Vec3 α

/-- Integrate a curve from start point `p₀` and start frame `fr` along arc-length `[0, s]`,
    given the **accumulated** turn and twist angles `Θκ(u) = ∫₀ᵘ κ` and `Θτ(u) = ∫₀ᵘ τ`
    (closed-form for our piecewise-linear `κ`/`τ` profiles). Returns the end point and the
    end frame.

    The interval is split into `panels` equal panels. Within each panel the position is
    integrated with the same composite 3-point Gauss–Legendre rule as `clothoidOffset`,
    evaluating the tangent at each node by rotating the panel-start frame through the
    sub-interval Darboux vector. The frame is then advanced across the whole panel by one
    Darboux rotation. With `Θτ ≡ 0` the Darboux axis is the constant binormal, every
    rotation angle is exact, and this reduces to the planar clothoid integral.

    The running frame and position are held as **scalar** components, not as `Vec3`
    values. `Vec3 α` is `Fin 3 → α` — a function — so a `Vec3` built by `+`/`•`/`rotateBy`
    is an unevaluated closure that re-runs on every component read; accumulating one across
    `panels` steps (each rotation reads its input several times) costs exponentially.
    Scalar `let mut` bindings, by contrast, store forced values, so each step is O(1). -/
def frameSample [TrackScalar α] (p₀ : Vec3 α) (fr : Frame α)
    (Θκ Θτ : α → α) (s : α) (panels : Nat) : Vec3 α × Frame α :=
  let two   : α := natToScalar 2
  let node  : α := TrackScalar.sqrt (natToScalar 3 / natToScalar 5)  -- √(3/5)
  let wSide : α := natToScalar 5 / natToScalar 9                     -- 5/9
  let wMid  : α := natToScalar 8 / natToScalar 9                     -- 8/9
  let h     : α := s / natToScalar panels
  let half  : α := h / two
  Id.run do
    let mut px := p₀ 0; let mut py := p₀ 1; let mut pz := p₀ 2
    let mut Tx := fr.T 0; let mut Ty := fr.T 1; let mut Tz := fr.T 2
    let mut Nx := fr.N 0; let mut Ny := fr.N 1; let mut Nz := fr.N 2
    let mut Bx := fr.B 0; let mut By := fr.B 1; let mut Bz := fr.B 2
    for k in [0:panels] do
      -- Rebuild the panel-start frame from the forced scalar components (O(1) reads).
      let T := Vec3.mk Tx Ty Tz
      let N := Vec3.mk Nx Ny Nz
      let B := Vec3.mk Bx By Bz
      let a   : α := natToScalar k * h        -- panel start (absolute arc-length)
      let m   : α := a + half                 -- panel midpoint
      let Θκa := Θκ a
      let Θτa := Θτ a
      -- Unit tangent at sub-interval offset `u ∈ [a, a+h]`, found by rotating the
      -- panel-start frame through the accumulated Darboux vector over `[a, u]`.
      let tNode := fun (u : α) =>
        Vec3.rotateBy ((Θτ u - Θτa) • T + (Θκ u - Θκa) • B) T
      let u0 := m - half * node
      let u2 := m + half * node
      let contrib := wSide • tNode u0 + wMid • tNode m + wSide • tNode u2
      px := px + half * contrib 0
      py := py + half * contrib 1
      pz := pz + half * contrib 2
      -- Advance the frame across the whole panel by one Darboux rotation, storing the
      -- rotated components back into the scalar accumulators.
      let ω := (Θτ (a + h) - Θτa) • T + (Θκ (a + h) - Θκa) • B
      let T' := Vec3.rotateBy ω T
      let N' := Vec3.rotateBy ω N
      let B' := Vec3.rotateBy ω B
      Tx := T' 0; Ty := T' 1; Tz := T' 2
      Nx := N' 0; Ny := N' 1; Nz := N' 2
      Bx := B' 0; By := B' 1; Bz := B' 2
    return (Vec3.mk px py pz, ⟨Vec3.mk Tx Ty Tz, Vec3.mk Nx Ny Nz, Vec3.mk Bx By Bz⟩)

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
    integral degenerates correctly on its own.

    The curve is planar (zero torsion), so rather than integrating a moving frame we take
    the scalar local offset `(xLocal, yLocal)` from `clothoidOffset` and place it in the
    corner's plane: `p + xLocal·v̂ + yLocal·n̂` where `v̂` is the unit start tangent and
    `n̂ = B × v̂` the in-plane normal (turn sense carried by the binormal `B`'s
    orientation; `B = ẑ` with planar inputs reproduces the old XY frame). We read `B`,
    `v̂` and `p` into scalars once and assemble the result component-wise — keeping reads
    cheap even when the stored tangent/binormal are nested rotation expressions. -/
def clothoidPoint [TrackScalar α] (p v : Vec3 α) (κ₀ κ₁ L s : α)
    (B : Vec3 α := Vec3.mk 0 0 1) : Vec3 α :=
  let κ' := (κ₁ - κ₀) / L
  let (xL, yL) := clothoidOffset κ₀ κ' s clothoidPanels
  let vUnit := Vec3.normalize v
  let tx := vUnit 0; let ty := vUnit 1; let tz := vUnit 2
  let bx := B 0; let bYc := B 1; let bz := B 2
  -- in-plane normal n̂ = B × v̂
  let nx := bYc * tz - bz * ty
  let ny := bz * tx - bx * tz
  let nz := bx * ty - bYc * tx
  Vec3.mk (p 0 + xL * tx + yL * nx)
          (p 1 + xL * ty + yL * ny)
          (p 2 + xL * tz + yL * nz)

/-- Evaluate a point along a transition curve at arc-length `s` (0 ≤ s ≤ L). -/
def transitionPoint [TrackScalar α]
    (p v : Vec3 α) (κ₀ κ₁ L s : α) (type : TransitionCurveType)
    (B : Vec3 α := Vec3.mk 0 0 1) : Vec3 α :=
  match type with
  | .clothoid => clothoidPoint p v κ₀ κ₁ L s B

/-- Sample a point at arc-length `t` along a single segment.
    Assumes `0 ≤ t ≤ seg.length`. -/
def Segment.pointAt [TrackScalar α] {cA cB : Curvature α}
    (seg : Segment α cA cB) (t : α) : Vec3 α :=
  match seg with
  | .straight p q =>
    let len := Vec3.dist p q
    let frac := if len = 0 then 0 else t / len
    Vec3.lerp p q frac
  | .arc r p _ v B _ =>
    -- A circular arc is the constant-curvature (`κ = 1/r`), zero-torsion case of the
    -- frame integrator in the corner's plane: the unsigned curvature gives the bend
    -- magnitude and the binormal `B` carries the turn direction. `L` is unused here
    -- (κ is constant, so κ' = 0); pass 1 to keep the divisor nonzero.
    clothoidPoint p v (1 / r) (1 / r) 1 t B
  | .transitionIn r _ p v B len cType =>
    transitionPoint p v 0 (1 / r) len t cType B
  | .transitionOut r _ p v B len cType =>
    transitionPoint p v (1 / r) 0 len t cType B

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

/-- Design parameters for auto-radius PI construction.

    Transition length is no longer a fixed geometric ratio: it is the *minimum*
    spiral that keeps the ride within comfort limits. Each corner runs at its own
    operating speed `V = √(a_max·R)` (the fastest the circular arc allows under the
    lateral-acceleration limit), and the clothoid is then made just long enough to
    cap both lateral jerk and yaw (heading) angular acceleration:

      `Ls = max( V³/(R·j_max), V²/(R·α_max) )`.

    Units are interpreted with **1 scene unit = 1 metre** (so `a_max` is m/s²,
    `j_max` m/s³, `α_max` rad/s²). Setting `maxLateralAccel ≤ 0` switches the speed
    model off and recovers the pure circular fillet (no transitions). -/
structure DesignParams (α : Type) where
  /-- Fraction (≤ 0.5) of the shorter adjacent leg a single corner may consume. -/
  legBudget : α
  /-- Minimum permitted arc radius (world units; 1 unit = 1 m). No corner is rounded —
      or resized — tighter than this: the tangent budget is floored at `minRadius ·
      tan(Δ/2)`, the pullback that yields exactly this radius. A corner too sharp or
      whose legs are too short to reach it is rounded as gently as the legs allow
      (budget capped at half the shorter leg). Roughly an AREMA-style absolute floor for
      sharp standard-gauge (yard / industrial) track. `≤ 0` disables the floor. -/
  minRadius : α
  /-- Corners whose `|sin Δ|` is below this are treated as straight (no arc). -/
  straightThreshold : α
  /-- Maximum lateral (centripetal) acceleration tolerated on the circular arc.
      Fixes each corner's operating speed via `V = √(a_max·R)`. `≤ 0` disables the
      speed model, recovering a pure straight→arc→straight corner. -/
  maxLateralAccel : α
  /-- Maximum lateral jerk (rate of change of lateral acceleration) on the
      transition. Imposes `Ls ≥ V³/(R·j_max)`. `≤ 0` drops this criterion. -/
  maxLateralJerk : α
  /-- Maximum yaw angular acceleration (rate of change of heading rate) on the
      transition. Imposes `Ls ≥ V²/(R·α_max)`. `≤ 0` drops this criterion. -/
  maxYawAccel : α
  /-- Design-speed ceiling. Operating speed is capped, `V = min(maxDesignSpeed,
      √(a_max·R))`, so large-radius curves that *could* exceed it don't get oversized
      transitions, and straights run at this speed. `≤ 0` leaves the speed uncapped. -/
  maxDesignSpeed : α

/-- Directional and angular facts for one interior PI, independent of any chosen
    tangent budget. `none` means the corner is degenerate or near-straight. -/
structure CornerGeometry (α : Type) where
  /-- Unit direction along the incoming leg, pointing into the PI. -/
  uIn : Vec3 α
  /-- Unit direction along the outgoing leg, pointing away from the PI. -/
  uOut : Vec3 α
  /-- Unit binormal of the corner's plane, oriented so the curve turns *left* about it
      (i.e. rotating `uIn` toward `uOut` by the selected turn is a positive rotation about
      `binormal`). For a planar `z=0` corner this is `+ẑ` on a left turn and `−ẑ` on a
      right turn, so rotating about it reproduces the old `signOf`/`ẑ` behaviour. -/
  binormal : Vec3 α
  /-- Signed `sin Δ` of the principal deflection; positive for a left turn. -/
  sinSigned : α
  /-- `cos Δ`. -/
  cosDelta : α
  /-- Signed total turn angle selected for this corner. Nonzero windings add full
      revolutions, allowing looped spiral-arc-spiral corners. -/
  turn : α
  /-- `tan(Δ₀/2)` of the *principal* deflection (always positive). Independent of
      winding: a wound corner sweeps the same fillet circle through extra revolutions. -/
  tanHalf : α
  /-- Unsigned selected turn angle `Δ`. -/
  delta : α
  /-- Shorter adjacent leg length. -/
  shorterLeg : α
  /-- Maximum tangent budget: half the shorter adjacent leg. -/
  maxBudget : α
  /-- Minimum tangent budget implied by `DesignParams.minRadius`, capped to `maxBudget`. -/
  minBudget : α

/-- Compute shared corner geometry for an interior PI. This is the common source for
    path construction and UI curve-end controls, so straight/degenerate detection and
    min/max budget bounds stay aligned. -/
def cornerGeometry [TrackScalar α] (a b c : Vec3 α) (dp : DesignParams α)
    (winding : Int := 0) :
    Option (CornerGeometry α) :=
  let dIn := b - a
  let dOut := c - b
  let nIn := Vec3.norm dIn
  let nOut := Vec3.norm dOut
  if nIn = 0 ∨ nOut = 0 then none
  else
    let uIn := (1 / nIn) • dIn
    let uOut := (1 / nOut) • dOut
    let sinSigned := Vec3.crossZ uIn uOut
    -- True |sin Δ| of the deflection, `‖uIn × uOut‖` — rotation-invariant, so a corner in
    -- a steep/tilted plane (where the `ẑ`-component `crossZ` is small) is not misread as
    -- straight. Equals `|crossZ|` for planar `z=0` corners, so the 2D path is unchanged.
    let sinAbs := Vec3.norm (Vec3.cross uIn uOut)
    let cosD := max (-1) (min 1 (Vec3.dot uIn uOut))
    let two : α := natToScalar 2
    let fullTurn := two * TrackScalar.pi
    let minor := TrackScalar.arccos cosD
    let principal := if sinSigned < 0 then -minor else minor
    let selected :=
      if sinAbs ≤ dp.straightThreshold then
        if winding = 0 then 0 else intToScalar winding * fullTurn
      else
        principal + intToScalar winding * fullTurn
    let delta := absScalar selected
    if delta ≤ dp.straightThreshold then none
    else
      let shorter := min nIn nOut
      let hi := (1 / two) * shorter
      -- `tan(Δ/2)` of the *selected* (possibly wound) turn. For a reflex turn
      -- (Δ ∈ (π, 2π), i.e. a reverse-winding loop) this is negative; that sign is
      -- exactly what flips the `K` term of the clothoid shift in the radius fit, so we
      -- keep it signed and let the consumers `absScalar` it where a magnitude is wanted.
      let cosT := TrackScalar.cos delta
      let tanHalf := TrackScalar.sin delta / (1 + cosT)
      let radiusFloorBudget := dp.minRadius * absScalar tanHalf
      let lo := min radiusFloorBudget hi
      -- Unit binormal of the corner's plane, oriented so a *positive* rotation about it
      -- carries `uIn` toward `uOut` along the selected turn. The geometric normal
      -- `uIn × uOut` already does this for the principal (minor) deflection; when the
      -- selected turn winds onto the opposite side (reflex / reverse loop) we flip it.
      -- For collinear legs (a wound loop on a straight) there is no leg-plane, so we fall
      -- back to `±ẑ` by the turn sense — reproducing the old rotate-about-`ẑ` behaviour.
      let cr := Vec3.cross uIn uOut
      let crNorm := Vec3.norm cr
      let binormal : Vec3 α :=
        if crNorm ≤ dp.straightThreshold then
          if selected > 0 then Vec3.mk 0 0 1 else Vec3.mk 0 0 (-1)
        else
          let nHat := (1 / crNorm) • cr
          let reversed := decide (selected > 0) != decide (sinSigned > 0)
          if reversed then (-(1 : α)) • nHat else nHat
      some { uIn := uIn, uOut := uOut, binormal := binormal, sinSigned := sinSigned,
             cosDelta := cosD, turn := selected, tanHalf := tanHalf, delta := delta,
             shorterLeg := shorter, maxBudget := hi, minBudget := lo }

/-- Whether the selected turn winds onto the *opposite* side from the principal
    deflection — a reverse-winding loop. When set, the corner is tangent to the legs on
    their extension rays (ahead of the PI on the entry leg, behind it on the exit leg)
    rather than the minor-fillet rays, so the tangent points flip sign. -/
def CornerGeometry.reversed [TrackScalar α] (g : CornerGeometry α) : Bool :=
  decide (g.turn > 0) != decide (g.sinSigned > 0)

/-- The entry tangent point (start of the curved run) for budget `budget` at PI `b`. -/
def CornerGeometry.entryPoint [TrackScalar α] (g : CornerGeometry α) (b : Vec3 α)
    (budget : α) : Vec3 α :=
  if g.reversed then b + budget • g.uIn else b - budget • g.uIn

/-- The exit tangent point (end of the curved run) for budget `budget` at PI `b`. -/
def CornerGeometry.exitTangentPoint [TrackScalar α] (g : CornerGeometry α) (b : Vec3 α)
    (budget : α) : Vec3 α :=
  if g.reversed then b - budget • g.uOut else b + budget • g.uOut

/-- A corner geometry plus the clamped tangent budget and its two tangent points. -/
structure CornerLayout (α : Type) extends CornerGeometry α where
  /-- The chosen tangent budget after override/default selection and clamping. -/
  budget : α
  /-- Where the straight leading into the corner ends. -/
  entryPoint : Vec3 α
  /-- Where the straight leaving the corner begins. -/
  exitPoint : Vec3 α

/-- Select and clamp the tangent budget for an interior PI, returning the tangent
    endpoints that consume that budget. An override is an absolute world-unit budget;
    `none` uses `dp.legBudget * shorter adjacent leg`. -/
def cornerLayout [TrackScalar α] (a b c : Vec3 α) (dp : DesignParams α)
    (override : Option α := none) (winding : Int := 0) : Option (CornerLayout α) :=
  match cornerGeometry a b c dp winding with
  | none => none
  | some g =>
      let cand := match override with
        | some o => o
        | none => dp.legBudget * g.shorterLeg
      let budget := max g.minBudget (min g.maxBudget cand)
      some { toCornerGeometry := g, budget := budget,
             entryPoint := g.entryPoint b budget, exitPoint := g.exitTangentPoint b budget }

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
  /-- Operating speed this corner is designed for, `V = √(a_max·R)` from the fitted
      radius (`0` when the speed model is disabled). The transition lengths are the
      minimum that hold this speed within the jerk/yaw limits. -/
  opSpeed : α
  /-- The fitted (unsigned) arc radius — handy for speed restrictions / labels. -/
  radius : α

/-- Solve a non-degenerate corner from precomputed shared corner geometry. -/
def solveCornerWithGeometry [TrackScalar α] (b : Vec3 α) (budget : α)
    (dp : DesignParams α) (g : CornerGeometry α) : CornerSolution α :=
  let uIn := g.uIn
  let two : α := natToScalar 2
  -- Binormal of the corner's plane; all in-plane rotations and curvatures are about it,
  -- with unsigned magnitudes. Handedness (left/right, reflex windings) lives entirely in
  -- `B`'s orientation, so a rotation about `B` here replaces the old `rotateXY (signOf θ)`.
  -- Read its components into scalars once: used as the (cheap) axis of every in-plane
  -- rotation, so nested rotations stay shallow (see `rotateAxisC`).
  let B := g.binormal
  let bx := B 0; let bYc := B 1; let bz := B 2
  -- The selected turn is "reversed" when it winds onto the opposite side from the
  -- principal deflection (e.g. a right-going loop on a left corner). The minor fillet
  -- is tangent at `b - budget·uIn` / `b + budget·uOut`; the reverse arc is tangent to
  -- the same legs but on their *extension* rays, so the tangent bases flip sign.
  let entryBase := g.entryPoint b budget
  let exitBase  := g.exitTangentPoint b budget
  let tanHalf := g.tanHalf
  let safeDenom := fun (x : α) =>
    let ax := absScalar x
    if ax ≤ dp.straightThreshold then dp.straightThreshold else ax
  let Δ := g.delta
  -- Speed-derived spiral. Each corner runs at `V = √(a_max·R)`; the clothoid is
  -- the shortest that holds that speed within the jerk and yaw-accel limits. `θs`
  -- and `R` are mutually dependent, so we fixed-point from the pure-fillet radius.
  let aMax := dp.maxLateralAccel
  let cap := dp.maxDesignSpeed
  -- Operating speed at fitted radius `R`: the arc's `√(a_max·R)`, capped at the
  -- design speed (so over-fast curves don't get oversized transitions).
  let speedAt := fun (R : α) =>
    let v := TrackScalar.sqrt (aMax * R)
    if cap > 0 then min cap v else v
  -- Transition length demanded at fitted radius `R` (the max of the two criteria).
  let lsOf := fun (R : α) =>
    let V := speedAt R
    let lsJerk := if dp.maxLateralJerk > 0 then (V * V * V) / (R * dp.maxLateralJerk) else 0
    let lsYaw  := if dp.maxYawAccel   > 0 then (V * V)     / (R * dp.maxYawAccel)  else 0
    max lsJerk lsYaw
  -- Fitted radius for spiral angle `θ > 0` (unit-clothoid shift `(P, K)` at angle θ).
  let radiusOf := fun (θ : α) =>
    let Ls1 := two * θ
    let (X1, Y1) := clothoidOffset 0 (1 / Ls1) Ls1 clothoidPanels
    let P := Y1 - (1 - TrackScalar.cos θ)
    let K := X1 - TrackScalar.sin θ
    budget / safeDenom ((1 + P) * tanHalf + K)
  -- One step: radius → spiral angle `θs = Ls/(2R)`, clamped so an arc remains.
  let stepθ := fun (R : α) => min (lsOf R / (two * R)) (Δ / two)
  let θs :=
    if aMax ≤ 0 then 0
    else Id.run do
      let mut R := budget / safeDenom tanHalf -- seed: pure-fillet radius where available
      let mut θ := stepθ R
      for _ in [0:4] do
        if θ > 0 then
          R := radiusOf θ
          θ := stepθ R
      return θ
  if θs ≤ 0 then
    -- No transitions: classic circular fillet (straight → arc → straight).
    let absR := budget / safeDenom tanHalf
    let pc := entryBase
    let pt := exitBase
    let opSpeed := if aMax > 0 then speedAt absR else 0
    { entryPoint := pc, exitPoint := pt, opSpeed := opSpeed, radius := absR,
      pieces := #[AnySegment.of (Segment.arc absR pc pt uIn B (some Δ))] }
  else
    -- Symmetric spiral corner. Shift constants from a unit clothoid (R = 1).
    let Ls1 := two * θs
    let (X1, Y1) := clothoidOffset 0 (1 / Ls1) Ls1 clothoidPanels
    let P := Y1 - (1 - TrackScalar.cos θs)
    let K := X1 - TrackScalar.sin θs
    let absR := budget / safeDenom ((1 + P) * tanHalf + K)
    let opSpeed := speedAt absR
    let Ls := two * absR * θs
    -- In-plane rotations use the scalar binormal `(bx,by,bz)` as a cheap axis, so the
    -- stored tangents stay shallow (cf. `rotateAxisC`); `sc` and the arc end are already
    -- scalar-assembled by `clothoidPoint`/`circleCenter`.
    let ts := entryBase                              -- entry tangent→spiral point
    let sc := clothoidPoint ts uIn 0 (1 / absR) Ls Ls B -- entry spiral end = arc start
    let tanSC := Vec3.rotateAxisC bx bYc bz θs uIn    -- tangent at sc
    let φ := Δ - two * θs                            -- circular arc central angle (≥ 0)
    let o := circleCenter sc tanSC absR B            -- arc center
    let cs := o + Vec3.rotateAxisC bx bYc bz φ (sc - o) -- arc end = exit spiral start
    let tanCS := Vec3.rotateAxisC bx bYc bz φ tanSC   -- tangent at cs
    let entrySeg := AnySegment.of
      (Segment.transitionIn (radius := absR) (startPt := ts) (startTangent := uIn)
        (binormal := B) (length := Ls))
    let exitSeg := AnySegment.of
      (Segment.transitionOut (radius := absR) (startPt := cs) (startTangent := tanCS)
        (binormal := B) (length := Ls))
    let pieces :=
      if φ ≤ dp.straightThreshold then #[entrySeg, exitSeg]
      else #[entrySeg, AnySegment.of (Segment.arc absR sc cs tanSC B (some φ)), exitSeg]
    { entryPoint := ts, exitPoint := exitSeg.pointAt Ls, pieces := pieces,
      opSpeed := opSpeed, radius := absR }

/-- Solve the corner at interior PI `b`, between prev PI `a` and next PI `c`, consuming
    `budget` of tangent length along each leg. Returns `none` when the legs are (near)
    collinear — the corner is straight and contributes nothing.

    With `dp.maxLateralAccel ≤ 0` this is the classic circular fillet: the tangent
    points sit `budget` back from `b` along each leg and `R = budget / tan(Δ/2)`, so the
    arc is exactly tangent to both legs.

    Otherwise the corner is the standard symmetric spiral: an entry clothoid, a circular
    arc, and an exit clothoid. The spiral angle `θs = Ls/(2R)` is now *speed-derived*
    rather than a fixed ratio. The corner's operating speed is the fastest its arc
    allows, `V = √(a_max·R)`, and the transition is the shortest clothoid that keeps the
    ride within the comfort limits:

      `Ls = max( V³/(R·j_max), V²/(R·α_max) )`   (jerk- and yaw-acceleration-limited).

    This couples `θs` to `R`: the radius is fitted to the budget via the clothoid shift,
    `R = budget / ((1+P)·tan(Δ/2) + K)` with `(P, K)` from a unit clothoid of angle `θs`,
    while `θs` depends on `R` through `Ls`. Because `P, K` are tiny for realistic
    spirals, a short fixed-point iteration (seeded from the pure-fillet radius) converges
    to float precision. `θs` is clamped to `Δ/2` so a non-negative circular arc remains;
    very sharp corners saturate at a full-spiral corner (and then exceed the nominal
    jerk, the geometric price of a corner too tight for its speed). -/
def solveCorner [TrackScalar α] (a b c : Vec3 α) (budget : α) (dp : DesignParams α) :
    Option (CornerSolution α) :=
  match cornerGeometry a b c dp with
  | none => none
  | some g => some (solveCornerWithGeometry b budget dp g)

/-- Build an `AlignmentPath` from a polyline of PIs.

    The first and last PIs are endpoints. Each interior PI is rounded with a circular
    arc whose radius fits a tangent budget = `legBudget × (shorter adjacent leg)`.
    Near-collinear corners pass straight through.

    `overrides` optionally supplies a per-PI tangent budget (absolute world units) that
    replaces the auto `legBudget` value at that corner. Each override is clamped to
    `(0, ½ · shorter adjacent leg]` so a dragged control point can never cross the PI or
    overrun a leg. An out-of-range index or a `none` falls back to the auto budget. -/
def buildPath [TrackScalar α] (pts : Array (Vec3 α)) (dp : DesignParams α)
    (overrides : Array (Option α) := #[]) (windings : Array Int := #[]) :
    AlignmentPath α :=
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
        match cornerLayout a b c dp ((overrides[i]?).bind id) ((windings[i]?).getD 0) with
        | none => pure ()
        | some layout =>
          let sol := solveCornerWithGeometry b layout.budget dp layout.toCornerGeometry
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
