import TrackGeometry.Scalar

/-! # Clothoid quadrature

Composite 3-point Gauss–Legendre quadrature for clothoid offsets and unit-clothoid
shift parameters, shared by both 2D and 3D alignments.

We evaluate clothoid offsets by integrating the unit tangent `(cos θ(u), sin θ(u))`
directly rather than reducing to Fresnel integrals. The heading is the running turn
angle `θ(u) = κ₀·u + ½·κ'·u²` of a linearly-varying-curvature transition.
-/

/-- Number of equal panels used by the composite Gauss–Legendre clothoid integrator.

Sixteen panels of a quintic-exact rule resolve any realistic transition (total turn
angle well under a full turn) to far better than floating-point precision. -/
def clothoidPanels : Nat := 16

/-- Panelization data for the composite 3-point Gauss–Legendre quadrature rule on `[0, s]`.

Stores the reference node offset `√(3/5)`, the side and midpoint weights `5/9` and
`8/9`, and the panel width with its half-width, built using only `0`, `1`, division,
and square root so it stays generic over any track scalar. -/
structure GL3 (α : Type) where
  /-- Positive quadrature node offset `√(3/5)` on the reference interval `[-1, 1]`. -/
  node  : α
  /-- Quadrature weight `5/9` for each of the two outer nodes. -/
  wSide : α
  /-- Quadrature weight `8/9` for the midpoint node. -/
  wMid  : α
  /-- Width of each integration panel. -/
  h     : α
  /-- Half-width of each integration panel. -/
  half  : α

/-- Build the 3-point Gauss–Legendre panelization of `[0, s]` into `panels` equal panels. -/
def GL3.on [TrackScalar α] (s : α) (panels : Nat) : GL3 α :=
  let h : α := s / natToScalar panels
  { node  := TrackScalar.sqrt (natToScalar 3 / natToScalar 5)
    wSide := natToScalar 5 / natToScalar 9
    wMid  := natToScalar 8 / natToScalar 9
    h     := h
    half  := h / natToScalar 2 }

/-- Integrate the local clothoid offset along and perpendicular to the start tangent.

Evaluates `(∫₀ˢ cos θ(u) du, ∫₀ˢ sin θ(u) du)` with composite 3-point Gauss–Legendre
quadrature, where `θ(u) = κ₀·u + ½·κ'·u²`. -/
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

/-- Compute the shift parameters `(P, K)` of a unit clothoid with spiral angle `θ > 0`.

For a circular arc of radius `R` and corner deflection `Δ`, the corner's tangent
budget is `R·((1 + P)·tan(Δ/2) + K)`. -/
def clothoidShift [TrackScalar α] (θ : α) : α × α :=
  let Ls1 := natToScalar 2 * θ
  let (X1, Y1) := clothoidOffset 0 (1 / Ls1) Ls1 clothoidPanels
  (Y1 - (1 - TrackScalar.cos θ), X1 - TrackScalar.sin θ)
