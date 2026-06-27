import TrackGeometry.Vec

/-! # Segments, clothoids, and rotation-minimizing frames

`Segment`, clothoid integration, `Frame` / RMF, and closed-form sampling.
-/

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

/-- Compute the center of the circle through `p` with tangent `v` at `p` and given
    radius `r`, in the plane with binormal `B` (default `ẑ`). The in-plane normal is
    `B × v̂`; handedness (which side the center sits) is carried by `B`'s orientation, so
    `r` is the unsigned radius. -/
def circleCenter [TrackScalar α] (p v : Vec3 α) (r : α)
    (B : Vec3 α := Vec3.mk 0 0 1) : Vec3 α :=
  let n := Vec3.cross B v
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
  | .arc radius startPt endPt startTangent binormal sweep =>
    match sweep with
    | some φ => (if radius > 0 then radius else -radius) * (if φ < 0 then -φ else φ)
    | none =>
      -- Derive the center and compute the minor arc length.
      let center := circleCenter startPt startTangent radius binormal
      arcLength center startPt endPt radius
  | .transitionIn _ _ _ _ _ len _ => len
  | .transitionOut _ _ _ _ _ len _ => len


/-! ## Transition curve evaluation -/

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

/-- Panelization data for the composite 3-point Gauss–Legendre rule on `[0, s]`:
    the node offset `√(3/5)`, the weights `5/9` / `8/9`, and the panel width `h`
    with its half-width. Built from `0`, `1`, division and `sqrt` only, so it stays
    generic over any `TrackScalar` (no decimal literals required). -/
structure GL3 (α : Type) where
  node  : α
  wSide : α
  wMid  : α
  h     : α
  half  : α

/-- The 3-point Gauss–Legendre panelization of `[0, s]` into `panels` equal panels. -/
def GL3.on [TrackScalar α] (s : α) (panels : Nat) : GL3 α :=
  let h : α := s / natToScalar panels
  { node  := TrackScalar.sqrt (natToScalar 3 / natToScalar 5)
    wSide := natToScalar 5 / natToScalar 9
    wMid  := natToScalar 8 / natToScalar 9
    h     := h
    half  := h / natToScalar 2 }

/-- Integrate `(cos θ(u), sin θ(u))` over `u ∈ [0, s]` with composite 3-point
    Gauss–Legendre quadrature, where `θ(u) = κ₀·u + ½·κ'·u²`. Returns the local
    offset `(xLocal, yLocal)` — displacement along and perpendicular to the start
    tangent. -/
def clothoidOffset [TrackScalar α] (κ₀ κ' s : α) (panels : Nat) : α × α :=
  let g : GL3 α := GL3.on s panels
  let heading : α → α := fun u => κ₀ * u + (κ' * u * u) / natToScalar 2
  Id.run do
    let mut sumC : α := 0
    let mut sumS : α := 0
    for k in [0:panels] do
      let m  : α := natToScalar k * g.h + g.half      -- panel midpoint
      let u0 : α := m - g.half * g.node
      let u2 : α := m + g.half * g.node
      sumC := sumC + g.wSide * TrackScalar.cos (heading u0)
                   + g.wMid  * TrackScalar.cos (heading m)
                   + g.wSide * TrackScalar.cos (heading u2)
      sumS := sumS + g.wSide * TrackScalar.sin (heading u0)
                   + g.wMid  * TrackScalar.sin (heading m)
                   + g.wSide * TrackScalar.sin (heading u2)
    return (g.half * sumC, g.half * sumS)

/-! ### Moving frame and rotation-minimizing frame (RMF)

A space curve carries a **moving frame** `(T, N, B)` — unit tangent, normal and binormal.
We propagate a **rotation-minimizing frame (RMF)**: the frame is seeded once at the start
and carried forward with zero rotation about the tangent, eliminating the classic Frenet
artifacts (normal flips at S-reversals, horizontal-reset on straights, roll jumps at plane
changes).

Within each planar segment (τ ≡ 0) the RMF angular velocity is `ω = κ·B`, so the frame is
an **exact rigid rotation** of the incoming frame about the segment's binormal by the heading
`θ(t)` — no integration needed. At segment boundaries a minimal rotation aligns the incoming
tangent to the new start tangent (the discrete double-reflection step; identity at G¹ joins).

Position is computed independently by the `clothoidPoint`/`pointAt` quadrature. -/

/-- An orthonormal moving frame: unit tangent `T`, normal `N`, binormal `B`. -/
structure Frame (α : Type) where
  T : Vec3 α
  N : Vec3 α
  B : Vec3 α

/-- Seed a rotation-minimizing frame from a tangent direction, using the convention
    `B = normalize(ẑ − (ẑ·T̂)T̂)` (project ẑ onto the plane ⊥ T̂), `N = B × T̂`.
    Falls back to x̂ as the reference when T ∥ ẑ (vertical track). -/
def Frame.fromTangent [TrackScalar α] (T : Vec3 α) : Frame α :=
  let Tn := Vec3.normalize T
  let zhat : Vec3 α := Vec3.mk 0 0 1
  let xhat : Vec3 α := Vec3.mk 1 0 0
  let d := Vec3.dot zhat Tn
  let Bproj := zhat - d • Tn
  let B := if Vec3.normSq Bproj = 0
            then Vec3.normalize (xhat - Vec3.dot xhat Tn • Tn)
            else Vec3.normalize Bproj
  let N := Vec3.normalize (Vec3.cross B Tn)
  ⟨Tn, N, B⟩

/-- Minimal rotation carrying `fr.T` onto the unit vector `T'`, applied to all three frame
    vectors via `rotateAxisC` (axis `fr.T × T'`, angle `arccos(fr.T · T')`). Returns `fr`
    unchanged when T' ∥ fr.T (zero axis). -/
def Frame.alignTo [TrackScalar α] (fr : Frame α) (T' : Vec3 α) : Frame α :=
  let axis := Vec3.cross fr.T T'
  let axisSq := Vec3.normSq axis
  if axisSq = 0 then fr
  else
    let d := max (-1) (min 1 (Vec3.dot fr.T T'))
    let φ := TrackScalar.arccos d
    let axN := Vec3.normalize axis
    let ax := axN 0; let ay := axN 1; let az := axN 2
    ⟨Vec3.rotateAxisC ax ay az φ fr.T,
     Vec3.rotateAxisC ax ay az φ fr.N,
     Vec3.rotateAxisC ax ay az φ fr.B⟩

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
  let g : GL3 α := GL3.on s panels
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
      let a   : α := natToScalar k * g.h      -- panel start (absolute arc-length)
      let m   : α := a + g.half               -- panel midpoint
      let Θκa := Θκ a
      let Θτa := Θτ a
      -- Unit tangent at sub-interval offset `u ∈ [a, a+h]`, found by rotating the
      -- panel-start frame through the accumulated Darboux vector over `[a, u]`.
      let tNode := fun (u : α) =>
        Vec3.rotateBy ((Θτ u - Θτa) • T + (Θκ u - Θκa) • B) T
      let u0 := m - g.half * g.node
      let u2 := m + g.half * g.node
      let contrib := g.wSide • tNode u0 + g.wMid • tNode m + g.wSide • tNode u2
      px := px + g.half * contrib 0
      py := py + g.half * contrib 1
      pz := pz + g.half * contrib 2
      -- Advance the frame across the whole panel by one Darboux rotation, storing the
      -- rotated components back into the scalar accumulators.
      let ω := (Θτ (a + g.h) - Θτa) • T + (Θκ (a + g.h) - Θκa) • B
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
    `n̂ = B × v̂` the in-plane normal (turn sense is carried by the binormal `B`'s
    orientation). We read `B`,
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

/-- The segment-plane binormal: the stored binormal for curved segments, `ẑ` for straights. -/
def Segment.planeBinormal [TrackScalar α] {cA cB : Curvature α} : Segment α cA cB → Vec3 α
  | .straight _ _ => Vec3.mk 0 0 1
  | .arc _ _ _ _ B _ => B
  | .transitionIn _ _ _ _ B _ _ => B
  | .transitionOut _ _ _ _ B _ _ => B

/-- Start tangent direction: `q − p` for straights, stored `v` for curved segments. -/
def Segment.startDir [TrackScalar α] {cA cB : Curvature α} : Segment α cA cB → Vec3 α
  | .straight p q => q - p
  | .arc _ _ _ v _ _ => v
  | .transitionIn _ _ _ v _ _ _ => v
  | .transitionOut _ _ _ v _ _ _ => v

/-- Running turn angle `θ(t)` — the heading the start tangent is rotated through to obtain
    the tangent at arc-length `t`. Mirrors `curvatureAt`'s integrand:
    - `straight → 0`
    - `arc → t/r`
    - `transitionIn → ½·(1/r)/len·t²`
    - `transitionOut → t/r − ½·(1/r)/len·t²` -/
def Segment.headingAt [TrackScalar α] {cA cB : Curvature α}
    (seg : Segment α cA cB) (t : α) : α :=
  match seg with
  | .straight _ _ => 0
  | .arc r _ _ _ _ _ => t / r
  | .transitionIn r _ _ _ _ len _ => (1 / r) / len * t * t / natToScalar 2
  | .transitionOut r _ _ _ _ len _ => t / r - (1 / r) / len * t * t / natToScalar 2

/-- Unit tangent at arc-length `t`: `startDir` rotated through `headingAt t` about the
    segment's plane binormal. Consistent with `pointAt` and `curvatureAt`. -/
def Segment.tangentAt [TrackScalar α] {cA cB : Curvature α}
    (seg : Segment α cA cB) (t : α) : Vec3 α :=
  Vec3.rotateAxis (Vec3.normalize seg.planeBinormal) (seg.headingAt t)
    (Vec3.normalize seg.startDir)

/-- Rotation-minimizing frame at local arc-length `t`, seeded by the pre-aligned incoming
    frame `fr`. Reads the normalized plane binormal into scalars once and rotates all three
    frame vectors through `headingAt t` via `rotateAxisC`. -/
def Segment.rmfAt [TrackScalar α] {cA cB : Curvature α}
    (seg : Segment α cA cB) (fr : Frame α) (t : α) : Frame α :=
  let B := Vec3.normalize seg.planeBinormal
  let bx := B 0; let by_ := B 1; let bz := B 2
  let θ := seg.headingAt t
  ⟨Vec3.rotateAxisC bx by_ bz θ fr.T,
   Vec3.rotateAxisC bx by_ bz θ fr.N,
   Vec3.rotateAxisC bx by_ bz θ fr.B⟩

/-- Sample the point and RMF at local arc-length `t`, propagated from the incoming frame
    `fr`. First aligns `fr.T` to the segment's start direction (identity at G¹ joins, a
    minimal rotation at tangent kinks), then rotates through the heading. The `.T` component
    always equals `tangentAt t`. -/
def Segment.frameAt [TrackScalar α] {cA cB : Curvature α}
    (seg : Segment α cA cB) (fr : Frame α) (t : α) : Vec3 α × Frame α :=
  let frIn := fr.alignTo (Vec3.normalize seg.startDir)
  (seg.pointAt t, seg.rmfAt frIn t)

/-- The RMF at the end of the segment — the propagation seed for the next segment. -/
def Segment.endFrame [TrackScalar α] {cA cB : Curvature α}
    (seg : Segment α cA cB) (fr : Frame α) : Frame α :=
  seg.rmfAt (fr.alignTo (Vec3.normalize seg.startDir)) seg.length

/-- Signed curvature `κ(t) = dθ/dt` at local arc-length `t` along a segment — the exact
    derivative of the heading `θ(t)` that `tangentAt` rotates the start tangent through.
    Profiles mirror `headingAt`'s termwise derivatives:

    - `straight → 0` (θ ≡ 0),
    - `arc → 1/r` (θ = t/r),
    - `transitionIn → (1/r)/len · t` (θ = ½·(1/r)/len·t², linear ramp 0 → 1/r),
    - `transitionOut → 1/r − (1/r)/len · t` (θ = t/r − ½·(1/r)/len·t², ramp 1/r → 0).

    Curvature is unsigned magnitude (turn sense lives in the binormal). Independently useful
    for cant / speed-view colouring, and the quantity the within-corner G² proofs compare. -/
def Segment.curvatureAt [TrackScalar α] {cA cB : Curvature α}
    (seg : Segment α cA cB) (t : α) : α :=
  match seg with
  | .straight _ _ => 0
  | .arc r _ _ _ _ _ => 1 / r
  | .transitionIn r _ _ _ _ len _ => (1 / r) / len * t
  | .transitionOut r _ _ _ _ len _ => 1 / r - (1 / r) / len * t
